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

    /// "Buy milk" created, scheduled and repeated offline, a capture taken on
    /// it, then deleted — all before the phone reconnects. The task's blocks
    /// and capture go in the same transaction; every queued upsert or insert
    /// for them is cancelled (they would wait forever on the missing parent,
    /// and the hydrate keeps a row with a queued op: a ghost block for good);
    /// the children's deletes queue BEFORE the task's. Another task's block
    /// is untouched (audit 2026-09-22, C23).
    func testDeletingATaskTakesItsBlocksAndCapturesWithItInOneGo() async throws {
        let tid = "33333333-3333-4333-8333-333333333333"
        let other = "44444444-4444-4444-8444-444444444444"
        try await write.upsertTask(TaskItem(id: tid, name: "Buy milk", estimateMin: 25, createdAt: now, updatedAt: now), nowISO: now)
        try await write.upsertTask(TaskItem(id: other, name: "Keep", estimateMin: 25, createdAt: now, updatedAt: now), nowISO: now)
        let scheduled = CalBlock(id: "55555555-5555-4555-8555-555555555555", taskId: tid, taskName: "Buy milk",
                                 startTime: "17:00", durationMinutes: 25, date: "2026-05-21", kind: .task)
        try await write.upsertCalBlock(scheduled, nowISO: now)
        let minted = CalBlock(id: occurrenceId(taskId: tid, date: "2026-05-22"), taskId: tid, taskName: "Buy milk",
                              startTime: "17:00", durationMinutes: 25, date: "2026-05-22", kind: .task)
        try await write.insertCalBlockIfAbsent(minted, retimeIfTaken: false, nowISO: now)
        let kept = CalBlock(id: "66666666-6666-4666-8666-666666666666", taskId: other, taskName: "Keep",
                            startTime: "09:00", durationMinutes: 25, date: "2026-05-21", kind: .task)
        try await write.upsertCalBlock(kept, nowISO: now)
        let capture = Capture(id: "c-milk", taskId: tid, sessionId: nil, tag: .idea, body: "semi-skimmed", at: now)
        try await write.upsertCapture(capture, nowISO: now)
        _ = try await write.setCaptureArchived(id: capture.id, archivedAt: now, nowISO: now)

        let removed = try await write.deleteTask(id: tid, nowISO: now)

        XCTAssertEqual(Set(removed.map(\.id)), [scheduled.id, minted.id], "the removed blocks, for the app's Google + reminder cleanup")
        XCTAssertNil(try db.fetchById(TaskItem.self, id: tid))
        XCTAssertEqual(try db.fetchAllCalBlocks().map(\.id), [kept.id], "no ghost block left on this phone")
        XCTAssertNil(try db.fetchById(Capture.self, id: capture.id))
        XCTAssertNil(try db.captureArchivedAt(id: capture.id))
        let ops = try box.pending()
        let gone = [scheduled.id, minted.id, capture.id, tid]
        XCTAssertTrue(ops.filter { gone.contains($0.rowId) }.allSatisfy { $0.kind == .delete },
                      "no upsert or insert left to re-create a row, or to wait on the missing parent")
        let deletes = ops.filter { $0.kind == .delete }.map(\.tableName)
        XCTAssertEqual(deletes, ["cal_blocks", "cal_blocks", "captures", "tasks"], "the children go before the task")
        XCTAssertEqual(ops.filter { $0.rowId == kept.id }.map(\.kind), [.upsert], "another task's block is untouched")
        let flushable = try box.nextFlushable().map(\.rowId)
        XCTAssertTrue(Set(gone).isSubset(of: Set(flushable)), "nothing of the deleted task is held back")
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

    // MARK: - insert-if-absent (stage 2, deterministic-occurrence-ids.md rule A)

    private let seriesId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
    private func mint(_ date: String, _ time: String = "07:00") -> CalBlock {
        CalBlock(id: occurrenceId(taskId: seriesId, date: date), taskId: seriesId, taskName: "Gym",
                 startTime: time, durationMinutes: 30, date: date, kind: .task)
    }
    /// The series' template, where a top-up reads it: a maintenance mint
    /// needs its task in the store (C23).
    private func saveSeries() throws {
        try db.save(TaskItem(id: seriesId, name: "Gym", estimateMin: 30, recurrence: .daily(until: nil),
                             createdAt: now, updatedAt: now))
    }

    /// A row with the id already exists locally (moved, done, kept — any
    /// state): the mint is skipped. No row write, no op.
    func testInsertIfAbsentSkipsAnExistingRow() async throws {
        var moved = mint("2026-09-24")
        moved.date = "2026-09-26"   // the day's occurrence, moved two days on
        moved.done = true
        try db.save(moved)
        let wrote = try await write.insertCalBlockIfAbsent(mint("2026-09-24", "09:00"), retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(wrote, .held)
        XCTAssertEqual(try box.count(), 0, "no op for a skipped mint")
        let row = try XCTUnwrap(db.fetchById(CalBlock.self, id: moved.id))
        XCTAssertEqual(row.date, "2026-09-26", "the moved occurrence is never pulled back")
        XCTAssertEqual(row.startTime, "07:00")
        XCTAssertTrue(row.done)
    }

    /// A fresh mint writes the row (clamped) and queues the requested kind,
    /// waiting on the parent task like every block op.
    func testInsertIfAbsentEnqueuesTheRequestedKind() async throws {
        try saveSeries()
        var short = mint("2026-09-24")
        short.durationMinutes = 2
        let r1 = try await write.insertCalBlockIfAbsent(short, retimeIfTaken: false, nowISO: now)
        XCTAssertEqual(r1, .inserted)
        let r2 = try await write.insertCalBlockIfAbsent(mint("2026-09-25"), retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(r2, .inserted)
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.kind), [.insert, .insertOrRetime])
        XCTAssertEqual(ops.map(\.kind.rawValue), ["insert", "insert_or_retime"], "the stored text every platform shares")
        XCTAssertEqual(ops.map(\.dependsOn), [seriesId, seriesId])
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: short.id)?.durationMinutes, 5, "clamped like an upsert")
        XCTAssertTrue(try XCTUnwrap(ops[0].payload).contains("\"duration_minutes\":5"))
        // A second mint of the same day (a back-to-back top-up) queues nothing.
        let r3 = try await write.insertCalBlockIfAbsent(mint("2026-09-24"), retimeIfTaken: false, nowISO: now)
        XCTAssertEqual(r3, .held)
        XCTAssertEqual(try box.count(), 2)
        // A Google g_ row is never enqueued, insert or not.
        let g = CalBlock(id: "g_evt", taskId: nil, taskName: "Meeting", startTime: "10:00", durationMinutes: 60,
                         date: "2026-09-24", kind: .external)
        let r4 = try await write.insertCalBlockIfAbsent(g, retimeIfTaken: false, nowISO: now)
        XCTAssertEqual(r4, .inserted)
        XCTAssertEqual(try box.count(), 2)
    }

    /// A delete cancels a still-queued mint (it would re-create the row).
    func testDeleteCancelsAPendingInsert() async throws {
        let b = mint("2026-09-24")
        try await write.insertCalBlockIfAbsent(b, retimeIfTaken: true, nowISO: now)
        try await write.deleteCalBlock(id: b.id, nowISO: now)
        XCTAssertEqual(try box.pending().map(\.kind), [.delete])
        XCTAssertNil(try db.fetchById(CalBlock.self, id: b.id))
    }

    /// The launch top-up mints a day at a time, and the user deletes the
    /// series between two mints. The days still to come are refused: minted
    /// after the cascade, each waited forever on the deleted task and stayed
    /// on the phone as a ghost block (audit 2026-09-22, C23). A user's mint
    /// for a task whose own save hasn't landed yet still writes — the
    /// flusher holds it until the task does.
    func testATopUpMintForADeletedTaskWritesNothing() async throws {
        try await write.upsertTask(TaskItem(id: seriesId, name: "Gym", estimateMin: 30, recurrence: .daily(until: nil),
                                            createdAt: now, updatedAt: now), nowISO: now)
        let first = try await write.insertCalBlockIfAbsent(mint("2026-09-24"), retimeIfTaken: false, nowISO: now)
        XCTAssertEqual(first, .inserted)
        try await write.deleteTask(id: seriesId, nowISO: now)

        let late = try await write.insertCalBlockIfAbsent(mint("2026-09-25"), retimeIfTaken: false, nowISO: now)

        XCTAssertEqual(late, .held)
        XCTAssertTrue(try db.fetchAllCalBlocks().isEmpty, "no ghost block for the deleted task")
        XCTAssertTrue(try box.pending().allSatisfy { $0.kind == .delete }, "nothing left waiting on the deleted task")

        let fresh = "5b2d7c1e-8f3a-4d6b-9c0e-1a2b3c4d5e6f"
        let userMint = CalBlock(id: occurrenceId(taskId: fresh, date: "2026-09-24"), taskId: fresh, taskName: "Swim",
                                startTime: "08:00", durationMinutes: 30, date: "2026-09-24", kind: .task)
        let asked = try await write.insertCalBlockIfAbsent(userMint, retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(asked, .inserted, "the user's own mint never waits on the task's save")
    }

    /// "Never" then "Daily": the day's id is deleted, then minted again. The
    /// outbox keeps both, delete first (hazard d).
    func testDeleteThenReMintKeepsOrder() async throws {
        let b = mint("2026-09-24")
        try db.save(b)
        try await write.deleteCalBlock(id: b.id, nowISO: now)
        let reMinted = try await write.insertCalBlockIfAbsent(b, retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(reMinted, .inserted, "the deleted row is gone locally, so the re-mint writes")
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.kind), [.delete, .insertOrRetime])
        XCTAssertEqual(Set(ops.map(\.rowId)), [b.id])
        XCTAssertLessThan(try XCTUnwrap(ops[0].opSeq), try XCTUnwrap(ops[1].opSeq))
    }

    /// A fresh whole-row save supersedes a quarantined insert of the row, as
    /// it does a quarantined upsert (C4).
    func testAFreshSaveDropsAQuarantinedInsert() async throws {
        try saveSeries()
        let b = mint("2026-09-24")
        try await write.insertCalBlockIfAbsent(b, retimeIfTaken: false, nowISO: now)
        let seq = try XCTUnwrap(box.pending().first?.opSeq)
        for _ in 0..<OutboxStore.quarantineCap { try box.bumpAttempts(seq) }
        try await write.upsertCalBlock(b, nowISO: now)
        XCTAssertEqual(try box.pending().map(\.kind), [.upsert])
    }

    // MARK: - stage 2 review: rule H locally, the Google mapping, the stamp

    /// A USER mint whose id is already that day's OPEN occurrence (a top-up
    /// minted it after the caller read the store) retimes it — start and
    /// length only — and queues insert_or_retime, so the server applies the
    /// same conditional retime. Skipping it dropped the user's time everywhere.
    func testUserMintRetimesTheDaysOpenOccurrenceLocally() async throws {
        try saveSeries()
        var topUp = mint("2026-09-24")   // 07:00, queued by a top-up
        topUp.externalEventId = "evt-1"
        topUp.externalConnectionId = "4c1f7a2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b"
        try await write.insertCalBlockIfAbsent(topUp, retimeIfTaken: false, nowISO: now)
        var asked = mint("2026-09-24", "09:00")
        asked.durationMinutes = 45
        let outcome = try await write.insertCalBlockIfAbsent(asked, retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(outcome, .retimed)
        let row = try XCTUnwrap(db.fetchById(CalBlock.self, id: asked.id))
        XCTAssertEqual(row.startTime, "09:00")
        XCTAssertEqual(row.durationMinutes, 45)
        XCTAssertEqual(row.externalEventId, "evt-1", "only the start and the length move")
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.kind), [.insert, .insertOrRetime], "the top-up's insert first, then the user's rule H")
        XCTAssertTrue(try XCTUnwrap(ops[1].payload).contains("\"start_time\":\"09:00\""))
        XCTAssertEqual(ops[1].dependsOn, seriesId)

        // Asked again at the same time: nothing to write.
        let again = try await write.insertCalBlockIfAbsent(asked, retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(again, .alreadyThere)
        XCTAssertEqual(try box.count(), 2)
    }

    /// Rule H never reaches a moved, done or skipped occurrence, and a
    /// maintenance mint (a top-up) never moves any row.
    func testLocalRuleHOnlyMovesTheDaysOpenOccurrence() async throws {
        try db.save(mint("2026-09-24"))
        let topUp = try await write.insertCalBlockIfAbsent(mint("2026-09-24", "09:00"), retimeIfTaken: false, nowISO: now)
        XCTAssertEqual(topUp, .held, "a top-up never moves a row")
        var skipped = mint("2026-09-25")
        skipped.skipped = true
        try db.save(skipped)
        let onSkipped = try await write.insertCalBlockIfAbsent(mint("2026-09-25", "09:00"), retimeIfTaken: true, nowISO: now)
        XCTAssertEqual(onSkipped, .held)
        XCTAssertEqual(try box.count(), 0)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: mint("2026-09-24").id)?.startTime, "07:00")
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: skipped.id)?.startTime, "07:00")
    }

    /// Every save carries the row's CURRENT Google mapping: a rewrite built
    /// from a copy read before the stamp landed must not null the event id
    /// (the push that followed INSERTed a second event).
    func testASaveKeepsTheMappingStampedAfterItsCopyWasRead() async throws {
        let snapshot = mint("2026-09-24")   // read before the Google push stamped it
        try db.save(snapshot)
        try await write.stampCalBlockMapping(id: snapshot.id, eventId: "evt-1",
                                             connectionId: "4c1f7a2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b", nowISO: now)
        var rewrite = snapshot
        rewrite.startTime = "08:00"
        try await write.upsertCalBlock(rewrite, nowISO: now)
        let row = try XCTUnwrap(db.fetchById(CalBlock.self, id: snapshot.id))
        XCTAssertEqual(row.startTime, "08:00")
        XCTAssertEqual(row.externalEventId, "evt-1")
        XCTAssertEqual(row.externalConnectionId, "4c1f7a2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b")
        let last = try XCTUnwrap(box.pending().last?.payload)
        XCTAssertTrue(last.contains("\"external_event_id\":\"evt-1\""), "the server keeps it too")
        // A brand-new row keeps what it was given.
        var fresh = mint("2026-09-26")
        fresh.externalEventId = "evt-9"
        try await write.upsertCalBlock(fresh, nowISO: now)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: fresh.id)?.externalEventId, "evt-9")
    }

    /// The stamp writes the two mapping columns onto the row as it is NOW, and
    /// refuses a row that is gone or has an unresolved insert (rule G).
    func testTheStampWritesOnlyTheMappingOntoTheCurrentRow() async throws {
        var edited = mint("2026-09-24")
        edited.startTime = "10:30"   // an edit made during the Google call
        try db.save(edited)
        let conn = "4c1f7a2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b"
        let stamped = try await write.stampCalBlockMapping(id: edited.id, eventId: "evt-1", connectionId: conn, nowISO: now)
        XCTAssertEqual(stamped, .stamped)
        let row = try XCTUnwrap(db.fetchById(CalBlock.self, id: edited.id))
        XCTAssertEqual(row.startTime, "10:30", "the edit survives")
        XCTAssertEqual(row.externalEventId, "evt-1")
        XCTAssertEqual(try box.pending().map(\.kind), [.upsert])
        let same = try await write.stampCalBlockMapping(id: edited.id, eventId: "evt-1", connectionId: conn, nowISO: now)
        XCTAssertEqual(same, .unchanged)
        let gone = try await write.stampCalBlockMapping(id: mint("2026-09-30").id, eventId: "evt-2", connectionId: conn, nowISO: now)
        XCTAssertEqual(gone, .gone)
        XCTAssertNil(try db.fetchById(CalBlock.self, id: mint("2026-09-30").id), "a stamp never resurrects a row")

        // Deleted and minted again during the call: the new row's insert is unresolved.
        let reMint = mint("2026-09-25")
        try db.save(reMint)
        try await write.deleteCalBlock(id: reMint.id, nowISO: now)
        try await write.insertCalBlockIfAbsent(reMint, retimeIfTaken: true, nowISO: now)
        let ops = try box.count()
        let blocked = try await write.stampCalBlockMapping(id: reMint.id, eventId: "evt-3", connectionId: conn, nowISO: now)
        XCTAssertEqual(blocked, .insertUnresolved)
        XCTAssertNil(try db.fetchById(CalBlock.self, id: reMint.id)?.externalEventId)
        XCTAssertEqual(try box.count(), ops, "nothing queued behind the insert")
    }

    // MARK: captures of a session that writes no Session row (audit 2026-09-22, C44)

    private func uuid() -> String { UUID().uuidString.lowercased() }
    private func captureOp(_ id: String) throws -> OutboxOp? {
        try box.pending().last { $0.tableName == "captures" && $0.rowId == id }
    }
    private func payload(_ op: OutboxOp?) throws -> [String: Any] {
        let data = try XCTUnwrap(op?.payload?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// cancel_focus, a discard, a task shared with me: the session's row never
    /// comes, so its captures are re-queued without it — and only its own.
    func testDetachingASessionReleasesOnlyItsHeldCaptures() async throws {
        let ended = uuid(), live = uuid()
        let note = Capture(id: uuid(), taskId: nil, sessionId: ended, tag: .followUp, body: "call the bank", at: now)
        let other = Capture(id: uuid(), taskId: nil, sessionId: live, tag: .idea, body: "later", at: now)
        try await write.upsertCapture(note, nowISO: now)
        try await write.upsertCapture(other, nowISO: now)
        _ = try await write.setCaptureArchived(id: note.id, archivedAt: now, nowISO: now)
        XCTAssertEqual(try captureOp(note.id)?.dependsOn, ended)

        let released = try await write.detachCapturesFromSession(ended, nowISO: now)
        XCTAssertEqual(released, 1)
        let op = try captureOp(note.id)
        XCTAssertNil(op?.dependsOn, "nothing left to wait for")
        XCTAssertTrue(try payload(op)["session_id"] is NSNull)
        XCTAssertEqual(try payload(op)["archived_at"] as? String, now, "the archive state travels with it")
        XCTAssertEqual(try box.pending().filter { $0.rowId == note.id }.count, 1, "the held op is replaced, not duplicated")
        XCTAssertNil(try db.fetchById(Capture.self, id: note.id)?.sessionId)
        XCTAssertEqual(try captureOp(other.id)?.dependsOn, live, "a live session's capture still waits for its row")
        let again = try await write.detachCapturesFromSession(ended, nowISO: now)
        XCTAssertEqual(again, 0, "idempotent")
    }

    /// A displaced session whose task was deleted meanwhile: the captures drop
    /// the dead task id too — captures.task_id references tasks(id).
    func testDetachingCanDropATaskThatIsGone() async throws {
        let sid = uuid(), gone = uuid()
        let c = Capture(id: uuid(), taskId: gone, sessionId: sid, tag: .idea, body: "x", at: now)
        try await write.upsertCapture(c, nowISO: now)
        try await write.detachCapturesFromSession(sid, unlinkingTaskId: gone, nowISO: now)
        XCTAssertTrue(try payload(captureOp(c.id))["task_id"] is NSNull)
        XCTAssertNil(try db.fetchById(Capture.self, id: c.id)?.taskId)
    }

    /// Launch: captures an earlier run left behind a session that never wrote
    /// its row are released; ones whose session is stored, queued or live, ones
    /// queued this run, and ones with no stored row (un-parked) are left alone.
    func testReleasingStrandedCapturesTouchesOnlyAnEarlierRunsOrphans() async throws {
        let earlier = "2026-05-21T10:00:00.000Z", launch = "2026-05-21T11:00:00.000Z", later = "2026-05-21T11:30:00.000Z"
        let stored = uuid(), queued = uuid(), live = uuid(), orphan = uuid(), endingNow = uuid()
        try db.save(UnstuckCore.Session(id: stored, taskName: "S", actualSec: 60, completedAt: earlier))
        try await write.upsertSession(UnstuckCore.Session(id: queued, taskName: "Q", actualSec: 60, completedAt: earlier), nowISO: earlier)
        func cap(_ sid: String, at: String) async throws -> String {
            let c = Capture(id: uuid(), sessionId: sid, tag: .idea, body: "x", at: at)
            try await write.upsertCapture(c, nowISO: at)
            return c.id
        }
        let onStored = try await cap(stored, at: earlier)
        let onQueued = try await cap(queued, at: earlier)
        let onLive = try await cap(live, at: earlier)
        let stranded = try await cap(orphan, at: earlier)
        let thisRun = try await cap(endingNow, at: later)
        let unparked = uuid()
        _ = try box.enqueue(table: "captures", rowId: unparked, kind: .upsert, payload: "{}", dependsOn: orphan, nowISO: earlier)

        let released = try await write.releaseCapturesOfEndedSessions(liveSessionId: live, queuedBefore: launch, nowISO: later)
        XCTAssertEqual(released, 1)
        XCTAssertNil(try captureOp(stranded)?.dependsOn)
        XCTAssertNil(try db.fetchById(Capture.self, id: stranded)?.sessionId)
        XCTAssertEqual(try captureOp(onStored)?.dependsOn, stored)
        XCTAssertEqual(try captureOp(onQueued)?.dependsOn, queued)
        XCTAssertEqual(try captureOp(onLive)?.dependsOn, live)
        XCTAssertEqual(try captureOp(thisRun)?.dependsOn, endingNow, "its row may be on its way")
        XCTAssertEqual(try captureOp(unparked)?.dependsOn, orphan, "no row stored here to re-send")
    }
}
