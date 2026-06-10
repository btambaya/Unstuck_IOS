// WriteThrough — optimistic local write + enqueue a server outbox op.
// The local GRDB write makes the UI update immediately; the OutboxFlusher
// drains the op to Supabase (FIFO, dependency-ordered). cal_block upserts
// carry `dependsOn = task.id` so the parent task flushes first (avoids a
// foreign-key violation), mirroring the web bridge's awaitPendingUpsert.
// External Google blocks (kind external / g_ ids) are NEVER enqueued
// (spec 02-sync-engine §1.6 — their id/shape isn't ours; the op would
// fail forever and wedge the outbox), and every delete cancels the row's
// still-queued upserts so a held-back upsert can't resurrect it (§1.8).

import Foundation
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

    private func enqueue(table: String, rowId: String, kind: OutboxKind,
                         payload: String? = nil, dependsOn: String? = nil, nowISO: String) throws {
        try box.enqueue(table: table, rowId: rowId, kind: kind,
                        payload: payload, dependsOn: dependsOn, nowISO: nowISO)
        onEnqueue?()
    }

    private func jsonString<R: Encodable>(_ r: R) throws -> String {
        String(data: try encoder.encode(r), encoding: .utf8) ?? "{}"
    }

    public func upsertTask(_ t: TaskItem, nowISO: String) throws {
        try db.save(t)
        try enqueue(table: "tasks", rowId: t.id, kind: .upsert, payload: try jsonString(TaskRow(t)), nowISO: nowISO)
    }

    public func upsertCalBlock(_ b: CalBlock, nowISO: String) throws {
        try db.save(b)
        // External Google events (g_ ids) are mirrored read-only — never push
        // them to our cal_blocks table (the row id/shape isn't ours; it would
        // fail forever and wedge the outbox). Spec 02-sync-engine §1.6.
        if b.kind == .external || b.id.hasPrefix("g_") { return }
        let dependsOn = b.taskId.flatMap { isUUID($0) ? $0 : nil }   // wait for the parent task op
        try enqueue(table: "cal_blocks", rowId: b.id, kind: .upsert,
                    payload: try jsonString(CalBlockRow(b)), dependsOn: dependsOn, nowISO: nowISO)
    }

    public func upsertSession(_ s: Session, nowISO: String) throws {
        try db.save(s)
        try enqueue(table: "sessions", rowId: s.id, kind: .upsert, payload: try jsonString(SessionRow(s)), nowISO: nowISO)
    }

    public func upsertCapture(_ c: Capture, nowISO: String) throws {
        try db.save(c)
        // Wait for the parent session row to flush first — a capture taken DURING
        // a session references a session_id (FK) whose `sessions` row is only
        // written at session end. The OutboxFlusher holds a dependsOn op while the
        // parent has a pending op OR doesn't exist locally yet (the live-session
        // case), so the capture can't push ahead, hit the FK, and be poison-dropped.
        let dependsOn = c.sessionId.flatMap { isUUID($0) ? $0 : nil }
        try enqueue(table: "captures", rowId: c.id, kind: .upsert,
                    payload: try jsonString(CaptureRow(c)), dependsOn: dependsOn, nowISO: nowISO)
    }

    public func upsertReasonLog(_ r: ReasonLog, nowISO: String) throws {
        try db.save(r)
        try enqueue(table: "reason_logs", rowId: r.id, kind: .upsert, payload: try jsonString(ReasonLogRow(r)), nowISO: nowISO)
    }

    public func upsertCollection(_ c: ItemCollection, nowISO: String) throws {
        try db.save(c)
        try enqueue(table: "collections", rowId: c.id, kind: .upsert, payload: try jsonString(CollectionRow(c)), nowISO: nowISO)
    }

    public func upsertTag(_ t: TagRow, nowISO: String) throws {
        try db.save(t)
        try enqueue(table: "tags", rowId: t.id, kind: .upsert, payload: try jsonString(TagDbRow(t)), nowISO: nowISO)
    }

    public func upsertLifeArea(_ a: LifeArea, nowISO: String) throws {
        try db.save(a)
        try enqueue(table: "life_areas", rowId: a.id, kind: .upsert, payload: try jsonString(LifeAreaDbRow(a)), nowISO: nowISO)
    }

    /// Local delete + enqueue a server delete. The caller is responsible
    /// for the local-row removal of the right type; this records intent.
    public func enqueueDelete(table: String, id: String, nowISO: String) throws {
        try box.cancelPendingUpserts(table: table, rowId: id)
        try enqueue(table: table, rowId: id, kind: .delete, nowISO: nowISO)
    }

    /// Delete a cal_block locally + enqueue the server delete (used by the
    /// recurrence regen to drop mismatched future occurrences). External g_
    /// rows aren't ours — local delete only (spec §1.6); for our rows,
    /// cancel any still-queued upsert first: a cal_block upsert carries
    /// dependsOn=task.id, so it can be held back while the delete (no
    /// dependsOn) flushes ahead of it — which would re-create the block
    /// server-side AFTER the delete (spec §1.8).
    public func deleteCalBlock(id: String, nowISO: String) throws {
        try db.deleteById(CalBlock.self, id: id)
        guard !id.hasPrefix("g_") else { return }
        try box.cancelPendingUpserts(table: "cal_blocks", rowId: id)
        try enqueue(table: "cal_blocks", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteTask(id: String, nowISO: String) throws {
        try db.deleteById(TaskItem.self, id: id)
        try box.cancelPendingUpserts(table: "tasks", rowId: id)
        try enqueue(table: "tasks", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteTag(id: String, nowISO: String) throws {
        try db.deleteById(TagRow.self, id: id)
        try box.cancelPendingUpserts(table: "tags", rowId: id)
        try enqueue(table: "tags", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteLifeArea(id: String, nowISO: String) throws {
        try db.deleteById(LifeArea.self, id: id)
        try box.cancelPendingUpserts(table: "life_areas", rowId: id)
        try enqueue(table: "life_areas", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteCollection(id: String, nowISO: String) throws {
        try db.deleteById(ItemCollection.self, id: id)
        try box.cancelPendingUpserts(table: "collections", rowId: id)
        try enqueue(table: "collections", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteSession(id: String, nowISO: String) throws {
        try db.deleteById(Session.self, id: id)
        try box.cancelPendingUpserts(table: "sessions", rowId: id)
        try enqueue(table: "sessions", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteCapture(id: String, nowISO: String) throws {
        try db.deleteById(Capture.self, id: id)
        try box.cancelPendingUpserts(table: "captures", rowId: id)
        try enqueue(table: "captures", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteReasonLog(id: String, nowISO: String) throws {
        try db.deleteById(ReasonLog.self, id: id)
        try box.cancelPendingUpserts(table: "reason_logs", rowId: id)
        try enqueue(table: "reason_logs", rowId: id, kind: .delete, nowISO: nowISO)
    }
}
