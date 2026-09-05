// Ported 1:1 from lib/shared-task-visibility.test.ts — a completed SHARED task
// follows the same rules as the user's own completed tasks (gone from Today,
// today's win still visible in All, and it lives under Completed from then on)
// — extended with the schedule-aware placement (migration 052): a shared task
// sits where the OWNER's next live block puts it (Today / Upcoming / Backlog),
// honours the active life-area filter, and reads its slot on the row.

import XCTest
@testable import UnstuckCore

/// Minimal row standing in for the projection (the web test uses object
/// literals). `SharedWithMe` conformance is covered separately below.
private struct Row: ShareVisibilityItem, Equatable {
    var id: String = "r"
    var done: Bool
    var completedAt: String?
    var nextDate: String?
    var nextDone: Bool?
    var lifeArea: String?
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

/// A fixed local "today" for the date-aware cases (a Thursday).
private let TODAY = "2026-05-21"
private let scheduledToday = Row(id: "today", done: false, nextDate: TODAY)
private let scheduledTomorrow = Row(id: "tomorrow", done: false, nextDate: "2026-05-22")
private let scheduledNextMonth = Row(id: "later", done: false, nextDate: "2026-06-03")
private let overdue = Row(id: "overdue", done: false, nextDate: "2026-05-15")
private let finishedPastBlock = Row(id: "pastdone", done: false, nextDate: "2026-05-15", nextDone: true)
private let unscheduled = Row(id: "none", done: false, nextDate: nil)

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

    // MARK: schedule-aware placement (migration 052)

