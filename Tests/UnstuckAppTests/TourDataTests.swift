// Guided-tour pure-logic tests — the iOS port of the web tour-data.test.ts /
// tour-ask.test.ts coverage: step lists, resume/auto-show decisions, canned
// answerFor, persistence round-trip (unstuck.tour.v1 parity), the ask-wire
// builder + fallback, the speed cycle, and the panel-dock rule (Ahmad's
// non-negotiable #1: the panel docks OPPOSITE the target, and collapses
// instead of covering the ring).

import XCTest
@testable import Unstuck

final class TourDataTests: XCTestCase {
    // MARK: - step lists

    func testEssentialStepCountAndOrder() {
        XCTAssertEqual(TourScript.essential.count, 9)
        XCTAssertEqual(TourScript.essential.map(\.id),
                       ["welcome", "today", "first-action", "assistant", "focus",
                        "capture", "reentry", "notifications", "finish"])
    }

    func testFullStepCountAndOrder() {
        XCTAssertEqual(TourScript.full.count, 14)
        XCTAssertEqual(TourScript.full.map(\.id),
                       ["welcome", "today", "first-action", "calendar", "captures",
                        "collections", "assistant", "focus", "reentry", "sharing",
                        "insights", "notifications", "personalization", "finish"])
    }

    func testFullSharesEssentialStepContent() {
        // The full tour reuses the SAME shared steps (web `essential(id)` —
        // drift would render holes).
        for id in ["assistant", "focus", "reentry", "notifications", "finish"] {
            let e = TourScript.essential.first { $0.id == id }!
            let f = TourScript.full.first { $0.id == id }!
            XCTAssertEqual(e.title, f.title, id)
            XCTAssertEqual(e.body, f.body, id)
            XCTAssertEqual(e.narration, f.narration, id)
            XCTAssertEqual(e.primary, f.primary, id)
        }
    }

    func testEveryStepHasCopyAndUniqueIds() {
        for steps in [TourScript.essential, TourScript.full] {
            XCTAssertEqual(Set(steps.map(\.id)).count, steps.count)
            for s in steps {
                XCTAssertFalse(s.title.isEmpty, s.id)
                XCTAssertFalse(s.body.isEmpty, s.id)
                XCTAssertFalse(s.narration.isEmpty, s.id)
                XCTAssertFalse(s.primary.isEmpty, s.id)
            }
        }
    }

    func testSettingsStepsCarrySections() {
        let notif = TourScript.essential.first { $0.id == "notifications" }!
        XCTAssertEqual(notif.view, .settings)
        XCTAssertEqual(notif.section, "Notifications")
        let pers = TourScript.full.first { $0.id == "personalization" }!
        XCTAssertEqual(pers.section, "Interface")
    }

    func testFocusStepsPresentTheDemoSurface() {
        // Round 2: focus/capture render the tour's own DEMO focus surface;
        // their spotlight targets live INSIDE the demo (always resolvable —
        // no fallbacks needed) and no session/navigation ever happens.
        let focus = TourScript.essential.first { $0.id == "focus" }!
        XCTAssertTrue(focus.isDemoFocus)
        XCTAssertEqual(focus.target, .focusRing)
        XCTAssertTrue(focus.targetFallbacks.isEmpty)
        let capture = TourScript.essential.first { $0.id == "capture" }!
        XCTAssertTrue(capture.isDemoFocus)
        XCTAssertEqual(capture.target, .captureHint)
        XCTAssertTrue(capture.targetFallbacks.isEmpty)
        // No other step is a demo step.
        for s in TourScript.full where !["focus", "capture"].contains(s.id) {
            XCTAssertFalse(s.isDemoFocus, s.id)
        }
    }

