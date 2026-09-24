// Ported from lib/assistant/moments.test.ts.
//
// Monday 24 Aug 2026 is the base day; Friday 28th and Sunday 30th host the
// weekly rituals. Yesterday (Sun 23rd) is where how-did-it-go and quiet-win
// look. Local, timezone-less timestamps throughout so the suite passes in
// any zone.

import XCTest
@testable import UnstuckCore

private let MON = "2026-08-24"
private let FRI = "2026-08-28"
private let SUN = "2026-08-30"

private func at(_ hm: String, _ iso: String = MON) -> Date { LocalTime.parseTimestamp("\(iso)T\(hm):00")! }

private let ALL = RitualPrefs(morning: true, evening: true, friday: true, sunday: true)
private let NONE = RitualPrefs(morning: false, evening: false, friday: false, sunday: false)
private func only(_ k: RitualKey) -> RitualPrefs { var p = NONE; p[k] = true; return p }

nonisolated(unsafe) private var seq = 0
private func nextId() -> String { seq += 1; return "id\(seq)" }

private func task(id: String? = nil, name: String = "A task", estimateMin: Int = 25, done: Bool = false,
                  moveCount: Int? = nil, later: Bool? = nil, completedAt: String? = nil, recurrence: Recurrence? = nil) -> TaskItem {
    TaskItem(id: id ?? nextId(), name: name, estimateMin: estimateMin, totalFocused: 0, done: done,
             moveCount: moveCount, completedAt: completedAt, later: later, recurrence: recurrence,
             createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
}

private func block(id: String? = nil, taskId: String? = "t", taskName: String = "A task", startTime: String = "10:00",
                   durationMinutes: Int = 30, date: String = MON, done: Bool = false) -> CalBlock {
    CalBlock(id: id ?? nextId(), taskId: taskId, taskName: taskName, startTime: startTime,
             durationMinutes: durationMinutes, date: date, done: done)
}

private func fact(_ text: String, id: String? = nil, category: ProfileFactCategory = .person, whenIso: String? = nil) -> ProfileFact {
    ProfileFact(id: id ?? nextId(), category: category, fact: text, source: .chat, whenIso: whenIso,
                createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
}

private func session(_ completedAt: String, _ actualSec: Int = 1500) -> Session {
    Session(id: nextId(), taskName: "Deep work", actualSec: actualSec, completedAt: completedAt)
}

private func state(tasks: [TaskItem] = [], blocks: [CalBlock] = [], sessions: [Session] = [], facts: [ProfileFact] = [],
                   struggles: [String] = [], todayIso: String = MON, now: Date = at("13:00"),
                   isDismissed: @escaping @Sendable (String) -> Bool = { _ in false }) -> MomentState {
    MomentState(tasks: tasks, blocks: blocks, sessions: sessions, reasons: [], facts: facts, struggles: struggles,
                todayIso: todayIso, now: now, isDismissed: isDismissed)
}

private func dismissed(_ ids: String...) -> @Sendable (String) -> Bool { { ids.contains($0) } }

private func withDismissed(_ s: MomentState, _ ids: String...) -> MomentState {
    var out = s
    out.isDismissed = { ids.contains($0) }
    return out
}

private func lastAction(_ m: Moment?) -> MomentAction { m!.actions[m!.actions.count - 1] }

private let TONES: [Tone] = [.gentle, .honest, .minimal]

final class DatesThatMatterTests: XCTestCase {
    private func zara(_ whenIso: String) -> MomentState {
        state(facts: [fact("Zara — daughter, turning 8", id: "f1", whenIso: whenIso)])
    }

    func testFiresForABirthdayFiveDaysOutWithTheGiftTaskReadyToGo() {
        let m = pickMoment(zara("2026-08-29"), prefs: NONE, tone: .gentle)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.kind, .relationship)
        XCTAssertEqual(m?.priority, 30)
        XCTAssertEqual(m?.text, "Zara’s birthday is Sat 29 Aug — gift sorted?")
        XCTAssertEqual(m?.actions[0], MomentAction(label: "Sort the gift", run: .createTask(name: "Get Zara’s birthday gift", estimateMin: nil)))
        XCTAssertEqual(lastAction(m).run, .dismiss)
    }

    func testWindowEdges() {
        XCTAssertNil(pickMoment(zara("2026-08-26"), prefs: NONE, tone: .gentle))       // 2 days
        XCTAssertNotNil(pickMoment(zara("2026-08-27"), prefs: NONE, tone: .gentle))    // 3
        XCTAssertNotNil(pickMoment(zara("2026-09-07"), prefs: NONE, tone: .gentle))    // 14
        XCTAssertNil(pickMoment(zara("2026-09-08"), prefs: NONE, tone: .gentle))       // 15
    }

    func testIdIsStablePerFactAndDateSoOneDismissalCoversTheWholeWindow() {
        let m = pickMoment(zara("2026-08-29"), prefs: NONE, tone: .gentle)!
        XCTAssertEqual(m.id, "dates-that-matter:f1:2026-08-29")
        XCTAssertNil(pickMoment(withDismissed(zara("2026-08-29"), m.id), prefs: NONE, tone: .gentle))
    }

    func testFactsWithoutAWhenIsoNeverFire() {
        XCTAssertNil(pickMoment(state(facts: [fact("Zara — daughter, turning 8")]), prefs: NONE, tone: .gentle))
    }

    func testStaysQuietOnceAnOpenGiftTaskForThatPersonExists() {
        let s = state(tasks: [task(name: "Get Zara’s birthday gift")],
                      facts: [fact("Zara — daughter, turning 8", whenIso: "2026-08-29")])
        XCTAssertNil(pickMoment(s, prefs: NONE, tone: .gentle))
    }

    func testADatedNonBirthdayFactGetsTheGenericPrepareFraming() {
        let s = state(facts: [fact("Visa renewal — passport expires", category: .context, whenIso: "2026-08-29")])
        let m = pickMoment(s, prefs: NONE, tone: .gentle)!
        XCTAssertTrue(m.text.contains("Visa renewal — passport expires"))
        XCTAssertEqual(m.text, "Sat 29 Aug — Visa renewal — passport expires. Want a task for it?")
        guard case .createTask(let name, _) = m.actions[0].run else { return XCTFail("expected create_task") }
        XCTAssertEqual(name, "Prepare: Visa renewal — passport expires")
    }

    func testToneShiftsThePhrasing() {
        let texts = TONES.map { pickMoment(zara("2026-08-29"), prefs: NONE, tone: $0)!.text }
        XCTAssertEqual(Set(texts).count, 3)
        XCTAssertTrue(texts[1].hasPrefix("Straight up:"))
        XCTAssertLessThan(texts[2].count, texts[0].count)
        XCTAssertLessThan(texts[2].count, texts[1].count)
    }
}

final class HowDidItGoTests: XCTestCase {
    private func rehearsals() -> MomentState {
        state(blocks: [block(id: "b1", taskName: "Take Maleek to rehearsals", date: "2026-08-23")],
              facts: [fact("Maleek — son, 9")])
    }

    func testLiftsThePersonAndTheActivityOutOfTheBlockName() {
        let m = pickMoment(rehearsals(), prefs: NONE, tone: .gentle)!
        XCTAssertEqual(m.kind, .relationship)
        XCTAssertEqual(m.text, "How did Maleek’s rehearsals go yesterday?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Talk about it", run: .chat(message: "Tell me how it went: Take Maleek to rehearsals")))
        XCTAssertEqual(m.id, "how-did-it-go:b1")
    }

    func testMultiWordActivitiesSurviveFillerWordsDoNot() {
        let s = state(blocks: [block(taskName: "Drive Amara to the piano recital", date: "2026-08-23")],
                      facts: [fact("Amara — daughter")])
        XCTAssertEqual(pickMoment(s, prefs: NONE, tone: .gentle)!.text, "How did Amara’s piano recital go yesterday?")
    }

    func testFallsBackToTheBlockTitleWhenNothingFollowsTheName() {
        let s = state(blocks: [block(taskName: "Call Maleek", date: "2026-08-23")], facts: [fact("Maleek — son, 9")])
        XCTAssertEqual(pickMoment(s, prefs: NONE, tone: .gentle)!.text, "How did ‘Call Maleek’ go yesterday?")
    }

    func testOnlyPersonFactsIntroduceNames() {
        let s = state(blocks: [block(taskName: "Take Maleek to rehearsals", date: "2026-08-23")],
                      facts: [fact("Maleek — the client project codename", category: .context)])
        XCTAssertNil(pickMoment(s, prefs: NONE, tone: .gentle))
    }

    func testWholeWordsOnlyMaleekaIsNotMaleek() {
        let s = state(blocks: [block(taskName: "Email Maleeka about invoices", date: "2026-08-23")],
                      facts: [fact("Maleek — son, 9")])
        XCTAssertNil(pickMoment(s, prefs: NONE, tone: .gentle))
    }

    func testYesterdayMeansYesterday() {
        let s = state(blocks: [block(taskName: "Take Maleek to rehearsals", date: MON)], facts: [fact("Maleek — son, 9")])
        XCTAssertNil(pickMoment(s, prefs: NONE, tone: .gentle))
    }

    func testDismissalSticksPerBlock() {
        XCTAssertNil(pickMoment(withDismissed(rehearsals(), "how-did-it-go:b1"), prefs: NONE, tone: .gentle))
    }
}

