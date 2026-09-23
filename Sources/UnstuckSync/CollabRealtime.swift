// CollabRealtime — live cross-user signal for sharing, the iOS port of the
// web's lib/collab-realtime.ts. The main RealtimeMirror mirrors your OWN rows
// into GRDB; the sharing surfaces are RPC-backed (level-scoped projections)
// that recipients CANNOT read as raw table rows (RLS), so realtime here is only
// a CHANGE SIGNAL — never a table mirror. It subscribes to task_shares +
// trusted_circle postgres_changes (RLS scopes each subscriber to the rows it
// can see: their outgoing + incoming) and posts a NotificationCenter signal the
// UI layer observes to REFETCH via CircleClient's RPCs.
//
// One channel (unstuck_collab_<uid>); idempotent start/stop, mirroring the
// web's singleton ensureCollabRealtime().
//
// It used to be subscribed once at sign-in and never again: a first subscribe
// that failed (an offline launch) just returned, and after any socket drop the
// channel kept reading `.subscribed` while the SDK's rejoin no-opped on it — so
// shares, revokes and "they joined" stopped arriving for the rest of the
// process. It now rebuilds on a reconnect and whenever the freshness owner's
// triggers find it not live (`ensureLive`, RealtimeHealPolicy — audit
// 2026-09-22, C30).

import Foundation
import Supabase

public extension Notification.Name {
    /// task_shares changed (a share added/updated/revoked, incoming or outgoing)
    /// → refetch tasks_shared_with_me / task_shares_for_task / badges.
    /// Mirrors web SHARES_CHANGED.
    static let unstuckCollabSharesChanged = Notification.Name("unstuck.collab.sharesChanged")
    /// trusted_circle changed (a member joined/left/was removed) → refetch the
    /// roster. Mirrors web CIRCLE_CHANGED.
    static let unstuckCollabCircleChanged = Notification.Name("unstuck.collab.circleChanged")
    /// A trusted_circle row I can see went ACTIVE (someone accepted my invite,
    /// claimed it at sign-up, or a share connected us) — the sender-side
    /// "they joined" moment (unified sharing v1). Posted IN ADDITION to
    /// circleChanged; the People roster and an open Share screen refresh.
    static let unstuckCollabConnectionActivated = Notification.Name("unstuck.collab.connectionActivated")
}

