// WriteThrough — optimistic local write + enqueue a server outbox op.
// The local GRDB write makes the UI update immediately; the OutboxFlusher
// drains the op to Supabase (FIFO, dependency-ordered). cal_block upserts
// carry `dependsOn = task.id` so the parent task flushes first (avoids a
// foreign-key violation), mirroring the web bridge's awaitPendingUpsert.

import Foundation
import UnstuckCore
import UnstuckData

public actor WriteThrough {
    private let db: AppDatabase
    private let box: OutboxStore
    private let encoder = JSONEncoder()

    public init(db: AppDatabase) {
        self.db = db
        self.box = OutboxStore(db)
    }

    private func jsonString<R: Encodable>(_ r: R) throws -> String {
        String(data: try encoder.encode(r), encoding: .utf8) ?? "{}"
    }

    public func upsertTask(_ t: TaskItem, nowISO: String) throws {
        try db.save(t)
        try box.enqueue(table: "tasks", rowId: t.id, kind: .upsert, payload: try jsonString(TaskRow(t)), nowISO: nowISO)
    }

    public func upsertCalBlock(_ b: CalBlock, nowISO: String) throws {
        try db.save(b)
        let dependsOn = b.taskId.flatMap { isUUID($0) ? $0 : nil }   // wait for the parent task op
        try box.enqueue(table: "cal_blocks", rowId: b.id, kind: .upsert,
                        payload: try jsonString(CalBlockRow(b)), dependsOn: dependsOn, nowISO: nowISO)
    }

    public func upsertSession(_ s: Session, nowISO: String) throws {
        try db.save(s)
        try box.enqueue(table: "sessions", rowId: s.id, kind: .upsert, payload: try jsonString(SessionRow(s)), nowISO: nowISO)
    }

    public func upsertCapture(_ c: Capture, nowISO: String) throws {
        try db.save(c)
        try box.enqueue(table: "captures", rowId: c.id, kind: .upsert, payload: try jsonString(CaptureRow(c)), nowISO: nowISO)
    }

    public func upsertReasonLog(_ r: ReasonLog, nowISO: String) throws {
        try db.save(r)
        try box.enqueue(table: "reason_logs", rowId: r.id, kind: .upsert, payload: try jsonString(ReasonLogRow(r)), nowISO: nowISO)
    }

    public func upsertCollection(_ c: ItemCollection, nowISO: String) throws {
        try db.save(c)
        try box.enqueue(table: "collections", rowId: c.id, kind: .upsert, payload: try jsonString(CollectionRow(c)), nowISO: nowISO)
    }

    public func upsertTag(_ t: TagRow, nowISO: String) throws {
        try db.save(t)
        try box.enqueue(table: "tags", rowId: t.id, kind: .upsert, payload: try jsonString(TagDbRow(t)), nowISO: nowISO)
    }

    public func upsertLifeArea(_ a: LifeArea, nowISO: String) throws {
        try db.save(a)
        try box.enqueue(table: "life_areas", rowId: a.id, kind: .upsert, payload: try jsonString(LifeAreaDbRow(a)), nowISO: nowISO)
    }

    /// Local delete + enqueue a server delete. The caller is responsible
    /// for the local-row removal of the right type; this records intent.
    public func enqueueDelete(table: String, id: String, nowISO: String) throws {
        try box.enqueue(table: table, rowId: id, kind: .delete, nowISO: nowISO)
    }

    /// Delete a cal_block locally + enqueue the server delete (used by the
    /// recurrence regen to drop mismatched future occurrences).
    public func deleteCalBlock(id: String, nowISO: String) throws {
        try db.deleteById(CalBlock.self, id: id)
        try box.enqueue(table: "cal_blocks", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteTask(id: String, nowISO: String) throws {
        try db.deleteById(TaskItem.self, id: id)
        try box.enqueue(table: "tasks", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteTag(id: String, nowISO: String) throws {
        try db.deleteById(TagRow.self, id: id)
        try box.enqueue(table: "tags", rowId: id, kind: .delete, nowISO: nowISO)
    }

    public func deleteLifeArea(id: String, nowISO: String) throws {
        try db.deleteById(LifeArea.self, id: id)
        try box.enqueue(table: "life_areas", rowId: id, kind: .delete, nowISO: nowISO)
    }
}
