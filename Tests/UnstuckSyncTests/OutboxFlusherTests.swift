// Port of the Android OutboxFlusher semantics (spec 02-sync-engine §1.2/
// §1.4): the rejection-only quarantine cap (transient failures NEVER count —
// the old poison pill dropped a valid write after five airplane-mode passes),
// the blockedRows per-row ordering after a failure, and the mid-drain
// user-switch guard. The fake gateway scripts per-row failures so the
// drain loop runs against a real GRDB outbox without a network.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Scripted SyncGateway stand-in: fails rows on demand, records the order
/// of successful applies (id + the payload's name for LWW assertions).
private actor FakeGateway: SyncGatewayProtocol {
    /// An un-classified error — the flusher must treat it as transient.
    struct Failure: Error {}
    /// A definite server rejection (PostgREST 4xx / FK / check) — the only
    /// kind that counts toward the quarantine cap.
    struct Rejection: Error, ServerRejectionClassifiable { var isServerRejection: Bool { true } }

    private(set) var upserts: [(table: String, id: String, name: String?)] = []
    private(set) var deletes: [String] = []
    private var failuresRemaining: [String: Int] = [:]   // rowId → failures left (.max = forever)
    private var errorFor: [String: Error] = [:]

    func fail(_ rowId: String, times: Int, with error: Error = Failure()) {
        failuresRemaining[rowId] = times
        errorFor[rowId] = error
    }
    func failForever(_ rowId: String, with error: Error = Failure()) {
        failuresRemaining[rowId] = .max
        errorFor[rowId] = error
    }

    private func shouldFail(_ id: String) -> Bool {
        guard let n = failuresRemaining[id], n > 0 else { return false }
        if n != .max { failuresRemaining[id] = n - 1 }
        return true
    }

    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        let data = try JSONEncoder().encode(row)
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let id = obj["id"] as? String ?? ""
        if shouldFail(id) { throw errorFor[id] ?? Failure() }
        upserts.append((table, id, obj["name"] as? String))
    }

    func delete(table: String, id: String) async throws {
        if shouldFail(id) { throw errorFor[id] ?? Failure() }
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

    // MARK: - transient failures never count; rejections quarantine (never delete)

    /// The CRITICAL data-loss path: airplane mode + the 60s foreground safety
    /// net = five failed passes in five minutes. The old cap then markDone'd
    /// the op (and its FK dependents) and the next hydrate wiped the local row.
    /// An offline / timeout / 5xx failure is NOT a verdict on the op: it must
    /// stay queued for as many passes as it takes.
    func testOfflineFailuresNeverCountTowardTheCap() async throws {
        try db.save(TaskItem(id: "t1", name: "kept", estimateMin: 25, createdAt: now, updatedAt: now))
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "b1", kind: .upsert,
                            payload: try blockPayload(id: "b1", taskId: "t1"),
                            dependsOn: "t1", nowISO: now)
        await gateway.fail("t1", times: 12, with: URLError(.notConnectedToInternet))
        for pass in 1...12 {
            await flusher.flush(userId: "u1")
            XCTAssertEqual(try box.count(), 2, "still queued after offline pass \(pass)")
            XCTAssertEqual(try box.pending().first?.attempts, 0, "offline passes must not be counted")
        }
        // Network back: both flush in FK order.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        let upserts = await gateway.upserts
        XCTAssertEqual(upserts.map(\.id), ["t1", "b1"])
    }

    func testUnclassifiedAndCancellationErrorsAreTransientToo() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        await gateway.failForever("t1")   // FakeGateway.Failure — no classification → transient
        for _ in 1...8 { await flusher.flush(userId: "u1") }
        XCTAssertEqual(try box.count(), 1)
        XCTAssertEqual(try box.pending().first?.attempts, 0)
        XCTAssertFalse(try XCTUnwrap(box.pending().first).isQuarantined)
    }

    func testServerRejectionsQuarantineTheOpButNeverDeleteItOrItsRow() async throws {
        try db.save(TaskItem(id: "t1", name: "kept", estimateMin: 25, createdAt: now, updatedAt: now))
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        _ = try box.enqueue(table: "cal_blocks", rowId: "b1", kind: .upsert,
                            payload: try blockPayload(id: "b1", taskId: "t1"),
                            dependsOn: "t1", nowISO: now)
        await gateway.failForever("t1", with: FakeGateway.Rejection())
        for pass in 1...OutboxStore.quarantineCap {
            await flusher.flush(userId: "u1")
            XCTAssertEqual(try box.count(), 2, "kept after rejection \(pass)")
            XCTAssertEqual(try box.pending().first?.attempts, pass, "each rejection is counted (persisted)")
        }
        let head = try XCTUnwrap(box.pending().first)
        XCTAssertTrue(head.isQuarantined)
        // Further drains skip it (no more sends) and the dependent stays held.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 2, "quarantined op + its dependent are KEPT, never deleted")
        XCTAssertEqual(try box.pending().first?.attempts, OutboxStore.quarantineCap, "no send after quarantine")
        XCTAssertEqual(try box.quarantinedCount(), 1)
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty, "the dependent was never pushed ahead of its parent")
        // The local row survives (hydrate's pending-row preservation keeps it too).
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "kept")
    }

    func testRejectionCountSurvivesARelaunchOfTheFlusher() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1"), nowISO: now)
        await gateway.failForever("t1", with: FakeGateway.Rejection())
        for _ in 1..<OutboxStore.quarantineCap { await flusher.flush(userId: "u1") }
        // New process: a fresh flusher over the same store continues the count.
        let relaunched = OutboxFlusher(gateway: gateway, db: db)
        await relaunched.flush(userId: "u1")
        XCTAssertTrue(try XCTUnwrap(box.pending().first).isQuarantined)
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
