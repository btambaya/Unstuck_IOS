// Ported from lib/assistant/insights-read.test.ts — the synthetic week,
// number for number. Local construction throughout; the suite runs TZ=UTC.

import XCTest
@testable import UnstuckCore

private let AUG = 8
private let SEP = 9

// Wed 2 Sep 2026, 18:00 local → the 'week' window is Mon 31 Aug 00:00 → now.
private let FIXED_NOW: Date = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Time.civil(2026, 9, 2))!
private let NOW_MS: EpochMillis = FIXED_NOW.timeIntervalSince1970 * 1000
private func ago(_ days: Double) -> String { iso(NOW_MS - days * DAY_MS) }

nonisolated(unsafe) private var seq = 0
private func nextSeq() -> Int { seq += 1; return seq }

private func task(_ id: String, _ name: String, estimateMin: Int = 30, done: Bool = false, moveCount: Int? = nil,
                  createdAt: String? = nil, lifeArea: String? = nil) -> TaskItem {
    TaskItem(id: id, name: name, estimateMin: estimateMin, totalFocused: 0, done: done, lifeArea: lifeArea,
             moveCount: moveCount, createdAt: createdAt ?? ago(3), updatedAt: ago(3))
}

/// A session on `t` STARTING at the local month/day/hour/minute, ending actualSec later.
private func sess(_ t: TaskItem, _ month: Int, _ day: Int, _ hour: Int, _ min: Int, _ actualSec: Int, _ id: String? = nil) -> Session {
    let start = Calendar.current.date(bySettingHour: hour, minute: min, second: 0, of: Time.civil(2026, month, day))!
    let end = start.timeIntervalSince1970 * 1000 + Double(actualSec) * 1000
    return Session(id: id ?? "s\(nextSeq())", taskId: t.id, taskName: t.name, estimateMin: t.estimateMin,
                   actualSec: actualSec, completedAt: iso(end))
}

private func log(_ reason: String, _ month: Int, _ day: Int, _ hour: Int, _ min: Int,
                 action: ReasonAction = .pause, durationSec: Int? = nil) -> ReasonLog {
    let at = Calendar.current.date(bySettingHour: hour, minute: min, second: 0, of: Time.civil(2026, month, day))!
    return ReasonLog(id: "r\(nextSeq())", reason: reason, action: action, at: iso(at.timeIntervalSince1970 * 1000), durationSec: durationSec)
}

private func capture(_ tag: CaptureTag, _ month: Int, _ day: Int, _ hour: Int, _ min: Int, _ sessionId: String? = nil) -> Capture {
    let at = Calendar.current.date(bySettingHour: hour, minute: min, second: 0, of: Time.civil(2026, month, day))!
    return Capture(id: "c\(nextSeq())", sessionId: sessionId, tag: tag, body: "note", at: iso(at.timeIntervalSince1970 * 1000))
}

private func block(_ date: String, _ durationMinutes: Int, taskId: String? = "a", taskName: String = "Write report",
                   kind: CalBlockKind? = nil, externalEventId: String? = nil, skipped: Bool = false) -> CalBlock {
    CalBlock(id: "b\(nextSeq())", taskId: taskId, taskName: taskName, startTime: "09:00", durationMinutes: durationMinutes,
             date: date, externalEventId: externalEventId, kind: kind, skipped: skipped)
}

private struct Data {
    var tasks: [TaskItem] = []
    var sessions: [Session] = []
    var captures: [Capture] = []
    var reasons: [ReasonLog] = []
    var blocks: [CalBlock] = []
    var now: Date = FIXED_NOW
}

private func render(_ d: Data = Data(), _ window: InsightsWindow = .week) -> String {
    renderInsights(tasks: d.tasks, sessions: d.sessions, captures: d.captures, reasons: d.reasons,
                   blocks: d.blocks, now: d.now, window: window)
}

// ---- the synthetic week ----------------------------------------------------

private let writeReport = task("a", "Write report", lifeArea: "Work")
private let gym = task("b", "Gym", estimateMin: 20, lifeArea: "Health")
private let taxReturn = task("c", "Tax return", estimateMin: 60, moveCount: 4, createdAt: ago(10))
private let dentist = task("d", "Dentist", done: true, moveCount: 5, createdAt: ago(40))
private let TASKS = [writeReport, gym, taxReturn, dentist]

