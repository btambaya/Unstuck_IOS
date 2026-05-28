// Store-level helpers the sync engine uses: optimistic upsert, the
// server-canonical per-table replace (hydrate), targeted delete, the
// preserved-external-blocks read, and the sign-out cache wipe.

import Foundation
import GRDB
import UnstuckCore

public extension AppDatabase {
    /// Optimistic insert-or-update by primary key.
    func save<T: PersistableRecord & Sendable>(_ row: T) throws {
        try writer.write { try row.upsert($0) }
    }

    /// Server-canonical replace of an entire table (hydrate). Used per
    /// table that fetched successfully; a failed table is left untouched.
    func replaceAll<T: PersistableRecord & FetchableRecord & Sendable>(_ type: T.Type, with rows: [T]) throws {
        try writer.write { db in
            try type.deleteAll(db)
            for r in rows { try r.insert(db) }
        }
    }

    func deleteById<T: PersistableRecord & FetchableRecord & Sendable>(_ type: T.Type, id: String) throws {
        _ = try writer.write { try type.deleteOne($0, key: id) }
    }

    /// Locally-cached Google external blocks (kind == external) — preserved
    /// across a cal_blocks hydrate since their ids aren't UUIDs and never
    /// live on the server.
    func fetchExternalCalBlocks() throws -> [CalBlock] {
        try writer.read { db in
            try CalBlock.filter(Column("kind") == CalBlockKind.external.rawValue).fetchAll(db)
        }
    }

    /// Wipe every synced table (sign-out / shared-device privacy). Local-
    /// only tables (outbox, live_session) are intentionally left alone.
    func wipeSyncedTables() throws {
        let tables = ["tasks", "sessions", "cal_blocks", "captures", "reason_logs",
                      "collections", "tags", "life_areas", "calendar_connections"]
        try writer.write { db in
            for t in tables { try db.execute(sql: "DELETE FROM \(t)") }
        }
    }
}
