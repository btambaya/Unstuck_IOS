// AppDatabase — the GRDB-backed local store. Schema mirrors the synced
// Supabase tables (one local table per server table, columns named to
// match the Swift model's Codable keys; JSON-shaped fields stored as TEXT
// and decoded back into the UnstuckCore models). Two local-only tables:
// `outbox` (offline write-ahead queue) and `live_session` (device-local
// focus state). The sync layer (UnstuckSync) treats the server as
// canonical and replaces these tables per the hydrate contract.

import Foundation
import GRDB
import UnstuckCore

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// In-memory store for tests + previews.
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// On-disk store at `path` (WAL pool for reader/writer concurrency).
    public static func make(path: String) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(try DatabasePool(path: path, configuration: config))
    }

    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("estimateMin", .integer).notNull()
                t.column("totalFocused", .integer).notNull()
                t.column("done", .boolean).notNull()
                t.column("priority", .text)
                t.column("tags", .text)            // JSON [String]
                t.column("objectives", .text)      // JSON [Objective]
                t.column("comments", .text)        // JSON [Comment]
                t.column("intentWhen", .text)
                t.column("intentThen", .text)
                t.column("lifeArea", .text)
                t.column("firstPhysicalAction", .text)
                t.column("moveCount", .integer)
                t.column("completedAt", .text)
                t.column("later", .boolean)
                t.column("recurrence", .text)      // JSON Recurrence
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }

            try db.create(table: "cal_blocks") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text)
                t.column("taskName", .text).notNull()
                t.column("startTime", .text).notNull()
                t.column("durationMinutes", .integer).notNull()
                t.column("date", .text).notNull().indexed()
                t.column("externalEventId", .text)
                t.column("externalConnectionId", .text)
                t.column("kind", .text)
            }

            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text)
                t.column("taskName", .text).notNull()
                t.column("tags", .text)            // JSON [String]
                t.column("estimateMin", .integer)
                t.column("actualSec", .integer).notNull()
                t.column("completedAt", .text).notNull()
            }

            try db.create(table: "captures") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text)
                t.column("sessionId", .text)
                t.column("tag", .text).notNull()
                t.column("body", .text).notNull()
                t.column("at", .text).notNull()
            }

            try db.create(table: "reason_logs") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text)
                t.column("reason", .text).notNull()
                t.column("action", .text).notNull()
                t.column("at", .text).notNull()
                t.column("durationSec", .integer)
            }

            try db.create(table: "collections") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("subtitle", .text)
                t.column("items", .text).notNull()  // JSON [CollectionItem]
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: "tags") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: "life_areas") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: "calendar_connections") { t in
                t.primaryKey("id", .text)
                t.column("provider", .text).notNull()
                t.column("accountEmail", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("selectedCalendarIds", .text).notNull()  // JSON [String]
                t.column("colorSlot", .integer).notNull()
                t.column("lastSyncCursor", .text)
                t.column("connectedAt", .text).notNull()
            }

            // Local-only: offline write-ahead queue.
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("opSeq")
                t.column("tableName", .text).notNull()
                t.column("rowId", .text).notNull()
                t.column("kind", .text).notNull()       // upsert | delete
                t.column("payload", .text)              // JSON row (nil for delete)
                t.column("dependsOn", .text)            // rowId this op waits on
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
            }

            // Local-only: single-row device-local live focus session.
            try db.create(table: "live_session") { t in
                t.primaryKey("slot", .text)             // always "current"
                t.column("payload", .text)              // JSON LiveSession, nil = idle
            }
        }

        return m
    }()
}
