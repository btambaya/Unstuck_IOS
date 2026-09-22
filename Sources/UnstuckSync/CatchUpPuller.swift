// CatchUpPuller — the CORRECTNESS path for "did anything change while we
// weren't listening?".
//
// postgres_changes has no replay: anything written while the socket was down,
// the phone was dozing, or the channel was joined-but-deaf (both proven on
// 2026-09-12) is simply never broadcast. Realtime is therefore an OPTIMISATION;
// this pull is what actually keeps the device in step.
//
// It is NOT the full hydrate. Per table we keep a high-water mark (the newest
// server stamp we have accepted — SyncCursorStore) and ask only for rows at or
// after it, ordered and paged. A typical tick is seven requests that each
// return an empty array.
//
// Three rules make it safe to run as often as we like:
//  1. it NEVER clobbers a pending local write. `tasks` and `profile_facts`
//     reuse the realtime mirror's own last-write-wins/base-aware guards; every
//     other table skips a row while the outbox still holds an un-acked write
//     for it — the same rule the hydrate's `pendingUpsertIds` applies.
//  2. the cursor only advances over rows the client actually ACCEPTED a verdict
//     on (applied, or deliberately skipped by those guards). A row that failed
//     to decode or failed to store STOPS the advance for that table, so the
//     next catch-up sees it again.
//  3. deletions can't be seen by a cursor pull at all, so a reconcile pass asks
//     the server for ids only (paged, `select=id`) and drops local rows the
//     server no longer has — never one with a pending local write.
//
// Two tables have no monotonic column on the server at all (`cal_blocks` has no
// timestamp; `captures.archived_at` moves without `created_at` moving), so they
// fall back to the existing full server-canonical replace inside the catch-up.
// That is what every 60s tick did for ALL ten tables before this existed, so it
// is strictly cheaper; adding `updated_at` to those two server tables is the
// follow-up that would make them delta-capable too.

import Foundation
import UnstuckCore
import UnstuckData

