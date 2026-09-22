// The local `call_requests` mirror (calls build-out iOS §4) — driven the way
// the sync rules demand: the REAL Hydrator / CatchUpPuller / SyncCursorStore
// over a real in-memory GRDB store and a fake server whose rows change
// mid-test while NO realtime event is ever delivered. Realtime is an
// optimisation; these tests prove the hydrate + the cursor catch-up keep the
// mirror correct on their own — and that the app's readers (get_calls via
// MirrorFirstCallStore, the deep link, the task editor) answer from it,
// offline included. Plus the bell's "Unstuck called you about X" card (pure).

import XCTest
import UnstuckCore
import UnstuckData
import UnstuckSync
@testable import Unstuck

/// A server exposing exactly the reads the hydrate + catch-up use. Rows are
/// stored as encoded JSON so the actor stays Sendable.
private actor FakeCallServer: SyncReadGatewayProtocol {
    private var rows: [String: [String: Data]] = [:]
    private(set) var pageRequests: [(table: String, atOrAfter: String?)] = []
    private var failAll = false
    func setFailAll(_ on: Bool) { failAll = on }

    func put(_ table: String, _ row: CallRequest) throws {
        rows[table, default: [:]][row.id] = try JSONEncoder().encode(row)
    }
    func remove(_ table: String, id: String) { rows[table]?.removeValue(forKey: id) }

    private static func field(_ key: String, _ raw: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?[key] as? String
    }

    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        if failAll { throw URLError(.notConnectedToInternet) }
        let dec = JSONDecoder()
        return (rows[table] ?? [:]).values.compactMap { try? dec.decode(Row.self, from: $0) }
    }
    func fetchAllRaw(table: String) async throws -> [Data] {
        if failAll { throw URLError(.notConnectedToInternet) }
        return Array((rows[table] ?? [:]).values)
    }
    func fetchPageSince(table: String, column: String, atOrAfter: String?, limit: Int) async throws -> [Data] {
        if failAll { throw URLError(.notConnectedToInternet) }
        pageRequests.append((table, atOrAfter))
        let kept = (rows[table] ?? [:]).values.filter { raw in
            guard let v = Self.field(column, raw) else { return false }
            guard let after = atOrAfter else { return true }
            return v >= after
        }
        return Array(kept.sorted { (Self.field(column, $0) ?? "") < (Self.field(column, $1) ?? "") }.prefix(limit))
    }
    func fetchIdPage(table: String, afterId: String?, limit: Int) async throws -> [String] {
        if failAll { throw URLError(.notConnectedToInternet) }
        let ids = (rows[table] ?? [:]).keys.sorted().filter { id in
            guard let afterId else { return true }
            return id > afterId
        }
        return Array(ids.prefix(limit))
    }
}

