// The gap test — the one that would have caught every regression in this area.
//
// postgres_changes has no replay, and a channel can report SUBSCRIBED while
// being permanently deaf (both proven against production on 2026-09-12). So the
// question these tests ask is not "does realtime work?" but "when realtime
// delivers NOTHING across a gap, does the client converge anyway, without a
// relaunch?"
//
// Each test drives the REAL pieces — FreshnessOwner, CatchUpPuller,
// SyncCursorStore and a real GRDB store — against a fake server whose rows are
// mutated mid-test while no realtime event is ever reported.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// A server whose rows can be changed mid-test, exposing exactly the reads the
/// catch-up uses. Rows are stored as encoded JSON so the actor stays Sendable.
private actor FakeServer: SyncReadGatewayProtocol {
    private var rows: [String: [String: Data]] = [:]
    /// Every cursor page asked for — proves the pull is a DELTA, not a replace.
    private(set) var pageRequests: [(table: String, atOrAfter: String?)] = []
    private(set) var fullTableReads = 0
    private(set) var fullReadsByTable: [String: Int] = [:]
    /// Full reads of a table that time out before one succeeds.
    private var failingFullReads: [String: Int] = [:]
    /// Runs as a full read of that table starts (a write landing mid-read).
    private var onFullRead: [String: @Sendable () -> Void] = [:]

    func setOnFullRead(_ table: String, _ hook: @escaping @Sendable () -> Void) {
        onFullRead[table] = hook
    }

    func put(_ table: String, _ data: Data) {
        guard let id = CatchUpPuller.stringField("id", in: data) else { return }
        rows[table, default: [:]][id] = data
    }

    func remove(_ table: String, id: String) {
        rows[table]?.removeValue(forKey: id)
    }

    func failNextFullReads(_ table: String, times: Int) {
        failingFullReads[table] = times
    }

    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        let dec = JSONDecoder()
        return (rows[table] ?? [:]).values.compactMap { try? dec.decode(Row.self, from: $0) }
    }

    func fetchAllRaw(table: String) async throws -> [Data] {
        fullTableReads += 1
        fullReadsByTable[table, default: 0] += 1
        onFullRead[table]?()
        if let left = failingFullReads[table], left > 0 {
            failingFullReads[table] = left - 1
            throw URLError(.timedOut)
        }
        return Array((rows[table] ?? [:]).values)
    }

    func fetchPageSince(table: String, column: String, atOrAfter: String?, limit: Int) async throws -> [Data] {
        pageRequests.append((table, atOrAfter))
        let all = Array((rows[table] ?? [:]).values)
        let kept = all.filter { raw in
            guard let v = CatchUpPuller.stringField(column, in: raw) else { return false }
            guard let after = atOrAfter else { return true }
            return v >= after
        }
        let sorted = kept.sorted {
            (CatchUpPuller.stringField(column, in: $0) ?? "") < (CatchUpPuller.stringField(column, in: $1) ?? "")
        }
        return Array(sorted.prefix(limit))
    }

    func fetchIdPage(table: String, afterId: String?, limit: Int) async throws -> [String] {
        let ids = (rows[table] ?? [:]).keys.sorted().filter { id in
            guard let afterId else { return true }
            return id > afterId
        }
        return Array(ids.prefix(limit))
    }
}

