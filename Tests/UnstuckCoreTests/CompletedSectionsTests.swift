// Tasks › Completed sections (CompletedSections.swift) — the cross-platform
// cases: local-midnight boundaries, Monday week start (incl. today = Monday /
// Tuesday / Sunday), exactly 00:00, missing/garbage completedAt, newest-first
// ordering, the recipient's zone, and both DST changeovers.

import XCTest
@testable import UnstuckCore

private let london = TimeZone(identifier: "Europe/London")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func cal(_ tz: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    c.firstWeekday = 1   // a Sunday-first device locale must not change the rule
    return c
}

/// Local wall-clock instant in `tz` → epoch millis.
private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0,
                _ tz: TimeZone = london) -> EpochMillis {
    let date = cal(tz).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    return date.timeIntervalSince1970 * 1000
}

/// The same instant as the ISO string a row carries (UTC `Z`).
private func iso(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0,
                 _ tz: TimeZone = london) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms(y, mo, d, h, mi, s, tz) / 1000))
}

final class CompletedSectionsTests: XCTestCase {

    private func section(_ at: String?, now: EpochMillis, _ tz: TimeZone = london) -> CompletedSection {
        completedSection(completedAt: at, now: now, calendar: cal(tz))
    }

    /// Thursday 2026-09-24 15:00 — every boundary, to the second.
    func testThursdayBoundaries() {
        let now = ms(2026, 9, 24, 15)
        XCTAssertEqual(section(iso(2026, 9, 24, 0, 0, 0), now: now), .today)          // exactly 00:00
        XCTAssertEqual(section(iso(2026, 9, 24, 14, 59), now: now), .today)
        XCTAssertEqual(section(iso(2026, 9, 25, 9), now: now), .today)                // future (clock skew)
        XCTAssertEqual(section(iso(2026, 9, 23, 23, 59, 59), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 9, 23, 0, 0, 0), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 9, 22, 23, 59, 59), now: now), .earlierThisWeek)  // Tue
        XCTAssertEqual(section(iso(2026, 9, 21, 0, 0, 0), now: now), .earlierThisWeek)     // Mon 00:00
        XCTAssertEqual(section(iso(2026, 9, 20, 23, 59, 59), now: now), .lastWeek)        // Sun
        XCTAssertEqual(section(iso(2026, 9, 14, 0, 0, 0), now: now), .lastWeek)           // prev Mon 00:00
        XCTAssertEqual(section(iso(2026, 9, 13, 23, 59, 59), now: now), .earlier)
        XCTAssertEqual(section(iso(2025, 1, 1), now: now), .earlier)
    }

    func testMissingOrGarbageCompletedAtIsEarlier() {
        let now = ms(2026, 9, 24, 15)
        XCTAssertEqual(section(nil, now: now), .earlier)
        XCTAssertEqual(section("", now: now), .earlier)
        XCTAssertEqual(section("garbage", now: now), .earlier)
    }

    /// Today = Monday: nothing can be "Earlier this week"; Sunday is Yesterday
    /// (Yesterday wins), Saturday is Last week.
    func testTodayIsMonday() {
        let now = ms(2026, 9, 21, 9)
        XCTAssertEqual(section(iso(2026, 9, 21, 0, 0, 0), now: now), .today)
        XCTAssertEqual(section(iso(2026, 9, 20, 12), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 9, 19, 23, 59), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 9, 14, 0, 0, 0), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 9, 13, 23, 59, 59), now: now), .earlier)
        for h in stride(from: 0, to: 24 * 21, by: 1) {
            let t = Date(timeIntervalSince1970: now / 1000 - Double(h) * 3600)
            XCTAssertNotEqual(section(ISO8601DateFormatter().string(from: t), now: now), .earlierThisWeek)
        }
    }

    /// Today = Tuesday: "Earlier this week" is empty too, and Sunday is Last week.
    func testTodayIsTuesday() {
        let now = ms(2026, 9, 22, 9)
        XCTAssertEqual(section(iso(2026, 9, 21, 0, 0, 0), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 9, 20, 23, 59, 59), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 9, 14, 0, 0, 0), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 9, 13, 23, 59), now: now), .earlier)
    }

    /// Today = Sunday: the week still started last Monday (not today).
    func testTodayIsSunday() {
        let now = ms(2026, 9, 27, 9)
        XCTAssertEqual(section(iso(2026, 9, 26, 8), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 9, 21, 0, 0, 0), now: now), .earlierThisWeek)
        XCTAssertEqual(section(iso(2026, 9, 20, 23, 59), now: now), .lastWeek)
    }

    /// Boundaries are the viewer's LOCAL midnight: one instant, two zones.
    func testLocalZoneDecides() {
        let at = "2026-09-23T16:00:00Z"              // London Wed 17:00 · Tokyo Thu 01:00
        let now = 1_790_251_200_000.0                // 2026-09-24T12:00:00Z
        XCTAssertEqual(section(at, now: now, london), .yesterday)
        XCTAssertEqual(section(at, now: now, tokyo), .today)
    }

    /// Autumn back (Sun 2026-10-25 is 25h in London): 00:30 BST that Sunday
    /// is still Yesterday on Monday — a naive "midnight − 24h" would miss it.
    func testDSTFallBack() {
        let now = ms(2026, 10, 26, 10)
        XCTAssertEqual(section(iso(2026, 10, 25, 0, 30), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 10, 25, 0, 0, 0), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 10, 24, 23, 59, 59), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 10, 26, 0, 0, 0), now: now), .today)
    }

    /// Spring forward (Sun 2026-03-29 is 23h): Saturday 23:30 is NOT yesterday.
    func testDSTSpringForward() {
        let now = ms(2026, 3, 30, 10)
        XCTAssertEqual(section(iso(2026, 3, 29, 23, 30), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 3, 29, 0, 0, 0), now: now), .yesterday)
        XCTAssertEqual(section(iso(2026, 3, 28, 23, 30), now: now), .lastWeek)
        // A week that spans the change still starts on Monday 00:00.
        XCTAssertEqual(section(iso(2026, 3, 23, 0, 0, 0), now: now), .lastWeek)
        XCTAssertEqual(section(iso(2026, 3, 22, 23, 59, 59), now: now), .earlier)
    }

    /// Sections in order, empty ones omitted, newest first inside each,
    /// undated rows last (input order kept for ties).
    func testGroupingOrderAndOmission() {
        let now = ms(2026, 9, 24, 15)
        let rows: [(String, String?)] = [
            ("old", iso(2026, 8, 1)),
            ("tMorning", iso(2026, 9, 24, 8)),
            ("noDateA", nil),
            ("lastWeek", iso(2026, 9, 16)),
            ("tNoon", iso(2026, 9, 24, 12)),
            ("older", iso(2026, 7, 1)),
            ("noDateB", "garbage"),
            ("tieA", iso(2026, 9, 16, 9)),
            ("tieB", iso(2026, 9, 16, 9)),
        ]
        let groups = groupCompleted(rows, completedAt: { $0.1 }, now: now, calendar: cal(london))
        XCTAssertEqual(groups.map(\.section), [.today, .lastWeek, .earlier])   // no Yesterday / this week
        XCTAssertEqual(groups[0].items.map(\.0), ["tNoon", "tMorning"])
        XCTAssertEqual(groups[1].items.map(\.0), ["lastWeek", "tieA", "tieB"])
        XCTAssertEqual(groups[2].items.map(\.0), ["old", "older", "noDateA", "noDateB"])
        XCTAssertTrue(groupCompleted([(String, String?)](), completedAt: { $0.1 }, now: now).isEmpty)
    }

    func testLabelsAndDefaultFolding() {
        XCTAssertEqual(CompletedSection.allCases.map(\.label),
                       ["Today", "Yesterday", "Earlier this week", "Last week", "Earlier"])
        XCTAssertEqual(CompletedSection.allCases.filter(\.expandedByDefault), [.today, .yesterday])
    }
}
