// Ported 1:1 from lib/free-slots.test.ts. The web's NOW is a local
// (zoneless) datetime; we build the same under TZ=UTC.

import XCTest
@testable import UnstuckCore

private func localDT(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = hh; c.minute = mm
    return Calendar.current.date(from: c)!
}

final class FindFreeSlotsTests: XCTestCase {
    private let now = localDT(2026, 5, 21, 7, 0)  // before workday starts

    func testEmptyDayStartsAtDayStart() {
        let slots = findFreeSlots([], durationMin: 30, now: now, startDate: now, daysToScan: 1, limit: 3)
        XCTAssertGreaterThan(slots.count, 0)
        XCTAssertEqual(slots[0].startTime, "08:00")
        XCTAssertEqual(slots[0].date, "2026-05-21")
    }

    func testSkipsTooShortWindows() {
        let blocks = [mkBlock(startTime: "08:15", durationMinutes: 45, date: "2026-05-21")]  // 08:15–09:00
        let slots = findFreeSlots(blocks, durationMin: 30, now: now, startDate: now, daysToScan: 1, limit: 3)
        XCTAssertEqual(slots[0].startTime, "09:00")
    }

    func testLimitsResults() {
        let slots = findFreeSlots([], durationMin: 15, now: now, startDate: now, daysToScan: 1, limit: 2)
        XCTAssertEqual(slots.count, 2)
    }

    func testTodaySnapsToNext15MinAfterNowPlus5() {
        let lateNow = localDT(2026, 5, 21, 8, 7)  // 08:07 → next slot 08:15
        let slots = findFreeSlots([], durationMin: 15, now: lateNow, startDate: lateNow, daysToScan: 1, limit: 1)
        XCTAssertEqual(slots[0].startTime, "08:15")
    }

    // A non-positive duration would make `cursor + durationMin <= gapEnd`
    // perpetually true → an unbounded run of zero/negative-length garbage slots.
    // Coerced to >= 1 (Android parity), so the count is bounded by the limit and
    // each slot is a real, advancing time.
    func testNonPositiveDurationCoercedToOne() {
        let zero = findFreeSlots([], durationMin: 0, now: now, startDate: now, daysToScan: 1, limit: 3)
        XCTAssertEqual(zero.count, 3, "limit still bounds the output; no infinite garbage run")
        XCTAssertEqual(zero[0].startTime, "08:00")
        // Slots must advance by the 30-min step (max(durationMin, 30)).
        XCTAssertEqual(zero[1].startTime, "08:30")
        let negative = findFreeSlots([], durationMin: -10, now: now, startDate: now, daysToScan: 1, limit: 2)
        XCTAssertEqual(negative.count, 2)
        XCTAssertEqual(negative[0].startTime, "08:00")
    }
}

final class FindFreeSlotsForDateTests: XCTestCase {
    private let now = localDT(2026, 5, 21, 7, 0)

    func testFutureDateIndependentOfNow() {
        let slots = findFreeSlotsForDate([], durationMin: 25, isoDate: "2026-06-01", now: now, limit: 3)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].date, "2026-06-01")
        XCTAssertEqual(slots[0].startTime, "08:00")
    }
}

final class FindConflictsTests: XCTestCase {
    func testReturnsOverlappingBlocks() {
        let blocks = [
            mkBlock(id: "a", startTime: "09:00", durationMinutes: 30, date: "2026-05-21"),
            mkBlock(id: "b", startTime: "09:30", durationMinutes: 60, date: "2026-05-21"),
            mkBlock(id: "c", startTime: "14:00", durationMinutes: 30, date: "2026-05-21"),
        ]
        let out = findConflicts(date: "2026-05-21", startTime: "09:15", durationMin: 30, blocks: blocks)
        XCTAssertEqual(out.map { $0.block.id }, ["a", "b"])
        XCTAssertEqual(out[0].overlapMin, 15)
    }

    func testEmptyWhenNoConflicts() {
        let blocks = [mkBlock(id: "a", startTime: "09:00", durationMinutes: 30, date: "2026-05-21")]
        XCTAssertEqual(findConflicts(date: "2026-05-21", startTime: "10:00", durationMin: 30, blocks: blocks), [])
    }

    func testExcludesEditedBlock() {
        let blocks = [mkBlock(id: "a", startTime: "09:00", durationMinutes: 30, date: "2026-05-21")]
        XCTAssertEqual(findConflicts(date: "2026-05-21", startTime: "09:00", durationMin: 30, blocks: blocks, excludeBlockId: "a"), [])
    }

    func testIgnoresOtherDates() {
        let blocks = [mkBlock(id: "a", startTime: "09:00", durationMinutes: 30, date: "2026-05-20")]
        XCTAssertEqual(findConflicts(date: "2026-05-21", startTime: "09:00", durationMin: 30, blocks: blocks), [])
    }
}

final class FormatTimeTests: XCTestCase {
    func testFormats12Hour() {
        XCTAssertEqual(formatTime("09:00", clock: .h12), "9:00 AM")
        XCTAssertEqual(formatTime("14:30", clock: .h12), "2:30 PM")
        XCTAssertEqual(formatTime("00:15", clock: .h12), "12:15 AM")
        XCTAssertEqual(formatTime("12:00", clock: .h12), "12:00 PM")
    }

    /// A 24-hour phone reads 24-hour times — never "2:30 PM" next to "14:30"
    /// (Ahmad, 2026-09-24).
    func testFormats24Hour() {
        XCTAssertEqual(formatTime("09:00", clock: .h24), "09:00")
        XCTAssertEqual(formatTime("14:30", clock: .h24), "14:30")
        XCTAssertEqual(formatTime("00:15", clock: .h24), "00:15")
    }

    func testDefaultFollowsTheDevice() {
        XCTAssertEqual(formatTime("14:30"), ClockFormat.device.time("14:30"))
    }

    func testBlockTimeRange() {
        let b = mkBlock(startTime: "09:00", durationMinutes: 60, date: "2026-05-21")
        XCTAssertEqual(blockTimeRange(b, clock: .h12), "9:00–10:00 AM")
        XCTAssertEqual(blockTimeRange(b, clock: .h24), "09:00–10:00")
        let noon = mkBlock(startTime: "11:30", durationMinutes: 60, date: "2026-05-21")
        XCTAssertEqual(blockTimeRange(noon, clock: .h12), "11:30 AM–12:30 PM")
    }

    func testSlotLabelsFollowTheClock() {
        let now = localDT(2026, 5, 21, 7, 0)
        let h24 = findFreeSlots([], durationMin: 30, now: now, startDate: now, daysToScan: 1, limit: 1, clock: .h24)
        let h12 = findFreeSlots([], durationMin: 30, now: now, startDate: now, daysToScan: 1, limit: 1, clock: .h12)
        XCTAssertEqual(h24.first?.label, "Today · 08:00")
        XCTAssertEqual(h12.first?.label, "Today · 8:00 AM")
        XCTAssertEqual(h24.first?.startTime, "08:00", "the stored time stays machine HH:MM")
        XCTAssertEqual(h12.first?.startTime, "08:00")
    }
}
