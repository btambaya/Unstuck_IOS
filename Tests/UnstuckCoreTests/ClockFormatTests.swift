// ClockFormat — the one formatter every user-visible clock time goes through
// (Ahmad, 2026-09-24: "either 12 hour or 24h, not both"). Both modes pinned.

import XCTest
@testable import UnstuckCore

final class ClockFormatTests: XCTestCase {

    // MARK: 24-hour

    func testTimeIn24Hour() {
        let c = ClockFormat.h24
        XCTAssertEqual(c.time(hour: 14, minute: 30), "14:30")
        XCTAssertEqual(c.time(hour: 9, minute: 5), "09:05")
        XCTAssertEqual(c.time(hour: 0, minute: 0), "00:00")
        XCTAssertEqual(c.time(hour: 23, minute: 59), "23:59")
        XCTAssertEqual(c.time("14:30"), "14:30")
        XCTAssertEqual(c.time("9:05"), "09:05")
        XCTAssertEqual(c.time(minutes: 24 * 60), "00:00", "midnight wraps")
        XCTAssertEqual(c.time(minutes: -30), "23:30")
    }

    func testWholeHoursIn24HourNeverDropTheMinutes() {
        let c = ClockFormat.h24
        XCTAssertEqual(c.hourLabel(14), "14:00", "never a bare '14'")
        XCTAssertEqual(c.hourLabel(0), "00:00")
        XCTAssertEqual(c.hourLabel(9), "09:00")
        XCTAssertEqual(c.shortTime(minutes: 14 * 60), "14:00")
        XCTAssertEqual(c.shortTime("14:30"), "14:30")
    }

    func testRangesIn24Hour() {
        let c = ClockFormat.h24
        XCTAssertEqual(c.range(startMinutes: 14 * 60, endMinutes: 15 * 60 + 30), "14:00–15:30")
        XCTAssertEqual(c.range("06:00", "23:00"), "06:00–23:00")
        XCTAssertEqual(c.range(start: "23:00", durationMinutes: 90), "23:00–00:30")
        XCTAssertEqual(c.hourSpan(14), "14:00–15:00")
        XCTAssertEqual(c.hourSpan(23), "23:00–00:00")
    }

    // MARK: 12-hour

    func testTimeIn12Hour() {
        let c = ClockFormat.h12
        XCTAssertEqual(c.time(hour: 14, minute: 30), "2:30 PM")
        XCTAssertEqual(c.time(hour: 9, minute: 5), "9:05 AM")
        XCTAssertEqual(c.time(hour: 0, minute: 15), "12:15 AM")
        XCTAssertEqual(c.time(hour: 12, minute: 0), "12:00 PM")
        XCTAssertEqual(c.time(hour: 0, minute: 0), "12:00 AM", "midnight")
        XCTAssertEqual(c.time(hour: 11, minute: 59), "11:59 AM")
        XCTAssertEqual(c.time(hour: 12, minute: 1), "12:01 PM", "just past noon")
        XCTAssertEqual(c.time("23:59"), "11:59 PM")
        XCTAssertEqual(c.time("24:00"), "12:00 AM", "24:00 is the next midnight")
        XCTAssertEqual(ClockFormat.h24.time(hour: 12, minute: 0), "12:00")
    }

    func testWholeHoursIn12HourAreShort() {
        let c = ClockFormat.h12
        XCTAssertEqual(c.hourLabel(14), "2 PM")
        XCTAssertEqual(c.hourLabel(0), "12 AM")
        XCTAssertEqual(c.hourLabel(12), "12 PM")
        XCTAssertEqual(c.shortTime(minutes: 14 * 60), "2 PM")
        XCTAssertEqual(c.shortTime(minutes: 14 * 60 + 30), "2:30 PM")
    }

