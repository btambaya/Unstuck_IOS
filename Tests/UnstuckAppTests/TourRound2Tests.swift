// Guided-tour "Feedback round 2" pure-logic tests:
//  • live captions — the splitSentences port + the char-weighted sentence
//    picker that syncs the Listen bar to audio progress;
//  • spotlight-only lockdown — tourClaims(): the tour claims EVERYTHING
//    except the panel + the spotlight cutout, panel-only while a step-opened
//    sheet is up, everything on demo steps, chip-only while paused;
//  • the paused "Resume tour" chip — eligibility + chipDismissed persistence
//    + resume-at-step semantics;
//  • the audio manifest — every step has its narration clip, and every
//    Tell-me-more text has its <id>-more.m4a, ON DISK in the bundled dir.

import UIKit
import XCTest
@testable import Unstuck

// MARK: - live captions (splitSentences + char-weighted spans)

final class TourCaptionTests: XCTestCase {
    func testSplitBasicSentences() {
        XCTAssertEqual(splitTourSentences("One. Two! Three?"),
                       ["One.", "Two!", "Three?"])
    }

    func testSplitKeepsTrailingQuotesAndEllipsis() {
        XCTAssertEqual(splitTourSentences("He said “go.” Then he left…"),
                       ["He said “go.”", "Then he left…"])
    }

    func testSplitFoldsShortFragmentsIntoPrevious() {
        // A trailing fragment under 4 chars merges into the prior sentence
        // (never a 2-character caption).
        XCTAssertEqual(splitTourSentences("Hello there. Ok"),
                       ["Hello there. Ok"])
    }

    func testSplitNoPunctuationIsOneSentence() {
        XCTAssertEqual(splitTourSentences("just one line with no stops"),
                       ["just one line with no stops"])
    }

    func testSplitEmptyAndWhitespace() {
        XCTAssertEqual(splitTourSentences(""), [])
        XCTAssertEqual(splitTourSentences("   \n "), [])
    }

    func testSplitRealNarrationYieldsMultipleSentences() {
        // Every step's narration must produce at least one caption; the
        // welcome narration is known multi-sentence.
        for s in TourScript.full + TourScript.essential {
            XCTAssertFalse(splitTourSentences(s.narration).isEmpty, s.id)
            if let more = s.more {
                XCTAssertFalse(splitTourSentences(more).isEmpty, s.id)
            }
        }
        XCTAssertGreaterThan(splitTourSentences(TourScript.essential[0].narration).count, 2)
    }

    func testCaptionIndexEqualWeights() {
        let sentences = ["aaaa", "bbbb"]   // equal spans: 0–0.5, 0.5–1
        XCTAssertEqual(tourCaptionIndex(progress: 0, sentences: sentences), 0)
        XCTAssertEqual(tourCaptionIndex(progress: 0.49, sentences: sentences), 0)
        XCTAssertEqual(tourCaptionIndex(progress: 0.51, sentences: sentences), 1)
        XCTAssertEqual(tourCaptionIndex(progress: 1, sentences: sentences), 1)
    }

    func testCaptionIndexIsCharWeighted() {
        // 8 chars vs 2 chars → spans 0–0.8 and 0.8–1.
        let sentences = ["aaaaaaaa", "bb"]
        XCTAssertEqual(tourCaptionIndex(progress: 0.5, sentences: sentences), 0)
        XCTAssertEqual(tourCaptionIndex(progress: 0.79, sentences: sentences), 0)
        XCTAssertEqual(tourCaptionIndex(progress: 0.85, sentences: sentences), 1)
    }

    func testCaptionIndexClampsOutOfRange() {
        let sentences = ["one.", "two.", "three."]
        XCTAssertEqual(tourCaptionIndex(progress: -1, sentences: sentences), 0)
        XCTAssertEqual(tourCaptionIndex(progress: 2, sentences: sentences), 2)
        XCTAssertEqual(tourCaptionIndex(progress: 0.5, sentences: []), 0)
    }
}

// MARK: - spotlight-only lockdown (tourClaims)

