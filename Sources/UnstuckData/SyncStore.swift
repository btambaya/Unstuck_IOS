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

    /// Every locally-cached cal block. The hydrator derives both the
    /// preserved-external set and the §1.3 `localPending` preservation set
    /// (unsynced optimistic task blocks) from this snapshot.
    func fetchAllCalBlocks() throws -> [CalBlock] {
        try writer.read { try CalBlock.fetchAll($0) }
    }

    /// Every locally-cached collection. The hydrator derives the §1.3
    /// `localPending` preservation set (unsynced optimistic collections) from it.
    func fetchAllCollections() throws -> [ItemCollection] {
        try writer.read { try ItemCollection.fetchAll($0) }
    }

    /// The user's first calendar connection (for choosing a Google push target).
    func firstCalendarConnection() throws -> CalendarConnection? {
        try writer.read { try CalendarConnection.fetchOne($0) }
    }

    func blocks(forTask id: String) throws -> [CalBlock] {
        try writer.read { db in try CalBlock.filter(Column("taskId") == id).fetchAll(db) }
    }

    /// Primary-key ids currently present locally for a dependsOn PARENT table
    /// (only `tasks` / `sessions` are dependsOn parents). The OutboxFlusher uses
    /// this to hold a child op (cal_block→task, capture→session) back until its
    /// FK parent exists locally — e.g. a capture taken DURING a live focus
    /// session, whose `sessions` row is only written at session end (spec
    /// 02-sync-engine §1.4 parent-row-exists). Pushing it before then would hit
    /// the `captures.session_id` FK on every drain and poison-drop a valid write.
    func localRowIds(table: String) throws -> Set<String> {
        try writer.read { db in
            switch table {
            case "tasks":    return Set(try TaskItem.fetchAll(db).map(\.id))
            case "sessions": return Set(try Session.fetchAll(db).map(\.id))
            default:         return []
            }
        }
    }

    /// Wipe EVERYTHING for a user change / sign-out: the synced tables PLUS
    /// the local-only outbox + live_session (spec 02-sync-engine §1.7/§2.2
    /// clearAll). Leaving the outbox behind would let the next sign-in stamp
    /// the previous user's queued ops with the new user's id (cross-account
    /// leak); the pre-signout drain in SyncCoordinator.signOutAndUnregister
    /// gives pending edits their chance to flush first.
    func clearAll() throws {
        let tables = ["tasks", "sessions", "cal_blocks", "captures", "reason_logs",
                      "collections", "tags", "life_areas", "calendar_connections",
                      "outbox", "live_session"]
        try writer.write { db in
            for t in tables { try db.execute(sql: "DELETE FROM \(t)") }
        }
    }
}