final class FirstTouchTests: XCTestCase {
    private func morning(now: Date = at("09:00"), tasks: [TaskItem]? = nil, blocks: [CalBlock]? = nil,
                         struggles: [String] = []) -> MomentState {
        state(tasks: tasks ?? [task(id: "w", name: "Write the report", estimateMin: 60)],
              blocks: blocks ?? [block(taskId: "w", taskName: "Write the report", startTime: "11:00")],
              struggles: struggles, now: now)
    }

    func testAnchorsOnTheFirstUpcomingBlockExactlyLikeTheBrief() {
        let m = pickMoment(morning(), prefs: only(.morning), tone: .gentle)!
        XCTAssertEqual(m.kind, .ritual)
        XCTAssertEqual(m.priority, 20)
        XCTAssertEqual(m.text, "Morning. ‘Write the report’ at 11:00 is the anchor — want the day built around it?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Plan my day", run: .chat(message: "Plan my day around the anchor")))
        XCTAssertEqual(m.id, "first-touch:\(MON)")
    }

    func testAPastBlockLosesTheAnchorSlotToTheNextUpcomingOne() {
        let s = morning(
            tasks: [task(id: "a", name: "Early thing"), task(id: "w", name: "Write the report")],
            blocks: [block(taskId: "a", taskName: "Early thing", startTime: "07:00"),
                     block(taskId: "w", taskName: "Write the report", startTime: "11:00")])
        XCTAssertTrue(pickMoment(s, prefs: only(.morning), tone: .gentle)!.text.contains("‘Write the report’ at 11:00"))
    }

    func testWithAnEmptyCalendarTheShortestUnscheduledTaskOpensTheDay() {
        let s = morning(tasks: [task(name: "Big thing", estimateMin: 90), task(name: "Tiny thing", estimateMin: 15)], blocks: [])
        XCTAssertTrue(pickMoment(s, prefs: only(.morning), tone: .gentle)!.text.contains("‘Tiny thing’ (~15 min)"))
    }

    func testGates() {
        XCTAssertNil(pickMoment(morning(now: at("12:00")), prefs: only(.morning), tone: .gentle))
        XCTAssertNotNil(pickMoment(morning(now: at("11:59")), prefs: only(.morning), tone: .gentle))
        XCTAssertNil(pickMoment(morning(now: at("01:00")), prefs: only(.morning), tone: .gentle))   // night owl = still yesterday
        XCTAssertNil(pickMoment(morning(), prefs: NONE, tone: .gentle))
        XCTAssertNil(pickMoment(morning(tasks: [task(done: true)]), prefs: only(.morning), tone: .gentle))
    }

    func testRecurringTemplatesAreNotOpenTasksForTheGate() {
        let s = morning(tasks: [task(recurrence: .daily(until: nil))], blocks: [])
        XCTAssertNil(pickMoment(s, prefs: only(.morning), tone: .gentle))
    }

    func testStrugglingWithStartingEarnsTheFirstTenMinutesInEveryTone() {
        for tone in TONES {
            let m = pickMoment(morning(struggles: ["Starting"]), prefs: only(.morning), tone: tone)!
            XCTAssertTrue(m.text.hasSuffix("I’ll give you the first ten minutes."), m.text)
        }
        XCTAssertFalse(pickMoment(morning(), prefs: only(.morning), tone: .gentle)!.text.contains("ten minutes"))
    }

    func testOnePerDayDismissingTodaysIdSilencesIt() {
        XCTAssertNil(pickMoment(withDismissed(morning(), "first-touch:\(MON)"), prefs: only(.morning), tone: .gentle))
    }
}

