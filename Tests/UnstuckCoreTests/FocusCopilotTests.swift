// Pure-logic tests for the Hands-Free Focus Copilot (Phase 1). Mirrors the
// FocusTimer test style: inject focus seconds + an already-fired set, assert
// the exact milestone / line / command. Must stay 1:1 with Android/web.

import XCTest
@testable import UnstuckCore

// MARK: - Scheduler: dueMilestone across level × estimate

final class FocusCopilotSchedulerTests: XCTestCase {

    /// Drive a session from 0 up to `untilMin` minutes of ACCUMULATED focus in
    /// 1-second steps, firing each due milestone exactly once (marking it in
    /// `fired`), and collect the ordered list of milestone keys fired. Honors
    /// keepGoing the moment an AT_TIME/T-5/OVERRUN fires if `keepGoingAfter` is
    /// the key to opt-out at.
    private func fireSequence(
        E: Int, level: NotificationLevel, untilMin: Int,
        keepGoingAfter: String? = nil
    ) -> [String] {
        var fired = Set<String>()
        var keepGoing = false
        var order: [String] = []
        for sec in 0...(untilMin * 60) {
            // Re-ask in a loop so a single tick can drain several thresholds.
            while let m = FocusCopilot.dueMilestone(estimateMin: E, level: level,
                                                    focusedSec: sec, alreadyFired: fired,
                                                    keepGoing: keepGoing) {
                fired.insert(m.key)
                order.append(m.key)
                if m.key == keepGoingAfter { keepGoing = true }
            }
        }
        return order
    }

    // ── Estimate gates per level ─────────────────────────────────────────

    func testCalm_onlyAtTime_regardlessOfEstimate() {
        for E in [3, 5, 10, 25, 50] {
            let order = fireSequence(E: E, level: .calm, untilMin: E + 30)
            XCTAssertEqual(order, ["atTime"], "Calm fires AT_TIME only (E=\(E))")
        }
    }

    func testBalanced_3min_atTimeOnly() {
        XCTAssertEqual(fireSequence(E: 3, level: .balanced, untilMin: 10), ["atTime"])
    }

    func testBalanced_5min_atTimeOnly_E5Collapses() {
        // E <= 5 → AT_TIME only at any level, so no T-5 even though Balanced.
        XCTAssertEqual(fireSequence(E: 5, level: .balanced, untilMin: 12), ["atTime"])
    }

    func testBalanced_10min_atTimeOnly_tMinus5GatedAtEgt10() {
        // T-5 requires E > 10, so exactly 10 gets AT_TIME only.
        XCTAssertEqual(fireSequence(E: 10, level: .balanced, untilMin: 15), ["atTime"])
    }

    func testBalanced_25min_tMinus5ThenAtTime() {
        XCTAssertEqual(fireSequence(E: 25, level: .balanced, untilMin: 40),
                       ["tMinus5", "atTime"])
    }

    func testBalanced_50min_tMinus5ThenAtTime_noHalfwayNoOverrun() {
        XCTAssertEqual(fireSequence(E: 50, level: .balanced, untilMin: 70),
                       ["tMinus5", "atTime"])
    }

    func testCoach_3min_atTimeOnly() {
        XCTAssertEqual(fireSequence(E: 3, level: .coach, untilMin: 20), ["atTime"])
    }

    func testCoach_5min_atTimeOnly() {
        XCTAssertEqual(fireSequence(E: 5, level: .coach, untilMin: 20), ["atTime"])
    }

    func testCoach_10min_tMinus5Gated_halfwayGated_atTimePlusOverrun() {
        // E=10: halfway needs E>=20 (no), T-5 needs E>10 (no) → AT_TIME, then
        // Coach overrun re-checks at +5 and +10.
        XCTAssertEqual(fireSequence(E: 10, level: .coach, untilMin: 25),
                       ["atTime", "overrun.1", "overrun.2"])
    }

    func testCoach_25min_halfwayTMinus5AtTimeThenOverrunCap2() {
        // halfway @ 12:30, T-5 @ 20:00, AT_TIME @ 25:00, overrun @ 30 + 35.
        XCTAssertEqual(fireSequence(E: 25, level: .coach, untilMin: 45),
                       ["halfway", "tMinus5", "atTime", "overrun.1", "overrun.2"])
    }

