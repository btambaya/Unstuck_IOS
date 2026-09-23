// Port of the Android OutboxFlusher semantics (spec 02-sync-engine §1.2/
// §1.4): the rejection-only quarantine cap (transient failures NEVER count —
// the old poison pill dropped a valid write after five airplane-mode passes),
// the blockedRows per-row ordering after a failure, and the mid-drain
// user-switch guard. The fake gateway scripts per-row failures so the
// drain loop runs against a real GRDB outbox without a network.

import XCTest
import Auth
import Supabase
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

    /// RPC ops are keyed by their function name for failure scripting.
    private(set) var rpcs: [(fn: String, params: String)] = []
    func rpc(fn: String, paramsJSON: String) async throws {
        if shouldFail(fn) { throw errorFor[fn] ?? Failure() }
        rpcs.append((fn, paramsJSON))
    }

    // MARK: the insert family (stage 2): a real ON CONFLICT (id) DO NOTHING
    // store keyed by id, and the filtered, column-scoped retime.

    struct ServerBlock: Sendable, Equatable {
        var id: String
        var taskId: String?
        var taskName: String
        var date: String
        var startTime: String
        var durationMinutes: Int
        var done = false
        var skipped = false
        var externalEventId: String?
    }
    private(set) var blocks: [String: ServerBlock] = [:]
    /// Every insert-if-absent sent (ids), and every conditional retime
    /// ("id|date|start|duration").
    private(set) var inserts: [String] = []
    private(set) var retimes: [String] = []
    private var onInsert: (@Sendable (String) -> Void)?

    func seed(_ b: ServerBlock) { blocks[b.id] = b }
    func setOnInsert(_ hook: @escaping @Sendable (String) -> Void) { onInsert = hook }

    func insertIfAbsent<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws -> Bool {
        let data = try JSONEncoder().encode(row)
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let id = obj["id"] as? String ?? ""
        onInsert?(id)
        if shouldFail(id) { throw errorFor[id] ?? Failure() }
        inserts.append(id)
        guard blocks[id] == nil else { return false }
        blocks[id] = ServerBlock(id: id, taskId: obj["task_id"] as? String, taskName: obj["task_name"] as? String ?? "",
                                 date: obj["date"] as? String ?? "", startTime: obj["start_time"] as? String ?? "",
                                 durationMinutes: obj["duration_minutes"] as? Int ?? 0,
                                 externalEventId: obj["external_event_id"] as? String)
        return true
    }

    func retimeIfOpen(table: String, id: String, date: String, startTime: String, durationMinutes: Int) async throws -> Data? {
        retimes.append("\(id)|\(date)|\(startTime)|\(durationMinutes)")
        guard var b = blocks[id], b.date == date, !b.done, !b.skipped else { return nil }
        b.startTime = startTime
        b.durationMinutes = durationMinutes
        blocks[id] = b
        let row: [String: Any] = ["id": b.id, "task_id": b.taskId ?? NSNull(), "task_name": b.taskName,
                                  "start_time": b.startTime, "duration_minutes": b.durationMinutes, "date": b.date,
                                  "external_event_id": b.externalEventId ?? NSNull(), "external_connection_id": NSNull(),
                                  "kind": "task", "done": b.done, "skipped": b.skipped, "completed_at": NSNull(),
                                  "user_id": "u1"]
        return try JSONSerialization.data(withJSONObject: row)
    }
}

/// A gateway that predates RPC ops (protocol default): every rpc op is a
/// definite rejection, never a retry loop.
private actor LegacyGateway: SyncGatewayProtocol {
    private(set) var upsertCalls = 0
    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws { upsertCalls += 1 }
    func delete(table: String, id: String) async throws {}
}

