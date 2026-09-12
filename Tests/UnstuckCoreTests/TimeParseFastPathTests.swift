// Differential proof for `Time.parseMillis`' hand-rolled fast path.
//
// `Time.fastParseMillis` exists ONLY to make the hot path cheap — it must
// never change what the app parses or what it parses it to. The contract it
// has to hold, for EVERY input:
//
//   Time.parseMillis(s)  ==  <the two ISO8601DateFormatters, as before>   (bit-for-bit)
//
// and, additionally, whenever the fast path answers at all (non-nil) it must
// agree with the formatters bit-for-bit — a fast path that quietly accepts
// something the formatters reject, or returns a value half an ULP away, would
// be a silent data bug in task bucketing and the focus heat-map.
//
// The reference here is built from the same `formatOptions` the shipping
// parsers use, so this test is the before/after behaviour comparison.

import XCTest
@testable import UnstuckCore

final class TimeParseFastPathTests: XCTestCase {

    // MARK: - the reference implementation (what parseMillis did before)

    private let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func reference(_ iso: String) -> EpochMillis? {
        if let d = isoWithFractional.date(from: iso) { return d.timeIntervalSince1970 * 1000 }
        if let d = isoPlain.date(from: iso) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }

    /// Both halves of the contract, for one input.
    private func assertIdentical(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let want = reference(s)
        let got = Time.parseMillis(s)
        XCTAssertEqual(got?.bitPattern, want?.bitPattern,
                       "parseMillis(\"\(s)\") = \(String(describing: got)), formatters said \(String(describing: want))",
                       file: file, line: line)
        if let fast = Time.fastParseMillis(s) {
            XCTAssertEqual(fast.bitPattern, want?.bitPattern,
                           "fast path answered \(fast) for \"\(s)\" but the formatters said \(String(describing: want))",
                           file: file, line: line)
        }
    }

    // MARK: - the shapes the app actually stores

    func testCanonicalShapes() {
        let shapes = [
            "2026-09-12T03:04:05Z",                 // app-written, whole seconds
            "2026-09-12T03:04:05.123Z",             // app-written, JS toISOString
            "2026-09-12T03:04:05.000Z",
            "2026-09-12T03:04:05.999Z",
            "2026-09-12T03:04:05.1Z",               // 1 fractional digit
            "2026-09-12T03:04:05.12Z",              // 2
            "2026-09-12T03:04:05.1234Z",            // 4 — truncated, not rounded
            "2026-09-12T03:04:05.1235Z",            // would ROUND up; must truncate
            "2026-09-12T03:04:05.1239Z",
            "2026-09-12T03:04:05.999999Z",
            "2026-09-12T03:04:05.123456Z",          // PostgREST microseconds
            "2026-09-12T03:04:05.123456789Z",       // nanoseconds
            "2026-09-12T03:04:05.123456+00:00",     // PostgREST, the real hydrate shape
            "2026-09-12T03:04:05+00:00",
            "2026-09-12T03:04:05-00:00",
            "2026-09-12T03:04:05+05:30",
            "2026-09-12T03:04:05-08:00",
            "2026-09-12T03:04:05+0530",             // no colon
            "2026-09-12T03:04:05-0800",
            "2026-09-12T03:04:05+05",               // hour-only offset
            "2026-09-12T03:04:05-05",
            "2026-09-12T03:04:05z",                 // lower-case designator
            "2026-09-12T03:04:05.123z",
            "1970-01-01T00:00:00Z",                 // the epoch itself
            "1969-12-31T23:59:59.500Z",             // negative, with millis
            "1901-12-13T20:45:52Z",
            "0001-01-01T00:00:00Z",     // pre-cutover: formatter reads it JULIAN
            "1582-10-04T12:00:00Z",
            "1582-10-15T12:00:00Z",
            "1583-01-01T00:00:00.001Z",
            "9999-12-31T23:59:59.999Z",
            "2000-02-29T12:00:00Z",                 // leap day
            "2024-02-29T00:00:00.001Z",
            "2026-12-31T23:59:59Z",
            "2026-01-01T00:00:00Z",
        ]
        for s in shapes { assertIdentical(s) }
    }

