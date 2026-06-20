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

    private func capturePayload(id: String, sessionId: String?) throws -> String {
        let c = Capture(id: id, sessionId: sessionId, tag: .idea, body: "x", at: now)
        return String(data: try JSONEncoder().encode(CaptureRow(c)), encoding: .utf8)!
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

    func testCaptureHeldBackUntilParentSessionExistsLocally() async throws {
        // A capture taken DURING a live focus session depends on a session whose
        // `sessions` row isn't written until session end: no pending session op,
        // and not in the local store yet. It must NOT flush (it would hit the
        // captures.session_id FK on every drain and get poison-dropped).
        _ = try box.enqueue(table: "captures", rowId: "c1", kind: .upsert,
                            payload: try capturePayload(id: "c1", sessionId: "s1"),
                            dependsOn: "s1", nowISO: now)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 1, "capture stays queued until its session exists locally")
        var upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)

        // Once the session row lands locally (flushed or hydrated), the FK is
        // satisfied server-side, so the capture is now flushable.
        try db.save(Session(id: "s1", taskName: "S", actualSec: 60, completedAt: now))
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        upserts = await gateway.upserts
        XCTAssertEqual(upserts.map(\.id), ["c1"])
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

    // MARK: - Malformed-op quarantine (dead-letter, not silent drop)

    func testUnknownTableOpIsQuarantinedNotDropped() async throws {
        // The user's local row is real; only the queued op names a table the
        // flusher can't route. The old `default: break` markDone'd it as
        // success, permanently dropping the edit. It must be kept + skipped.
        try db.save(TaskItem(id: "x1", name: "kept", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        _ = try box.enqueue(table: "unknown_table", rowId: "x1", kind: .upsert,
                            payload: try taskPayload(id: "x1"), nowISO: now)

        await flusher.flush(userId: "u1")
        // Op survives in the outbox (not silently dropped) ...
        XCTAssertEqual(try box.count(), 1)
        // ... was never sent to the server ...
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)
        // ... and the user's local row is untouched.
        let kept = try db.fetchById(TaskItem.self, id: "x1")
        XCTAssertEqual(kept?.name, "kept")
    }

    func testNilPayloadUpsertOpIsQuarantinedNotDropped() async throws {
        // An upsert op whose payload is nil can never be sent. It must be
        // quarantined (kept, not markDone'd) rather than treated as success.
        try db.save(TaskItem(id: "x1", name: "kept", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        _ = try box.enqueue(table: "tasks", rowId: "x1", kind: .upsert,
                            payload: nil, nowISO: now)

        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 1)
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)
        let kept = try db.fetchById(TaskItem.self, id: "x1")
        XCTAssertEqual(kept?.name, "kept")
    }

    func testQuarantinedOpDoesNotBlockHealthyOpsOrSpinAcrossDrains() async throws {
        // A malformed op for one row must not stall a valid op for another, and
        // re-draining must not re-send it (it's filtered out every pass).
        _ = try box.enqueue(table: "unknown_table", rowId: "bad", kind: .upsert,
                            payload: try taskPayload(id: "bad"), nowISO: now)
        _ = try box.enqueue(table: "tasks", rowId: "good", kind: .upsert,
                            payload: try taskPayload(id: "good"), nowISO: now)

        await flusher.flush(userId: "u1")
        // Valid op flushed + dropped; malformed op remains quarantined.
        XCTAssertEqual(try box.pending().map(\.rowId), ["bad"])
        var upserts = await gateway.upserts
        XCTAssertEqual(upserts.map(\.id), ["good"])

        // A second drain doesn't re-send the quarantined op.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 1)
        upserts = await gateway.upserts
        XCTAssertEqual(upserts.map(\.id), ["good"])
    }
}
