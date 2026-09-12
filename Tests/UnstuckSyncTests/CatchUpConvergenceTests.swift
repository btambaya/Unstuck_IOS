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

    func put(_ table: String, _ data: Data) {
        guard let id = CatchUpPuller.stringField("id", in: data) else { return }
        rows[table, default: [:]][id] = data
    }

    func remove(_ table: String, id: String) {
        rows[table]?.removeValue(forKey: id)
    }

    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        let dec = JSONDecoder()
        return (rows[table] ?? [:]).values.compactMap { try? dec.decode(Row.self, from: $0) }
    }

    func fetchAllRaw(table: String) async throws -> [Data] {
        fullTableReads += 1
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

    /// Every gap trigger must also re-read the account-wide preference rows —
    /// they live outside the local store, so no cursor pull carries them, and
    /// before this they were read ONCE per process launch.
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