/// Collects the flusher's insert resolutions (the hook fires synchronously on
/// the flusher's executor).
private final class ResolutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [InsertResolution] = []
    func add(_ r: InsertResolution) { lock.withLock { items.append(r) } }
    var all: [InsertResolution] { lock.withLock { items } }
    func of(_ id: String) -> InsertResolution? { all.first { $0.rowId == id } }
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
        try db.save(UnstuckCore.Session(id: "s1", taskName: "S", actualSec: 60, completedAt: now))
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

    // MARK: - `rpc` ops (shared-collection item mutations)

    private func rpcPayload(fn: String = "collection_add_item") throws -> String {
        try OutboxRPCPayload(fn: fn, paramsJSON: #"{"p_collection_id":"c1","p_item":{"id":"i1","body":"Milk","at":"\(now)"}}"#).encoded()
    }

    func testRPCOpIsSentAndDequeued() async throws {
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: try rpcPayload(), nowISO: now)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        let rpcs = await gateway.rpcs
        XCTAssertEqual(rpcs.map(\.fn), ["collection_add_item"])
        XCTAssertTrue(rpcs[0].params.contains(#""id":"i1""#), "the descriptor's params reach the gateway verbatim")
    }

    func testRPCTransientFailureRetriesWithoutCounting() async throws {
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: try rpcPayload(), nowISO: now)
        await gateway.fail("collection_add_item", times: 3, with: URLError(.notConnectedToInternet))
        for _ in 1...3 {
            await flusher.flush(userId: "u1")
            XCTAssertEqual(try box.count(), 1, "offline: the item edit stays queued (the old fire-and-forget lost it)")
            XCTAssertEqual(try box.pending().first?.attempts, 0)
        }
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        let rpcs = await gateway.rpcs
        XCTAssertEqual(rpcs.count, 1)
    }

    func testRPCServerRefusalIsTerminalDroppedAndReported() async throws {
        // RLS no-op / revoked share: the same bytes can never succeed — the op
        // is dropped on the FIRST strike and the app is told which row to roll
        // back (never five silent retries, never a quarantined zombie).
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: try rpcPayload(), nowISO: now)
        // A later op for the same row must still flush (it doesn't depend on the refused one).
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc,
                            payload: try rpcPayload(fn: "collection_set_item_flag"), nowISO: now)
        await gateway.failForever("collection_add_item", with: FakeGateway.Rejection())
        actor Sink { var rejected: [(String, String, String)] = []; func add(_ t: String, _ r: String, _ f: String) { rejected.append((t, r, f)) } }
        let sink = Sink()
        await flusher.setOnRPCRejected { table, rowId, fn, _ in Task { await sink.add(table, rowId, fn) } }
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0, "refused op dropped; the later op flushed")
        let rpcs = await gateway.rpcs
        XCTAssertEqual(rpcs.map(\.fn), ["collection_set_item_flag"])
        // The hook fires asynchronously off the actor — give it a beat.
        for _ in 0..<50 where await sink.rejected.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let rejected = await sink.rejected
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.0, "collections")
        XCTAssertEqual(rejected.first?.1, "c1")
        XCTAssertEqual(rejected.first?.2, "collection_add_item")
    }

    func testRPCOpAgainstAGatewayWithoutRPCIsARejectionNotARetryLoop() async throws {
        let legacy = OutboxFlusher(gateway: LegacyGateway(), db: db)
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: try rpcPayload(), nowISO: now)
        await legacy.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0, "RPCUnsupportedError is a definite rejection → dropped, not spun forever")
    }

    func testRPCOpWithoutAPayloadIsQuarantined() async throws {
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc, payload: nil, nowISO: now)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 1, "malformed: kept, never sent, never dropped")
        let rpcs = await gateway.rpcs
        XCTAssertTrue(rpcs.isEmpty)
    }

    func testRPCBooleanFalseReturnIsARefusalDroppedAndReportedNotRetried() async throws {
        // Migration 056: the item RPCs answer 200 + `false` when the write did
        // nothing (RLS / unknown item). The gateway surfaces that as
        // RPCRefusedError — a definite rejection: dropped on the first strike,
        // never counted or retried, and the app is told to roll the row back.
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .rpc,
                            payload: try rpcPayload(fn: "collection_set_item_flag"), nowISO: now)
        await gateway.failForever("collection_set_item_flag", with: RPCRefusedError(fn: "collection_set_item_flag"))
        actor Sink {
            var rejected: [(fn: String, error: Error)] = []
            func add(_ fn: String, _ e: Error) { rejected.append((fn, e)) }
        }
        let sink = Sink()
        await flusher.setOnRPCRejected { _, _, fn, error in Task { await sink.add(fn, error) } }
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0, "a `false` is terminal — dropped, not left to spin")
        let rpcs = await gateway.rpcs
        XCTAssertTrue(rpcs.isEmpty, "never reached the recorder: the fake refused it")
        for _ in 0..<50 where await sink.rejected.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let rejected = await sink.rejected
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.fn, "collection_set_item_flag")
        XCTAssertTrue(rejected.first?.error is RPCRefusedError, "the app sees WHY: \(String(describing: rejected.first?.error))")
        // A second drain finds nothing to resend.
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
    }

    // MARK: - the insert family (stage 2, deterministic-occurrence-ids.md §3c)

    private let seriesId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
    private func mintBlock(_ date: String, _ time: String = "07:00", duration: Int = 30) -> CalBlock {
        CalBlock(id: occurrenceId(taskId: seriesId, date: date), taskId: seriesId, taskName: "Gym",
                 startTime: time, durationMinutes: duration, date: date, kind: .task)
    }
    /// The op WriteThrough.insertCalBlockIfAbsent queues (no dependsOn: the
    /// parent task isn't in this store).
    private func enqueueMint(_ b: CalBlock, _ kind: OutboxKind) throws {
        _ = try box.enqueue(table: "cal_blocks", rowId: b.id, kind: kind,
                            payload: String(data: try JSONEncoder().encode(CalBlockRow(b)), encoding: .utf8), nowISO: now)
    }
    private func serverBlock(_ b: CalBlock, done: Bool = false, eventId: String? = nil) -> FakeGateway.ServerBlock {
        FakeGateway.ServerBlock(id: b.id, taskId: b.taskId, taskName: b.taskName, date: b.date, startTime: b.startTime,
                                durationMinutes: b.durationMinutes, done: done, externalEventId: eventId)
    }

    func testInsertRoutesToInsertIfAbsent() async throws {
        let b = mintBlock("2026-09-24")
        try enqueueMint(b, .insert)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        let inserts = await gateway.inserts
        let upserts = await gateway.upserts
        let server = await gateway.blocks[b.id]
        XCTAssertEqual(inserts, [b.id])
        XCTAssertTrue(upserts.isEmpty, "a mint is never a plain upsert")
        XCTAssertEqual(server?.startTime, "07:00")
    }

    /// Rule H: the user's mint of a day another device already has retimes
    /// that day's OPEN occurrence — only its start and duration.
    func testIgnoredInsertOrRetimeSendsTheConditionalRetime() async throws {
        let theirs = mintBlock("2026-09-24", "07:00")
        await gateway.seed(serverBlock(theirs, eventId: "evt-A"))
        try enqueueMint(mintBlock("2026-09-24", "16:00", duration: 45), .insertOrRetime)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0)
        let retimes = await gateway.retimes
        XCTAssertEqual(retimes, ["\(theirs.id)|2026-09-24|16:00|45"], "the op's own date, start and duration")
        let server = await gateway.blocks[theirs.id]
        XCTAssertEqual(server?.startTime, "16:00")
        XCTAssertEqual(server?.durationMinutes, 45)
        XCTAssertEqual(server?.externalEventId, "evt-A", "column-scoped: the other device's Google mapping stays")
        let upserts = await gateway.upserts
        XCTAssertTrue(upserts.isEmpty)
    }

    /// A top-up's plain insert never moves a row another device has.
    func testIgnoredPlainInsertDoesNot() async throws {
        let theirs = mintBlock("2026-09-24", "07:00")
        await gateway.seed(serverBlock(theirs))
        try enqueueMint(mintBlock("2026-09-24", "16:00"), .insert)
        await flusher.flush(userId: "u1")
        XCTAssertEqual(try box.count(), 0, "an ignored insert acks — nothing left pending")
        let retimes = await gateway.retimes
        let server = await gateway.blocks[theirs.id]
        XCTAssertTrue(retimes.isEmpty)
        XCTAssertEqual(server?.startTime, "07:00")
    }

    /// `[delete X, insert X]`: a failed delete holds the re-mint back for the
    /// whole pass, so the insert can never land first (and be ignored by the
    /// row it was meant to replace).
    func testDeleteFlushesBeforeReMint() async throws {
        let old = mintBlock("2026-09-24", "07:00")
        await gateway.seed(serverBlock(old))
        _ = try box.enqueue(table: "cal_blocks", rowId: old.id, kind: .delete, nowISO: now)
        try enqueueMint(mintBlock("2026-09-24", "09:15"), .insertOrRetime)
        await gateway.fail(old.id, times: 1, with: URLError(.notConnectedToInternet))
        await flusher.flush(userId: "u1")
        var inserts = await gateway.inserts
        XCTAssertTrue(inserts.isEmpty, "the insert must not go out in the pass its delete failed")
        XCTAssertEqual(try box.pending().map(\.kind), [.delete, .insertOrRetime])
        await flusher.flush(userId: "u1")
        inserts = await gateway.inserts
        let deletes = await gateway.deletes
        let server = await gateway.blocks[old.id]
        XCTAssertEqual(deletes, [old.id])
        XCTAssertEqual(inserts, [old.id])
        XCTAssertEqual(server?.startTime, "09:15", "the delete landed first, so the re-mint INSERTED")
        XCTAssertEqual(try box.count(), 0)
    }

    func testInsertResolvedHookReportsOutcome() async throws {
        let fresh = mintBlock("2026-09-24")
        let open = mintBlock("2026-09-25", "07:00")
        let done = mintBlock("2026-09-26", "07:00")
        let taken = mintBlock("2026-09-27", "07:00")
        await gateway.seed(serverBlock(open, eventId: "evt-open"))
        await gateway.seed(serverBlock(done, done: true))
        await gateway.seed(serverBlock(taken))
        // This device's own copy of the retimed day: its time, no mapping.
        let mine = mintBlock("2026-09-25", "16:00")
        try db.save(mine)
        try enqueueMint(fresh, .insert)
        try enqueueMint(mine, .insertOrRetime)
        try enqueueMint(mintBlock("2026-09-26", "16:00"), .insertOrRetime)
        try enqueueMint(mintBlock("2026-09-27", "16:00"), .insert)
        let recorder = ResolutionRecorder()
        await flusher.setOnInsertResolved { recorder.add($0) }
        await flusher.flush(userId: "u1")

        XCTAssertEqual(recorder.all.count, 4, "one report per op")
        XCTAssertEqual(recorder.of(fresh.id)?.outcome, .inserted)
        XCTAssertNil(recorder.of(fresh.id)?.serverRow)
        XCTAssertEqual(recorder.of(done.id)?.outcome, .ignored, "a done day keeps its occurrence")
        XCTAssertEqual(recorder.of(taken.id)?.outcome, .ignored)
        let retimed = try XCTUnwrap(recorder.of(open.id))
        XCTAssertEqual(retimed.outcome, .retimed)
        XCTAssertEqual(retimed.table, "cal_blocks")
        let row = try JSONDecoder().decode(CalBlockRow.self, from: XCTUnwrap(retimed.serverRow))
        XCTAssertEqual(row.startTime, "16:00")
        XCTAssertEqual(row.externalEventId, "evt-open")
        // The server row replaced the local copy BEFORE anyone heard: it now
        // carries the other device's Google mapping.
        let local = try XCTUnwrap(db.fetchById(CalBlock.self, id: open.id))
        XCTAssertEqual(local.externalEventId, "evt-open")
        XCTAssertEqual(local.startTime, "16:00")
    }

    /// The protocol default THROWS — it never falls back to an upsert, which
    /// would overwrite another device's row (hazard c).
    func testDefaultGatewayInsertThrows() async throws {
        let gw = LegacyGateway()
        let row = CalBlockRow(mintBlock("2026-09-24"))
        do {
            _ = try await gw.insertIfAbsent(row, table: "cal_blocks", userId: "u1")
            XCTFail("the default must throw")
        } catch let e as InsertUnsupportedError {
            XCTAssertTrue(e.isServerRejection)
        }
        do {
            _ = try await gw.retimeIfOpen(table: "cal_blocks", id: row.id, date: row.date, startTime: "09:00", durationMinutes: 30)
            XCTFail("the default must throw")
        } catch is InsertUnsupportedError {}
        // Through the flusher: a rejection (counted, kept), never an upsert.
        let legacy = OutboxFlusher(gateway: gw, db: db)
        try enqueueMint(mintBlock("2026-09-24"), .insert)
        await legacy.flush(userId: "u1")
        let upserts = await gw.upsertCalls
        XCTAssertEqual(upserts, 0)
        XCTAssertEqual(try box.pending().first?.attempts, 1)
    }

    /// Rule G: a push for a row whose insert is unresolved (queued, or being
    /// sent) is deferred; the confirmed outcome carries it, an ignored one
    /// drops it; a row with no insert pushes at once.
    func testRuleGDefersAPushUntilTheInsertResolvesAndDropsItWhenIgnored() async throws {
        let gate = flusher.mirrorGate
        let ours = mintBlock("2026-09-24")
        let theirs = mintBlock("2026-09-25")
        let late = mintBlock("2026-09-26")
        await gateway.seed(serverBlock(theirs))
        try enqueueMint(ours, .insert)
        try enqueueMint(theirs, .insert)
        try enqueueMint(late, .insert)
        XCTAssertFalse(gate.requestMirror(rowId: ours.id), "queued: deferred")
        XCTAssertFalse(gate.requestMirror(rowId: theirs.id))
        XCTAssertTrue(gate.requestMirror(rowId: "no-insert-here"), "an ordinary block pushes at once")
        // A push asked for WHILE the insert is being sent is deferred too.
        let probe = ResultBox()
        await gateway.setOnInsert { id in if id == late.id { probe.set(gate.requestMirror(rowId: id)) } }
        let recorder = ResolutionRecorder()
        await flusher.setOnInsertResolved { recorder.add($0) }
        await flusher.flush(userId: "u1")

        XCTAssertEqual(probe.value, false, "in flight: still unresolved")
        XCTAssertEqual(recorder.of(ours.id)?.mirrorWanted, true, "confirmed: mirror once")
        XCTAssertEqual(recorder.of(late.id)?.mirrorWanted, true)
        XCTAssertEqual(recorder.of(theirs.id)?.outcome, .ignored)
        XCTAssertEqual(recorder.of(theirs.id)?.mirrorWanted, false, "an ignored insert is never mirrored")
        XCTAssertFalse(gate.isMirrorWanted(rowId: theirs.id), "and nothing lingers")
        XCTAssertTrue(gate.requestMirror(rowId: ours.id), "resolved: later edits push normally")
    }

    /// A push the flusher could not deliver (offline) stays deferred: the op is
    /// still queued, so the row is still unresolved.
    func testRuleGKeepsATransientlyFailedInsertUnresolved() async throws {
        let b = mintBlock("2026-09-24")
        try enqueueMint(b, .insert)
        await gateway.fail(b.id, times: 1, with: URLError(.notConnectedToInternet))
        await flusher.flush(userId: "u1")
        XCTAssertTrue(flusher.mirrorGate.isUnresolved(rowId: b.id))
        XCTAssertFalse(flusher.mirrorGate.requestMirror(rowId: b.id))
        let recorder = ResolutionRecorder()
        await flusher.setOnInsertResolved { recorder.add($0) }
        await flusher.flush(userId: "u1")
        XCTAssertEqual(recorder.of(b.id)?.outcome, .inserted)
        XCTAssertEqual(recorder.of(b.id)?.mirrorWanted, true)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ v: Bool) { lock.withLock { stored = v } }
    var value: Bool? { lock.withLock { stored } }
}

