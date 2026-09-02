// Ported from lib/assistant/time-guard.test.ts (the time half) plus the
// `upcoming` semantics of buildAssistantContext / rejectPastDate in tools.ts.
// Times are LOCAL; the suite runs under TZ=UTC so local == UTC.

import XCTest
@testable import UnstuckCore

private let TODAY = "2026-09-02"   // a Wednesday

/// Local wall-clock `Date` — the web's `new Date(2026, 8, 2, 15, 7)`.
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Time.civil(y, m, d))!
}

/// The web `api(blocks)` helper: every block defaults to today 10:00 × 30 min.
private func blocks(_ overrides: [(startTime: String, durationMinutes: Int, date: String, done: Bool)]) -> [CalBlock] {
    overrides.enumerated().map { i, b in
        CalBlock(id: "b\(i)", taskId: "t\(i)", taskName: "x", startTime: b.startTime,
                 durationMinutes: b.durationMinutes, date: b.date, done: b.done)
    }
}
private func b(_ startTime: String = "10:00", durationMinutes: Int = 30, date: String = TODAY, done: Bool = false)
    -> (startTime: String, durationMinutes: Int, date: String, done: Bool) {
    (startTime, durationMinutes, date, done)
}

final class AssistantTimeTests: XCTestCase {

    // MARK: time cognisance (tester: "it suggested 10am at 3pm", 2026-09-02)

    func testLocalNowHMIsLocalWallClockHHMM() {
        XCTAssertEqual(localNowHM(at(2026, 9, 2, 15, 7)), "15:07")
        XCTAssertEqual(localNowHM(at(2026, 9, 2, 9, 0)), "09:00")
    }

    func testFreeWindowsStartAtTheNextQuarterHourAfterNowAndSkipBlocks() {
        XCTAssertEqual(
            freeWindowsToday(blocks: blocks([b("16:00", durationMinutes: 60)]), today: TODAY, nowHM: "15:07"),
            [FreeWindow(from: "15:15", to: "16:00"), FreeWindow(from: "17:00", to: "21:00")])
    }

    func testIgnoresDoneSkippedOtherDayBlocksAndYieldsNothingLateAtNight() {
        XCTAssertEqual(
            freeWindowsToday(blocks: blocks([b("16:00", done: true), b("17:00", date: "2026-09-03")]), today: TODAY, nowHM: "15:07"),
            [FreeWindow(from: "15:15", to: "21:00")])
        XCTAssertEqual(freeWindowsToday(blocks: [], today: TODAY, nowHM: "20:50"), [])
    }

