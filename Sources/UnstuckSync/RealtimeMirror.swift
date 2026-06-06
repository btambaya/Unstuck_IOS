// RealtimeMirror — subscribes to postgres_changes per synced table and
// applies INSERT/UPDATE (upsert into local) + DELETE (remove from local).
// One channel per table (unstuck_<table>_<uid>), filtered by user_id (RLS
// enforces server-side; the filter is client safety). calendar_connections
// is intentionally NOT subscribed — its encrypted credentials must never
// be broadcast (refreshed via polling instead).

import Foundation
import Supabase
import UnstuckCore
import UnstuckData

public actor RealtimeMirror {
    private let client: SupabaseClient
    private let db: AppDatabase
    private var channels: [RealtimeChannelV2] = []
    private var streamTasks: [Task<Void, Never>] = []

    public init(client: SupabaseClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    private struct IdOnly: Decodable { let id: String }

    public func subscribeAll(userId: String, onMembersChanged: @escaping @Sendable () async -> Void = {}) async {
        await unsubscribeAll()
        await subscribe("tasks", TaskRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(TaskItem.self, id: $0) })
        await subscribe("sessions", SessionRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(Session.self, id: $0) })
        await subscribe("cal_blocks", CalBlockRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(CalBlock.self, id: $0) })
        await subscribe("captures", CaptureRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(Capture.self, id: $0) })
        await subscribe("reason_logs", ReasonLogRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(ReasonLog.self, id: $0) })
        // Collections: shared rows are owned by someone else, so subscribe
        // WITHOUT the user_id filter and rely on RLS for delivery (members get
        // the owner's edits). Preserve the client-only members/myRole across the
        // incoming row (it carries neither). Port of realtime.ts mergeKeep.
        await subscribe("collections", CollectionRow.self, userId: userId,
                        onUpsert: { row in
                            let m = row.model()
                            let existing = try? self.db.fetchById(ItemCollection.self, id: m.id)
                            var merged = m
                            merged.members = existing?.members ?? []
                            merged.myRole = existing?.myRole ?? (m.ownerId == userId ? "owner" : nil)
                            try? self.db.save(merged)
                        },
                        onDelete: { try? self.db.deleteById(ItemCollection.self, id: $0) },
                        noUserFilter: true)
        await subscribe("tags", TagDbRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(TagRow.self, id: $0) })
        await subscribe("life_areas", LifeAreaDbRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(LifeArea.self, id: $0) })
        // Membership changes for ME — a new share or a revocation. Re-hydrate
        // collections so the freshly-shared list appears / the revoked one drops.
        await subscribeMembers(userId: userId, onChanged: onMembersChanged)
    }

    private func subscribe<Row: Decodable & Sendable>(
        _ table: String,
        _ rowType: Row.Type,
        userId: String,
        onUpsert: @escaping @Sendable (Row) -> Void,
        onDelete: @escaping @Sendable (String) -> Void,
        noUserFilter: Bool = false
    ) async {
        let channel = client.channel("unstuck_\(table)_\(userId)")
        let filter: RealtimePostgresFilter? = noUserFilter ? nil : .eq("user_id", value: userId)
        // Build streams BEFORE subscribing so no early events are missed.
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: table, filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: table, filter: filter)
        let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: table, filter: filter)
        do {
            try await channel.subscribeWithError()
        } catch {
            print("[realtime] subscribe \(table) failed: \(error)")
            return
        }
        channels.append(channel)
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in inserts {
                if let row = try? change.decodeRecord(as: Row.self, decoder: dec) { onUpsert(row) }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in updates {
                if let row = try? change.decodeRecord(as: Row.self, decoder: dec) { onUpsert(row) }
            }
        })
        streamTasks.append(Task {
            let dec = JSONDecoder()
            for await change in deletes {
                if let gone = try? change.decodeOldRecord(as: IdOnly.self, decoder: dec) { onDelete(gone.id) }
            }
        })
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
        do {
            try await channel.subscribeWithError()
        } catch {
            print("[realtime] subscribe collection_members failed: \(error)")
            return
        }
        channels.append(channel)
        streamTasks.append(Task { for await _ in inserts { await onChanged() } })
        streamTasks.append(Task { for await _ in updates { await onChanged() } })
        streamTasks.append(Task { for await _ in deletes { await onChanged() } })
    }

    public func unsubscribeAll() async {
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        for ch in channels { await client.removeChannel(ch) }
        channels.removeAll()
    }
}
