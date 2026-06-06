// Ported 1:1 from lib/recurrence.test.ts.

import XCTest
@testable import UnstuckCore

final class MaterializeOccurrencesTests: XCTestCase {
    // Thu May 21 2026
    private let start = Time.civil(2026, 5, 21)

    func testDailyOnePerDayAcrossHorizon() {
        let occ = materializeOccurrences(.daily(until: nil), startDate: start, startTime: "09:00", horizonDays: 14)
        XCTAssertEqual(occ.count, 14)
        XCTAssertEqual(occ[0], MaterializedOccurrence(date: "2026-05-21", startTime: "09:00"))
        XCTAssertEqual(occ[13], MaterializedOccurrence(date: "2026-06-03", startTime: "09:00"))
    }

    func testWeeklyMonWedFri() {
        let occ = materializeOccurrences(.weekly(daysOfWeek: [1, 3, 5], until: nil),
                                         startDate: start, startTime: "09:00", horizonDays: 14)
        XCTAssertEqual(occ.map(\.date), [
            "2026-05-22", "2026-05-25", "2026-05-27", "2026-05-29", "2026-06-01", "2026-06-03",
        ])
    }

    func testMonthlySameDayOfMonth() {
        let occ = materializeOccurrences(.monthly(until: nil), startDate: start, startTime: "09:00", horizonDays: 93)
        XCTAssertEqual(occ.map(\.date), ["2026-05-21", "2026-06-21", "2026-07-21", "2026-08-21"])
    }

    // A day-31 monthly start clamps to each month's last day (Feb 28 in a non-leap
    // year), then RECOVERS to 31 in long months — it doesn't drift down. (Android parity.)
    func testMonthlyDay31ClampsToShortMonthEnd() {
        let occ = materializeOccurrences(.monthly(until: nil), startDate: Time.civil(2026, 1, 31), startTime: "09:00", horizonDays: 95)
        XCTAssertEqual(occ.map(\.date), ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
    }

    // Same start in a leap year clamps Feb to the 29th.
    func testMonthlyDay31ClampsToLeapFeb() {
        let occ = materializeOccurrences(.monthly(until: nil), startDate: Time.civil(2024, 1, 31), startTime: "09:00", horizonDays: 95)
        XCTAssertEqual(occ.map(\.date), ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30"])
    }

    func testDefaultHorizonIs8Weeks() {
        let occ = materializeOccurrences(.daily(until: nil), startDate: start, startTime: "09:00")
        XCTAssertEqual(occ.count, RECURRENCE_HORIZON_DAYS)
    }

    func testUntilStopsInclusive() {
        let occ = materializeOccurrences(.daily(until: "2026-05-25"), startDate: start, startTime: "09:00", horizonDays: 56)
        XCTAssertEqual(occ.map(\.date), ["2026-05-21", "2026-05-22", "2026-05-23", "2026-05-24", "2026-05-25"])
    }

    func testNullUntilUsesHorizon() {
        let occ = materializeOccurrences(.daily(until: nil), startDate: start, startTime: "09:00", horizonDays: 7)
        XCTAssertEqual(occ.count, 7)
    }

    func testWeeklyWithUntilSkipsOutOfRange() {
        let occ = materializeOccurrences(.weekly(daysOfWeek: [1], until: "2026-06-15"),
                                         startDate: start, startTime: "09:00", horizonDays: 56)
        XCTAssertEqual(occ.map(\.date), ["2026-05-25", "2026-06-01", "2026-06-08", "2026-06-15"])
    }
}

final class RegenerateForTaskTests: XCTestCase {
    private let t = mkTask(id: "task-1", name: "A")
    private let startDate = Time.civil(2026, 5, 21)
    private let today = "2026-05-21"

    func testNullRecurrenceDeletesFutureKeepsHistory() {
        let blocks = [
            mkBlock(id: "past", taskId: "task-1", date: "2026-05-10"),
            mkBlock(id: "today", taskId: "task-1", date: today),
            mkBlock(id: "future1", taskId: "task-1", date: "2026-05-22"),
            mkBlock(id: "future2", taskId: "task-1", date: "2026-05-23"),
        ]
        let plan = regenerateForTask(task: t, recurrence: nil, existingBlocks: blocks,
                                     todayIso: today, startTime: "09:00", startDate: startDate)
        XCTAssertEqual(plan.toUpsert, [])
        XCTAssertEqual(plan.toDelete.sorted(), ["future1", "future2"])
    }

    func testWeeklyAddsMissingDeletesMismatched() {
        let blocks = [mkBlock(id: "stray", taskId: "task-1", date: "2026-05-26")]  // Tue
        let plan = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                     existingBlocks: blocks, todayIso: today,
                                     startTime: "09:00", startDate: startDate, horizonDays: 14)
        XCTAssertEqual(plan.toDelete, ["stray"])
        XCTAssertEqual(plan.toUpsert.map(\.date), ["2026-05-25", "2026-06-01"])
        XCTAssertTrue(plan.toUpsert.allSatisfy { $0.taskId == "task-1" })
    }

    func testPreservesMatchingFutureBlocks() {
        let blocks = [mkBlock(id: "kept", taskId: "task-1", startTime: "09:00", date: "2026-05-25")]
        let plan = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                     existingBlocks: blocks, todayIso: today,
                                     startTime: "09:00", startDate: startDate, horizonDays: 14)
        XCTAssertEqual(plan.toDelete, [])
        XCTAssertEqual(plan.toUpsert.map(\.date), ["2026-06-01"])
    }
}

final class RecurrenceLabelTests: XCTestCase {
    func testNilIsEmpty() {
        XCTAssertEqual(recurrenceLabel(nil), "")
    }
    func testAppendsUntil() {
        XCTAssertEqual(recurrenceLabel(.daily(until: "2026-06-15")), "Repeats daily until Jun 15, 2026")
        XCTAssertEqual(recurrenceLabel(.weekly(daysOfWeek: [1, 3, 5], until: "2026-08-01")),
                       "Repeats Mon/Wed/Fri until Aug 1, 2026")
    }
    func testOmitsUntilWhenUnset() {
        XCTAssertEqual(recurrenceLabel(.daily(until: nil)), "Repeats daily")
    }
    func testDailyMonthly() {
        XCTAssertEqual(recurrenceLabel(.daily(until: nil)), "Repeats daily")
        XCTAssertEqual(recurrenceLabel(.monthly(until: nil)), "Repeats monthly")
    }
    func testWeeklyWeekdays() {
        XCTAssertEqual(recurrenceLabel(.weekly(daysOfWeek: [1, 2, 3, 4, 5], until: nil)), "Repeats weekdays")
    }
    func testWeeklyWeekends() {
        XCTAssertEqual(recurrenceLabel(.weekly(daysOfWeek: [0, 6], until: nil)), "Repeats weekends")
    }
    func testWeeklyAllSevenCollapsesToDaily() {
        XCTAssertEqual(recurrenceLabel(.weekly(daysOfWeek: [0, 1, 2, 3, 4, 5, 6], until: nil)), "Repeats daily")
    }
    func testWeeklyMixedLists() {
        XCTAssertEqual(recurrenceLabel(.weekly(daysOfWeek: [1, 3, 5], until: nil)), "Repeats Mon/Wed/Fri")
    }
}