    func testCoach_50min_full() {
        XCTAssertEqual(fireSequence(E: 50, level: .coach, untilMin: 75),
                       ["halfway", "tMinus5", "atTime", "overrun.1", "overrun.2"])
    }

    // ── No double-fire ───────────────────────────────────────────────────

    func testEachMilestoneFiresAtMostOnce() {
        let order = fireSequence(E: 25, level: .coach, untilMin: 60)
        XCTAssertEqual(order.count, Set(order).count, "no milestone fires twice")
    }

    func testAlreadyFiredSuppressesRefire() {
        // AT_TIME already fired → not returned again at/after the threshold.
        let m = FocusCopilot.dueMilestone(estimateMin: 25, level: .calm,
                                          focusedSec: 25 * 60 + 120,
                                          alreadyFired: ["atTime"])
        XCTAssertNil(m)
    }

    // ── Overrun cap (2) ──────────────────────────────────────────────────

    func testOverrunCappedAtTwoEvenWayOver() {
        // Run far past the estimate — still only 2 overrun re-checks.
        let order = fireSequence(E: 25, level: .coach, untilMin: 90)
        let overruns = order.filter { $0.hasPrefix("overrun") }
        XCTAssertEqual(overruns, ["overrun.1", "overrun.2"])
    }

    func testThirdOverrunNeverDue() {
        // By the time the 3rd overrun could be due, every earlier milestone
        // has fired — so nothing is left to surface.
        let fired: Set<String> = ["halfway", "tMinus5", "atTime", "overrun.1", "overrun.2"]
        // 25m + 16m over (well past a hypothetical 3rd re-check at +15).
        let m = FocusCopilot.dueMilestone(estimateMin: 25, level: .coach,
                                          focusedSec: (25 + 16) * 60,
                                          alreadyFired: fired)
        XCTAssertNil(m, "the cap of 2 overrun re-checks is hard")
    }

    func testCoachE5NoOverrunReChecks() {
        // E<=5 collapses to AT_TIME only at EVERY level — Coach included — so
        // even way over a 5-min block there are no overrun re-checks.
        let order = fireSequence(E: 5, level: .coach, untilMin: 40)
        XCTAssertEqual(order, ["atTime"])
    }

    // ── keepGoing suppression ────────────────────────────────────────────

    func testKeepGoingSuppressesAllOverrun() {
        // Opt out at AT_TIME → no overrun re-checks at all.
        let order = fireSequence(E: 25, level: .coach, untilMin: 60, keepGoingAfter: "atTime")
        XCTAssertEqual(order, ["halfway", "tMinus5", "atTime"])
    }

    func testKeepGoingMidOverrunStopsFurtherOverrun() {
        // Opt out at the FIRST overrun → the 2nd never fires.
        let order = fireSequence(E: 25, level: .coach, untilMin: 60, keepGoingAfter: "overrun.1")
        XCTAssertEqual(order, ["halfway", "tMinus5", "atTime", "overrun.1"])
    }

    func testKeepGoingDoesNotSuppressNonOverrun() {
        // keepGoing set from the start must NOT block the fixed milestones.
        var fired = Set<String>()
        var order: [String] = []
        for sec in 0...(40 * 60) {
            while let m = FocusCopilot.dueMilestone(estimateMin: 25, level: .coach,
                                                    focusedSec: sec, alreadyFired: fired,
                                                    keepGoing: true) {
                fired.insert(m.key); order.append(m.key)
            }
        }
        XCTAssertEqual(order, ["halfway", "tMinus5", "atTime"])
    }

    // ── Paused-excluded (uses accumulated focus seconds) ─────────────────

    func testUsesAccumulatedFocusNotWallClock() {
        // The scheduler is fed FOCUS seconds. With only 10 min of focus on a
        // 25-min Coach block (even if 30 wall-clock min passed while paused),
        // only HALFWAY (@12:30 needs 750s; 10min=600s < 750) has NOT fired yet.
        let m = FocusCopilot.dueMilestone(estimateMin: 25, level: .coach,
                                          focusedSec: 10 * 60, alreadyFired: [])
        XCTAssertNil(m, "10 min of focus hasn't reached halfway (12:30) on a 25-min block")
        // 13 min of focus → halfway is due (regardless of how long paused).
        let m2 = FocusCopilot.dueMilestone(estimateMin: 25, level: .coach,
                                           focusedSec: 13 * 60, alreadyFired: [])
        XCTAssertEqual(m2, .halfway)
    }

