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

    func testCancelPendingUpsertsAlsoDropsRPCOpsButKeepsDeletes() throws {
        // Deleting a shared list must cancel its queued item RPCs (they'd fire
        // on a list that no longer exists) — but never a queued delete.
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .upsert, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "collections", rowId: "c2", kind: .rpc, payload: "{}", nowISO: now)
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .delete, nowISO: now)
        try box.cancelPendingUpserts(table: "collections", rowId: "c1")
        let left = try box.pending()
        XCTAssertEqual(left.map { "\($0.rowId):\($0.kind.rawValue)" }, ["c2:rpc", "c1:delete"])
    }

    func testMarkDoneRemoves() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, nowISO: now)
        try box.markDone(op.opSeq!)
        XCTAssertEqual(try box.count(), 0)
    }

    func testBumpAttempts() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, nowISO: now)
        XCTAssertEqual(try box.bumpAttempts(op.opSeq!), 1)
        XCTAssertEqual(try box.bumpAttempts(op.opSeq!), 2)
        XCTAssertEqual(try box.pending().first?.attempts, 2)
        XCTAssertFalse(try XCTUnwrap(box.pending().first).isQuarantined)
        for _ in 0..<(OutboxStore.quarantineCap - 2) { _ = try box.bumpAttempts(op.opSeq!) }
        XCTAssertTrue(try XCTUnwrap(box.pending().first).isQuarantined)
        XCTAssertEqual(try box.quarantinedCount(), 1)
        XCTAssertEqual(try box.count(), 1, "quarantine keeps the op")
    }

    func testBaseTravelsWithTheOpAndCanBeRewritten() throws {
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{\"v\":2}", nowISO: now,
                                 baseUpdatedAt: "2026-05-21T09:00:00.000Z", basePayload: "{\"v\":1}")
        XCTAssertEqual(try box.pending().first?.baseUpdatedAt, "2026-05-21T09:00:00.000Z")
        try box.replacePayload(op.opSeq!, payload: "{\"v\":3}", baseUpdatedAt: "2026-05-21T10:00:00.000Z", basePayload: "{\"v\":2}")
        let after = try XCTUnwrap(box.pending().first)
        XCTAssertEqual(after.payload, "{\"v\":3}")
        XCTAssertEqual(after.baseUpdatedAt, "2026-05-21T10:00:00.000Z")
        XCTAssertEqual(after.basePayload, "{\"v\":2}")
    }

    // MARK: - parking (sign-out while offline)

    func testParkMovesEveryOpUnderTheUserAndRestoreBringsOnlyTheirsBack() throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now,
                            baseUpdatedAt: "b1", basePayload: "{}")
        _ = try box.enqueue(table: "cal_blocks", rowId: "b1", kind: .upsert, payload: "{}", dependsOn: "t1", nowISO: now)
        XCTAssertEqual(try box.park(userId: "u1"), 2)
        XCTAssertEqual(try box.count(), 0, "the outbox is empty for the next account")
        XCTAssertEqual(try box.parkedCount(userId: "u1"), 2)

        // Another user signs in: nothing of u1's is replayed.
        XCTAssertEqual(try box.restoreParked(userId: "u2"), 0)
        XCTAssertEqual(try box.count(), 0)
        XCTAssertEqual(try box.parkedCount(), 2)

        // u1 comes back: original order, base + dependsOn intact, parking cleared.
        _ = try box.enqueue(table: "tasks", rowId: "t9", kind: .delete, nowISO: now)   // queued before the restore
        XCTAssertEqual(try box.restoreParked(userId: "u1"), 2)
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.rowId), ["t9", "t1", "b1"])
        XCTAssertEqual(ops[1].baseUpdatedAt, "b1")
        XCTAssertEqual(ops[2].dependsOn, "t1")
        XCTAssertEqual(try box.parkedCount(), 0)
        XCTAssertEqual(try box.nextFlushable().map(\.rowId), ["t9", "t1"], "the dependent still waits for its parent")
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