public actor CatchUpPuller {
    /// What one catch-up did — the freshness owner logs it and uses
    /// `appliedNewerThan` as the deafness oracle.
    public struct Outcome: Sendable, Equatable {
        public var rowsApplied = 0
        public var rowsSkippedPending = 0
        public var idsDropped = 0
        public var fullFallbackTables: [String] = []
        public var failedTables: [String] = []
        /// Server stamps (epoch ms) of rows applied to a table this device was
        /// ALREADY caught up on (it had a cursor). If realtime were healthy
        /// those rows would have arrived as events first, so this is the
        /// deafness oracle. Rows applied while a table was being seeded are
        /// deliberately excluded — see `seededRowsApplied`.
        public var appliedStampsMs: [Double] = []
        public var reconciled = false
        /// Rows applied to tables that had NO cursor yet (first pull after
        /// sign-in or a cache wipe): a re-application of what the hydrate just
        /// fetched, which says nothing about whether realtime is delivering.
        public var seededRowsApplied = 0
        /// Tables that were pulled in full because they had no cursor.
        public var seededTables: [String] = []
        /// A `collections` row this device had not seen (strictly newer than
        /// the cursor the pull started from, or the table was being seeded)
        /// was applied or skipped. The server row carries no membership, and
        /// migration 056 §4 bumps `updated_at` on every collection_members
        /// change — so this is what tells the catch-up to re-read membership
        /// (audit 2026-09-22, C8). The inclusive boundary re-read never sets it.
        public var collectionsChanged = false

        public var changed: Bool { rowsApplied > 0 || idsDropped > 0 }
        public init() {}
    }

    /// A table the catch-up can pull by cursor.
    struct DeltaTable {
        let name: String
        /// The monotonic server column this table's cursor tracks.
        let column: String
        /// Apply one raw server row. Returns the verdict so the cursor knows
        /// whether it may move past it.
        let apply: @Sendable (Data, AppDatabase) -> ApplyVerdict
        /// Drop a local row the server no longer has.
        let delete: @Sendable (String, AppDatabase) -> Void
        /// Hard deletes are possible (false for tombstoned tables).
        let reconcileDeletes: Bool
    }

    public enum ApplyVerdict: Sendable, Equatable {
        case applied
        case skippedPendingLocalWrite
        case failed
    }

    private let gateway: any SyncReadGatewayProtocol
    private let db: AppDatabase
    private let cursors: SyncCursorStore
    private let box: OutboxStore
    /// Full-replace fallback for the two tables the server gives no cursor for.
    private let fullFallback: @Sendable (String) async -> Bool
    /// Collections membership re-read, run right after the collections pull:
    /// `(userId, collectionsChanged)`, and the Hydrator decides (it also
    /// retries a membership read that failed earlier). Injected like
    /// `fullFallback`.
    private let refreshCollections: @Sendable (String, Bool) async -> Void
    private let decoder = JSONDecoder()

    static let pageSize = 500
    static let idPageSize = 1000

    public init(gateway: any SyncReadGatewayProtocol, db: AppDatabase,
                fullFallback: @escaping @Sendable (String) async -> Bool,
                refreshCollections: @escaping @Sendable (String, Bool) async -> Void = { _, _ in }) {
        self.gateway = gateway
        self.db = db
        self.cursors = SyncCursorStore(db)
        self.box = OutboxStore(db)
        self.fullFallback = fullFallback
        self.refreshCollections = refreshCollections
    }

    /// Tables with no monotonic server column — pulled by full replace.
    public static let fullReplaceTables = ["cal_blocks", "captures"]

    // MARK: - the pull

    /// Ask the server for everything newer than our cursors and merge it.
    /// `reconcileDeletions` additionally asks which ids still exist.
    public func catchUp(userId: String, reconcileDeletions: Bool) async -> Outcome {
        var outcome = Outcome()
        for table in Self.deltaTables {
            await pull(table, userId: userId, into: &outcome)
            // Right after the collections page, not after every table: an edit
            // made while the rest of the pull runs would still route on the
            // stale membership.
            if table.name == "collections" {
                await refreshCollections(userId, outcome.collectionsChanged)
            }
        }
        for name in Self.fullReplaceTables {
            if await fullFallback(name) {
                outcome.fullFallbackTables.append(name)
            } else {
                outcome.failedTables.append(name)
            }
        }
        if reconcileDeletions {
            outcome.reconciled = true
            for table in Self.deltaTables where table.reconcileDeletes {
                await reconcile(table, userId: userId, into: &outcome)
            }
        }
        return outcome
    }

    private func pull(_ table: DeltaTable, userId: String, into outcome: inout Outcome) async {
        let startCursor = (try? cursors.cursor(userId: userId, table: table.name)) ?? nil
        // No cursor = this device has never completed a pull for the table, so
        // the pull below is a full one and its rows prove nothing about the
        // health of the realtime channel.
        let seeding = startCursor == nil
        if seeding { outcome.seededTables.append(table.name) }
        let startMs = startCursor.flatMap(Time.parseMillis)
        var after = startCursor
        var seenIds = Set<String>()
        var highWater: String?
        var pages = 0
        // A missing cursor means this device has never completed a pull for the
        // table (first run, or the cache was wiped) — `after == nil` asks for
        // everything, which is the full-hydrate fallback the contract requires.
        while pages < 40 {
            pages += 1
            let page: [Data]
            do {
                page = try await gateway.fetchPageSince(table: table.name, column: table.column,
                                                        atOrAfter: after, limit: Self.pageSize)
            } catch {
                print("[catchup] \(table.name) page failed, cursor held: \(error)")
                outcome.failedTables.append(table.name)
                break
            }
            var lastStamp: String?
            var blocked = false
            for raw in page {
                guard let id = Self.stringField("id", in: raw) else { continue }
                guard seenIds.insert(id).inserted else { continue }   // page-boundary tie
                let stamp = Self.stringField(table.column, in: raw)
                let stampMs = stamp.flatMap(Time.parseMillis)
                let newerThanStart = stampMs.flatMap { ms in startMs.map { ms > $0 } } ?? false
                // A row this device DELETED whose delete hasn't reached the
                // server yet is still on the server, so the pull carries it.
                // Applying it would resurrect something the user removed; the
                // queued delete is what settles it.
                let verdict = Self.hasPendingDelete(table: table.name, rowId: id, db: db)
                    ? ApplyVerdict.skippedPendingLocalWrite
                    : table.apply(raw, db)
                switch verdict {
                case .applied:
                    outcome.rowsApplied += 1
                    if seeding {
                        outcome.seededRowsApplied += 1
                    } else if newerThanStart, let ms = stampMs {
                        // ONLY rows strictly newer than the mark we asked from.
                        // The pull is inclusive (`>= cursor`) on purpose — every
                        // tick re-reads the boundary row of every table — and
                        // counting those re-reads as "realtime never delivered
                        // this" made a healthy, quiet phone rebuild all eleven
                        // channels every 60s (proven by
                        // testAQuietAccountIsNeverAccusedOfDeafness).
                        outcome.appliedStampsMs.append(ms)
                    }
                case .skippedPendingLocalWrite:
                    outcome.rowsSkippedPending += 1
                case .failed:
                    // Don't move the cursor past a row we couldn't take.
                    blocked = true
                }
                // Skipped rows count too: the cursor still moves past them.
                if table.name == "collections", verdict != .failed, seeding || newerThanStart {
                    outcome.collectionsChanged = true
                }
                if blocked { break }
                if let stamp { lastStamp = stamp }
            }
            if let lastStamp { highWater = lastStamp }
            if blocked { break }
            if page.count < Self.pageSize { break }
            guard let lastStamp else { break }   // no usable stamp → stop rather than loop
            // A full page whose last stamp equals the one we asked from is a
            // page of identical timestamps: paging again would re-fetch it
            // forever. Stop; the cursor stays put and the next catch-up retries.
            if lastStamp == after { break }
            after = lastStamp
        }
        if let highWater, highWater != startCursor {
            try? cursors.advance(userId: userId, table: table.name, to: highWater)
        }
    }

    /// Drop local rows the server no longer has. Never touches a row with a
    /// pending local write (it may be a create the server hasn't seen yet).
    private func reconcile(_ table: DeltaTable, userId: String, into outcome: inout Outcome) async {
        var serverIds = Set<String>()
        var afterId: String?
        var pages = 0
        while pages < 40 {
            pages += 1
            let page: [String]
            do {
                page = try await gateway.fetchIdPage(table: table.name, afterId: afterId, limit: Self.idPageSize)
            } catch {
                print("[catchup] \(table.name) id reconcile failed, keeping local rows: \(error)")
                return   // an incomplete id set must NEVER drive deletions
            }
            serverIds.formUnion(page)
            if page.count < Self.idPageSize { break }
            afterId = page.last
        }
        let localIds = (try? db.localIds(table: table.name)) ?? []
        guard !localIds.isEmpty else { return }
        let pending = pendingRowIds(table: table.name)
        for id in localIds where !serverIds.contains(id) && !pending.contains(id) {
            table.delete(id, db)
            outcome.idsDropped += 1
        }
    }

    // MARK: - guards

    /// Row ids with an un-acked local write (upsert or RPC) for `table` —
    /// the same set the hydrate preserves.
    private func pendingRowIds(table: String) -> Set<String> {
        Set(((try? box.pending()) ?? [])
            .filter { $0.tableName == table && ($0.kind == .upsert || $0.kind == .rpc) }
            .map(\.rowId))
    }

    /// A queued local DELETE for that row. Checked for EVERY table (tasks
    /// included, where the ordinary pending-write case is handled by the
    /// base-aware LWW guard instead).
    static func hasPendingDelete(table: String, rowId: String, db: AppDatabase) -> Bool {
        ((try? OutboxStore(db).pending()) ?? [])
            .contains { $0.tableName == table && $0.kind == .delete && $0.rowId == rowId }
    }

    static func hasPendingWrite(table: String, rowId: String, db: AppDatabase) -> Bool {
        ((try? OutboxStore(db).pending()) ?? [])
            .contains { $0.tableName == table && ($0.kind == .upsert || $0.kind == .rpc) && $0.rowId == rowId }
    }

    /// Read one string field out of a raw server row without decoding it.
    static func stringField(_ key: String, in raw: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    // MARK: - the table registry

    /// The tables a cursor pull covers, with the column each one's cursor
    /// tracks. `sessions` / `reason_logs` are append-only ledgers whose natural
    /// timestamp is their monotonic column; the rest carry `updated_at`.
    static let deltaTables: [DeltaTable] = [
        DeltaTable(name: "tasks", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(TaskRow.self, from: raw) else { return .failed }
                       // The realtime mirror's own base-aware LWW guard: a row
                       // at-or-before a queued edit's base is the server state
                       // that edit was made on, and must not overwrite it.
                       guard RealtimeMirror.incomingTaskWins(row, db: db) else { return .skippedPendingLocalWrite }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(TaskItem.self, id: id) },
                   reconcileDeletes: true),

        DeltaTable(name: "sessions", column: "completed_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(SessionRow.self, from: raw) else { return .failed }
                       guard !CatchUpPuller.hasPendingWrite(table: "sessions", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(Session.self, id: id) },
                   reconcileDeletes: true),

        DeltaTable(name: "reason_logs", column: "at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(ReasonLogRow.self, from: raw) else { return .failed }
                       guard !CatchUpPuller.hasPendingWrite(table: "reason_logs", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(ReasonLog.self, id: id) },
                   reconcileDeletes: true),

        DeltaTable(name: "collections", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(CollectionRow.self, from: raw) else { return .failed }
                       guard !CatchUpPuller.hasPendingWrite(table: "collections", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       // members/myRole are client-only and the server row
                       // carries neither — preserve them (realtime mirror parity).
                       // catchUp re-reads them right after this table's pull
                       // (`refreshCollections`), which also gives a newly
                       // visible foreign list its real myRole (audit 2026-09-22, C8).
                       var merged = row.model()
                       let existing = try? db.fetchById(ItemCollection.self, id: merged.id)
                       merged.members = existing?.members ?? []
                       merged.myRole = existing?.myRole
                       guard (try? db.save(merged)) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(ItemCollection.self, id: id) },
                   reconcileDeletes: true),

        DeltaTable(name: "tags", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(TagDbRow.self, from: raw) else { return .failed }
                       guard !CatchUpPuller.hasPendingWrite(table: "tags", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(TagRow.self, id: id) },
                   reconcileDeletes: true),

        DeltaTable(name: "life_areas", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(LifeAreaDbRow.self, from: raw) else { return .failed }
                       guard !CatchUpPuller.hasPendingWrite(table: "life_areas", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(LifeArea.self, id: id) },
                   reconcileDeletes: true),

        // profile_facts are soft-deleted (`active=false` tombstones) so a
        // missing id never means "deleted" — no reconcile pass.
        DeltaTable(name: "profile_facts", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(ProfileFactRow.self, from: raw) else { return .failed }
                       guard RealtimeMirror.incomingProfileFactWins(row, db: db) else { return .skippedPendingLocalWrite }
                       guard !CatchUpPuller.hasPendingWrite(table: "profile_facts", rowId: row.id, db: db) else {
                           return .skippedPendingLocalWrite
                       }
                       guard (try? db.save(row.model())) != nil else { return .failed }
                       return .applied
                   },
                   delete: { _, _ in },
                   reconcileDeletes: false),

        // call_requests: direct writes only (no outbox op to guard), a touch
        // trigger on `updated_at` (migration 051) so every status change the
        // dispatcher / call-outcome makes is a delta row, and a 30-day prune
        // of finished rows the id-reconcile mirrors. LWW keeps a stale page
        // from rewinding a row a realtime echo already advanced.
        DeltaTable(name: "call_requests", column: "updated_at",
                   apply: { raw, db in
                       guard let row = try? JSONDecoder().decode(CallRequest.self, from: raw) else { return .failed }
                       guard (try? db.writer.write({ conn -> Bool in
                           guard CallRequestsMirror.incomingWins(row, in: conn) else { return false }
                           try row.upsert(conn)
                           return true
                       })) != nil else { return .failed }
                       return .applied
                   },
                   delete: { id, db in try? db.deleteById(CallRequest.self, id: id) },
                   reconcileDeletes: true),
    ]

    /// Table names the cursor pull covers (diagnostics + tests).
    public static var deltaTableNames: [String] { deltaTables.map(\.name) }
}
