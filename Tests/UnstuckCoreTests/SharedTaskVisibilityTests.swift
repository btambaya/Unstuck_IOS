// Ported 1:1 from lib/shared-task-visibility.test.ts — a completed SHARED task
// follows the same rules as the user's own completed tasks (gone from Today,
// today's win still visible in All, and it lives under Completed from then on)
// — extended with the schedule-aware placement (migration 052): a shared task
// sits where the OWNER's next live block puts it (Today / Upcoming / Backlog),
// honours the active life-area filter, and reads its slot on the row — and
// the CROSS-PLATFORM contract (migration 053): a finished past block is
// "done-ish" (All only), an area-less share always shows, open rows are
// chronological, and `next_start_at` places the row in the RECIPIENT's zone.

import XCTest
@testable import UnstuckCore

/// Minimal row standing in for the projection (the web test uses object
/// literals). `SharedWithMe` conformance is covered separately below.
private struct Row: ShareVisibilityItem, Equatable {
    var id: String = "r"
    var done: Bool
    var completedAt: String?
    var nextDate: String?
    var nextStartTime: String?
    var nextStartAt: String?
    var nextDone: Bool?
    var later: Bool?
    var lifeArea: String?
}

private let london = TimeZone(identifier: "Europe/London")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

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

    func testAFinishedPastBlockIsDoneIshAllOnlyNeverTodayOrBacklog() {
        // The server falls back to the most recent PAST block only when no live
        // block exists; if that past block is done, nothing is scheduled — but
        // it isn't current work either. The cross-platform rule (web / Android
        // / iOS): All only. It used to sit under Today here while web + Android
        // put it in Backlog — two devices of one user disagreed.
        XCTAssertNil(sharedPlacementDate(nextDate: "2026-05-15", nextDone: true))
        XCTAssertEqual(sharedPlacementDate(nextDate: "2026-05-15", nextDone: false), "2026-05-15")
        XCTAssertEqual(sharedPlacementDate(nextDate: "2026-05-15", nextDone: nil), "2026-05-15")
        XCTAssertNil(sharedPlacementDate(nextDate: nil, nextDone: nil))
        XCTAssertNil(sharedPlacementDate(nextDate: "", nextDone: nil))
        XCTAssertEqual(shareBucket(finishedPastBlock, todayISO: TODAY), .finishedPast)
        XCTAssertFalse(shareVisibleIn(finishedPastBlock, .today, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(finishedPastBlock, .backlog, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(finishedPastBlock, .upcoming, now: NOW, todayISO: TODAY))
        XCTAssertTrue(shareVisibleIn(finishedPastBlock, .all, now: NOW, todayISO: TODAY))
        XCTAssertFalse(shareVisibleIn(finishedPastBlock, .completed, now: NOW, todayISO: TODAY))
    }

    func testBucketsMirrorTheWebRule() {
        XCTAssertEqual(shareBucket(scheduledToday, todayISO: TODAY), .today)
        XCTAssertEqual(shareBucket(scheduledTomorrow, todayISO: TODAY), .upcoming)
        XCTAssertEqual(shareBucket(overdue, todayISO: TODAY), .overdue)
        XCTAssertEqual(shareBucket(unscheduled, todayISO: TODAY), .unscheduled)
        XCTAssertEqual(shareBucket(doneToday, todayISO: TODAY), .done)
    }

    // MARK: `later` (migration 053) — the owner's Later bucket travels with the share

    func testAParkedShareLeavesTodayAndBacklogLikeTheOwnersOwnLaterTasks() {
        let parkedNoBlock = Row(id: "p1", done: false, later: true)
        let parkedOverdue = Row(id: "p2", done: false, nextDate: "2026-05-15", later: true)
        let parkedToday = Row(id: "p3", done: false, nextDate: TODAY, later: true)
        let parkedFuture = Row(id: "p4", done: false, nextDate: "2026-05-22", later: true)
        for r in [parkedNoBlock, parkedOverdue, parkedToday] {
            XCTAssertEqual(shareBucket(r, todayISO: TODAY), .parked, r.id)
            XCTAssertFalse(shareVisibleIn(r, .today, now: NOW, todayISO: TODAY), r.id)
            XCTAssertFalse(shareVisibleIn(r, .backlog, now: NOW, todayISO: TODAY), r.id)
            XCTAssertFalse(shareVisibleIn(r, .upcoming, now: NOW, todayISO: TODAY), r.id)
            XCTAssertTrue(shareVisibleIn(r, .all, now: NOW, todayISO: TODAY), r.id)
        }
        // A future block still puts it in Upcoming (own-task rule).
        XCTAssertEqual(shareBucket(parkedFuture, todayISO: TODAY), .upcoming)
        XCTAssertTrue(shareVisibleIn(parkedFuture, .upcoming, now: NOW, todayISO: TODAY))
        // `later: false` / nil is the plain rule.
        XCTAssertEqual(shareBucket(Row(id: "n", done: false, nextDate: TODAY, later: false), todayISO: TODAY), .today)
    }

    // MARK: `next_start_at` (migration 053) — placed in the RECIPIENT's zone

    func testNextStartAtPlacesTheRowOnTheRecipientsDay() {
        // The owner (Tokyo) booked Fri 22 May 00:30 local = Thu 21 May 15:30Z.
        // The projection's next_date says "2026-05-22" — the OWNER's day.
        let row = Row(id: "x", done: false, nextDate: "2026-05-22", nextStartTime: "00:30",
                      nextStartAt: "2026-05-21T15:30:00+00:00")
        // A London recipient (BST) sees 16:30 on Thu 21 May → Today.
        XCTAssertEqual(shareBucket(row, todayISO: TODAY, timeZone: london), .today)
        XCTAssertTrue(shareVisibleIn(row, .today, now: NOW, todayISO: TODAY, timeZone: london))
        XCTAssertFalse(shareVisibleIn(row, .upcoming, now: NOW, todayISO: TODAY, timeZone: london))
        XCTAssertEqual(sharedPlacementDate(nextDate: row.nextDate, nextStartAt: row.nextStartAt, nextDone: nil,
                                           timeZone: london), "2026-05-21")
        // A Tokyo recipient sees the owner's own day → Upcoming.
        XCTAssertEqual(shareBucket(row, todayISO: TODAY, timeZone: tokyo), .upcoming)
        // The slot + planned labels read in the recipient's zone too.
        XCTAssertEqual(sharedSlotLabel(nextDate: row.nextDate, nextStartTime: row.nextStartTime, nextDurationMinutes: 45,
                                       nextStartAt: row.nextStartAt, todayISO: TODAY, timeZone: london),
                       "Today 16:30 · 45m")
        XCTAssertEqual(sharedSlotLabel(nextDate: row.nextDate, nextStartTime: row.nextStartTime, nextDurationMinutes: 45,
                                       nextStartAt: row.nextStartAt, todayISO: TODAY, timeZone: tokyo),
                       "Tomorrow 00:30 · 45m")
        XCTAssertEqual(sharedPlannedLabel(nextDate: row.nextDate, nextStartTime: row.nextStartTime, nextDurationMinutes: 45,
                                          nextDone: false, nextStartAt: row.nextStartAt, timeZone: london),
                       "Planned Thu, May 21 · 16:30 · 45m")
        XCTAssertEqual(sharedPlannedLabel(nextDate: row.nextDate, nextStartTime: row.nextStartTime, nextDurationMinutes: 45,
                                          nextDone: true, nextStartAt: row.nextStartAt, timeZone: london),
                       "Done Thu, May 21 · 16:30 · 45m")
    }

    func testNextStartAtFallsBackToTheOwnersTextWhenAbsentOrUnparseable() {
        // Pre-053 server: no instant → the owner's date/time text, as before.
        let slot = sharedLocalSlot(nextDate: "2026-05-22", nextStartTime: "00:30", nextStartAt: nil, timeZone: london)
        XCTAssertEqual(slot?.date, "2026-05-22")
        XCTAssertEqual(slot?.time, "00:30")
        // Garbage instant → the same fallback, never a crash or a lost row.
        let bad = sharedLocalSlot(nextDate: "2026-05-22", nextStartTime: nil, nextStartAt: "not-a-date", timeZone: london)
        XCTAssertEqual(bad?.date, "2026-05-22")
        XCTAssertNil(bad?.time)
        XCTAssertNil(sharedLocalSlot(nextDate: nil, nextStartTime: nil, nextStartAt: nil))
        // Postgres microseconds are accepted (the ISO parser wants three digits).
        XCTAssertEqual(sharedInstantMillis("2026-05-21T15:30:00.123456+00:00"),
                       sharedInstantMillis("2026-05-21T15:30:00.123+00:00"))
        XCTAssertNotNil(sharedInstantMillis("2026-05-21T15:30:00Z"))
        XCTAssertNil(sharedInstantMillis("2026-05-21"))
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

    func testActiveAreaNarrowsEveryModeButAnAreaLessShareAlwaysShows() {
        let work = Row(id: "w", done: false, nextDate: TODAY, lifeArea: "Work")
        let home = Row(id: "h", done: false, nextDate: TODAY, lifeArea: "Home")
        let none = Row(id: "n", done: false, nextDate: TODAY, lifeArea: nil)
        let blank = Row(id: "b", done: false, nextDate: TODAY, lifeArea: "")
        XCTAssertTrue(shareVisibleIn(work, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        XCTAssertFalse(shareVisibleIn(home, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        // The web / Android `shareMatchesArea` rule: an area-less share is
        // ALWAYS shown under an area pill (the owner's vocabulary isn't ours —
        // it used to vanish here for no visible reason).
        XCTAssertTrue(shareVisibleIn(none, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        XCTAssertTrue(shareVisibleIn(blank, .today, now: NOW, todayISO: TODAY, activeArea: "Work"))
        // The Unassigned sentinel admits only area-less rows; nil admits all.
        XCTAssertTrue(shareVisibleIn(none, .today, now: NOW, todayISO: TODAY, activeArea: UNASSIGNED_AREA))
        XCTAssertFalse(shareVisibleIn(work, .today, now: NOW, todayISO: TODAY, activeArea: UNASSIGNED_AREA))
        XCTAssertTrue(shareVisibleIn(home, .today, now: NOW, todayISO: TODAY, activeArea: nil))
        XCTAssertTrue(shareVisibleIn(home, .all, now: NOW, todayISO: TODAY, activeArea: ""))
    }

    func testShareMatchesAreaIsTheWebRule() {
        XCTAssertTrue(shareMatchesArea(nil, nil))
        XCTAssertTrue(shareMatchesArea("Work", nil))
        XCTAssertTrue(shareMatchesArea("Work", ""))
        XCTAssertTrue(shareMatchesArea("Work", "Work"))
        XCTAssertFalse(shareMatchesArea("Home", "Work"))
        XCTAssertTrue(shareMatchesArea(nil, "Work"), "area-less always shows")
        XCTAssertTrue(shareMatchesArea("", "Work"), "blank counts as area-less")
        XCTAssertTrue(shareMatchesArea(nil, UNASSIGNED_AREA))
        XCTAssertFalse(shareMatchesArea("Work", UNASSIGNED_AREA))
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

    func testSplitsAMixedListAcrossTodayUpcomingBacklogInSlotOrder() {
        // Open rows are CHRONOLOGICAL by the owner's slot (unscheduled last),
        // not in share order — web / Android parity ("Call bank 09:00" above
        // "Review PR 16:00" however recently each was shared).
        let mixed = [scheduledNextMonth, overdue, scheduledToday, unscheduled, scheduledTomorrow, doneToday, finishedPastBlock]
        XCTAssertEqual(visibleShares(mixed, mode: .today, now: NOW, todayISO: TODAY).map(\.id), ["today", "none"])
        XCTAssertEqual(visibleShares(mixed, mode: .upcoming, now: NOW, todayISO: TODAY).map(\.id), ["tomorrow", "later"])
        XCTAssertEqual(visibleShares(mixed, mode: .backlog, now: NOW, todayISO: TODAY).map(\.id), ["overdue"])
        XCTAssertEqual(visibleShares(mixed, mode: .all, now: NOW, todayISO: TODAY).map(\.id),
                       ["overdue", "pastdone", "today", "tomorrow", "later", "none", "done"])
    }

    func testOpenRowsSortByTimeWithinADayAndKeepShareOrderOnTies() {
        let late = Row(id: "late", done: false, nextDate: TODAY, nextStartTime: "16:00")
        let early = Row(id: "early", done: false, nextDate: TODAY, nextStartTime: "09:00")
        let noTime = Row(id: "notime", done: false, nextDate: TODAY)
        let dupA = Row(id: "dupA", done: false, nextDate: TODAY, nextStartTime: "09:00")
        XCTAssertEqual(visibleShares([late, early, noTime, dupA], mode: .today, now: NOW, todayISO: TODAY).map(\.id),
                       ["notime", "early", "dupA", "late"])
        XCTAssertLessThan(compareShareSlot(early, late), 0)
        XCTAssertGreaterThan(compareShareSlot(late, early), 0)
        XCTAssertEqual(compareShareSlot(early, dupA), 0)
        XCTAssertEqual(compareShareSlot(unscheduled, unscheduled), 0)
        XCTAssertGreaterThan(compareShareSlot(unscheduled, late), 0, "unscheduled sinks")
        XCTAssertLessThan(compareShareSlot(late, unscheduled), 0)
        // The instant wins over the owner's text when both are present.
        let ownerLate = Row(id: "ol", done: false, nextDate: TODAY, nextStartTime: "23:00",
                            nextStartAt: "2026-05-21T06:00:00+00:00")
        XCTAssertLessThan(compareShareSlot(ownerLate, early, timeZone: london), 0, "07:00 London < 09:00")
    }

    func testAreaFilterAppliesToTheList() {
        let rows = [Row(id: "w", done: false, lifeArea: "Work"), Row(id: "h", done: false, lifeArea: "Home"),
                    Row(id: "n", done: false)]
        XCTAssertEqual(visibleShares(rows, mode: .today, now: NOW, todayISO: TODAY, activeArea: "Home").map(\.id), ["h", "n"])
        XCTAssertEqual(visibleShares(rows, mode: .today, now: NOW, todayISO: TODAY, activeArea: UNASSIGNED_AREA).map(\.id), ["n"])
        XCTAssertEqual(visibleShares(rows, mode: .today, now: NOW, todayISO: TODAY).map(\.id), ["w", "h", "n"])
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
        // Chronological in All: today's 10:00 before Saturday's 04:30.
        XCTAssertEqual(visibleShares([future, today], mode: .all, now: NOW, todayISO: TODAY).map(\.taskId), ["t2", "t1"])
        // The 053 fields ride through the protocol (instant + later).
        let zoned = SharedWithMe(shareId: "s3", taskId: "t3", ownerName: "Anna", level: .view, title: "Zoned", done: false,
                                 nextBlockId: "b3", nextDate: "2026-05-22", nextStartTime: "00:30",
                                 nextDurationMinutes: 30, nextDone: false,
                                 nextStartAt: "2026-05-21T15:30:00+00:00", later: false)
        XCTAssertEqual(zoned.nextStartAt, "2026-05-21T15:30:00+00:00")
        XCTAssertEqual(shareBucket(zoned, todayISO: TODAY, timeZone: london), .today)
        let parked = SharedWithMe(shareId: "s4", taskId: "t4", ownerName: "Anna", level: .view, title: "Parked", done: false,
                                  later: true)
        XCTAssertEqual(shareBucket(parked, todayISO: TODAY), .parked)
        XCTAssertEqual(sharedSlotLabel(nextDate: future.nextDate, nextStartTime: future.nextStartTime,
                                       nextDurationMinutes: future.nextDurationMinutes, nextDone: future.nextDone,
                                       todayISO: TODAY), "Sat 04:30 · 45m")
    }
}