// estimate → actual: 30→30 hit, 30→45 over, 30→10 under, 20→20 hit, 20→60 over.
private let s1 = sess(writeReport, AUG, 31, 9, 0, 1800, "s1")      // Mon, ends 09:30
private let s2 = sess(writeReport, SEP, 1, 9, 0, 2700, "s2")       // Tue, ends 09:45
private let s5 = sess(writeReport, SEP, 1, 9, 48, 600, "s5")       // Tue, 3-min re-entry, ends 09:58
private let s3 = sess(gym, SEP, 1, 14, 0, 1200, "s3")              // Tue, ends 14:20
private let s4 = sess(gym, SEP, 2, 10, 0, 3600, "s4")              // Wed, ends 11:00
private let SESSIONS = [s1, s2, s3, s4, s5]

private let REASONS = [
    log("phone call", SEP, 1, 10, 0, durationSec: 300),
    log("phone call", SEP, 2, 11, 0, durationSec: 420),
    log("snack", SEP, 1, 14, 5, durationSec: 180),
    log("email", AUG, 31, 9, 10, action: .switch),        // legacy row: no duration
]

private let CAPTURES = [
    capture(.distraction, SEP, 2, 10, 7, "s4"),           // 7 min into s4
    capture(.followUp, SEP, 1, 9, 8, "s2"),               // 8 min into s2
    capture(.idea, SEP, 1, 16, 0),                        // not tied to a session
]

private let BLOCKS = [
    block("2026-09-01", 60),
    block("2026-09-02", 30, taskId: "b", taskName: "Gym"),
    block("2026-08-28", 45),                              // before Monday
    block("2026-09-03", 30),                              // tomorrow
    block("2026-09-01", 60, kind: .external, externalEventId: "ev1"),
    block("2026-09-02", 15, skipped: true),
]

private let WEEK = Data(tasks: TASKS, sessions: SESSIONS, captures: CAPTURES, reasons: REASONS, blocks: BLOCKS)

final class InsightsReadSyntheticWeekTests: XCTestCase {
    func testRendersTheKnownReport() {
        XCTAssertEqual(render(WEEK), [
            "ok: Insights, week so far (Mon 31 Aug – Wed 2 Sep).",
            "Focus: 2h 45m across 5 sessions, median 30m.",
            "By area: Work 1.4h, Health 1.3h.",
            "Peak slot: Wed 10–11am (60 min).",
            "Estimates: 40% of 5 estimated sessions landed within 5 min; 2 ran over, 1 ran under; actual vs estimate averages +7 min. Verdict: underestimating (things take longer than you plan).",
            "Pauses: 4 reasons logged; top: phone call 2x (12m), snack 1x (3m), email 1x.",
            "Coming back: 1 of 3 timed pauses ended within 5 min.",
            "Slipping: 1 task — \"Tax return\" (moved 4x, 1wk on list).",
            "Captures: 3 — follow-up 1, idea 1, distraction 1.",
            "Planned: 2 calendar blocks (1h 30m) dated in this window.",
            "Worth noticing:",
            "- Tuesdays are your strongest day. 75 focused minutes — more than any other day this window. Stack harder work here.",
            "- Estimates within 5 min 40% of the time. 5 recent sessions tracked — estimates are still settling. The calibration card shows where outliers landed.",
            "- \"Tax return\" keeps slipping. rescheduled 4 times. Remove it, or break it down differently?",
        ].joined(separator: "\n"))
    }

    func testIsPlainTextWithinBudgetNoMarkdownNoNaNLeaks() {
        let out = render(WEEK)
        XCTAssertTrue(out.hasPrefix("ok:"))
        XCTAssertLessThanOrEqual(out.count, INSIGHTS_MAX_CHARS)
        XCTAssertFalse(out.contains("**"))
        XCTAssertFalse(out.contains("\n#"))
        XCTAssertFalse(out.contains("nan"))
        XCTAssertFalse(out.contains("nil"))
    }
}

final class InsightsReadEmptyDataTests: XCTestCase {
    func testSaysSoInOneLinePerSectionNothingFabricated() {
        XCTAssertEqual(render(), [
            "ok: Insights, week so far (Mon 31 Aug – Wed 2 Sep).",
            "Focus: no focus sessions in this window.",
            "Pauses: none logged in this window.",
            "Slipping: none.",
            "Captures: none.",
        ].joined(separator: "\n"))
    }

