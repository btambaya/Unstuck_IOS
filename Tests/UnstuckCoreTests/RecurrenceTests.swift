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

    /// Run again with nothing changed and the plan adds nothing; run it when
    /// the horizon has moved on and it only ADDS. (The launch-time top-up no
    /// longer uses this plan — see RecurrenceTopUpTests.)
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

// The post-plan decision behind scheduleTaskAt's guarantee on the chosen day,
// extracted as a pure helper. A block the plan is about to DELETE must NOT count
// as coverage (else the day silently ends up empty); a planned upsert DOES.
final class RecurrenceChosenDateActionTests: XCTestCase {
    private let iso = "2026-05-25"
    private let today = "2026-05-21"

    func testCoveredByPlannedUpsert() {
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: iso)], toDelete: [])
        XCTAssertEqual(recurrenceChosenDateAction(existing: [], plan: plan, iso: iso, startTime: "09:00"), .covered)
    }

    func testCoveredByExistingBlockNotBeingDeleted() {
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [], toDelete: [])
        XCTAssertEqual(recurrenceChosenDateAction(existing: existing, plan: plan, iso: iso, startTime: "09:00"), .covered)
    }

    func testExistingBlockBeingDeletedDoesNotCount() {
        // The only block on the chosen date is queued for deletion → NOT covered,
        // so the caller must mint a guarantee block (the bug this guards).
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [], toDelete: ["e1"])
        XCTAssertEqual(recurrenceChosenDateAction(existing: existing, plan: plan, iso: iso, startTime: "09:00"), .mint)
    }

    func testDeletedExistingButPlannedUpsertOnSameDateIsCovered() {
        // The old block is deleted but the plan re-adds one on the same date.
        let existing = [mkBlock(id: "e1", taskId: "t", date: iso)]
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: iso)], toDelete: ["e1"])
        XCTAssertEqual(recurrenceChosenDateAction(existing: existing, plan: plan, iso: iso, startTime: "09:00"), .covered)
    }

    func testNothingOnChosenDateIsNotCovered() {
        let existing = [mkBlock(id: "e1", taskId: "t", date: "2026-05-26")]
        let plan = RegenPlan(toUpsert: [mkBlock(id: "u1", taskId: "t", date: "2026-06-01")], toDelete: [])
        XCTAssertEqual(recurrenceChosenDateAction(existing: existing, plan: plan, iso: iso, startTime: "09:00"), .mint)
    }

    // MARK: audit 2026-09-22, C7 / core-scheduling#8

    /// regenerateForTask never touches today, so "schedule Walk today at 4pm"
    /// used to leave today's occurrence at 07:00 (it counted as covering).
    func testTodaysOpenOccurrenceAtAnotherTimeIsRetimed() {
        let t = mkTask(id: "t", name: "Walk")
        let walk = mkBlock(id: "walk", taskId: "t", startTime: "07:00", date: today)
        let plan = regenerateForTask(task: t, recurrence: .daily(until: nil), existingBlocks: [walk], todayIso: today,
                                     startTime: "16:00", startDate: Time.civil(2026, 5, 21), horizonDays: 7)
        XCTAssertFalse(plan.toDelete.contains("walk"), "regenerate never touches today")
        XCTAssertFalse(plan.toUpsert.contains { $0.date == today })
        XCTAssertEqual(recurrenceChosenDateAction(existing: [walk], plan: plan, iso: today, startTime: "16:00"), .retime(walk))
    }

    /// A skipped occurrence used to count as covering the day, so the day just
    /// scheduled stayed hidden. It is retimed; the caller un-skips it.
    func testASkippedOccurrenceNoLongerCoversItsDay() {
        var skipped = mkBlock(id: "skip", taskId: "t", startTime: "07:00", date: today)
        skipped.skipped = true
        let none = RegenPlan(toUpsert: [], toDelete: [])
        XCTAssertEqual(recurrenceChosenDateAction(existing: [skipped], plan: none, iso: today, startTime: "16:00"), .retime(skipped))
        // A future skipped block at the chosen time survives the plan (same key)
        // and is still retimed, i.e. un-skipped.
        var future = mkBlock(id: "fs", taskId: "t", startTime: "16:00", date: iso)
        future.skipped = true
        XCTAssertEqual(recurrenceChosenDateAction(existing: [future], plan: none, iso: iso, startTime: "16:00"), .retime(future))
    }

    /// A done occurrence covers its day — never an open second copy — but an
    /// open one beside it is the one that moves.
    func testADoneOccurrenceCoversTheDay() {
        var done = mkBlock(id: "done", taskId: "t", startTime: "07:00", date: today)
        done.done = true
        let none = RegenPlan(toUpsert: [], toDelete: [])
        XCTAssertEqual(recurrenceChosenDateAction(existing: [done], plan: none, iso: today, startTime: "16:00"), .covered)
        var early = mkBlock(id: "early", taskId: "t", startTime: "06:00", date: today)
        early.done = true
        let open = mkBlock(id: "open", taskId: "t", startTime: "07:00", date: today)
        XCTAssertEqual(recurrenceChosenDateAction(existing: [early, open], plan: none, iso: today, startTime: "16:00"), .retime(open))
    }

    /// Starting a series on a blockless task places today's occurrence
    /// (tasks-ui#5 / #11 end state): the plan only fills days after today.
    func testStartingASeriesTodayMintsTodaysOccurrence() {
        let t = mkTask(id: "t", name: "Stretch")
        let plan = regenerateForTask(task: t, recurrence: .daily(until: nil), existingBlocks: [], todayIso: today,
                                     startTime: "19:00", startDate: Time.civil(2026, 5, 21))
        XCTAssertTrue(plan.toUpsert.allSatisfy { $0.date > today })
        XCTAssertEqual(recurrenceChosenDateAction(existing: [], plan: plan, iso: today, startTime: "19:00"), .mint)
        // A timeless block on the day gets the chosen time instead of a twin.
        let timeless = mkBlock(id: "none", taskId: "t", startTime: "", date: today)
        XCTAssertEqual(recurrenceChosenDateAction(existing: [timeless], plan: plan, iso: today, startTime: "19:00"), .retime(timeless))
    }
}

