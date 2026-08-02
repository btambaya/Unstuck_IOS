// Ported 1:1 from lib/shared-task-visibility.test.ts — a completed SHARED task
// follows the same rules as the user's own completed tasks (gone from Today,
// today's win still visible in All, and it lives under Completed from then on).

import XCTest
@testable import UnstuckCore

/// Minimal row standing in for the projection (the web test uses object
/// literals). `SharedWithMe` conformance is covered separately below.
private struct Row: ShareVisibilityItem, Equatable {
    var id: String = "r"
    var done: Bool
    var completedAt: String?
}

/// Today's 09:30 (local) and an hour before today's local midnight — always
/// "yesterday", DST included.
private let startToday = Time.startOfDayMillis(NOW)
private let doneTodayStamp = iso(startToday + 9.5 * 60 * 60 * 1000)
private let doneYesterdayStamp = iso(startToday - 60 * 60 * 1000)

private let open = Row(id: "open", done: false)
private let doneToday = Row(id: "done", done: true, completedAt: doneTodayStamp)
private let doneYesterday = Row(id: "old", done: true, completedAt: doneYesterdayStamp)
private let doneUnknownWhen = Row(id: "nostamp", done: true, completedAt: nil)

final class ShareVisibleInTests: XCTestCase {

    func testTodayShowsOpenWorkOnly() {
        XCTAssertTrue(shareVisibleIn(open, .today, now: NOW))
        XCTAssertFalse(shareVisibleIn(doneToday, .today, now: NOW))
        XCTAssertFalse(shareVisibleIn(doneYesterday, .today, now: NOW))
    }

    func testAllKeepsTodaysWinButAgesOlderCompletionsOut() {
        XCTAssertTrue(shareVisibleIn(open, .all, now: NOW))
        XCTAssertTrue(shareVisibleIn(doneToday, .all, now: NOW))
        XCTAssertFalse(shareVisibleIn(doneYesterday, .all, now: NOW))
    }

    func testCompletedHoldsEveryFinishedShareHoweverOld() {
        XCTAssertTrue(shareVisibleIn(doneYesterday, .completed, now: NOW))
        XCTAssertTrue(shareVisibleIn(doneToday, .completed, now: NOW))
        XCTAssertFalse(shareVisibleIn(open, .completed, now: NOW))
    }

    func testWithoutACompletionTimeADoneShareStillLeavesTheActiveLists() {
        XCTAssertFalse(shareVisibleIn(doneUnknownWhen, .today, now: NOW))
        XCTAssertFalse(shareVisibleIn(doneUnknownWhen, .all, now: NOW))
        XCTAssertTrue(shareVisibleIn(doneUnknownWhen, .completed, now: NOW))
    }

    func testMalformedTimestampNeverKeepsACompletedRowInTheActiveList() {
        let bad = Row(id: "bad", done: true, completedAt: "not-a-date")
        XCTAssertFalse(shareVisibleIn(bad, .all, now: NOW))
        XCTAssertFalse(shareVisibleIn(bad, .today, now: NOW))
        XCTAssertTrue(shareVisibleIn(bad, .completed, now: NOW))
    }
}

final class VisibleSharesTests: XCTestCase {

    private let items = [doneToday, Row(id: "open1", done: false), doneYesterday, Row(id: "open2", done: false)]

    func testFiltersByViewAndAlwaysPutsOpenRowsAboveCompletedOnes() {
        XCTAssertEqual(visibleShares(items, mode: .all, now: NOW).map(\.id), ["open1", "open2", "done"])
        XCTAssertEqual(visibleShares(items, mode: .today, now: NOW).map(\.id), ["open1", "open2"])
        XCTAssertEqual(visibleShares(items, mode: .completed, now: NOW).map(\.id), ["done", "old"])
    }

    func testOrderIsStableWithinEachBucket() {
        let many = [Row(id: "d1", done: true, completedAt: doneTodayStamp),
                    Row(id: "o1", done: false),
                    Row(id: "d2", done: true, completedAt: doneTodayStamp),
                    Row(id: "o2", done: false),
                    Row(id: "o3", done: false)]
        XCTAssertEqual(visibleShares(many, mode: .all, now: NOW).map(\.id), ["o1", "o2", "o3", "d1", "d2"])
    }

    func testEmptyInEmptyOut() {
        XCTAssertTrue(visibleShares([Row](), mode: .all, now: NOW).isEmpty)
    }
}

final class ShareViewModeTests: XCTestCase {

    /// The mapping the Tasks screen uses to pick a mode from its list view —
    /// mirrors the web `view === 'Completed' ? 'completed' : view === 'Today' ? 'today' : 'all'`.
    func testModeFromTaskListView() {
        XCTAssertEqual(ShareViewMode(.completed), .completed)
        XCTAssertEqual(ShareViewMode(.today), .today)
        XCTAssertEqual(ShareViewMode(.all), .all)
        // Views that don't mount the group degrade to `.all`, never to a
        // mode that would hide open shares.
        XCTAssertEqual(ShareViewMode(.backlog), .all)
        XCTAssertEqual(ShareViewMode(.upcoming), .all)
        XCTAssertEqual(ShareViewMode(.later), .all)
        XCTAssertEqual(ShareViewMode(.recurring), .all)
    }
}

/// `SharedWithMe` is the real row the app filters — its stamp must survive the
/// projection (either key shape) and its absence must not break decoding.
final class SharedWithMeVisibilityTests: XCTestCase {

    private func decode(_ json: String) throws -> SharedWithMe {
        try JSONDecoder().decode(SharedWithMe.self, from: Data(json.utf8))
    }

    func testDecodesCompletedAtFromEitherKeyAndToleratesItsAbsence() throws {
        let camel = try decode("""
        {"shareId":"s1","taskId":"t1","ownerName":"Pat","level":"assign",
         "title":"Ship the deck","done":true,"completedAt":"\(doneTodayStamp)"}
        """)
        XCTAssertEqual(camel.completedAt, doneTodayStamp)

        let snake = try decode("""
        {"shareId":"s2","taskId":"t2","ownerName":"Pat","level":"assign",
         "title":"Ship the deck","done":true,"completed_at":"\(doneTodayStamp)"}
        """)
        XCTAssertEqual(snake.completedAt, doneTodayStamp)

        // Pre-049 projection: the key is absent entirely.
        let missing = try decode("""
        {"shareId":"s3","taskId":"t3","ownerName":"Pat","level":"view",
         "title":"Read spec","done":false}
        """)
        XCTAssertNil(missing.completedAt)
        XCTAssertFalse(missing.done)

        // Explicit null is equally fine.
        let null = try decode("""
        {"shareId":"s4","taskId":"t4","ownerName":"Pat","level":"partner",
         "title":"Read spec","done":true,"completedAt":null}
        """)
        XCTAssertNil(null.completedAt)
    }

    func testSharedWithMeFlowsThroughTheRule() {
        let done = SharedWithMe(shareId: "s1", taskId: "t1", ownerName: "Pat", level: .partner,
                                title: "Ship the deck", done: true, completedAt: doneTodayStamp)
        let openRow = SharedWithMe(shareId: "s2", taskId: "t2", ownerName: "Pat", level: .partner,
                                   title: "Draft it", done: false)
        XCTAssertEqual(visibleShares([done, openRow], mode: .today, now: NOW).map(\.taskId), ["t2"])
        XCTAssertEqual(visibleShares([done, openRow], mode: .all, now: NOW).map(\.taskId), ["t2", "t1"])
        XCTAssertEqual(visibleShares([done, openRow], mode: .completed, now: NOW).map(\.taskId), ["t1"])
    }
}