    func testSessionsWithNoTaskLinkGetAnHonestEstimatesLine() {
        let orphan = Session(id: "x", taskName: "Ad hoc", actualSec: 900, completedAt: ago(1))
        let out = render(Data(sessions: [orphan]))
        XCTAssertTrue(out.contains("Focus: 15m across 1 session, median 15m."))
        XCTAssertTrue(out.contains("Estimates: no sessions linked to an estimated task yet."))
        XCTAssertFalse(out.contains("Re-entry"))
        XCTAssertFalse(out.contains("Worth noticing"))
    }
}

final class InsightsReadWindowTests: XCTestCase {
    // Sat 29 Aug: before this week's Monday AND before the 1st of September.
    private let saturday = sess(writeReport, AUG, 29, 10, 0, 1800, "sat")
    private let oldLog = log("old thing", AUG, 20, 9, 0, durationSec: 600)
    private var data: Data {
        var d = WEEK
        d.sessions = SESSIONS + [saturday]
        d.reasons = REASONS + [oldLog]
        return d
    }

    func testWeekExcludesASessionAndAReasonLogFromLastSaturday() {
        let out = render(data, .week)
        XCTAssertTrue(out.contains("Focus: 2h 45m across 5 sessions"))
        XCTAssertTrue(out.contains("Pauses: 4 reasons logged"))
        XCTAssertFalse(out.contains("old thing"))
    }

    func testMonthExcludesThemToo() {
        let out = render(data, .month)
        XCTAssertTrue(out.contains("ok: Insights, month so far (Tue 1 Sep – Wed 2 Sep)."))
        // Monday 31 Aug is still August → its session AND its reason log drop
        // out of the month window along with Saturday's.
        XCTAssertTrue(out.contains("Focus: 2h 15m across 4 sessions"))
        XCTAssertTrue(out.contains("Pauses: 3 reasons logged"))
        XCTAssertFalse(out.contains("email"))
        XCTAssertFalse(out.contains("old thing"))
    }

    func testAllIncludesEverythingAndCountsEveryBlockUpToToday() {
        let out = render(data, .all)
        XCTAssertTrue(out.contains("ok: Insights, all time (to Wed 2 Sep)."))
        XCTAssertTrue(out.contains("Focus: 3h 15m across 6 sessions"))
        // pauseAnatomy orders by real minutes, then count.
        XCTAssertTrue(out.contains("Pauses: 5 reasons logged; top: phone call 2x (12m), old thing 1x (10m), snack 1x (3m)."))
        XCTAssertTrue(out.contains("Planned: 3 calendar blocks (2h 15m)"))
    }
}

final class InsightsReadSlippingTests: XCTestCase {
    func testSurfacesMoveCountAndAgeSkipsDoneTasksAndTwoMoves() {
        let tasks = [
            task("x", "Renew passport", moveCount: 3, createdAt: ago(1)),
            task("y", "Water plants", moveCount: 2, createdAt: ago(1)),
            task("z", "Old but done", done: true, moveCount: 6, createdAt: ago(60)),
            task("w", "Sort the garage", createdAt: ago(30)),
        ]
        let out = render(Data(tasks: tasks))
        XCTAssertTrue(out.contains("Slipping: 2 tasks — \"Renew passport\" (moved 3x, 0wk on list); \"Sort the garage\" (moved 0x, 4wk on list)."), out)
        XCTAssertFalse(out.contains("Water plants"))
        XCTAssertFalse(out.contains("Old but done"))
        // The narrative card names the worst offender even with zero sessions.
        XCTAssertTrue(out.contains("- \"Renew passport\" keeps slipping. rescheduled 3 times."))
    }

    func testListsAtMostFiveNamesAndCountsTheRest() {
        let tasks = (0..<8).map { i in task("t\(i)", "Chore \(i)", moveCount: 3 + i, createdAt: ago(1)) }
        let out = render(Data(tasks: tasks))
        // slipping() returns the full list — the same true count the Report card shows.
        XCTAssertTrue(out.contains("Slipping: 8 tasks — \"Chore 7\" (moved 10x, 0wk on list); \"Chore 6\""), out)
        XCTAssertTrue(out.contains("\"Chore 3\" (moved 6x, 0wk on list) +3 more."), out)
        XCTAssertFalse(out.contains("\"Chore 2\""))
    }
}