    func testTodayAndFinishRingTheTodayList() {
        // The Start-Next hero (2026-09-18) and the "Nothing scheduled today"
        // backlog pointer (2026-09-17) are both gone from Today: the list
        // section is the primary anchor, and it is always mounted on Today,
        // so no fallback chain remains.
        for id in ["today", "finish"] {
            let s = TourScript.essential.first { $0.id == id }!
            XCTAssertEqual(s.target, .todayList, id)
            XCTAssertTrue(s.targetFallbacks.isEmpty, id)
        }
        XCTAssertFalse(TourTargetID.allCases.map(\.rawValue).contains("start-next"),
                       "the start-next anchor must not linger once the hero is gone")
    }

    func testNoStepCopyNamesTheRemovedStartNextHero() {
        // Body, narration and more must not point the user at a card that no
        // longer exists on the iOS home.
        for s in TourScript.full {
            for text in [s.body, s.narration, s.more ?? ""] {
                XCTAssertFalse(text.range(of: "start next", options: .caseInsensitive) != nil,
                               "'\(s.id)' still mentions Start Next: \(text)")
            }
        }
    }

    func testStepsForMode() {
        XCTAssertEqual(TourScript.steps(for: .essential).count, 9)
        XCTAssertEqual(TourScript.steps(for: .full).count, 14)
    }

    // MARK: - canned Q&A (answerFor)

    func testAnswerForMatchesKnownQuestions() {
        XCTAssertTrue(tourAnswer(for: "What is usable time?").contains("focus time you realistically have"))
        XCTAssertTrue(tourAnswer(for: "Does it work OFFLINE?").contains("works offline"))
        // The restart answer names the ACTUAL Settings row label ("Product
        // tour" — SettingsFeature's Account card), not a phantom one.
        XCTAssertTrue(tourAnswer(for: "how do I restart the tour").contains("Settings → Account → Product tour"))
        XCTAssertTrue(tourAnswer(for: "why is unstuck different from a task manager")
            .contains("A planner assumes deciding is the hard part"))
        XCTAssertTrue(tourAnswer(for: "difference between partner and assign?").contains("Partner:"))
    }

    func testAnswerForIsCaseInsensitive() {
        XCTAssertEqual(tourAnswer(for: "USABLE TIME"), tourAnswer(for: "usable time"))
    }

    func testAnswerForFallsBackOnUnknown() {
        XCTAssertEqual(tourAnswer(for: "what's the meaning of life"), TOUR_FALLBACK_ANSWER)
    }

    // MARK: - initial phase (auto-show rules)

    func testInitialPhaseDoneStaysHidden() {
        XCTAssertEqual(tourInitialPhase(TourState(done: true, eligible: true)), .hidden)
    }

    func testInitialPhasePausedRunOffersResume() {
        XCTAssertEqual(tourInitialPhase(TourState(started: true, paused: true, mode: .essential)), .paused)
    }

    func testInitialPhasePausedWithoutModeHidden() {
        // A paused flag without a mode can't resume — treated as hidden.
        XCTAssertEqual(tourInitialPhase(TourState(started: true, paused: true)), .hidden)
    }

    func testInitialPhaseStartedStaysHidden() {
        XCTAssertEqual(tourInitialPhase(TourState(started: true)), .hidden)
    }

    func testInitialPhaseEligibleGetsWelcomeOnce() {
        XCTAssertEqual(tourInitialPhase(TourState(eligible: true)), .welcome)
    }

    func testInitialPhaseExistingAccountsNeverAmbushed() {
        XCTAssertEqual(tourInitialPhase(TourState()), .hidden)
    }

    // MARK: - resume decision (explicit open)

    func testResumeDecisionResumesSavedStep() {
        XCTAssertEqual(tourResumeDecision(TourState(started: true, index: 4)), .running(index: 4))
    }

    func testResumeDecisionFreshShowsWelcome() {
        XCTAssertEqual(tourResumeDecision(TourState()), .welcome)
        XCTAssertEqual(tourResumeDecision(TourState(started: true)), .welcome)   // no index
        XCTAssertEqual(tourResumeDecision(TourState(index: 3)), .welcome)        // never started
    }