final class EveningSweepTests: XCTestCase {
    private func evening(now: Date = at("18:00"), tasks: [TaskItem]? = nil, blocks: [CalBlock]? = nil) -> MomentState {
        state(tasks: tasks ?? [task(id: "t1", name: "Call the bank"), task(id: "t2", name: "Water plants")],
              blocks: blocks ?? [block(taskId: "t1", taskName: "Call the bank", startTime: "09:00"),
                                 block(taskId: "t2", taskName: "Water plants", startTime: "10:00")],
              now: now)
    }

    func testOffersToCarryEveryTaskThatWasScheduledAndMissed() {
        let m = pickMoment(evening(), prefs: only(.evening), tone: .gentle)!
        XCTAssertEqual(m.text, "Two things didn’t happen today — carry them to tomorrow?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Carry 2 to tomorrow", run: .carryTasks(taskIds: ["t1", "t2"])))
        XCTAssertEqual(lastAction(m), MomentAction(label: "Leave them", run: .dismiss))
        XCTAssertEqual(m.id, "evening-sweep:\(MON)")
    }

    func testASingleMissReadsSingular() {
        let s = evening(tasks: [task(id: "t1", name: "Call the bank")], blocks: [block(taskId: "t1", startTime: "09:00")])
        let m = pickMoment(s, prefs: only(.evening), tone: .gentle)!
        XCTAssertEqual(m.text, "One thing didn’t happen today — carry it to tomorrow?")
        XCTAssertEqual(lastAction(m).label, "Leave it")
    }

    func testSeventeenTwentyNineIsTooEarly() {
        XCTAssertNil(pickMoment(evening(now: at("17:29")), prefs: only(.evening), tone: .gentle))
        XCTAssertNotNil(pickMoment(evening(now: at("17:30")), prefs: only(.evening), tone: .gentle))
    }

    func testDoneBlocksDoneTasksAndBlocksStillAheadTonightAreNotMisses() {
        let s = evening(
            tasks: [task(id: "t1"), task(id: "t2", done: true), task(id: "t3", name: "Evening yoga")],
            blocks: [block(taskId: "t1", startTime: "09:00", done: true),
                     block(taskId: "t2", startTime: "10:00"),
                     block(taskId: "t3", taskName: "Evening yoga", startTime: "20:00")])
        XCTAssertNil(pickMoment(s, prefs: only(.evening), tone: .gentle))
    }

    func testAChronicSlipperFlipsTheSweepToTheHonestVariantWithAShrinkPath() {
        let s = evening(tasks: [task(id: "t1", name: "Tax form", moveCount: 4), task(id: "t2", name: "Water plants")])
        let m = pickMoment(s, prefs: only(.evening), tone: .gentle)!
        XCTAssertEqual(m.text, "‘Tax form’ has slipped 4 times — want to carry it, shrink it, or let it go?")
        XCTAssertEqual(m.actions.count, 3)
        XCTAssertEqual(m.actions[0].run, .carryTasks(taskIds: ["t1", "t2"]))
        XCTAssertEqual(m.actions[1].run, .chat(message: "Help me shrink ‘Tax form’ into a first step"))
        XCTAssertEqual(m.actions[2].run, .dismiss)
    }

    func testPrefGateAndOnePerDayDismissal() {
        XCTAssertNil(pickMoment(evening(), prefs: NONE, tone: .gentle))
        XCTAssertNil(pickMoment(withDismissed(evening(), "evening-sweep:\(MON)"), prefs: only(.evening), tone: .gentle))
    }
}