    func testNothingDueBeforeFirstThreshold() {
        let m = FocusCopilot.dueMilestone(estimateMin: 25, level: .coach,
                                          focusedSec: 60, alreadyFired: [])
        XCTAssertNil(m)
    }

    // ── asksQuestion classification ──────────────────────────────────────

    func testHalfwayIsSpeakOnly_othersAsk() {
        XCTAssertFalse(FocusMilestone.halfway.asksQuestion)
        XCTAssertTrue(FocusMilestone.tMinus5.asksQuestion)
        XCTAssertTrue(FocusMilestone.atTime.asksQuestion)
        XCTAssertTrue(FocusMilestone.overrun(index: 1).asksQuestion)
    }
}

// MARK: - Spoken line {n} rendering

final class FocusCopilotLineTests: XCTestCase {

    func testHalfwayUsesWholeMinutesLeft() {
        // 25-min block, 13 min focused → 12 min left (floored).
        XCTAssertEqual(FocusCopilot.line(for: .halfway, estimateMin: 25, focusedSec: 13 * 60),
                       "Halfway there — about 12 minutes left.")
        // Exactly halfway (12:30 focused) → 12 left.
        XCTAssertEqual(FocusCopilot.line(for: .halfway, estimateMin: 25, focusedSec: 12 * 60 + 30),
                       "Halfway there — about 12 minutes left.")
    }

    func testTMinus5FixedString() {
        XCTAssertEqual(FocusCopilot.line(for: .tMinus5, estimateMin: 25, focusedSec: 20 * 60),
                       "Five minutes left. Want to wrap up, or add time?")
    }

    func testAtTimeFixedString() {
        XCTAssertEqual(FocusCopilot.line(for: .atTime, estimateMin: 25, focusedSec: 25 * 60),
                       "That's your block. Add five, stop, or keep going?")
    }

    func testOverrunUsesWholeMinutesOver() {
        // 25-min block, 32 min focused → 7 min over.
        XCTAssertEqual(FocusCopilot.line(for: .overrun(index: 1), estimateMin: 25, focusedSec: 32 * 60),
                       "You're 7 minutes over. Stop here, or keep going?")
        // Just past the cap step (30:00 focused) → 5 over.
        XCTAssertEqual(FocusCopilot.line(for: .overrun(index: 1), estimateMin: 25, focusedSec: 30 * 60),
                       "You're 5 minutes over. Stop here, or keep going?")
    }
}

// MARK: - parseCommand table

final class FocusCommandParserTests: XCTestCase {

    private func assertParse(_ utterance: String, _ expected: FocusCommand,
                             file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(FocusCommandParser.parse(utterance), expected,
                       "\"\(utterance)\"", file: file, line: line)
    }

    // ── stop synonyms (priority 1) ───────────────────────────────────────
    func testStopSynonyms() {
        assertParse("stop", .stop)
        assertParse("Stop.", .stop)
        assertParse("I'm done", .stop)
        assertParse("done", .stop)
        assertParse("finish", .stop)
        assertParse("let's finish up", .stop)
        assertParse("end", .stop)
        assertParse("end it", .stop)
        assertParse("stop here", .stop)
        assertParse("that's it", .stop)
        assertParse("thats it for now", .stop)
    }

    func testStopWordBoundary_nonstopIsNotStop() {
        // "nonstop" must NOT match the whole-word "stop".
        assertParse("nonstop work please", .none)
    }

    // ── extend: word + digit (priority 2) ────────────────────────────────
    func testExtendWordAndDigit() {
        assertParse("add ten", .extend(minutes: 10))
        assertParse("add 10", .extend(minutes: 10))
        assertParse("extend by fifteen", .extend(minutes: 15))
        assertParse("give me five more", .extend(minutes: 5))
        assertParse("add 5 minutes", .extend(minutes: 5))
        assertParse("extend 20", .extend(minutes: 20))
        assertParse("give me twenty", .extend(minutes: 20))
    }

    func testAddTimeAndMoreTimeMapToFive() {
        assertParse("add time", .extend(minutes: 5))
        assertParse("more time", .extend(minutes: 5))
        assertParse("give me more time", .extend(minutes: 5))
    }