    func testResumeDecisionFinishedTourRestartsAtWelcome() {
        // Settings → Product tour on a FINISHED tour = web restart semantics:
        // the welcome card (index 0), never a "resume" at the final step.
        XCTAssertEqual(tourResumeDecision(TourState(started: true, done: true, index: 8)), .welcome)
        // An explicitly-unfinished run still resumes.
        XCTAssertEqual(tourResumeDecision(TourState(started: true, done: false, index: 4)), .running(index: 4))
    }

    // MARK: - persistence round-trip (unstuck.tour.v1 parity)

    private func freshDefaults() -> UserDefaults {
        let name = "test.tour.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testStoreKeyParity() {
        XCTAssertEqual(TourStore.key, "unstuck.tour.v1")
    }

    func testStoreLoadEmptyIsBlankState() {
        let store = TourStore(defaults: freshDefaults())
        XCTAssertEqual(store.load(), TourState())
    }

    func testStoreSavePatchMergesAndRoundTrips() {
        let store = TourStore(defaults: freshDefaults())
        store.save { $0.mode = .full; $0.started = true; $0.index = 5 }
        store.save { $0.mediaMode = .listen; $0.speed = 1.5 }
        let s = store.load()
        XCTAssertEqual(s.mode, .full)
        XCTAssertEqual(s.started, true)
        XCTAssertEqual(s.index, 5)
        XCTAssertEqual(s.mediaMode, .listen)
        XCTAssertEqual(s.speed, 1.5)
        XCTAssertNil(s.done)
        XCTAssertNil(s.paused)
    }

