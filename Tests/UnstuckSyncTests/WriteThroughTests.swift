// WriteThrough — every optimistic write commits the row AND its outbox op in
// ONE GRDB transaction (a kill between two transactions left a local row
// with no op, which the next server-canonical hydrate silently deleted), task
// ops carry the BASE they were edited on top of (the prune's skew-proof
// conflict detection), and the capture archive rides on the capture row as
// `archived_at` (migration 053).

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

final class WriteThroughTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private var write: WriteThrough!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
        write = WriteThrough(db: db)
    }

    private func decodeTask(_ op: OutboxOp) throws -> TaskRow {
        try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(op.payload?.data(using: .utf8)))
    }

    func testTaskUpsertCommitsRowAndOpTogetherAndRecordsTheBase() async throws {
        let v1 = TaskItem(id: "t1", name: "first", estimateMin: 25, createdAt: now, updatedAt: "2026-05-21T10:00:00.000Z")
        try await write.upsertTask(v1, nowISO: now)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "first")
        var ops = try box.pending()
        XCTAssertEqual(ops.count, 1)
        XCTAssertNil(ops[0].baseUpdatedAt, "a brand-new row has no base")

        // A hydrate / realtime echo stamps the local row with the SERVER's time…
        var synced = v1
        synced.updatedAt = "2026-05-21T10:00:05.123456+00:00"
        try db.save(synced)
        // …and the next edit is based on exactly that.
        var v2 = synced
        v2.name = "second"
        v2.updatedAt = "2026-05-21T10:01:00.000Z"
        try await write.upsertTask(v2, nowISO: now)
        ops = try box.pending()
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[1].baseUpdatedAt, "2026-05-21T10:00:05.123456+00:00")
        let base = try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(ops[1].basePayload?.data(using: .utf8)))
        XCTAssertEqual(base.name, "first", "the base is the row as this device last saw it")
        XCTAssertEqual(try decodeTask(ops[1]).name, "second")
    }

    /// Every writer is covered at the choke point: the local row, the op and
    /// its base all hold what the server's CHECKs accept (audit 2026-09-22, C4).
    func testEstimatesAndDurationsAreClampedToTheServerChecksOnTheRowAndTheOp() async throws {
        let tid = "11111111-1111-4111-8111-111111111111"
        try await write.upsertTask(TaskItem(id: tid, name: "Huge", estimateMin: 2000, createdAt: now, updatedAt: now), nowISO: now)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: tid)?.estimateMin, 1440)
        XCTAssertEqual(try decodeTask(XCTUnwrap(box.pending().last)).estimateMin, 1440)
        try await write.upsertTask(TaskItem(id: "t0", name: "Zero", estimateMin: 0, createdAt: now, updatedAt: now), nowISO: now)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t0")?.estimateMin, 1)
        try await write.upsertTask(TaskItem(id: "t2", name: "Meds", estimateMin: 2, createdAt: now, updatedAt: now), nowISO: now)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t2")?.estimateMin, 2, "a 1-4 minute estimate is legal")

        let bid = "22222222-2222-4222-8222-222222222222"
        try await write.upsertCalBlock(CalBlock(id: bid, taskId: tid, taskName: "Meds", startTime: "08:00",
                                                durationMinutes: 2, date: "2026-05-21", kind: .task), nowISO: now)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: bid)?.durationMinutes, 5)
        let op = try XCTUnwrap(box.pending().last)
        XCTAssertEqual(op.dependsOn, tid)
        XCTAssertTrue(try XCTUnwrap(op.payload).contains("\"duration_minutes\":5"))
        try await write.upsertCalBlock(CalBlock(id: bid, taskId: tid, taskName: "Meds", startTime: "08:00",
                                                durationMinutes: 5000, date: "2026-05-21", kind: .task), nowISO: now)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: bid)?.durationMinutes, 1440)
        try await write.upsertCalBlock(CalBlock(id: bid, taskId: tid, taskName: "Meds", startTime: "08:00",
                                                durationMinutes: 25, date: "2026-05-21", kind: .task), nowISO: now)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: bid)?.durationMinutes, 25)

        // A Google mirror keeps its real length and is never enqueued.
        let before = try box.count()
        try await write.upsertCalBlock(CalBlock(id: "g_evt", taskId: nil, taskName: "Standup", startTime: "09:00",
                                                durationMinutes: 2, date: "2026-05-21", kind: .external), nowISO: now)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: "g_evt")?.durationMinutes, 2)
        XCTAssertEqual(try box.count(), before)

        // A row stored before this fix: its next whole-row re-save (Mark done)
        // lands in range, and the base carries no phantom estimate diff.
        try db.save(TaskItem(id: "legacy", name: "Old", estimateMin: 2000, createdAt: now, updatedAt: now))
        try await write.upsertTask(TaskItem(id: "legacy", name: "Old", estimateMin: 2000, done: true, createdAt: now, updatedAt: now), nowISO: now)
        let legacy = try XCTUnwrap(box.pending().last)
        XCTAssertEqual(try decodeTask(legacy).estimateMin, 1440)
        let base = try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(legacy.basePayload?.data(using: .utf8)))
        XCTAssertEqual(base.estimateMin, 1440)
    }

    /// A fresh whole-row write supersedes the row's QUARANTINED upsert: kept,
    /// it pinned the row against every hydrate and held the task's blocks back
    /// (audit 2026-09-22, C4). Deleting it never re-sends stale bytes.
    func testAFreshWriteSupersedesAQuarantinedOpForTheSameRow() async throws {
        let tid = "11111111-1111-4111-8111-111111111111"
        let bid = "22222222-2222-4222-8222-222222222222"
        func quarantine(_ op: OutboxOp) throws {
            for _ in 0..<OutboxStore.quarantineCap { try box.bumpAttempts(XCTUnwrap(op.opSeq)) }
        }
        let block = CalBlock(id: bid, taskId: tid, taskName: "Meds", startTime: "08:00", durationMinutes: 25,
                             date: "2026-05-21", kind: .task)
        try quarantine(box.enqueue(table: "cal_blocks", rowId: bid, kind: .upsert, payload: "{}", nowISO: now))
        try await write.upsertCalBlock(block, nowISO: now)
        let forBlock = try box.pending().filter { $0.rowId == bid }
        XCTAssertEqual(forBlock.count, 1)
        XCTAssertEqual(forBlock.first?.attempts, 0, "only the fresh op is left")

        // A quarantined TASK op held the block op back; the next task write
        // replaces it, and once that flushes the block is free to go.
        try quarantine(box.enqueue(table: "tasks", rowId: tid, kind: .upsert, payload: "{}", nowISO: now))
        XCTAssertFalse(try box.nextFlushable().contains { $0.rowId == bid }, "held back behind the refused task op")
        try await write.upsertTask(TaskItem(id: tid, name: "Meds", estimateMin: 2, createdAt: now, updatedAt: now), nowISO: now)
        let taskOps = try box.pending().filter { $0.rowId == tid }
        XCTAssertEqual(taskOps.map(\.attempts), [0])
        try box.markDone(XCTUnwrap(taskOps.first?.opSeq))
        XCTAssertTrue(try box.nextFlushable().contains { $0.rowId == bid })
        XCTAssertTrue(try box.pending().allSatisfy { !$0.isQuarantined }, "nothing refused is left pinning a row")
    }

    func testDeleteCancelsQueuedUpsertsAndRemovesTheRowInOneGo() async throws {
        let t = TaskItem(id: "t1", name: "x", estimateMin: 25, createdAt: now, updatedAt: now)
        try await write.upsertTask(t, nowISO: now)
        try await write.deleteTask(id: "t1", nowISO: now)
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "t1"))
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.kind), [.delete], "the held-back upsert can't resurrect the row after the delete")
    }

    func testCaptureArchiveRidesOnTheCaptureRowAsArchivedAt() async throws {
        let c = Capture(id: "c1", taskId: nil, sessionId: nil, tag: .idea, body: "x", at: now)
        try await write.upsertCapture(c, nowISO: now)
        XCTAssertTrue(try XCTUnwrap(box.pending().last?.payload).contains("\"archived_at\":null"), "explicit null — open")

        let wrote = try await write.setCaptureArchived(id: "c1", archivedAt: "2026-05-21T11:00:00.000Z", nowISO: now)
        XCTAssertTrue(wrote)
        XCTAssertEqual(try db.captureArchivedAt(id: "c1"), "2026-05-21T11:00:00.000Z")
        var ops = try box.pending()
        XCTAssertEqual(ops.count, 1, "the archive replaces the queued capture upsert (same row, newer intent)")
        XCTAssertTrue(try XCTUnwrap(ops[0].payload).contains("\"archived_at\":\"2026-05-21T11:00:00.000Z\""))

        // A later re-save of the capture keeps it archived server-side.
        try await write.upsertCapture(c, nowISO: now)
        ops = try box.pending()
        XCTAssertTrue(try XCTUnwrap(ops.last?.payload).contains("\"archived_at\":\"2026-05-21T11:00:00.000Z\""))

        // Restore → explicit null reaches the server.
        let restored = try await write.setCaptureArchived(id: "c1", archivedAt: nil, nowISO: now)
        XCTAssertTrue(restored)
        XCTAssertNil(try db.captureArchivedAt(id: "c1"))
        XCTAssertTrue(try XCTUnwrap(box.pending().last?.payload).contains("\"archived_at\":null"))
    }

    func testArchivingAMissingCaptureIsAnHonestNoOp() async throws {
        let wrote = try await write.setCaptureArchived(id: "ghost", archivedAt: now, nowISO: now)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try box.count(), 0, "no upsert may resurrect a deleted capture server-side")
        XCTAssertNil(try db.captureArchivedAt(id: "ghost"))
    }

    func testDeletingACaptureTakesItsArchiveStateWithIt() async throws {
        let c = Capture(id: "c1", taskId: nil, sessionId: nil, tag: .idea, body: "x", at: now)
        try await write.upsertCapture(c, nowISO: now)
        _ = try await write.setCaptureArchived(id: "c1", archivedAt: now, nowISO: now)
        try await write.deleteCapture(id: "c1", nowISO: now)
        XCTAssertNil(try db.captureArchivedAt(id: "c1"))
        XCTAssertEqual(try box.pending().map(\.kind), [.delete])
    }

    func testCollectionSyncUpsertIsCommittedWhenItReturns() throws {
        let col = ItemCollection(id: "l1", name: "Fresh", color: "indigo", subtitle: nil, items: [], sortOrder: 0, archived: false)
        try write.upsertCollectionSync(col, nowISO: now)
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "l1")?.name, "Fresh")
        XCTAssertEqual(try box.pending().map(\.rowId), ["l1"])
    }
}