// The create sheet's gate (audit 2026-09-22, C7 / tasks-ui#5): a series saved
// without a time had zero occurrences and showed only in Tasks → Recurring.
final class NewTaskNeedsTimeTests: XCTestCase {
    private let today = "2026-05-21"
    private let tomorrow = "2026-05-22"

    func testRepeatingTasksNeedADayAndATime() {
        XCTAssertTrue(newTaskNeedsTime(repeats: true, date: today, todayIso: today, pickedTime: nil))
        XCTAssertFalse(newTaskNeedsTime(repeats: true, date: today, todayIso: today, pickedTime: "19:00"))
        XCTAssertTrue(newTaskNeedsTime(repeats: true, date: nil, todayIso: today, pickedTime: nil), "Later + Repeat")
    }

    func testAOneOffNeedsATimeOnlyForALaterDay() {
        XCTAssertFalse(newTaskNeedsTime(repeats: false, date: today, todayIso: today, pickedTime: nil), "still added without a time")
        XCTAssertTrue(newTaskNeedsTime(repeats: false, date: tomorrow, todayIso: today, pickedTime: nil))
        XCTAssertFalse(newTaskNeedsTime(repeats: false, date: tomorrow, todayIso: today, pickedTime: "10:00"))
        XCTAssertFalse(newTaskNeedsTime(repeats: false, date: nil, todayIso: today, pickedTime: nil), "Later")
    }

    /// Why the evening reaches the gate: the free-slot finder stops at 18:00.
    func testTheEveningHasNoFreeSlotToAutoPick() {
        let evening = Time.civil(2026, 5, 21).addingTimeInterval(18.5 * 3600)
        XCTAssertTrue(findFreeSlotsForDate([], durationMin: 25, isoDate: today, now: evening).isEmpty)
    }
}

// The horizon top-up (audit 2026-09-22, C1): extend only the TAIL, at the
// series' own time. It used to rebuild the whole 8 weeks from the next open
// occurrence and add every missing date|time, so one moved occurrence copied
// the series (~55 duplicates) and every deleted one came back.
final class RecurrenceTopUpTests: XCTestCase {
    private let today = "2026-05-21"

    private func gym(_ recurrence: Recurrence? = .daily(until: nil), estimateMin: Int = 25) -> TaskItem {
        var t = mkTask(id: "gym", name: "Gym", estimateMin: estimateMin)
        t.recurrence = recurrence
        return t
    }
    private func day(_ offset: Int) -> String { LocalDate.addDays(today, offset) }
    private func occ(_ offset: Int, _ time: String = "07:00", done: Bool = false) -> CalBlock {
        var b = mkBlock(id: "g\(offset)", taskId: "gym", taskName: "Gym", startTime: time, date: day(offset))
        b.done = done
        return b
    }
    private func series(_ offsets: ClosedRange<Int>, _ time: String = "07:00") -> [CalBlock] {
        offsets.map { occ($0, time) }
    }
    private func slots(_ blocks: [CalBlock]) -> [String] { blocks.map { "\($0.date) \($0.startTime)" } }

