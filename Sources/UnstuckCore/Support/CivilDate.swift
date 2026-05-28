// Local civil-date helpers reproducing the JS `Date` arithmetic the
// recurrence + free-slot logic relies on: `new Date(y, monthIndex, day)`
// (local midnight, overflow-normalized), `getDay()` (0=Sun…6=Sat),
// `getDate()`, and whole-day differences. All in the device's local
// calendar/timezone, exactly like the web.

import Foundation

public extension Time {
    /// Local midnight `Date` for civil (year, month, day). `month` is
    /// 1-based. Day overflow normalizes (day 32 → next month), matching
    /// `new Date(y, m-1, d)`.
    static func civil(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    /// `Date` advanced by `n` whole days, preserving wall-clock time
    /// (DST-safe), matching `new Date(y, m, d+n)`.
    static func addDays(_ d: Date, _ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: d) ?? d
    }

    /// Local start-of-day. Equivalent to flooring a JS Date to midnight.
    static func startOfDay(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }

    /// Day-of-week in JS convention: 0=Sun … 6=Sat (Calendar gives 1…7).
    static func dayOfWeekJS(_ d: Date) -> Int {
        Calendar.current.component(.weekday, from: d) - 1
    }

    /// Day-of-month (1…31), matching `Date.getDate()`.
    static func dayOfMonth(_ d: Date) -> Int {
        Calendar.current.component(.day, from: d)
    }

    /// Whole-day difference `floor(a) - floor(b)` rounded — matches the
    /// web's `Math.round((midnightA - midnightB)/oneDay)`.
    static func wholeDaysBetween(_ a: Date, _ b: Date) -> Int {
        let secs = startOfDay(a).timeIntervalSince(startOfDay(b))
        return Int((secs / 86_400).rounded())
    }
}
