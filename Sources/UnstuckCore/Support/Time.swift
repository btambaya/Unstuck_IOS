// Time helpers that reproduce the exact semantics the web logic relies
// on. The web stores timestamps as ISO strings and does date math with
// JS `Date` in the device's LOCAL timezone (Calendar.current /
// TimeZone.current here), and compares ISO strings lexicographically.
// Keeping the same conventions means the ported logic + tests behave
// identically to lib/*.test.ts.

import Foundation

/// Epoch milliseconds — matches the JS `number` returned by
/// `Date.now()` / `Date.parse()`. Used wherever the web passes `now`.
public typealias EpochMillis = Double

public let DAY_MS: Double = 24 * 60 * 60 * 1000

public enum Time {
    /// Parse an ISO-8601 timestamp to epoch milliseconds, or `nil` if it
    /// can't be parsed — mirrors `Date.parse` returning `NaN`. Accepts
    /// both fractional-second and whole-second forms.
    public static func parseMillis(_ iso: String) -> EpochMillis? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: iso) {
            return d.timeIntervalSince1970 * 1000
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: iso) {
            return d.timeIntervalSince1970 * 1000
        }
        return nil
    }

    /// Local-midnight (start-of-day) epoch ms for the day containing
    /// `now`. Equivalent to `new Date(now).setHours(0,0,0,0)`.
    public static func startOfDayMillis(_ now: EpochMillis) -> EpochMillis {
        let date = Date(timeIntervalSince1970: now / 1000)
        let start = Calendar.current.startOfDay(for: date)
        return start.timeIntervalSince1970 * 1000
    }
}

/// Wall-clock access, isolated so it's easy to see where real time is
/// read. The web's `todayDateIso()` reads the real clock with no
/// injection; we match that (callers that need determinism pass `now`
/// explicitly, exactly as the web tests do).
public enum Clock {
    /// Today's local date as `YYYY-MM-DD`. Mirrors `todayDateIso()`
    /// (lib/dnd-task.ts): local getFullYear/getMonth+1/getDate.
    public static func todayISO() -> String {
        dateISO(Date())
    }

    /// `YYYY-MM-DD` for a specific `Date`, in the local calendar.
    public static func dateISO(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYY-MM-DD` for the day containing `now` (epoch ms), local.
    public static func dateISO(millis now: EpochMillis) -> String {
        dateISO(Date(timeIntervalSince1970: now / 1000))
    }
}