    func testStoreShapeMatchesWebKeys() throws {
        // The stored blob uses the exact web field names (mode/mediaMode/… as
        // raw JSON keys) so the semantics stay portable.
        let defaults = freshDefaults()
        let store = TourStore(defaults: defaults)
        store.save {
            $0.started = true; $0.done = false; $0.paused = true; $0.eligible = true
            $0.mode = .essential; $0.mediaMode = .read; $0.speed = 1.25; $0.index = 2
            $0.chipDismissed = true
        }
        let data = try XCTUnwrap(defaults.data(forKey: TourStore.key))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["mode"] as? String, "essential")
        XCTAssertEqual(obj["mediaMode"] as? String, "read")
        XCTAssertEqual(obj["started"] as? Bool, true)
        XCTAssertEqual(obj["paused"] as? Bool, true)
        XCTAssertEqual(obj["eligible"] as? Bool, true)
        XCTAssertEqual(obj["index"] as? Int, 2)
        XCTAssertEqual(obj["speed"] as? Double, 1.25)
        XCTAssertEqual(obj["chipDismissed"] as? Bool, true)
    }

    func testStoreSurvivesCorruptData() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: TourStore.key)
        let store = TourStore(defaults: defaults)
        XCTAssertEqual(store.load(), TourState())   // never crashes, blank state
    }

    // MARK: - speed cycle (0.75 → 2 → wrap)

    func testSpeedCycle() {
        XCTAssertEqual(nextTourSpeed(0.75), 1.0)
        XCTAssertEqual(nextTourSpeed(1.0), 1.25)
        XCTAssertEqual(nextTourSpeed(1.25), 1.5)
        XCTAssertEqual(nextTourSpeed(1.5), 1.75)
        XCTAssertEqual(nextTourSpeed(1.75), 2.0)
        XCTAssertEqual(nextTourSpeed(2.0), 0.75)   // wraps
    }

    // MARK: - panel placement (non-negotiable #1)

    private let screen = CGRect(x: 0, y: 0, width: 390, height: 844)

    func testTargetInTopHalfDocksPanelBottom() {
        let target = CGRect(x: 20, y: 100, width: 350, height: 120)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
    }

    func testTargetInBottomHalfDocksPanelTop() {
        let target = CGRect(x: 20, y: 700, width: 350, height: 80)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
    }

    func testNoTargetDocksBottomExpanded() {
        let p = tourPanelPlacement(target: nil, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
    }

    func testTallTargetSpanningBothHalvesCollapsesInsteadOfCovering() {
        // A target from y=100 to y=744 leaves ~100pt below — nowhere near the
        // expanded panel height, so the panel must collapse, not cover the ring.
        let target = CGRect(x: 20, y: 100, width: 350, height: 644)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340)
        XCTAssertTrue(p.collapsed)
    }

    func testRingPaddingCountsAgainstFreeSpace() {
        // Target bottom at y=400: free space below WITHOUT the ring pad is
        // 844 - 400 - 32 = 412 (a 405 panel would fit); WITH the 14pt ring pad
        // it's 398 < 405 → the ring must win → collapsed.
        let target = CGRect(x: 20, y: 100, width: 350, height: 300)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 405)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertTrue(p.collapsed)
    }

    func testZeroSizedTargetTreatedAsNone() {
        let p = tourPanelPlacement(target: .zero, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
    }

    // MARK: - keyboard rule (the Ask field owns focus)

    func testKeyboardForcesTopDockOverBottomPreference() {
        // A top-half target normally docks the panel BOTTOM — but the keyboard
        // owns the bottom of the screen, so focus forces the TOP dock.
        let target = CGRect(x: 20, y: 100, width: 350, height: 120)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
    }

    func testKeyboardSuppressesCollapseRule() {
        // This tall target collapses the panel WITHOUT the keyboard (see
        // testTallTargetSpanningBothHalvesCollapsesInsteadOfCovering). With
        // the Ask field focused a collapse would UNMOUNT the field and drop
        // the keyboard in a loop — the keyboard rule must win.
        let target = CGRect(x: 20, y: 100, width: 350, height: 644)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
    }

    func testKeyboardAppliesWithNoTarget() {
        // Whisper-scrim steps default the panel to the bottom — still forced
        // top while typing, or the keyboard would cover the field.
        let p = tourPanelPlacement(target: nil, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
    }

    func testKeyboardOffKeepsExistingRules() {
        // The default (keyboard: false) is byte-for-byte the old behavior.
        let target = CGRect(x: 20, y: 100, width: 350, height: 120)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: false)
        XCTAssertEqual(p, tourPanelPlacement(target: target, screen: screen, panelHeight: 340))
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertEqual(p.topOffset, 0, "the nudge is keyboard-time only")
    }

    // MARK: - keyboard × top-half ring (round 3 — the documented nudge)

    func testKeyboardNudgesTopDockBelowATopRingWhenBothFit() {
        // Ring: target (20,80,350,60) + 14pt pad → maxY 154. With a 260pt
        // panel: 154 + 16 + 260 + 16 = 446 ≤ 464 (55% keyboard floor) → the
        // panel is nudged to sit just below the ring (offset = ring.maxY +
        // margin − default panel top = 154).
        let target = CGRect(x: 20, y: 80, width: 350, height: 60)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 260, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.topOffset, 154)
    }

    func testKeyboardAcceptsOverlapWhenTheNudgeCannotFit() {
        // Same ring, 340pt panel: 154 + 16 + 340 + 16 = 526 > 464 — nudging
        // would shove the panel under the keyboard, so the PANEL WINS the
        // overlap (documented decision: typing is the user's current intent;
        // the ring's claim behavior is unchanged — tourClaims checks the
        // panel frame first, and a cutoutInteractive ring still passes
        // through wherever the panel doesn't cover it).
        let target = CGRect(x: 20, y: 80, width: 350, height: 60)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.topOffset, 0)
    }

    func testKeyboardNoNudgeWhenTheRingDoesNotOverlapTheTopDock() {
        // A bottom-half ring never conflicts with the forced top dock.
        let target = CGRect(x: 20, y: 700, width: 350, height: 80)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertEqual(p.topOffset, 0)
        // No target at all → no nudge either.
        XCTAssertEqual(tourPanelPlacement(target: nil, screen: screen,
                                          panelHeight: 340, keyboard: true).topOffset, 0)
    }
}

// MARK: - ask wire + fallback (web tour-ask.test.ts port)

final class TourAskTests: XCTestCase {
    private let step = TourScript.essential.first { $0.id == "today" }!

