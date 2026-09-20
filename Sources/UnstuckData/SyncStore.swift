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
            try AppDatabase.insertReplacing(db, rows)
        }
    }

    /// Write every row with `INSERT OR REPLACE` — the fast equivalent of the
    /// per-row `upsert` the hydrate's table replaces used to do.
    ///
    /// NOT plain `insert`: a duplicate id in `rows` — e.g. the server briefly
    /// returns two rows with the same id during a merge — would make `insert`
    /// throw and, because the Hydrator catch swallows it and "leaves local
    /// intact", abort the WHOLE table's hydrate. `upsert` and `INSERT OR
    /// REPLACE` both resolve the duplicate to last-write-wins instead of
    /// failing, so the stored result is the same (SyncStoreTests pins it).
    ///
    /// NOT `upsert`: it emits `ON CONFLICT DO UPDATE SET … RETURNING …` and
    /// decodes the returned row for its insert callbacks — ~4× the cost per
    /// row, for a result we throw away. Measured on the heavy fixture
    /// (Release, 4,000 cal_blocks in one transaction): upsert 96.6 ms vs
    /// INSERT OR REPLACE 23.4 ms. Note the statement COUNT is NOT the problem
    /// — `deleteAll` is 0.14 ms, and batching the same rows into 160 multi-row
    /// INSERTs only reaches 12.8 ms, which does not justify hand-maintaining a
    /// column list per record type beside the Codable encoding.
    ///
    /// `REPLACE` deletes a conflicting row before re-inserting it, which would
    /// matter if these tables had `ON DELETE CASCADE` children or delete
    /// triggers. The LOCAL schema (AppDatabase.migrator) declares neither — no
    /// `references`/`REFERENCES` anywhere in it, so `foreignKeysEnabled` has
    /// nothing to act on here; the FKs the sync engine talks about are the
    /// SERVER's, enforced by Postgres on push, not by this store. Nothing in
    /// the app reads a SQLite rowid either, so the only difference from
    /// `upsert` is the speed. Keep both facts true if you add a local FK.
    static func insertReplacing<T: PersistableRecord & Sendable>(_ db: Database, _ rows: [T]) throws {
        for r in rows { try r.insert(db, onConflict: .replace) }
    }

    /// Read → decide → replace, in ONE write transaction. `body` receives the
    /// current local rows (plus the connection, for outbox edits that must
    /// commit with the merge) and returns what the table becomes. Because the
    /// read and the replace share the transaction, a row written by another
    /// caller lands either BEFORE (so `body` sees it) or AFTER (so it isn't
    /// deleted) — never in between. The profile_facts hydrate merge needs
    /// this: with separate transactions, a fact saved between the local read
    /// and the replace was silently deleted.
    func replaceAllAtomically<T: PersistableRecord & FetchableRecord & Sendable>(
        _ type: T.Type, _ body: (Database, [T]) throws -> [T]) throws {
        try writer.write { db in
            let local = try T.fetchAll(db)
            let rows = try body(db, local)
            try type.deleteAll(db)
            try AppDatabase.insertReplacing(db, rows)
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

    /// Every locally-cached life area. Onboarding uses this to seed default
    /// areas only when the user has none yet (avoids double-seeding on an
    /// existing account whose areas already hydrated).
    func fetchAllLifeAreas() throws -> [LifeArea] {
        try writer.read { try LifeArea.fetchAll($0) }
    }

    /// Every locally-cached tag. The assistant context builder reads this to
    /// give the agent the user's curated tag vocabulary.
    func fetchAllTags() throws -> [TagRow] {
        try writer.read { try TagRow.order(Column("sortOrder")).fetchAll($0) }
    }

    /// Every locally-cached profile fact INCLUDING tombstones. The hydrator's
    /// last-write-wins merge needs the inactive rows too (a local tombstone
    /// newer than the server's active row must win, and vice versa).
    func fetchAllProfileFacts() throws -> [ProfileFact] {
        try writer.read { try ProfileFact.fetchAll($0) }
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

    /// Every locally-held primary-key id for a synced table — what the
    /// catch-up's deletion reconcile compares against the server's surviving
    /// id set. Unknown tables answer empty (never "delete everything").
    func localIds(table: String) throws -> Set<String> {
        try writer.read { db in
            switch table {
            case "tasks":        return Set(try String.fetchAll(db, sql: "SELECT id FROM tasks"))
            case "sessions":     return Set(try String.fetchAll(db, sql: "SELECT id FROM sessions"))
            case "reason_logs":  return Set(try String.fetchAll(db, sql: "SELECT id FROM reason_logs"))
            case "collections":  return Set(try String.fetchAll(db, sql: "SELECT id FROM collections"))
            case "tags":         return Set(try String.fetchAll(db, sql: "SELECT id FROM tags"))
            case "life_areas":   return Set(try String.fetchAll(db, sql: "SELECT id FROM life_areas"))
            case "captures":     return Set(try String.fetchAll(db, sql: "SELECT id FROM captures"))
            case "cal_blocks":   return Set(try String.fetchAll(db, sql: "SELECT id FROM cal_blocks"))
            case "call_requests": return Set(try String.fetchAll(db, sql: "SELECT id FROM call_requests"))
            default:             return []
            }
        }
    }

    /// Wipe EVERYTHING for a user change / sign-out: the synced tables PLUS
    /// the local-only outbox + live_session + capture archive (spec
    /// 02-sync-engine §1.7/§2.2 clearAll). Leaving the outbox behind would let
    /// the next sign-in stamp the previous user's queued ops with the new
    /// user's id (cross-account leak); the pre-signout drain in
    /// SyncCoordinator.signOutAndUnregister gives pending edits their chance
    /// to flush first, and whatever still couldn't flush is PARKED under the
    /// signing-out user (`parked_outbox`, deliberately NOT wiped here) for
    /// that user's next sign-in.
    func clearAll() throws {
        // `sync_cursors` goes with them: a wiped table must re-pull from the
        // start, and a cursor left behind would tell the next catch-up the
        // device is already in step with rows it no longer holds.
        let tables = ["tasks", "sessions", "cal_blocks", "captures", "reason_logs",
                      "collections", "tags", "life_areas", "calendar_connections",
                      "profile_facts", "call_requests", "outbox", "live_session", "capture_archive",
                      "sync_cursors"]
        try writer.write { db in
            for t in tables { try db.execute(sql: "DELETE FROM \(t)") }
        }
    }

    // MARK: - capture archive (server `captures.archived_at`, migration 053)

    /// Capture ids currently archived (`archived_at` set) — the Inbox's
    /// archived set is a cache of this.
    func archivedCaptureIds() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT captureId FROM capture_archive"))
        }
    }

    /// Live view of the archived-capture id set — the Inbox's observable
    /// cache follows THIS (hydrate, realtime, our own write-through and the
    /// sign-out wipe all land here), never the other way round.
    func observeArchivedCaptureIds() -> AsyncValueObservation<Set<String>> {
        ValueObservation.tracking { db in
            Set(try String.fetchAll(db, sql: "SELECT captureId FROM capture_archive"))
        }.values(in: writer)
    }

    /// The archive state for one capture: its `archived_at`, or nil when open.
    func captureArchivedAt(id: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT archivedAt FROM capture_archive WHERE captureId = ?", arguments: [id])
        }
    }

    /// Set / clear one capture's archive state. `archivedAt` nil = open.
    func setCaptureArchived(id: String, archivedAt: String?) throws {
        try writer.write { db in try Self.setCaptureArchived(in: db, id: id, archivedAt: archivedAt) }
    }

    /// Same, on an OPEN connection (WriteThrough commits it with the outbox op).
    static func setCaptureArchived(in db: Database, id: String, archivedAt: String?) throws {
        if let archivedAt {
            try db.execute(sql: "INSERT OR REPLACE INTO capture_archive (captureId, archivedAt) VALUES (?, ?)",
                           arguments: [id, archivedAt])
        } else {
            try db.execute(sql: "DELETE FROM capture_archive WHERE captureId = ?", arguments: [id])
        }
    }

    /// Server-canonical replace of the archive state (hydrate): `byId` maps
    /// capture id → archived_at for every archived server row. Ids with a
    /// pending captures upsert keep their LOCAL state (the op carries the
    /// user's newer intent). Runs in the same transaction as the captures
    /// replace when called from `replaceAllAtomically`'s body.
    static func replaceCaptureArchive(in db: Database, serverArchived byId: [String: String], keepLocalIds: Set<String>) throws {
        let localRows = try Row.fetchAll(db, sql: "SELECT captureId, archivedAt FROM capture_archive")
        var next: [String: String] = byId
        for row in localRows {
            let id: String = row["captureId"]
            if keepLocalIds.contains(id) { next[id] = row["archivedAt"] }
        }
        for id in keepLocalIds where byId[id] != nil && !localRows.contains(where: { ($0["captureId"] as String) == id }) {
            next[id] = nil   // pending local state says "open" — keep it open
        }
        try db.execute(sql: "DELETE FROM capture_archive")
        for (id, at) in next {
            try db.execute(sql: "INSERT INTO capture_archive (captureId, archivedAt) VALUES (?, ?)", arguments: [id, at])
        }
    }

    // MARK: - generic transaction seam

    /// One write transaction for callers that must commit several things
    /// together (WriteThrough: the row save + the outbox op — a crash between
    /// two separate transactions left a local row with no op, which the next
    /// hydrate silently deleted).
    func transaction<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.write(body)
    }
}