final class FridayReviewTests: XCTestCase {
    private let week = [
        session("2026-08-24T10:00:00"), session("2026-08-25T09:30:00", 3000),
        session("2026-08-26T14:00:00"), session("2026-08-27T11:00:00"), session("2026-08-28T09:00:00"),
    ]
    private func friday(todayIso: String = FRI, now: Date? = nil, sessions: [Session]? = nil) -> MomentState {
        state(sessions: sessions ?? week, todayIso: todayIso, now: now ?? at("16:00", FRI))
    }

    func testFiresWithFiveSessionsAndNamesTheBestRunsDayAndDaypart() {
        let m = pickMoment(friday(), prefs: only(.friday), tone: .gentle)!
        XCTAssertEqual(m.kind, .ritual)
        XCTAssertEqual(m.text, "Week in three minutes? 5 focus blocks, best run Tuesday morning.")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Review the week", run: .chat(message: "Let’s do the week review")))
        XCTAssertEqual(m.id, "friday-review:\(FRI)")
    }

    func testFourSessionsAreNotYetAWeekWorthReviewing() {
        XCTAssertNil(pickMoment(friday(sessions: Array(week.prefix(4))), prefs: only(.friday), tone: .gentle))
    }

    func testLastWeeksSessionsDoNotPadTheCount() {
        let s = friday(sessions: Array(week.prefix(4)) + [session("2026-08-22T10:00:00")])
        XCTAssertNil(pickMoment(s, prefs: only(.friday), tone: .gentle))
    }