    func testMovedNextOccurrenceNeverCopiesTheSeries() {
        // Today's Gym moved to 09:15 by the notification's Reschedule action.
        var blocks = series(0...55)
        blocks[0].startTime = "09:15"
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: today), [],
                       "a same-day relaunch adds nothing (was ~55 blocks at 09:15)")
        XCTAssertEqual(slots(recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: day(1))), ["\(day(56)) 07:00"],
                       "the next day extends the tail by one, at the series' time")
        // Today ticked, and TOMORROW's is the moved one (calendar#3).
        var other = series(0...55)
        other[0].done = true
        other[1].startTime = "18:00"
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: other, todayIso: today), [])
        XCTAssertEqual(slots(recurrenceTopUp(task: gym(), existingBlocks: other, todayIso: day(1))), ["\(day(56)) 07:00"])
    }

    func testDeletedAndMovedMidSeriesOccurrencesStayGone() {
        var blocks = series(0...55).filter { $0.date != day(10) }            // deleted
        blocks[blocks.firstIndex { $0.date == day(20) }!].startTime = "18:00"  // re-timed
        blocks[blocks.firstIndex { $0.date == day(30) }!].date = day(31)       // moved a day on
        XCTAssertEqual(slots(recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: day(1))), ["\(day(56)) 07:00"],
                       "nothing comes back on +10, +20 @ 07:00 or +30")
    }

    func testSeriesTimeIsTheCommonTimeNotTheNextOpenOne() {
        var moved = series(0...55)
        moved[0].startTime = "09:15"
        XCTAssertEqual(recurrenceSeriesTime(taskId: "gym", blocks: moved, frontierIso: day(55)), "07:00")
        // A whole-series re-plan to 08:00 isn't outvoted by older history.
        let replanned = series(-30...(-1)) + series(1...55, "08:00")
        XCTAssertEqual(recurrenceSeriesTime(taskId: "gym", blocks: replanned, frontierIso: day(55)), "08:00")
        // Monthly: one occurrence in the window each side of a move — history breaks the tie.
        let monthly = [occ(-66), occ(-35), occ(-5), occ(25, "09:00")]
        XCTAssertEqual(recurrenceSeriesTime(taskId: "gym", blocks: monthly, frontierIso: day(25)), "07:00")
        XCTAssertNil(recurrenceSeriesTime(taskId: "gym", blocks: [occ(1, "")], frontierIso: day(1)), "timeless only")
    }

    func testRevivesALapsedSeries() {
        // C95: a series idle for more than 8 weeks comes back from tomorrow.
        let history = series(-90...(-70), "07:30")
        let revived = recurrenceTopUp(task: gym(), existingBlocks: history, todayIso: today)
        XCTAssertEqual(revived.map(\.date), (1...55).map(day))
        XCTAssertTrue(revived.allSatisfy { $0.startTime == "07:30" })
        let weekly = recurrenceTopUp(task: gym(.weekly(daysOfWeek: [1, 3], until: nil)), existingBlocks: history, todayIso: today)
        XCTAssertFalse(weekly.isEmpty)
        XCTAssertTrue(weekly.allSatisfy { [1, 3].contains(LocalDate.dayOfWeek($0.date)) }, "Mondays and Wednesdays only")
    }

    func testFarMovedOccurrenceDoesNotFreezeTheSeries() {
        var blocks = series(0...55)
        blocks[5].date = day(90)
        XCTAssertEqual(slots(recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: day(1))), ["\(day(56)) 07:00"])
    }

    func testSeriesRePlannedBeyondTheHorizonIsLeftAlone() {
        let blocks = series(-10...(-1)) + series(70...80)
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: today), [])
    }

    func testUntilNilUnknownAndTimelessAddNothing() {
        let blocks = series(0...10)
        let capped = recurrenceTopUp(task: gym(.daily(until: day(30))), existingBlocks: blocks, todayIso: today)
        XCTAssertEqual(capped.map(\.date), (11...30).map(day), "nothing after until")
        XCTAssertEqual(recurrenceTopUp(task: gym(nil), existingBlocks: blocks, todayIso: today), [])
        XCTAssertEqual(recurrenceTopUp(task: gym(.daily(until: Recurrence.UNKNOWN_UNTIL)), existingBlocks: blocks, todayIso: today), [])
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: [occ(1, ""), occ(2, "")], todayIso: today), [])
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: [], todayIso: today), [], "a blockless series has no time")
    }

    func testTopUpIsIdempotentAndClamped() {
        let blocks = series(0...10)
        let added = recurrenceTopUp(task: gym(estimateMin: 2), existingBlocks: blocks, todayIso: today)
        XCTAssertEqual(added.map(\.date), (11...55).map(day))
        XCTAssertTrue(added.allSatisfy { $0.durationMinutes == 5 }, "a 2-minute task mints blocks the server accepts")
        XCTAssertTrue(added.allSatisfy { $0.taskId == "gym" && $0.kind == .task && $0.taskName == "Gym" })
        XCTAssertEqual(Set(added.map(\.id)).count, added.count)
        XCTAssertEqual(recurrenceTopUp(task: gym(), existingBlocks: blocks + added, todayIso: today), [], "idempotent")
    }

    func testExplicitSeriesTimeOverridesTheVote() {
        // A lapsed series re-placed at 19:00: the history's 07:00 must not win.
        let blocks = series(-29...(-1)) + [occ(1, "19:00")]
        let added = recurrenceTopUp(task: gym(), existingBlocks: blocks, todayIso: today, seriesTime: "19:00")
        XCTAssertEqual(added.map(\.date), (2...55).map(day))
        XCTAssertTrue(added.allSatisfy { $0.startTime == "19:00" })
        // Monthly: a lapsed series on the 15th re-placed on the 20th runs on the
        // 20th, as the placed time does (the history's day must not win either).
        let lapsed = ["2026-06-15", "2026-07-15", "2026-08-15"].map { mkBlock(id: $0, taskId: "gym", startTime: "07:00", date: $0) }
            + [mkBlock(id: "placed", taskId: "gym", startTime: "07:00", date: "2026-10-20")]
        XCTAssertEqual(recurrenceTopUp(task: gym(.monthly(until: nil)), existingBlocks: lapsed, todayIso: "2026-10-16",
                                       seriesTime: "07:00").map(\.date), ["2026-11-20"])
    }

    // Monthly day of month (C1 critic / C22): from the series, not the frontier.

    func testMonthlyCarriedOccurrenceDoesNotDoubleNextMonth() {
        // Sept 15th's occurrence carried to the 16th.
        let blocks = [mkBlock(id: "c", taskId: "gym", startTime: "07:00", date: "2026-09-16"),
                      mkBlock(id: "n", taskId: "gym", startTime: "07:00", date: "2026-10-15")]
        let monthly = gym(.monthly(until: nil))
        XCTAssertEqual(recurrenceTopUp(task: monthly, existingBlocks: blocks, todayIso: "2026-09-15"), [])
        XCTAssertEqual(recurrenceTopUp(task: monthly, existingBlocks: blocks, todayIso: "2026-09-21").map(\.date), ["2026-11-15"])
    }

    func testMonthlyMovedFrontierKeepsTheSeriesDay() {
        // The only upcoming occurrence (Oct 15) moved to Oct 20.
        let blocks = [mkBlock(id: "p", taskId: "gym", startTime: "07:00", date: "2026-09-15"),
                      mkBlock(id: "m", taskId: "gym", startTime: "07:00", date: "2026-10-20")]
        let monthly = gym(.monthly(until: nil))
        XCTAssertEqual(recurrenceTopUp(task: monthly, existingBlocks: blocks, todayIso: "2026-09-19"), [])
        XCTAssertEqual(recurrenceTopUp(task: monthly, existingBlocks: blocks, todayIso: "2026-10-16").map(\.date), ["2026-11-15"],
                       "not 11-20")
    }

    func testMonthlyThirtyFirstRecoversFromAClampedMonth() {
        let blocks = ["2026-01-31", "2026-02-28", "2026-03-31"].map {
            mkBlock(id: $0, taskId: "gym", startTime: "07:00", date: $0)
        }
        XCTAssertEqual(recurrenceTopUp(task: gym(.monthly(until: nil)), existingBlocks: blocks, todayIso: "2026-03-10").map(\.date),
                       ["2026-04-30"])
    }

    // A moved occurrence still owns its month (audit 2026-09-22, C1 review).

    /// The top-up run once a day from `from` through `to`, keeping what it adds.
    private func dailyTopUps(_ task: TaskItem, _ blocks: [CalBlock], from: String, to: String) -> [CalBlock] {
        var all = blocks
        var d = from
        while d <= to {
            all += recurrenceTopUp(task: task, existingBlocks: all, todayIso: d)
            d = LocalDate.addDays(d, 1)
        }
        return all
    }
    private func rentBlock(_ date: String, done: Bool = false) -> CalBlock {
        var b = mkBlock(id: date, taskId: "gym", startTime: "07:00", date: date)
        b.done = done
        return b
    }

    func testMonthlyRePlanToALaterDayMintsNoStrayOldDay() {
        // Rent on the 15th, re-planned on Oct 16 from Nov 15 to the 20th (or the
        // 30th) in the Schedule sheet: regenerate builds 8 weeks from the new
        // date, so its second occurrence lies past the horizon and the old vote
        // read [15, 15, 20] and minted Dec 15 next to Dec 20.
        let rent = gym(.monthly(until: nil))
        let cases: [(history: [String], day: Int, expected: [String])] = [
            (["2026-08-15", "2026-09-15", "2026-10-15"], 20, ["2026-11-20", "2026-12-20", "2027-01-20", "2027-02-20", "2027-03-20"]),
            (["2026-10-15"], 20, ["2026-11-20", "2026-12-20", "2027-01-20", "2027-02-20", "2027-03-20"]),
            (["2026-08-15", "2026-09-15", "2026-10-15"], 30, ["2026-11-30", "2026-12-30", "2027-01-30", "2027-02-28"]),
        ]
        for c in cases {
            var blocks = c.history.map { rentBlock($0, done: true) } + [rentBlock("2026-11-15")]
            let plan = regenerateForTask(task: rent, recurrence: rent.recurrence, existingBlocks: blocks, todayIso: "2026-10-16",
                                         startTime: "07:00", startDate: LocalDate.parse("2026-11-\(c.day)"))
            blocks = blocks.filter { !plan.toDelete.contains($0.id) } + plan.toUpsert
            let after = dailyTopUps(rent, blocks, from: "2026-10-16", to: "2027-01-31")
            XCTAssertEqual(after.map(\.date).filter { $0 > "2026-10-16" }.sorted(), c.expected, "re-planned to the \(c.day)th")
        }
    }

    func testMonthlyFrontierMovedEarlierDoesNotBringTheOldDateBack() {
        // On Oct 20 Nov 15 is the only upcoming occurrence; it is dragged to Nov 10.
        let rent = gym(.monthly(until: nil))
        let blocks = ["2026-08-15", "2026-09-15", "2026-10-15"].map { rentBlock($0, done: true) } + [rentBlock("2026-11-10")]
        XCTAssertEqual(recurrenceTopUp(task: rent, existingBlocks: blocks, todayIso: "2026-10-20"), [], "Nov 15 does not come back")
        let after = dailyTopUps(rent, blocks, from: "2026-10-20", to: "2027-01-31")
        XCTAssertEqual(after.map(\.date).filter { $0 > "2026-10-20" }.sorted(),
                       ["2026-11-10", "2026-12-15", "2027-01-15", "2027-02-15", "2027-03-15"], "the series keeps the 15th after it")
    }

    func testWeeklyFrontierMovedEarlierDoesNotBringTheOldDateBack() {
        // Mondays; the last one in the horizon dragged to the Saturday before.
        let mondays = gym(.weekly(daysOfWeek: [1], until: nil))
        var blocks = (0...55).filter { LocalDate.dayOfWeek(day($0)) == 1 }.map { occ($0) }
        let last = blocks.count - 1
        let lastMonday = blocks[last].date
        blocks[last].date = LocalDate.addDays(lastMonday, -2)
        XCTAssertEqual(recurrenceTopUp(task: mondays, existingBlocks: blocks, todayIso: today), [], "that Monday does not come back")
        let after = dailyTopUps(mondays, blocks, from: today, to: day(7))
        XCTAssertFalse(after.contains { $0.date == lastMonday })
        XCTAssertEqual(after.filter { $0.date > lastMonday }.map(\.date), [LocalDate.addDays(lastMonday, 7)], "the next week still comes")
    }
}

