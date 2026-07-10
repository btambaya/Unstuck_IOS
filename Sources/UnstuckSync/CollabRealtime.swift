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
}

public actor CollabRealtime {
    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var streamTasks: [Task<Void, Never>] = []

    public init(client: SupabaseClient) { self.client = client }

    /// Subscribe to task_shares + trusted_circle changes for the current user.
    /// No user_id filter: neither table keys on user_id (owner_id /
    /// invitee_user_id / shared_with_user_id), so we rely on RLS to scope
    /// delivery — exactly as the web does. Idempotent.
    public func start(userId: String) async {
        await stop()
        let ch = client.channel("unstuck_collab_\(userId)")
        // Build the streams BEFORE subscribing so no early events are missed.
        let shareInserts = ch.postgresChange(InsertAction.self, schema: "public", table: "task_shares")
        let shareUpdates = ch.postgresChange(UpdateAction.self, schema: "public", table: "task_shares")
        let shareDeletes = ch.postgresChange(DeleteAction.self, schema: "public", table: "task_shares")
        let circleInserts = ch.postgresChange(InsertAction.self, schema: "public", table: "trusted_circle")
        let circleUpdates = ch.postgresChange(UpdateAction.self, schema: "public", table: "trusted_circle")
        let circleDeletes = ch.postgresChange(DeleteAction.self, schema: "public", table: "trusted_circle")
        do {
            try await ch.subscribeWithError()
        } catch {
            print("[collab-realtime] subscribe failed: \(error)")
            return
        }
        channel = ch
        streamTasks.append(Task { for await _ in shareInserts { await Self.emitShares() } })
        streamTasks.append(Task { for await _ in shareUpdates { await Self.emitShares() } })
        streamTasks.append(Task { for await _ in shareDeletes { await Self.emitShares() } })
        streamTasks.append(Task { for await _ in circleInserts { await Self.emitCircle() } })
        streamTasks.append(Task { for await _ in circleUpdates { await Self.emitCircle() } })
        streamTasks.append(Task { for await _ in circleDeletes { await Self.emitCircle() } })
    }

    public func stop() async {
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        if let channel { await client.removeChannel(channel) }
        channel = nil
    }

    // Post on the main actor so SwiftUI observers can update state directly.
    @MainActor private static func emitShares() {
        NotificationCenter.default.post(name: .unstuckCollabSharesChanged, object: nil)
    }
    @MainActor private static func emitCircle() {
        NotificationCenter.default.post(name: .unstuckCollabCircleChanged, object: nil)
    }
}
