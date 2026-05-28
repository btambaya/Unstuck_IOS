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

    public func subscribeAll(userId: String) async {
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
        await subscribe("collections", CollectionRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(ItemCollection.self, id: $0) })
        await subscribe("tags", TagDbRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(TagRow.self, id: $0) })
        await subscribe("life_areas", LifeAreaDbRow.self, userId: userId,
                        onUpsert: { try? self.db.save($0.model()) },
                        onDelete: { try? self.db.deleteById(LifeArea.self, id: $0) })
    }

    private func subscribe<Row: Decodable & Sendable>(
        _ table: String,
        _ rowType: Row.Type,
        userId: String,
        onUpsert: @escaping @Sendable (Row) -> Void,
        onDelete: @escaping @Sendable (String) -> Void
    ) async {
        let channel = client.channel("unstuck_\(table)_\(userId)")
        let filter = RealtimePostgresFilter.eq("user_id", value: userId)
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

    public func unsubscribeAll() async {
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        for ch in channels { await client.removeChannel(ch) }
        channels.removeAll()
    }
}