final class InsightsReadCalibrationVerdictTests: XCTestCase {
    func testOverestimatingWhenSessionsKeepFinishingEarly() {
        let t = task("a", "Write report")
        let sessions = [
            sess(t, SEP, 1, 9, 0, 600),   // 30 → 10
            sess(t, SEP, 1, 11, 0, 900),  // 30 → 15
            sess(t, SEP, 2, 9, 0, 1800),  // 30 → 30
        ]
        let out = render(Data(tasks: [t], sessions: sessions))
        XCTAssertTrue(out.contains("Estimates: 33% of 3 estimated sessions landed within 5 min; 0 ran over, 2 ran under; actual vs estimate averages -12 min. Verdict: overestimating (things finish sooner than you plan)."), out)
    }

    func testAboutRightWhenMissesAreFewAndBalanced() {
        let t = task("a", "Write report")
        let sessions = [
            sess(t, SEP, 1, 9, 0, 1800),
            sess(t, SEP, 1, 11, 0, 1980),  // +3, inside slack
            sess(t, SEP, 2, 9, 0, 1620),   // −3, inside slack
            sess(t, SEP, 2, 12, 0, 2400),  // +10, the lone miss
        ]
        let out = render(Data(tasks: [t], sessions: sessions))
        // mean delta (0 + 3 − 3 + 10) / 4 = 2.5 → rounds to +3
        XCTAssertTrue(out.contains("75% of 4 estimated sessions landed within 5 min; 1 ran over, 0 ran under; actual vs estimate averages +3 min. Verdict: about right."), out)
    }
}

final class InsightsReadDatesAndBudgetTests: XCTestCase {
    func testBlockDatesCompareAsLocalCalendarDaysEvenLateAtNight() {
        let lateNight = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Time.civil(2026, 9, 2))!
        let out = render(Data(blocks: [block("2026-09-02", 45), block("2026-09-03", 45)], now: lateNight))
        XCTAssertTrue(out.contains("Planned: 1 calendar block (45m) dated in this window."), out)
    }

    func testStaysUnderTheCapWithLongNamesDroppingInsightDetailFirst() {
        let longName = "A truly enormous task name that keeps going and going well past forty characters"
        let tasks = (0..<6).map { i in task("t\(i)", "\(longName) \(i)", moveCount: 3, createdAt: ago(1)) }
        var d = WEEK
        d.tasks = TASKS + tasks
        let out = render(d)
        XCTAssertLessThanOrEqual(out.count, INSIGHTS_MAX_CHARS)
        XCTAssertTrue(out.hasPrefix("ok:"))
        XCTAssertTrue(out.contains("\"A truly enormous task name that keeps g…\""), out)
        // Titles survive; the sub-lines were the first thing to go.
        XCTAssertTrue(out.contains("- Tuesdays are your strongest day."))
        XCTAssertFalse(out.contains("Stack harder work here."))
    }
}

final class InsightsReadAlignedDefinitionsTests: XCTestCase {
    func testRepeatingTemplatesAndLaterTasksAreNotSlips() {
        var template = task("r", "Stretch", createdAt: ago(60))
        template.recurrence = .daily(until: nil)
        var parked = task("l", "Someday idea", moveCount: 5, createdAt: ago(60))
        parked.later = true
        let real = task("x", "Renew passport", moveCount: 3, createdAt: ago(1))
        let out = render(Data(tasks: [template, parked, real]))
        XCTAssertTrue(out.contains("Slipping: 1 task — \"Renew passport\""), out)
        XCTAssertFalse(out.contains("Stretch"))
        XCTAssertFalse(out.contains("Someday idea"))
    }

    func testByAreaUsesTheUsersOwnAreasPlusNoArea() {
        let errands = task("e", "Post office", lifeArea: "Errands")
        let loose = task("n", "Loose end")
        let sessions = [sess(errands, SEP, 1, 9, 0, 3600), sess(loose, SEP, 1, 11, 0, 1800),
                        Session(id: "free", taskName: "Focus session", actualSec: 1800, completedAt: ago(0.5))]
        let out = renderInsights(tasks: [errands, loose], sessions: sessions, captures: [], reasons: [], blocks: [],
                                 now: FIXED_NOW, window: .week, areas: ["Errands", "Work"])
        XCTAssertTrue(out.contains("By area: Errands 1.0h, No area 1.0h."), out)
    }

