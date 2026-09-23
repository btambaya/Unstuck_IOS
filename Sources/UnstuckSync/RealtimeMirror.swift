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
//
// Those three never covered two shapes (audit 2026-09-22, C30): an OFFLINE
// launch (every subscribe exhausts its retries, nothing reconnects the socket,
// and 2 needs a socket that was once connected) and a socket that dropped and
// came back (the SDK's rejoin no-ops on a channel still reading `.subscribed`
// from before the drop). `ensureLive` — asked by the freshness owner on network
// back / foreground / the floor tick — and a rebuild on every reconnect close
// them; RealtimeHealPolicy holds the rules. Rebuilds are serialised, so two can
// never register the same topic twice.

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
    /// The last rebuild queued. Each rebuild waits for the one before it: two
    /// interleaving at their awaits would each register every topic, and
    /// `client.channel` hands the second the first's instance — every event
    /// applied twice (audit 2026-09-22, C30).
    private var rebuildTail: Task<Void, Never>?
    /// Rebuilds queued or running; `ensureLive` leaves the set alone meanwhile.
    private var rebuildsInFlight = 0
    /// The socket went down after the channels joined: they still read
    /// `.subscribed` but are dead on the new socket (C30).
    private var droppedSinceJoin = false
    /// When `ensureLive` may rebuild again (C30).
    private var healPolicy = RealtimeHealPolicy()
    /// Channels whose subscribe is still running (`startJoin`): they read
    /// `.unsubscribed` without having given up (C30).
    private var joining: Set<ObjectIdentifier> = []

    // MARK: - reporting into the freshness owner
    //
    // The mirror no longer decides anything about staleness: it REPORTS. Every
    // delivered row, every (re)subscribe and every socket connect goes to the
    // one component that owns "am I in step?" (FreshnessOwner), which is the
    // only thing allowed to schedule a pull. `onResync` is kept as the seam the
    // coordinator points at that owner.

    /// Any postgres_changes row of any kind arrived — the liveness evidence the
    /// deafness detector reads. Channel status is never trusted for this.
    private var onRealtimeEvent: (@Sendable () -> Void)?
    /// A channel reached `.subscribed`: a (re)join means everything written
    /// during the gap was never broadcast to us.
    private var onChannelsSubscribed: (@Sendable () -> Void)?
    /// An account-wide preference row changed (notification_preferences /
    /// user_preferences — both in the publication since migration 063).
    private var onPreferencesChanged: (@Sendable () -> Void)?

    /// Rule G's gate (stage 2): a cal_blocks row arriving from the server
    /// releases a confirmed mint's Google push that was waiting for it.
    private let mirrorGate: InsertMirrorGate?

    public init(client: SupabaseClient, db: AppDatabase, mirrorGate: InsertMirrorGate? = nil) {
        self.client = client
        self.db = db
        self.mirrorGate = mirrorGate
    }

    /// Wire the mirror's reports into the freshness owner. Set once, before
    /// `subscribeAll`; survives self-heal rebuilds.
    public func setSignals(onRealtimeEvent: @escaping @Sendable () -> Void,
                           onChannelsSubscribed: @escaping @Sendable () -> Void,
                           onPreferencesChanged: @escaping @Sendable () -> Void) {
        self.onRealtimeEvent = onRealtimeEvent
        self.onChannelsSubscribed = onChannelsSubscribed
        self.onPreferencesChanged = onPreferencesChanged
    }

    private struct IdOnly: Decodable { let id: String }

    public func subscribeAll(userId: String,
                             onMembersChanged: @escaping @Sendable () async -> Void = {},
                             onResync: @escaping @Sendable () async -> Void = {}) async {
        // A fresh subscribe is a new session boundary — bump so any in-flight
        // self-heal from a prior session aborts instead of hydrating over the
        // new one (see performHeal / BUG-1 guard).
        sessionGeneration &+= 1
        healPolicy = RealtimeHealPolicy()
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
        let previous = rebuildTail
        let generation = sessionGeneration
        rebuildsInFlight += 1
        let rebuild = Task { [weak self] in
            await previous?.value
            await self?.performRebuild(userId: userId, generation: generation,
                                       onMembersChanged: onMembersChanged, onResync: onResync)
        }
        rebuildTail = rebuild
        await rebuild.value
        rebuildsInFlight -= 1
    }

    private func performRebuild(userId: String, generation: Int,
                                onMembersChanged: @escaping @Sendable () async -> Void,
                                onResync: @escaping @Sendable () async -> Void) async {
        // A sign-out / user switch since this rebuild was queued owns the set
        // now; checked again after every await below (C30).
        guard generation == sessionGeneration else { return }
        await teardown()
        guard generation == sessionGeneration else { return }
        currentUserId = userId
        self.onMembersChanged = onMembersChanged
        self.onResync = onResync
        droppedSinceJoin = false
        // Open the socket ONCE, and wait for it, before any channel subscribes.
        // subscribeChannels fans ~11 subscribes out into detached Tasks; each one
        // lazily calls connect(), and on supabase-swift 2.46 those parallel
        // connects overwrite the socket's single message handler — every phx_join
        // goes out and no reply is ever read, so the mirror reported no error and
        // received nothing, ever. iOS live sync has never worked because of this;
        // only the foreground pull brought remote changes in. CoFocusPresenceClient
        // already does exactly this (CoFocusPresenceClient.swift:713).
        // Diagnosis 2026-09-12.
        // Never re-open a socket that is up or opening (connectIfNeeded): a
        // second connect() silences the socket, and this now runs on every
        // reconnect. With no socket there are no joins either — each subscribe
        // would call connect() itself, racing — and ensureLive rebuilds once
        // one can open (audit 2026-09-22, C30).
        let connected = await RealtimeHealPolicy.connectIfNeeded(client.realtimeV2)
        guard generation == sessionGeneration else { return }
        if connected {
            await subscribeChannels(userId: userId, onMembersChanged: onMembersChanged)
        } else {
            print("[realtime] socket not open — channels wait for ensureLive")
        }
        observeSocketStatus(joinedOpen: connected)
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
                        onUpsert: { [db, mirrorGate] row in
                            try? db.save(row.model())
                            mirrorGate?.rowLanded(rowId: row.id)
                        },
                        onDelete: { [db] in try? db.deleteById(CalBlock.self, id: $0) })
        // captures carry their Inbox archive state (`archived_at`, migration
        // 053) — an archive made on the web must move the row out of this
        // device's open Inbox too, so the local archive table follows the row.
        await subscribe("captures", CaptureRow.self, userId: userId,
                        onUpsert: { [db] row in
                            try? db.save(row.model())
                            try? db.setCaptureArchived(id: row.id, archivedAt: row.archivedAt)
                        },
                        onDelete: { [db] in
                            try? db.deleteById(Capture.self, id: $0)
                            try? db.setCaptureArchived(id: $0, archivedAt: nil)
                        })
        await subscribe("reason_logs", ReasonLogRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(ReasonLog.self, id: $0) })
        // profile_facts: a "forget" on another device arrives as an UPDATE to
        // active=false — saved as a local tombstone, which every read filters
        // out. Same updated_at last-write-wins guard as tasks so a stale echo
        // can't clobber a newer local save.
        await subscribe("profile_facts", ProfileFactRow.self, userId: userId,
                        onUpsert: { [db] in try? db.save($0.model()) },
                        onDelete: { [db] in try? db.deleteById(ProfileFact.self, id: $0) },
                        shouldApplyUpdate: { [db] incoming in
                            Self.incomingProfileFactWins(incoming, db: db)
                        })
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
        // call_requests (migration 051: published, replica identity full): a
        // booking from the web / the assistant, the dispatcher flipping a row
        // to `calling`, call-outcome settling it — all reach the mirror live.
        // LWW on `updated_at`; the cursor catch-up is the correctness path.
        await subscribe("call_requests", CallRequest.self, userId: userId,
                        onUpsert: { [db] row in try? CallRequestsMirror(db).upsert(row) },
                        onDelete: { [db] in try? db.deleteById(CallRequest.self, id: $0) })
        // Membership changes for ME (a new share or a revocation) AND on lists
        // I OWN (someone joined or left). Re-hydrate collections so the
        // freshly-shared list appears / the revoked one drops, and the owner's
        // members[] (what routes item edits through the RPCs) stays current.
        await subscribeMembers(userId: userId, onChanged: onMembersChanged)
        await subscribePreferences(userId: userId)
    }

    /// Last-write-wins guard for an incoming `tasks` UPDATE. Skip (return
    /// false) when the local row's `updated_at` parses to a STRICTLY newer
    /// instant than the incoming row's — i.e. a newer local edit would be
    /// clobbered by a stale remote echo. Compares parsed dates, not strings.
    /// Applies (returns true) when there's no local row, the local row has no
    /// usable timestamp, or the incoming is at-or-after the local one.
    ///
    /// Base-aware: while a queued upsert for the row exists, an incoming row
    /// stamped at-or-before the op's `baseUpdatedAt` is the SERVER STATE THE
    /// EDIT WAS MADE ON (a late echo) — it must not overwrite the pending
    /// local edit even when a slow device clock stamped that edit "earlier".
    static func incomingTaskWins(_ incoming: TaskRow, db: AppDatabase) -> Bool {
        guard let incomingMs = Time.parseMillis(incoming.updatedAt) else { return true }
        let pendingBases = ((try? OutboxStore(db).pending()) ?? [])
            .filter { $0.tableName == "tasks" && $0.kind == .upsert && $0.rowId == incoming.id }
            .compactMap { $0.baseUpdatedAt.flatMap(Time.parseMillis) }
        if let base = pendingBases.max(), incomingMs <= base + 1 { return false }
        guard let local = try? db.fetchById(TaskItem.self, id: incoming.id),
              let localMs = Time.parseMillis(local.updatedAt) else { return true }
        return incomingMs >= localMs
    }

    /// The same last-write-wins guard for an incoming `profile_facts` UPDATE
    /// (a tombstone from another device included).
    static func incomingProfileFactWins(_ incoming: ProfileFactRow, db: AppDatabase) -> Bool {
        guard let local = try? db.fetchById(ProfileFact.self, id: incoming.id),
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
        let report = onRealtimeEvent ?? {}
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
                report()   // liveness: the channel IS delivering
                do { onUpsert(try change.decodeRecord(as: Row.self, decoder: dec)) }
                catch { print("[realtime] \(table) INSERT decode failed: \(error)") }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in updates {
                report()
                do {
                    let row = try change.decodeRecord(as: Row.self, decoder: dec)
                    if shouldApplyUpdate(row) { onUpsert(row) }
                } catch { print("[realtime] \(table) UPDATE decode failed: \(error)") }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in deletes {
                report()
                do { onDelete(try change.decodeOldRecord(as: IdOnly.self, decoder: dec).id) }
                catch { print("[realtime] \(table) DELETE decode failed: \(error)") }
            }
        })
        streamTasks.append(channelStatusObserver(channel, table: table))
        // Subscribe with bounded backoff, off the subscribeAll path so a slow /
        // retrying network subscribe doesn't stall sign-in.
        startJoin(channel, table: table)
    }

    /// collection_members, UNFILTERED — RLS ("member or owner") decides
    /// delivery, so rows for me AND rows on lists I own arrive. Any
    /// insert/update/delete → re-hydrate collections via [onChanged]. Doesn't
    /// mirror rows itself — membership lives in the collection's
    /// members[]/myRole, refreshed by the hydrate.
    /// It was filtered to user_id = me, so the owner never heard a join by
    /// link, an invite claimed at sign-up, a share made on another device or a
    /// member leaving: its list kept `members == []`, read as unshared, and its
    /// item edits went out as whole-row upserts over the members' RPC edits
    /// (audit 2026-09-22, C8; web realtime.ts / Android RealtimeMirror parity).
    /// Cost: Realtime can't RLS-check a DELETE, so every membership delete
    /// anywhere reaches this channel; a burst costs at most two
    /// hydrateCollections (`coalescedSignal`).
    private func subscribeMembers(userId: String, onChanged: @escaping @Sendable () async -> Void) async {
        let report = onRealtimeEvent ?? {}
        await subscribeSignal(table: "collection_members", userId: userId) {
            report()
            await onChanged()
        }
    }

    /// Account-wide PREFERENCE rows. They are keyed by `user_id` and live
    /// outside the local store, so nothing is mirrored — the event is a signal
    /// to re-read them. Migration 063 put both tables in `supabase_realtime`
    /// and set replica identity FULL, so a notification level / lead time /
    /// timezone / display name / ritual / assistant-interview change made on
    /// one device now reaches the others without a relaunch. `sharing_
    /// preferences` is deliberately NOT subscribed: iOS reads no column of it.
    private func subscribePreferences(userId: String) async {
        let report = onRealtimeEvent ?? {}
        let changed = onPreferencesChanged ?? {}
        for table in ["notification_preferences", "user_preferences"] {
            await subscribeSignal(table: table, userId: userId) {
                report()
                changed()
            }
        }
    }

    /// Signal tables subscribed WITHOUT the user_id filter (RLS decides who
    /// hears a row). The preference tables are singleton rows per user and
    /// keep theirs.
    static let unfilteredSignalTables: Set<String> = ["collection_members"]

    /// A signal-only channel: any INSERT/UPDATE/DELETE for this user (or, for
    /// `unfilteredSignalTables`, any row RLS delivers) runs `onChanged`.
    /// Nothing is mirrored into the local store.
    private func subscribeSignal(table: String, userId: String,
                                 onChanged: @escaping @Sendable () async -> Void) async {
        let channel = client.channel("unstuck_\(table)_\(userId)")
        let filter: RealtimePostgresFilter? = Self.unfilteredSignalTables.contains(table)
            ? nil : .eq("user_id", value: userId)
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: table, filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: table, filter: filter)
        let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: table, filter: filter)
        channels.append(channel)
        // Each stream used to await `onChanged` once per event, so N buffered
        // collection_members deletes (a list deleted with N members, an
        // account deletion's cascade; the channel is unfiltered now) ran N
        // back-to-back collections hydrates. One consumer for all three
        // streams, and whatever lands while it runs is one trailing run
        // (audit 2026-09-22, C8).
        let (signal, consumer) = Self.coalescedSignal(onChanged)
        streamTasks.append(consumer)
        streamTasks.append(Task { for await _ in inserts { signal() } })
        streamTasks.append(Task { for await _ in updates { signal() } })
        streamTasks.append(Task { for await _ in deletes { signal() } })
        streamTasks.append(channelStatusObserver(channel, table: table))
        startJoin(channel, table: table)
    }

    /// Subscribe `channel` (subscribeWithRetry) in its own task, marked as
    /// joining until that returns: until then `.unsubscribed` means "not yet",
    /// and `ensureLive` must not rebuild the set over it (audit 2026-09-22, C30).
    private func startJoin(_ channel: RealtimeChannelV2, table: String) {
        let id = ObjectIdentifier(channel)
        joining.insert(id)
        streamTasks.append(Task { [weak self] in
            await Self.subscribeWithRetry(channel, table: table)
            await self?.joinSettled(id)
        })
    }

    private func joinSettled(_ id: ObjectIdentifier) {
        joining.remove(id)
    }

    /// `signal()` never waits. `onChanged` runs once for every signal that
    /// arrived before that run started: a burst costs one run plus at most
    /// one trailing run. Cancelling `consumer` stops it.
    static func coalescedSignal(_ onChanged: @escaping @Sendable () async -> Void)
        -> (signal: @Sendable () -> Void, consumer: Task<Void, Never>) {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { for await _ in signals { await onChanged() } }
        return ({ continuation.yield() }, consumer)
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
                    // A (re)join is a gap: nothing written while we were away
                    // was broadcast. Report it — the freshness owner decides
                    // whether to pull, and coalesces the ~11 channels' reports
                    // into one.
                    await self?.reportSubscribed()
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
    /// we've already been connected once) rebuild the channels and backfill
    /// the events missed while the socket was down. The SDK's own rejoin is
    /// not enough: a drop leaves each channel reading `.subscribed`, and its
    /// rejoin no-ops on that — the channels stayed deaf until the silence rule
    /// fired, minutes later (audit 2026-09-22, C30). A first `.connected` for
    /// a set built without a socket (an offline launch) asks `ensureLive`.
    private func observeSocketStatus(joinedOpen: Bool) {
        let realtime = client.realtimeV2
        socketStatusTask = Task { [weak self] in
            // The stream replays the current status first; the watch reads it
            // against how the set was joined, so a rebuild's own listener
            // doesn't ask for another rebuild (SocketWatch, C30).
            var watch = SocketWatch(joinedOpen: joinedOpen)
            for await status in realtime.statusChange {
                if Task.isCancelled { return }
                print("[realtime] socket status: \(status)")
                switch watch.see(status) {
                case .reconnected: await self?.onSocketReconnected()
                case .firstConnected: await self?.ensureLive()
                case .dropped: await self?.noteSocketDropped()
                case .none: break
                }
            }
        }
    }

    private func noteSocketDropped() {
        droppedSinceJoin = true
    }

    private func onSocketReconnected() async {
        print("[realtime] socket reconnected — rebuilding the channels and reporting the gap")
        scheduleHeal(reason: "socket reconnected")
    }

    private func reportSubscribed() {
        if RealtimeHealPolicy.isLive(channels.map(\.status)) { healPolicy.recordLive() }
        onChannelsSubscribed?()
    }

    /// Rebuild the channels when they can't be delivering — the socket is
    /// down or parked, a channel gave up (an offline launch exhausts every
    /// subscribe's retries), or the socket dropped since they joined — with
    /// RealtimeHealPolicy's back-off between rebuilds that don't bring them
    /// live. Asked by the freshness owner on network back / foreground / the
    /// floor tick; a no-op for a healthy set, while signed out, and while a
    /// rebuild is already queued. No pull of its own: the channels reaching
    /// `.subscribed` report the gap (audit 2026-09-22, C30).
    public func ensureLive(networkRegained: Bool = false) async {
        guard let uid = currentUserId, rebuildsInFlight == 0 else { return }
        if networkRegained { healPolicy.resetBackoff() }
        let statuses = channels.map {
            RealtimeHealPolicy.effectiveStatus($0.status, joining: joining.contains(ObjectIdentifier($0)))
        }
        guard RealtimeHealPolicy.needsRebuild(socket: client.realtimeV2.status, channels: statuses,
                                              droppedSinceJoin: droppedSinceJoin) else { return }
        let now = Date()
        guard healPolicy.mayHeal(now: now) else { return }
        healPolicy.recordHeal(now: now)
        print("[realtime] channels not live (socket \(client.realtimeV2.status)) — rebuilding (attempt \(healPolicy.failedHeals))")
        let members = onMembersChanged ?? {}
        let resync = onResync ?? {}
        await rebuildSubscriptions(userId: uid, onMembersChanged: members, onResync: resync)
    }

    /// The last rebuild's policy state (tests).
    var healPolicyForTesting: RealtimeHealPolicy { healPolicy }

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

    /// The freshness owner's deafness verdict (silence, or a catch-up that
    /// found a change realtime never delivered): tear the subscriptions down
    /// and rejoin. Deliberately does NOT run the resync itself — the owner is
    /// already pulling, and a rebuild that re-triggers a pull would loop.
    public func rebuildSubscriptionsNow() async {
        guard let uid = currentUserId else { return }
        let members = onMembersChanged ?? {}
        let resync = onResync ?? {}
        lastHealAt = Date()
        healTask?.cancel()
        healTask = nil
        await rebuildSubscriptions(userId: uid, onMembersChanged: members, onResync: resync)
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
        // All at once: removing a channel that went stale in a socket drop
        // waits the SDK's 10 s for a close the new socket never sends, so one
        // at a time held a reconnect heal for ~2 minutes (audit 2026-09-22, C30).
        let doomed = channels
        channels.removeAll()
        joining.removeAll()
        let client = self.client
        await withTaskGroup(of: Void.self) { group in
            for ch in doomed { group.addTask { await client.removeChannel(ch) } }
        }
        currentUserId = nil
        onMembersChanged = nil
        onResync = nil
    }
}