// Where a recurrence EDIT regenerates from (audit 2026-09-22, C1): the series'
// own time and day, never a one-off moved occurrence's.
final class RecurrenceEditStartTests: XCTestCase {
    private let today = "2026-05-21"
    private func day(_ offset: Int) -> String { LocalDate.addDays(today, offset) }

    func testASingleLiveOccurrenceStillSetsTheTimeOverHistory() {
        // The build-79 "Office every Monday at 11" fix must hold.
        var doneOld = mkBlock(id: "old", taskId: "task-1", startTime: "09:15", date: "2026-05-04")
        doneOld.done = true
        let next = mkBlock(id: "next", taskId: "task-1", startTime: "11:00", date: "2026-05-25")
        let start = recurrenceEditStart(taskId: "task-1", recurrence: .weekly(daysOfWeek: [1], until: nil),
                                        blocks: [doneOld, next], todayIso: today)
        XCTAssertEqual(start, RecurrenceStart(date: "2026-05-25", startTime: "11:00", horizonDays: 56))
        XCTAssertNil(recurrenceEditStart(taskId: "task-1", recurrence: .daily(until: nil), blocks: [], todayIso: today))
    }

    func testEditingTheEndDateNeverRebuildsTheSeriesAtAMovedTime() throws {
        let t = mkTask(id: "task-1", name: "Gym")
        var blocks = (1...55).map { mkBlock(id: "b\($0)", taskId: "task-1", startTime: "07:00", date: day($0)) }
        blocks[0].startTime = "18:00"   // tomorrow's moved by hand
        let rec = Recurrence.daily(until: day(90))
        let start = try XCTUnwrap(recurrenceEditStart(taskId: "task-1", recurrence: rec, blocks: blocks, todayIso: today))
        XCTAssertEqual(start.startTime, "07:00", "the series' time, not the moved one's")
        let plan = regenerateForTask(task: t, recurrence: rec, existingBlocks: blocks, todayIso: today,
                                     startTime: start.startTime, startDate: LocalDate.parse(start.date), horizonDays: start.horizonDays)
        let deleted = Set(plan.toDelete)
        XCTAssertFalse(blocks.contains { $0.startTime == "07:00" && deleted.contains($0.id) }, "nothing at 07:00 is deleted")
        XCTAssertFalse(plan.toUpsert.contains { $0.startTime != "07:00" })
    }