    func testFridayFrom15OnlyThursdayAnd1459StayQuiet() {
        XCTAssertNil(pickMoment(friday(todayIso: "2026-08-27", now: at("16:00", "2026-08-27")), prefs: only(.friday), tone: .gentle))
        XCTAssertNil(pickMoment(friday(now: at("14:59", FRI)), prefs: only(.friday), tone: .gentle))
        XCTAssertNotNil(pickMoment(friday(now: at("15:00", FRI)), prefs: only(.friday), tone: .gentle))
    }
}

final class SundayRunwayTests: XCTestCase {
    // Next week from Sunday 30 Aug: Mon 31 Aug … Fri 4 Sept. Wednesday = 2 Sept.
    private func sunday(tasks: [TaskItem] = [], blocks: [CalBlock] = []) -> MomentState {
        state(tasks: tasks, blocks: blocks, todayIso: SUN, now: at("17:00", SUN))
    }
    private func load(_ date: String, _ minutes: Int) -> CalBlock { block(taskId: nil, durationMinutes: minutes, date: date) }

    func testAnOverbookedWeekdayGetsNamedForThinning() {
        let m = pickMoment(sunday(blocks: [load("2026-09-02", 270)]), prefs: only(.sunday), tone: .gentle)!
        XCTAssertEqual(m.text, "Wednesday looks wall-to-wall — want to thin it out?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Thin out Wednesday", run: .chat(message: "Help me thin out Wednesday")))
        XCTAssertEqual(m.id, "sunday-runway:\(SUN)")
    }

    func testHonestVariantQuotesTheLoadInHours() {
        XCTAssertEqual(pickMoment(sunday(blocks: [load("2026-09-02", 270)]), prefs: only(.sunday), tone: .honest)!.text,
                       "Straight up: Wednesday has 4.5h scheduled. Thin it out?")
        XCTAssertEqual(pickMoment(sunday(blocks: [load("2026-09-02", 300)]), prefs: only(.sunday), tone: .minimal)!.text,
                       "Wednesday: 5h. Thin it?")
    }

    func testTheHeaviestDayWinsWhenSeveralAreLoaded() {
        let s = sunday(blocks: [load("2026-09-01", 250), load("2026-09-02", 300)])
        XCTAssertTrue(pickMoment(s, prefs: only(.sunday), tone: .gentle)!.text.contains("Wednesday"))
    }

    func testExactlyFourHoursIsNotWallToWallThreeUnscheduledEarnTheRoughOutOffer() {
        let s = sunday(tasks: [task(), task(), task()], blocks: [load("2026-09-02", 240)])
        let m = pickMoment(s, prefs: only(.sunday), tone: .gentle)!
        XCTAssertEqual(m.text, "Rough out next week? 3 tasks are still unscheduled.")
        guard case .chat = m.actions[0].run else { return XCTFail("expected chat") }
    }

    func testTwoUnscheduledTasksAndALightWeekIsAQuietSunday() {
        XCTAssertNil(pickMoment(sunday(tasks: [task(), task()]), prefs: only(.sunday), tone: .gentle))
    }

    func testSundayFrom16Only() {
        var s = sunday(blocks: [load("2026-09-02", 270)])
        s.now = at("15:59", SUN)
        XCTAssertNil(pickMoment(s, prefs: only(.sunday), tone: .gentle))
        s.todayIso = MON
        s.now = at("17:00", MON)
        XCTAssertNil(pickMoment(s, prefs: only(.sunday), tone: .gentle))
    }
}

