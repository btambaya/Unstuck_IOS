// SyncCursorStore — per-(user, table) high-water marks for the catch-up pull.
//
// A cursor is the newest SERVER stamp (`updated_at`, or the table's equivalent
// monotonic column) this device has already accepted for that table. The
// catch-up asks the server for `column > cursor` instead of replacing the whole
// table, which makes "am I in step?" answerable cheaply enough to ask on every
// foreground, reconnect and 60s tick.
//
// Two invariants keep it honest:
//  • the stored value only ever moves FORWARD (a late/duplicate advance with an
//    older stamp is ignored), so a re-ordered response can't rewind the client
//    past rows it already has;
//  • the cursors are wiped with the rest of the cache (clearAll) — a table that
//    was emptied must re-pull from the beginning, never from where the previous
//    user left off.

import Foundation
import GRDB
import UnstuckCore

public struct SyncCursorStore: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// The newest accepted stamp for `table`, or nil when this device has never
    /// completed a pull for it (→ the caller falls back to a full pull).
    public func cursor(userId: String, table: String) throws -> String? {
        try db.writer.read { conn in
            try String.fetchOne(conn,
                sql: "SELECT value FROM sync_cursors WHERE userId = ? AND tableName = ?",
                arguments: [userId, table])
        }
    }

    /// Every cursor for the user (diagnostics + tests).
    public func all(userId: String) throws -> [String: String] {
        try db.writer.read { conn in
            let rows = try Row.fetchAll(conn,
                sql: "SELECT tableName, value FROM sync_cursors WHERE userId = ?",
                arguments: [userId])
            var out: [String: String] = [:]
            for r in rows { out[r["tableName"]] = r["value"] }
            return out
        }
    }

    /// Move the cursor forward to `value`. A value that parses OLDER than the
    /// stored one is ignored (monotonic); an unparseable value is only accepted
    /// when there is nothing stored yet, so a malformed stamp can never rewind
    /// a healthy cursor.
    public func advance(userId: String, table: String, to value: String) throws {
        try db.writer.write { conn in
            let current = try String.fetchOne(conn,
                sql: "SELECT value FROM sync_cursors WHERE userId = ? AND tableName = ?",
                arguments: [userId, table])
            if let current {
                guard let newMs = Time.parseMillis(value) else { return }
                if let curMs = Time.parseMillis(current), newMs <= curMs { return }
            }
            try conn.execute(
                sql: """
                INSERT INTO sync_cursors (userId, tableName, value) VALUES (?, ?, ?)
                ON CONFLICT(userId, tableName) DO UPDATE SET value = excluded.value
                """,
                arguments: [userId, table, value])
        }
    }

    /// Forget every cursor (sign-out / user switch / a table that was wiped).
    public func clear() throws {
        _ = try db.writer.write { conn in try conn.execute(sql: "DELETE FROM sync_cursors") }
    }
}