    func testAtMostFourWindowsAndOnlyGapsOfTwentyMinutesOrMore() {
        let busy = blocks([b("09:30"), b("10:30"), b("11:30"), b("12:30"), b("13:30"), b("14:10", durationMinutes: 10)])
        let w = freeWindowsToday(blocks: busy, today: TODAY, nowHM: "08:00")
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w.first, FreeWindow(from: "08:15", to: "09:30"))
        // 14:00–14:10 is only ten minutes — never offered.
        XCTAssertFalse(w.contains { $0.from == "14:00" })
    }

    func testRefusesATimeTodayThatHasAlreadyPassedWithWhatIsFree() {
        let err = rejectPastTime(blocks: blocks([b("16:00")]), today: TODAY, date: TODAY, startTime: "10:00", nowHM: "15:07")
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.hasPrefix("error: 10:00 today is already past (it's 15:07 now)"), err!)
        XCTAssertTrue(err!.contains("free today: 15:15–16:00, 16:30–21:00"), err!)
        XCTAssertEqual(err, "error: 10:00 today is already past (it's 15:07 now). Ask for a later time or another day — free today: 15:15–16:00, 16:30–21:00.")
    }

    func testAllowsALaterTimeTodayAnyTimeAnotherDayAndNoTimeAtAll() {
        XCTAssertNil(rejectPastTime(blocks: [], today: TODAY, date: TODAY, startTime: "15:30", nowHM: "15:07"))
        XCTAssertNil(rejectPastTime(blocks: [], today: TODAY, date: "2026-09-03", startTime: "10:00", nowHM: "15:07"))
        XCTAssertNil(rejectPastTime(blocks: [], today: TODAY, date: TODAY, startTime: nil, nowHM: "15:07"))
        XCTAssertNil(rejectPastTime(blocks: [], today: TODAY, date: TODAY, startTime: "", nowHM: "15:07"))
    }

    func testExactlyNowCountsAsPast() {
        XCTAssertNotNil(rejectPastTime(blocks: [], today: TODAY, date: TODAY, startTime: "15:07", nowHM: "15:07"))
    }

    func testSaysNothingIsLeftWhenTheEveningIsGone() {
        let err = rejectPastTime(blocks: [], today: TODAY, date: TODAY, startTime: "20:00", nowHM: "20:50")
        XCTAssertTrue(err?.contains("nothing usable is left today") ?? false)
        XCTAssertEqual(err, "error: 20:00 today is already past (it's 20:50 now). Ask for a later time or another day — nothing usable is left today — offer tomorrow.")
    }

    // MARK: past dates ("Monday" → last Monday, 2026-09-02)

    func testRejectPastDateNamesTheComingWeekdayVerbatim() {
        // Mon 31 Aug from Wed 2 Sept → next Monday is 7 Sept.
        XCTAssertEqual(
            rejectPastDate(today: TODAY, date: "2026-08-31"),
            "error: 2026-08-31 is in the PAST (today is 2026-09-02). If the user meant the coming Monday, use 2026-09-07 — see context.upcoming. Never schedule into the past.")
        // Same weekday last week → a full week ahead, never "today".
        XCTAssertEqual(
            rejectPastDate(today: TODAY, date: "2026-08-26"),
            "error: 2026-08-26 is in the PAST (today is 2026-09-02). If the user meant the coming Wednesday, use 2026-09-09 — see context.upcoming. Never schedule into the past.")
    }

    func testRejectPastDateAllowsTodayAndTheFutureAndRefusesBadShapes() {
        XCTAssertNil(rejectPastDate(today: TODAY, date: TODAY))
        XCTAssertNil(rejectPastDate(today: TODAY, date: "2026-12-25"))
        XCTAssertEqual(rejectPastDate(today: TODAY, date: "Monday"), "error: date must be YYYY-MM-DD (got \"Monday\")")
        XCTAssertEqual(rejectPastDate(today: TODAY, date: "2026-9-2"), "error: date must be YYYY-MM-DD (got \"2026-9-2\")")
    }

    // MARK: upcoming — the dates the model must COPY

    func testUpcomingDatesFromAWednesday() {
        let u = upcomingDates(today: TODAY)
        XCTAssertEqual(u["tomorrow"], "2026-09-03")
        XCTAssertEqual(u["thursday"], "2026-09-03")
        XCTAssertEqual(u["friday"], "2026-09-04")
        XCTAssertEqual(u["saturday"], "2026-09-05")
        XCTAssertEqual(u["sunday"], "2026-09-06")
        XCTAssertEqual(u["monday"], "2026-09-07")
        XCTAssertEqual(u["tuesday"], "2026-09-08")
        // Today's own weekday resolves to NEXT week, never today.
        XCTAssertEqual(u["wednesday"], "2026-09-09")
        XCTAssertEqual(u["next_week_monday"], "2026-09-07")
        XCTAssertEqual(u.count, 9)
    }

    func testUpcomingFromASundayRollsNextWeekMondayCorrectly() {
        let u = upcomingDates(today: "2026-09-06")
        XCTAssertEqual(u["monday"], "2026-09-07")
        XCTAssertEqual(u["next_week_monday"], "2026-09-07")   // Sunday's week started Mon 31 Aug
        XCTAssertEqual(u["sunday"], "2026-09-13")
    }

    func testWeekdayNameAndNowNote() {
        XCTAssertEqual(weekdayName(today: TODAY), "wednesday")
        XCTAssertEqual(weekdayName(today: "2026-09-06"), "sunday")
        XCTAssertEqual(nowNote(today: TODAY, nowHM: "15:07"),
                       "it is 15:07 on wednesday — times earlier than this today are already gone")
    }

    // MARK: LocalDate plumbing

    func testLocalDateHelpersNeverDriftThroughUTC() {
        XCTAssertEqual(LocalDate.addDays("2026-08-31", 1), "2026-09-01")
        XCTAssertEqual(LocalDate.addDays("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(LocalDate.mondayOf("2026-09-06"), "2026-08-31")   // Sunday → its Monday
        XCTAssertEqual(LocalDate.mondayOf("2026-08-31"), "2026-08-31")
        XCTAssertEqual(LocalDate.dayOfWeek("2026-09-02"), 3)
        XCTAssertEqual(LocalDate.daysUntil("2026-08-24", "2026-08-29"), 5)
        XCTAssertEqual(LocalDate.dateOfStamp("2026-08-23T18:00:00"), "2026-08-23")
        XCTAssertEqual(LocalDate.dateOfStamp("2026-08-23T18:00:00.000Z"), "2026-08-23")
        XCTAssertNil(LocalDate.dateOfStamp("nope"))
        XCTAssertNil(LocalDate.dateOfStamp(nil))
    }
}
