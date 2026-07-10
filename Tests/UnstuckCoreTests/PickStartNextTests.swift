// Covers the ranker rules documented in lib/pick-start-next.ts (the web
// has no dedicated unit test for this module — these are new but encode
// the same contract that the dashboard / Up Next / NEXT badge rely on).

import XCTest
@testable import UnstuckCore

final class PickStartNextTests: XCTestCase {

    func testRanksByPriorityDescThenEstimateAscThenCreatedAtAsc() {
        let low = mkTask(id: "low", priority: .low)
        let urgentBig = mkTask(id: "urgent-big", estimateMin: 60, priority: .urgent)
        let urgentSmall = mkTask(id: "urgent-small", estimateMin: 10, priority: .urgent)
        let pick = pickStartNext(tasks: [low, urgentBig, urgentSmall], blocks: [], liveTaskId: nil)
        XCTAssertEqual(pick?.id, "urgent-small")
    }

    func testEstimateTieBrokenByCreatedAt() {
        let earlier = mkTask(id: "earlier", estimateMin: 25, priority: .high, createdAt: "2026-05-01T00:00:00.000Z")
        let later = mkTask(id: "later", estimateMin: 25, priority: .high, createdAt: "2026-05-10T00:00:00.000Z")
        let pick = pickStartNext(tasks: [later, earlier], blocks: [], liveTaskId: nil)
        XCTAssertEqual(pick?.id, "earlier")
    }

    func testMissingPriorityTreatedAsLow() {
        let none = mkTask(id: "none")            // no priority → low
        let medium = mkTask(id: "medium", priority: .medium)
        let pick = pickStartNext(tasks: [none, medium], blocks: [], liveTaskId: nil)
        XCTAssertEqual(pick?.id, "medium")
    }

    func testExcludesDoneLaterAndLive() {
        let done = mkTask(id: "done", priority: .urgent, later: nil); var d = done; d.done = true
        let later = mkTask(id: "later", priority: .urgent, later: true)
        let live = mkTask(id: "live", priority: .urgent)
        let open = mkTask(id: "open", priority: .low)
        let pick = pickStartNext(tasks: [d, later, live, open], blocks: [], liveTaskId: "live")
        XCTAssertEqual(pick?.id, "open")
    }

    func testHonoursAreaFilter() {
        let work = mkTask(id: "work", priority: .high, lifeArea: "Work")
        let personal = mkTask(id: "personal", priority: .urgent, lifeArea: "Personal")
        let pick = pickStartNext(tasks: [work, personal], blocks: [], liveTaskId: nil, areaFilter: "Work")
        XCTAssertEqual(pick?.id, "work")
    }

    func testReturnsNilWhenNoCandidates() {
        let later = mkTask(id: "later", later: true)
        XCTAssertNil(pickStartNext(tasks: [later], blocks: [], liveTaskId: nil))
        XCTAssertNil(pickStartNext(tasks: [], blocks: [], liveTaskId: nil))
    }

    func testUpNextSkipsLiveAndStartNextAndLimits() {
        let a = mkTask(id: "a", priority: .urgent)
        let b = mkTask(id: "b", priority: .high)
        let c = mkTask(id: "c", priority: .medium)
        let d = mkTask(id: "d", priority: .low)
        let live = mkTask(id: "live", priority: .urgent)
        let out = pickUpNext(tasks: [a, b, c, d, live], blocks: [],
                             liveTaskId: "live", startNextId: "a", limit: 2)
        XCTAssertEqual(out.map(\.id), ["b", "c"])
    }

    func testUpNextExcludesDoneAndLater() {
        var done = mkTask(id: "done", priority: .urgent); done.done = true
        let later = mkTask(id: "later", priority: .urgent, later: true)
        let open = mkTask(id: "open", priority: .low)
        let out = pickUpNext(tasks: [done, later, open], blocks: [], liveTaskId: nil, startNextId: nil)
        XCTAssertEqual(out.map(\.id), ["open"])
    }

    // MARK: excludeIds — tasks assigned away are never recommended (web parity:
    // pick-start-next.ts excludeIds; delegated tasks show in Delegated instead).

    func testStartNextSkipsAssignedAwayId() {
        let assigned = mkTask(id: "assigned", priority: .urgent)   // would win…
        let open = mkTask(id: "open", priority: .low)
        let pick = pickStartNext(tasks: [assigned, open], blocks: [], liveTaskId: nil,
                                 areaFilter: nil, excludeIds: ["assigned"])
        XCTAssertEqual(pick?.id, "open")                            // …but it's excluded
    }

    func testUpNextSkipsAssignedAwayIds() {
        let a = mkTask(id: "a", priority: .urgent)
        let b = mkTask(id: "b", priority: .high)
        let c = mkTask(id: "c", priority: .medium)
        let out = pickUpNext(tasks: [a, b, c], blocks: [], liveTaskId: nil, startNextId: nil,
                             limit: 3, excludeIds: ["a"])
        XCTAssertEqual(out.map(\.id), ["b", "c"])
    }
}
