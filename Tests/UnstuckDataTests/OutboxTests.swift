import XCTest
import UnstuckCore
@testable import UnstuckData

final class OutboxTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
    }

    func testEnqueueAssignsOpSeqAndKeepsFIFO() throws {
        let a = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now)
        let b = try box.enqueue(table: "tasks", rowId: "t2", kind: .upsert, payload: "{}", nowISO: now)
        XCTAssertNotNil(a.opSeq)
        XCTAssertEqual(a.opSeq! + 1, b.opSeq!)
        XCTAssertEqual(try box.pending().map(\.rowId), ["t1", "t2"])
        XCTAssertEqual(try box.count(), 2)
    }

    func testNextFlushableHoldsBackDependentUntilParentDone() throws {
        let task = try box.enqueue(table: "tasks", rowId: "T1", kind: .upsert, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "B1", kind: .upsert, payload: "{}", dependsOn: "T1", nowISO: now)

        // The cal_block op waits for the task op (still pending).
        XCTAssertEqual(try box.nextFlushable().map(\.rowId), ["T1"])

        // Once the task op is flushed, the cal_block becomes flushable.
        try box.markDone(task.opSeq!)
        XCTAssertEqual(try box.nextFlushable().map(\.rowId), ["B1"])
    }

    func testIndependentOpsAreAllFlushable() throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "t2", kind: .delete, nowISO: now)
        XCTAssertEqual(try box.nextFlushable().map(\.rowId), ["t1", "t2"])
    }

    func testMarkDoneRemoves() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, nowISO: now)
        try box.markDone(op.opSeq!)
        XCTAssertEqual(try box.count(), 0)
    }

    func testBumpAttempts() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, nowISO: now)
        try box.bumpAttempts(op.opSeq!)
        try box.bumpAttempts(op.opSeq!)
        XCTAssertEqual(try box.pending().first?.attempts, 2)
    }
}

final class LiveSessionStoreTests: XCTestCase {
    private var db: AppDatabase!
    private var store: LiveSessionStore!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        store = LiveSessionStore(db)
    }

    func testGetIsNilWhenEmpty() throws {
        XCTAssertNil(try store.get())
    }

    func testSetGetRoundTrip() throws {
        let live = LiveSession(id: "ls1", taskId: "t1", sessionStart: 1000, paused: true, pausedAt: 2000,
                               sessionEstimateMin: 25, nudge80Fired: false, overrunPromptFired: false,
                               treatment: .cockpit, priorAccumulatedSec: 300)
        try store.set(live)
        XCTAssertEqual(try store.get(), live)
    }

    func testSetNilClears() throws {
        try store.set(LiveSession(id: "ls1", taskId: "t1", sessionEstimateMin: 25, treatment: .ambient))
        try store.set(nil)
        XCTAssertNil(try store.get())
    }

    func testSetOverwritesSingleRow() throws {
        try store.set(LiveSession(id: "a", taskId: "t1", sessionEstimateMin: 25, treatment: .ambient))
        try store.set(LiveSession(id: "b", taskId: "t2", sessionEstimateMin: 50, treatment: .monk))
        XCTAssertEqual(try store.get()?.id, "b")
    }
}
