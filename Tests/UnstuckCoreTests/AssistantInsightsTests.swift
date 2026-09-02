// Ported from lib/assistant/insights.test.ts.

import XCTest
@testable import UnstuckCore

nonisolated(unsafe) private var seq = 0
private func nextSeq() -> Int { seq += 1; return seq }

// All sessions live in August 2026, local time; FIXED_NOW sits just past them so
// everything falls inside the 60-day window unless a test says otherwise.
private let FIXED_NOW: Date = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Time.civil(2026, 8, 28))!

/// A session STARTING at the given local day/hour/minute, ending actualSec later.
private func sess(_ day: Int, _ hour: Int, _ min: Int, _ actualSec: Int, estimateMin: Int? = nil, completedAt: String? = nil) -> Session {
    let start = Calendar.current.date(bySettingHour: hour, minute: min, second: 0, of: Time.civil(2026, 8, day))!
    let end = start.timeIntervalSince1970 * 1000 + Double(actualSec) * 1000
    return Session(id: "s\(nextSeq())", taskName: "Deep work", estimateMin: estimateMin, actualSec: actualSec,
                   completedAt: completedAt ?? iso(end))
}

private func repeatN(_ n: Int, _ make: (Int) -> Session) -> [Session] { (0..<n).map(make) }

private func ago(_ days: Double) -> String { iso(Date().timeIntervalSince1970 * 1000 - days * DAY_MS) }

private func log(reason: String = "phone call", action: ReasonAction = .pause, at: String? = nil, durationSec: Int? = nil) -> ReasonLog {
    ReasonLog(id: "r\(nextSeq())", reason: reason, action: action, at: at ?? ago(2), durationSec: durationSec)
}

private func repeat5(_ make: () -> ReasonLog) -> [ReasonLog] { (0..<5).map { _ in make() } }

final class GoldenHoursTests: XCTestCase {

    func testFindsAClearMorningClusterAndPhrasesItLikeAHuman() {
        let sessions = repeatN(8) { sess(10 + $0, 9, 15, 1800) } + repeatN(6) { sess(10 + $0, 10, 5, 1800) }
        let g = goldenHours(sessions, now: FIXED_NOW)
        XCTAssertNotNil(g)
        XCTAssertEqual(g?.hours, [9, 10])
        XCTAssertEqual(g?.label, "mornings around 9–11")
        XCTAssertEqual(g?.share ?? 0, 1, accuracy: 1e-5)
        XCTAssertEqual(g?.factText, "Deep focus lands best around 9–11am (from 14 real sessions)")
    }

    func testFewerThanTenQualifyingSessionsIsNull() {
        let nine = repeatN(9) { sess(10 + $0, 9, 0, 1800) }
        XCTAssertNil(goldenHours(nine, now: FIXED_NOW))
        XCTAssertNil(goldenHours([], now: FIXED_NOW))
    }