    func testTodayHoldsSharesScheduledTodayOrNotScheduledAtAll() {
        XCTAssertTrue(shareVisibleIn(scheduledToday, .today, now: NOW, todayISO: TODAY))
        XCTAssertTrue(shareVisibleIn(unscheduled, .today, now: NOW, todayISO: TODAY))
        // The bug: every shared task sat under Today regardless of its date.
        XCTAssertFalse(shareVisibleIn(scheduledTomorrow, .today, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(scheduledNextMonth, .today, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(overdue, .today, now: NOW, todayISO: TODAY))
    }

    func testUpcomingHoldsOnlyFutureScheduledShares() {
        XCTAssertTrue(shareVisibleIn(scheduledTomorrow, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertTrue(shareVisibleIn(scheduledNextMonth, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(scheduledToday, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(unscheduled, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(overdue, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(doneToday, .upcoming, now: NOW, todayISO: TODAY))
    }

    func testBacklogHoldsOnlyOverdueShares() {
        XCTAssertTrue(shareVisibleIn(overdue, .backlog, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(scheduledToday, .backlog, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(scheduledTomorrow, .backlog, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(unscheduled, .backlog, now: NOW, todayISO: TODAY))
        // A completed share is never "overdue".
        XCTAssertFalse(shareVisibleIn(Row(id: "d", done: true, completedAt: doneYesterdayStamp, nextDate: "2026-05-15"),
                                      .backlog, now: NOW, todayISO: TODAY))
    }

    func testAFinishedPastBlockMeansUnscheduledNotOverdue() {
        // The server falls back to the most recent PAST block only when no live
        // block exists; if that past block is done, nothing is scheduled.
        XCTAssertNil(sharedPlacementDate(nextDate: "2026-05-15", nextDone: true))
        XCTAssertEqual(sharedPlacementDate(nextDate: "2026-05-15", nextDone: false), "2026-05-15")
        XCTAssertEqual(sharedPlacementDate(nextDate: "2026-05-15", nextDone: nil), "2026-05-15")
        XCTAssertNil(sharedPlacementDate(nextDate: nil, nextDone: nil))
        XCTAssertNil(sharedPlacementDate(nextDate: "", nextDone: nil))
        XCTAssertTrue(shareVisibleIn(finishedPastBlock, .today, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(finishedPastBlock, .backlog, now: NOW, todayISO: TODAY))
    }

    func testAllHoldsEveryOpenShareWhateverItsDate() {
        for r in [scheduledToday, scheduledTomorrow, scheduledNextMonth, overdue, unscheduled, finishedPastBlock] {
            XCTAssertTrue(shareVisibleIn(r, .all, now: NOW, todayISO: TODAY), r.id)
        }
    }

    func testCompletedIgnoresTheSchedule() {
        XCTAssertTrue(shareVisibleIn(Row(id: "d", done: true, nextDate: "2026-06-03"), .completed, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(scheduledNextMonth, .completed, now: NOW, todayISO: TODAY))
    }

    func testPre052ProjectionDegradesToUnscheduled() {
        // The default protocol extension: a row without schedule fields reads
        // as unscheduled → Today, never Upcoming/Backlog.
        struct Legacy: ShareVisibilityItem { var done: Bool; var completedAt: String? }
        let l = Legacy(done: false, completedAt: nil)
        XCTAssertNil(l.nextDate)
        XCTAssertNil(l.nextDone)
        XCTAssertNil(l.lifeArea)
        XCTAssertTrue(shareVisibleIn(l, .today, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(l, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(l, .backlog, now: NOW, todayISO: TODAY))
    }

    // MARK: life-area filter

    func testActiveAreaNarrowsEveryMode() {
        let work = Row(id: "w", done: false, nextDate: TODAY, lifeArea: "Work")
        let home = Row(id: "h", done: false, nextDate: TODAY, lifeArea: "Home")
        let none = Row(id: "n", done: false, nextDate: TODAY, lifeArea: nil)
        XCTAssertTrue(shareVisibleIn(work, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        XCTAssertFalse(shareVisibleIn(home, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        // A pre-052 row (no area) is hidden under an area pill — like Delegated.
        XCTAssertFalse(shareVisibleIn(none, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        // The Unassigned sentinel admits only area-less rows; nil admits all.
        XCTAssertTrue(shareVisibleIn(none, .today, now: NOW, todayISO: TODAY, activeArea: UNASSIGNED_AREA))
        XCTAssertFalse(shareVisibleIn(work, .today, now: NOW, todayISO: TODAY, activeArea: UNASSIGNED_AREA))
        XCTAssertTrue(shareVisibleIn(home, .today, now: NOW, todayISO: TODAY, activeArea: nil))
        XCTAssertTrue(shareVisibleIn(home, .all, now: NOW, todayISO: TODAY, activeArea: ""))
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

    func testSplitsAMixedListAcrossTodayUpcomingBacklog() {
        let mixed = [scheduledNextMonth, overdue, scheduledToday, unscheduled, scheduledTomorrow, doneToday]
        XCTAssertEqual(visibleShares(mixed, mode: .today, now: NOW, todayISO: TODAY).map(\.id), ["today", "none"])
        XCTAssertEqual(visibleShares(mixed, mode: .upcoming, now: NOW, todayISO: TODAY).map(\.id), ["later", "tomorrow"])
        XCTAssertEqual(visibleShares(mixed, mode: .backlog, now: NOW, todayISO: TODAY).map(\.id), ["overdue"])
        XCTAssertEqual(visibleShares(mixed, mode: .all, now: NOW, todayISO: TODAY).map(\.id),
                       ["later", "overdue", "today", "none", "tomorrow", "done"])
    }

    func testAreaFilterAppliesToTheList() {
        let rows = [Row(id: "w", done: false, lifeArea: "Work"), Row(id: "h", done: false, lifeArea: "Home")]
        XCTAssertEqual(visibleShares(rows, mode: .today, now: NOW, todayISO: TODAY, activeArea: "Home").map(\.id), ["h"])
        XCTAssertEqual(visibleShares(rows, mode: .today, now: NOW, todayISO: TODAY).map(\.id), ["w", "h"])
    }
}

final class ShareViewModeTests: XCTestCase {

    /// The mapping the Tasks screen uses to pick a mode from its list view —
    /// every date-aware bucket maps 1:1; the views that never mount the group
    /// degrade to `.all`, never to a mode that would hide open shares.
    func testModeFromTaskListView() {
        XCTAssertEqual(ShareViewMode(.completed), .completed)
        XCTAssertEqual(ShareViewMode(.today), .today)
        XCTAssertEqual(ShareViewMode(.all), .all)
        XCTAssertEqual(ShareViewMode(.backlog), .backlog)
        XCTAssertEqual(ShareViewMode(.upcoming), .upcoming)
        XCTAssertEqual(ShareViewMode(.later), .all)
        XCTAssertEqual(ShareViewMode(.recurring), .all)
    }
}

/// The slot the row shows ("Sat 04:30 · 45m") and the detail's "Planned …" line.
final class SharedSlotLabelTests: XCTestCase {

    func testDayLabelRelativeToToday() {
        XCTAssertEqual(sharedDayLabel(TODAY, todayISO: TODAY), "Today")
        XCTAssertEqual(sharedDayLabel("2026-05-22", todayISO: TODAY), "Tomorrow")
        XCTAssertEqual(sharedDayLabel("2026-05-23", todayISO: TODAY), "Sat")      // inside the coming week
        XCTAssertEqual(sharedDayLabel("2026-05-27", todayISO: TODAY), "Wed")      // +6 — still a bare weekday
        XCTAssertEqual(sharedDayLabel("2026-05-28", todayISO: TODAY), "Thu 28 May") // +7 — needs the date
        XCTAssertEqual(sharedDayLabel("2026-06-03", todayISO: TODAY), "Wed 3 Jun")
        XCTAssertEqual(sharedDayLabel("2026-05-15", todayISO: TODAY), "Overdue · Fri")
        XCTAssertEqual(sharedDayLabel("garbage", todayISO: TODAY), "")
    }

    func testSlotLabelFromTheNextBlock() {
        XCTAssertEqual(sharedSlotLabel(nextDate: "2026-05-23", nextStartTime: "04:30", nextDurationMinutes: 45, todayISO: TODAY),
                       "Sat 04:30 · 45m")
        XCTAssertEqual(sharedSlotLabel(nextDate: TODAY, nextStartTime: "09:00", nextDurationMinutes: 25, todayISO: TODAY),
                       "Today 09:00 · 25m")
        XCTAssertEqual(sharedSlotLabel(nextDate: "2026-05-15", nextStartTime: "09:00", nextDurationMinutes: 45, todayISO: TODAY),
                       "Overdue · Fri 09:00 · 45m")
        // Missing pieces are simply omitted.
        XCTAssertEqual(sharedSlotLabel(nextDate: "2026-05-23", nextStartTime: nil, nextDurationMinutes: nil, todayISO: TODAY), "Sat")
        XCTAssertEqual(sharedSlotLabel(nextDate: "2026-05-23", nextStartTime: "", nextDurationMinutes: 0, todayISO: TODAY), "Sat")
        // Nothing placed → nil (row falls back to "from <owner>").
        XCTAssertNil(sharedSlotLabel(nextDate: nil, nextStartTime: nil, nextDurationMinutes: nil, todayISO: TODAY))
        XCTAssertNil(sharedSlotLabel(nextDate: "2026-05-15", nextStartTime: "09:00", nextDurationMinutes: 45,
                                     nextDone: true, todayISO: TODAY))
    }

    func testPlannedLabelForTheDetail() {
        XCTAssertEqual(sharedPlannedLabel(nextDate: "2026-05-23", nextStartTime: "04:30", nextDurationMinutes: 45, nextDone: false),
                       "Planned Sat, May 23 · 04:30 · 45m")
        // A finished past block still says when the task WAS.
        XCTAssertEqual(sharedPlannedLabel(nextDate: "2026-05-15", nextStartTime: "09:00", nextDurationMinutes: 45, nextDone: true),
                       "Done Fri, May 15 · 09:00 · 45m")
        XCTAssertEqual(sharedPlannedLabel(nextDate: "2026-05-23", nextStartTime: nil, nextDurationMinutes: nil, nextDone: nil),
                       "Planned Sat, May 23")
        XCTAssertNil(sharedPlannedLabel(nextDate: nil, nextStartTime: "09:00", nextDurationMinutes: 45, nextDone: nil))
        XCTAssertNil(sharedPlannedLabel(nextDate: "nope", nextStartTime: nil, nextDurationMinutes: nil, nextDone: nil))
    }
}

/// `SharedWithMe` is the real row the app filters — its stamp + schedule must
/// survive the projection (either key shape) and their absence must not
/// break decoding.
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

    func testSharedWithMeIsPlacedByItsNextBlockAndArea() {
        let future = SharedWithMe(shareId: "s1", taskId: "t1", ownerName: "Anna", level: .view,
                                  title: "Deck", done: false, lifeArea: "Work",
                                  nextBlockId: "b1", nextDate: "2026-05-23", nextStartTime: "04:30",
                                  nextDurationMinutes: 45, nextDone: false)
        let today = SharedWithMe(shareId: "s2", taskId: "t2", ownerName: "Anna", level: .partner,
                                 title: "Call", done: false, lifeArea: "Home",
                                 nextBlockId: "b2", nextDate: TODAY, nextStartTime: "10:00",
                                 nextDurationMinutes: 25, nextDone: false)
        XCTAssertEqual(visibleShares([future, today], mode: .today, now: NOW, todayISO: TODAY).map(\.taskId), ["t2"])
        XCTAssertEqual(visibleShares([future, today], mode: .upcoming, now: NOW, todayISO: TODAY).map(\.taskId), ["t1"])
        XCTAssertEqual(visibleShares([future, today], mode: .today, now: NOW, todayISO: TODAY, activeArea: "Work").map(\.taskId), [])
        XCTAssertEqual(visibleShares([future, today], mode: .all, now: NOW, todayISO: TODAY, activeArea: "Work").map(\.taskId), ["t1"])
        XCTAssertEqual(sharedSlotLabel(nextDate: future.nextDate, nextStartTime: future.nextStartTime,
                                       nextDurationMinutes: future.nextDurationMinutes, nextDone: future.nextDone,
                                       todayISO: TODAY), "Sat 04:30 · 45m")
    }
}