final class SlipRadarTests: XCTestCase {
    private func slipping(struggles: [String] = []) -> MomentState {
        state(tasks: [task(id: "tax", name: "Tax form", moveCount: 4)], struggles: struggles)
    }

    func testFiresAsANoticeWithTheShrinkParkLetGoFork() {
        let m = pickMoment(slipping(), prefs: NONE, tone: .gentle)!
        XCTAssertEqual(m.kind, .notice)
        XCTAssertEqual(m.priority, 10)
        XCTAssertEqual(m.text, "‘Tax form’ has moved 4 times. Shrink it to a 10-minute step, park it, or let it go?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Shrink it", run: .chat(message: "Help me shrink ‘Tax form’ into a first step")))
        XCTAssertEqual(m.id, "slip-radar:tax:4")
    }

    func testTwoMovesAreLifeThreeAreAPattern() {
        XCTAssertNil(pickMoment(state(tasks: [task(moveCount: 2)]), prefs: NONE, tone: .gentle))
        XCTAssertNotNil(pickMoment(state(tasks: [task(moveCount: 3)]), prefs: NONE, tone: .gentle))
    }

    func testDoneAndParkedTasksAreOffTheRadar() {
        XCTAssertNil(pickMoment(state(tasks: [task(done: true, moveCount: 5)]), prefs: NONE, tone: .gentle))
        XCTAssertNil(pickMoment(state(tasks: [task(moveCount: 5, later: true)]), prefs: NONE, tone: .gentle))
    }

    func testTheHighestCountWinsDismissingItPromotesTheNextSlipper() {
        let s = state(tasks: [task(id: "a", name: "Lesser slip", moveCount: 3), task(id: "b", name: "Worst slip", moveCount: 5)])
        XCTAssertEqual(pickMoment(s, prefs: NONE, tone: .gentle)!.id, "slip-radar:b:5")
        XCTAssertEqual(pickMoment(withDismissed(s, "slip-radar:b:5"), prefs: NONE, tone: .gentle)!.id, "slip-radar:a:3")
    }

    func testWithStartingInTheStrugglesTheFramingBlamesTheStart() {
        let m = pickMoment(slipping(struggles: ["Starting"]), prefs: NONE, tone: .gentle)!
        XCTAssertTrue(m.text.contains("starting is the hard part, not the task"))
    }

    func testToneVariants() {
        let texts = TONES.map { pickMoment(slipping(), prefs: NONE, tone: $0)!.text }
        XCTAssertEqual(Set(texts).count, 3)
        XCTAssertTrue(texts[1].hasPrefix("Straight up:"))
        XCTAssertLessThan(texts[2].count, texts[0].count)
    }
}