final class TourClaimsTests: XCTestCase {
    private let panel = CGRect(x: 24, y: 500, width: 342, height: 320)
    private let target = CGRect(x: 40, y: 120, width: 310, height: 90)

    private func running(_ mutate: (inout TourClaimContext) -> Void = { _ in }) -> TourClaimContext {
        var ctx = TourClaimContext()
        ctx.running = true
        ctx.panelFrame = panel
        ctx.targetRect = target
        mutate(&ctx)
        return ctx
    }

    func testCardClaimsEverything() {
        var ctx = TourClaimContext()
        ctx.cardVisible = true
        XCTAssertTrue(tourClaims(point: CGPoint(x: 5, y: 5), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 800), ctx: ctx))
    }

    func testHiddenClaimsNothing() {
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 400), ctx: TourClaimContext()))
    }

    func testRunningClaimsThePanel() {
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: running()))
    }

    func testCutoutIsDisplayOnlyByDefault() {
        // Round-3 cutout policy: on ordinary steps the ring is VISUAL — the
        // cutout region is claimed and swallowed too. (A pass-through cutout
        // once let a tap on the spotlighted Start-Next hero mint a REAL
        // session; today it would open a real task from the ringed list.)
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 150), ctx: running()))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 40, y: 110), ctx: running()))
    }

    func testCutoutPassesThroughOnlyOnInteractiveSteps() {
        // assistant/reentry (cutoutInteractive): the ringed launcher must
        // stay tappable — inside the target and inside the ring pad (14pt).
        let ctx = running { $0.cutoutInteractive = true }
        XCTAssertFalse(tourClaims(point: CGPoint(x: 100, y: 150), ctx: ctx))
        XCTAssertFalse(tourClaims(point: CGPoint(x: 40, y: 110), ctx: ctx),
                       "ring-pad halo passes through too")
        // Outside the ring is still locked down even on interactive steps.
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: target.maxY + 15), ctx: ctx))
    }

    func testCutoutInteractiveOnlyOnAssistantAndReentrySteps() {
        for steps in [TourScript.essential, TourScript.full] {
            for s in steps {
                XCTAssertEqual(s.cutoutInteractive, ["assistant", "reentry"].contains(s.id),
                               "cutoutInteractive drift on '\(s.id)'")
            }
        }
    }

    func testRunningSwallowsEverythingElse() {
        // Lockdown: nav/tabs/dim panels — anywhere outside panel + cutout —
        // is claimed (and the swallow layer eats the touch).
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 400), ctx: running()))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 10, y: 830), ctx: running()),
                      "the tab bar is blocked while the tour runs")
        // Just OUTSIDE the ring pad → blocked.
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: target.maxY + 15), ctx: running()))
    }

    func testNoTargetStepClaimsAllButPanel() {
        let ctx = running { $0.targetRect = nil }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 150), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))   // panel
        let zero = running { $0.targetRect = .zero }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 2, y: 2), ctx: zero),
                      "a zero-sized target is treated as none")
    }

    func testOpenedSheetRevertsToPanelOnlyOnExemptSteps() {
        // Round 3: a presented surface unlocks ONLY on surfaceInteractive
        // steps (assistant/reentry/settings) — there the panel is claimed and
        // the whole sheet stays usable, cutout or not.
        let ctx = running {
            $0.presentationActive = true
            $0.surfaceExempt = true
        }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))    // panel
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 400), ctx: ctx))   // sheet body
        XCTAssertFalse(tourClaims(point: CGPoint(x: 100, y: 150), ctx: ctx))   // cutout area
        XCTAssertFalse(tourClaims(point: CGPoint(x: 10, y: 830), ctx: ctx))
    }

    func testOpenedSheetStaysLockedOnNonExemptSteps() {
        // Round 3 (the tester's video): the task-detail sheet on first-action
        // (and inbox/insights) is DISPLAY-ONLY — with no exemption the tour
        // claims everything except the panel, so estimate chips / custom-time
        // keypad / scroll can't happen mid-tour.
        let ctx = running { $0.presentationActive = true }   // surfaceExempt = false
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))    // panel
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 400), ctx: ctx),
                      "sheet body is swallowed")
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 150), ctx: ctx),
                      "even the ringed block is display-only")
        XCTAssertTrue(tourClaims(point: CGPoint(x: 10, y: 830), ctx: ctx))
    }

    func testSurfaceInteractiveOnlyOnAssistantReentryAndSettingsSteps() {
        // Drift guard, mirrors the cutoutInteractive one: the exemption is
        // exactly assistant + reentry + the settings steps.
        for steps in [TourScript.essential, TourScript.full] {
            for s in steps {
                let expected = ["assistant", "reentry", "notifications", "personalization"].contains(s.id)
                XCTAssertEqual(s.surfaceInteractive, expected,
                               "surfaceInteractive drift on '\(s.id)'")
            }
        }
    }

    func testDemoStepClaimsEverything() {
        // The demo focus surface fills the tour window: swallowed taps do
        // nothing and NOTHING underneath (Today) may react — even inside the
        // demo's own spotlight rect (its targets are demo-rendered).
        let ctx = running { $0.demoStep = true }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 400), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 150), ctx: ctx))    // "cutout"
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))    // panel
    }

    func testDemoStepClaimsEverythingEvenWithAPresentationUp() {
        // Round 3: demoStep beats the panel-only presentation reversion — a
        // LIVE real focus cover under the (opaque) demo must never receive
        // blind pass-through touches. Even cutoutInteractive can't open it.
        let ctx = running {
            $0.demoStep = true
            $0.presentationActive = true
            $0.cutoutInteractive = true
        }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 400), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 150), ctx: ctx))    // "cutout"
        XCTAssertTrue(tourClaims(point: CGPoint(x: 10, y: 830), ctx: ctx))     // tab bar
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))    // panel
    }

    func testChipClaimsOnlyItself() {
        var ctx = TourClaimContext()
        ctx.chipVisible = true
        ctx.chipFrame = CGRect(x: 16, y: 700, width: 140, height: 36)
        XCTAssertTrue(tourClaims(point: CGPoint(x: 60, y: 715), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 10, y: 700), ctx: ctx),
                      "8pt grace inset around the chip")
        // Everything else passes through — the app is fully usable while paused.
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 400), ctx: ctx))
        XCTAssertFalse(tourClaims(point: CGPoint(x: 300, y: 830), ctx: ctx))
    }
}

