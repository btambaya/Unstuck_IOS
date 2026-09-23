// WriteThrough — optimistic local write + enqueue a server outbox op.
// The local GRDB write makes the UI update immediately; the OutboxFlusher
// drains the op to Supabase (FIFO, dependency-ordered). cal_block upserts
// carry `dependsOn = task.id` so the parent task flushes first (avoids a
// foreign-key violation), mirroring the web bridge's awaitPendingUpsert.
// External Google blocks (kind external / g_ ids) are NEVER enqueued
// (spec 02-sync-engine §1.6 — their id/shape isn't ours; the op would
// fail forever and wedge the outbox), and every delete cancels the row's
// still-queued upserts so a held-back upsert can't resurrect it (§1.8).
//
// Every row save and its outbox op commit in ONE GRDB transaction: with two
// transactions a kill between them left a local row with no op, which the
// next hydrate (server-canonical) silently deleted.

import Foundation
import GRDB
import UnstuckCore
import UnstuckData

public actor WriteThrough {
    private let db: AppDatabase
    private let box: OutboxStore
    private let encoder = JSONEncoder()
    // Fired after every enqueued op — the SyncCoordinator hooks this to
    // debounce a flush so mid-session edits reach the server without
    // waiting for the next auth event (spec 02-sync-engine §5).
    private var onEnqueue: (@Sendable () -> Void)?

    public init(db: AppDatabase) {
        self.db = db
        self.box = OutboxStore(db)
    }

    public func setOnEnqueue(_ hook: @escaping @Sendable () -> Void) {
        onEnqueue = hook
    }

    private func jsonString<R: Encodable>(_ r: R) throws -> String {
        String(data: try encoder.encode(r), encoding: .utf8) ?? "{}"
    }

    /// Row save + outbox op, atomically.
    private func saveAndEnqueue<R: PersistableRecord>(_ row: R, table: String, rowId: String, payload: String,
                                                      dependsOn: String? = nil, nowISO: String,
                                                      baseUpdatedAt: String? = nil, basePayload: String? = nil,
                                                      extra: ((Database) throws -> Void)? = nil) throws {
        try db.transaction { conn in
            try row.upsert(conn)
            try extra?(conn)
            try OutboxStore.enqueue(in: conn, table: table, rowId: rowId, kind: .upsert, payload: payload,
                                    dependsOn: dependsOn, nowISO: nowISO,
                                    baseUpdatedAt: baseUpdatedAt, basePayload: basePayload)
        }
        onEnqueue?()
    }

    /// Row delete + cancel its queued upserts + outbox delete op, atomically.
    private func deleteAndEnqueue<R: PersistableRecord & FetchableRecord>(_ type: R.Type, table: String, id: String,
                                                                           nowISO: String,
                                                                           extra: ((Database) throws -> Void)? = nil) throws {
        try db.transaction { conn in
            try Self.deleteAndEnqueue(in: conn, type, table: table, id: id, nowISO: nowISO, extra: extra)
        }
        onEnqueue?()
    }

    /// Same, on an OPEN connection — `deleteTask` removes a task and its
    /// children in one transaction.
    private static func deleteAndEnqueue<R: PersistableRecord & FetchableRecord>(in conn: Database, _ type: R.Type,
                                                                                  table: String, id: String, nowISO: String,
                                                                                  extra: ((Database) throws -> Void)? = nil) throws {
        _ = try type.deleteOne(conn, key: id)
        try extra?(conn)
        try OutboxStore.cancelPendingUpserts(in: conn, table: table, rowId: id)
        try OutboxStore.enqueue(in: conn, table: table, rowId: id, kind: .delete, nowISO: nowISO)
    }

    /// Tasks carry the BASE (the row as this device last saw it) on the op so
    /// the prune-before-flush can tell "the server moved underneath this edit"
    /// apart from device-clock skew, and 3-way merge instead of dropping.
    ///
    /// Every task write passes here, so the estimate is clamped to the server's
    /// `estimate_min between 1 and 1440` CHECK first. A row outside it is
    /// refused on every flush and quarantined, and as the FK parent it held all
    /// of the task's blocks back behind it; build 80 only clamped two assistant
    /// tools (audit 2026-09-22, C4). The fresh op supersedes a quarantined one
    /// for the row (dropQuarantinedUpserts).
    public func upsertTask(_ t: TaskItem, nowISO: String) throws {
        var t = t
        t.estimateMin = clampEstimateMin(t.estimateMin)
        let payload = try jsonString(TaskRow(t))
        try db.transaction { conn in
            let existing = try TaskItem.fetchOne(conn, key: t.id)
            let basePayload = try existing.map { try jsonString(TaskRow($0)) }
            try t.upsert(conn)
            try OutboxStore.dropQuarantinedUpserts(in: conn, table: "tasks", rowId: t.id)
            try OutboxStore.enqueue(in: conn, table: "tasks", rowId: t.id, kind: .upsert, payload: payload,
                                    nowISO: nowISO, baseUpdatedAt: existing?.updatedAt, basePayload: basePayload)
        }
        onEnqueue?()
    }

    public func upsertCalBlock(_ b: CalBlock, nowISO: String) throws {
        // External Google events (g_ ids) are mirrored read-only — never push
        // them to our cal_blocks table (the row id/shape isn't ours; it would
        // fail forever and wedge the outbox). Spec 02-sync-engine §1.6.
        if b.kind == .external || b.id.hasPrefix("g_") {
            try db.save(b)
            return
        }
        // `duration_minutes between 5 and 1440` (migration 001): the local row
        // and the op both carry what the server accepts. scheduleTaskAt, the
        // assistant's scheduleTask / update_task and whole-row re-saves of a
        // block stored before this fix all wrote the raw estimate, and a
        // refused block was quarantined and lived on this phone only (audit
        // 2026-09-22, C4). Google mirrors keep their real length (above).
        var b = b
        b.durationMinutes = clampDurationMin(b.durationMinutes)
        let dependsOn = b.taskId.flatMap { isUUID($0) ? $0 : nil }   // wait for the parent task op
        let id = b.id
        try db.transaction { conn in
            // The Google mapping belongs to the stamp (`stampCalBlockMapping`):
            // every other save carries the row's CURRENT mapping. A save built
            // from a copy read before a stamp landed — a series edit's
            // rewrites, a Schedule, an assistant move, all computed from a
            // snapshot while the Google chain stamps minted days — nulled the
            // event id, and the push that followed INSERTed a second event
            // (stage 2 review). Read inside the write, so no stamp slips
            // between the read and the save.
            if let current = try CalBlock.fetchOne(conn, key: id) {
                b.externalEventId = current.externalEventId
                b.externalConnectionId = current.externalConnectionId
            }
            try b.upsert(conn)
            try OutboxStore.dropQuarantinedUpserts(in: conn, table: "cal_blocks", rowId: id)
            try OutboxStore.enqueue(in: conn, table: "cal_blocks", rowId: id, kind: .upsert,
                                    payload: try jsonString(CalBlockRow(b)), dependsOn: dependsOn, nowISO: nowISO)
        }
        onEnqueue?()
    }

    /// What a MINT did (`insertCalBlockIfAbsent`).
    public enum MintOutcome: Sendable, Equatable {
        /// The row was written and its insert queued.
        case inserted
        /// Rule H, applied locally (`retimeIfTaken` only): the id was already
        /// that day's OPEN occurrence at another time — typically minted by a
        /// top-up after the caller read the store. It now has the asked start
        /// and length (those two columns only), queued as `insert_or_retime`
        /// so the server makes the same conditional retime.
        case retimed
        /// That day's open occurrence already has the asked start and length:
        /// nothing to write.
        case alreadyThere
        /// Rule A: the id lives on as a row that is NOT that day's open
        /// occurrence (moved, done or skipped), or any row holds it and this is
        /// a maintenance mint (a top-up never moves a row). Also a maintenance
        /// mint whose task is no longer in this store (deleted). Nothing written.
        case held

        /// The day now has the asked occurrence (whatever was written).
        public var landed: Bool { self != .held }
        /// An insert-family op was queued for the row.
        public var queued: Bool { self == .inserted || self == .retimed }
    }

    /// A MINT: a repeating task's occurrence created with its deterministic id
    /// (`occurrenceId`, audit 2026-09-22 C21, stage 2). Insert-if-absent end to
    /// end — rule A of deterministic-occurrence-ids.md:
    ///  • locally it never overwrites a row with that id: a moved, done, skipped
    ///    or kept occurrence lives on (`.held`). The check, the row save and the
    ///    op commit in ONE transaction, so two back-to-back top-ups that read
    ///    the store before either wrote can't both enqueue it;
    ///  • on the server the op is `INSERT … ON CONFLICT (id) DO NOTHING`
    ///    (`insert`), plus rule H's conditional retime when the USER asked for
    ///    this day (`retimeIfTaken` → `insert_or_retime`).
    /// A user's mint (`retimeIfTaken`) whose id is already that day's OPEN
    /// occurrence gets rule H here too (`.retimed`): the planner would have
    /// retimed that row had it seen it, and skipping silently dropped the
    /// user's time on every device, since no op reached the server to apply
    /// rule H (stage 2 review).
    /// Otherwise exactly `upsertCalBlock`: the duration clamp, `dependsOn` the
    /// parent task, and a g_ / external row is never enqueued.
    @discardableResult
    public func insertCalBlockIfAbsent(_ b: CalBlock, retimeIfTaken: Bool, nowISO: String) throws -> MintOutcome {
        if b.kind == .external || b.id.hasPrefix("g_") {
            return try db.transaction { conn -> MintOutcome in
                guard try CalBlock.fetchOne(conn, key: b.id) == nil else { return .held }
                try b.upsert(conn)
                return .inserted
            }
        }
        var b = b
        b.durationMinutes = clampDurationMin(b.durationMinutes)
        let dependsOn = b.taskId.flatMap { isUUID($0) ? $0 : nil }
        let row = b
        let outcome = try db.transaction { conn -> MintOutcome in
            // A maintenance mint extends a series this store holds, so a task
            // that is gone was deleted while the run was in flight. The top-up
            // reads its templates once and then mints a day at a time: a
            // Delete landing between two mints (or another device's, by
            // realtime) left the task's remaining days minted after the
            // cascade, each insert waiting forever on a parent that will never
            // be here again and kept by every hydrate: a ghost block, and an
            // outbox that never drains (audit 2026-09-22, C23). A user's mint
            // is not refused: a new repeating task's own save can still be on
            // its way (NewTaskSheet queues both), and the flusher holds the
            // insert until the task lands.
            if !retimeIfTaken, let parent = dependsOn, try TaskItem.fetchOne(conn, key: parent) == nil {
                return .held
            }
            if var held = try CalBlock.fetchOne(conn, key: row.id) {
                guard retimeIfTaken, held.date == row.date, !held.done, !held.skipped else { return .held }
                if held.startTime == row.startTime && held.durationMinutes == row.durationMinutes { return .alreadyThere }
                held.startTime = row.startTime
                held.durationMinutes = row.durationMinutes
                try held.upsert(conn)
                try OutboxStore.dropQuarantinedUpserts(in: conn, table: "cal_blocks", rowId: held.id)
                try OutboxStore.enqueue(in: conn, table: "cal_blocks", rowId: held.id, kind: .insertOrRetime,
                                        payload: try jsonString(CalBlockRow(held)), dependsOn: dependsOn, nowISO: nowISO)
                return .retimed
            }
            try row.upsert(conn)
            try OutboxStore.enqueue(in: conn, table: "cal_blocks", rowId: row.id,
                                    kind: retimeIfTaken ? .insertOrRetime : .insert,
                                    payload: try jsonString(CalBlockRow(row)), dependsOn: dependsOn, nowISO: nowISO)
            return .inserted
        }
        if outcome.queued { onEnqueue?() }
        return outcome
    }

    /// What `stampCalBlockMapping` did.
    public enum MappingStamp: Sendable, Equatable {
        case stamped
        /// The row already carries that mapping.
        case unchanged
        /// The row is gone (deleted while the Google call ran).
        case gone
        /// The row has an unresolved insert-family op — it was deleted and
        /// minted again, or a user mint retimed it, during the Google call.
        /// Rule G: nothing is written; the event belongs to the insert's
        /// outcome, which mirrors the row itself once confirmed.
        case insertUnresolved
    }

    /// The Google push's write-back: the new event id and connection go onto
    /// the row as it is NOW, in one transaction — the two mapping columns
    /// only, never the pushed copy (an edit made during the Google call
    /// survives). Queued as a plain upsert of that current row.
    @discardableResult
    public func stampCalBlockMapping(id: String, eventId: String, connectionId: String,
                                     nowISO: String) throws -> MappingStamp {
        let result = try db.transaction { conn -> MappingStamp in
            guard var row = try CalBlock.fetchOne(conn, key: id) else { return .gone }
            guard row.kind != .external, !id.hasPrefix("g_") else { return .unchanged }
            if try OutboxStore.hasInsertFamilyOp(in: conn, table: "cal_blocks", rowId: id) { return .insertUnresolved }
            guard row.externalEventId != eventId || row.externalConnectionId != connectionId else { return .unchanged }
            row.externalEventId = eventId
            row.externalConnectionId = connectionId
            row.durationMinutes = clampDurationMin(row.durationMinutes)
            try row.upsert(conn)
            try OutboxStore.dropQuarantinedUpserts(in: conn, table: "cal_blocks", rowId: id)
            try OutboxStore.enqueue(in: conn, table: "cal_blocks", rowId: id, kind: .upsert,
                                    payload: try jsonString(CalBlockRow(row)),
                                    dependsOn: row.taskId.flatMap { isUUID($0) ? $0 : nil }, nowISO: nowISO)
            return .stamped
        }
        if result == .stamped { onEnqueue?() }
        return result
    }

    public func upsertSession(_ s: Session, nowISO: String) throws {
        try saveAndEnqueue(s, table: "sessions", rowId: s.id, payload: try jsonString(SessionRow(s)), nowISO: nowISO)
    }

    /// The capture row travels with its CURRENT archive state (`archived_at`,
    /// migration 053) so a re-save can't un-archive it server-side.
    public func upsertCapture(_ c: Capture, nowISO: String) throws {
        // The row here and the op both carry what the server accepts (4096
        // characters): every capture path writes through here (C28).
        var c = c
        c.body = clampCaptureBody(c.body)
        try db.transaction { conn in
            let archivedAt = try String.fetchOne(conn, sql: "SELECT archivedAt FROM capture_archive WHERE captureId = ?", arguments: [c.id])
            try c.upsert(conn)
            // Wait for the parent session row to flush first — a capture taken DURING
            // a session references a session_id (FK) whose `sessions` row is only
            // written at session end. The OutboxFlusher holds a dependsOn op while the
            // parent has a pending op OR doesn't exist locally yet (the live-session
            // case), so the capture can't push ahead, hit the FK, and be quarantined.
            let dependsOn = c.sessionId.flatMap { isUUID($0) ? $0 : nil }
            try OutboxStore.enqueue(in: conn, table: "captures", rowId: c.id, kind: .upsert,
                                    payload: try jsonString(CaptureRow(c, archivedAt: archivedAt)),
                                    dependsOn: dependsOn, nowISO: nowISO)
        }
        onEnqueue?()
    }

    /// Archive / restore a capture (Inbox "Done" / "Restore"): the local
    /// archive table + a captures upsert carrying `archived_at` (server truth,
    /// migration 053). Returns false — with NO op enqueued — when the capture
    /// row doesn't exist locally (deleted meanwhile): an upsert would resurrect
    /// it server-side, and the caller shouldn't report success.
    @discardableResult
    public func setCaptureArchived(id: String, archivedAt: String?, nowISO: String) throws -> Bool {
        let wrote = try db.transaction { conn -> Bool in
            guard let c = try Capture.fetchOne(conn, key: id) else {
                try AppDatabase.setCaptureArchived(in: conn, id: id, archivedAt: nil)
                return false
            }
            try AppDatabase.setCaptureArchived(in: conn, id: id, archivedAt: archivedAt)
            let dependsOn = c.sessionId.flatMap { isUUID($0) ? $0 : nil }
            try OutboxStore.cancelPendingUpserts(in: conn, table: "captures", rowId: id)
            try OutboxStore.enqueue(in: conn, table: "captures", rowId: id, kind: .upsert,
                                    payload: try jsonString(CaptureRow(c, archivedAt: archivedAt)),
                                    dependsOn: dependsOn, nowISO: nowISO)
            return true
        }
        if wrote { onEnqueue?() }
        return wrote
    }

    public func upsertReasonLog(_ r: ReasonLog, nowISO: String) throws {
        try saveAndEnqueue(r, table: "reason_logs", rowId: r.id, payload: try jsonString(ReasonLogRow(r)), nowISO: nowISO)
    }

    public func upsertCollection(_ c: ItemCollection, nowISO: String) throws {
        try saveAndEnqueue(c, table: "collections", rowId: c.id, payload: try jsonString(CollectionRow(c)), nowISO: nowISO)
    }

    /// A SHARED collection's item mutation: the optimistic local row (already
    /// transformed) + an `rpc` outbox op carrying the atomic server-side
    /// mutation, in ONE transaction — so it is retried offline like every
    /// other edit instead of the old fire-and-forget RPC whose failure left
    /// the optimistic row to be silently deleted by the next echo/hydrate.
    /// Ordered per row by the outbox seq (replaces the per-collection chain).
    public func applyCollectionRPC(_ c: ItemCollection, rpc: CollectionRPC, nowISO: String) throws {
        let payload = try OutboxRPCPayload(fn: rpc.fn, paramsJSON: rpc.paramsJSON).encoded()
        try db.transaction { conn in
            try c.upsert(conn)
            try OutboxStore.enqueue(in: conn, table: "collections", rowId: c.id, kind: .rpc,
                                    payload: payload, nowISO: nowISO)
        }
        onEnqueue?()
    }

    /// Synchronous variant for callers that must have the row committed
    /// BEFORE returning without an actor hop (the assistant's `create_list`,
    /// whose protocol is synchronous — a later tool in the same turn reads
    /// the row straight back). Same single transaction; the flush kick is
    /// the caller's job (`SyncCoordinator.flushNow`).
    nonisolated public func upsertCollectionSync(_ c: ItemCollection, nowISO: String) throws {
        let payload = String(data: try JSONEncoder().encode(CollectionRow(c)), encoding: .utf8) ?? "{}"
        try db.transaction { conn in
            try c.upsert(conn)
            try OutboxStore.enqueue(in: conn, table: "collections", rowId: c.id, kind: .upsert, payload: payload, nowISO: nowISO)
        }
    }

    public func upsertTag(_ t: TagRow, nowISO: String) throws {
        try saveAndEnqueue(t, table: "tags", rowId: t.id, payload: try jsonString(TagDbRow(t)), nowISO: nowISO)
    }

    public func upsertLifeArea(_ a: LifeArea, nowISO: String) throws {
        try saveAndEnqueue(a, table: "life_areas", rowId: a.id, payload: try jsonString(LifeAreaDbRow(a)), nowISO: nowISO)
    }

    /// Optimistic local save of a profile fact + push (see pushProfileFact).
    public func upsertProfileFact(_ f: ProfileFact, nowISO: String) throws {
        try db.transaction { conn in
            try f.upsert(conn)
            try ProfileFactPush.enqueue(f, in: conn, nowISO: nowISO)
        }
        onEnqueue?()
    }

    /// Enqueue the CURRENT local `profile_facts` row for upsert (the row is
    /// already written by ProfileFactsService / the repository). Reads the row
    /// back from GRDB and cancels any older queued upsert for it first, so two
    /// rapid saves of the same fact (a refine right after a save) converge on
    /// the latest local state server-side regardless of Task ordering. A soft
    /// delete is the same op with `active=false` — an upsert on `id` that
    /// tombstones the server row (the web does an UPDATE; the result is
    /// identical, and this also tombstones a row the server never received).
    public func pushProfileFact(id: String, nowISO: String) throws {
        let pushed = try db.transaction { conn -> Bool in
            guard let f = try ProfileFact.fetchOne(conn, key: id) else { return false }
            try ProfileFactPush.enqueue(f, in: conn, nowISO: nowISO)
            return true
        }
        if pushed { onEnqueue?() }
    }

    /// Local delete + enqueue a server delete. The caller is responsible
    /// for the local-row removal of the right type; this records intent.
    public func enqueueDelete(table: String, id: String, nowISO: String) throws {
        try db.transaction { conn in
            try OutboxStore.cancelPendingUpserts(in: conn, table: table, rowId: id)
            try OutboxStore.enqueue(in: conn, table: table, rowId: id, kind: .delete, nowISO: nowISO)
        }
        onEnqueue?()
    }

    /// Delete a cal_block locally + enqueue the server delete (used by the
    /// recurrence regen to drop mismatched future occurrences). External g_
    /// rows aren't ours — local delete only (spec §1.6); for our rows,
    /// cancel any still-queued upsert first: a cal_block upsert carries
    /// dependsOn=task.id, so it can be held back while the delete (no
    /// dependsOn) flushes ahead of it — which would re-create the block
    /// server-side AFTER the delete (spec §1.8).
    public func deleteCalBlock(id: String, nowISO: String) throws {
        guard !id.hasPrefix("g_") else {
            try db.deleteById(CalBlock.self, id: id)
            return
        }
        try deleteAndEnqueue(CalBlock.self, table: "cal_blocks", id: id, nowISO: nowISO)
    }

    /// A task goes with its blocks and captures, in ONE transaction (audit
    /// 2026-09-22, C23). The local store has no FK cascade, so deleting the
    /// tasks row alone left its cal_blocks behind: their reminders stayed
    /// armed for a deleted task, and a block op still queued (scheduled or
    /// minted offline) waited forever on a parent that would never exist
    /// locally again, so the hydrate kept that block on this phone for good.
    /// The server cascades cal_blocks and only nulls captures.task_id; the web
    /// and the assistant delete both first, and the editor's dialog promises
    /// it. Each child's queued upsert or insert is cancelled and its delete
    /// queued BEFORE the task's, the order they send in; a delete of a row
    /// the server never received is a no-op there. Returns the removed
    /// blocks: their Google events and armed reminders are the app's to clear.
    @discardableResult
    public func deleteTask(id: String, nowISO: String) throws -> [CalBlock] {
        let blocks = try db.transaction { conn -> [CalBlock] in
            let blocks = try CalBlock.filter(Column("taskId") == id).fetchAll(conn)
            for b in blocks {
                // External g_ rows aren't ours: local delete only (deleteCalBlock).
                if b.id.hasPrefix("g_") {
                    _ = try CalBlock.deleteOne(conn, key: b.id)
                } else {
                    try Self.deleteAndEnqueue(in: conn, CalBlock.self, table: "cal_blocks", id: b.id, nowISO: nowISO)
                }
            }
            for c in try Capture.filter(Column("taskId") == id).fetchAll(conn) {
                // A deleted capture takes its archive state with it (deleteCapture).
                try Self.deleteAndEnqueue(in: conn, Capture.self, table: "captures", id: c.id, nowISO: nowISO) {
                    try AppDatabase.setCaptureArchived(in: $0, id: c.id, archivedAt: nil)
                }
            }
            try Self.deleteAndEnqueue(in: conn, TaskItem.self, table: "tasks", id: id, nowISO: nowISO)
            return blocks
        }
        onEnqueue?()
        return blocks
    }

    public func deleteTag(id: String, nowISO: String) throws {
        try deleteAndEnqueue(TagRow.self, table: "tags", id: id, nowISO: nowISO)
    }

    public func deleteLifeArea(id: String, nowISO: String) throws {
        try deleteAndEnqueue(LifeArea.self, table: "life_areas", id: id, nowISO: nowISO)
    }

    public func deleteCollection(id: String, nowISO: String) throws {
        try deleteAndEnqueue(ItemCollection.self, table: "collections", id: id, nowISO: nowISO)
    }

    public func deleteSession(id: String, nowISO: String) throws {
        try deleteAndEnqueue(Session.self, table: "sessions", id: id, nowISO: nowISO)
    }

    /// A deleted capture takes its archive state with it.
    public func deleteCapture(id: String, nowISO: String) throws {
        try deleteAndEnqueue(Capture.self, table: "captures", id: id, nowISO: nowISO) { conn in
            try AppDatabase.setCaptureArchived(in: conn, id: id, archivedAt: nil)
        }
    }

    public func deleteReasonLog(id: String, nowISO: String) throws {
        try deleteAndEnqueue(ReasonLog.self, table: "reason_logs", id: id, nowISO: nowISO)
    }
}