final class QuietWinTests: XCTestCase {
    private func win() -> MomentState {
        state(tasks: [task(id: "tax", name: "Tax form", done: true, moveCount: 3, completedAt: "2026-08-23T18:00:00")])
    }

    func testAcknowledgesTheWinAndAsksForNothing() {
        let m = pickMoment(win(), prefs: NONE, tone: .gentle)!
        XCTAssertEqual(m.kind, .notice)
        XCTAssertEqual(m.text, "‘Tax form’ finally happened after 3 dodges. That’s the hard kind of done.")
        XCTAssertEqual(m.actions, [MomentAction(label: "Noted", run: .dismiss)])
        XCTAssertEqual(m.id, "quiet-win:tax:2026-08-23")
    }

    func testOnlyYesterdaysCompletionsCountAndOnlyAfterThreeMoves() {
        let today = state(tasks: [task(done: true, moveCount: 3, completedAt: "\(MON)T09:00:00")])
        let older = state(tasks: [task(done: true, moveCount: 3, completedAt: "2026-08-22T09:00:00")])
        let smooth = state(tasks: [task(done: true, moveCount: 2, completedAt: "2026-08-23T09:00:00")])
        XCTAssertNil(pickMoment(today, prefs: NONE, tone: .gentle))
        XCTAssertNil(pickMoment(older, prefs: NONE, tone: .gentle))
        XCTAssertNil(pickMoment(smooth, prefs: NONE, tone: .gentle))
    }
}

final class HabitGapMomentTests: XCTestCase {
    // Three history Wednesdays before Mon 24 Aug → gym pattern; next
    // occurrence Wed 26 Aug is uncovered.
    private func gym() -> MomentState {
        state(tasks: [task(id: "gym", name: "Gym", estimateMin: 60)],
              blocks: ["2026-08-19", "2026-08-12", "2026-08-05"].map {
                  block(taskId: "gym", taskName: "Gym", startTime: "07:00", durationMinutes: 60, date: $0)
              })
    }

    func testOffersToBookTheUsualSlotAsARealScheduleAction() {
        let m = pickMoment(gym(), prefs: NONE, tone: .gentle)!
        XCTAssertEqual(m.kind, .notice)
        XCTAssertEqual(m.text, "You usually do ‘Gym’ on Wednesdays — still on for Wednesday 26 Aug?")
        XCTAssertEqual(m.actions[0], MomentAction(label: "Book Wednesday 07:00",
                                                  run: .schedule(taskId: "gym", date: "2026-08-26", time: "07:00")))
        XCTAssertEqual(m.id, "habit-gap:gym:2026-08-26")
    }

    func testABlockAlreadyCoveringTheSlotMeansNoGapNoMoment() {
        var s = gym()
        s.blocks.append(block(taskId: "gym", taskName: "Gym", startTime: "07:00", date: "2026-08-26"))
        XCTAssertNil(pickMoment(s, prefs: NONE, tone: .gentle))
    }
}

final class MomentSelectionTests: XCTestCase {
    // Monday 18:00 with everything primed: a birthday five days out (30),
    // an evening sweep with a chronic slipper (20), and slip-radar (10).
    private func loaded() -> MomentState {
        state(tasks: [task(id: "tax", name: "Tax form", moveCount: 4)],
              blocks: [block(taskId: "tax", taskName: "Tax form", startTime: "09:00")],
              facts: [fact("Zara — daughter, turning 8", id: "f1", whenIso: "2026-08-29")],
              now: at("18:00"))
    }

    private func gymPlusSlipper() -> MomentState {
        state(tasks: [task(id: "gym", name: "Gym", estimateMin: 60), task(id: "tax", name: "Tax form", moveCount: 4)],
              blocks: ["2026-08-19", "2026-08-12", "2026-08-05"].map {
                  block(taskId: "gym", taskName: "Gym", startTime: "07:00", date: $0)
              })
    }