// MARK: - the requests supabase-swift 2.46 actually sends (stage 2)
//
// Step 0 verified the SERVER's answers to these exact requests live
// (audit/parity-2026-09-23/stage2-check.mjs). These pin that the SDK sends
// them: `Prefer: resolution=ignore-duplicates,return=representation` with
// `on_conflict=id` for the insert (a `.select()` after `upsert` must not drop
// the resolution), and a filtered PATCH with `return=representation`.

final class SyncGatewayInsertRequestTests: XCTestCase {
    private let uid = "11111111-1111-4111-8111-111111111111"
    private let block = CalBlock(id: occurrenceId(taskId: "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60", date: "2026-09-24"),
                                 taskId: "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60", taskName: "Gym",
                                 startTime: "07:00", durationMinutes: 30, date: "2026-09-24", kind: .task)

    private func gateway() -> SyncGateway {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PostgrestStubProtocol.self]
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://stub.invalid")!, supabaseKey: "anon",
            options: .init(auth: .init(storage: MemoryAuthStorage(), autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return SyncGateway(client)
    }

    private func query(_ r: URLRequest) -> [String: String] {
        let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
    private func preferParts(_ r: URLRequest) -> Set<String> {
        Set((r.value(forHTTPHeaderField: "Prefer") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func testGatewayInsertIfAbsentRequestShape() async throws {
        PostgrestStubProtocol.reset(bodies: [#"[{"id":"\#(block.id)"}]"#, "[]"], status: 201)
        let gw = gateway()
        let inserted = try await gw.insertIfAbsent(CalBlockRow(block), table: "cal_blocks", userId: uid)
        let ignored = try await gw.insertIfAbsent(CalBlockRow(block), table: "cal_blocks", userId: uid)
        XCTAssertTrue(inserted, "one row back = inserted")
        XCTAssertFalse(ignored, "[] = the server already had the id")

        let requests = PostgrestStubProtocol.recorded()
        XCTAssertEqual(requests.count, 2)
        let r = try XCTUnwrap(requests.first)
        XCTAssertEqual(r.request.httpMethod, "POST")
        XCTAssertEqual(r.request.url?.path, "/rest/v1/cal_blocks")
        let q = query(r.request)
        XCTAssertEqual(q["on_conflict"], "id")
        XCTAssertEqual(q["select"], "id")
        XCTAssertEqual(preferParts(r.request), ["resolution=ignore-duplicates", "return=representation"],
                       "ignore-duplicates must survive the .select()")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, block.id)
        XCTAssertEqual(body["user_id"] as? String, uid)
        XCTAssertEqual(body["start_time"] as? String, "07:00")
    }

    func testGatewayRetimeIfOpenRequestShape() async throws {
        let row = #"[{"id":"\#(block.id)","task_id":null,"task_name":"Gym","start_time":"16:00","duration_minutes":45,"date":"2026-09-24","external_event_id":"evt","external_connection_id":null,"kind":"task","done":false,"skipped":false,"completed_at":null}]"#
        PostgrestStubProtocol.reset(bodies: [row, "[]"], status: 200)
        let gw = gateway()
        let hit = try await gw.retimeIfOpen(table: "cal_blocks", id: block.id, date: "2026-09-24",
                                            startTime: "16:00", durationMinutes: 45)
        let miss = try await gw.retimeIfOpen(table: "cal_blocks", id: block.id, date: "2026-09-24",
                                             startTime: "16:00", durationMinutes: 45)
        let server = try JSONDecoder().decode(CalBlockRow.self, from: XCTUnwrap(hit))
        XCTAssertEqual(server.startTime, "16:00")
        XCTAssertEqual(server.externalEventId, "evt")
        XCTAssertNil(miss, "[] = moved, done, skipped or gone")

        let r = try XCTUnwrap(PostgrestStubProtocol.recorded().first)
        XCTAssertEqual(r.request.httpMethod, "PATCH")
        XCTAssertEqual(r.request.url?.path, "/rest/v1/cal_blocks")
        let q = query(r.request)
        XCTAssertEqual(q["id"], "eq.\(block.id)")
        XCTAssertEqual(q["date"], "eq.2026-09-24")
        XCTAssertEqual(q["done"], "is.false")
        XCTAssertEqual(q["skipped"], "is.false")
        XCTAssertNil(q["on_conflict"])
        XCTAssertEqual(preferParts(r.request), ["return=representation"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["start_time", "duration_minutes"], "column-scoped: nothing else is written")
        XCTAssertEqual(body["start_time"] as? String, "16:00")
        XCTAssertEqual(body["duration_minutes"] as? Int, 45)
    }
}

/// Answers PostgREST requests from a queue of bodies and records each request
/// with its body (inside a URLProtocol the body arrives as a stream).
private final class PostgrestStubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded { let request: URLRequest; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [Recorded] = []
    nonisolated(unsafe) private static var bodies: [String] = []
    nonisolated(unsafe) private static var status = 200

    static func reset(bodies: [String], status: Int) {
        lock.withLock { requests = []; Self.bodies = bodies; Self.status = status }
    }
    static func recorded() -> [Recorded] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let (answer, code): (String, Int) = Self.lock.withLock {
            Self.requests.append(Recorded(request: request, body: body))
            return (Self.bodies.isEmpty ? "[]" : Self.bodies.removeFirst(), Self.status)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Session storage that lives and dies with the test — NOT the keychain.
private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