    func testBuildTourPromptEmbedsMarkTitleAndQuestion() {
        let p = buildTourPrompt(stepTitle: step.title, stepBody: step.body, question: "  what is backlog?  ")
        XCTAssertTrue(p.contains(TOUR_CONTEXT_MARK))
        XCTAssertTrue(p.contains(step.title))
        XCTAssertTrue(p.hasSuffix("Question: what is backlog?"))
        XCTAssertTrue(p.contains("without using any tools"))
    }

    func testBuildTourPromptTruncatesLongBodies() {
        let longBody = String(repeating: "a", count: 400)
        let p = buildTourPrompt(stepTitle: "T", stepBody: longBody, question: "q")
        XCTAssertTrue(p.contains("…"))
        XCTAssertFalse(p.contains(String(repeating: "a", count: 300)))
    }

    func testFirstAskEmbedsFraming() {
        let wire = buildAskWire(stepTitle: step.title, stepBody: step.body, thread: [], question: "why?")
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire[0].role, .user)
        XCTAssertTrue(wire[0].content.contains(TOUR_CONTEXT_MARK))
    }

    func testFollowUpKeepsFramedHistoryWithoutReembedding() {
        let thread = [
            TourAskMessage(role: .user, content: buildTourPrompt(stepTitle: step.title, stepBody: step.body, question: "q1")),
            TourAskMessage(role: .assistant, content: "a1"),
        ]
        let wire = buildAskWire(stepTitle: step.title, stepBody: step.body, thread: thread, question: "q2")
        XCTAssertEqual(wire.count, 3)
        XCTAssertEqual(wire.last?.content, "q2")   // plain — framing already present
    }

    func testCapDropsOldTurnsAndReembedsFraming() {
        // 6 messages of history: the cap keeps the last 4; the framed first
        // turn falls off, so the new question is re-framed.
        var thread: [TourAskMessage] = [
            TourAskMessage(role: .user, content: buildTourPrompt(stepTitle: step.title, stepBody: step.body, question: "q1")),
            TourAskMessage(role: .assistant, content: "a1"),
        ]
        for i in 2...3 {
            thread.append(TourAskMessage(role: .user, content: "q\(i)"))
            thread.append(TourAskMessage(role: .assistant, content: "a\(i)"))
        }
        let wire = buildAskWire(stepTitle: step.title, stepBody: step.body, thread: thread, question: "q4")
        XCTAssertEqual(wire.count, 5)   // 4 kept + the new question
        XCTAssertEqual(wire.first?.role, .user)   // always starts at a user turn
        XCTAssertTrue(wire.last!.content.contains(TOUR_CONTEXT_MARK))   // re-framed
    }

    func testCapNeverStartsWithAssistantTurn() {
        let thread = [
            TourAskMessage(role: .assistant, content: "orphan"),
            TourAskMessage(role: .user, content: "q"),
            TourAskMessage(role: .assistant, content: "a"),
        ]
        let wire = buildAskWire(stepTitle: step.title, stepBody: step.body, thread: thread, question: "next")
        XCTAssertEqual(wire.first?.role, .user)
    }

    func testResolveAskReplyPassesRealAnswerThrough() {
        let r = resolveAskReply("  A real answer.  ", question: "usable time")
        XCTAssertEqual(r.text, "A real answer.")
        XCTAssertTrue(r.fromAssistant)
    }

    func testResolveAskReplyFallsBackOnNilOrEmpty() {
        // nil (error/timeout) and tool-calls-only (empty content) both answer
        // canned — instantly, unlabelled.
        for content in [nil, "", "   "] {
            let r = resolveAskReply(content, question: "usable time")
            XCTAssertFalse(r.fromAssistant)
            XCTAssertTrue(r.text.contains("focus time you realistically have"))
        }
    }

    func testResolveAskReplyUnknownQuestionUsesGenericFallback() {
        XCTAssertEqual(resolveAskReply(nil, question: "zzz").text, TOUR_FALLBACK_ANSWER)
    }
}
