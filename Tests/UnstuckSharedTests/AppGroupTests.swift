import XCTest
@testable import UnstuckShared

/// Covers the App-Group surface the Siri layer depends on: the pending-route
/// hand-off (open-app intents) and the snapshot the read intents speak from.
final class AppGroupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start each test from a clean route slot.
        AppGroup.setPendingRoute(nil)
    }

    // MARK: pending route (Siri "open the app" hand-off)

    func testPendingRouteRoundTrips() {
        XCTAssertFalse(AppGroup.hasPendingRoute())
        AppGroup.setPendingRoute("unstuck://focus-next")
        XCTAssertTrue(AppGroup.hasPendingRoute())
        XCTAssertEqual(AppGroup.consumePendingRoute(), "unstuck://focus-next")
    }

    func testConsumeClearsTheRouteSoItFiresOnce() {
        AppGroup.setPendingRoute("unstuck://new-task")
        XCTAssertEqual(AppGroup.consumePendingRoute(), "unstuck://new-task")
        // Second consume must be empty — the app must not re-route on the next
        // foreground.
        XCTAssertNil(AppGroup.consumePendingRoute())
        XCTAssertFalse(AppGroup.hasPendingRoute())
    }

    func testSetNilClearsAnExistingRoute() {
        AppGroup.setPendingRoute("unstuck://today")
        AppGroup.setPendingRoute(nil)
        XCTAssertFalse(AppGroup.hasPendingRoute())
        XCTAssertNil(AppGroup.consumePendingRoute())
    }

    // MARK: snapshot (what the read intents speak)

    func testSnapshotEncodesAndDecodes() throws {
        let snap = StartNextSnapshot(
            taskName: "Call the bank", estimateMin: 15, lifeArea: "Personal",
            openCount: 4, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(StartNextSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.taskName, "Call the bank")
        XCTAssertEqual(back.openCount, 4)
    }

    func testEmptySnapshotIsAllClear() {
        XCTAssertNil(StartNextSnapshot.empty.taskName)
        XCTAssertEqual(StartNextSnapshot.empty.openCount, 0)
    }

    // MARK: enriched snapshot (what the Siri reads + entities use)

    func testEnrichedSnapshotRoundTrips() throws {
        let snap = UnstuckSnapshot(
            pendingCount: 5, todayCount: 2, overdueCount: 1,
            nextTaskName: "Call the bank", nextEstimateMin: 15,
            tasks: [
                .init(id: "t1", name: "Call the bank", today: true),
                .init(id: "t2", name: "Email Sam", today: false),
            ],
            collections: [.init(id: "c1", name: "Groceries", openCount: 3)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let back = try JSONDecoder().decode(
            UnstuckSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.tasks.filter { $0.today }.count, 1)
        XCTAssertEqual(back.collections.first?.name, "Groceries")
        XCTAssertEqual(back.collections.first?.openCount, 3)
    }

    func testEnrichedSnapshotPersistsViaAppGroup() {
        let snap = UnstuckSnapshot(
            pendingCount: 4, todayCount: 1, overdueCount: 0,
            nextTaskName: "Write report", nextEstimateMin: 25,
            tasks: [.init(id: "t9", name: "Write report", today: true)],
            collections: [], updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        AppGroup.writeSnapshot(snap)
        let back = AppGroup.readSnapshot()
        XCTAssertEqual(back.pendingCount, 4)
        XCTAssertEqual(back.nextTaskName, "Write report")
        XCTAssertEqual(back.tasks.first?.id, "t9")
    }

    func testEmptyEnrichedSnapshotIsAllClear() {
        XCTAssertEqual(UnstuckSnapshot.empty.pendingCount, 0)
        XCTAssertNil(UnstuckSnapshot.empty.nextTaskName)
        XCTAssertTrue(UnstuckSnapshot.empty.tasks.isEmpty)
    }

    // MARK: hands-free write queue (Siri → app drain)

    override func tearDown() {
        AppGroup.removeWrites(ids: Set(AppGroup.readWriteQueue().map { $0.id }))
        super.tearDown()
    }

    func testEnqueueAndReadWritePreservesOrderAndFields() {
        AppGroup.removeWrites(ids: Set(AppGroup.readWriteQueue().map { $0.id }))
        AppGroup.enqueueWrite(PendingWrite(id: "a", kind: .createTask, text: "Call bank", createdAt: Date()))
        AppGroup.enqueueWrite(PendingWrite(id: "b", kind: .addToList, text: "Milk",
                                           collectionId: "c1", createdAt: Date()))
        let q = AppGroup.readWriteQueue()
        XCTAssertEqual(q.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q[0].kind, .createTask)
        XCTAssertEqual(q[0].text, "Call bank")
        XCTAssertEqual(q[1].kind, .addToList)
        XCTAssertEqual(q[1].collectionId, "c1")
    }

    func testRemoveWritesDropsOnlyProcessedIds() {
        AppGroup.removeWrites(ids: Set(AppGroup.readWriteQueue().map { $0.id }))
        AppGroup.enqueueWrite(PendingWrite(id: "x", kind: .capture, text: "idea", createdAt: Date()))
        AppGroup.enqueueWrite(PendingWrite(id: "y", kind: .completeTask, taskId: "t9", createdAt: Date()))
        // App applied only "x"; "y" (e.g. enqueued meanwhile) must survive.
        AppGroup.removeWrites(ids: ["x"])
        let q = AppGroup.readWriteQueue()
        XCTAssertEqual(q.map { $0.id }, ["y"])
        XCTAssertEqual(q.first?.taskId, "t9")
    }

    func testRemoveAllClearsTheQueue() {
        AppGroup.removeWrites(ids: Set(AppGroup.readWriteQueue().map { $0.id }))
        AppGroup.enqueueWrite(PendingWrite(id: "z", kind: .createTask, text: "Solo", createdAt: Date()))
        AppGroup.removeWrites(ids: ["z"])
        XCTAssertTrue(AppGroup.readWriteQueue().isEmpty)
    }

    // MARK: Ask Unstuck prompt hand-off

    func testAssistantPromptRoundTripsAndClears() {
        AppGroup.setPendingAssistantPrompt("what's my afternoon like")
        XCTAssertEqual(AppGroup.consumePendingAssistantPrompt(), "what's my afternoon like")
        XCTAssertNil(AppGroup.consumePendingAssistantPrompt())
    }

    // MARK: widget Complete optimistic patch

    func testOptimisticCompleteDropsTaskAndAdvancesStartNext() {
        AppGroup.writeSnapshot(UnstuckSnapshot(
            pendingCount: 2, todayCount: 1, overdueCount: 0,
            nextTaskName: "Call bank", nextEstimateMin: 15,
            tasks: [
                .init(id: "t1", name: "Call bank", today: true),
                .init(id: "t2", name: "Email Sam", today: false),
            ],
            collections: [], updatedAt: Date(timeIntervalSince1970: 1)))
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: "Call bank", estimateMin: 15, lifeArea: nil, openCount: 2,
            taskId: "t1", updatedAt: Date(timeIntervalSince1970: 1)))

        AppGroup.optimisticComplete(taskId: "t1")

        let snap = AppGroup.readSnapshot()
        XCTAssertEqual(snap.pendingCount, 1)
        XCTAssertEqual(snap.todayCount, 0)
        XCTAssertEqual(snap.tasks.map { $0.id }, ["t2"])
        XCTAssertEqual(snap.nextTaskName, "Email Sam")

        let widget = AppGroup.readStartNext()
        XCTAssertEqual(widget.taskId, "t2")
        XCTAssertEqual(widget.taskName, "Email Sam")
        XCTAssertEqual(widget.openCount, 1)
    }

    func testStartNextSnapshotCarriesTaskId() throws {
        let s = StartNextSnapshot(taskName: "X", estimateMin: 10, lifeArea: nil,
                                  openCount: 1, taskId: "abc", updatedAt: Date(timeIntervalSince1970: 1))
        let back = try JSONDecoder().decode(StartNextSnapshot.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.taskId, "abc")
    }
}