    /// Out-of-range-but-accepted fields roll FORWARD in the formatter; the fast
    /// path's civil-date arithmetic has to roll the same way or it would hand
    /// the app a different day.
    func testRolloverMatchesTheFormatter() {
        let rollovers = [
            "2026-02-30T03:04:05Z",   // → 2026-03-02
            "2026-02-31T03:04:05Z",
            "2025-02-29T00:00:00Z",   // non-leap year
            "2026-04-31T00:00:00Z",   // 30-day month
            "2026-06-31T12:00:00Z",
            "2026-09-31T23:00:00Z",
            "2026-11-31T00:00:00.250Z",
            "2026-09-12T24:00:00Z",   // hour 24 → next midnight
            "2026-12-31T24:00:00Z",   // → year rollover
            "2026-02-28T24:00:00Z",
            "2024-02-29T24:00:00Z",
        ]
        for s in rollovers { assertIdentical(s) }
    }

    /// Everything the fast path must REFUSE to answer (it returns nil and the
    /// formatters decide). Some of these the formatters accept, some they
    /// don't — either way `parseMillis` must be unchanged.
    func testShapesTheFastPathMustDecline() {
        let odd = [
            "2026-09-12t03:04:05Z",    // lower-case T — formatter rejects
            "2026-9-12T03:04:05Z",     // 1-digit month — formatter ACCEPTS
            "26-09-12T03:04:05Z",      // 2-digit year — formatter ACCEPTS
            " 2026-09-12T03:04:05Z",   // leading space — formatter accepts
            "2026-09-12T03:04:05Z ",   // trailing space
            "2026-09-12T03:04:05ZZ",   // trailing junk — formatter accepts
            "2026-09-12 03:04:05Z",    // space separator
            "2026-09-12T03:04:05",     // no zone
            "2026-09-12T03:04:05.123", // no zone, with millis
            "2026-09-12T03:04:05.Z",   // empty fraction
            "2026-09-12T03:04:05.",
            "2026-09-12",              // date only
            "2026-09-12T03:04",        // no seconds
            "2026-09-12T03:04:60Z",    // leap second
            "2026-09-12T03:60:05Z",
            "2026-09-12T25:04:05Z",
            "2026-13-01T03:04:05Z",
            "2026-00-12T03:04:05Z",
            "2026-09-00T03:04:05Z",
            "2026-09-32T03:04:05Z",
            "2026-09-12T03:04:05+24:00",
            "2026-09-12T03:04:05+99:99",
            "2026-09-12T03:04:05+5:30",
            "2026-09-12T03:04:05+05:3",
            "+002026-09-12T03:04:05Z",
            "",
            "not a date",
            "🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛🕐🕑🕒🕓🕔🕕🕖🕗",   // ≥20 bytes, non-ASCII
            "null",
            "1789182245000",
        ]
        for s in odd { assertIdentical(s) }
    }

    /// Every offset form across the full legal range, against a fixed instant.
    func testEveryZoneOffset() {
        for h in 0...23 {
            for m in [0, 15, 30, 45, 59] {
                for sign in ["+", "-"] {
                    assertIdentical(String(format: "2026-09-12T03:04:05%@%02d:%02d", sign, h, m))
                    assertIdentical(String(format: "2026-09-12T03:04:05%@%02d%02d", sign, h, m))
                    assertIdentical(String(format: "2026-09-12T03:04:05.250%@%02d:%02d", sign, h, m))
                }
            }
            assertIdentical(String(format: "2026-09-12T03:04:05+%02d", h))
            assertIdentical(String(format: "2026-09-12T03:04:05-%02d", h))
        }
    }