    // ── keepGoing ────────────────────────────────────────────────────────
    func testKeepGoingPhrases() {
        assertParse("keep going", .keepGoing)
        assertParse("Keep going!", .keepGoing)
        assertParse("I'm in the zone", .keepGoing)
        assertParse("not yet", .keepGoing)
    }

    // ── capture prefixes + verbatim remainder (priority 3) ───────────────
    func testCapturePrefixesAndRemainder() {
        assertParse("capture call the dentist", .capture(text: "call the dentist"))
        assertParse("note buy milk", .capture(text: "buy milk"))
        assertParse("remember the API key rotates Friday",
                    .capture(text: "the API key rotates Friday"))
        assertParse("remind me to email Sam", .capture(text: "email Sam"))
        assertParse("add a task review the PR", .capture(text: "review the PR"))
        // Verbatim casing preserved in the body.
        assertParse("note Ping Zubair re TestFlight",
                    .capture(text: "Ping Zubair re TestFlight"))
    }

    func testCapturePrefixWordBoundary() {
        // "remembering" must not match the "remember" prefix.
        assertParse("remembering things is hard", .none)
        // bare prefix with no body → not a capture.
        assertParse("note", .none)
    }

    // ── clamp ────────────────────────────────────────────────────────────
    func testExtendClampsToRange() {
        assertParse("add 999", .extend(minutes: 120))
        // word "ninety" within range.
        assertParse("give me ninety", .extend(minutes: 90))
        // A digit below 1 floors to 1 only via clamp; "add 0" → 0 → clamp 1.
        assertParse("add 0", .extend(minutes: 1))
    }

    func testClampMinutesHelper() {
        XCTAssertEqual(FocusCommandParser.clampMinutes(0), 1)
        XCTAssertEqual(FocusCommandParser.clampMinutes(200), 120)
        XCTAssertEqual(FocusCommandParser.clampMinutes(45), 45)
    }

    // ── garbage / empty → none ───────────────────────────────────────────
    func testGarbageAndEmpty() {
        assertParse("", .none)
        assertParse("   ", .none)
        assertParse("banana helicopter", .none)
        // "add" with no number and not "add time" → none.
        assertParse("add", .none)
    }

    // ── priority: stop beats everything ──────────────────────────────────
    func testStopBeatsExtendAndCapture() {
        assertParse("stop and add ten", .stop)
        assertParse("note this then stop", .stop)
    }
}

// MARK: - Effect mapping + acks

final class FocusEffectTests: XCTestCase {

    func testEffectMappingAndAcks() {
        XCTAssertEqual(FocusCommand.stop.effect, .stop)
        XCTAssertEqual(FocusCommand.stop.effect.ack, "Nice work.")

        XCTAssertEqual(FocusCommand.keepGoing.effect, .keepGoing)
        XCTAssertEqual(FocusCommand.keepGoing.effect.ack, "Okay, keep going.")

        XCTAssertEqual(FocusCommand.extend(minutes: 10).effect, .extend(minutes: 10))
        XCTAssertEqual(FocusCommand.extend(minutes: 10).effect.ack, "Added 10 minutes.")

        XCTAssertEqual(FocusCommand.capture(text: "buy milk").effect, .capture(text: "buy milk"))
        XCTAssertEqual(FocusCommand.capture(text: "buy milk").effect.ack, "Got it.")

        XCTAssertEqual(FocusCommand.none.effect, .none)
        XCTAssertNil(FocusCommand.none.effect.ack)
    }

    func testExtendEffectReclampsOutOfRange() {
        XCTAssertEqual(FocusCommand.extend(minutes: 999).effect, .extend(minutes: 120))
        XCTAssertEqual(FocusCommand.extend(minutes: 0).effect, .extend(minutes: 1))
    }

    func testNoEffectDeletesData() {
        // Guard: assert no effect case is a destructive delete (capture SAVES,
        // stop FINISHES — neither removes). This is a compile-time guarantee
        // (the enum has no .delete case) made explicit here for the audit.
        let all: [FocusEffect] = [.extend(minutes: 5), .keepGoing, .stop, .capture(text: "x"), .none]
        for e in all {
            switch e {
            case .extend, .keepGoing, .stop, .capture, .none: break  // exhaustive: no delete
            }
        }
        XCTAssertTrue(true)
    }
}