    func testRangesIn12HourShareTheMarkerWhenTheyCan() {
        let c = ClockFormat.h12
        XCTAssertEqual(c.range(startMinutes: 14 * 60, endMinutes: 15 * 60 + 30), "2:00–3:30 PM")
        XCTAssertEqual(c.range(startMinutes: 11 * 60 + 30, endMinutes: 12 * 60 + 30), "11:30 AM–12:30 PM")
        XCTAssertEqual(c.range("22:00", "02:00"), "10:00 PM–2:00 AM")
        XCTAssertEqual(c.range(start: "23:00", durationMinutes: 90), "11:00 PM–12:30 AM")
        // An overnight span that ends in the SAME half-day keeps both markers —
        // "1:00–12:30 AM" / "8:00–7:00 PM" would read as a short range.
        XCTAssertEqual(c.range("01:00", "00:30"), "1:00 AM–12:30 AM")
        XCTAssertEqual(c.range("20:00", "19:00"), "8:00 PM–7:00 PM")
        XCTAssertEqual(c.range(startMinutes: 9 * 60, endMinutes: 9 * 60 + 24 * 60 + 30), "9:00 AM–9:30 AM")
        XCTAssertEqual(c.hourSpan(10), "10–11 AM")
        XCTAssertEqual(c.hourSpan(11), "11 AM–12 PM")
        XCTAssertEqual(c.hourSpan(0), "12–1 AM")
        XCTAssertEqual(c.hourSpan(23), "11 PM–12 AM")
    }

    func testTheLocalesMarkersAreUsed() {
        let gb = ClockFormat(cycle: .h12, amSymbol: "am", pmSymbol: "pm")
        XCTAssertEqual(gb.time("14:30"), "2:30 pm")
        XCTAssertEqual(gb.hourLabel(9), "9 am")
    }

    // MARK: input that isn't a clock time

    func testNonTimesComeBackAsGiven() {
        for c in [ClockFormat.h12, .h24] {
            XCTAssertEqual(c.time(""), "")
            XCTAssertEqual(c.time("anytime"), "anytime")
            XCTAssertEqual(c.time("25:00"), "25:00")
            XCTAssertEqual(c.time("14:3"), "14:3")
            XCTAssertEqual(c.time("7:30pm"), "7:30pm")
            XCTAssertEqual(c.range(start: "junk", durationMinutes: 30), "junk")
        }
        XCTAssertEqual(ClockFormat.h12.time("14:30:00"), "2:30 PM", "seconds are tolerated")
    }

    // MARK: detection

    func testHourPatternDetection() {
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "h a"), .h12)       // en_US
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "a h시"), .h12)     // ko_KR
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "B h"), .h12)       // hi_IN (flexible day period)
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "HH"), .h24)        // en_GB, en_NG, en_US@hours=h23
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "H時"), .h24)       // ja_JP
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "HH 'Uhr'"), .h24)  // de_DE — literal ignored
        XCTAssertEqual(ClockFormat.cycle(forHourPattern: "HH 'h'"), .h24)    // fr_CA — a quoted 'h' is not the hour
    }

    func testLocaleDetectionHonoursTheTwentyFourHourOverride() {
        XCTAssertEqual(ClockFormat.forLocale(Locale(identifier: "en_US")).cycle, .h12)
        XCTAssertEqual(ClockFormat.forLocale(Locale(identifier: "en_GB")).cycle, .h24)
        // Settings › 24-Hour Time rides in the locale as the hours keyword.
        XCTAssertEqual(ClockFormat.forLocale(Locale(identifier: "en_US@hours=h23")).cycle, .h24)
        XCTAssertEqual(ClockFormat.forLocale(Locale(identifier: "en_GB@hours=h12")).cycle, .h12)
        let us = ClockFormat.forLocale(Locale(identifier: "en_US"))
        XCTAssertEqual(us.time("14:30"), "2:30 PM")
        XCTAssertEqual(ClockFormat.forLocale(Locale(identifier: "en_US@hours=h23")).time("14:30"), "14:30")
    }

    func testDeviceIsTheCurrentLocalesClockAndRefreshes() {
        XCTAssertEqual(ClockFormat.device, ClockFormat.forLocale(Locale.current))
        ClockFormat.refreshDevice()
        XCTAssertEqual(ClockFormat.device, ClockFormat.forLocale(Locale.current))
    }

    func testDateInTheGivenZone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let d = ISO8601DateFormatter().date(from: "2026-05-21T15:30:00Z")!   // 16:30 BST
        XCTAssertEqual(ClockFormat.h24.time(d, calendar: cal), "16:30")
        XCTAssertEqual(ClockFormat.h12.time(d, calendar: cal), "4:30 PM")
    }
}