// MARK: - paused "Resume tour" chip (eligibility + persistence + resume)

final class TourChipTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.tour.chip.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testChipEligibleForPausedRunWithProgress() {
        XCTAssertTrue(tourChipEligible(
            TourState(started: true, done: false, paused: true, mode: .essential, index: 3)))
    }

    func testChipIneligibleWhenDismissedDoneOrNotResumable() {
        XCTAssertFalse(tourChipEligible(
            TourState(started: true, paused: true, mode: .essential, chipDismissed: true)))
        XCTAssertFalse(tourChipEligible(
            TourState(started: true, done: true, paused: true, mode: .essential)))
        XCTAssertFalse(tourChipEligible(TourState(started: true, paused: true)))   // no mode
        XCTAssertFalse(tourChipEligible(TourState(paused: true, mode: .essential)))  // never started
        XCTAssertFalse(tourChipEligible(TourState(started: true, mode: .essential)))  // not paused
        XCTAssertFalse(tourChipEligible(TourState()))
    }

    func testChipDismissedPersistsAcrossLoads() {
        let store = TourStore(defaults: freshDefaults())
        store.save { $0.started = true; $0.paused = true; $0.mode = .essential; $0.index = 2 }
        XCTAssertTrue(tourChipEligible(store.load()))
        store.save { $0.chipDismissed = true }
        XCTAssertFalse(tourChipEligible(store.load()), "✕ is forever for this run")
        XCTAssertEqual(store.load().chipDismissed, true)
    }

    func testFreshRunReArmsTheChip() {
        // begin() clears chipDismissed — a NEW run's pause deserves a chip.
        let store = TourStore(defaults: freshDefaults())
        store.save { $0.started = true; $0.paused = true; $0.mode = .essential; $0.chipDismissed = true }
        store.save { $0.paused = false; $0.done = false; $0.index = 0; $0.chipDismissed = nil }
        store.save { $0.paused = true; $0.index = 1 }
        XCTAssertTrue(tourChipEligible(store.load()))
    }

    func testChipResumeStateResumesAtTheSavedStep() {
        // The state confirmPause writes must (a) offer the paused card on
        // relaunch and (b) resume at the exact saved step — chip tap = resume.
        let s = TourState(started: true, done: false, paused: true, mode: .essential, index: 4)
        XCTAssertEqual(tourInitialPhase(s), .paused)
        XCTAssertEqual(tourResumeDecision(s), .running(index: 4))
    }
}