    func testSessionsOlderThan60DaysNeverQualify() {
        let recent = repeatN(7) { sess(10 + $0, 9, 0, 1800) }
        // June 1 is ~88 days before FIXED_NOW — outside the window.
        let june1 = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Time.civil(2026, 6, 1))!
        let ancient = repeatN(5) { sess(10 + $0, 9, 0, 1800, completedAt: iso(june1.timeIntervalSince1970 * 1000)) }
        XCTAssertNil(goldenHours(recent + ancient, now: FIXED_NOW))
    }

    func testShareIsTheBandsFractionOfFocusedSecondsNotOfSessions() {
        let sessions = repeatN(6) { sess(10 + $0, 9, 0, 3600) }
            + repeatN(5) { sess(10 + $0, 10, 0, 3600) }
            + repeatN(3) { sess(10 + $0, 20, 0, 3600) }
        let g = goldenHours(sessions, now: FIXED_NOW)!
        XCTAssertEqual(g.hours, [9, 10])
        XCTAssertEqual(g.share, 11.0 / 14.0, accuracy: 1e-5)
        XCTAssertTrue(g.factText.contains("from 14 real sessions"))
    }

    func testWeightsByActualSecStartHourDrivesTheBand() {
        // Four 2-hour blocks starting 9:00 (completedAt lands at 11:00 — the
        // START hour must drive the band) vs ten 10-minute dabs at 20:30.
        let sessions = repeatN(4) { sess(10 + $0, 9, 0, 7200) } + repeatN(10) { sess(10 + $0, 20, 30, 600) }
        let g = goldenHours(sessions, now: FIXED_NOW)!
        XCTAssertEqual(g.hours, [9, 10])
        XCTAssertEqual(g.share, 28800.0 / 34800.0, accuracy: 1e-5)
    }

    func testGrowsToAThreeHourBandWhenTheNeighbouringHourCarriesWeight() {
        let sessions = repeatN(4) { sess(10 + $0, 13, 0, 1800) }
            + repeatN(4) { sess(10 + $0, 14, 0, 1800) }
            + repeatN(4) { sess(10 + $0, 15, 0, 1800) }
        let g = goldenHours(sessions, now: FIXED_NOW)!
        XCTAssertEqual(g.hours, [13, 14, 15])
        XCTAssertEqual(g.label, "early afternoons around 13–16")
        XCTAssertTrue(g.factText.contains("1–4pm"))
        XCTAssertEqual(g.share, 1, accuracy: 1e-5)
    }

    func testSessionsWithNoEstimateMinStillCount() {
        let sessions = repeatN(7) { sess(10 + $0, 9, 0, 1800) } + repeatN(7) { sess(10 + $0, 10, 0, 1800, estimateMin: 30) }
        let g = goldenHours(sessions, now: FIXED_NOW)
        XCTAssertNotNil(g)
        XCTAssertTrue(g?.factText.contains("from 14 real sessions") ?? false)
    }
}

final class StruggleProfileTests: XCTestCase {

    func testNoDeclaredStrugglesIsAnEmptyHonestProfile() {
        let p = struggleProfile([], [log(), log()])
        XCTAssertEqual(p, StruggleProfile(primary: nil, confirmed: false, line: nil, offerFirstStep: false))
    }

    func testADeclaredStruggleAlwaysYieldsItsWarmLineUnconfirmedWithoutEvidence() {
        let p = struggleProfile(["Starting"], [])
        XCTAssertEqual(p.primary, "Starting")
        XCTAssertFalse(p.confirmed)
        XCTAssertEqual(p.line, "Their hard part is Starting — offer a tiny first step before anything else.")
        XCTAssertTrue(p.offerFirstStep)
    }

    func testSwitchingConfirmsOnFiveRecentSwitchLogsAndNotOnFour() {
        let distracted = { log(reason: "got distracted by email", action: .switch) }
        XCTAssertTrue(struggleProfile(["Switching"], repeat5(distracted)).confirmed)
        XCTAssertFalse(struggleProfile(["Switching"], [distracted(), distracted(), distracted(), distracted()]).confirmed)
    }

    func testEvidenceOlderThan30DaysDoesNotConfirm() {
        let old = repeat5 { log(reason: "got distracted", action: .switch, at: ago(45)) }
        XCTAssertFalse(struggleProfile(["Switching"], old).confirmed)
    }

    func testSustainingConfirmsViaLongPausesNotQuickBreaks() {
        let longPauses = repeat5 { log(action: .pause, durationSec: 900) }
        XCTAssertTrue(struggleProfile(["Sustaining"], longPauses).confirmed)
        let quick = repeat5 { log(action: .pause, durationSec: 60) }
        XCTAssertFalse(struggleProfile(["Sustaining"], quick).confirmed)
    }

    func testStartingConfirmsOnItsOwnVocabularyNotOnSomeoneElsesLogs() {
        let stuck = repeat5 { log(reason: "couldn’t get started, kept avoiding it") }
        XCTAssertTrue(struggleProfile(["Starting"], stuck).confirmed)
        // A pile of switch logs is Switching evidence — it must NOT confirm Starting.
        let switchy = repeat5 { log(reason: "got distracted", action: .switch) }
        XCTAssertFalse(struggleProfile(["Starting"], switchy).confirmed)
    }

    func testOfferFirstStepFiresWheneverStartingIsDeclaredEvenBehindAnotherPrimary() {
        let p = struggleProfile(["Switching", "Starting"], [])
        XCTAssertEqual(p.primary, "Switching")
        XCTAssertTrue(p.offerFirstStep)
    }

    func testNormalizesCasingToTheCanonicalLabel() {
        let p = struggleProfile(["starting"], [])
        XCTAssertEqual(p.primary, "Starting")
        XCTAssertTrue(p.offerFirstStep)
    }

