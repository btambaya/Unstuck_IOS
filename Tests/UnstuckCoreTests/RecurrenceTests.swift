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

    // MARK: the anchor (audit 2026-09-21)
    //
    // regenerateForTask deletes every future block that doesn't match the
    // anchor's date|time, so the anchor decides what survives. Picking an
    // arbitrary or a historical block rebuilt the series at the wrong time —
    // one tester ended up with four "Office" tasks, one of them timeless, and
    // nothing on the next Monday.

    func testAnchorIsTheEarliestLiveBlockNotAnArbitraryOne() {
        var doneOld = mkBlock(id: "old", taskId: "task-1", startTime: "09:15", date: "2026-05-04")
        doneOld.done = true
        let blocks = [
            doneOld,                                                                     // history, wrong time
            mkBlock(id: "next", taskId: "task-1", startTime: "11:00", date: "2026-05-25"),  // what the user set
            mkBlock(id: "later", taskId: "task-1", startTime: "11:00", date: "2026-06-01"),
            mkBlock(id: "other", taskId: "task-2", startTime: "07:00", date: "2026-05-22"),
        ]
        let anchor = recurrenceAnchor(taskId: "task-1", blocks: blocks, todayIso: today)
        XCTAssertEqual(anchor?.id, "next")
        XCTAssertEqual(anchor?.startTime, "11:00", "the series keeps the time the user chose")
        // The old behaviour — the first/earliest block of any kind — would have
        // anchored on 09:15 and deleted both 11:00 occurrences.
        let plan = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                     existingBlocks: blocks, todayIso: today,
                                     startTime: anchor!.startTime, startDate: Time.civil(2026, 5, 25),
                                     horizonDays: 14)
        XCTAssertEqual(plan.toDelete, [], "nothing the user placed is removed")
        XCTAssertEqual(plan.toUpsert, [], "both Mondays already exist at 11:00")
    }

    func testAnchorFallsBackToHistoryAndIgnoresTimelessBlocks() {
        // Only history: keep its time of day rather than snapping to 09:00.
        var past = mkBlock(id: "past", taskId: "task-1", startTime: "07:30", date: "2026-05-04")
        past.done = true
        XCTAssertEqual(recurrenceAnchor(taskId: "task-1", blocks: [past], todayIso: today)?.id, "past")
        // A block with no time can't anchor a series (it produced the timeless
        // duplicate); a real one alongside it wins.
        let timeless = mkBlock(id: "none", taskId: "task-1", startTime: "", date: "2026-05-22")
        let timed = mkBlock(id: "timed", taskId: "task-1", startTime: "11:00", date: "2026-05-25")
        XCTAssertEqual(recurrenceAnchor(taskId: "task-1", blocks: [timeless, timed], todayIso: today)?.id, "timed")
        XCTAssertNil(recurrenceAnchor(taskId: "task-1", blocks: [timeless], todayIso: today))
        XCTAssertNil(recurrenceAnchor(taskId: "task-1", blocks: [], todayIso: today))
        // Skipped and done occurrences are not "live".
        var skipped = mkBlock(id: "skip", taskId: "task-1", startTime: "08:00", date: "2026-05-25")
        skipped.skipped = true
        let live = mkBlock(id: "live", taskId: "task-1", startTime: "11:00", date: "2026-05-26")
        XCTAssertEqual(recurrenceAnchor(taskId: "task-1", blocks: [skipped, live], todayIso: today)?.id, "live")
    }

    /// The horizon top-up's contract: run again with nothing changed and the
    /// plan adds nothing, so a launch-time pass is free and idempotent. Run it
    /// when the horizon has moved on and it only ADDS.
    func testRegenerateIsIdempotentAndOnlyExtendsWhenTheHorizonMoves() {
        let anchorDate = Time.civil(2026, 5, 25)
        let first = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                      existingBlocks: [], todayIso: today,
                                      startTime: "11:00", startDate: anchorDate, horizonDays: 14)
        XCTAssertEqual(first.toUpsert.map(\.date), ["2026-05-25", "2026-06-01"])
        let again = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                      existingBlocks: first.toUpsert, todayIso: today,
                                      startTime: "11:00", startDate: anchorDate, horizonDays: 14)
        XCTAssertEqual(again.toUpsert, [], "nothing to add the second time")
        XCTAssertEqual(again.toDelete, [], "and nothing to remove")
        let wider = regenerateForTask(task: t, recurrence: .weekly(daysOfWeek: [1], until: nil),
                                      existingBlocks: first.toUpsert, todayIso: today,
                                      startTime: "11:00", startDate: anchorDate, horizonDays: 28)
        XCTAssertEqual(wider.toUpsert.map(\.date), ["2026-06-08", "2026-06-15"], "the horizon moved: add only")
        XCTAssertEqual(wider.toDelete, [])
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