    func testMonthlyEditKeepsTheSeriesDayButAKindSwitchKeepsTheAnchors() {
        var history = ["2026-03-15", "2026-04-15", "2026-05-15"].map {
            mkBlock(id: $0, taskId: "task-1", startTime: "07:00", date: $0)
        }
        for i in history.indices { history[i].done = true }
        let carried = mkBlock(id: "carried", taskId: "task-1", startTime: "07:00", date: "2026-06-16")
        let next = mkBlock(id: "next", taskId: "task-1", startTime: "07:00", date: "2026-07-15")
        let start = recurrenceEditStart(taskId: "task-1", recurrence: .monthly(until: "2026-12-31"),
                                        blocks: history + [carried, next], todayIso: today)
        XCTAssertEqual(start?.date, "2026-06-15", "the 15th, not the carried occurrence's 16th")
        XCTAssertEqual(start?.horizonDays, 57, "the horizon still ends 8 weeks after the anchor")
        // Weekly Mondays switched to monthly: no day has two votes → the anchor's.
        let mondays = ["2026-05-25", "2026-06-01", "2026-06-08"].map {
            mkBlock(id: $0, taskId: "task-1", startTime: "09:00", date: $0)
        }
        XCTAssertEqual(recurrenceEditStart(taskId: "task-1", recurrence: .monthly(until: nil), blocks: mondays, todayIso: today)?.date,
                       "2026-05-25")
    }

    /// The plan an edit applies: regenerate from the start, minus `keepId`.
    private func editPlan(_ rec: Recurrence, _ blocks: [CalBlock], today: String) throws -> RegenPlan {
        var t = mkTask(id: "task-1", name: "Rent")
        t.recurrence = rec
        let start = try XCTUnwrap(recurrenceEditStart(taskId: "task-1", recurrence: rec, blocks: blocks, todayIso: today))
        var plan = regenerateForTask(task: t, recurrence: rec, existingBlocks: blocks, todayIso: today, startTime: start.startTime,
                                     startDate: LocalDate.parse(start.date), horizonDays: start.horizonDays)
        plan.toDelete.removeAll { $0 == start.keepId }
        return plan
    }
    private func rent(_ date: String, _ time: String = "07:00", done: Bool = false) -> CalBlock {
        var b = mkBlock(id: date, taskId: "task-1", startTime: time, date: date)
        b.done = done
        return b
    }

    func testMonthlyEditKeepsThisMonthsOccurrenceMovedOffAPassedDay() throws {
        // Oct 15's rent pushed to Oct 20 at 18:00; on Oct 16 only the end date
        // changes. The start is Oct 15 (passed), so regenerate wanted nothing in
        // October and deleted Oct 20: the month lost its occurrence.
        let blocks = [rent("2026-08-15", done: true), rent("2026-09-15", done: true), rent("2026-10-20", "18:00"), rent("2026-11-15")]
        let plan = try editPlan(.monthly(until: "2027-06-30"), blocks, today: "2026-10-16")
        XCTAssertEqual(plan, RegenPlan(toUpsert: [], toDelete: []), "Oct 20 stays; Nov 15 stays")
        // An end date before it ends the series there: nothing is kept.
        XCTAssertEqual(Set(try editPlan(.monthly(until: "2026-10-18"), blocks, today: "2026-10-16").toDelete),
                       ["2026-10-20", "2026-11-15"])
    }

