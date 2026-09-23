// Inputs the server refuses (audit 2026-09-22, C28). Each one was accepted on
// the phone, refused on every flush and quarantined — the change lived on this
// phone only while the assistant or the UI said it was saved. These are the
// checks that now stop them before anything is written.

import XCTest
@testable import UnstuckCore

final class ServerAcceptedInputTests: XCTestCase {

    // MARK: - dates that don't exist

    func testImpossibleDatesAreNotCalendarDates() {
        XCTAssertTrue(isCalendarDate("2026-09-30"))
        XCTAssertTrue(isCalendarDate("2028-02-29"), "a leap day in a leap year")
        XCTAssertFalse(isCalendarDate("2026-09-31"))
        XCTAssertFalse(isCalendarDate("2027-02-29"))
        XCTAssertFalse(isCalendarDate("2026-13-01"))
        XCTAssertFalse(isCalendarDate("2026-09-00"))
        XCTAssertFalse(isCalendarDate("2026-9-30"))
    }

    /// "Move the report to the 31st" in September: the date passed the
    /// pattern, overwrote the block's date, and the push was refused.
    func testSchedulingOntoAnImpossibleDateIsRefusedWithTheMonthsLength() throws {
        let e = try XCTUnwrap(rejectPastDate(today: "2026-09-22", date: "2026-09-31"))
        XCTAssertTrue(e.hasPrefix("error: 2026-09-31 is not a real date"), e)
        XCTAssertTrue(e.contains("30 days"), e)
        XCTAssertNil(rejectPastDate(today: "2026-09-22", date: "2026-09-30"))
    }

    /// `when_iso` is a Postgres `date`: a Feb-29 fact in a non-leap year never
    /// synced. It is kept without the date instead.
    func testAFactsDateMustExist() {
        XCTAssertNil(ProfileFactsLogic.validWhenIso("2027-02-29"))
        XCTAssertEqual(ProfileFactsLogic.validWhenIso("2028-02-29"), "2028-02-29")
    }

    // MARK: - start times

    /// `cal_blocks_start_time_format` is `^([01][0-9]|2[0-3]):[0-5][0-9]$`.
    func testStartTimesAreNormalisedToTheServersHHMM() {
        XCTAssertEqual(normalizeClockTime("9:00"), "09:00")
        XCTAssertEqual(normalizeClockTime("09:05"), "09:05")
        XCTAssertEqual(normalizeClockTime("23:59"), "23:59")
        XCTAssertEqual(normalizeClockTime(" 7:30 "), "07:30")
        XCTAssertNil(normalizeClockTime("7:30pm"))
        XCTAssertNil(normalizeClockTime("0930"))
        XCTAssertNil(normalizeClockTime("24:00"))
        XCTAssertNil(normalizeClockTime("9:5"))
        XCTAssertNil(normalizeClockTime("٩:٠٠"), "only ASCII digits reach the server's pattern")
        XCTAssertNil(rejectBadStartTime(nil))
        XCTAssertNil(rejectBadStartTime("9:00"))
        XCTAssertNotNil(rejectBadStartTime("7:30pm"))
    }

    // MARK: - deadlines

    /// `tasks.due_at` is timestamptz: free text failed the whole row, and a
    /// zone-less stamp was read as UTC — the deadline moved by the user's
    /// offset after the echo.
    func testDeadlinesBecomeInstantsTheServerAccepts() throws {
        XCTAssertNil(normalizeDueAt("Friday 5pm"))
        XCTAssertNil(normalizeDueAt("2026-09-31T10:00:00Z"), "an impossible day is refused, not rolled over")
        XCTAssertNotNil(rejectBadDueAt("tomorrow"))
        XCTAssertNil(rejectBadDueAt(nil))

        XCTAssertEqual(normalizeDueAt("2026-09-25T17:00:00+01:00"), "2026-09-25T17:00:00+01:00",
                       "an instant with its zone travels as sent")

        // Zone-less: the user's local wall clock, like the rest of the app.
        let local = try XCTUnwrap(normalizeDueAt("2026-09-25T17:00:00"))
        let expected = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 17)))
        XCTAssertEqual(Time.parseMillis(local), expected.timeIntervalSince1970 * 1000)
        XCTAssertTrue(local.hasSuffix("Z"), "stored as an explicit instant")
    }

    // MARK: - capture length

    /// `captures.body` allows 4096 characters — Unicode scalars, which is what
    /// Postgres counts — and the cut never splits a character.
    func testCaptureBodiesAreClampedToWholeCharactersWithinTheLimit() {
        XCTAssertEqual(clampCaptureBody("short"), "short")
        let long = String(repeating: "x", count: 5000)
        XCTAssertEqual(clampCaptureBody(long).unicodeScalars.count, maxCaptureBodyLength)
        // 🇳🇬 is two scalars: an odd start puts a flag across the limit.
        let flags = String(repeating: "x", count: 3) + String(repeating: "🇳🇬", count: 2100)
        let clamped = clampCaptureBody(flags)
        XCTAssertLessThanOrEqual(clamped.unicodeScalars.count, maxCaptureBodyLength)
        XCTAssertTrue(clamped.hasSuffix("🇳🇬"), "no half flag at the end")
    }
}
