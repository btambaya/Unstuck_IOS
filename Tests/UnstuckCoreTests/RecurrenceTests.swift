// Ported 1:1 from lib/recurrence.test.ts.

import XCTest
import Foundation
@testable import UnstuckCore

// Forward-compat: an UNKNOWN recurrence kind (a newer release added a type this
// build can't model) must NOT throw on decode — a throw would abort the whole
// TaskRow decode and the task would VANISH from the list. It degrades to an inert
// no-op daily (Recurrence.isUnknown) that materialises zero occurrences and
// renders a blank label. Mirrors the Android RecurrenceSerializer fix.
final class RecurrenceUnknownKindTests: XCTestCase {
    private func decode(_ json: String) throws -> Recurrence {
        try JSONDecoder().decode(Recurrence.self, from: json.data(using: .utf8)!)
    }

    func testUnknownKindDecodesToInertSentinelWithoutThrowing() throws {
        let r = try decode(#"{"kind":"yearly"}"#)
        XCTAssertTrue(Recurrence.isUnknown(r))
        if case .daily(let until) = r {
            XCTAssertEqual(until, Recurrence.UNKNOWN_UNTIL)
        } else {
            XCTFail("unknown kind should degrade to a daily sentinel")
        }
    }

    func testUnknownKindMaterializesZeroOccurrences() throws {
        let r = try decode(#"{"kind":"quarterly","until":null}"#)
        let occ = materializeOccurrences(r, startDate: Time.civil(2026, 5, 21), startTime: "09:00", horizonDays: 56)
        XCTAssertTrue(occ.isEmpty, "an unknown recurrence must not schedule any occurrence")
    }

    func testUnknownKindRendersBlankLabel() throws {
        let r = try decode(#"{"kind":"fortnightly"}"#)
        XCTAssertEqual(recurrenceLabel(r), "")
    }

    func testKnownKindsAreNotFlaggedUnknown() {
        XCTAssertFalse(Recurrence.isUnknown(.daily(until: nil)))
        XCTAssertFalse(Recurrence.isUnknown(.daily(until: "2026-09-01")))
        XCTAssertFalse(Recurrence.isUnknown(.weekly(daysOfWeek: [1], until: nil)))
        XCTAssertFalse(Recurrence.isUnknown(.monthly(until: nil)))
        XCTAssertFalse(Recurrence.isUnknown(nil))
    }
}

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

// A daily series spanning a DST transition must produce exactly one occurrence
// per consecutive civil day — never dropping or doubling the transition day.
// We re-floor each step (startOfDay(addDays(startOfDay(start), i))) so a
// startDate carrying a time-of-day can't drift across the spring-forward gap.
// Pin the process timezone to a DST-observing zone (CI runs TZ=UTC, which has
// no DST), and exercise the spring-forward day (Sun Mar 8, 2026 in US Eastern).
final class MaterializeOccurrencesDSTTests: XCTestCase {
    private var savedTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
    }
    override func tearDown() {
        NSTimeZone.default = savedTimeZone
        super.tearDown()
    }

    func testDailyAcrossSpringForwardNoDropOrDouble() {
        // Start Fri Mar 6 — series crosses the spring-forward boundary (Mar 8).
        let occ = materializeOccurrences(.daily(until: nil),
                                         startDate: Time.civil(2026, 3, 6), startTime: "09:00", horizonDays: 6)
        XCTAssertEqual(occ.map(\.date),
                       ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10", "2026-03-11"])
        // No civil day repeated, none skipped.
        XCTAssertEqual(Set(occ.map(\.date)).count, occ.count)
    }

    func testDailyAcrossFallBackNoDropOrDouble() {
        // Fall-back boundary: Sun Nov 1, 2026 in US Eastern.
        let occ = materializeOccurrences(.daily(until: nil),
                                         startDate: Time.civil(2026, 10, 30), startTime: "09:00", horizonDays: 5)
        XCTAssertEqual(occ.map(\.date),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03"])
        XCTAssertEqual(Set(occ.map(\.date)).count, occ.count)
    }

    func testNonMidnightStartDateStillLandsOnCivilDays() {
        // A startDate carrying a wall-clock time (not local midnight) must still
        // materialize one occurrence per civil day across the DST gap — the
        // pre-fix code (addDays preserving time-of-day, no re-floor) is what
        // risked a drift on the transition day.
        let noon = Calendar.current.date(bySettingHour: 13, minute: 30, second: 0,
                                         of: Time.civil(2026, 3, 6))!
        let occ = materializeOccurrences(.daily(until: nil),
                                         startDate: noon, startTime: "09:00", horizonDays: 6)
        XCTAssertEqual(occ.map(\.date),
                       ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10", "2026-03-11"])
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

// The post-plan coverage decision behind scheduleTaskAt's guarantee-upsert,
// extracted as a pure helper. A block the plan is about to DELETE must NOT count
// as coverage (else the day silently ends up empty); a planned upsert DOES.
final class RecurrenceCoversChosenDateTests: XCTestCase {
    private let iso = "2026-05-25"

    func testCoveredByPlannedUpsert() {
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: iso)], toDelete: [])
        XCTAssertTrue(recurrenceCoversChosenDate(existing: [], plan: plan, iso: iso))
    }

    func testCoveredByExistingBlockNotBeingDeleted() {
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [], toDelete: [])
        XCTAssertTrue(recurrenceCoversChosenDate(existing: existing, plan: plan, iso: iso))
    }

    func testExistingBlockBeingDeletedDoesNotCount() {
        // The only block on the chosen date is queued for deletion → NOT covered,
        // so the caller must mint a guarantee block (the bug this guards).
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [], toDelete: ["e1"])
        XCTAssertFalse(recurrenceCoversChosenDate(existing: existing, plan: plan, iso: iso))
    }

    func testDeletedExistingButPlannedUpsertOnSameDateIsCovered() {
        // The old block is deleted but the plan re-adds one on the same date.
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: iso)], toDelete: ["e1"])
        XCTAssertTrue(recurrenceCoversChosenDate(existing: existing, plan: plan, iso: iso))
    }

    func testNothingOnChosenDateIsNotCovered() {
        let existing = [mkBlock(id: "e1", taskId: "t", date: "2026-05-26")]
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: "2026-06-01")], toDelete: [])
        XCTAssertFalse(recurrenceCoversChosenDate(existing: existing, plan: plan, iso: iso))
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
