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
    /// Tables whose read times out (a flaky link between two back-to-back GETs).
    private let failing: Set<String>
    /// Runs as a table's read starts — lets a test land a flush between reads.
    private let onRead: (@Sendable (String) -> Void)?
    init(rowsByTable: [String: [Data]], failing: Set<String> = [], onRead: (@Sendable (String) -> Void)? = nil) {
        self.rowsByTable = rowsByTable
        self.failing = failing
        self.onRead = onRead
    }
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        if failing.contains(table) { throw URLError(.timedOut) }
        let dec = JSONDecoder()
        return (rowsByTable[table] ?? []).compactMap { try? dec.decode(Row.self, from: $0) }
    }
    func fetchAllRaw(table: String) async throws -> [Data] {
        onRead?(table)
        if failing.contains(table) { throw URLError(.timedOut) }
        return rowsByTable[table] ?? []
    }
}

/// A read gateway whose cal_blocks read can be switched between failing and
/// answering (the catch-up's full replace failing after a good hydrate).
private actor SwitchableBlocksGateway: SyncReadGatewayProtocol {
    var blocks: [Data] = []
    var failBlocks = false
    func set(_ rows: [Data], failing: Bool) { blocks = rows; failBlocks = failing }
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] { [] }
    func fetchAllRaw(table: String) async throws -> [Data] {
        guard table == "cal_blocks" else { return [] }
        if failBlocks { throw URLError(.timedOut) }
        return blocks
    }
}

