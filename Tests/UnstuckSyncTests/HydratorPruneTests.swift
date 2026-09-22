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
    /// Runs while the tasks read is "in flight" — lets a test queue an edit
    /// between the prune's fetch and its rewrite.
    private let onFetch: (@Sendable () async -> Void)?
    init(taskRows: [TaskRow], onFetch: (@Sendable () async -> Void)? = nil) {
        self.taskRows = taskRows
        self.onFetch = onFetch
    }
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        if table == "tasks", let rows = taskRows as? [Row] { return rows }
        return []
    }
    func fetchAllRaw(table: String) async throws -> [Data] {
        guard table == "tasks" else { return [] }
        await onFetch?()
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

    // MARK: - skew-safe prune (the op carries the BASE it was edited on top of)

    /// The finding's scenario: the phone clock is 3 minutes SLOW. The user
    /// renames the task offline at a device time that is EARLIER than the
    /// server row's (unchanged) updated_at. The old device-vs-server compare
    /// pruned the genuine edit silently. With the base recorded, "did the
    /// server move underneath me?" is server-clock vs server-clock: it didn't
    /// (base == server), so the op is kept and flushed.
    func testSlowDeviceClockDoesNotPruneAGenuineOfflineEdit() async throws {
        let serverStamp = "2026-05-21T10:00:00.123456+00:00"
        let base = TaskItem(id: "t1", name: "server", estimateMin: 25,
                            createdAt: "2026-05-21T09:00:00.000Z", updatedAt: serverStamp)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "renamed-offline", updatedAt: "2026-05-21T09:57:00.000Z"),
                            nowISO: "2026-05-21T09:57:00.000Z",
                            baseUpdatedAt: serverStamp,
                            basePayload: String(data: try JSONEncoder().encode(TaskRow(base)), encoding: .utf8))
        let read = FakeReadGateway(taskRows: [TaskRow(base)])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: "u1")

        let upserts = await write.upserts
        XCTAssertEqual(upserts.map(\.name), ["renamed-offline"], "the edit must survive a slow device clock")
    }

    /// A real conflict: the web COMPLETED the task while the phone renamed it
    /// offline. Neither edit may be dropped — the op is 3-way merged onto the
    /// newer server row (rename from the op, done from the server), the local
    /// row updated, and the merged op flushed.
    func testConflictIsThreeWayMergedInsteadOfDropped() async throws {
        let baseStamp = "2026-05-21T10:00:00.000000+00:00"
        let base = TaskItem(id: "t1", name: "old name", estimateMin: 25,
                            createdAt: "2026-05-21T09:00:00.000Z", updatedAt: baseStamp)
        try db.save(TaskItem(id: "t1", name: "new name", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000Z", updatedAt: "2026-05-21T10:03:00.000Z"))
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "new name", updatedAt: "2026-05-21T10:03:00.000Z"),
                            nowISO: "2026-05-21T10:03:00.000Z",
                            baseUpdatedAt: baseStamp,
                            basePayload: String(data: try JSONEncoder().encode(TaskRow(base)), encoding: .utf8))
        var serverRow = TaskItem(id: "t1", name: "old name", estimateMin: 25,
                                 createdAt: "2026-05-21T09:00:00.000Z", updatedAt: "2026-05-21T10:05:00.000000+00:00")
        serverRow.done = true
        serverRow.completedAt = "2026-05-21T10:05:00.000Z"
        let read = FakeReadGateway(taskRows: [TaskRow(serverRow)])
        let hydrator = Hydrator(gateway: read, db: db)
        let write = RecordingGateway()
        let flusher = OutboxFlusher(gateway: write, db: db)

        await hydrator.pruneStaleTaskOps()
        // The op was re-based and rewritten, not dropped.
        let op = try XCTUnwrap(box.pending().first)
        XCTAssertEqual(op.baseUpdatedAt, "2026-05-21T10:05:00.000000+00:00")
        let merged = try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(op.payload?.data(using: .utf8)))
        XCTAssertEqual(merged.name, "new name", "the offline rename is kept")
        XCTAssertTrue(merged.done, "the web completion is kept")
        XCTAssertEqual(merged.completedAt, "2026-05-21T10:05:00.000Z")
        // The local row follows the merge so the UI shows both changes.
        let local = try XCTUnwrap(db.fetchById(TaskItem.self, id: "t1"))
        XCTAssertEqual(local.name, "new name")
        XCTAssertTrue(local.done)

        await flusher.flush(userId: "u1")
        let upserts = await write.upserts
        XCTAssertEqual(upserts.map(\.name), ["new name"])
    }

    /// A legacy op (enqueued by an older build, no base) still uses the
    /// device-clock compare — but with a skew margin: a server row newer by
    /// less than the allowance is NOT proof the edit is stale.
    func testLegacyOpWithinTheSkewMarginIsKept() async throws {
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: try taskPayload(id: "t1", name: "offline", updatedAt: "2026-05-21T10:00:00.000Z"),
                            nowISO: "2026-05-21T10:00:00.000Z")
        let read = FakeReadGateway(taskRows: [
            TaskRow(TaskItem(id: "t1", name: "server", estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000Z", updatedAt: "2026-05-21T10:00:01.500Z"))   // +1.5s
        ])
        let hydrator = Hydrator(gateway: read, db: db)
        await hydrator.pruneStaleTaskOps()
        XCTAssertEqual(try box.count(), 1, "1.5s of skew must not prune a legacy op")
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

    // MARK: - two or more queued edits to one task (audit 2026-09-22, C9)
    //
    // Every TaskEditor field change is its own op, and each op's base is the
    // LOCAL row it was made on — so only the first op's base is a server stamp.
    // These enqueue through the real WriteThrough, exactly as the app does.

    private func edit(_ t: TaskItem, at: String, _ change: (inout TaskItem) -> Void) -> TaskItem {
        var next = t
        change(&next)
        next.updatedAt = at
        return next
    }

    private func row(_ op: OutboxOp?) throws -> TaskRow {
        try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(op?.payload?.data(using: .utf8)))
    }

    /// Case A: two offline edits (a rename, then an estimate), THEN the web
    /// completes the task. The second op used to be merged against the raw
    /// server row: the name was unchanged versus ITS base, so it took the
    /// server's old name and the rename was lost on the server and the phone.
    func testTwoOfflineEditsBothSurviveAWebCompletionThatLandsAfterThem() async throws {
        let s0 = TaskItem(id: "t1", name: "Call mom", estimateMin: 25,
                          createdAt: "2026-05-21T08:00:00.000Z", updatedAt: "2026-05-21T09:00:00.000000+00:00")
        try db.save(s0)
        let write = WriteThrough(db: db)
        let e1 = edit(s0, at: "2026-05-21T09:10:00.000Z") { $0.name = "Call mom re: birthday" }
        try await write.upsertTask(e1, nowISO: e1.updatedAt)
        let e2 = edit(e1, at: "2026-05-21T09:11:00.000Z") { $0.estimateMin = 10 }
        try await write.upsertTask(e2, nowISO: e2.updatedAt)
        let s1 = edit(s0, at: "2026-05-21T09:30:00.000000+00:00") {
            $0.done = true
            $0.completedAt = "2026-05-21T09:30:00.000Z"
        }
        let hydrator = Hydrator(gateway: FakeReadGateway(taskRows: [TaskRow(s1)]), db: db)

        await hydrator.pruneStaleTaskOps()

        let ops = try box.pending()
        XCTAssertEqual(ops.count, 2, "both edits stay queued")
        let op1 = try row(ops.first), op2 = try row(ops.last)
        XCTAssertEqual(op1.name, "Call mom re: birthday")
        XCTAssertEqual(op1.estimateMin, 25)
        XCTAssertTrue(op1.done, "the web completion is kept in the first op")
        XCTAssertEqual(op2.name, "Call mom re: birthday", "the second op must not revert the rename")
        XCTAssertEqual(op2.estimateMin, 10)
        XCTAssertTrue(op2.done)
        XCTAssertEqual(op2.completedAt, "2026-05-21T09:30:00.000Z")
        XCTAssertEqual(ops.map(\.baseUpdatedAt), [s1.updatedAt, s1.updatedAt], "both re-based on the server stamp")
        let op2Base = try JSONDecoder().decode(TaskRow.self, from: XCTUnwrap(ops.last?.basePayload?.data(using: .utf8)))
        XCTAssertEqual(op2Base.name, op1.name, "the second op's base is the first op's merged row")
        XCTAssertEqual(op2Base.done, op1.done)
        XCTAssertEqual(op2Base.estimateMin, op1.estimateMin)
        let local = try XCTUnwrap(db.fetchById(TaskItem.self, id: "t1"))
        XCTAssertEqual(local.name, "Call mom re: birthday")
        XCTAssertEqual(local.estimateMin, 10)
        XCTAssertTrue(local.done)

        let recorder = RecordingGateway()
        await OutboxFlusher(gateway: recorder, db: db).flush(userId: "u1")
        let upserts = await recorder.upserts
        XCTAssertEqual(upserts.map(\.name), ["Call mom re: birthday", "Call mom re: birthday"])
    }

    /// Case B: the web completed the task BEFORE the phone's two offline
    /// edits. The second op's base was the first op's device stamp, later
    /// than the web change, so it was judged "server unchanged" and flushed
    /// its done=false over the completion.
    func testTwoOfflineEditsDoNotReopenAnEarlierWebCompletion() async throws {
        let s0 = TaskItem(id: "t1", name: "Call mom", estimateMin: 25,
                          createdAt: "2026-05-21T07:00:00.000Z", updatedAt: "2026-05-21T08:00:00.000000+00:00")
        try db.save(s0)
        let write = WriteThrough(db: db)
        let e1 = edit(s0, at: "2026-05-21T09:00:00.000Z") { $0.name = "Call mom re: birthday" }
        try await write.upsertTask(e1, nowISO: e1.updatedAt)
        let e2 = edit(e1, at: "2026-05-21T09:01:00.000Z") { $0.estimateMin = 10 }
        try await write.upsertTask(e2, nowISO: e2.updatedAt)
        let s1 = edit(s0, at: "2026-05-21T08:50:00.000000+00:00") {
            $0.done = true
            $0.completedAt = "2026-05-21T08:50:00.000Z"
        }
        let hydrator = Hydrator(gateway: FakeReadGateway(taskRows: [TaskRow(s1)]), db: db)

        await hydrator.pruneStaleTaskOps()

        let last = try row(box.pending().last)
        XCTAssertTrue(last.done, "the last op to land must not re-open the web completion")
        XCTAssertEqual(last.completedAt, "2026-05-21T08:50:00.000Z")
        XCTAssertEqual(last.name, "Call mom re: birthday")
        XCTAssertEqual(last.estimateMin, 10)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.done, true)
    }

    /// A slow device clock with an UNCHANGED server row: the second op's
    /// device-stamped base (09:57) reads as earlier than the server's 10:00, so
    /// it was judged a conflict and merged against the server row — reverting
    /// the rename with no web edit at all. The head's server base says "keep".
    func testASlowClockDoesNotMergeASecondEditAgainstAnUnchangedServerRow() async throws {
        let s0 = TaskItem(id: "t1", name: "Call mom", estimateMin: 25,
                          createdAt: "2026-05-21T08:00:00.000Z", updatedAt: "2026-05-21T10:00:00.000000+00:00")
        try db.save(s0)
        let write = WriteThrough(db: db)
        let e1 = edit(s0, at: "2026-05-21T09:57:00.000Z") { $0.name = "Call mom re: birthday" }
        try await write.upsertTask(e1, nowISO: e1.updatedAt)
        let e2 = edit(e1, at: "2026-05-21T09:57:30.000Z") { $0.estimateMin = 10 }
        try await write.upsertTask(e2, nowISO: e2.updatedAt)
        let before = try box.pending()
        let hydrator = Hydrator(gateway: FakeReadGateway(taskRows: [TaskRow(s0)]), db: db)

        await hydrator.pruneStaleTaskOps()

        XCTAssertEqual(try box.pending(), before, "an unmoved server row leaves the whole chain untouched")
        let local = try XCTUnwrap(db.fetchById(TaskItem.self, id: "t1"))
        XCTAssertEqual(local.name, "Call mom re: birthday")
        XCTAssertEqual(local.estimateMin, 10)

        let recorder = RecordingGateway()
        await OutboxFlusher(gateway: recorder, db: db).flush(userId: "u1")
        let upserts = await recorder.upserts
        XCTAssertEqual(upserts.map(\.name), ["Call mom re: birthday", "Call mom re: birthday"])
    }

    /// Mark done, then Undo, while the web renamed the task. The first prune
    /// merges both; then only the first op lands. The Undo must survive the
    /// next prune — it used to be re-based on the RAW server row (not done),
    /// so against the landed completion its done=false looked "unchanged".
    func testAnUndoQueuedBehindAMergedCompletionSurvivesAPartialFlush() async throws {
        let s0 = TaskItem(id: "t1", name: "Call mom", estimateMin: 25,
                          createdAt: "2026-05-21T08:00:00.000Z", updatedAt: "2026-05-21T09:00:00.000000+00:00")
        try db.save(s0)
        let write = WriteThrough(db: db)
        let done = edit(s0, at: "2026-05-21T09:10:00.000Z") {
            $0.done = true
            $0.completedAt = "2026-05-21T09:10:00.000Z"
        }
        try await write.upsertTask(done, nowISO: done.updatedAt)
        let undo = edit(done, at: "2026-05-21T09:11:00.000Z") {
            $0.done = false
            $0.completedAt = nil
        }
        try await write.upsertTask(undo, nowISO: undo.updatedAt)
        let s1 = edit(s0, at: "2026-05-21T09:30:00.000000+00:00") { $0.name = "Web name" }

        await Hydrator(gateway: FakeReadGateway(taskRows: [TaskRow(s1)]), db: db).pruneStaleTaskOps()

        let first = try box.pending()
        XCTAssertEqual(try row(first.first).name, "Web name")
        XCTAssertTrue(try row(first.first).done)
        XCTAssertEqual(try row(first.last).name, "Web name")
        XCTAssertFalse(try row(first.last).done)

        // Only the completion lands; the server now holds it, stamped later.
        let op1 = try XCTUnwrap(first.first)
        var landed = try row(op1)
        landed.updatedAt = "2026-05-21T09:40:00.000000+00:00"
        try box.markDone(XCTUnwrap(op1.opSeq))

        await Hydrator(gateway: FakeReadGateway(taskRows: [landed]), db: db).pruneStaleTaskOps()

        let undoOp = try row(XCTUnwrap(box.pending().first))
        XCTAssertFalse(undoOp.done, "the Undo must not be lost to the landed completion")
        XCTAssertNil(undoOp.completedAt)
        XCTAssertEqual(undoOp.name, "Web name")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.done, false)
    }

    /// An edit queued WHILE the prune's server read is in flight. The prune
    /// read the ops before the fetch and saved its merged row after it, so the
    /// new edit's local row was overwritten and its op flushed unmerged.
    func testAnEditQueuedWhileThePruneIsFetchingJoinsTheChain() async throws {
        let s0 = TaskItem(id: "t1", name: "Call mom", estimateMin: 25,
                          createdAt: "2026-05-21T08:00:00.000Z", updatedAt: "2026-05-21T09:00:00.000000+00:00")
        try db.save(s0)
        let write = WriteThrough(db: db)
        let e1 = edit(s0, at: "2026-05-21T09:10:00.000Z") { $0.name = "Call mom re: birthday" }
        try await write.upsertTask(e1, nowISO: e1.updatedAt)
        let e2 = edit(e1, at: "2026-05-21T09:11:00.000Z") { $0.estimateMin = 10 }
        let s1 = edit(s0, at: "2026-05-21T09:30:00.000000+00:00") {
            $0.done = true
            $0.completedAt = "2026-05-21T09:30:00.000Z"
        }
        let gateway = FakeReadGateway(taskRows: [TaskRow(s1)], onFetch: {
            try? await write.upsertTask(e2, nowISO: e2.updatedAt)
        })

        await Hydrator(gateway: gateway, db: db).pruneStaleTaskOps()

        let ops = try box.pending()
        XCTAssertEqual(ops.count, 2)
        let op2 = try row(ops.last)
        XCTAssertTrue(op2.done, "the edit queued mid-fetch is merged too")
        XCTAssertEqual(op2.name, "Call mom re: birthday")
        XCTAssertEqual(op2.estimateMin, 10)
        let local = try XCTUnwrap(db.fetchById(TaskItem.self, id: "t1"))
        XCTAssertEqual(local.estimateMin, 10, "the local row follows the LAST op, not the first op's merge")
        XCTAssertEqual(local.name, "Call mom re: birthday")
        XCTAssertTrue(local.done)
    }
}