final class CatchUpConvergenceTests: XCTestCase {
    private let uid = "11111111-1111-1111-1111-111111111111"
    private var db: AppDatabase!
    private var server: FakeServer!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        server = FakeServer()
    }

    // MARK: - helpers

    private func task(_ id: String, _ name: String, updatedAt: String, done: Bool = false) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: 25, done: done,
                 createdAt: "2026-09-12T08:00:00.000Z", updatedAt: updatedAt)
    }

    private func serverRow(_ t: TaskItem) throws -> Data {
        try JSONEncoder().encode(TaskRow(t))
    }

    private func makePuller() -> CatchUpPuller {
        CatchUpPuller(gateway: server, db: db, fullFallback: { _ in true })
    }

    /// A freshness owner wired to the real puller, plus counters for what it
    /// decided to do. `fullSync` is deliberately a no-op recorder: if it ever
    /// fires after the cold start, the catch-up was not the correctness path.
    private func makeOwner(_ puller: CatchUpPuller,
                           fullSyncs: Counter,
                           rebuilds: Counter,
                           prefsRefreshes: Counter = Counter()) -> FreshnessOwner {
        FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { _ in await fullSyncs.bump() },
            catchUp: { uid, reconcile in await puller.catchUp(userId: uid, reconcileDeletions: reconcile) },
            rebuildSubscriptions: { await rebuilds.bump() },
            refreshPreferences: { await prefsRefreshes.bump() }))
    }

    actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - the headline test

    /// SUBSCRIPTION DOWN → rows written server-side → SUBSCRIPTION BACK.
    /// No realtime event is ever reported, and the app is never restarted.
    func testConvergesAcrossASubscriptionGapWithoutARelaunch() async throws {
        // Cold start: one task, hydrated into the local store.
        let original = task("t1", "Write the spec", updatedAt: "2026-09-12T09:00:00.000Z")
        try db.save(original)
        await server.put("tasks", try serverRow(original))

        let puller = makePuller()
        let fullSyncs = Counter(), rebuilds = Counter()
        let owner = makeOwner(puller, fullSyncs: fullSyncs, rebuilds: rebuilds)
        await owner.setUser(uid)
        await owner.markHydrated()          // the cold-start hydrate already ran
        await owner.report(.coldStart)      // seeds the cursors
        await owner.awaitIdle()

        // ---- THE GAP. The channel is down (or joined-and-deaf): the app is
        // told nothing. Meanwhile the web edits one task and creates another.
        await server.put("tasks", try serverRow(task("t1", "Write the spec v2", updatedAt: "2026-09-12T09:05:00.000Z")))
        await server.put("tasks", try serverRow(task("t2", "Ship it", updatedAt: "2026-09-12T09:06:00.000Z")))

        // Nothing has reached the device — this is the state users report.
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "Write the spec")
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "t2"))

        // ---- THE SUBSCRIPTION COMES BACK. That is the only thing that happens.
        await owner.report(.channelsSubscribed)
        await owner.awaitIdle()

        // Converged, in the same process.
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "Write the spec v2")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t2")?.name, "Ship it")

        // And it converged via the CURSOR pull, not a full-table replace.
        let syncs = await fullSyncs.value
        XCTAssertEqual(syncs, 0, "the catch-up, not a full hydrate, is the correctness path")
        let requests = await server.pageRequests
        let taskPages = requests.filter { $0.table == "tasks" }
        XCTAssertGreaterThanOrEqual(taskPages.count, 2)
        XCTAssertNotNil(taskPages.last?.atOrAfter, "the second pull asked from the cursor, not from scratch")
    }

    /// The deafness oracle: the channel said SUBSCRIBED, delivered nothing, and
    /// the catch-up found a change that was already a minute old. That is the
    /// "connected but deaf" signature — the subscriptions get rebuilt and the
    /// event is counted so the field can be measured.
    func testAChangeRealtimeNeverDeliveredRebuildsTheSubscriptions() async throws {
        let original = task("t1", "Original", updatedAt: "2026-09-12T09:00:00.000Z")
        try db.save(original)
        await server.put("tasks", try serverRow(original))

        let puller = makePuller()
        let fullSyncs = Counter(), rebuilds = Counter()
        let owner = makeOwner(puller, fullSyncs: fullSyncs, rebuilds: rebuilds)
        await owner.setUser(uid)
        await owner.markHydrated()
        await owner.report(.channelsSubscribed)   // the channel claims health
        await owner.awaitIdle()
        let rebuildsAfterSeed = await rebuilds.value

        // A change stamped a minute ago — far older than the grace window, so a
        // healthy channel would have delivered it long before this pull.
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        await server.put("tasks", try serverRow(task("t9", "Made on the web", updatedAt: stale)))

        await owner.report(.floorTick)
        await owner.awaitIdle()

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t9")?.name, "Made on the web")
        let stats = await owner.snapshot()
        XCTAssertEqual(stats.missedEventRebuilds, 1, "a change realtime never delivered must be recorded")
        let after = await rebuilds.value
        XCTAssertGreaterThan(after, rebuildsAfterSeed, "and must rebuild the subscriptions")
    }

    /// Overlapping triggers must collapse into ONE in-flight pull, and a pull
    /// must never run beside another. Five triggers, at most two pulls (the one
    /// already running plus a single trailing one).
    func testOverlappingTriggersCollapseIntoOnePull() async throws {
        try db.save(task("t1", "A", updatedAt: "2026-09-12T09:00:00.000Z"))
        await server.put("tasks", try serverRow(task("t1", "A", updatedAt: "2026-09-12T09:00:00.000Z")))

        let counting = CountingCatchUp(inner: makePuller())
        let owner = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { _ in },
            catchUp: { uid, reconcile in await counting.run(uid, reconcile) }))
        await owner.setUser(uid)
        await owner.markHydrated()

        await owner.report(.becameActive)
        await owner.report(.floorTick)
        await owner.report(.networkRegained)
        await owner.report(.socketConnected)
        await owner.report(.manual)
        await owner.awaitIdle()

        let runs = await counting.runs
        XCTAssertLessThanOrEqual(runs, 2, "overlapping triggers must coalesce")
        XCTAssertGreaterThanOrEqual(runs, 1)
        let maxConcurrent = await counting.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1, "two pulls must never overlap")
    }

    /// A catch-up must never revert a pending local edit: the row the server
    /// still has is the state the edit was made ON.
    func testCatchUpDoesNotClobberAPendingLocalWrite() async throws {
        let base = task("t1", "Server copy", updatedAt: "2026-09-12T09:00:00.000Z")
        await server.put("tasks", try serverRow(base))
        // The user renamed it offline; the op is queued with the server row as
        // its base, exactly as WriteThrough enqueues it.
        let edited = task("t1", "My offline rename", updatedAt: "2026-09-12T09:04:00.000Z")
        try db.save(edited)
        let box = OutboxStore(db)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: String(data: try JSONEncoder().encode(TaskRow(edited)), encoding: .utf8),
                            nowISO: "2026-09-12T09:04:00.000Z",
                            baseUpdatedAt: base.updatedAt)

        let outcome = await makePuller().catchUp(userId: uid, reconcileDeletions: true)

        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "My offline rename")
        XCTAssertGreaterThanOrEqual(outcome.rowsSkippedPending, 1)
        XCTAssertEqual(outcome.idsDropped, 0, "a row with a pending write is never reconciled away")
    }

    /// Hard deletes are invisible to a cursor pull, so the id sweep is what
    /// removes them — and it must leave a locally-created row alone.
    func testDeletionsAreReconciledByTheIdSweep() async throws {
        let kept = task("t1", "Kept", updatedAt: "2026-09-12T09:00:00.000Z")
        let deletedRemotely = task("t2", "Deleted on the web", updatedAt: "2026-09-12T09:01:00.000Z")
        let createdHere = task("t3", "Made on this phone", updatedAt: "2026-09-12T09:02:00.000Z")
        try db.save(kept); try db.save(deletedRemotely); try db.save(createdHere)
        await server.put("tasks", try serverRow(kept))
        await server.put("tasks", try serverRow(deletedRemotely))
        let box = OutboxStore(db)
        _ = try box.enqueue(table: "tasks", rowId: "t3", kind: .upsert,
                            payload: String(data: try JSONEncoder().encode(TaskRow(createdHere)), encoding: .utf8),
                            nowISO: "2026-09-12T09:02:00.000Z")

        let puller = makePuller()
        _ = await puller.catchUp(userId: uid, reconcileDeletions: true)   // seeds cursors, keeps everything
        await server.remove("tasks", id: "t2")
        let outcome = await puller.catchUp(userId: uid, reconcileDeletions: true)

        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: "t1"))
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "t2"), "a row the server no longer has must go")
        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: "t3"), "an un-pushed local row must survive")
        XCTAssertEqual(outcome.idsDropped, 1)
    }

    /// The cursor is per (user, table), only ever moves forward, and is wiped
    /// with the cache — a wiped table must re-pull from the beginning.
    func testCursorIsMonotonicAndClearedWithTheCache() throws {
        let cursors = SyncCursorStore(db)
        try cursors.advance(userId: uid, table: "tasks", to: "2026-09-12T09:00:00.000Z")
        try cursors.advance(userId: uid, table: "tasks", to: "2026-09-12T08:00:00.000Z")
        XCTAssertEqual(try cursors.cursor(userId: uid, table: "tasks"), "2026-09-12T09:00:00.000Z")
        try cursors.advance(userId: uid, table: "tasks", to: "2026-09-12T10:00:00.000Z")
        XCTAssertEqual(try cursors.cursor(userId: uid, table: "tasks"), "2026-09-12T10:00:00.000Z")
        XCTAssertNil(try cursors.cursor(userId: "someone-else", table: "tasks"))
        try db.clearAll()
        XCTAssertNil(try cursors.cursor(userId: uid, table: "tasks"))
    }

    /// VERIFIER: a QUIET account must not be accused of deafness. The pull is
    /// inclusive (`>= cursor`) on purpose, so every tick re-reads the boundary
    /// row of every table. If those re-reads count as "realtime never delivered
    /// this", a healthy phone rebuilds all 11 channels every minute forever.
    func testAQuietAccountIsNeverAccusedOfDeafness() async throws {
        let t1 = task("t1", "Kept", updatedAt: "2026-09-12T09:00:00.000Z")
        try db.save(t1)
        await server.put("tasks", try serverRow(t1))

        let puller = makePuller()
        let fullSyncs = Counter(), rebuilds = Counter()
        let owner = makeOwner(puller, fullSyncs: fullSyncs, rebuilds: rebuilds)
        await owner.setUser(uid)
        await owner.markHydrated()
        await owner.report(.channelsSubscribed)      // the channel is healthy
        await owner.awaitIdle()
        let rebuildsAfterSeed = await rebuilds.value

        // Nothing changes on the server at all. Three floor ticks.
        for _ in 0..<3 {
            await owner.report(.floorTick)
            await owner.awaitIdle()
        }

        let stats = await owner.snapshot()
        XCTAssertEqual(stats.missedEventRebuilds, 0,
                       "re-reading the boundary row is not evidence that realtime is deaf")
        let after = await rebuilds.value
        XCTAssertEqual(after, rebuildsAfterSeed, "a quiet healthy channel must not be rebuilt")
    }

    /// VERIFIER: the cursor must not move past a row the pull deliberately did
    /// NOT apply. If it does, and the pending write later dead-letters, the
    /// server's version of that row is never asked for again.
    func testTheCursorDoesNotMovePastASkippedRow() async throws {
        let base = task("t1", "Server copy", updatedAt: "2026-09-12T09:00:00.000Z")
        await server.put("tasks", try serverRow(base))
        let edited = task("t1", "My offline rename", updatedAt: "2026-09-12T09:04:00.000Z")
        try db.save(edited)
        let box = OutboxStore(db)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert,
                            payload: String(data: try JSONEncoder().encode(TaskRow(edited)), encoding: .utf8),
                            nowISO: "2026-09-12T09:04:00.000Z",
                            baseUpdatedAt: base.updatedAt)

        let puller = makePuller()
        let first = await puller.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertGreaterThanOrEqual(first.rowsSkippedPending, 1)

        // The queued write is abandoned (quarantined / the user signed out of
        // that edit). The local row is now simply stale, and the ONLY thing
        // that can fix it is the catch-up asking for that row again.
        try box.cancelPendingUpserts(table: "tasks", rowId: "t1")
        try db.save(task("t1", "stale local copy", updatedAt: "2026-09-12T08:00:00.000Z"))

        let second = await puller.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "t1")?.name, "Server copy",
                       "the row we refused to apply must be offered again, not skipped forever")
        XCTAssertGreaterThanOrEqual(second.rowsApplied, 1)
    }

    /// VERIFIER: a catch-up must not resurrect a row this device deleted while
    /// the delete is still queued.
    func testCatchUpDoesNotResurrectALocallyDeletedRow() async throws {
        let doomed = task("t1", "Deleted here", updatedAt: "2026-09-12T09:00:00.000Z")
        await server.put("tasks", try serverRow(doomed))
        // WriteThrough's delete: gone locally, the op queued.
        let box = OutboxStore(db)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .delete, payload: nil,
                            nowISO: "2026-09-12T09:01:00.000Z")

        let outcome = await makePuller().catchUp(userId: uid, reconcileDeletions: false)

        XCTAssertNil(try db.fetchById(TaskItem.self, id: "t1"),
                     "the server's copy must not come back while our delete is queued")
        XCTAssertGreaterThanOrEqual(outcome.rowsSkippedPending, 1)
    }

    // MARK: - shared-list membership (audit 2026-09-22, C8)
    //
    // The owner's phone decides "shared" from the local members[]; with none it
    // ships item edits as whole-row upserts over the members' edits. A join by
    // link / an invite claimed at sign-up never produces a row for the owner's
    // own user_id — the ONLY pull-side trace is migration 056 §4 bumping the
    // list's updated_at. These drive the real puller + a real Hydrator with no
    // realtime event at all.

    private let partner = "22222222-2222-2222-2222-222222222222"

    private func listRow(_ id: String, owner: String, updatedAt: String) throws -> Data {
        let c = ItemCollection(id: id, name: "Groceries", color: "indigo", items: [], sortOrder: 0)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CollectionRow(c))) as? [String: Any])
        obj["user_id"] = owner
        obj["updated_at"] = updatedAt
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func memberRow(_ collectionId: String, _ userId: String, role: String = "editor") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "m-\(collectionId)-\(userId)", "collection_id": collectionId,
                                                    "user_id": userId, "role": role])
    }

    /// The puller wired exactly as SyncCoordinator wires it.
    private func makeMembershipPuller(_ hydrator: Hydrator) -> CatchUpPuller {
        CatchUpPuller(gateway: server, db: db, fullFallback: { _ in true },
                      refreshCollections: { uid, changed in
                          await hydrator.refreshCollectionMembership(userId: uid, collectionsChanged: changed)
                      })
    }

    private func membershipReads() async -> Int {
        await server.fullReadsByTable["collection_members"] ?? 0
    }

    func testAJoinReachesTheOwnersListThroughTheCatchUpWithoutARelaunch() async throws {
        // Cold start: the owner's unshared list, hydrated.
        try db.save(ItemCollection(id: "c1", name: "Groceries", color: "indigo", items: [], sortOrder: 0,
                                   ownerId: uid, members: [], myRole: "owner"))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:00:00.000000+00:00"))
        let hydrator = Hydrator(gateway: server, db: db)
        let puller = makeMembershipPuller(hydrator)
        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)   // seeds the cursors
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.members, [])

        // ---- THE GAP: the partner joins by link. No realtime event reaches
        // the owner; the server only bumps the list's updated_at (056 §4).
        await server.put("collection_members", try memberRow("c1", partner))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:05:00.000000+00:00"))

        let outcome = await puller.catchUp(userId: uid, reconcileDeletions: false)

        XCTAssertTrue(outcome.collectionsChanged)
        let c1 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c1"))
        XCTAssertEqual(c1.members, [partner], "the owner's list now reads as shared, in the same process")
        XCTAssertEqual(c1.myRole, "owner")
    }

    /// Only a collections row the device had NOT seen triggers the re-read:
    /// every tick re-reads the boundary row, and that must not cost a
    /// membership pull (it runs every 60s while visible).
    func testACatchUpWithNoCollectionChangeDoesNotRereadMembership() async throws {
        try db.save(ItemCollection(id: "c1", name: "Groceries", color: "indigo", items: [], sortOrder: 0,
                                   ownerId: uid, members: [], myRole: "owner"))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:00:00.000000+00:00"))
        let puller = makeMembershipPuller(Hydrator(gateway: server, db: db))
        let seed = await puller.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertTrue(seed.collectionsChanged, "the seeding pull re-reads once")
        let readsAfterSeed = await membershipReads()

        for _ in 0..<3 {
            let tick = await puller.catchUp(userId: uid, reconcileDeletions: false)
            XCTAssertFalse(tick.collectionsChanged, "re-reading the boundary row is not a change")
        }

        let reads = await membershipReads()
        XCTAssertEqual(reads, readsAfterSeed, "quiet ticks add no membership pull")
    }

    /// A fresh sign-in knows no membership to fall back on. If the members read
    /// fails there AND on the seeding catch-up, the next catch-up retries it
    /// even though nothing changed on the server — else the owner's list read
    /// as unshared until some list happened to change.
    func testAFailedMembershipReadIsRetriedByTheNextQuietCatchUp() async throws {
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:00:00.000000+00:00"))
        await server.put("collection_members", try memberRow("c1", partner))
        await server.failNextFullReads("collection_members", times: 2)
        let hydrator = Hydrator(gateway: server, db: db)
        let puller = makeMembershipPuller(hydrator)

        await hydrator.hydrateCollections(userId: uid)                          // the sign-in hydrate: fails
        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)      // the seeding refresh: fails
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.members, [])

        let quiet = await puller.catchUp(userId: uid, reconcileDeletions: false)

        XCTAssertFalse(quiet.collectionsChanged, "nothing changed on the server")
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.members, [partner],
                       "the unresolved membership read is retried and fills the list in")
        let readsAfterFix = await membershipReads()
        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)
        let reads = await membershipReads()
        XCTAssertEqual(reads, readsAfterFix, "once resolved, quiet ticks stop re-reading")
    }

    /// The re-read also runs after the user's OWN list edits (realtime never
    /// moves the cursor), so it must never touch content. A full collections
    /// read + replace here raced the debounced flush: an edit acked or echoed
    /// between that read and the write went back to the older snapshot, and
    /// the owner's next whole-row upsert, built on it, deleted it on the server.
    func testTheCatchUpMembershipReReadNeverRevertsAListEdit() async throws {
        try db.save(ItemCollection(id: "c1", name: "Groceries", color: "indigo", items: [], sortOrder: 0,
                                   ownerId: uid, members: [], myRole: "owner"))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:00:00.000000+00:00"))
        let puller = makeMembershipPuller(Hydrator(gateway: server, db: db))
        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)   // seeds the cursors

        // The partner joins (056 §4 bumps the list), and while the membership
        // read is in flight the owner's "milk" lands: the flush acked it and
        // the realtime echo wrote it locally.
        await server.put("collection_members", try memberRow("c1", partner))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:05:00.000000+00:00"))
        let db = self.db!
        await server.setOnFullRead("collection_members") {
            guard var c1 = try? db.fetchById(ItemCollection.self, id: "c1") else { return }
            c1.items = [CollectionItem(id: "i-milk", body: "milk", at: "2026-09-12T09:06:00.000Z")]
            try? db.save(c1)
        }

        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)

        let c1 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c1"))
        XCTAssertEqual(c1.items.map(\.id), ["i-milk"], "the edit that landed mid-read is kept")
        XCTAssertEqual(c1.members, [partner], "and the list now reads as shared")
        let listReads = await server.fullReadsByTable["collections"] ?? 0
        XCTAssertEqual(listReads, 0, "the pull already applied the list: only membership is read")
    }

    /// A list shared WITH me arrives through the pull with no role (the server
    /// row carries none); the membership re-read gives it the real one, so a
    /// viewer doesn't get edit controls.
    func testAListSharedWithMeGetsItsRoleFromTheCatchUp() async throws {
        try db.save(ItemCollection(id: "c1", name: "Groceries", color: "indigo", items: [], sortOrder: 0,
                                   ownerId: uid, members: [], myRole: "owner"))
        await server.put("collections", try listRow("c1", owner: uid, updatedAt: "2026-09-12T09:00:00.000000+00:00"))
        let puller = makeMembershipPuller(Hydrator(gateway: server, db: db))
        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)   // seeds the cursors

        await server.put("collection_members", try memberRow("c9", uid, role: "viewer"))
        await server.put("collections", try listRow("c9", owner: partner, updatedAt: "2026-09-12T09:05:00.000000+00:00"))

        _ = await puller.catchUp(userId: uid, reconcileDeletions: false)

        let c9 = try XCTUnwrap(db.fetchById(ItemCollection.self, id: "c9"))
        XCTAssertEqual(c9.myRole, "viewer")
        XCTAssertEqual(c9.members, [uid])
        XCTAssertEqual(try db.fetchById(ItemCollection.self, id: "c1")?.myRole, "owner", "my own list is untouched")
    }

    /// Every gap trigger must also re-read the account-wide preference rows —
    /// they live outside the local store, so no cursor pull carries them, and
    /// before this they were read ONCE per process launch.
    /// A mint queued as an insert-family op counts as a pending local write in
    /// the catch-up: cal_blocks' full replace keeps the row, and the generic
    /// pending guard (every delta table's skip rule) sees it (stage 2).
    func testCatchUpSkipsRowWithPendingInsert() async throws {
        let seriesId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
        let minted = CalBlock(id: occurrenceId(taskId: seriesId, date: "2026-09-24"), taskId: seriesId, taskName: "Gym",
                              startTime: "07:00", durationMinutes: 30, date: "2026-09-24", kind: .task)
        try db.save(minted)
        _ = try OutboxStore(db).enqueue(table: "cal_blocks", rowId: minted.id, kind: .insert,
                                        payload: String(data: try JSONEncoder().encode(CalBlockRow(minted)), encoding: .utf8),
                                        nowISO: "2026-09-23T10:00:00.000Z")
        let other = CalBlock(id: "b-server", taskId: seriesId, taskName: "Gym", startTime: "07:00", durationMinutes: 30,
                             date: "2026-09-25", kind: .task)
        await server.put("cal_blocks", try JSONEncoder().encode(CalBlockRow(other)))
        let hydrator = Hydrator(gateway: server, db: db)
        let puller = CatchUpPuller(gateway: server, db: db, fullFallback: { await hydrator.hydrateFullReplaceTable($0) })

        let outcome = await puller.catchUp(userId: uid, reconcileDeletions: true)

        XCTAssertTrue(outcome.fullFallbackTables.contains("cal_blocks"))
        XCTAssertNotNil(try db.fetchById(CalBlock.self, id: minted.id), "the pending mint survives the pull")
        XCTAssertNotNil(try db.fetchById(CalBlock.self, id: "b-server"))
        XCTAssertTrue(CatchUpPuller.hasPendingWrite(table: "cal_blocks", rowId: minted.id, db: db))
        XCTAssertTrue(CatchUpPuller.hasPendingWrite(table: "cal_blocks", rowId: minted.id, db: db) &&
                      !CatchUpPuller.hasPendingDelete(table: "cal_blocks", rowId: minted.id, db: db))
        let stamp = await hydrator.calBlocksPull()
        XCTAssertEqual(stamp?.rowCount, 1, "the catch-up's full replace stamps the top-up gate too")
    }

    func testGapTriggersRefreshAccountPreferences() async throws {
        let prefs = Counter()
        let owner = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { _ in },
            catchUp: { _, _ in CatchUpPuller.Outcome() },
            refreshPreferences: { await prefs.bump() }))
        await owner.setUser(uid)
        await owner.markHydrated()
        await owner.report(.becameActive)
        await owner.awaitIdle()
        let count = await prefs.value
        XCTAssertEqual(count, 1)
    }
}

