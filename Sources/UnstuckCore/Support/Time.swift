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
    /// THE calendar every civil date the app stores, syncs or compares is
    /// computed in: Gregorian, in the device's time zone, locale and week
    /// start. `Calendar.current` follows the device's calendar SETTING, so on
    /// a phone set to the Buddhist calendar (Thailand's default) or the
    /// Japanese one `dateISO` wrote "2569-09-23" / "0008-09-23" — dates the
    /// server and the web and Android apps read as a different day, which
    /// broke scheduling, recurrence and reminders for those users (audit
    /// 2026-09-22, known deferred; Ahmad 2026-09-23). Display formatting is
    /// untouched: a DateFormatter still shows the user's own calendar.
    public static var calendar: Calendar { gregorian(matching: Calendar.current) }

    /// `base` itself when it is already Gregorian (the common case, no cost),
    /// else a Gregorian calendar carrying its time zone, locale and week rules.
    public static func gregorian(matching base: Calendar) -> Calendar {
        if base.identifier == .gregorian { return base }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = base.timeZone
        g.locale = base.locale
        g.firstWeekday = base.firstWeekday
        g.minimumDaysInFirstWeek = base.minimumDaysInFirstWeek
        return g
    }

    /// Shared ISO-8601 parsers, hoisted to `static let` so the hot path
    /// (realtime mirror / outbox prune / analytics / list rebuild) doesn't
    /// allocate two formatters on every `parseMillis` call. `ISO8601DateFormatter`
    /// is thread-safe for `date(from:)` (we only ever read with these — the
    /// `formatOptions` are set once here and never mutated), so a single shared
    /// instance is safe; `nonisolated(unsafe)` documents that to the compiler.
    nonisolated(unsafe) private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO-8601 timestamp to epoch milliseconds, or `nil` if it
    /// can't be parsed — mirrors `Date.parse` returning `NaN`. Accepts
    /// both fractional-second and whole-second forms.
    ///
    /// PERFORMANCE (heavy-account soak, 2026-09-12): this is the hottest pure
    /// function in the app — every task bucket (`isCreatedToday`), every focus
    /// heat-map cell and every `goldenHours` session goes through it, so an
    /// 800-task Today recompute called it 1,600 times and a 1,500-session
    /// `goldenHours` 1,500 times. `ISO8601DateFormatter.date(from:)` costs
    /// ~24 µs a call, which made those passes 20 ms and 37 ms of pure parsing.
    /// `fastParseMillis` below handles the canonical shape in ~0.03 µs; ANY
    /// deviation from that shape falls through to the two formatters, so the
    /// accepted-input set and every returned value are unchanged (proved
    /// byte-for-byte by `Tests/UnstuckCoreTests/TimeParseFastPathTests.swift`,
    /// which differential-tests the fast path against the formatters over
    /// every shape, rollover and rejection case).
    public static func parseMillis(_ iso: String) -> EpochMillis? {
        if let ms = fastParseMillis(iso) { return ms }
        if let d = isoWithFractional.date(from: iso) {
            return d.timeIntervalSince1970 * 1000
        }
        if let d = isoPlain.date(from: iso) {
            return d.timeIntervalSince1970 * 1000
        }
        return nil
    }

    /// Days since 1970-01-01 for a proleptic-Gregorian civil date (Howard
    /// Hinnant's `days_from_civil`). `d` is used linearly, so an out-of-range
    /// day rolls forward exactly the way `ISO8601DateFormatter` does
    /// (`2026-02-30` → 2026-03-02). `m` must be 1…12.
    @inline(__always)
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = y - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                       // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1      // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy               // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// Hand-rolled parse of the ONE shape the app actually stores — strict
    /// `YYYY-MM-DDTHH:MM:SS`, an optional `.` + fractional digits (truncated to
    /// milliseconds, like the formatter), then `Z`/`z` or `±HH:MM` / `±HHMM` /
    /// `±HH`. Returns nil for anything else (lower-case `t`, a 1-digit month,
    /// stray whitespace, a missing zone, an out-of-range field) so the caller
    /// falls back to `ISO8601DateFormatter` and the observable behaviour is
    /// identical. Field ranges mirror the formatter's own acceptance exactly:
    /// month 1…12, day 1…31, hour 0…24, minute/second 0…59 (hour 24 and an
    /// over-long day roll forward; hour 25, minute 60 and second 60 are
    /// rejected by both), zone offset 0…23 h / 0…59 min.
    @inline(__always)
    static func fastParseMillis(_ iso: String) -> EpochMillis? {
        var s = iso
        return s.withUTF8 { buf -> EpochMillis? in
            let n = buf.count
            guard n >= 20 else { return nil }
            func digit(_ i: Int) -> Int { Int(buf[i]) &- 48 }
            func isDigit(_ i: Int) -> Bool { buf[i] >= 48 && buf[i] <= 57 }
            guard isDigit(0), isDigit(1), isDigit(2), isDigit(3), buf[4] == UInt8(ascii: "-"),
                  isDigit(5), isDigit(6), buf[7] == UInt8(ascii: "-"),
                  isDigit(8), isDigit(9), buf[10] == UInt8(ascii: "T"),
                  isDigit(11), isDigit(12), buf[13] == UInt8(ascii: ":"),
                  isDigit(14), isDigit(15), buf[16] == UInt8(ascii: ":"),
                  isDigit(17), isDigit(18) else { return nil }
            let year = digit(0) * 1000 + digit(1) * 100 + digit(2) * 10 + digit(3)
            let month = digit(5) * 10 + digit(6)
            let day = digit(8) * 10 + digit(9)
            let hour = digit(11) * 10 + digit(12)
            let minute = digit(14) * 10 + digit(15)
            let second = digit(17) * 10 + digit(18)
            // year >= 1583: `ISO8601DateFormatter` sits on ICU's default
            // hybrid calendar, which is JULIAN before the 1582-10-15 cutover
            // (0001-01-01T00:00:00Z parses two days off a proleptic-Gregorian
            // reading). Nothing this app stores predates 1583; leave those to
            // the formatter rather than answer them differently.
            guard year >= 1583, month >= 1, month <= 12, day >= 1, day <= 31,
                  hour <= 24, minute <= 59, second <= 59 else { return nil }

            var i = 19
            var millis = 0
            if buf[i] == UInt8(ascii: ".") {
                i += 1
                var digits = 0
                var place = 100
                while i < n, isDigit(i) {
                    if digits < 3 { millis += digit(i) * place; place /= 10 }   // truncate, never round
                    digits += 1
                    i += 1
                }
                guard digits > 0 else { return nil }
            }

            guard i < n else { return nil }   // no zone designator → formatter says nil too
            var offsetSeconds = 0
            let z = buf[i]
            if z == UInt8(ascii: "Z") || z == UInt8(ascii: "z") {
                guard i + 1 == n else { return nil }
            } else if z == UInt8(ascii: "+") || z == UInt8(ascii: "-") {
                let sign = z == UInt8(ascii: "+") ? 1 : -1
                let rest = n - i - 1
                var oh = 0
                var om = 0
                if rest == 5, isDigit(i + 1), isDigit(i + 2), buf[i + 3] == UInt8(ascii: ":"),
                   isDigit(i + 4), isDigit(i + 5) {
                    oh = digit(i + 1) * 10 + digit(i + 2)
                    om = digit(i + 4) * 10 + digit(i + 5)
                } else if rest == 4, isDigit(i + 1), isDigit(i + 2), isDigit(i + 3), isDigit(i + 4) {
                    oh = digit(i + 1) * 10 + digit(i + 2)
                    om = digit(i + 3) * 10 + digit(i + 4)
                } else if rest == 2, isDigit(i + 1), isDigit(i + 2) {
                    oh = digit(i + 1) * 10 + digit(i + 2)
                } else {
                    return nil
                }
                guard oh <= 23, om <= 59 else { return nil }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }

            let secs = daysFromCivil(year, month, day) * 86_400
                + hour * 3600 + minute * 60 + second - offsetSeconds
            // NOT `Double(secs) * 1000 + Double(millis)`. That is the exact
            // value, but the formatter's is not: it goes epoch-ms → seconds →
            // `Date` (which stores seconds since 2001) → back to epoch-ms, and
            // those two divisions lose up to ~2e-4 ms for instants far from
            // 2001 (1930-12-08T10:28:32.582Z reads back as …418.0002, not
            // …418.0). Reproducing the round-trip literally keeps every value
            // bit-identical to what the app parsed before — a boundary compare
            // like `isCreatedToday`'s `t >= startOfDay` can't flip.
            let referenceEpoch: Double = 978_307_200      // 2001-01-01T00:00:00Z
            let sinceReference = Double(secs * 1000 + millis) / 1000 - referenceEpoch
            return (sinceReference + referenceEpoch) * 1000
        }
    }

    /// Local-midnight (start-of-day) epoch ms for the day containing
    /// `now`. Equivalent to `new Date(now).setHours(0,0,0,0)`.
    public static func startOfDayMillis(_ now: EpochMillis) -> EpochMillis {
        let date = Date(timeIntervalSince1970: now / 1000)
        let start = Time.calendar.startOfDay(for: date)
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
    ///
    /// PERFORMANCE: `String(format:)` is ~1.3 µs a call and this runs once per
    /// session in the Calendar focus heat-map (1,500 calls) and once per day in
    /// every occurrence materialisation, so the padding is done by hand for the
    /// ordinary ranges and falls back to `String(format:)` for anything outside
    /// them (a negative or 5-digit year, where `%04d`'s own width/sign rules
    /// would differ). Output is identical either way —
    /// `Tests/UnstuckCoreTests/ClockDateISOTests.swift` compares the two over
    /// the full component range.
    public static func dateISO(_ date: Date) -> String {
        let c = Time.calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        guard y >= 0, y <= 9999, m >= 0, m <= 99, d >= 0, d <= 99 else {
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        let zero = UInt8(ascii: "0"), dash = UInt8(ascii: "-")
        let bytes: [UInt8] = [
            zero &+ UInt8(y / 1000), zero &+ UInt8((y / 100) % 10),
            zero &+ UInt8((y / 10) % 10), zero &+ UInt8(y % 10), dash,
            zero &+ UInt8(m / 10), zero &+ UInt8(m % 10), dash,
            zero &+ UInt8(d / 10), zero &+ UInt8(d % 10),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `YYYY-MM-DD` for the day containing `now` (epoch ms), local.
    public static func dateISO(millis now: EpochMillis) -> String {
        dateISO(Date(timeIntervalSince1970: now / 1000))
    }
}
