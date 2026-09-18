// Guided-tour pure-logic tests — the iOS port of the web tour-data.test.ts /
// tour-ask.test.ts coverage: step lists, resume/auto-show decisions, canned
// answerFor, persistence round-trip (unstuck.tour.v1 parity), the ask-wire
// builder + fallback, the speed cycle, and the panel-dock rule (Ahmad's
// non-negotiable #1: the panel docks OPPOSITE the target, and collapses
// instead of covering the ring).

import SwiftUI
import UIKit
import UnstuckDesign
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
        // longer exists on the iOS home. BOTH scripts, because `full` is NOT a
        // superset of `essential`: it keeps welcome / today / first-action and
        // finish but drops focus, capture, assistant, reentry and
        // notifications — iterating one script alone leaves five steps
        // unguarded.
        var seen = Set<String>()
        let allSteps = (TourScript.essential + TourScript.full).filter { seen.insert($0.id).inserted }
        XCTAssertEqual(allSteps.count, 15, "9 essential + 6 full-only steps")
        for s in allSteps {
            for text in [s.body, s.narration, s.more ?? ""] {
                XCTAssertFalse(text.range(of: "start next", options: .caseInsensitive) != nil,
                               "'\(s.id)' still mentions Start Next: \(text)")
            }
        }
        // The canned Q&A is tour copy too — a stock answer describing the card
        // would be just as wrong as a step body.
        for qa in TOUR_QA {
            XCTAssertFalse(qa.answer.range(of: "start next", options: .caseInsensitive) != nil,
                           "a canned tour answer still names Start Next: \(qa.answer)")
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
        XCTAssertNil(p.maxHeight, "578pt free below the ring fits the panel whole — no cap")
    }

    func testTargetInBottomHalfDocksPanelTop() {
        let target = CGRect(x: 20, y: 700, width: 350, height: 80)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertNil(p.maxHeight)
    }

    func testNoTargetDocksBottomExpanded() {
        let p = tourPanelPlacement(target: nil, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
        XCTAssertNil(p.maxHeight, "no ring to avoid → the panel hugs its copy")
    }

    func testTallTargetSpanningBothHalvesCollapsesInsteadOfCovering() {
        // A target from y=100 to y=744 leaves 54pt on either side — not even a
        // readable panel fits, so the panel must collapse, not cover the ring,
        // and is floored at the collapsed minimum so its controls stay usable.
        let target = CGRect(x: 20, y: 100, width: 350, height: 644)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340)
        XCTAssertTrue(p.collapsed)
        XCTAssertEqual(p.maxHeight, TourPanelMetrics.collapsedMin)
    }

    func testRingPaddingCountsAgainstFreeSpace() {
        // Target bottom at y=400: free space below WITHOUT the ring pad is
        // 844 - 400 - 32 = 412 (a 405 panel would fit whole); WITH the 14pt ring
        // pad it's 398 < 405 → the ring wins, and the panel is CAPPED to those
        // 398pt (well clear of the readable minimum) rather than collapsed.
        let target = CGRect(x: 20, y: 100, width: 350, height: 300)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 405)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.maxHeight, 398)
    }

    func testZeroSizedTargetTreatedAsNone() {
        let p = tourPanelPlacement(target: .zero, screen: screen, panelHeight: 340)
        XCTAssertEqual(p.dock, .bottom)
        XCTAssertFalse(p.collapsed)
        XCTAssertNil(p.maxHeight)
    }

    // MARK: - the today/finish regression (2026-09-18, 6.3" phones)

    /// The 6.3" iPhone the today/finish steps rendered title-only on (iPhone
    /// 16/17 Pro — 402 × 874pt, 62pt Dynamic-Island inset, 34pt home
    /// indicator). The tour's GeometryReader is safe-area-inset — it ignores
    /// only the KEYBOARD — so this is the rect the rule actually sees.
    private let screen63 = CGRect(x: 0, y: 62, width: 402, height: 778)

    /// The ringed Today list, MEASURED off the running tour — TourUITests'
    /// 02-today shot on that simulator (1206 × 2622px at 3×). The ring's 2pt
    /// primary stroke occupies 341.0 → 343.0pt at the top and 680.0 → 682.0 at
    /// the bottom, so it is CENTRED on 342 and 681. TourSpotlight strokes
    /// `target.insetBy(-8)` — the 8pt spotlight pad, NOT the 14pt `ringPad` the
    /// placement rule adds for the halo — so the list itself runs 350 → 673:
    /// 288pt below the safe-area top, 323 tall.
    ///
    /// The chrome above the list — top bar, greeting, week pill, assistant
    /// pill, filters — is the same stack on every iPhone, so the list always
    /// starts that same 288pt down; that is what `todayList(on:)` re-uses for
    /// the other screen sizes.
    private func todayList(on screen: CGRect) -> CGRect {
        CGRect(x: 10, y: screen.minY + 288, width: screen.width - 20, height: 323)
    }

    /// What that leaves the panel above the ring on every one of these phones:
    /// (288 − 14 ringPad) − 2 × 16 margin = 242pt. The readable minimum is
    /// 233.66, so the headroom is 8.3pt — a third of a line of copy. Any extra
    /// chrome in the Today header eats it, which is what `TourPanelMeasureTests`
    /// and this fixture exist to catch.
    private let todayFree: CGFloat = 242

    func testTodayStepStaysExpandedOn63InchPhone() {
        // The today panel measures 358pt (title + seven lines of copy + mini
        // links + chrome — TourPanelMeasureTests pins it) and only 242pt is
        // free above the ring. The old all-or-nothing rule collapsed it there —
        // title + footer, the step's whole body hidden. 242 clears the readable
        // minimum (233.66) by 8.3pt, so it stays EXPANDED and scrolls under the
        // cap instead.
        let p = tourPanelPlacement(target: todayList(on: screen63), screen: screen63, panelHeight: 358)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed, "242pt holds a readable panel — it must not collapse")
        XCTAssertEqual(p.maxHeight, todayFree)
        XCTAssertGreaterThanOrEqual(p.maxHeight ?? 0, TourPanelMetrics.readableMin)
    }

    func testFinishStepStaysExpandedOn63InchPhone() {
        // Same anchor, shorter copy (295pt measured): same dock, same cap,
        // expanded.
        let p = tourPanelPlacement(target: todayList(on: screen63), screen: screen63, panelHeight: 295)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.maxHeight, todayFree)
    }

    func testTodayListStaysExpandedOnASmallPhone() {
        // 5.4" (375 × 812pt, 50pt notch inset): the Today chrome is the same
        // stack, so the free space above the ring is the same 242pt. The panel
        // is 327pt wide there and the copy still wraps to seven lines — 358pt,
        // measured.
        let small = CGRect(x: 0, y: 50, width: 375, height: 728)
        let p = tourPanelPlacement(target: todayList(on: small), screen: small, panelHeight: 358)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.maxHeight, todayFree)
    }

    func testTodayListStaysExpandedOnALargePhone() {
        // 6.9" (440 × 956pt): the panel hits its own 380pt maxWidth there, so
        // the copy wraps into one fewer line — 337pt measured, still taller
        // than the 242pt above the ring.
        let large = CGRect(x: 0, y: 62, width: 440, height: 860)
        let p = tourPanelPlacement(target: todayList(on: large), screen: large, panelHeight: 337)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertEqual(p.maxHeight, todayFree)
    }

    func testRingFillingNearlyTheWholeScreenStillCollapsesWithAFloor() {
        // 90 → 790pt of a 778pt usable screen: 0pt above the ring, 4pt below.
        // Nothing readable fits either side → the roomier side, title-only,
        // floored so the controls are still there to tap.
        let p = tourPanelPlacement(target: CGRect(x: 18, y: 90, width: 366, height: 700),
                                   screen: screen63, panelHeight: 354)
        XCTAssertTrue(p.collapsed)
        XCTAssertEqual(p.dock, .bottom, "4pt beats 0pt")
        XCTAssertEqual(p.maxHeight, TourPanelMetrics.collapsedMin)
    }

    func testPreferredDockIsAlwaysTheRoomierSide() {
        // Docking "opposite the target" IS choosing the roomier side: a center
        // above the screen's mid-line means more space below the ring than
        // above it. That identity is why the flip to the other side is a
        // safety net and not a branch any geometry can reach — assert it over
        // a high ring, a low ring, and one that runs off the bottom.
        for target in [CGRect(x: 18, y: 100, width: 366, height: 120),     // high
                       CGRect(x: 18, y: 700, width: 366, height: 90),      // low
                       todayList(on: screen63),                            // the Today list
                       CGRect(x: 18, y: 400, width: 366, height: 900)] {   // off the bottom
            let ring = target.insetBy(dx: -14, dy: -14)
            let above = max(0, ring.minY - screen63.minY - 32)
            let below = max(0, screen63.maxY - ring.maxY - 32)
            let p = tourPanelPlacement(target: target, screen: screen63, panelHeight: 354)
            XCTAssertEqual(p.dock, below > above ? .bottom : .top, "target \(target)")
        }
    }

    func testAHighRingDocksTheFullPanelBelowItAndALowRingAboveIt() {
        let high = tourPanelPlacement(target: CGRect(x: 18, y: 100, width: 366, height: 120),
                                      screen: screen63, panelHeight: 354)
        XCTAssertEqual(high.dock, .bottom)
        XCTAssertNil(high.maxHeight, "574pt below the ring fits the whole panel")
        let low = tourPanelPlacement(target: CGRect(x: 18, y: 700, width: 366, height: 90),
                                     screen: screen63, panelHeight: 354)
        XCTAssertEqual(low.dock, .top)
        XCTAssertNil(low.maxHeight, "592pt above it does too")
    }

    func testACappedHeightFedBackWouldFlipTheDecision() {
        // Why TourModel.reportPanelHeight measures the panel's BODY inside its
        // scroll view (and its chrome outside the cap) instead of trusting the
        // rendered frame: a capped panel's frame IS the cap. Hand 242 back as
        // "the expanded height" and the rule says it fits — the panel re-expands
        // to its natural 358, covers the ring, measures 358, caps again. Once
        // "expanded but capped" exists, a capped measurement is as poisonous as
        // a collapsed one.
        let capped = tourPanelPlacement(target: todayList(on: screen63), screen: screen63, panelHeight: 358)
        XCTAssertEqual(capped.maxHeight, todayFree)
        let poisoned = tourPanelPlacement(target: todayList(on: screen63), screen: screen63,
                                          panelHeight: capped.maxHeight ?? 0)
        XCTAssertNil(poisoned.maxHeight, "a capped height fed back flips the rule to 'it fits'")
        // Fed its true natural height the rule is a fixed point, cap and all.
        XCTAssertEqual(tourPanelPlacement(target: todayList(on: screen63), screen: screen63,
                                          panelHeight: 358), capped)
    }

    func testReadableMinimumIsThreeLinesOfCopyAboveTheCollapsedFloor() {
        // The metrics are MEASURED off the real panel (TourPanelMeasureTests
        // re-measures every one of them); these pin the arithmetic built on
        // top, so a change to either shows up in both places.
        XCTAssertEqual(TourPanelMetrics.collapsedMin, 165)
        XCTAssertEqual(TourPanelMetrics.readableMin, 233.66, accuracy: 0.01)
        // title→body gap + three RENDERED Geist-13.5 line boxes (18.22 each,
        // not the face's 17.55) + the two 3pt line gaps.
        let threeLines: CGFloat = 8 + 18.22 * 3 + 3 * 2
        XCTAssertEqual(TourPanelMetrics.readableMin - TourPanelMetrics.collapsedMin,
                       threeLines, accuracy: 0.01)
        // And the headroom that leaves on the tightest real step: a third of a
        // line. This is the number that decides today/finish.
        XCTAssertEqual(todayFree - TourPanelMetrics.readableMin, 8.34, accuracy: 0.01)
    }

    // MARK: - keyboard rule (the Ask field owns focus)

    func testKeyboardForcesTopDockOverBottomPreference() {
        // A top-half target normally docks the panel BOTTOM — but the keyboard
        // owns the bottom of the screen, so focus forces the TOP dock.
        let target = CGRect(x: 20, y: 100, width: 350, height: 120)
        let p = tourPanelPlacement(target: target, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertNil(p.maxHeight, "and never capped — a cap could scroll the focused field away")
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
        XCTAssertNil(p.maxHeight)
    }

    func testKeyboardAppliesWithNoTarget() {
        // Whisper-scrim steps default the panel to the bottom — still forced
        // top while typing, or the keyboard would cover the field.
        let p = tourPanelPlacement(target: nil, screen: screen, panelHeight: 340, keyboard: true)
        XCTAssertEqual(p.dock, .top)
        XCTAssertFalse(p.collapsed)
        XCTAssertNil(p.maxHeight)
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

// MARK: - the metrics, measured off the REAL panel

/// `TourPanelMetrics` is the placement rule's model of the panel, and every
/// number in it is measured rather than derived — SwiftUI's rendered line box
/// for Geist 13.5 is 18.22pt where the face's own line height is 17.55, and the
/// pause confirm makes the footer twice its documented size. A model that drifts
/// from the panel mis-places it silently, so this suite re-measures the panel
/// itself: a padding or font change fails HERE, with the new number in the
/// failure message, instead of quietly under-provisioning a cap.
@MainActor
final class TourPanelMeasureTests: XCTestCase {
    /// A 402 × 874pt phone, less the running layer's 2 × 24pt horizontal
    /// padding: the width the today/finish panels are actually laid out at.
    private let panelWidth: CGFloat = 354
    private let expanded = TourPanelPlacement(dock: .top, collapsed: false, maxHeight: nil)
    private let collapsed = TourPanelPlacement(dock: .top, collapsed: true, maxHeight: nil)

    private func freshStore() -> TourStore {
        let name = "test.tour.measure.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return TourStore(defaults: d)
    }

    /// Render the view FOR REAL — in a window, through several layout passes —
    /// before reading its height: the panel measures its own chrome with
    /// `onGeometryChange`, and a bare `sizeThatFits` reports the first pass,
    /// where that is still the seed value.
    private func mount<V: View>(_ v: V, width: CGFloat? = nil) -> (UIWindow, UIHostingController<V>) {
        let w = width ?? panelWidth
        let vc = UIHostingController(rootView: v)
        // The panel is measured on its own, not inside a screen: without this
        // the host window donates its safe-area insets and every reading comes
        // back 54pt tall.
        vc.safeAreaRegions = []
        // On the host app's real window scene: a detached window never gets a
        // display pass, and UIKit-level scroll state (contentSize, offset) never
        // catches up with SwiftUI's layout.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: w, height: 900)
        window.rootViewController = vc
        window.isHidden = false
        return (window, vc)
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func height<V: View>(_ v: V, width: CGFloat? = nil) -> CGFloat {
        let (window, vc) = mount(v, width: width)
        settle(window)
        defer { window.isHidden = true }
        return vc.sizeThatFits(in: CGSize(width: width ?? panelWidth,
                                          height: .greatestFiniteMagnitude)).height
    }

    /// The panel's body scroll view — the only one mounted unless the Ask
    /// thread is open.
    private func bodyScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let s = bodyScrollView(in: sub) { return s }
        }
        return nil
    }

    private func tourOn(_ stepID: String, _ body: (TourModel) -> Void) {
        let app = AppModel()
        let tour = TourModel(app: app, store: freshStore())
        tour.begin(.essential)
        while tour.currentStep.id != stepID && tour.phase == .running { tour.advance() }
        XCTAssertEqual(tour.currentStep.id, stepID)
        body(tour)
        tour.exit()
    }

    func testTheCollapsedPanelMeasuresTheCollapsedMinimum() {
        tourOn("today") { tour in
            // chrome + the body block a collapsed panel keeps (padding + title).
            XCTAssertEqual(height(TourPanel(tour: tour, placement: collapsed)),
                           TourPanelMetrics.collapsedMin, accuracy: 1)
        }
    }

    func testOneTitleLineAndThreeBodyLinesMatchTheMetrics() {
        let inner = panelWidth - 32
        XCTAssertEqual(height(Text("Today narrows it down").font(UFont.serifItalic(20))
                                .fixedSize(horizontal: false, vertical: true), width: inner),
                       TourPanelMetrics.title, accuracy: 0.5)
        // The three lines `readableMin` budgets for — line boxes plus the two
        // 3pt gaps between them.
        XCTAssertEqual(height(Text("A\nB\nC").font(UFont.sans(13.5)).lineSpacing(3), width: inner),
                       TourPanelMetrics.bodyLine * 3 + TourPanelMetrics.bodyLineSpacing * 2,
                       accuracy: 0.5)
    }

    /// Defect the round-1 fix left open: the chrome is NOT a constant.
    func testThePauseConfirmMakesTheChromeMeasurablyTaller() {
        tourOn("today") { tour in
            let controls = height(TourPanel(tour: tour, placement: expanded))
            tour.requestPause()
            let confirm = height(TourPanel(tour: tour, placement: expanded))
            tour.cancelPause()
            XCTAssertEqual(confirm - controls, 67, accuracy: 1,
                           "the inline pause confirm adds 67pt of FOOTER — a compile-time chrome "
                           + "constant under-reports the panel by exactly that much")
        }
    }

    /// The cap is a promise the panel has to keep whatever its footer is doing:
    /// the whole point is that it can never grow into the ring.
    func testACappedPanelNeverExceedsItsCapEvenWithTheConfirmOpen() {
        tourOn("today") { tour in
            let cap: CGFloat = 242          // what the Today ring leaves on a 6.3" phone
            let capped = TourPanelPlacement(dock: .top, collapsed: false, maxHeight: cap)
            XCTAssertEqual(height(TourPanel(tour: tour, placement: capped)), cap, accuracy: 1)
            tour.requestPause()
            XCTAssertLessThanOrEqual(height(TourPanel(tour: tour, placement: capped)), cap + 1)
            tour.cancelPause()
        }
    }

    /// The panel must never draw outside the frame it reports — `tour.panelFrame`
    /// is the hit-test claim, and a band of panel outside it sends touches
    /// straight through to the app. With the confirm open the real chrome (188)
    /// is above the collapsed floor (165), so the panel has to report the taller
    /// height rather than clamp to a frame it then overflows.
    func testACollapsedPanelReportsTheHeightItDraws() {
        tourOn("today") { tour in
            tour.requestPause()
            let floored = TourPanelPlacement(dock: .top, collapsed: true,
                                             maxHeight: TourPanelMetrics.collapsedMin)
            let natural = height(TourPanel(tour: tour, placement: collapsed))
            XCTAssertEqual(height(TourPanel(tour: tour, placement: floored)), natural, accuracy: 1,
                           "a collapsed panel under a cap smaller than its own chrome must report "
                           + "what it draws, not the cap")
            tour.cancelPause()
        }
    }

    /// The wiring behind all of it: the panel has to TELL the placement rule
    /// that its footer grew. The body's own geometry callback cannot — the copy
    /// above the footer is untouched when the confirm opens, so nothing about
    /// the body's height changes and `onGeometryChange` never fires. Without a
    /// second trigger the rule keeps placing a 358pt panel that is really 425,
    /// and the uncapped branch lets those 67pt run into the ring.
    func testTheReportedHeightFollowsTheFooterNotAConstant() {
        tourOn("today") { tour in
            let (window, _) = mount(TourPanel(tour: tour, placement: expanded))
            defer { window.isHidden = true }
            settle(window)
            let withControls = tour.panelExpandedHeight
            XCTAssertEqual(withControls, 358, accuracy: 2, "the panel's natural height")
            tour.requestPause()
            settle(window)
            XCTAssertEqual(tour.panelExpandedHeight - withControls, 67, accuracy: 2,
                           "the inline pause confirm makes the panel 67pt taller and the "
                           + "placement rule has to be told")
            tour.cancelPause()
            settle(window)
            XCTAssertEqual(tour.panelExpandedHeight, withControls, accuracy: 2,
                           "…and told again when it shrinks back")
        }
    }

    /// The body's scroll OFFSET is per-step state on a panel that is deliberately
    /// ONE structural identity across steps (TourRootView keeps a single
    /// flipping panel), so nothing resets it on its own: leave a capped step
    /// scrolled and the next capped step opens past its own first line.
    func testTheBodyScrollsBackToTheTopOnAStepChange() {
        tourOn("today") { tour in
            let capped = TourPanelPlacement(dock: .top, collapsed: false, maxHeight: 242)
            let (window, vc) = mount(TourPanel(tour: tour, placement: capped))
            defer { window.isHidden = true }
            settle(window)
            guard let scroll = bodyScrollView(in: vc.view) else {
                return XCTFail("the capped panel's body should be a scroll view")
            }
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1,
                                 "242pt cannot hold the 358pt today panel — the body must scroll")
            scroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
            settle(window)
            XCTAssertEqual(scroll.contentOffset.y, 40, accuracy: 1, "scrolled down 40pt")
            tour.advance()
            settle(window)
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1,
                                 "the next step's body still overflows — 40pt was a REACHABLE offset "
                                 + "there, so a reset is the only thing that can have moved it")
            XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 1,
                           "a step change must put the body back at its first line")
        }
    }

    /// The fixtures the placement tests use are real panel heights, and the
    /// today panel really is taller than the space its own ring leaves.
    func testTheTodayAndFinishPanelsMatchTheirPlacementFixtures() {
        tourOn("today") { tour in
            XCTAssertEqual(height(TourPanel(tour: tour, placement: expanded)), 358, accuracy: 1)
        }
        tourOn("finish") { tour in
            XCTAssertEqual(height(TourPanel(tour: tour, placement: expanded)), 295, accuracy: 1)
        }
        XCTAssertGreaterThan(358, 242, "the today panel does not fit above its ring — hence the cap")
        XCTAssertLessThanOrEqual(TourPanelMetrics.readableMin, 242,
                                 "…but a READABLE panel does, which is why it must not collapse")
    }
}
