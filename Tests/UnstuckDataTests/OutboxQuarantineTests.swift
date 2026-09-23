// The outbox quarantine, surfaced (audit 2026-09-22, C28): an op the server
// refused five times used to sit here for good — nothing reset its count,
// nothing showed it, and whatever waited behind it waited for ever.

import XCTest
import UnstuckCore
@testable import UnstuckData

final class OutboxQuarantineTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
    }

    private func quarantine(_ op: OutboxOp) throws {
        for _ in 0..<OutboxStore.quarantineCap { _ = try box.bumpAttempts(op.opSeq!) }
    }

    /// What can't reach the server: the refused op AND what waits behind it
    /// (a block on its task, a capture on that block's… anything chained).
    func testStuckIsTheQuarantineAndEverythingHeldBehindIt() throws {
        let task = try box.enqueue(table: "tasks", rowId: "T1", kind: .upsert, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "B1", kind: .upsert, payload: "{}", dependsOn: "T1", nowISO: now)
        _ = try box.enqueue(table: "captures", rowId: "C1", kind: .upsert, payload: "{}", dependsOn: "B1", nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "T2", kind: .upsert, payload: "{}", nowISO: now)
        XCTAssertEqual(try box.stuck().count, 0)
        try quarantine(task)
        XCTAssertEqual(try box.stuck().map(\.rowId), ["T1", "B1", "C1"])
    }

    /// A new build must get another go: nothing ever reset `attempts`, so a
    /// build that fixed the payload still never sent it. Parked ops too.
    func testReleaseQuarantineGivesEveryQuarantinedOpItsTriesBack() throws {
        let a = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now)
        let b = try box.enqueue(table: "tasks", rowId: "t2", kind: .upsert, payload: "{}", nowISO: now)
        try quarantine(a)
        _ = try box.bumpAttempts(b.opSeq!)
        let c = try box.enqueue(table: "tasks", rowId: "t3", kind: .upsert, payload: "{}", nowISO: now)
        try quarantine(c)
        XCTAssertEqual(try box.quarantinedCount(), 2)

        // t9 was parked for a user who signed out with it quarantined.
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO parked_outbox (userId, tableName, rowId, kind, payload, attempts, createdAt) VALUES ('u1','tasks','t9','upsert','{}',?,?)",
                             arguments: [OutboxStore.quarantineCap, now])
        }
        XCTAssertEqual(try box.releaseQuarantine(), 3)
        XCTAssertEqual(try box.quarantinedCount(), 0)
        XCTAssertEqual(try box.pending().first { $0.rowId == "t2" }?.attempts, 1, "an op that isn't quarantined keeps its count")
        XCTAssertEqual(try box.restoreParked(userId: "u1"), 1)
        XCTAssertEqual(try box.pending().first { $0.rowId == "t9" }?.attempts, 0)
    }

    /// Retry sends each quarantined op once more; one more refusal
    /// quarantines it again at once.
    func testRetryQuarantinedAllowsExactlyOneMoreRefusal() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now)
        try quarantine(op)
        XCTAssertEqual(try box.retryQuarantined(), 1)
        XCTAssertFalse(try XCTUnwrap(box.pending().first).isQuarantined)
        _ = try box.bumpAttempts(op.opSeq!)
        XCTAssertTrue(try XCTUnwrap(box.pending().first).isQuarantined)
    }

    /// Discard drops the stuck ops and the rows they carry (the server's copy
    /// comes back with the next full hydrate); everything else stays.
    func testDiscardStuckDropsTheOpsAndTheirLocalRows() throws {
        try db.save(TaskItem(id: "T1", name: "Refused", estimateMin: 25, createdAt: now, updatedAt: now))
        try db.save(CalBlock(id: "B1", taskId: "T1", taskName: "Refused", startTime: "09:00",
                             durationMinutes: 30, date: "2026-05-22", kind: .task))
        try db.save(TaskItem(id: "T2", name: "Fine", estimateMin: 25, createdAt: now, updatedAt: now))
        let task = try box.enqueue(table: "tasks", rowId: "T1", kind: .upsert, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "B1", kind: .upsert, payload: "{}", dependsOn: "T1", nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "T2", kind: .upsert, payload: "{}", nowISO: now)
        try quarantine(task)

        XCTAssertEqual(try box.discardStuck(), 2)
        XCTAssertEqual(try box.pending().map(\.rowId), ["T2"])
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "T1"))
        XCTAssertNil(try db.fetchById(CalBlock.self, id: "B1"))
        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: "T2"))
    }
}
