// RealtimeMirror — subscribes to postgres_changes per synced table and
// applies INSERT/UPDATE (upsert into local) + DELETE (remove from local).
// One channel per table (unstuck_<table>_<uid>), filtered by user_id (RLS
// enforces server-side; the filter is client safety). calendar_connections
// is intentionally NOT subscribed — its encrypted credentials must never
// be broadcast (refreshed via polling instead).
//
// Self-healing (spec 02-sync-engine §5): realtime is fragile — a socket can
// drop, a channel can be closed server-side, and the very first subscribe
// can fail on a flaky launch. None of those must silently kill live sync for
// the whole session. So on top of the bare subscribe we layer three
// backstops, all converging on the ONE reliable path — a full REST hydrate:
//   1. bounded retry/backoff on the initial subscribe (a thrown subscribe no
//      longer returns and leaves realtime dead);
//   2. a socket-status observer that hydrates on every RE-connect (the SDK
//      re-joins channels itself; we backfill the events missed during the gap);
//   3. a per-channel status observer that, on an unexpected server close,
//      rebuilds the subscriptions + hydrates.
// The app layer adds a 4th: a ~60s foreground safety-net hydrate for the
// continuously-foregrounded case (see UnstuckApp/AppModel). Decode failures
// are logged, never swallowed, so the black box stays debuggable.

import Foundation
import Supabase
import UnstuckCore
import UnstuckData