public actor CollabRealtime {
    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var streamTasks: [Task<Void, Never>] = []
    /// The user the channel is for; nil once stopped.
    private var userId: String?
    /// Bumped by start / stop: a rebuild that straddles one gives up.
    private var generation = 0
    private var socketTask: Task<Void, Never>?
    /// The socket went down after the channel joined (C30).
    private var droppedSinceJoin = false
    /// The generation a start / rebuild is joining for: `ensureLive` stays out
    /// meanwhile, so a join in flight is never dropped mid-subscribe (its SDK
    /// retries would keep calling connect() beside ours).
    private var joiningFor: Int?
    private var healPolicy = RealtimeHealPolicy()

    public init(client: SupabaseClient) { self.client = client }

    /// Subscribe to task_shares + trusted_circle changes for the current user.
    /// No user_id filter: neither table keys on user_id (owner_id /
    /// invitee_user_id / shared_with_user_id), so we rely on RLS to scope
    /// delivery — exactly as the web does. Idempotent.
    public func start(userId: String) async {
        await stop()
        self.userId = userId
        let gen = generation
        joiningFor = gen
        await join(userId: userId, generation: gen)
        guard gen == generation else { return }
        joiningFor = nil
        observeSocket()
    }

    /// Bring the channel back when it can't be delivering (socket down, the
    /// subscribe gave up, or the socket dropped since it joined), with
    /// RealtimeHealPolicy's back-off. A no-op when healthy or stopped (audit
    /// 2026-09-22, C30).
    public func ensureLive(networkRegained: Bool = false) async {
        guard let uid = userId, joiningFor != generation else { return }
        if networkRegained { healPolicy.resetBackoff() }
        guard RealtimeHealPolicy.needsRebuild(socket: client.realtimeV2.status,
                                              channels: channel.map { [$0.status] } ?? [],
                                              droppedSinceJoin: droppedSinceJoin) else { return }
        let now = Date()
        guard healPolicy.mayHeal(now: now) else { return }
        healPolicy.recordHeal(now: now)
        let gen = generation
        joiningFor = gen
        defer { if joiningFor == gen { joiningFor = nil } }
        await dropChannel()
        guard gen == generation else { return }
        droppedSinceJoin = false
        // Never a second connect() on an open or opening socket (it silences
        // it — RealtimeHealPolicy.connectIfNeeded); no socket, no join.
        let connected = await RealtimeHealPolicy.connectIfNeeded(client.realtimeV2)
        guard gen == generation, connected else { return }
        await join(userId: uid, generation: gen)
    }

    /// Watch the shared socket: a drop marks the channel stale, and every
    /// `.connected` asks `ensureLive` (a no-op when nothing is wrong).
    private func observeSocket() {
        socketTask?.cancel()
        let realtime = client.realtimeV2
        socketTask = Task { [weak self] in
            var everConnected = false
            for await status in realtime.statusChange {
                if Task.isCancelled { return }
                switch status {
                case .connected:
                    everConnected = true
                    await self?.ensureLive()
                case .disconnected, .connecting:
                    if everConnected { await self?.noteSocketDropped() }
                @unknown default:
                    break
                }
            }
        }
    }

    private func noteSocketDropped() {
        droppedSinceJoin = true
    }

    private func noteLive() {
        healPolicy.recordLive()
    }

    /// The rebuild policy's state (tests).
    var healPolicyForTesting: RealtimeHealPolicy { healPolicy }

    /// Build the channel and subscribe it. The channel and its consumers are
    /// kept even when the subscribe fails: `ensureLive` replaces them.
    private func join(userId: String, generation gen: Int) async {
        let ch = client.channel("unstuck_collab_\(userId)")
        // Build the streams BEFORE subscribing so no early events are missed.
        let shareInserts = ch.postgresChange(InsertAction.self, schema: "public", table: "task_shares")
        let shareUpdates = ch.postgresChange(UpdateAction.self, schema: "public", table: "task_shares")
        let shareDeletes = ch.postgresChange(DeleteAction.self, schema: "public", table: "task_shares")
        let circleInserts = ch.postgresChange(InsertAction.self, schema: "public", table: "trusted_circle")
        let circleUpdates = ch.postgresChange(UpdateAction.self, schema: "public", table: "trusted_circle")
        let circleDeletes = ch.postgresChange(DeleteAction.self, schema: "public", table: "trusted_circle")
        channel = ch
        streamTasks.append(Task { [weak self] in
            for await status in ch.statusChange where status == .subscribed { await self?.noteLive() }
        })
        streamTasks.append(Task { for await _ in shareInserts { await Self.emitShares() } })
        streamTasks.append(Task { for await _ in shareUpdates { await Self.emitShares() } })
        streamTasks.append(Task { for await _ in shareDeletes { await Self.emitShares() } })
        streamTasks.append(Task {
            for await ins in circleInserts {
                // A row born active = the server connected us in one step
                // (circle-invite existing-user branch, ensure_connection).
                if Self.circleRowWentActive(old: [:], new: ins.record) { await Self.emitConnectionActivated() }
                await Self.emitCircle()
            }
        })
        streamTasks.append(Task {
            for await upd in circleUpdates {
                if Self.circleRowWentActive(old: upd.oldRecord, new: upd.record) { await Self.emitConnectionActivated() }
                await Self.emitCircle()
            }
        })
        streamTasks.append(Task { for await _ in circleDeletes { await Self.emitCircle() } })
        do {
            try await ch.subscribeWithError()
        } catch {
            print("[collab-realtime] subscribe failed (ensureLive retries): \(error)")
        }
        // A stop() / start() landed while we waited: this join is not ours to keep.
        if gen != generation, ch.status == .subscribed { await ch.unsubscribe() }
    }

    /// Pure: did this change flip a trusted_circle row to `active`? The old
    /// record only carries the columns replica identity projects (the PK
    /// alone by default), so "old status unknown" counts as a flip — an
    /// extra refresh is harmless; a missed join is not.
    static func circleRowWentActive(old: [String: AnyJSON], new: [String: AnyJSON]) -> Bool {
        guard new["status"]?.stringValue == "active" else { return false }
        return old["status"]?.stringValue != "active"
    }

    public func stop() async {
        generation &+= 1
        userId = nil
        socketTask?.cancel()
        socketTask = nil
        droppedSinceJoin = false
        healPolicy = RealtimeHealPolicy()
        await dropChannel()
    }

    private func dropChannel() async {
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        let old = channel
        channel = nil
        if let old { await client.removeChannel(old) }
    }

    // Post on the main actor so SwiftUI observers can update state directly.
    @MainActor private static func emitShares() {
        NotificationCenter.default.post(name: .unstuckCollabSharesChanged, object: nil)
    }
    @MainActor private static func emitCircle() {
        NotificationCenter.default.post(name: .unstuckCollabCircleChanged, object: nil)
    }
    @MainActor private static func emitConnectionActivated() {
        NotificationCenter.default.post(name: .unstuckCollabConnectionActivated, object: nil)
    }
}