// A repeat turned off / on moves the day's done across (audit 2026-09-22, C3):
// a series' template carries no done of its own, a plain task's done is
// task-level. "Never" on a ticked day used to bring today back unticked, and
// Daily → Never → Daily must not leave a DONE template (an ended series).
final class TaskAfterSettingRecurrenceTests: XCTestCase {
    private let today = "2026-09-22"
    private let now = "2026-09-22T18:00:00.000Z"

    private func series(done: Bool = false, completedAt: String? = nil) -> TaskItem {
        var t = mkTask(id: "tpl", name: "Meditate", done: done)
        t.recurrence = .daily(until: nil)
        t.completedAt = completedAt
        return t
    }

    private func day(_ id: String, _ date: String, done: Bool = false, skipped: Bool = false,
                     completedAt: String? = nil, at startTime: String = "07:00") -> CalBlock {
        CalBlock(id: id, taskId: "tpl", taskName: "Meditate", startTime: startTime, durationMinutes: 20,
                 date: date, kind: .task, done: done, skipped: skipped, completedAt: completedAt)
    }

    func testNeverOnATickedDayCarriesTheTickOntoTheTask() {
        let blocks = [day("b0", "2026-09-21", done: true, completedAt: "2026-09-21T07:20:00.000Z"),
                      day("b1", today, done: true, completedAt: "2026-09-22T07:20:00.000Z"),
                      day("b2", "2026-09-23")]
        let out = taskAfterSettingRecurrence(series(), recurrence: nil, blocks: blocks, todayIso: today, nowISO: now)
        XCTAssertNil(out.recurrence)
        XCTAssertTrue(out.done)
        XCTAssertEqual(out.completedAt, "2026-09-22T07:20:00.000Z", "the day's own completion time")
    }

    func testATickWithNoStampFallsBackToNow() {
        let out = taskAfterSettingRecurrence(series(), recurrence: nil, blocks: [day("b1", today, done: true)],
                                             todayIso: today, nowISO: now)
        XCTAssertTrue(out.done)
        XCTAssertEqual(out.completedAt, now)
    }

    /// Owner decision: an open or absent today leaves the task OPEN — no
    /// silent completion.
    func testNeverWithTodayOpenOrAbsentLeavesTheTaskOpen() {
        let open = taskAfterSettingRecurrence(series(), recurrence: nil, blocks: [day("b1", today)],
                                              todayIso: today, nowISO: now)
        XCTAssertFalse(open.done)
        XCTAssertNil(open.completedAt)
        let twins = [day("b1", today, done: true, completedAt: now), day("b2", today, at: "19:00")]
        XCTAssertFalse(taskAfterSettingRecurrence(series(), recurrence: nil, blocks: twins, todayIso: today, nowISO: now).done,
                       "one of two occurrences today is still open")
        let skippedOnly = [day("b1", today, done: true, skipped: true)]
        XCTAssertFalse(taskAfterSettingRecurrence(series(), recurrence: nil, blocks: skippedOnly, todayIso: today, nowISO: now).done)
        let historyOnly = [day("b0", "2026-09-21", done: true, completedAt: "2026-09-21T07:20:00.000Z")]
        XCTAssertFalse(taskAfterSettingRecurrence(series(), recurrence: nil, blocks: historyOnly, todayIso: today, nowISO: now).done)
    }

