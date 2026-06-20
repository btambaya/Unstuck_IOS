// Prune-before-flush ordering (the bug-1 fix). The debounced/foreground
// flushNow() now runs Hydrator.pruneStaleTaskOps() BEFORE draining the
// outbox — like syncNow() and the auth-event path, and like Android which
// pairs every flush with a prune. Without it, a queued task op the server
// already superseded (e.g. a completion made on the web) would re-push and
// clobber the newer server state before the next prune+hydrate.
//
// These tests assemble the same two pieces flushNow() drives — a Hydrator
// and an OutboxFlusher over one in-memory outbox — and run prune→flush in
// that order, proving the stale op is dropped and never reaches the gateway,
// while a genuinely-newer offline edit survives and flushes.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Read-side fake: returns scripted server rows for prune to compare against.
private actor FakeReadGateway: SyncReadGatewayProtocol {
    private let taskRows: [TaskRow]
    init(taskRows: [TaskRow]) { self.taskRows = taskRows }
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        if table == "tasks", let rows = taskRows as? [Row] { return rows }
        return []
    }
    func fetchAllRaw(table: String) async throws -> [Data] {
        guard table == "tasks" else { return [] }
        let encoder = JSONEncoder()
        return try taskRows.map { try encoder.encode($0) }
    }
}

/// Write-side fake (mirrors OutboxFlusherTests): records successful upserts.
private actor RecordingGateway: SyncGatewayProtocol {
    private(set) var upserts: [(id: String, name: String?)] = []
    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        let data = try JSONEncoder().encode(row)
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        upserts.append((obj["id"] as? String ?? "", obj["name"] as? String))
    }
    func delete(table: String, id: String) async throws {}
}

final class HydratorPruneTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
    }

    private func taskPayload(id: String, name: String, updatedAt: String) throws -> String {
        let t = TaskItem(id: id, name: name, estimateMin: 25,
                         createdAt: "2026-05-21T09:00:00.000Z", updatedAt: updatedAt)
        return String(data: try JSONEncoder().encode(TaskRow(t)), encoding: .utf8)!
    }

    func testDebouncedFlushPrunesStaleTaskOpBeforeFlushing() async throws {
        // A queued op edited the task at 10:00 (e.g. an old done=false sitting
        // offline); the server already has a NEWER 10:05 version (completed on
        // web). flushNow() prunes first, so this op is dropped and never sent —
        // without the prune it would re-push and clobber the newer server state.
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "stale", updatedAt: "2026-05-21T10:00:00.000Z"),
                            nowISO: "2026-05-21T10:00:00.000Z")
        let read = FakeReadGateway(taskRows: [
            TaskRow(TaskItem(id: "t1", name: "server-new", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000Z", updatedAt: "2026-05-21T10:05:00.000Z"))
        ])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        // Exactly the order flushNow() now uses: prune, then flush.
        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: "u1")

        XCTAssertEqual(try box.count(), 0, "stale op pruned, then nothing left to flush")
        let upserts = await write.upserts
        XCTAssertTrue(upserts.isEmpty, "stale op must NOT re-push and clobber the newer server state")
    }

    // Bug-1 regression (Android: pruneStaleTaskOps_instantCompareNotStringCompare).
    // The server emits MICROSECONDS + "+00:00"; the local op uses MILLIS + "Z".
    // A raw string `>` compares these char-by-char, where the genuinely-newer
    // server time can sort BELOW the older local time (e.g. "…10:05:00.000000+00:00"
    // vs "…10:00:00.000Z" — '0' < 'Z' makes the server string "smaller"), so the
    // stale op would NOT be pruned and would re-push, clobbering the newer server
    // row. Parsing both to instants prunes it correctly.
    func testPrunesStaleOpAcrossMixedTimestampFormats() async throws {
        // local op: millis + Z, 10:00; server: microseconds + +00:00, 10:05 (newer).
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "stale", updatedAt: "2026-05-21T10:00:00.000Z"),
                            nowISO: "2026-05-21T10:00:00.000Z")
        let read = FakeReadGateway(taskRows: [
            TaskRow(TaskItem(id: "t1", name: "server-new", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000000+00:00",
                             updatedAt: "2026-05-21T10:05:00.123456+00:00"))
        ])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: "u1")

        XCTAssertEqual(try box.count(), 0, "newer server row (microseconds/+00:00) must prune the stale op (millis/Z)")
        let upserts = await write.upserts
        XCTAssertTrue(upserts.isEmpty, "stale op must NOT re-push and clobber the newer server state")
    }

    // The high-value flip (Android: instantCompare): a local op at
    // "…12:00:00.500Z" is genuinely NEWER than a server row at "…12:00:00Z",
    // yet string-compares as EARLIER ('.' 0x2E < 'Z' 0x5A right after "…00"),
    // so the raw `serverTime > row.updatedAt` returns TRUE and the OLD code
    // WRONGLY PRUNES the newer offline edit — silent data loss. Instant-compare
    // parses both (12:00:00.500 > 12:00:00 in ms) and KEEPS it.
    func testKeepsNewerLocalOpThatStringSortsEarlierThanServer() async throws {
        // Sanity: this pair is exactly the string-vs-instant divergence.
        XCTAssertTrue("2026-05-21T12:00:00Z" > "2026-05-21T12:00:00.500Z",
                      "precondition: server string sorts ABOVE the newer local string")
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "offline-new", updatedAt: "2026-05-21T12:00:00.500Z"),
                            nowISO: "2026-05-21T12:00:00.500Z")
        let read = FakeReadGateway(taskRows: [
            TaskRow(TaskItem(id: "t1", name: "server-old", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00Z", updatedAt: "2026-05-21T12:00:00Z"))
        ])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: "u1")

        let upserts = await write.upserts
        XCTAssertEqual(upserts.map(\.name), ["offline-new"],
                       "the genuinely-newer offline edit must survive the prune + flush")
    }

    func testNewerOfflineEditSurvivesPruneAndFlushes() async throws {
        // The genuine offline case: the queued op (10:10) is NEWER than the
        // server row (10:00). Prune must keep it, and the flush must push it.
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "offline-new", updatedAt: "2026-05-21T10:10:00.000Z"),
                            nowISO: "2026-05-21T10:10:00.000Z")
        let read = FakeReadGateway(taskRows: [
            TaskRow(TaskItem(id: "t1", name: "server-old", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000Z", updatedAt: "2026-05-21T10:00:00.000Z"))
        ])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: "u1")

        XCTAssertEqual(try box.count(), 0, "newer offline edit flushed")
        let upserts = await write.upserts
        XCTAssertEqual(upserts.map(\.name), ["offline-new"], "the newer offline edit reaches the server")
    }
}