/// Wraps the real puller to count runs and prove none overlap.
private actor CountingCatchUp {
    private let inner: CatchUpPuller
    private(set) var runs = 0
    private(set) var maxConcurrent = 0
    private var concurrent = 0
    init(inner: CatchUpPuller) { self.inner = inner }

    func run(_ uid: String, _ reconcile: Bool) async -> CatchUpPuller.Outcome {
        runs += 1
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        let out = await inner.catchUp(userId: uid, reconcileDeletions: reconcile)
        concurrent -= 1
        return out
    }
}

// MARK: - stage 2: two devices, one series, deterministic occurrence ids
//
// deterministic-occurrence-ids.md §4.1 "two-device twin test": two in-memory
// stores, each with its own WriteThrough + OutboxFlusher + Hydrator, sharing
// ONE fake server with ON CONFLICT (id) DO NOTHING semantics, the filtered
// retime, and plain merge upserts. Before stage 2 each device minted the same
// tail day with its own random id: two rows, two reminders, two Google events.

/// The shared server. Rows are JSON (Data) so the actor stays Sendable.
private actor TwinServer: SyncGatewayProtocol, SyncReadGatewayProtocol {
    private var rows: [String: [String: Data]] = [:]
    private(set) var insertsIgnored = 0
    private(set) var retimed = 0

    private func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
    private func encoded<Row: Encodable>(_ row: Row, userId: String) throws -> [String: Any] {
        var obj = object(try JSONEncoder().encode(row))
        obj["user_id"] = userId
        return obj
    }

    func seed(_ table: String, _ data: Data) {
        guard let id = object(data)["id"] as? String else { return }
        rows[table, default: [:]][id] = data
    }
    func blocks() -> [CalBlock] {
        (rows["cal_blocks"] ?? [:]).values.compactMap { try? JSONDecoder().decode(CalBlockRow.self, from: $0).model() }
    }

    // writes
    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        let incoming = try encoded(row, userId: userId)
        guard let id = incoming["id"] as? String else { return }
        var merged = rows[table]?[id].map(object) ?? [:]
        for (k, v) in incoming { merged[k] = v }
        rows[table, default: [:]][id] = try JSONSerialization.data(withJSONObject: merged)
    }
    func delete(table: String, id: String) async throws {
        rows[table]?.removeValue(forKey: id)
    }
    func insertIfAbsent<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws -> Bool {
        let incoming = try encoded(row, userId: userId)
        guard let id = incoming["id"] as? String else { return false }
        guard rows[table]?[id] == nil else { insertsIgnored += 1; return false }
        rows[table, default: [:]][id] = try JSONSerialization.data(withJSONObject: incoming)
        return true
    }
    func retimeIfOpen(table: String, id: String, date: String, startTime: String, durationMinutes: Int) async throws -> Data? {
        guard let data = rows[table]?[id] else { return nil }
        var obj = object(data)
        guard obj["date"] as? String == date, obj["done"] as? Bool == false, obj["skipped"] as? Bool == false else { return nil }
        obj["start_time"] = startTime
        obj["duration_minutes"] = durationMinutes
        let out = try JSONSerialization.data(withJSONObject: obj)
        rows[table]?[id] = out
        retimed += 1
        return out
    }

    // reads
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        (rows[table] ?? [:]).values.compactMap { try? JSONDecoder().decode(Row.self, from: $0) }
    }
    func fetchAllRaw(table: String) async throws -> [Data] {
        Array((rows[table] ?? [:]).values)
    }
}

