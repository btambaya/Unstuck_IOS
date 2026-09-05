// Hydrate's pending-row preservation (spec 02-sync-engine §1.3 localPending),
// generalised from cal_blocks/collections to EVERY synced table. The trap:
// offline, the user creates task T and completes task U (both ops queued, the
// debounced flush already failed); the network returns; the realtime socket
// reconnects first and its resync hydrates → the blanket replaceAll removed T
// and flipped U back to not-done until some later trigger flushed. A row with
// a queued upsert carries an un-acked local intent and must survive the
// server-canonical replace; tasks decide collisions base-aware (a server row
// that hasn't moved past the op's base can't out-vote the local edit even
// when the device clock is slow), other tables keep the local intent.
//
// Captures additionally hydrate their archive state (`archived_at`, 053).

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

private actor FakeRawGateway: SyncReadGatewayProtocol {
    private let rowsByTable: [String: [Data]]
    init(rowsByTable: [String: [Data]]) { self.rowsByTable = rowsByTable }
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        let dec = JSONDecoder()
        return (rowsByTable[table] ?? []).compactMap { try? dec.decode(Row.self, from: $0) }
    }
    func fetchAllRaw(table: String) async throws -> [Data] { rowsByTable[table] ?? [] }
}

final class HydratorPendingPreservationTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private let enc = JSONEncoder()

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
    }

    private func task(_ id: String, _ name: String, done: Bool = false, at: String) -> TaskItem {
        var t = TaskItem(id: id, name: name, estimateMin: 25, createdAt: "2026-05-21T08:00:00.000Z", updatedAt: at)
        t.done = done
        return t
    }
    private func taskJSON(_ t: TaskItem) throws -> Data { try enc.encode(TaskRow(t)) }
    private func json<R: Encodable>(_ r: R) throws -> Data { try enc.encode(r) }

    /// Queue an upsert op for `t` the way WriteThrough does (payload + base).
    private func enqueueTaskOp(_ t: TaskItem, baseUpdatedAt: String? = nil) throws {
        _ = try box.enqueue(table: "tasks", rowId: t.id, kind: .upsert,
                            payload: String(data: try taskJSON(t), encoding: .utf8), nowISO: t.updatedAt,
                            baseUpdatedAt: baseUpdatedAt, basePayload: nil)
    }

    func testOfflineCreatedTaskSurvivesTheReconnectHydrate() async throws {
        let t = task("new", "created offline", at: "2026-05-21T10:00:00.000Z")
        try db.save(t)
        try enqueueTaskOp(t)
        let serverOnly = task("s1", "server", at: "2026-05-21T09:00:00.000Z")
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(serverOnly)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "new")?.name, "created offline", "pending row kept")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "s1")?.name, "server", "server row pulled")
    }

    func testOfflineCompletionIsNotRevertedEvenWithASlowDeviceClock() async throws {
        // Server row: not done, stamped 10:00 (server clock). The phone, 3 min
        // slow, completed it offline at "09:58" on top of that 10:00 base.
        let serverStamp = "2026-05-21T10:00:00.000000+00:00"
        let server = task("u", "U", done: false, at: serverStamp)
        let local = task("u", "U", done: true, at: "2026-05-21T09:58:00.000Z")
        try db.save(local)
        try enqueueTaskOp(local, baseUpdatedAt: serverStamp)
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(server)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "u")?.done, true, "the un-acked completion stays on the UI")
    }

    func testRowsWithoutAPendingOpAreServerCanonical() async throws {
        try db.save(task("x", "stale local", at: "2026-05-21T11:00:00.000Z"))
        try db.save(task("gone", "deleted elsewhere", at: "2026-05-21T11:00:00.000Z"))
        let server = task("x", "server", at: "2026-05-21T10:00:00.000Z")
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(server)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "x")?.name, "server")
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "gone"))
    }

    func testPendingEditYieldsToAServerRowThatMovedPastItsBaseByLWW() async throws {
        let local = task("a", "local", at: "2026-05-21T10:03:00.000Z")
        try db.save(local)
        try enqueueTaskOp(local, baseUpdatedAt: "2026-05-21T10:00:00.000Z")
        let server = task("a", "server moved", at: "2026-05-21T10:05:00.000Z")
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(server)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "a")?.name, "server moved",
                       "server moved past the base → last-write-wins → server (the prune re-bases the op first in production)")
    }

    func testPendingRowsOfEveryOtherTableSurviveTheReplace() async throws {
        let now = "2026-05-21T10:00:00.000Z"
        let session = Session(id: "s1", taskName: "S", actualSec: 60, completedAt: now)
        let tag = TagRow(id: "tg1", name: "deep", color: nil, sortOrder: 0)
        let area = LifeArea(id: "la1", name: "Side", color: "teal", sortOrder: 0)
        let reason = ReasonLog(id: "r1", taskId: "t", reason: "tired", action: .pause, at: now)
        try db.save(session); try db.save(tag); try db.save(area); try db.save(reason)
        _ = try box.enqueue(table: "sessions", rowId: "s1", kind: .upsert, payload: String(data: try json(SessionRow(session)), encoding: .utf8), nowISO: now)
        _ = try box.enqueue(table: "tags", rowId: "tg1", kind: .upsert, payload: String(data: try json(TagDbRow(tag)), encoding: .utf8), nowISO: now)
        _ = try box.enqueue(table: "life_areas", rowId: "la1", kind: .upsert, payload: String(data: try json(LifeAreaDbRow(area)), encoding: .utf8), nowISO: now)
        _ = try box.enqueue(table: "reason_logs", rowId: "r1", kind: .upsert, payload: String(data: try json(ReasonLogRow(reason)), encoding: .utf8), nowISO: now)
        // A non-pending local session the server no longer has → dropped.
        try db.save(Session(id: "s-old", taskName: "old", actualSec: 1, completedAt: now))
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: [:]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertNotNil(try db.fetchById(Session.self, id: "s1"))
        XCTAssertNil(try db.fetchById(Session.self, id: "s-old"))
        XCTAssertNotNil(try db.fetchById(TagRow.self, id: "tg1"))
        XCTAssertNotNil(try db.fetchById(LifeArea.self, id: "la1"))
        XCTAssertNotNil(try db.fetchById(ReasonLog.self, id: "r1"))
    }

    // MARK: - captures archive (server `captures.archived_at`, migration 053)

    private func capture(_ id: String) -> Capture {
        Capture(id: id, taskId: nil, sessionId: nil, tag: .idea, body: id, at: "2026-05-21T09:00:00.000Z")
    }

    func testCapturesArchiveFollowsArchivedAtAndKeepsPendingLocalState() async throws {
        let now = "2026-05-21T10:00:00.000Z"
        // Server: c1 archived on the web, c2 open, c3 archived — but c3 has a
        // pending local UNARCHIVE (restore tapped offline).
        let rows = [try json(CaptureRow(capture("c1"), archivedAt: now)),
                    try json(CaptureRow(capture("c2"), archivedAt: nil)),
                    try json(CaptureRow(capture("c3"), archivedAt: now))]
        try db.save(capture("c3"))
        try db.setCaptureArchived(id: "c3", archivedAt: nil)
        _ = try box.enqueue(table: "captures", rowId: "c3", kind: .upsert,
                            payload: String(data: try json(CaptureRow(capture("c3"), archivedAt: nil)), encoding: .utf8), nowISO: now)
        // c4: archived offline, not on the server yet (pending).
        try db.save(capture("c4"))
        try db.setCaptureArchived(id: "c4", archivedAt: now)
        _ = try box.enqueue(table: "captures", rowId: "c4", kind: .upsert,
                            payload: String(data: try json(CaptureRow(capture("c4"), archivedAt: now)), encoding: .utf8), nowISO: now)
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["captures": rows]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.archivedCaptureIds(), ["c1", "c4"])
        XCTAssertNotNil(try db.fetchById(Capture.self, id: "c4"), "pending offline capture kept")
    }

    func testAPre053ServerCannotBlankTheLocalArchive() async throws {
        let now = "2026-05-21T10:00:00.000Z"
        try db.save(capture("c1"))
        try db.setCaptureArchived(id: "c1", archivedAt: now)
        // Rows WITHOUT the archived_at key at all (column not deployed).
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try json(CaptureRow(capture("c1")))) as? [String: Any])
        obj.removeValue(forKey: "archived_at")
        let raw = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertFalse(CaptureRow.hasArchivedAtColumn(raw))
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["captures": [raw]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.archivedCaptureIds(), ["c1"], "the local archive is left intact")
    }
}
