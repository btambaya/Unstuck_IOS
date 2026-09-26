// The calendar's NOW marker: which minute, which week column. Every case
// pins its own time zone, so the suite means the same thing on any machine
// (the package suite runs under TZ=UTC; the phone runs in the user's zone).

import XCTest
@testable import UnstuckCore

final class CalendarNowLineTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.firstWeekday = 2
        return c
    }

    /// An absolute instant from a UTC wall-clock time.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
        cal("UTC").date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    /// Monday-anchored week of local midnights in `c` (how WeekView builds its columns).
    private func week(from monday: DateComponents, in c: Calendar) -> [Date] {
        let start = c.date(from: monday)!
        return (0..<7).map { c.date(byAdding: .day, value: $0, to: start)! }
    }

    // MARK: minutes into the grid

    func testWallClockMinutesInTheCalendarsOwnZone() {
        let instant = utc(2026, 9, 26, 13, 42)
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: instant, firstHour: 0, lastHour: 24, calendar: cal("UTC")), 13 * 60 + 42)
        // +5:30 — a half-hour zone.
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: instant, firstHour: 0, lastHour: 24, calendar: cal("Asia/Kolkata")), 19 * 60 + 12)
        // −2:30 (Newfoundland daylight time in September).
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: instant, firstHour: 0, lastHour: 24, calendar: cal("America/St_Johns")), 11 * 60 + 12)
        // +14 — already tomorrow there: 03:42.
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: instant, firstHour: 0, lastHour: 24, calendar: cal("Pacific/Kiritimati")), 3 * 60 + 42)
        // +1 (London summer time) — Ahmad's zone.
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: instant, firstHour: 0, lastHour: 24, calendar: cal("Europe/London")), 14 * 60 + 42)
    }

    func testAcrossADaylightSavingChangeItFollowsTheWallClock() {
        // New York, 1 Nov 2026: clocks go back 02:00 → 01:00. 06:30 UTC is
        // the SECOND 01:30 — the blocks are laid out by "HH:mm", so the line
        // belongs at 01:30 as well.
        let ny = cal("America/New_York")
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 11, 1, 6, 30), firstHour: 0, lastHour: 24, calendar: ny), 90)
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 11, 1, 5, 30), firstHour: 0, lastHour: 24, calendar: ny), 90)
        // Spring forward, 8 Mar 2026: 07:05 UTC = 03:05 EDT (02:xx never happens).
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 3, 8, 7, 5), firstHour: 0, lastHour: 24, calendar: ny), 3 * 60 + 5)
    }

    func testMidnightAndTheLastMinuteBothLandOnTheFullDayGrid() {
        let c = cal("UTC")
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 0, 0), firstHour: 0, lastHour: 24, calendar: c), 0)
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 23, 59), firstHour: 0, lastHour: 24, calendar: c), 1439)
    }

    func testOutsideAShorterGridThereIsNoLine() {
        let c = cal("UTC")
        XCTAssertNil(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 5, 59), firstHour: 6, lastHour: 22, calendar: c))
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 6, 0), firstHour: 6, lastHour: 22, calendar: c), 0)
        XCTAssertEqual(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 22, 0), firstHour: 6, lastHour: 22, calendar: c), 16 * 60)
        XCTAssertNil(CalendarNowLine.minutesIntoGrid(now: utc(2026, 9, 26, 22, 1), firstHour: 6, lastHour: 22, calendar: c))
    }

    func testYIsMinutesScaledToTheHourHeight() {
        XCTAssertEqual(CalendarNowLine.y(minutes: 0, pointsPerHour: 44), 0)
        XCTAssertEqual(CalendarNowLine.y(minutes: 90, pointsPerHour: 44), 66, accuracy: 1e-9)   // Week grid
        XCTAssertEqual(CalendarNowLine.y(minutes: 13 * 60 + 42, pointsPerHour: 56), 767.2, accuracy: 1e-9)   // Day grid
    }

    // MARK: which week column

    func testTodaysColumnIsTheLocalDay() {
        // Mon 21 – Sun 27 Sep 2026; 13:42 UTC on Saturday the 26th.
        let instant = utc(2026, 9, 26, 13, 42)
        let london = cal("Europe/London")
        XCTAssertEqual(CalendarNowLine.todayColumn(days: week(from: DateComponents(year: 2026, month: 9, day: 21), in: london),
                                                   now: instant, calendar: london), 5)
        // +14: it is already Sunday there → the last column.
        let kiri = cal("Pacific/Kiritimati")
        XCTAssertEqual(CalendarNowLine.todayColumn(days: week(from: DateComponents(year: 2026, month: 9, day: 21), in: kiri),
                                                   now: instant, calendar: kiri), 6)
        // −11: still Saturday, early morning.
        let pago = cal("Pacific/Pago_Pago")
        XCTAssertEqual(CalendarNowLine.todayColumn(days: week(from: DateComponents(year: 2026, month: 9, day: 21), in: pago),
                                                   now: utc(2026, 9, 26, 13, 42), calendar: pago), 5)
        // Monday 00:00 local is the first column, Sunday 23:59 the last.
        let utcCal = cal("UTC")
        let days = week(from: DateComponents(year: 2026, month: 9, day: 21), in: utcCal)
        XCTAssertEqual(CalendarNowLine.todayColumn(days: days, now: utc(2026, 9, 21, 0, 0), calendar: utcCal), 0)
        XCTAssertEqual(CalendarNowLine.todayColumn(days: days, now: utc(2026, 9, 27, 23, 59), calendar: utcCal), 6)
    }

    func testAnotherWeekHasNoTodayColumn() {
        let c = cal("Europe/London")
        let nextWeek = week(from: DateComponents(year: 2026, month: 9, day: 28), in: c)
        XCTAssertNil(CalendarNowLine.todayColumn(days: nextWeek, now: utc(2026, 9, 26, 13, 42), calendar: c))
        let lastWeek = week(from: DateComponents(year: 2026, month: 9, day: 14), in: c)
        XCTAssertNil(CalendarNowLine.todayColumn(days: lastWeek, now: utc(2026, 9, 26, 13, 42), calendar: c))
        // Sunday 23:59 → Monday 00:00 moves today out of this week.
        let thisWeek = week(from: DateComponents(year: 2026, month: 9, day: 21), in: c)
        XCTAssertEqual(CalendarNowLine.todayColumn(days: thisWeek, now: utc(2026, 9, 27, 22, 59), calendar: c), 6)   // 23:59 BST
        XCTAssertNil(CalendarNowLine.todayColumn(days: thisWeek, now: utc(2026, 9, 27, 23, 0), calendar: c))         // 00:00 BST Mon
    }

    func testAWeekThatCrossesADaylightSavingChangeStillFindsEachDay() {
        // London falls back on Sun 25 Oct 2026 (a 25-hour day).
        let c = cal("Europe/London")
        let days = week(from: DateComponents(year: 2026, month: 10, day: 19), in: c)
        XCTAssertEqual(CalendarNowLine.todayColumn(days: days, now: utc(2026, 10, 25, 23, 30), calendar: c), 6)   // 23:30 GMT Sun
        XCTAssertEqual(CalendarNowLine.todayColumn(days: days, now: utc(2026, 10, 25, 0, 30), calendar: c), 6)    // 01:30 BST Sun
        XCTAssertEqual(CalendarNowLine.todayColumn(days: days, now: utc(2026, 10, 24, 22, 30), calendar: c), 5)   // 23:30 BST Sat
    }

    // MARK: column geometry

    func testColumnsSplitTheGridAfterTheGutter() {
        // 357 pt grid (a 393 pt phone less 2 × 18), 26 pt gutter, 7 days.
        let w = CalendarNowLine.columnWidth(totalWidth: 357, gutter: 26, columns: 7)
        XCTAssertEqual(w, 331.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(CalendarNowLine.columnLeading(index: 0, totalWidth: 357, gutter: 26, columns: 7), 26, accuracy: 1e-9)
        XCTAssertEqual(CalendarNowLine.columnLeading(index: 5, totalWidth: 357, gutter: 26, columns: 7), 26 + 5 * w, accuracy: 1e-9)
        // The last column ends at the grid's trailing edge.
        XCTAssertEqual(CalendarNowLine.columnLeading(index: 6, totalWidth: 357, gutter: 26, columns: 7) + w, 357, accuracy: 1e-9)
    }

    func testDegenerateGeometryNeverGoesNegative() {
        XCTAssertEqual(CalendarNowLine.columnWidth(totalWidth: 10, gutter: 26, columns: 7), 0)
        XCTAssertEqual(CalendarNowLine.columnWidth(totalWidth: 357, gutter: 26, columns: 0), 0)
    }
}