final class TwinOccurrenceTests: XCTestCase {
    private let seriesId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
    private let today = "2026-09-23"
    private let now = "2026-09-23T10:00:00.000Z"
    private var server: TwinServer!

    private struct Device {
        let db: AppDatabase
        let write: WriteThrough
        let flusher: OutboxFlusher
        let hydrator: Hydrator
    }

    private var series: TaskItem {
        TaskItem(id: seriesId, name: "Gym", estimateMin: 30, recurrence: .daily(until: nil),
                 createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z")
    }
    private func day(_ o: Int) -> String { LocalDate.addDays(today, o) }
    private func id(_ o: Int) -> String { occurrenceId(taskId: seriesId, date: day(o)) }
    private func occurrence(_ o: Int, _ time: String = "07:00") -> CalBlock {
        CalBlock(id: id(o), taskId: seriesId, taskName: "Gym", startTime: time, durationMinutes: 30, date: day(o), kind: .task)
    }

    /// A device holding the same STALE store: the series minted through +52,
    /// its frontier three days short of the horizon (+55).
    private func device() throws -> Device {
        let db = try AppDatabase.makeInMemory()
        try db.save(series)
        for o in 1...52 { try db.save(occurrence(o)) }
        return Device(db: db, write: WriteThrough(db: db), flusher: OutboxFlusher(gateway: server, db: db),
                      hydrator: Hydrator(gateway: server, db: db))
    }

    override func setUp() async throws {
        server = TwinServer()
        for o in 1...52 { await server.seed("cal_blocks", try JSONEncoder().encode(CalBlockRow(occurrence(o)))) }
    }

    /// What AppModel.topUpRecurrenceHorizon writes: the pure tail, each day
    /// minted insert-if-absent without rule H.
    private func topUp(_ d: Device) async throws {
        for b in recurrenceTopUp(task: series, existingBlocks: try d.db.fetchAllCalBlocks(), todayIso: today) {
            try await d.write.insertCalBlockIfAbsent(b, retimeIfTaken: false, nowISO: now)
        }
    }

    private func serverBlocksByDate() async -> [String: [CalBlock]] {
        Dictionary(grouping: await server.blocks().filter { $0.taskId == seriesId }, by: \.date)
    }

    func testTwoDevicesToppingUpTheSameStaleSeriesLandOnOneRowPerDay() async throws {
        let a = try device(), b = try device()
        try await topUp(a)
        try await topUp(b)
        XCTAssertEqual(try a.db.fetchAllCalBlocks().count, 55)
        XCTAssertEqual(try b.db.fetchAllCalBlocks().count, 55)
        await a.flusher.flush(userId: "u1")
        await b.flusher.flush(userId: "u1")

        let byDate = await serverBlocksByDate()
        XCTAssertEqual(byDate.count, 55)
        for o in 1...55 {
            XCTAssertEqual(byDate[day(o)]?.map(\.id), [id(o)], "exactly one row for +\(o), with its deterministic id")
        }
        let ignored = await server.insertsIgnored
        XCTAssertEqual(ignored, 3, "B's three mints were the same rows, ignored")
        XCTAssertEqual(try OutboxStore(a.db).count(), 0)
        XCTAssertEqual(try OutboxStore(b.db).count(), 0)
    }

    /// A moved the day's occurrence; B, stale, mints that day again. The
    /// server keeps A's row where A put it, and B converges on it after its
    /// catch-up — no block on the day it left.
    func testAStaleMintNeverPullsAMovedOccurrenceBack() async throws {
        let a = try device(), b = try device()
        try await topUp(a)
        await a.flusher.flush(userId: "u1")
        var moved = try XCTUnwrap(a.db.fetchById(CalBlock.self, id: id(54)))
        moved.date = day(60)
        try await a.write.upsertCalBlock(moved, nowISO: now)
        await a.flusher.flush(userId: "u1")

        try await topUp(b)   // B never saw +53…+55
        XCTAssertEqual(try b.db.fetchById(CalBlock.self, id: id(54))?.date, day(54), "B's stale local mint")
        await b.flusher.flush(userId: "u1")
        let onServer = await server.blocks().first { $0.id == id(54) }
        XCTAssertEqual(onServer?.date, day(60), "the server row id(D) is still at E")

        let pulled = await b.hydrator.hydrateFullReplaceTable("cal_blocks")
        XCTAssertTrue(pulled)
        XCTAssertEqual(try b.db.fetchById(CalBlock.self, id: id(54))?.date, day(60), "B converged on A's move")
        XCTAssertFalse(try b.db.fetchAllCalBlocks().contains { $0.taskId == seriesId && $0.date == day(54) },
                       "and has no block on the day it left")
    }

    /// Rule H: B, stale, re-plans the series to 16:00. The days A minted that B
    /// never saw are retimed on the server rather than silently kept at 07:00;
    /// a day A had moved stays where A put it.
    func testAStaleUserMintRetimesTheDaysOpenOccurrenceButNotAMovedOne() async throws {
        let a = try device(), b = try device()
        try await topUp(a)
        await a.flusher.flush(userId: "u1")
        // A moves +55 to +60 first; +53 and +54 stay at 07:00.
        var moved = try XCTUnwrap(a.db.fetchById(CalBlock.self, id: id(55)))
        moved.date = day(60)
        try await a.write.upsertCalBlock(moved, nowISO: now)
        await a.flusher.flush(userId: "u1")

        // B's Schedule on the series at 16:00, on its stale store: rewrites
        // +1…+52 in place, mints the rest as user mints.
        let existing = try b.db.fetchAllCalBlocks()
        let plan = regenerateForTask(task: series, recurrence: series.recurrence, existingBlocks: existing, todayIso: today,
                                     startTime: "16:00", startDate: LocalDate.parse(day(1)))
        XCTAssertEqual(plan.toRetime.count, 52)
        XCTAssertTrue(plan.toDelete.isEmpty)
        for r in plan.toRetime { try await b.write.upsertCalBlock(r, nowISO: now) }
        for m in plan.toUpsert { try await b.write.insertCalBlockIfAbsent(m, retimeIfTaken: true, nowISO: now) }
        await b.flusher.flush(userId: "u1")

        let byDate = await serverBlocksByDate()
        for o in 1...54 {
            XCTAssertEqual(byDate[day(o)]?.count, 1, "one row for +\(o)")
            XCTAssertEqual(byDate[day(o)]?.first?.startTime, "16:00", "+\(o) runs at B's new time")
        }
        XCTAssertEqual(byDate[day(56)]?.map(\.id), [id(56)], "the day nobody had is inserted")
        let movedOnServer = await server.blocks().first { $0.id == id(55) }
        XCTAssertEqual(movedOnServer?.date, day(60), "a moved occurrence is never pulled back")
        XCTAssertEqual(movedOnServer?.startTime, "07:00", "nor retimed: its date no longer matches")
        XCTAssertNil(byDate[day(55)], "the day A moved away from stays empty (rule A)")
        let retimes = await server.retimed
        XCTAssertEqual(retimes, 2, "+53 and +54: open, on their date")
    }

    // MARK: the top-up's gate (§3c, §f)

    func testTopUpGateRunsOnlyAfterAFreshSuccessfulUntruncatedPull() {
        var gate = RecurrenceTopUpGate()
        let first = CalBlocksPull(seq: 1, at: Date(), rowCount: 120)
        XCTAssertEqual(gate.verdict(pull: nil, userId: "u1", today: today, timeZone: "Europe/London"), .noPull)
        XCTAssertEqual(gate.verdict(pull: CalBlocksPull(seq: 1, at: Date(), rowCount: 1000), userId: "u1", today: today,
                                    timeZone: "Europe/London"), .truncated)
        XCTAssertEqual(gate.verdict(pull: first, userId: "u1", today: today, timeZone: "Europe/London"), .run)
        gate.recordRun(pull: first, userId: "u1", today: today, timeZone: "Europe/London")
        XCTAssertEqual(gate.verdict(pull: first, userId: "u1", today: day(1), timeZone: "Europe/London"), .pullNotAdvanced,
                       "a new day still waits for a pull that succeeded")
        let second = CalBlocksPull(seq: 2, at: Date(), rowCount: 120)
        XCTAssertEqual(gate.verdict(pull: second, userId: "u1", today: today, timeZone: "Europe/London"), .alreadyRanToday)
        XCTAssertEqual(gate.verdict(pull: second, userId: "u1", today: day(1), timeZone: "Europe/London"), .run, "the next day")
        XCTAssertEqual(gate.verdict(pull: second, userId: "u1", today: today, timeZone: "America/New_York"), .run,
                       "a time-zone change")
        XCTAssertEqual(gate.verdict(pull: first, userId: "u2", today: today, timeZone: "Europe/London"), .run, "another account")
    }

    /// The day / time-zone observers pull first (§3c): the top-up runs only if
    /// THAT pull moved the stamp. A failed observer pull must not be stood in
    /// for by an earlier floor pull, however new that one is.
    func testTopUpGateAfterTheObserversOwnPullNeedsThatPullToSucceed() {
        var gate = RecurrenceTopUpGate()
        let yesterday = CalBlocksPull(seq: 3, at: Date(), rowCount: 120)
        gate.recordRun(pull: yesterday, userId: "u1", today: day(-1), timeZone: "Europe/London")
        let floorPull = CalBlocksPull(seq: 40, at: Date(), rowCount: 120)   // 23:59, before the day changed
        XCTAssertEqual(gate.verdict(pull: floorPull, userId: "u1", today: today, timeZone: "Europe/London", pulledAfter: 40),
                       .pullNotAdvanced, "the observer's own pull failed: the stamp did not move")
        XCTAssertEqual(gate.verdict(pull: floorPull, userId: "u1", today: today, timeZone: "Europe/London"), .run,
                       "the hydrate hook (no pull of its own) judges only against the last run")
        let observerPull = CalBlocksPull(seq: 41, at: Date(), rowCount: 120)
        XCTAssertEqual(gate.verdict(pull: observerPull, userId: "u1", today: today, timeZone: "Europe/London", pulledAfter: 40),
                       .run)
        XCTAssertEqual(gate.verdict(pull: CalBlocksPull(seq: 1, at: Date(), rowCount: 5), userId: "u9", today: today,
                                    timeZone: "Europe/London", pulledAfter: 0), .run, "the first read of a session")
        XCTAssertEqual(gate.verdict(pull: nil, userId: "u9", today: today, timeZone: "Europe/London", pulledAfter: 0), .noPull)
    }
}
