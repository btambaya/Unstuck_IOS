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
}