/// Holds the FIRST collections read open until released, so a test can pile
/// more hydrateCollections calls up behind it.
private actor GatedCollectionsGateway: SyncReadGatewayProtocol {
    private(set) var collectionsReads = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = true
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] { [] }
    func fetchAllRaw(table: String) async throws -> [Data] {
        guard table == "collections" else { return [] }
        collectionsReads += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        return []
    }
    var isHolding: Bool { gate != nil }
    func release() {
        gate?.resume()
        gate = nil
    }
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

    /// Two queued edits on a 3-min-slow phone: the first op's base is the
    /// server stamp (10:00), the second op's is the first edit's DEVICE stamp
    /// (09:57). Judged by the last op's base, the unchanged server row "moved
    /// past" it and replaced the local edits (audit 2026-09-22, C9).
    func testHydrateJudgesAQueuedChainByItsNewestBase() async throws {
        let serverStamp = "2026-05-21T10:00:00.000000+00:00"
        let server = task("u", "U", at: serverStamp)
        var local = task("u", "renamed", at: "2026-05-21T09:57:30.000Z")
        local.estimateMin = 10
        try db.save(local)
        try enqueueTaskOp(task("u", "renamed", at: "2026-05-21T09:57:00.000Z"), baseUpdatedAt: serverStamp)
        try enqueueTaskOp(local, baseUpdatedAt: "2026-05-21T09:57:00.000Z")
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(server)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        let after = try XCTUnwrap(db.fetchById(TaskItem.self, id: "u"))
        XCTAssertEqual(after.name, "renamed", "the queued edits stay on the UI")
        XCTAssertEqual(after.estimateMin, 10)
    }

    /// A row whose only queued op is QUARANTINED still keeps its local edit:
    /// the quarantine contract is "kept in the outbox, so hydrate keeps the
    /// local row" — its base must still count.
    func testAQuarantinedOpStillProtectsItsRowFromTheHydrate() async throws {
        let serverStamp = "2026-05-21T10:00:00.000000+00:00"
        let server = task("q", "Q", at: serverStamp)
        let local = task("q", "stuck local edit", at: "2026-05-21T09:58:00.000Z")
        try db.save(local)
        try enqueueTaskOp(local, baseUpdatedAt: serverStamp)
        let seq = try XCTUnwrap(box.pending().first?.opSeq)
        for _ in 0..<OutboxStore.quarantineCap { _ = try box.bumpAttempts(seq) }
        XCTAssertTrue(try XCTUnwrap(box.pending().first).isQuarantined)
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["tasks": [try taskJSON(server)]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "q")?.name, "stuck local edit")
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

    // MARK: - collections membership (audit 2026-09-22, C8)
    //
    // `isShared` reads the local members[]: an owner's list with no members
    // routes item edits as whole-row upserts that overwrite what members added.

    private func list(_ id: String, owner: String, members: [String]? = nil, role: String? = nil,
                      items: [CollectionItem] = []) -> ItemCollection {
        ItemCollection(id: id, name: id, color: "indigo", items: items, sortOrder: 0,
                       ownerId: owner, members: members, myRole: role)
    }

    /// A server `collections` row: CollectionRow never encodes `user_id`.
    private func listJSON(_ c: ItemCollection) throws -> Data {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try json(CollectionRow(c))) as? [String: Any])
        obj["user_id"] = c.ownerId
        obj["updated_at"] = "2026-05-21T10:00:00.000000+00:00"
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func memberJSON(_ collectionId: String, _ userId: String, role: String = "editor") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "\(collectionId)-\(userId)", "collection_id": collectionId,
                                                    "user_id": userId, "role": role])
    }

    func testAFailedMembersReadKeepsEveryListsKnownMembership() async throws {
        try db.save(list("c1", owner: "u1", members: ["p1"], role: "owner"))
        try db.save(list("c2", owner: "o2", members: ["u1"], role: "viewer"))
        let gateway = FakeRawGateway(rowsByTable: ["collections": [try listJSON(list("c1", owner: "u1")),
                                                                   try listJSON(list("c2", owner: "o2"))]],
                                     failing: ["collection_members"])

        await Hydrator(gateway: gateway, db: db).hydrateCollections(userId: "u1")

        let c1 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c1"))
        XCTAssertEqual(c1.members, ["p1"], "the owner's list still reads as shared, so edits keep using the RPCs")
        XCTAssertEqual(c1.myRole, "owner")
        let c2 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c2"))
        XCTAssertEqual(c2.myRole, "viewer", "a viewer must not get edit controls from a failed read")
        XCTAssertEqual(c2.members, ["u1"])
    }

    func testASuccessfulEmptyMembersReadIsAuthoritative() async throws {
        try db.save(list("c1", owner: "u1", members: ["p1"], role: "owner"))
        let gateway = FakeRawGateway(rowsByTable: ["collections": [try listJSON(list("c1", owner: "u1"))],
                                                   "collection_members": []])

        await Hydrator(gateway: gateway, db: db).hydrateCollections(userId: "u1")

        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.members, [],
                       "a successful read can still unshare — only a FAILED read is ignored")
    }

    func testAPendingListKeepsItsContentButTakesFreshMembership() async throws {
        let localItem = CollectionItem(id: "i-local", body: "eggs", at: "2026-05-21T10:01:00.000Z")
        let local = list("c1", owner: "u1", members: [], role: "owner", items: [localItem])
        try db.save(local)
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .upsert,
                            payload: String(data: try json(CollectionRow(local)), encoding: .utf8),
                            nowISO: "2026-05-21T10:01:00.000Z")
        let gateway = FakeRawGateway(rowsByTable: ["collections": [try listJSON(list("c1", owner: "u1"))],
                                                   "collection_members": [try memberJSON("c1", "p1")]])

        await Hydrator(gateway: gateway, db: db).hydrateCollections(userId: "u1")

        let c1 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c1"))
        XCTAssertEqual(c1.items.map(\.id), ["i-local"], "the queued edit's content is kept")
        XCTAssertEqual(c1.members, ["p1"], "but membership is server truth, not a local edit")
        XCTAssertEqual(c1.myRole, "owner")
    }

    /// The collections hydrate now also runs from the catch-up and on every
    /// membership event — not only after a flush — so a list whose DELETE is
    /// still queued must not come back.
    func testAListWithAQueuedDeleteIsNotResurrected() async throws {
        _ = try box.enqueue(table: "collections", rowId: "c1", kind: .delete, nowISO: "2026-05-21T10:01:00.000Z")
        let gateway = FakeRawGateway(rowsByTable: ["collections": [try listJSON(list("c1", owner: "u1"))]])

        await Hydrator(gateway: gateway, db: db).hydrateCollections(userId: "u1")

        XCTAssertNil(try db.fetchById(ItemCollection.self, id: "c1"))
    }

    /// The debounced flush acks a list edit and a list delete BETWEEN the
    /// hydrate's collections read and its replace: the snapshot predates both
    /// and nothing is queued any more. The edit must not revert (the owner's
    /// next whole-row upsert would be built on the reverted row and delete it
    /// on the server), and the list must not come back.
    func testAListWriteAckedWhileTheHydrateReadsIsNotReverted() async throws {
        let milk = CollectionItem(id: "i-milk", body: "milk", at: "2026-05-21T10:01:00.000Z")
        let edited = list("c1", owner: "u1", members: [], role: "owner", items: [milk])
        try db.save(edited)
        let edit = try box.enqueue(table: "collections", rowId: "c1", kind: .upsert,
                                   payload: String(data: try json(CollectionRow(edited)), encoding: .utf8),
                                   nowISO: "2026-05-21T10:01:00.000Z")
        let delete = try box.enqueue(table: "collections", rowId: "c2", kind: .delete, nowISO: "2026-05-21T10:01:00.000Z")
        let ackedSeqs = [try XCTUnwrap(edit.opSeq), try XCTUnwrap(delete.opSeq)]
        let db = self.db!
        let gateway = FakeRawGateway(rowsByTable: ["collections": [try listJSON(list("c1", owner: "u1")),
                                                                   try listJSON(list("c2", owner: "u1"))],
                                                   "collection_members": []],
                                     onRead: { table in
                                         guard table == "collection_members" else { return }
                                         for seq in ackedSeqs { try? OutboxStore(db).markDone(seq) }
                                     })

        await Hydrator(gateway: gateway, db: db).hydrateCollections(userId: "u1")

        XCTAssertEqual(try box.count(), 0, "both ops were acked mid-hydrate")
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.items.map(\.id), ["i-milk"],
                       "an edit acked mid-read is not reverted to the older snapshot")
        XCTAssertNil(try db.fetchById(ItemCollection.self, id: "c2"), "a delete acked mid-read stays deleted")
    }

    /// A burst of membership events (the channel is unfiltered now) costs at
    /// most two pulls, and a caller that arrived mid-run returns only after a
    /// run that STARTED after its call.
    func testOverlappingCollectionHydratesCollapseIntoOneTrailingRun() async throws {
        let gateway = GatedCollectionsGateway()
        let hydrator = Hydrator(gateway: gateway, db: db)
        let first = Task { await hydrator.hydrateCollections(userId: "u1") }
        var spins = 0
        while !(await gateway.isHolding), spins < 5_000 {
            spins += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let isHolding = await gateway.isHolding
        XCTAssertTrue(isHolding)
        let others = (0..<3).map { _ in
            Task { () -> Int in
                await hydrator.hydrateCollections(userId: "u1")
                return await gateway.collectionsReads
            }
        }
        spins = 0
        while await hydrator.collectionsHydrateWaiterCount < 3, spins < 5_000 {
            spins += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let waiting = await hydrator.collectionsHydrateWaiterCount
        XCTAssertEqual(waiting, 3)

        await gateway.release()
        await first.value
        for t in others {
            let readsWhenReturned = await t.value
            XCTAssertEqual(readsWhenReturned, 2, "returned only after the trailing run")
        }
        let reads = await gateway.collectionsReads
        XCTAssertEqual(reads, 2, "one run + one trailing run for the whole burst")
    }

    /// The realtime side of the burst: the members channel's consumer used to
    /// await one hydrate per event, so five buffered DELETEs (a list deleted
    /// with five members) ran five full hydrates back to back. Driven through
    /// the consumer the mirror now builds.
    func testABurstOfMembershipEventsCostsOneRunAndOneTrailingRun() async throws {
        let gateway = GatedCollectionsGateway()
        let hydrator = Hydrator(gateway: gateway, db: db)
        let (signal, consumer) = RealtimeMirror.coalescedSignal { await hydrator.hydrateCollections(userId: "u1") }
        defer { consumer.cancel() }

        signal()
        var spins = 0
        while !(await gateway.isHolding), spins < 5_000 {
            spins += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let isHolding = await gateway.isHolding
        XCTAssertTrue(isHolding, "the first event's hydrate is in flight")
        for _ in 0..<4 { signal() }   // four more DELETEs land meanwhile
        await gateway.release()

        spins = 0
        while await gateway.collectionsReads < 2, spins < 5_000 {
            spins += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)   // room for any extra run
        let reads = await gateway.collectionsReads
        XCTAssertEqual(reads, 2, "the events that landed mid-run share ONE trailing run")
    }

    // MARK: - stage 2: insert-family ops + the cal_blocks pull signal

    private let seriesId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
    private func occurrence(_ date: String, _ time: String = "07:00") -> CalBlock {
        CalBlock(id: occurrenceId(taskId: seriesId, date: date), taskId: seriesId, taskName: "Gym",
                 startTime: time, durationMinutes: 30, date: date, kind: .task)
    }
    private func blockPayload(_ b: CalBlock) throws -> String? { String(data: try json(CalBlockRow(b)), encoding: .utf8) }

    /// A mint the server hasn't seen yet survives the server-canonical replace,
    /// exactly like a pending upsert — and so does a RE-mint whose delete is
    /// queued ahead of it while the server still has the old row.
    func testPendingInsertSurvivesHydrate() async throws {
        let minted = occurrence("2026-09-24")
        try db.save(minted)
        _ = try box.enqueue(table: "cal_blocks", rowId: minted.id, kind: .insert, payload: try blockPayload(minted),
                            nowISO: "2026-09-23T10:00:00.000Z")
        let reMinted = occurrence("2026-09-25", "09:15")
        try db.save(reMinted)
        _ = try box.enqueue(table: "cal_blocks", rowId: reMinted.id, kind: .delete, nowISO: "2026-09-23T10:00:00.000Z")
        _ = try box.enqueue(table: "cal_blocks", rowId: reMinted.id, kind: .insertOrRetime, payload: try blockPayload(reMinted),
                            nowISO: "2026-09-23T10:00:01.000Z")
        let stale = occurrence("2026-09-26")
        try db.save(stale)   // no op: the server's word wins, and it doesn't have it
        let serverOld = occurrence("2026-09-25", "07:00")
        let hydrator = Hydrator(gateway: FakeRawGateway(rowsByTable: ["cal_blocks": [try json(CalBlockRow(serverOld))]]), db: db)

        await hydrator.hydrate(userId: "u1")

        XCTAssertNotNil(try db.fetchById(CalBlock.self, id: minted.id), "the pending mint stays on the UI")
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: reMinted.id)?.startTime, "09:15",
                       "the re-mint's local intent wins over the not-yet-deleted server row")
        XCTAssertNil(try db.fetchById(CalBlock.self, id: stale.id))
    }

    /// The top-up's gate: only a SUCCESSFUL cal_blocks read stamps it. The
    /// session's first pull (fullSync) with cal_blocks failing still reads as
    /// "success" to the freshness owner — the top-up must not believe that.
    func testFailedCalBlocksPullDoesNotAdvanceTheTopUpStamp() async throws {
        let gateway = SwitchableBlocksGateway()
        await gateway.set([], failing: true)
        let hydrator = Hydrator(gateway: gateway, db: db)
        let owner = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { uid in await hydrator.hydrate(userId: uid) },
            catchUp: { _, _ in CatchUpPuller.Outcome() }))
        await owner.setUser("u1")
        await owner.report(.coldStart)
        await owner.awaitIdle()
        let generic = await owner.snapshot().lastSuccessfulPullAt
        XCTAssertNotNil(generic, "the generic signal claims success")
        var stamp = await hydrator.calBlocksPull()
        XCTAssertNil(stamp, "but cal_blocks was never read")

        // A good read stamps it, with the raw row count.
        await gateway.set([try json(CalBlockRow(occurrence("2026-09-24"))), try json(CalBlockRow(occurrence("2026-09-25")))],
                          failing: false)
        let okFull = await hydrator.hydrateFullReplaceTable("cal_blocks")
        XCTAssertTrue(okFull)
        stamp = await hydrator.calBlocksPull()
        XCTAssertEqual(stamp?.seq, 1)
        XCTAssertEqual(stamp?.rowCount, 2)
        XCTAssertEqual(stamp?.mayBeTruncated, false)

        // The catch-up's full replace failing later leaves it where it was.
        await gateway.set([], failing: true)
        let failedFull = await hydrator.hydrateFullReplaceTable("cal_blocks")
        XCTAssertFalse(failedFull)
        let after = await hydrator.calBlocksPull()
        XCTAssertEqual(after, stamp, "a failed read never advances the stamp")

        // A read at PostgREST's row cap may be truncated: the top-up must skip.
        XCTAssertTrue(CalBlocksPull(seq: 9, at: Date(), rowCount: 1000).mayBeTruncated)
        XCTAssertFalse(CalBlocksPull(seq: 9, at: Date(), rowCount: 999).mayBeTruncated)

        // A sign-out forgets it: the next account waits for its own read.
        await hydrator.resetCalBlocksPull()
        let reset = await hydrator.calBlocksPull()
        XCTAssertNil(reset)
    }
}
