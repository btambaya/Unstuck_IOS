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

    /// Read a single row by primary key (nil if absent). Used by the realtime
    /// mirror to preserve client-only fields (collection members/myRole) across
    /// an incoming server row that carries neither.
    func fetchById<T: FetchableRecord & PersistableRecord & Sendable>(_ type: T.Type, id: String) throws -> T? {
        try writer.read { try type.fetchOne($0, key: id) }
    }

    /// Locally-cached Google external blocks (kind == external) — preserved
    /// across a cal_blocks hydrate since their ids aren't UUIDs and never
    /// live on the server.
    func fetchExternalCalBlocks() throws -> [CalBlock] {
        try writer.read { db in
            try CalBlock.filter(Column("kind") == CalBlockKind.external.rawValue).fetchAll(db)
        }
    }

    /// The user's first calendar connection (for choosing a Google push target).
    func firstCalendarConnection() throws -> CalendarConnection? {
        try writer.read { try CalendarConnection.fetchOne($0) }
    }

    func blocks(forTask id: String) throws -> [CalBlock] {
        try writer.read { db in try CalBlock.filter(Column("taskId") == id).fetchAll(db) }
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
