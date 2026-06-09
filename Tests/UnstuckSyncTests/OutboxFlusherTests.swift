// Port of the Android OutboxFlusher semantics (spec 02-sync-engine §1.2/
// §1.4): the FAIL_CAP=5 poison pill + orphan-drop of dependents, the
// blockedRows per-row ordering after a failure, and the mid-drain
// user-switch guard. The fake gateway scripts per-row failures so the
// drain loop runs against a real GRDB outbox without a network.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Scripted SyncGateway stand-in: fails rows on demand, records the order
/// of successful applies (id + the payload's name for LWW assertions).
private actor FakeGateway: SyncGatewayProtocol {
    struct Failure: Error {}

    private(set) var upserts: [(table: String, id: String, name: String?)] = []
    private(set) var deletes: [String] = []
    private var failuresRemaining: [String: Int] = [:]   // rowId → failures left (.max = forever)

    func fail(_ rowId: String, times: Int) { failuresRemaining[rowId] = times }
    func failForever(_ rowId: String) { failuresRemaining[rowId] = .max }

    private func shouldFail(_ id: String) -> Bool {
        guard let n = failuresRemaining[id], n > 0 else { return false }
        if n != .max { failuresRemaining[id] = n - 1 }
        return true
    }

    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        let data = try JSONEncoder().encode(row)
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let id = obj["id"] as? String ?? ""
        if shouldFail(id) { throw Failure() }
        upserts.append((table, id, obj["name"] as? String))
    }

    func delete(table: String, id: String) async throws {
        if shouldFail(id) { throw Failure() }
        deletes.append(id)
    }
}

final class OutboxFlusherTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private var gateway: FakeGateway!
    private var flusher: OutboxFlusher!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
        gateway = FakeGateway()
        flusher = OutboxFlusher(gateway: gateway, db: db)
    }

    private func taskPayload(id: String, name: String = "T") throws -> String {
        let t = TaskItem(id: id, name: name, estimateMin: 25, createdAt: now, updatedAt: now)
        return String(data: try JSONEncoder().encode(TaskRow(t)), encoding: .utf8)!
    }

    private func blockPayload(id: String, taskId: String) throws -> String {
        let b = CalBlock(id: id, taskId: taskId, taskName: "B", startTime: "09:00",
                         durationMinutes: 25, date: "2026-05-21", kind: .task)
        return String(data: try JSONEncoder().encode(CalBlockRow(b)), encoding: .utf8)!
    }

    func testUserSwitchGuardBailsWithoutFlushing() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        // The live user changed mid-drain → nothing may be stamped/sent.
        await flusher.flush(userId: "u1", currentUserId: { "u2" })
        XCTAssertEqual(try box.count(), 1)
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)
    }

    func testPoisonOpDroppedAtFailCapAndOrphanedDependentsDropped() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "b1", kind: .upsert,
                            payload: try blockPayload(id: "b1", taskId: "t1"),
                            dependsOn: "t1", nowISO: now)
        await gateway.failForever("t1")
        // 4 failed passes: the op + its held-back dependent stay queued.
        for pass in 1...4 {
            await flusher.flush(userId: "u1")
            XCTAssertEqual(try box.count(), 2, "still queued after pass \(pass)")
        }
        // 5th consecutive failure → poison drop + orphan-drop of the dependent.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        // The dependent was never pushed (its FK parent never existed server-side).
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)
    }

    func testFailedRowBlocksItsLaterOpsAndRetryPreservesSeqOrder() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "old"), nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "new"), nowISO: now)
        await gateway.fail("t1", times: 1)

        // Pass 1: op#1 fails → op#2 (same row) must be skipped, not applied —
        // otherwise the older retried op#1 would clobber it later.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 2)
        var upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)

        // Retry: both apply in seq order, so the last-enqueued state wins.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        upserts = await gateway.upserts
        XCTAssertEqual(upserts.map { $0.name }, ["old", "new"])
    }

    func testOtherRowsStillFlushWhenOneRowFails() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "t2", kind: .upsert,
                            payload: try taskPayload(id: "t2"), nowISO: now)
        await gateway.failForever("t1")
        await flusher.flush(userId: "u1")
        // t2 progressed despite t1's failure; t1 stays queued for retry.
        XCTAssertEqual(try box.pending().map(\.rowId), ["t1"])
        let upserts = await gateway.upserts
        XCTAssertEqual(upserts.map { $0.id }, ["t2"])
    }
}