    func testASeriesAlreadyDoneKeepsItsDone() {
        let t0 = "2026-09-17T09:00:00.000Z"
        let out = taskAfterSettingRecurrence(series(done: true, completedAt: t0), recurrence: nil, blocks: [day("b1", today)],
                                             todayIso: today, nowISO: now)
        XCTAssertTrue(out.done)
        XCTAssertEqual(out.completedAt, t0)
    }

    /// Daily → Never (ticked today, so done) → Daily must give an OPEN series.
    func testTurningARepeatBackOnReopensTheTask() {
        let blocks = [day("b1", today, done: true, completedAt: "2026-09-22T07:20:00.000Z")]
        let off = taskAfterSettingRecurrence(series(), recurrence: nil, blocks: blocks, todayIso: today, nowISO: now)
        XCTAssertTrue(off.done)
        let on = taskAfterSettingRecurrence(off, recurrence: .daily(until: nil), blocks: blocks, todayIso: today, nowISO: now)
        XCTAssertEqual(on.recurrence, .daily(until: nil))
        XCTAssertFalse(on.done, "a done template is an ended series")
        XCTAssertNil(on.completedAt)
    }

    func testOtherChangesOnlySetTheRecurrence() {
        let plain = mkTask(id: "tpl", name: "Meditate")
        let on = taskAfterSettingRecurrence(plain, recurrence: .weekly(daysOfWeek: [1], until: nil), blocks: [],
                                            todayIso: today, nowISO: now)
        XCTAssertEqual(on.recurrence, .weekly(daysOfWeek: [1], until: nil))
        XCTAssertFalse(on.done)
        let ended = series(done: true, completedAt: "2026-09-17T09:00:00.000Z")
        let retimed = taskAfterSettingRecurrence(ended, recurrence: .weekly(daysOfWeek: [2], until: nil), blocks: [],
                                                 todayIso: today, nowISO: now)
        XCTAssertTrue(retimed.done, "one rule for another leaves the done state as it is")
        var plainDone = mkTask(id: "p", name: "Plain", done: true)
        plainDone.completedAt = "2026-09-20T09:00:00.000Z"
        let stillPlain = taskAfterSettingRecurrence(plainDone, recurrence: nil, blocks: [], todayIso: today, nowISO: now)
        XCTAssertEqual(stillPlain, plainDone)
    }

    // MARK: occurrencesCarryingTaskDone — a done task made to repeat keeps its tick
    //
    // Stamps sit at 11:00Z so the local day is the literal's in any timezone
    // from UTC-11 to UTC+12 (isoToLocalYmd reads the device's zone).

    private func plain(done: Bool = true, completedAt: String? = "2026-09-22T11:00:00.000Z") -> TaskItem {
        var t = mkTask(id: "tpl", name: "Meditate", done: done)
        t.completedAt = completedAt
        return t
    }

    /// Ticked this morning, made daily: today's slot keeps the tick, so it is
    /// not back in Today to do again. Tomorrow's is a new day.
    func testADoneTaskMadeToRepeatKeepsTodaysTick() {
        let blocks = [day("b1", today, at: "07:30"), day("b2", "2026-09-23", at: "07:30")]
        let carried = occurrencesCarryingTaskDone(plain(), recurrence: .daily(until: nil), blocks: blocks,
                                                  todayIso: today, nowISO: now)
        XCTAssertEqual(carried.map(\.id), ["b1"])
        XCTAssertTrue(carried[0].done)
        XCTAssertEqual(carried[0].completedAt, "2026-09-22T11:00:00.000Z", "the task's own completion time")
        XCTAssertEqual(carried[0].startTime, "07:30", "only the done state changes")
        // With the task cleared, the day reads done exactly as a ticked occurrence.
        let tpl = taskAfterSettingRecurrence(plain(), recurrence: .daily(until: nil), blocks: blocks,
                                             todayIso: today, nowISO: now)
        let rows = projectOccurrences([tpl], [carried[0], blocks[1]], fromISO: today)
        XCTAssertEqual(rows.first { $0.id == "b1" }?.done, true)
        XCTAssertEqual(rows.first { $0.id == "b2" }?.done, false)
    }