@MainActor
final class CallsMirrorTests: XCTestCase {
    private let uid = "11111111-1111-1111-1111-111111111111"
    private var db: AppDatabase!
    private var server: FakeCallServer!
    private var mirror: CallRequestsMirror!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        server = FakeCallServer()
        mirror = CallRequestsMirror(db)
    }

    private func call(_ id: String, label: String = "speak to James", status: String = "scheduled",
                      taskId: String? = nil, callAt: String = "2026-09-20T14:45:00.000Z",
                      updatedAt: String, notes: [String] = ["Ask about the invoice"], kind: String = "requested") -> CallRequest {
        CallRequest(id: id, userId: uid, taskId: taskId, blockId: taskId.map { _ in "b1" }, callAt: callAt,
                    leadMin: taskId == nil ? nil : 15, label: label, notes: notes, status: status,
                    kind: kind, createdAt: "2026-09-20T08:00:00.000Z", updatedAt: updatedAt)
    }

    private func hydrator() -> Hydrator { Hydrator(gateway: server, db: db) }
    private func puller() -> CatchUpPuller { CatchUpPuller(gateway: server, db: db, fullFallback: { _ in true }) }

    // MARK: - hydrate

    func testHydrateReplacesTheMirrorServerCanonically() async throws {
        try db.save(call("stale", updatedAt: "2026-09-20T09:00:00.000Z"))
        try await server.put("call_requests", call("c1", updatedAt: "2026-09-20T10:00:00.000Z"))
        try await server.put("call_requests", call("c2", label: "the dentist", status: "done",
                                                   callAt: "2026-09-20T15:00:00.000Z", updatedAt: "2026-09-20T10:30:00.000Z"))
        let hydrated = await hydrator().hydrateCallRequests(); XCTAssertTrue(hydrated)
        XCTAssertEqual(try mirror.all().map(\.id), ["c1", "c2"], "the server's rows, in call_at order")
        XCTAssertEqual(try mirror.live().map(\.id), ["c1"], "done is not live")
        XCTAssertEqual(try mirror.get(id: "c2")?.notes, ["Ask about the invoice"], "JSON columns round-trip")
        XCTAssertEqual(try mirror.get(id: "c2")?.kind, "requested")
        XCTAssertNil(try mirror.get(id: "stale"), "a row the server no longer has is gone")
    }

    func testHydrateKeepsALocalBookingNewerThanEveryServerRow() async throws {
        // The row was booked (direct write → mirrored) after this fetch started:
        // it is newer than anything the server returned, so it survives until
        // the next pull confirms it — never yanked off the UI.
        try await server.put("call_requests", call("c1", updatedAt: "2026-09-20T10:00:00.000Z"))
        try mirror.upsert(call("fresh", label: "ring the bank", updatedAt: "2026-09-20T10:00:05.000Z"))
        try mirror.upsert(call("old", label: "an old one", updatedAt: "2026-09-19T10:00:00.000Z"))
        let hydrated = await hydrator().hydrateCallRequests(); XCTAssertTrue(hydrated)
        XCTAssertEqual(Set(try mirror.all().map(\.id)), ["c1", "fresh"], "the older local-only row is dropped")
        // Pure rule.
        let merged = CallRequestsMirror.mergeHydrated(remote: [], local: [call("x", updatedAt: "2026-09-20T10:00:00.000Z")])
        XCTAssertEqual(merged.map(\.id), ["x"], "an empty server keeps a fresh local booking")
    }

    func testHydrateFailureLeavesTheMirrorIntact() async throws {
        try mirror.upsert(call("c1", updatedAt: "2026-09-20T10:00:00.000Z"))
        await server.setFailAll(true)
        let hydrated = await hydrator().hydrateCallRequests(); XCTAssertFalse(hydrated)
        XCTAssertEqual(try mirror.all().map(\.id), ["c1"])
    }

    func testHydrateRunsInsideTheFullHydrate() async throws {
        try await server.put("call_requests", call("c1", updatedAt: "2026-09-20T10:00:00.000Z"))
        await hydrator().hydrate(userId: uid)
        XCTAssertEqual(try mirror.all().map(\.id), ["c1"])
    }

    // MARK: - catch-up (the correctness path)

    func testCatchUpAppliesADeltaAndAdvancesTheCursor() async throws {
        let c1 = call("c1", updatedAt: "2026-09-20T10:00:00.000Z")
        try await server.put("call_requests", c1)
        let hydrated = await hydrator().hydrateCallRequests(); XCTAssertTrue(hydrated)
        let p = puller()
        // Seed the cursor (first pull after sign-in).
        _ = await p.catchUp(userId: uid, reconcileDeletions: false)
        let cursors = SyncCursorStore(db)
        XCTAssertEqual(try cursors.cursor(userId: uid, table: "call_requests"), "2026-09-20T10:00:00.000Z")

        // THE GAP: the dispatcher flips c1 to `calling`, then the phone's
        // outcome report to `missed`; a new call is booked on the web. No
        // realtime event is delivered.
        var moved = c1; moved.status = "missed"; moved.updatedAt = "2026-09-20T14:46:00.000Z"
        try await server.put("call_requests", moved)
        try await server.put("call_requests", call("web", label: "the dentist", updatedAt: "2026-09-20T14:47:00.000Z"))
        let outcome = await p.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertEqual(outcome.rowsApplied, 2)
        XCTAssertEqual(try mirror.get(id: "c1")?.status, "missed")
        XCTAssertEqual(try mirror.live().map(\.id), ["web"], "the missed call left the live list; the web booking joined it")
        XCTAssertEqual(try cursors.cursor(userId: uid, table: "call_requests"), "2026-09-20T14:47:00.000Z")
        let requests = await server.pageRequests
        XCTAssertEqual(requests.last?.atOrAfter, "2026-09-20T10:00:00.000Z", "a DELTA from the cursor, not a full replace")
        XCTAssertTrue(CatchUpPuller.deltaTableNames.contains("call_requests"))
    }

    func testCatchUpNeverRewindsARowARealtimeEchoAlreadyAdvanced() async throws {
        // LWW: the mirror already holds the newer row (a realtime echo landed
        // first); a page carrying the older stamp must not clobber it.
        var newer = call("c1", updatedAt: "2026-09-20T15:00:00.000Z"); newer.status = "done"
        try mirror.upsert(newer)
        var older = newer; older.status = "answered"; older.updatedAt = "2026-09-20T14:50:00.000Z"
        try await server.put("call_requests", older)
        _ = await puller().catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertEqual(try mirror.get(id: "c1")?.status, "done")
        // And the mirror's own write-through follows the same rule.
        try mirror.upsert(older)
        XCTAssertEqual(try mirror.get(id: "c1")?.status, "done", "upsert of a staler row is a no-op")
        try mirror.upsert(call("c1", status: "cancelled", updatedAt: "2026-09-20T15:01:00.000Z"))
        XCTAssertEqual(try mirror.get(id: "c1")?.status, "cancelled", "a newer row wins")
    }

    func testCatchUpReconcileDropsTheServersPrunedRows() async throws {
        // The nightly prune hard-deletes done/cancelled/stale rows older than
        // 30 days — invisible to a cursor pull; the id reconcile sees it.
        try await server.put("call_requests", call("keep", updatedAt: "2026-09-20T10:00:00.000Z"))
        try await server.put("call_requests", call("pruned", status: "done", updatedAt: "2026-08-01T10:00:00.000Z"))
        let hydrated = await hydrator().hydrateCallRequests(); XCTAssertTrue(hydrated)
        await server.remove("call_requests", id: "pruned")
        let outcome = await puller().catchUp(userId: uid, reconcileDeletions: true)
        XCTAssertEqual(outcome.idsDropped, 1)
        XCTAssertEqual(try mirror.all().map(\.id), ["keep"])
    }

    // MARK: - readers

    func testMirrorFirstStoreAnswersOfflineFromTheMirror() async throws {
        // No network at all (a CallsClient is never touched when the mirror
        // has rows): get_calls / cancel_call resolve their reads locally.
        try mirror.upsert(call("c1", taskId: "t1", updatedAt: "2026-09-20T10:00:00.000Z"))
        try mirror.upsert(call("c2", label: "the dentist", status: "snoozed", callAt: "2026-09-20T15:00:00.000Z",
                               updatedAt: "2026-09-20T10:01:00.000Z"))
        try mirror.upsert(call("c3", label: "done one", status: "done", callAt: "2026-09-20T16:00:00.000Z",
                               updatedAt: "2026-09-20T10:02:00.000Z"))
        XCTAssertEqual(try mirror.live().map(\.id), ["c1", "c2"])
        XCTAssertEqual(try mirror.forTask(taskId: "t1")?.id, "c1")
        XCTAssertNil(try mirror.forTask(taskId: "nope"))
        XCTAssertFalse(try mirror.isEmpty())
        // The formatted get_calls output comes straight off the mirror rows.
        let text = CallToolLogic.formatCalls(try mirror.live(), taskName: { $0 == "t1" ? "Speak to James" : nil })
        XCTAssertTrue(text.hasPrefix("ok: 2 upcoming calls:"))
        XCTAssertTrue(text.contains("\"speak to James\" (1 note) for \"Speak to James\""))
        XCTAssertTrue(text.contains("\"the dentist\" (1 note) · snoozed"))
    }

    func testObserveForTaskFollowsStatusChanges() async throws {
        try mirror.upsert(call("c1", taskId: "t1", updatedAt: "2026-09-20T10:00:00.000Z"))
        var it = mirror.observeForTask(taskId: "t1").makeAsyncIterator()
        let first = try await it.next()
        XCTAssertEqual(first??.id, "c1")
        try mirror.upsert(call("c1", status: "missed", taskId: "t1", updatedAt: "2026-09-20T10:05:00.000Z"))
        let second = try await it.next()
        XCTAssertNil(second ?? nil, "a missed call is no longer the task's live call")
    }

    func testClearAllWipesTheMirror() throws {
        try mirror.upsert(call("c1", updatedAt: "2026-09-20T10:00:00.000Z"))
        try db.clearAll()
        XCTAssertTrue(try mirror.isEmpty())
        XCTAssertEqual(try db.localIds(table: "call_requests"), [])
    }

    // MARK: - the bell's "Unstuck called you about X" card

    func testQueueCardBecomesACallEntryWithTheCallsNotes() {
        let calls = [
            call("c1", label: "speak to James", status: "missed", taskId: "t1",
                 callAt: "2026-09-20T14:45:00.000Z", updatedAt: "2026-09-20T14:46:00.000Z",
                 notes: ["Ask about the invoice", "Confirm Friday"]),
            call("c0", label: "speak to James", status: "done", callAt: "2026-09-01T14:45:00.000Z",
                 updatedAt: "2026-09-01T14:46:00.000Z", notes: ["an older call, same label"]),
        ]
        let card = NotificationQueueCard(id: "q1", moment: "call", title: "Unstuck is calling",
                                         body: "Unstuck is calling about speak to James", createdAt: "2026-09-20T14:45:03.000Z")
        let e = NotificationQueueCards.entry(from: card, calls: calls)
        XCTAssertEqual(e.id, "q_q1")
        XCTAssertEqual(e.kind, "call")
        XCTAssertEqual(e.title, "Unstuck called you about speak to James")
        XCTAssertEqual(e.body, "Ask about the invoice\nConfirm Friday", "the nearest call with that label, not the older one")
        XCTAssertEqual(e.deepLink, "unstuck://task/t1?exact", "the series editor itself, never a day's occurrence (C3)")
        XCTAssertEqual(e.at, Time.parseMillis("2026-09-20T14:45:03.000Z"))
    }

    func testQueueCardWithoutAMatchingCallKeepsItsOwnCopy() {
        let card = NotificationQueueCard(id: "q2", moment: "call", title: "Unstuck is calling",
                                         body: "Unstuck is calling about the dentist", createdAt: "2026-09-20T09:00:00.000Z")
        let e = NotificationQueueCards.entry(from: card, calls: [])
        XCTAssertEqual(e.title, "Unstuck called you about the dentist")
        XCTAssertEqual(e.body, "Unstuck is calling about the dentist")
        XCTAssertEqual(e.deepLink, "unstuck://today")
        // A missed call with no notes says so; a body that isn't a call keeps the card's title.
        let missed = [call("m", label: "the dentist", status: "missed", updatedAt: "2026-09-20T09:00:30.000Z", notes: [])]
        XCTAssertEqual(NotificationQueueCards.entry(from: card, calls: missed).body, "You missed it — no notes on this one.")
        let odd = NotificationQueueCard(id: "q3", moment: "call", title: "Custom", body: "something else", createdAt: "x")
        XCTAssertEqual(NotificationQueueCards.entry(from: odd, calls: []).title, "Custom")
        XCTAssertNil(NotificationQueueCards.callLabel(fromBody: "Unstuck is calling about "))
        XCTAssertEqual(NotificationQueueCards.callLabel(fromBody: "  Unstuck is calling about ring the bank "), "ring the bank")
    }

    func testMergeRecentIsTheWebRule() {
        func entry(_ id: String, kind: String, title: String, body: String, at: Double) -> NotificationLog.Entry {
            NotificationLog.Entry(id: id, kind: kind, title: title, body: body, deepLink: nil, at: at)
        }
        let t: Double = 1_800_000_000_000
        let local = [
            entry("l1", kind: "call_missed", title: "I called about speak to James", body: "Ask", at: t + 60_000),
            entry("l2", kind: "session_recap", title: "You did the thing.", body: "", at: t),
            entry("l3", kind: "task_reminder", title: "Same copy", body: "Same", at: t - 1_000),
        ]
        let queue = [
            entry("q_1", kind: "call", title: "Unstuck called you about speak to James", body: "Ask", at: t + 3_000),
            entry("q_2", kind: "session_recap", title: "Session wrapped", body: "x", at: t + 30_000),
            entry("q_3", kind: "task_reminder", title: "Same copy", body: "Same", at: t + 2_000),
            entry("q_4", kind: "task_reminder", title: "Same copy", body: "Same", at: t + 10 * 60_000),
            entry("q_1", kind: "call", title: "dup id", body: "", at: t),
        ]
        let merged = NotificationQueueCards.mergeRecent(local: local, queue: queue)
        XCTAssertEqual(merged.map(\.id), ["q_4", "l1", "q_1", "l2", "l3"],
                       "newest first; the recap within 5 min and the same-copy card within 5 min collapse; the call card stays (different copy); a duplicate id is dropped; the far-apart same-copy card stays")
        XCTAssertEqual(NotificationQueueCards.mergeRecent(local: [], queue: Array(repeating: queue[0], count: 1), cap: 1).count, 1)
        let many = (0..<30).map { entry("q_\($0)", kind: "call", title: "t\($0)", body: "", at: t + Double($0)) }
        XCTAssertEqual(NotificationQueueCards.mergeRecent(local: [], queue: many).count, NotificationQueueCards.cap)
    }
}
