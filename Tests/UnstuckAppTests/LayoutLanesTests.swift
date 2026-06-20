// App-layer unit tests for the calendar lane layout (the overlap → side-by-side
// columns greedy interval colouring in CalendarFeature). Pure function over
// CalBlock; no UI, no store. Mirrors the Android layoutLanes / web calendar.

import XCTest
import UnstuckCore
@testable import Unstuck

private func block(_ id: String, _ start: String, _ durationMin: Int) -> CalBlock {
    CalBlock(id: id, taskId: id, taskName: id, startTime: start,
             durationMinutes: durationMin, date: "2026-05-21", kind: .task)
}

final class LayoutLanesTests: XCTestCase {
    func testEmptyInput() {
        XCTAssertTrue(layoutLanes([]).isEmpty)
    }

    func testSingleBlockOneLane() {
        let laid = layoutLanes([block("a", "09:00", 60)])
        XCTAssertEqual(laid.count, 1)
        XCTAssertEqual(laid[0].lane, 0)
        XCTAssertEqual(laid[0].lanes, 1)
        XCTAssertEqual(laid[0].startMin, 9 * 60)
        XCTAssertEqual(laid[0].endMin, 10 * 60)
    }

    func testNonOverlappingBlocksAllLaneZeroSingleColumn() {
        // 9–10 and 11–12 don't overlap → each is its own cluster, one lane wide.
        let laid = layoutLanes([block("a", "09:00", 60), block("b", "11:00", 60)])
        XCTAssertEqual(laid.map(\.lane), [0, 0])
        XCTAssertEqual(laid.map(\.lanes), [1, 1])
    }

    func testTwoOverlapSplitsIntoTwoLanes() {
        // 9–10 and 9:30–10:30 overlap → two side-by-side lanes, width 2.
        let laid = layoutLanes([block("a", "09:00", 60), block("b", "09:30", 60)])
        XCTAssertEqual(laid.map(\.lane), [0, 1])
        XCTAssertEqual(laid.map(\.lanes), [2, 2])
    }

    func testAdjacentEndEqualsStartDoesNotOverlap() {
        // 9–10 ends exactly when 10–11 starts (end == start) → NOT overlapping,
        // so they stay in a single lane (half-open interval semantics).
        let laid = layoutLanes([block("a", "09:00", 60), block("b", "10:00", 60)])
        XCTAssertEqual(laid.map(\.lane), [0, 0])
        XCTAssertEqual(laid.map(\.lanes), [1, 1])
    }

    func testThreeWayOverlapCapsAtThreeLanes() {
        // Three mutually-overlapping blocks → three lanes.
        let laid = layoutLanes([
            block("a", "09:00", 90),   // 9:00–10:30
            block("b", "09:15", 90),   // 9:15–10:45
            block("c", "09:30", 90),   // 9:30–11:00
        ])
        XCTAssertEqual(Set(laid.map(\.lane)), [0, 1, 2])
        XCTAssertEqual(laid.map(\.lanes), [3, 3, 3])
    }

    func testFreedLaneIsReused() {
        // a: 9–10, b: 9:30–10:30 (overlaps a → lane 1), c: 10–11 starts when a
        // ends so it can reuse lane 0; all three are one transitive cluster (b
        // overlaps both a and c) → cluster width 2.
        let laid = layoutLanes([block("a", "09:00", 60), block("b", "09:30", 60), block("c", "10:00", 60)])
        let byId = Dictionary(uniqueKeysWithValues: laid.map { ($0.block.id, $0) })
        XCTAssertEqual(byId["a"]?.lane, 0)
        XCTAssertEqual(byId["b"]?.lane, 1)
        XCTAssertEqual(byId["c"]?.lane, 0, "c reuses the lane a vacated at 10:00")
        XCTAssertEqual(laid.map(\.lanes), [2, 2, 2])
    }

    func testZeroDurationGetsMinimumHeight() {
        // A 0-minute block is coerced to span at least 1 minute (max(1, …)).
        let laid = layoutLanes([block("a", "09:00", 0)])
        XCTAssertEqual(laid[0].endMin, laid[0].startMin + 1)
    }
}