    func testMonthlyEditStillRealignsNextMonthsOccurrenceMovedEarlier() throws {
        // Nov 15 dragged to Nov 10 is next month's, not October's: an explicit
        // edit puts it back on the series day, as regenerate does everywhere.
        let blocks = [rent("2026-08-15", done: true), rent("2026-09-15", done: true), rent("2026-10-15", done: true), rent("2026-11-10")]
        let plan = try editPlan(.monthly(until: nil), blocks, today: "2026-10-16")
        XCTAssertEqual(plan.toDelete, ["2026-11-10"])
        XCTAssertEqual(plan.toUpsert.map(\.date), ["2026-11-15", "2026-12-15"])
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

// Stage 2 — "same id for same day" (audit 2026-09-22 C21; the rules are in
// audit/parity-2026-09-23/deterministic-occurrence-ids.md §3). Every occurrence
// a series mints carries occurrenceId(task, date), so the pure plans must never
// mint an id a kept row holds (rule A), never delete and mint the same id
// (rule B), never count a row the plan moves as the chosen day's (rule B′), and
// the chosen day's own write follows §3b′.
final class DeterministicOccurrenceTests: XCTestCase {
    private let taskId = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
    private let today = "2026-09-23"

    private func series(_ recurrence: Recurrence, estimateMin: Int = 30) -> TaskItem {
        var t = mkTask(id: taskId, name: "Gym", estimateMin: estimateMin)
        t.recurrence = recurrence
        return t
    }
    private func day(_ offset: Int) -> String { LocalDate.addDays(today, offset) }
    /// The occurrence minted FOR `date`, sitting on `on` (moved when they differ).
    private func occ(_ date: String, on: String? = nil, _ time: String = "07:00", done: Bool = false,
                     event: String? = nil) -> CalBlock {
        var b = mkBlock(id: occurrenceId(taskId: taskId, date: date), taskId: taskId, taskName: "Gym",
                        startTime: time, durationMinutes: 30, date: on ?? date, kind: .task)
        b.done = done
        b.completedAt = done ? "2026-09-23T08:00:00.000Z" : nil
        b.externalEventId = event
        return b
    }
    private func ids(_ p: RegenPlan) -> [String] { p.toUpsert.map(\.id) + p.toRetime.map(\.id) + p.toDelete }

    func testRegenerateMintsDeterministicIds() {
        let t = series(.weekly(daysOfWeek: [1, 3], until: nil))
        let plan = regenerateForTask(task: t, recurrence: t.recurrence, existingBlocks: [], todayIso: today,
                                     startTime: "07:00", startDate: LocalDate.parse(today))
        XCTAssertFalse(plan.toUpsert.isEmpty)
        for b in plan.toUpsert {
            XCTAssertEqual(b.id, occurrenceId(taskId: t.id, date: b.date))
        }
        XCTAssertTrue(plan.toRetime.isEmpty)
        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    /// Rule B: 07:00 → 09:00. Each future day's row is rewritten IN PLACE —
    /// never deleted and minted again with the same id (iOS's own callers
    /// cancelled that mint with the delete, and the day was lost).
    func testRegenerateTimeChangeRewritesInPlace() {
        let t = series(.daily(until: nil))
        var blocks = (1...55).map { occ(day($0), event: $0 % 2 == 0 ? "evt\($0)" : nil) }
        blocks[4].done = true   // a future day ticked early comes back open, as delete + mint did
        blocks.append(occ(day(-1), done: true))   // history is never touched
        let plan = regenerateForTask(task: t, recurrence: t.recurrence, existingBlocks: blocks, todayIso: today,
                                     startTime: "09:00", startDate: LocalDate.parse(day(1)))
        let retimed = Dictionary(uniqueKeysWithValues: plan.toRetime.map { ($0.id, $0) })
        for o in 1...55 {
            let id = occurrenceId(taskId: t.id, date: day(o))
            XCTAssertEqual(retimed[id]?.date, day(o))
            XCTAssertEqual(retimed[id]?.startTime, "09:00")
            XCTAssertEqual(retimed[id]?.done, false)
            XCTAssertNil(retimed[id]?.completedAt)
            XCTAssertEqual(retimed[id]?.externalEventId, o % 2 == 0 ? "evt\(o)" : nil, "the Google mapping is kept")
            XCTAssertFalse(plan.toDelete.contains(id), "day \(o) is not deleted")
            XCTAssertFalse(plan.toUpsert.contains { $0.id == id }, "day \(o) is not minted again")
        }
        XCTAssertEqual(plan.toUpsert.map(\.date), [day(56)], "only the day nobody had is minted")
        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertEqual(Set(ids(plan)).count, ids(plan).count, "the three lists are disjoint")
    }

    /// Rule A: id(D) sits on E (still desired there, same time). D is not
    /// minted — the day's occurrence lives on, moved.
    func testRegenerateSkipsIdHeldByMovedOccurrence() {
        let t = series(.daily(until: nil))
        var blocks = (1...10).filter { $0 != 3 && $0 != 5 }.map { occ(day($0)) }
        blocks.append(occ(day(3), on: day(5)))   // D = +3 moved to E = +5 (E's own was deleted)
        let plan = regenerateForTask(task: t, recurrence: t.recurrence, existingBlocks: blocks, todayIso: today,
                                     startTime: "07:00", startDate: LocalDate.parse(day(1)), horizonDays: 10)
        XCTAssertEqual(plan, RegenPlan(toUpsert: [], toDelete: []), "no block is minted for D, nothing moves")
    }

    /// Rule A in the top-up: id(D) was moved before the frontier, outside
    /// occurrenceReach (daily: 0 days). The tail mint for D is dropped.
    func testTopUpSkipsIdHeldByMovedOccurrence() {
        let t = series(.daily(until: nil))
        var blocks = (1...52).map { occ(day($0)) }
        blocks.append(occ(day(54), on: day(10), "18:00"))
        let tail = recurrenceTopUp(task: t, existingBlocks: blocks, todayIso: today)
        XCTAssertEqual(tail.map(\.date), [day(53), day(55)], "+54's occurrence lives on at +10")
        XCTAssertEqual(tail.map(\.id), [occurrenceId(taskId: t.id, date: day(53)), occurrenceId(taskId: t.id, date: day(55))])
    }

    func testTopUpIdsAreDeterministic() {
        let t = series(.weekly(daysOfWeek: [1, 3, 5], until: nil))
        let blocks = (1...20).map { day($0) }.filter { [1, 3, 5].contains(LocalDate.dayOfWeek($0)) }.map { occ($0) }
        let a = recurrenceTopUp(task: t, existingBlocks: blocks, todayIso: today)
        let b = recurrenceTopUp(task: t, existingBlocks: blocks, todayIso: today)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "two devices topping up the same store mint the same ids")
        XCTAssertTrue(a.allSatisfy { $0.id == occurrenceId(taskId: t.id, date: $0.date) })
    }

    /// The kept row (`RecurrenceStart.keepId`) goes INTO the plan: it is in
    /// none of the three lists, and the day whose id it carries is not minted.
    func testKeepIdNeverCollidesWithAMint() throws {
        // (a) The C1 fixture: Oct 15's rent pushed to Oct 20 18:00; on Oct 16
        // only the end date changes.
        let rent = series(.monthly(until: "2027-06-30"))
        let a = [occ("2026-08-15", done: true), occ("2026-09-15", done: true),
                 occ("2026-10-15", on: "2026-10-20", "18:00"), occ("2026-11-15")]
        let startA = try XCTUnwrap(recurrenceEditStart(taskId: taskId, recurrence: rent.recurrence, blocks: a, todayIso: "2026-10-16"))
        let keptA = try XCTUnwrap(startA.keepId)
        XCTAssertEqual(keptA, occurrenceId(taskId: taskId, date: "2026-10-15"))
        let planA = regenerateForTask(task: rent, recurrence: rent.recurrence, existingBlocks: a, todayIso: "2026-10-16",
                                      startTime: startA.startTime, startDate: LocalDate.parse(startA.date),
                                      horizonDays: startA.horizonDays, keepIds: [keptA])
        XCTAssertFalse(ids(planA).contains(keptA))
        XCTAssertEqual(planA, RegenPlan(toUpsert: [], toDelete: []))

        // (b) The monthly series on the 15th, today Sep 20: NEXT month's
        // occurrence id(Oct 15) dragged earlier to Sep 25 is within 14 days of
        // the passed Sep 15, so keepId == id(Oct 15). Without keepIds in the
        // plan, rule B would move the kept block back to Oct 15.
        let monthly = series(.monthly(until: nil))
        let b = [occ("2026-07-15", done: true), occ("2026-08-15", done: true), occ("2026-09-15", done: true),
                 occ("2026-10-15", on: "2026-09-25"), occ("2026-11-15")]
        let startB = try XCTUnwrap(recurrenceEditStart(taskId: taskId, recurrence: monthly.recurrence, blocks: b, todayIso: "2026-09-20"))
        let keptB = try XCTUnwrap(startB.keepId)
        XCTAssertEqual(keptB, occurrenceId(taskId: taskId, date: "2026-10-15"))
        let planB = regenerateForTask(task: monthly, recurrence: monthly.recurrence, existingBlocks: b, todayIso: "2026-09-20",
                                      startTime: startB.startTime, startDate: LocalDate.parse(startB.date),
                                      horizonDays: startB.horizonDays, keepIds: [keptB])
        XCTAssertFalse(ids(planB).contains(keptB), "the kept row is in none of the lists")
        XCTAssertFalse(planB.toUpsert.contains { $0.date == "2026-10-15" }, "Oct 15 is not minted: its occurrence lives on")
        XCTAssertFalse(planB.toRetime.contains { $0.id == keptB }, "the Sep 25 block stays where the user put it")
        // Filtering afterwards (the old callers) cannot undo the rewrite.
        let unkept = regenerateForTask(task: monthly, recurrence: monthly.recurrence, existingBlocks: b, todayIso: "2026-09-20",
                                       startTime: startB.startTime, startDate: LocalDate.parse(startB.date),
                                       horizonDays: startB.horizonDays)
        XCTAssertTrue(unkept.toRetime.contains { $0.id == keptB && $0.date == "2026-10-15" },
                      "the trap keepIds closes")
    }

    /// Rule B′, the exact example: weekly Mon/Wed at 07:00, today Tue Sep 29;
    /// Wed Oct 7's occurrence was moved to Fri Oct 2, then the series is
    /// scheduled on Fri Oct 2 at 09:00. The plan moves id(Oct 7) home; Oct 2
    /// gets its own mint; no id is written twice.
    func testChosenDateIgnoresRowTheRetimeMovesAway() {
        let t = series(.weekly(daysOfWeek: [1, 3], until: nil))
        let today = "2026-09-29"
        let dates = (1...56).map { LocalDate.addDays(today, $0) }.filter { [1, 3].contains(LocalDate.dayOfWeek($0)) }
        let existing = dates.map { $0 == "2026-10-07" ? occ($0, on: "2026-10-02") : occ($0) }
        let plan0 = regenerateForTask(task: t, recurrence: t.recurrence, existingBlocks: existing, todayIso: today,
                                      startTime: "09:00", startDate: LocalDate.parse("2026-10-02"))
        let oct7 = occurrenceId(taskId: taskId, date: "2026-10-07")
        XCTAssertEqual(plan0.toRetime.first { $0.id == oct7 }?.date, "2026-10-07", "moved home, at the new time")
        XCTAssertEqual(recurrenceChosenDateAction(existing: existing, plan: plan0, iso: "2026-10-02", startTime: "09:00"), .mint,
                       "the row the plan moves away is not Oct 2's occurrence")
        let (plan, write) = recurrenceChosenDateWrite(task: t, existing: existing, plan: plan0, iso: "2026-10-02", startTime: "09:00")
        guard case .insert(let minted) = write else { return XCTFail("expected a mint, got \(write)") }
        XCTAssertEqual(minted.id, occurrenceId(taskId: taskId, date: "2026-10-02"))
        XCTAssertEqual(minted.date, "2026-10-02")
        XCTAssertEqual(minted.startTime, "09:00")
        let written = ids(plan) + [minted.id]
        XCTAssertEqual(Set(written).count, written.count, "no id is written twice")
    }

    /// §3b′ case by case.
    func testChosenDateWrite() {
        let t = series(.weekly(daysOfWeek: [1, 3], until: nil), estimateMin: 2)
        let d = "2026-10-02"
        let idD = occurrenceId(taskId: taskId, date: d)
        let none = RegenPlan(toUpsert: [], toDelete: [])

        // .covered → nothing.
        let covering = occ(d, "09:00")
        XCTAssertEqual(recurrenceChosenDateWrite(task: t, existing: [covering], plan: none, iso: d, startTime: "09:00").1, .none)

        // .retime → the day's row at the time, un-skipped.
        var skipped = occ(d, "07:00")
        skipped.skipped = true
        var expected = skipped
        expected.startTime = "09:00"
        expected.skipped = false
        XCTAssertEqual(recurrenceChosenDateWrite(task: t, existing: [skipped], plan: none, iso: d, startTime: "09:00").1,
                       .upsert(expected))

        // .mint with the day's id in toDelete → that row, taken out of the
        // delete and rewritten in place: it keeps its Google mapping.
        let doomed = occ(d, "07:00", done: true, event: "evt-d")
        let (planA, writeA) = recurrenceChosenDateWrite(task: t, existing: [doomed], plan: RegenPlan(toUpsert: [], toDelete: [idD]),
                                                        iso: d, startTime: "09:00")
        XCTAssertEqual(planA.toDelete, [], "no longer deleted")
        guard case .upsert(let rewritten) = writeA else { return XCTFail("expected an upsert, got \(writeA)") }
        XCTAssertEqual(rewritten.id, idD)
        XCTAssertEqual(rewritten.externalEventId, "evt-d", "built from the existing row, never a fresh one")
        XCTAssertEqual(rewritten.startTime, "09:00")
        XCTAssertEqual(rewritten.durationMinutes, 5, "clamped to the server's 5…1440")
        XCTAssertFalse(rewritten.done)
        XCTAssertNil(rewritten.completedAt)

        // .mint with the id held elsewhere (moved) → a RANDOM-id block; the
        // surviving row is never taken over.
        let moved = occ(d, on: "2026-10-05")
        let (planB, writeB) = recurrenceChosenDateWrite(task: t, existing: [moved], plan: none, iso: d, startTime: "09:00")
        XCTAssertEqual(planB, none)
        guard case .upsert(let extra) = writeB else { return XCTFail("expected an upsert, got \(writeB)") }
        XCTAssertNotEqual(extra.id, idD)
        XCTAssertTrue(isUUID(extra.id))
        XCTAssertEqual(extra.date, d)
        XCTAssertEqual(extra.startTime, "09:00")

        // .mint with nothing held → the deterministic insert.
        let (planC, writeC) = recurrenceChosenDateWrite(task: t, existing: [], plan: none, iso: d, startTime: "09:00")
        XCTAssertEqual(planC, none)
        XCTAssertEqual(writeC, .insert(CalBlock(id: idD, taskId: taskId, taskName: "Gym", startTime: "09:00",
                                                durationMinutes: 5, date: d, kind: .task)))
    }

    /// A rewritten row covers the chosen day by its NEW date.
    func testChosenDateActionCountsRetimeAsCoverage() {
        let d = "2026-10-07"
        let moved = occ(d, on: "2026-10-02")
        var home = moved
        home.date = d
        home.startTime = "09:00"
        let plan = RegenPlan(toUpsert: [], toDelete: [], toRetime: [home])
        XCTAssertEqual(recurrenceChosenDateAction(existing: [moved], plan: plan, iso: d, startTime: "09:00"), .covered)
        XCTAssertEqual(recurrenceChosenDateAction(existing: [moved], plan: plan, iso: "2026-10-02", startTime: "09:00"), .mint,
                       "and never covers the day it is leaving")
    }
}