    /// A broad sweep: every (month, day) pair including the illegal ones, over
    /// leap and non-leap years and across the epoch boundary, with and without
    /// fractional seconds.
    func testDateSweep() {
        // 1500/1582/1583 straddle ICU's Julian→Gregorian cutover, which the
        // fast path declines and the formatter answers on the JULIAN calendar.
        for year in [1500, 1582, 1583, 1584, 1899, 1900, 1969, 1970, 1971, 1999, 2000, 2024, 2025, 2026, 2100] {
            for month in 1...12 {
                for day in [1, 15, 28, 29, 30, 31] {
                    assertIdentical(String(format: "%04d-%02d-%02dT00:00:00Z", year, month, day))
                    assertIdentical(String(format: "%04d-%02d-%02dT23:59:59.987Z", year, month, day))
                    assertIdentical(String(format: "%04d-%02d-%02dT13:37:00+02:00", year, month, day))
                }
            }
        }
    }

    /// Every millisecond value, so truncation and the Double arithmetic are
    /// exercised across the whole 0…999 range.
    func testEveryMillisecondValue() {
        for ms in 0...999 {
            assertIdentical(String(format: "2026-09-12T03:04:05.%03dZ", ms))
            assertIdentical(String(format: "1969-12-31T23:59:59.%03dZ", ms))
        }
    }

    /// Every hour/minute/second field value.
    func testEveryClockField() {
        for h in 0...24 { assertIdentical(String(format: "2026-09-12T%02d:00:00Z", h)) }
        for m in 0...59 { assertIdentical(String(format: "2026-09-12T12:%02d:00Z", m)) }
        for s in 0...59 { assertIdentical(String(format: "2026-09-12T12:00:%02dZ", s)) }
        // …and the values just past the legal edge, which both must refuse.
        for bad in ["2026-09-12T25:00:00Z", "2026-09-12T99:00:00Z",
                    "2026-09-12T12:60:00Z", "2026-09-12T12:99:00Z",
                    "2026-09-12T12:00:60Z", "2026-09-12T12:00:99Z"] {
            assertIdentical(bad)
        }
    }

    /// Randomised fuzz over well-formed-ish strings, so a shape nobody thought
    /// to enumerate still has to agree.
    func testRandomisedFuzz() {
        var rng = SystemRandomNumberGenerator()
        let zones = ["Z", "z", "+00:00", "-03:30", "+0530", "+09", "-11", "", " ", "+5:00"]
        let fractions = ["", ".0", ".5", ".25", ".123", ".9999", ".000000", ".123456789"]
        for _ in 0..<4_000 {
            let y = Int.random(in: 1960...2100, using: &rng)
            let mo = Int.random(in: 0...13, using: &rng)
            let d = Int.random(in: 0...32, using: &rng)
            let h = Int.random(in: 0...25, using: &rng)
            let mi = Int.random(in: 0...60, using: &rng)
            let se = Int.random(in: 0...60, using: &rng)
            let s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, mo, d, h, mi, se)
                + fractions.randomElement(using: &rng)!
                + zones.randomElement(using: &rng)!
            assertIdentical(s)
        }
    }

    /// The parse is used from the sync engine off the main actor as well as
    /// from the view models — the fast path must stay thread-safe.
    func testConcurrentParsesAgree() {
        let stamps = (0..<500).map { String(format: "2026-09-%02dT%02d:%02d:%02d.%03dZ",
                                            ($0 % 28) + 1, $0 % 24, $0 % 60, $0 % 60, $0 % 1000) }
        let want = stamps.map { reference($0)! }
        let got = [EpochMillis?](unsafeUninitializedCapacity: stamps.count) { buf, count in
            count = stamps.count
            DispatchQueue.concurrentPerform(iterations: stamps.count) { i in
                buf.baseAddress!.advanced(by: i).initialize(to: Time.parseMillis(stamps[i]))
            }
        }
        for (i, w) in want.enumerated() {
            XCTAssertEqual(got[i]?.bitPattern, w.bitPattern, "concurrent parse #\(i) (\(stamps[i]))")
        }
    }
}
