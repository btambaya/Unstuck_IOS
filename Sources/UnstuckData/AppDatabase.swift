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
                t.column("sourceCollectionId", .text)   // move-to-task link (migration 025)
                t.column("sourceItemId", .text)
                t.column("dueAt", .text)
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
                t.column("ownerId", .text)          // sharing fields (client-only, hydrate-populated)
                t.column("members", .text)          // JSON [String]
                t.column("myRole", .text)
                t.column("archived", .boolean)      // migration 026
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

        // Per-occurrence state for recurring tasks (migration 033). A cal_block
        // that fronts a recurring template's occurrence carries its own
        // done/skipped/completedAt so each day can be completed/skipped without
        // touching the series. Defaults match the server columns
        // (not null default false / null).
        m.registerMigration("v2_cal_block_occurrence_state") { db in
            try db.alter(table: "cal_blocks") { t in
                t.add(column: "done", .boolean).notNull().defaults(to: false)
                t.add(column: "skipped", .boolean).notNull().defaults(to: false)
                t.add(column: "completedAt", .text)
            }
        }

        // The assistant's cross-device memory (server migration 050
        // `profile_facts`). `active` is a soft-delete tombstone — rows are
        // never hard-deleted by a client, so another device's cache can't
        // resurrect a forgotten fact. Columns mirror the server; `whenIso`
        // is the `when_iso` date (YYYY-MM-DD) a fact refers to.
        m.registerMigration("v3_profile_facts") { db in
            try db.create(table: "profile_facts") { t in
                t.primaryKey("id", .text)
                t.column("category", .text).notNull()
                t.column("fact", .text).notNull()
                t.column("source", .text).notNull()
                t.column("whenIso", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull().indexed()
            }
        }

        // Sync-engine hardening:
        //  • outbox.baseUpdatedAt / basePayload — the row a task edit was made
        //    on top of, so the prune compares server clock with server clock
        //    (skew-proof) and can 3-way merge instead of dropping the op.
        //  • parked_outbox — un-pushed ops kept across a sign-out, keyed by the
        //    owning user, restored on THAT user's next sign-in (never replayed
        //    under anyone else). Survives clearAll.
        //  • capture_archive — the Inbox archive state (server `captures.
        //    archived_at`, migration 053) as a local table: the UI's archived
        //    set is a cache of this, and a row here means "archived_at is set".
        m.registerMigration("v4_outbox_base_parking_capture_archive") { db in
            try db.alter(table: "outbox") { t in
                t.add(column: "baseUpdatedAt", .text)
                t.add(column: "basePayload", .text)
            }
            try db.create(table: "parked_outbox") { t in
                t.autoIncrementedPrimaryKey("parkSeq")
                t.column("userId", .text).notNull().indexed()
                t.column("tableName", .text).notNull()
                t.column("rowId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .text)
                t.column("dependsOn", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("baseUpdatedAt", .text)
                t.column("basePayload", .text)
            }
            try db.create(table: "capture_archive") { t in
                t.primaryKey("captureId", .text)
                t.column("archivedAt", .text).notNull()
            }
        }

        // Catch-up cursors (the freshness owner's high-water marks): the newest
        // server stamp this device has ACCEPTED per (user, table), so a catch-up
        // can ask for `<cursorColumn> > cursor` instead of replacing the whole
        // table. Keyed by user so a device shared by two accounts can't inherit
        // the other's position; wiped by clearAll with the rest of the cache,
        // because a wiped table must re-pull from the start.
        m.registerMigration("v5_sync_cursors") { db in
            try db.create(table: "sync_cursors") { t in
                t.column("userId", .text).notNull()
                t.column("tableName", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["userId", "tableName"])
            }
        }

        // "Unstuck calls you": the local mirror of `call_requests` (server
        // migrations 051 / 053 / 072). Columns ARE the server's snake_case names
        // (the CallRequest row type in UnstuckSync is the record); `notes` /
        // `outcome_notes` are JSON text. Never written by the outbox — the
        // client books / cancels through direct writes and mirrors the returned
        // row; the hydrate / realtime / cursor catch-up keep it in step.
        m.registerMigration("v6_call_requests") { db in
            try db.create(table: "call_requests") { t in
                t.primaryKey("id", .text)
                t.column("user_id", .text)
                t.column("task_id", .text).indexed()
                t.column("block_id", .text)
                t.column("call_at", .text).notNull().indexed()
                t.column("lead_min", .integer)
                t.column("label", .text).notNull()
                t.column("notes", .text)             // JSON [String]
                t.column("status", .text).notNull().defaults(to: "scheduled")
                t.column("snooze_until", .text)
                t.column("outcome_notes", .text)     // JSON [String]
                t.column("call_id", .text)
                t.column("attempts", .integer)
                t.column("kind", .text).notNull().defaults(to: "requested")
                t.column("retries", .integer)
                t.column("created_at", .text)
                t.column("updated_at", .text).indexed()
            }
        }

        return m
    }()
}