    /// The tick lands on the slot it fulfilled — the latest scheduled day on
    /// or before the day it was done — so that slot is never an overdue miss.
    func testTheTickLandsOnTheSlotItFulfilled() {
        // Scheduled yesterday, done today (late): yesterday's slot.
        let late = occurrencesCarryingTaskDone(plain(), recurrence: .daily(until: nil),
                                               blocks: [day("b0", "2026-09-21")], todayIso: today, nowISO: now)
        XCTAssertEqual(late.map(\.id), ["b0"])
        let tpl = taskAfterSettingRecurrence(plain(), recurrence: .daily(until: nil), blocks: late,
                                             todayIso: today, nowISO: now)
        XCTAssertEqual(projectOverdueOccurrences([tpl], [day("b0", "2026-09-21")], todayISO: today).count, 1,
                       "left open, the slot showed as a missed day")
        XCTAssertTrue(projectOverdueOccurrences([tpl], late, todayISO: today).isEmpty,
                      "no overdue row for a day that was done")
        // Done yesterday on its slot: that slot. Today's is a new day, still open.
        let early = occurrencesCarryingTaskDone(plain(completedAt: "2026-09-21T11:00:00.000Z"), recurrence: .daily(until: nil),
                                                blocks: [day("b0", "2026-09-21"), day("b1", today)], todayIso: today, nowISO: now)
        XCTAssertEqual(early.map(\.id), ["b0"])
        // Done yesterday, scheduled only today: nothing at or before the done day.
        XCTAssertTrue(occurrencesCarryingTaskDone(plain(completedAt: "2026-09-21T11:00:00.000Z"), recurrence: .daily(until: nil),
                                                  blocks: [day("b1", today)], todayIso: today, nowISO: now).isEmpty)
        // Two slots on the day: both; a skipped or already-ticked one is left alone.
        let twins = occurrencesCarryingTaskDone(plain(), recurrence: .daily(until: nil),
                                                blocks: [day("b1", today), day("b2", today, at: "19:00"),
                                                         day("b3", today, done: true, at: "12:00"),
                                                         day("b4", today, skipped: true, at: "13:00")],
                                                todayIso: today, nowISO: now)
        XCTAssertEqual(Set(twins.map(\.id)), ["b1", "b2"])
    }

    func testAStamplessDoneCountsAsToday() {
        let carried = occurrencesCarryingTaskDone(plain(completedAt: nil), recurrence: .weekly(daysOfWeek: [2], until: nil),
                                                  blocks: [day("b1", today)], todayIso: today, nowISO: now)
        XCTAssertEqual(carried.map(\.completedAt), [now])
    }

    func testNothingCarriesForAnyOtherChange() {
        let blocks = [day("b1", today)]
        XCTAssertTrue(occurrencesCarryingTaskDone(plain(done: false), recurrence: .daily(until: nil), blocks: blocks,
                                                  todayIso: today, nowISO: now).isEmpty, "an open task has no tick")
        XCTAssertTrue(occurrencesCarryingTaskDone(plain(), recurrence: nil, blocks: blocks,
                                                  todayIso: today, nowISO: now).isEmpty, "no repeat turned on")
        XCTAssertTrue(occurrencesCarryingTaskDone(series(done: true, completedAt: "2026-09-22T11:00:00.000Z"),
                                                  recurrence: .weekly(daysOfWeek: [1], until: nil), blocks: blocks,
                                                  todayIso: today, nowISO: now).isEmpty, "one rule for another")
        XCTAssertTrue(occurrencesCarryingTaskDone(plain(), recurrence: .daily(until: nil), blocks: [day("b1", today, done: true)],
                                                  todayIso: today, nowISO: now).isEmpty, "a day already ticked")
        var other = day("x", today)
        other.taskId = "someone-else"
        XCTAssertTrue(occurrencesCarryingTaskDone(plain(), recurrence: .daily(until: nil), blocks: [other],
                                                  todayIso: today, nowISO: now).isEmpty)
    }
}