    func testAccidentalAndRunawaySessionsGoThroughTheSameFilterAsTheScreen() {
        let t = task("a", "Write report")
        let sessions = [sess(t, SEP, 1, 9, 0, 19), sess(t, SEP, 1, 10, 0, 37),
                        Session(id: "run", taskId: "a", taskName: "Write report", estimateMin: 30,
                                actualSec: 30 * 3600, completedAt: ago(0.2))]
        let out = render(Data(tasks: [t], sessions: sessions))
        // 19 s and 37 s don't count; the 30-hour timer counts for 90 min (3 × 30).
        XCTAssertTrue(out.contains("Focus: 1h 30m across 1 session"), out)
    }

    // MARK: cross-platform rules (analytics review, 2026-09-24)

    /// An area on a task that isn't in the user's list is its own line, by
    /// name, after the user's areas — never folded into "No area" (web's rule).
    func testByAreaShowsAnAreaOutsideTheUsersListUnderItsOwnName() {
        let errands = task("e", "Post office", lifeArea: "Errands")
        let garden = task("g", "Weed the beds", lifeArea: "Gardening")
        let loose = task("n", "Loose end")
        let sessions = [sess(errands, SEP, 1, 9, 0, 3600), sess(garden, SEP, 1, 11, 0, 1800), sess(loose, SEP, 1, 13, 0, 1800)]
        let out = renderInsights(tasks: [errands, garden, loose], sessions: sessions, captures: [], reasons: [], blocks: [],
                                 now: FIXED_NOW, window: .week, areas: ["Errands", "Work"])
        XCTAssertTrue(out.contains("By area: Errands 1.0h, Gardening 0.5h, No area 0.5h."), out)
    }

    /// get_insights' minutes are the page's: floor((sec + 30) / 60), written
    /// like the review — 99.5 min is "1h 40m", never the floored "1h 39m".
    func testFocusMinutesRoundLikeThePage() {
        let t = task("a", "Write report", estimateMin: 60)
        let out = render(Data(tasks: [t], sessions: [sess(t, SEP, 1, 9, 0, 5970)],
                              blocks: [block("2026-09-01", 60), block("2026-09-02", 60)]))
        XCTAssertTrue(out.contains("Focus: 1h 40m across 1 session, median 1h 40m."), out)
        XCTAssertTrue(out.contains("Planned: 2 calendar blocks (2h) dated in this window."), out)
        XCTAssertEqual(fmtFocusSec(5969), "1h 39m")   // 99.48 min
        XCTAssertEqual(fmtFocusSec(5970), "1h 40m")   // 99.5 min
        XCTAssertEqual(fmtFocusSec(29), "0m")
        XCTAssertEqual(fmtFocusSec(3600), "1h")
    }

    /// A runaway timer's captures are placed from its REAL start (completedAt −
    /// what it really ran), not from its clamped length, which put them hours
    /// "before the start" and dropped them (Android's rule).
    func testInterruptionsPlaceARunawayTimersCapturesFromItsRealStart() {
        let t = task("a", "Write report")   // estimate 30 → counts at most 90 min
        let run = sess(t, SEP, 1, 9, 0, 6 * 3600, "run")   // 09:00 → 15:00, forgotten
        let caps = [capture(.idea, SEP, 1, 9, 5, "run"), capture(.idea, SEP, 1, 9, 10, "run"), capture(.idea, SEP, 1, 9, 20, "run")]
        let out = render(Data(tasks: [t], sessions: [run], captures: caps))
        XCTAssertTrue(out.contains("Interruptions: 3 captures mid-session, most around 3–6 min in."), out)
    }

    func testInterruptionsNeedThreeLinkedCaptures() {
        var d = WEEK
        d.captures = CAPTURES + [capture(.idea, SEP, 2, 10, 20, "s4")]
        XCTAssertTrue(render(d).contains("Interruptions: 3 captures mid-session"), render(d))
        XCTAssertFalse(render(WEEK).contains("Interruptions"))
    }

    func testHourSpanLabels() {
        XCTAssertEqual(hourSpanLabel(0), "12–1am")
        XCTAssertEqual(hourSpanLabel(10), "10–11am")
        XCTAssertEqual(hourSpanLabel(11), "11am–12pm")
        XCTAssertEqual(hourSpanLabel(12), "12–1pm")
        XCTAssertEqual(hourSpanLabel(23), "11pm–12am")
    }
}