    func testAnUnknownStruggleGetsTheGenericLine() {
        XCTAssertEqual(struggleProfile(["Finishing"], []).line,
                       "Their hard part is Finishing — meet them there before anything else.")
    }
}

final class ToneFromFactsTests: XCTestCase {
    private func f(_ category: String, _ fact: String) -> (category: String, fact: String) { (category, fact) }

    func testGentle() {
        XCTAssertEqual(toneFromFacts([f("style", "Prefers gentle nudges — suggest, never push")]), .gentle)
    }

    func testHonestDirect() {
        XCTAssertEqual(toneFromFacts([f("style", "Wants to be kept honest — direct nudges are welcome")]), .honest)
        XCTAssertEqual(toneFromFacts([f("style", "Be direct with nudges")]), .honest)
    }

    func testMinimalBarely() {
        XCTAssertEqual(toneFromFacts([f("style", "Minimal nudging — only speak up when it really matters")]), .minimal)
        XCTAssertEqual(toneFromFacts([f("style", "Barely any nudging, please")]), .minimal)
    }

    func testDefaultsToGentleWithNoFactsOrNoStyleFact() {
        XCTAssertEqual(toneFromFacts([(category: String, fact: String)]()), .gentle)
        XCTAssertEqual(toneFromFacts([f("life", "Has two kids")]), .gentle)
    }

    func testAnUnrelatedFactMentioningDirectCannotHijackTheTone() {
        XCTAssertEqual(toneFromFacts([f("work", "Direct reports sync on Mondays")]), .gentle)
    }

    func testProfileFactsRouteThroughTheirCategoryName() {
        let honest = ProfileFact(id: "f1", category: .preference, fact: "Wants to be kept honest — direct nudges are welcome",
                                 source: .interview, createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
        XCTAssertEqual(toneFromFacts([honest]), .honest)
        let person = ProfileFact(id: "f2", category: .person, fact: "Sam — direct manager", source: .chat,
                                 createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
        XCTAssertEqual(toneFromFacts([person]), .gentle)
    }
}

final class QuietWinLineTests: XCTestCase {
    func testUnderThreeMovesIsNull() {
        XCTAssertNil(quietWinLine(taskName: "Tax return", moveCount: 0, tone: .gentle))
        XCTAssertNil(quietWinLine(taskName: "Tax return", moveCount: 2, tone: .honest))
    }

    func testEachToneGetsItsOwnLineDodgesAcknowledgedWithoutShame() {
        XCTAssertEqual(quietWinLine(taskName: "Tax return", moveCount: 4, tone: .gentle),
                       "“Tax return” finally happened — it dodged you 4 times, and you got it anyway.")
        XCTAssertEqual(quietWinLine(taskName: "Tax return", moveCount: 4, tone: .honest),
                       "That’s “Tax return” done after 4 dodges. The hard kind of done.")
        XCTAssertEqual(quietWinLine(taskName: "Tax return", moveCount: 4, tone: .minimal),
                       "“Tax return” — done, after 4 tries.")
    }
}

final class FactCitationTests: XCTestCase {
    func testDateOnlyCreatedAtRendersAsAShortLocalDate() {
        XCTAssertEqual(factCitation(fact: "Mornings are the good hours", createdAt: "2026-08-12"),
                       "“Mornings are the good hours” (you told me 12 Aug)")
    }

    func testFullTimestampsRenderDayPlusShortMonthNoZeroPadding() {
        // No trailing Z → parsed as local time, deterministic in any zone.
        XCTAssertEqual(factCitation(fact: "Fridays are for admin", createdAt: "2026-01-03T09:30:00"),
                       "“Fridays are for admin” (you told me 3 Jan)")
    }

    func testUnparseableDatesFallBackToTheBareQuote() {
        XCTAssertEqual(factCitation(fact: "Loves tea", createdAt: "whenever"), "“Loves tea”")
        let f = ProfileFact(id: "f", category: .context, fact: "Loves tea", source: .chat,
                            createdAt: "2026-08-12T10:00:00Z", updatedAt: "2026-08-12T10:00:00Z")
        XCTAssertEqual(factCitation(f), "“Loves tea” (you told me 12 Aug)")
    }
}