public actor RealtimeMirror {
    private let client: SupabaseClient
    private let db: AppDatabase
    private var channels: [RealtimeChannelV2] = []
    private var streamTasks: [Task<Void, Never>] = []
    /// Observes the shared realtime socket status → hydrate on reconnect.
    private var socketStatusTask: Task<Void, Never>?

    // Context captured on subscribeAll so a self-heal can rebuild identically.
    private var currentUserId: String?
    private var onMembersChanged: (@Sendable () async -> Void)?
    /// Full-hydrate backfill, invoked on reconnect / after a channel rebuild.
    private var onResync: (@Sendable () async -> Void)?
    /// Coalesces a burst of channel drops into a single rebuild.
    private var healTask: Task<Void, Never>?
    /// Rate-limit heals so a channel that keeps closing (e.g. a persistent
    /// auth/RLS error) can't spin a tight rebuild loop; the socket-reconnect
    /// and 60s foreground hydrates remain as backstops in that window.
    private var lastHealAt = Date.distantPast
    /// Session boundary counter, bumped by every `subscribeAll` (sign-in) and
    /// `unsubscribeAll` (sign-out). A self-heal captures it and aborts if it
    /// moves across its awaits — so a sign-out that interleaves mid-rebuild
    /// can't have the heal re-hydrate the signed-out user's data (BUG 1). The
    /// internal `rebuildSubscriptions` deliberately does NOT bump it, so the
    /// heal's own teardown isn't mistaken for a session change.
    private var sessionGeneration = 0

    public init(client: SupabaseClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    private struct IdOnly: Decodable { let id: String }

    public func subscribeAll(userId: String,
                             onMembersChanged: @escaping @Sendable () async -> Void = {},
                             onResync: @escaping @Sendable () async -> Void = {}) async {
        // A fresh subscribe is a new session boundary — bump so any in-flight
        // self-heal from a prior session aborts instead of hydrating over the
        // new one (see performHeal / BUG-1 guard).
        sessionGeneration &+= 1
        await rebuildSubscriptions(userId: userId, onMembersChanged: onMembersChanged, onResync: onResync)
    }

    /// Tear down any existing subscriptions and (re)build the full set for
    /// `userId`. The shared body of the public `subscribeAll` (which bumps
    /// `sessionGeneration`) and the self-heal rebuild — it deliberately does
    /// NOT bump the generation, so a heal's own teardown isn't misread as a
    /// concurrent sign-out / user-switch.
    private func rebuildSubscriptions(userId: String,
                                      onMembersChanged: @escaping @Sendable () async -> Void,
                                      onResync: @escaping @Sendable () async -> Void) async {
        await teardown()
        currentUserId = userId
        self.onMembersChanged = onMembersChanged
        self.onResync = onResync
        await subscribeChannels(userId: userId, onMembersChanged: onMembersChanged)
        observeSocketStatus()
    }

    private func subscribeChannels(userId: String, onMembersChanged: @escaping @Sendable () async -> Void) async {
        // tasks carries `updated_at`, so guard incoming UPDATEs with last-write-
        // wins: an out-of-order remote echo (the server re-broadcasting an edit
        // we already superseded locally) must NOT clobber a newer local edit.
        // INSERTs always apply (creating a row we don't have); only UPDATEs are
        // gated. Other tables have no `updated_at` column, so they can't be
        // timestamp-guarded and keep the prior unconditional apply.
        // Consumer closures capture `db` directly (not `self`) so the long-lived
        // stream tasks don't strongly retain the actor.
        await subscribe("tasks", TaskRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(TaskItem.self, id: $0) },
                        shouldApplyUpdate: { [db] incoming in
                            Self.incomingTaskWins(incoming, db: db)
                        })
        await subscribe("sessions", SessionRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(Session.self, id: $0) })
        await subscribe("cal_blocks", CalBlockRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(CalBlock.self, id: $0) })
        await subscribe("captures", CaptureRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(Capture.self, id: $0) })
        await subscribe("reason_logs", ReasonLogRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(ReasonLog.self, id: $0) })
        // Collections: shared rows are owned by someone else, so subscribe
        // WITHOUT the user_id filter and rely on RLS for delivery (members get
        // the owner's edits). Preserve the client-only members/myRole across the
        // incoming row (it carries neither). Port of realtime.ts mergeKeep.
        await subscribe("collections", CollectionRow.self, userId: userId,
                        onUpsert: { [db] row in
                            let m = row.model()
                            let existing = try? db.fetchById(ItemCollection.self, id: m.id)
                            var merged = m
                            merged.members = existing?.members ?? []
                            merged.myRole = existing?.myRole ?? (m.ownerId == userId ? "owner" : nil)
                            try? db.save(merged)
                        },
                        onDelete: { [db] in try? db.deleteById(ItemCollection.self, id: $0) },
                        noUserFilter: true)
        await subscribe("tags", TagDbRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(TagRow.self, id: $0) })
        await subscribe("life_areas", LifeAreaDbRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(LifeArea.self, id: $0) })
        // Membership changes for ME — a new share or a revocation. Re-hydrate
        // collections so the freshly-shared list appears / the revoked one drops.
        await subscribeMembers(userId: userId, onChanged: onMembersChanged)
    }

    /// Last-write-wins guard for an incoming `tasks` UPDATE. Skip (return
    /// false) when the local row's `updated_at` parses to a STRICTLY newer
    /// instant than the incoming row's — i.e. a newer local edit would be
    /// clobbered by a stale remote echo. Compares parsed dates, not strings.
    /// Applies (returns true) when there's no local row, the local row has no
    /// usable timestamp, or the incoming is at-or-after the local one.
    static func incomingTaskWins(_ incoming: TaskRow, db: AppDatabase) -> Bool {
        guard let local = try? db.fetchById(TaskItem.self, id: incoming.id),
              let localMs = Time.parseMillis(local.updatedAt),
              let incomingMs = Time.parseMillis(incoming.updatedAt) else { return true }
        return incomingMs >= localMs
    }

    /// Exponential backoff (capped) for realtime subscribe retries. `attempt`
    /// is 1-based: the delay to wait AFTER the attempt-th failure before the
    /// next try. Doubles from 0.5s, capped at 8s. Pure → unit-tested.
    static func retryBackoffNs(attempt: Int) -> UInt64 {
        let base: UInt64 = 500_000_000   // 0.5s
        let cap: UInt64 = 8_000_000_000  // 8s
        let shift = min(max(attempt, 1) - 1, 20)
        return min(base << shift, cap)
    }

    private func subscribe<Row: Decodable & Sendable>(
        _ table: String,
        _ rowType: Row.Type,
        userId: String,
        onUpsert: @escaping @Sendable (Row) -> Void,
        onDelete: @escaping @Sendable (String) -> Void,
        noUserFilter: Bool = false,
        shouldApplyUpdate: @escaping @Sendable (Row) -> Bool = { _ in true }
    ) async {
        let channel = client.channel("unstuck_\(table)_\(userId)")
        let filter: RealtimePostgresFilter? = noUserFilter ? nil : .eq("user_id", value: userId)
        // Build streams BEFORE subscribing so no early events are missed.
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: table, filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: table, filter: filter)
        let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: table, filter: filter)
        channels.append(channel)
        // Start the consumers UNCONDITIONALLY (was: only after a successful
        // subscribe). The channel is already registered with the client, so a
        // first subscribe that fails but later succeeds — via our retry or the
        // SDK's own reconnect re-join — must find live listeners waiting, not a
        // dead channel. Decode failures are LOGGED, never silently dropped.
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in inserts {
                do { onUpsert(try change.decodeRecord(as: Row.self, decoder: dec)) }
                catch { print("[realtime] \(table) INSERT decode failed: \(error)") }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in updates {
                do {
                    let row = try change.decodeRecord(as: Row.self, decoder: dec)
                    if shouldApplyUpdate(row) { onUpsert(row) }
                } catch { print("[realtime] \(table) UPDATE decode failed: \(error)") }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in deletes {
                do { onDelete(try change.decodeOldRecord(as: IdOnly.self, decoder: dec).id) }
                catch { print("[realtime] \(table) DELETE decode failed: \(error)") }
            }
        })
        streamTasks.append(channelStatusObserver(channel, table: table))
        // Subscribe with bounded backoff, off the subscribeAll path so a slow /
        // retrying network subscribe doesn't stall sign-in.
        streamTasks.append(Task { await Self.subscribeWithRetry(channel, table: table) })
    }

    /// collection_members for ME (filtered user_id=eq). Any insert/update/delete
    /// → re-hydrate collections via [onChanged] (RLS decides which rows return).
    /// Doesn't mirror rows itself — membership lives in the collection's
    /// members[]/myRole, refreshed by the hydrate.
    private func subscribeMembers(userId: String, onChanged: @escaping @Sendable () async -> Void) async {
        let channel = client.channel("unstuck_collection_members_\(userId)")
        let filter = RealtimePostgresFilter.eq("user_id", value: userId)
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "collection_members", filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: "collection_members", filter: filter)
        let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "collection_members", filter: filter)
        channels.append(channel)
        streamTasks.append(Task { for await _ in inserts { await onChanged() } })
        streamTasks.append(Task { for await _ in updates { await onChanged() } })
        streamTasks.append(Task { for await _ in deletes { await onChanged() } })
        streamTasks.append(channelStatusObserver(channel, table: "collection_members"))
        streamTasks.append(Task { await Self.subscribeWithRetry(channel, table: "collection_members") })
    }

    /// Subscribe a channel, retrying on failure with capped exponential
    /// backoff. A single throw used to kill the channel for the whole session;
    /// now we retry, and the SDK's own reconnect re-join + our hydrate backstops
    /// cover anything past the final attempt.
    private static func subscribeWithRetry(_ channel: RealtimeChannelV2, table: String, maxAttempts: Int = 5) async {
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }
            do {
                try await channel.subscribeWithError()
                if attempt > 1 { print("[realtime] subscribed \(table) on attempt \(attempt)") }
                return
            } catch {
                print("[realtime] subscribe \(table) failed (attempt \(attempt)/\(maxAttempts)): \(error)")
                if attempt == maxAttempts { break }
                try? await Task.sleep(nanoseconds: retryBackoffNs(attempt: attempt))
            }
        }
        print("[realtime] subscribe \(table) exhausted retries — SDK re-join + hydrate remain as backstops")
    }

    /// Log a channel's status transitions (observability) and self-heal on an
    /// UNEXPECTED close. A WebSocket-level drop leaves channel status untouched
    /// (the SDK re-joins on reconnect); only a server-side `phx_close` / error
    /// drives `.unsubscribed`, and that also removes the channel from the client
    /// — so it will NOT auto-rejoin. There we rebuild + hydrate. Our own
    /// teardown cancels this task before removeChannel, so `Task.isCancelled`
    /// distinguishes a real drop from an intentional unsubscribe.
    private func channelStatusObserver(_ channel: RealtimeChannelV2, table: String) -> Task<Void, Never> {
        Task { [weak self] in
            var wasSubscribed = false
            for await status in channel.statusChange {
                if Task.isCancelled { return }
                print("[realtime] channel \(table) status: \(String(describing: status))")
                switch status {
                case .subscribed:
                    wasSubscribed = true
                case .unsubscribed:
                    if wasSubscribed {
                        wasSubscribed = false
                        await self?.scheduleHeal(reason: "\(table) channel closed")
                    }
                case .subscribing, .unsubscribing:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    /// Watch the shared realtime socket. On a RE-connect (a `.connected` after
    /// we've already been connected once — the SDK re-joins channels itself),
    /// run the full hydrate to backfill events missed while the socket was down.
    private func observeSocketStatus() {
        let realtime = client.realtimeV2
        socketStatusTask = Task { [weak self] in
            var everConnected = false
            for await status in realtime.statusChange {
                if Task.isCancelled { return }
                print("[realtime] socket status: \(status)")
                switch status {
                case .connected:
                    if everConnected { await self?.onSocketReconnected() }
                    everConnected = true
                case .disconnected, .connecting:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func onSocketReconnected() async {
        print("[realtime] socket reconnected — backfilling via hydrate")
        await (onResync ?? {})()
    }

    /// Coalesced, rate-limited self-heal: rebuild every subscription and
    /// hydrate. Guarded on the still-current user so a heal queued before a
    /// sign-out / user-switch is a no-op.
    private func scheduleHeal(reason: String) {
        guard let uid = currentUserId else { return }
        // Rate-limit against the last heal that actually RAN (see performHeal),
        // NOT schedule time: a scheduled-then-cancelled heal must not advance
        // the clock and suppress a later, legitimately-needed heal (BUG 3).
        guard Date().timeIntervalSince(lastHealAt) >= 5 else { return }   // rate-limit tight loops
        let gen = sessionGeneration
        healTask?.cancel()
        healTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)   // coalesce a burst of drops
            guard let self, !Task.isCancelled else { return }
            await self.performHeal(userId: uid, generation: gen, reason: reason)
        }
    }

    private func performHeal(userId uid: String, generation gen: Int, reason: String) async {
        // Abort if the session moved between scheduling and now (a sign-out /
        // user-switch bumps sessionGeneration and nils currentUserId).
        guard sessionGeneration == gen, currentUserId == uid else { return }
        lastHealAt = Date()   // rate-limit stamps when the heal RUNS, not at schedule (BUG 3)
        healTask = nil        // detach so the rebuild's teardown won't cancel us
        let members = onMembersChanged ?? {}
        let resync = onResync ?? {}
        print("[realtime] self-heal (\(reason)) — rebuilding subscriptions + hydrate")
        await rebuildSubscriptions(userId: uid, onMembersChanged: members, onResync: resync)
        // Re-validate AFTER the rebuild, BEFORE the hydrate (BUG 1): a sign-out
        // can interleave at the teardown's `removeChannel` awaits — wiping the
        // cache and nilling the user. Because rebuildSubscriptions re-sets
        // currentUserId = uid, ONLY the generation reliably reveals that
        // interleave, so gate the resync on it. If it moved, drop the channels
        // we just (wrongly) rebuilt rather than re-hydrating the signed-out
        // user's data over a just-cleared cache.
        guard sessionGeneration == gen, currentUserId == uid else {
            print("[realtime] self-heal aborted — session changed mid-rebuild")
            await teardown()
            return
        }
        await resync()
    }

    public func unsubscribeAll() async {
        // A sign-out / external teardown is a session boundary — bump so an
        // in-flight self-heal aborts instead of resurrecting this session.
        sessionGeneration &+= 1
        await teardown()
    }

    /// Cancel every task, remove every channel, and clear the captured context.
    /// Does NOT bump `sessionGeneration` — the public `subscribeAll` /
    /// `unsubscribeAll` own that, so the self-heal rebuild can reuse this body
    /// without its own teardown looking like a session change.
    private func teardown() async {
        healTask?.cancel()
        healTask = nil
        socketStatusTask?.cancel()
        socketStatusTask = nil
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        for ch in channels { await client.removeChannel(ch) }
        channels.removeAll()
        currentUserId = nil
        onMembersChanged = nil
        onResync = nil
    }
}