// MARK: - Tell-me-more handback (round 3 — pause + finished-narration fixes)

final class TourHandbackProgressTests: XCTestCase {
    func testHandbackKeepsANaturallyFinishedNarrationAtFull() {
        // AVAudioPlayer rewinds currentTime to 0 after a natural finish —
        // the handback must NOT snap the bar 1 → 0.
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 1, currentTime: 0, duration: 30), 1)
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 1.0, currentTime: 12, duration: 30), 1)
    }

    func testHandbackRestoresThePausedPosition() {
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 0.4, currentTime: 15, duration: 30), 0.5)
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 0, currentTime: 0, duration: 30), 0)
    }

    func testHandbackClampsAndSurvivesZeroDuration() {
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 0.5, currentTime: 40, duration: 30), 1)
        XCTAssertEqual(tourHandbackProgress(preMoreProgress: 0.5, currentTime: 5, duration: 0), 0)
    }
}

@MainActor
final class TourAudioPauseTests: XCTestCase {
    /// Round-3 LOW fix: an explicit pause() while the more clip plays must
    /// disarm the narration handback — collapsing Tell-me-more afterwards
    /// stays paused instead of restarting the narration.
    func testExplicitPauseKillsThePendingMoreHandback() throws {
        let audio = TourAudioPlayer()
        audio.prepare(step: "welcome", autoplay: false)
        try XCTSkipUnless(audio.available, "welcome.m4a not bundled in this test host")
        audio.play()
        try XCTSkipUnless(audio.playing, "audio playback unavailable in this environment")
        audio.playMore()          // narration was playing → handback armed
        audio.pause()             // explicit pause must disarm it…
        audio.stopMore()          // …so the Tell-me-more collapse…
        XCTAssertFalse(audio.playing, "…must NOT restart the narration after an explicit pause")
        audio.stop()
    }
}

// MARK: - key-window handback (round 3 — exit/pause/finish with keyboard up)

/// Records makeKey() calls without touching the test host's real key window.
@MainActor
private final class RecordingWindow: UIWindow {
    var makeKeyCount = 0
    override func makeKey() { makeKeyCount += 1 }
}

/// The Ask field makes the TOUR window key; every teardown path must hand key
/// status back to the APP window when the field was focused — the panel
/// unmounts before its askFocused onChange can fire, so teardownRunning is
/// the only reliable place. (XCUITest can't observe key-window status —
/// synthesized taps self-heal it — hence this model-level test.)
@MainActor
final class TourKeyWindowHandbackTests: XCTestCase {
    private func freshStore() -> TourStore {
        let name = "test.tour.keywindow.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return TourStore(defaults: d)
    }

    private func runningTour(app: AppModel) -> TourModel {
        let tour = TourModel(app: app, store: freshStore())
        tour.begin(.essential)
        return tour
    }

    func testExitWithAskFieldFocusedRestoresAppKey() {
        let app = AppModel()
        let appWin = RecordingWindow()
        TourWindowHandle.shared.appWindow = appWin
        defer { TourWindowHandle.shared.appWindow = nil }
        let tour = runningTour(app: app)
        tour.askFieldFocused = true
        appWin.makeKeyCount = 0
        tour.exit()
        XCTAssertEqual(appWin.makeKeyCount, 1, "exit with the keyboard up must restore the app key window")
    }