    func testRelationshipBeatsRitualBeatsNoticeAndDismissalsCascadeDown() {
        let first = pickMoment(loaded(), prefs: ALL, tone: .gentle)!
        XCTAssertEqual(first.id, "dates-that-matter:f1:2026-08-29")

        let second = pickMoment(withDismissed(loaded(), first.id), prefs: ALL, tone: .gentle)!
        XCTAssertEqual(second.id, "evening-sweep:\(MON)")

        let third = pickMoment(withDismissed(loaded(), first.id, second.id), prefs: ALL, tone: .gentle)!
        XCTAssertEqual(third.id, "slip-radar:tax:4")

        XCTAssertNil(pickMoment(withDismissed(loaded(), first.id, second.id, third.id), prefs: ALL, tone: .gentle))
    }

    func testHowDidItGoOutranksABirthdayStillDaysAway() {
        let s = state(blocks: [block(taskName: "Take Maleek to rehearsals", date: "2026-08-23")],
                      facts: [fact("Zara — daughter, turning 8", whenIso: "2026-08-29"), fact("Maleek — son, 9")])
        XCTAssertTrue(pickMoment(s, prefs: NONE, tone: .gentle)!.id.hasPrefix("how-did-it-go:"))
    }

    func testAmongNoticesOnlyTheStrongestSurfaces() {
        let s = gymPlusSlipper()
        XCTAssertEqual(pickMoment(s, prefs: NONE, tone: .gentle)!.id, "slip-radar:tax:4")
        XCTAssertEqual(pickMoment(withDismissed(s, "slip-radar:tax:4"), prefs: NONE, tone: .gentle)!.id, "habit-gap:gym:2026-08-26")
    }

    func testAnEmptyAccountIsAQuietGateway() {
        XCTAssertNil(pickMoment(state(), prefs: ALL, tone: .gentle))
    }

    func testDeterministic() {
        XCTAssertEqual(pickMoment(loaded(), prefs: ALL, tone: .honest), pickMoment(loaded(), prefs: ALL, tone: .honest))
    }

    func testEveryMomentsLastActionIsADismiss() {
        let states: [(MomentState, RitualPrefs)] = [
            (loaded(), ALL),
            (gymPlusSlipper(), NONE),
            (state(tasks: [task()], now: at("09:00")), only(.morning)),
        ]
        for (s, p) in states {
            for tone in TONES {
                let m = pickMoment(s, prefs: p, tone: tone)
                XCTAssertNotNil(m)
                XCTAssertEqual(lastAction(m).run, .dismiss)
            }
        }
    }

    func testSalienceOrdersSamePriorityRituals() {
        // Monday 18:00: first-touch is gated off, evening sweep (400) is the only ritual.
        let m = pickMoment(withDismissed(loaded(), "dates-that-matter:f1:2026-08-29"), prefs: ALL, tone: .gentle)!
        XCTAssertEqual(m.salience, 400)
    }
}

final class RitualPrefsTests: XCTestCase {
    func testDefaultsMorningEveningOnWeekliesOff() {
        XCTAssertEqual(RitualPrefs.defaults, RitualPrefs(morning: true, evening: true, friday: false, sunday: false))
        XCTAssertEqual(RitualPrefs(), RitualPrefs.defaults)
    }

    func testPartialJsonKeepsDefaultsForMissingKeysLikeTheWeb() throws {
        let p = try JSONDecoder().decode(RitualPrefs.self, from: Data("{\"friday\":true}".utf8))
        XCTAssertEqual(p, RitualPrefs(morning: true, evening: true, friday: true, sunday: false))
        let round = try JSONDecoder().decode(RitualPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
    }

    func testSubscriptAndLabels() {
        var p = RitualPrefs.defaults
        p[.sunday] = true
        XCTAssertTrue(p.sunday)
        XCTAssertEqual(RITUAL_LABELS.map { $0.key }, [.morning, .evening, .friday, .sunday])
        XCTAssertEqual(RITUAL_LABELS[0].label, "Morning plan")
        XCTAssertEqual(RITUAL_LABELS[1].sub, "Carry what didn’t happen — no guilt attached")
    }
}
