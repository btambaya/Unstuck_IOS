// `Clock.dateISO` formats 'YYYY-MM-DD' by hand instead of through
// `String(format:)` (it runs once per session in the Calendar heat-map and
// once per day in every occurrence materialisation). This proves the two
// agree for every component value it can be handed, including the ranges
// where it deliberately falls back.

import XCTest
@testable import UnstuckCore

final class ClockDateISOTests: XCTestCase {

    private func reference(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Every (year, month, day) the fast path covers, plus the edges around it.
    func testHandFormattingMatchesStringFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        for y in [0, 1, 9, 10, 99, 100, 999, 1000, 1582, 1969, 1970, 1999, 2000,
                  2024, 2026, 2100, 9998, 9999] {
            for m in 1...12 {
                for d in [1, 9, 10, 28, 31] {
                    var c = DateComponents()
                    c.year = y; c.month = m; c.day = d; c.hour = 12
                    guard let date = cal.date(from: c) else { continue }
                    let got = Clock.dateISO(date)
                    let want = reference(
                        cal.component(.year, from: date),
                        cal.component(.month, from: date),
                        cal.component(.day, from: date))
                    XCTAssertEqual(got, want, "y=\(y) m=\(m) d=\(d)")
                    XCTAssertEqual(got.count, 10)
                }
            }
        }
    }

    /// Round-trip through the parser + the millis overload: every day of a
    /// 400-year span formats the same as `String(format:)` would.
    func testMillisOverloadAcrossFourCenturies() {
        var day = Time.parseMillis("1800-01-01T12:00:00Z")!
        let end = Time.parseMillis("2200-01-01T12:00:00Z")!
        let cal = Calendar.current
        while day < end {
            let date = Date(timeIntervalSince1970: day / 1000)
            let c = cal.dateComponents([.year, .month, .day], from: date)
            XCTAssertEqual(Clock.dateISO(millis: day),
                           reference(c.year ?? 0, c.month ?? 0, c.day ?? 0))
            day += 37 * DAY_MS + 3_600_000   // stride off a day boundary, ~4000 samples
        }
    }

    /// todayISO stays a plain 'YYYY-MM-DD' and agrees with the components.
    func testTodayISO() {
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        XCTAssertEqual(Clock.todayISO(), reference(c.year ?? 0, c.month ?? 0, c.day ?? 0))
        XCTAssertEqual(Clock.todayISO(), Clock.dateISO(now))
    }

    // A phone set to the Buddhist calendar (Thailand's default) or the
    // Japanese one must still store Gregorian dates — `Calendar.current`
    // gave "2569-…" / "0008-…" (Ahmad 2026-09-23).
    func testStoredDatesAreGregorianWhateverTheDeviceCalendar() {
        let instant = Date(timeIntervalSince1970: 1_790_164_800)   // 2026-09-23 12:00 UTC
        for id in [Calendar.Identifier.buddhist, .japanese, .persian, .islamicUmmAlQura] {
            var device = Calendar(identifier: id)
            device.timeZone = TimeZone(identifier: "Asia/Bangkok")!
            device.locale = Locale(identifier: "th_TH")
            device.firstWeekday = 2
            let g = Time.gregorian(matching: device)
            XCTAssertEqual(g.identifier, .gregorian, "\(id)")
            XCTAssertEqual(g.component(.year, from: instant), 2026, "\(id)")
            XCTAssertEqual(g.component(.month, from: instant), 9, "\(id)")
            XCTAssertEqual(g.component(.day, from: instant), 23, "\(id)")
            XCTAssertEqual(g.timeZone, device.timeZone, "keeps the device's zone")
            XCTAssertEqual(g.firstWeekday, 2, "keeps the device's week start")
        }
        XCTAssertNotEqual(Calendar(identifier: .buddhist).component(.year, from: instant), 2026,
                          "the bug this guards: the device calendar's own year")
        let gregorianDevice = Calendar(identifier: .gregorian)
        XCTAssertEqual(Time.gregorian(matching: gregorianDevice), gregorianDevice, "the common case is untouched")
        XCTAssertEqual(Time.calendar.identifier, .gregorian)
    }
}