    func testConfirmPauseWithAskFieldFocusedRestoresAppKey() {
        let app = AppModel()
        let appWin = RecordingWindow()
        TourWindowHandle.shared.appWindow = appWin
        defer { TourWindowHandle.shared.appWindow = nil }
        let tour = runningTour(app: app)
        tour.askFieldFocused = true
        appWin.makeKeyCount = 0
        tour.requestPause()
        tour.confirmPause()
        XCTAssertEqual(appWin.makeKeyCount, 1, "pausing with the keyboard up must restore the app key window")
    }

    func testAdvanceToDoneWithAskFieldFocusedRestoresAppKey() {
        let app = AppModel()
        let appWin = RecordingWindow()
        TourWindowHandle.shared.appWindow = appWin
        defer { TourWindowHandle.shared.appWindow = nil }
        let tour = runningTour(app: app)
        while tour.phase == .running, tour.index < tour.steps.count - 1 { tour.advance() }
        tour.askFieldFocused = true
        appWin.makeKeyCount = 0
        tour.advance()   // last step → done → teardownRunning
        XCTAssertEqual(tour.phase, .done)
        XCTAssertEqual(appWin.makeKeyCount, 1, "finishing with the keyboard up must restore the app key window")
    }

    func testTeardownWithoutFocusLeavesKeyWindowAlone() {
        let app = AppModel()
        let appWin = RecordingWindow()
        TourWindowHandle.shared.appWindow = appWin
        defer { TourWindowHandle.shared.appWindow = nil }
        let tour = runningTour(app: app)
        appWin.makeKeyCount = 0
        tour.exit()
        XCTAssertEqual(appWin.makeKeyCount, 0, "no keyboard was up — nothing to restore")
    }
}

// MARK: - audio manifest (narration + more clips on disk)

final class TourAudioManifestTests: XCTestCase {
    /// The bundled audio dir, located from this file's repo path (unit tests
    /// host in the app process, whose bundle layout flattens the clips — the
    /// on-disk manifest is the stable thing to assert).
    private var audioDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnstuckAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("App/Resources/TourAudio")
    }

    /// Every distinct step across both modes.
    private var allSteps: [TourStep] {
        var seen = Set<String>()
        return (TourScript.essential + TourScript.full).filter { seen.insert($0.id).inserted }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(name).path)
    }

    /// The steps whose clips are deliberately absent — their copy changed
    /// (the `today` step no longer describes the removed Start-Next hero) and
    /// the old recordings were dropped rather than narrate the wrong screen.
    /// Pinned to exactly that set so a clip going missing anywhere else still
    /// fails, and so regenerating the clips forces the set to be emptied.
    private let awaiting = TourScript.stepsAwaitingNarration

    func testOnlyTheTodayStepAwaitsRegeneratedNarration() {
        XCTAssertEqual(awaiting, ["today"])
        // The stale clips must really be gone — Listen would play the old
        // "Start Next offers one realistic suggestion…" recording otherwise.
        for id in awaiting {
            XCTAssertFalse(exists("\(id).m4a"), "stale narration clip for '\(id)' is still bundled")
            XCTAssertFalse(exists("\(id)-more.m4a"), "stale more clip for '\(id)' is still bundled")
        }
    }

    func testEveryStepHasANarrationClip() {
        for s in allSteps where !awaiting.contains(s.id) {
            XCTAssertTrue(exists("\(s.id).m4a"), "missing narration clip for '\(s.id)'")
        }
    }

    func testEveryTellMeMoreHasAMoreClip() {
        let withMore = allSteps.filter { $0.more != nil }
        XCTAssertEqual(withMore.count, 9, "the 9 essential steps carry more-copy")
        for s in withMore where !awaiting.contains(s.id) {
            XCTAssertTrue(exists("\(s.id)-more.m4a"), "missing more clip for '\(s.id)'")
        }
    }

    func testNoOrphanMoreClipsWithoutMoreCopy() {
        // A -more clip for a step with no `more` text would be unreachable.
        let ids = Set(allSteps.filter { $0.more != nil }.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []
        for f in files where f.hasSuffix("-more.m4a") {
            let id = String(f.dropLast("-more.m4a".count))
            XCTAssertTrue(ids.contains(id), "orphan more clip '\(f)'")
        }
    }
}
