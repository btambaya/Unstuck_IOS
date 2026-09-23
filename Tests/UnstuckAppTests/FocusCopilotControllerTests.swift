// App-layer tests for FocusCopilotController — the speak/listen/duck wiring
// around the pure UnstuckCore.FocusCopilot. Uses fake Speaker / Listener so no
// real audio or Speech framework runs, and a manual "tick" clock (we just call
// tick(focusedSec:) with the focus seconds we want). Asserts the GUARDRAILS:
//   • fires the right line at the right tick,
//   • a heard transcript → the right effect (extend/keepGoing/stop/capture),
//   • permission-denied (canListen=false) degrades to speak-only,
//   • a THROWING speaker/listener never breaks the controller (fail-safe),
//   • NO LLM/network is reachable from the copilot path.

import AVFoundation
import XCTest
import UnstuckCore
@testable import Unstuck

// MARK: - Fakes

@MainActor
final class FakeSpeaker: CopilotSpeaker {
    var canSpeak = true
    var spoken: [String] = []
    var shouldThrow = false
    var stopCount = 0
    /// Lines "still playing": their onFinish waits for `finishSpeaking()` /
    /// `stop()`. Off, a line finishes as soon as it is spoken.
    var holdLines = false
    private var playing: [@MainActor () -> Void] = []
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) throws {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        spoken.append(text)
        if holdLines { playing.append(onFinish) } else { onFinish() }
    }
    /// Off, `stop()` cuts a held line without reporting its end — the
    /// synthesizer an audio interruption cut off.
    var stopEndsLines = true
    /// The held lines finish playing.
    func finishSpeaking() { let p = playing; playing = []; p.forEach { $0() } }
    func stop() { stopCount += 1; if stopEndsLines { finishSpeaking() } }
}

@MainActor
final class FakeListener: CopilotListener {
    var canListen = true
    var shouldThrow = false
    var startCount = 0
    var stopCount = 0
    /// What to feed back to the controller as the heard transcript. If nil, the
    /// window is left "open" (the test can call `deliver` manually).
    var autoResult: String? = ""
    private var pending: (@MainActor (String) -> Void)?

    func start(maxSeconds: Double, onResult: @escaping @MainActor (String) -> Void) throws {
        startCount += 1
        if shouldThrow { throw NSError(domain: "test", code: 2) }
        pending = onResult
        if let r = autoResult { deliver(r) }
    }
    func stop() { stopCount += 1; pending = nil }
    /// Manually fire the result (for tests that hold the window open).
    func deliver(_ text: String) {
        let p = pending; pending = nil; p?(text)
    }
}

@MainActor
final class CopilotEffectsSpy {
    var extended: [Int] = []
    var keptGoing = 0
    var stopped = 0
    var captured: [String] = []
    func make() -> CopilotEffects {
        CopilotEffects(
            extend: { self.extended.append($0) },
            keepGoing: { self.keptGoing += 1 },
            stop: { self.stopped += 1 },
            capture: { self.captured.append($0) }
        )
    }
}

// MARK: - Tests

@MainActor
final class FocusCopilotControllerTests: XCTestCase {

    private var speaker: FakeSpeaker!
    private var listener: FakeListener!
    private var spy: CopilotEffectsSpy!
    private var ducks = 0
    private var restores = 0

    private func makeController(
        estimateMin: Int = 25,
        level: NotificationLevel = .coach,
        voiceReplies: Bool = true,
        lineTimeoutSec: Double = 12
    ) -> FocusCopilotController {
        speaker = FakeSpeaker()
        listener = FakeListener()
        spy = CopilotEffectsSpy()
        ducks = 0; restores = 0
        let c = FocusCopilotController(
            speaker: speaker, listener: listener, effects: spy.make(),
            estimateMin: { estimateMin }, level: { level },
            voiceRepliesEnabled: { voiceReplies },
            duck: { self.ducks += 1 }, restore: { self.restores += 1 },
            listenWindowSec: 6, lineTimeoutSec: lineTimeoutSec
        )
        c.startSession()
        return c
    }

    /// Drive the controller second-by-second from `from` up to and including
    /// `to` — the real app ticks once per accumulated-focus second, so each
    /// threshold is crossed individually (the controller surfaces one milestone
    /// per tick by design, never stacking two prompts in the same instant).
    private func tickThrough(_ c: FocusCopilotController, from: Int = 0, to: Int) {
        for s in from...to { c.tick(focusedSec: s) }
    }

    // ── fires the right line at the right tick ───────────────────────────

    func testFiresHalfwayLineAtHalfwaySecond_speakOnly() {
        // Coach, 25-min: HALFWAY @ 12:30 (750s), speak-only (no mic).
        let c = makeController(estimateMin: 25, level: .coach, voiceReplies: true)
        c.tick(focusedSec: 749)
        XCTAssertTrue(speaker.spoken.isEmpty, "not due 1s early")
        c.tick(focusedSec: 750)
        XCTAssertEqual(speaker.spoken, ["Halfway there — about 12 minutes left."])
        XCTAssertEqual(listener.startCount, 0, "HALFWAY is speak-only — no mic")
        XCTAssertEqual(ducks, 1); XCTAssertEqual(restores, 1)
    }

    func testFiresAtTimeAndOpensMic_thenRestores() {
        // Calm, 25-min: AT_TIME @ 25:00 (1500s) is the ONLY milestone and asks a
        // question → mic opens. (Calm isolates AT_TIME cleanly.)
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = ""   // heard nothing
        tickThrough(c, to: 1500)
        XCTAssertTrue(speaker.spoken.contains("That's your block. Add five, stop, or keep going?"))
        XCTAssertEqual(listener.startCount, 1, "question milestone opens the mic")
        XCTAssertFalse(c.listening, "auto-empty result closed the window")
        XCTAssertEqual(restores, 1)
    }

    func testEachMilestoneFiresOncePerSession() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        tickThrough(c, to: 1600)
        XCTAssertEqual(speaker.spoken.filter { $0.hasPrefix("That's your block") }.count, 1)
    }

    // ── transcript → effect ──────────────────────────────────────────────

    func testHeardExtendRunsExtendEffectAndAcks() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "add ten"
        tickThrough(c, to: 1500)
        XCTAssertEqual(spy.extended, [10])
        XCTAssertTrue(speaker.spoken.contains("Added 10 minutes."))
        XCTAssertFalse(c.listening)
    }

    func testHeardKeepGoingSetsFlagAndSuppressesOverrun() {
        let c = makeController(estimateMin: 25, level: .coach, voiceReplies: true)
        // Through HALFWAY (speak-only) + T-5 (question) say nothing.
        listener.autoResult = ""
        tickThrough(c, to: 1499)
        XCTAssertEqual(spy.keptGoing, 0, "nothing heard yet")
        // At AT_TIME, say "keep going" → sets the no-re-nag flag.
        listener.autoResult = "keep going"
        c.tick(focusedSec: 1500)
        XCTAssertEqual(spy.keptGoing, 1)
        XCTAssertTrue(speaker.spoken.contains("Okay, keep going."))
        // Now well into overrun — no overrun re-check should fire.
        speaker.spoken.removeAll()
        tickThrough(c, from: 1501, to: 1500 + 11 * 60)
        XCTAssertTrue(speaker.spoken.isEmpty, "keepGoing suppresses overrun nags")
    }

    func testHeardStopRunsStopEffect() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "stop"
        tickThrough(c, to: 1500)
        XCTAssertEqual(spy.stopped, 1)
        XCTAssertTrue(speaker.spoken.contains("Nice work."))
    }

    func testHeardCaptureSavesVerbatimAndAcks() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "note call the dentist"
        tickThrough(c, to: 1500)
        XCTAssertEqual(spy.captured, ["call the dentist"])
        XCTAssertTrue(speaker.spoken.contains("Got it."))
    }

    func testHeardGarbageRunsNoEffect() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "banana helicopter"
        tickThrough(c, to: 1500)
        XCTAssertTrue(spy.extended.isEmpty && spy.captured.isEmpty)
        XCTAssertEqual(spy.stopped, 0); XCTAssertEqual(spy.keptGoing, 0)
        // No ack for `.none`.
        XCTAssertFalse(speaker.spoken.contains { $0.hasPrefix("Added") || $0 == "Got it." })
    }

    // ── permission-denied = speak-only ───────────────────────────────────

    func testListenerUnavailableDegradesToSpeakOnly() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.canListen = false   // mic permission denied / no recognizer
        tickThrough(c, to: 1500)
        XCTAssertTrue(speaker.spoken.contains("That's your block. Add five, stop, or keep going?"))
        XCTAssertEqual(listener.startCount, 0, "no mic when recognition unavailable")
        XCTAssertFalse(c.listening)
        XCTAssertEqual(restores, 1, "audio still restored")
    }

    func testVoiceRepliesOffNeverOpensMic() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        tickThrough(c, to: 1500)
        XCTAssertTrue(speaker.spoken.contains("That's your block. Add five, stop, or keep going?"))
        XCTAssertEqual(listener.startCount, 0, "Voice replies off → speak-only")
    }

    // ── FAIL-SAFE: throwing speaker / listener never breaks the controller ─

    func testThrowingSpeakerNeverBreaksTheTick() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        speaker.shouldThrow = true
        // Must not crash / throw; the milestone is still marked fired + audio
        // restored (the timer is unaffected — the controller swallows the error).
        tickThrough(c, to: 1500)
        XCTAssertEqual(restores, 1)
        // Still de-dupes despite the throw.
        tickThrough(c, from: 1501, to: 1600)
        XCTAssertEqual(restores, 1, "AT_TIME already fired — no second prompt")
    }

    func testThrowingListenerDegradesGracefully() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.shouldThrow = true
        tickThrough(c, to: 1500)
        // Spoke the prompt, tried to open the mic (threw), recovered: not stuck
        // "listening", audio restored, no effect run.
        XCTAssertFalse(c.listening)
        XCTAssertEqual(restores, 1)
        XCTAssertTrue(spy.extended.isEmpty && spy.captured.isEmpty)
    }

    func testEndSessionStopsSpeechAndMicAndRestores() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = nil   // hold the window open
        tickThrough(c, to: 1500)
        XCTAssertTrue(c.listening)
        c.endSession()
        XCTAssertFalse(c.listening)
        XCTAssertGreaterThanOrEqual(speaker.stopCount, 1)
        XCTAssertGreaterThanOrEqual(listener.stopCount, 1)
    }

    func testTickIgnoredWhenInactive() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        c.endSession()             // inactive
        c.tick(focusedSec: 1500)
        XCTAssertTrue(speaker.spoken.isEmpty, "no speech when not active")
    }

    func testPauseKeepsCadenceResumeDoesNotReplay() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        tickThrough(c, to: 1500)   // AT_TIME spoken
        XCTAssertEqual(speaker.spoken.count, 1)
        c.pauseSession()
        c.resumeSession()
        tickThrough(c, from: 1501, to: 1600)   // still past AT_TIME — must NOT replay
        XCTAssertEqual(speaker.spoken.count, 1, "resume keeps the fired cadence")
    }

    // ── Phase 1.5: push-to-talk capture ──────────────────────────────────

    func testCaptureNowSavesTranscriptVerbatim() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "  Ping Zubair re TestFlight  "
        c.captureNow()
        // Saved verbatim (trimmed only) with the live session's body — NOT parsed.
        XCTAssertEqual(spy.captured, ["Ping Zubair re TestFlight"])
        XCTAssertEqual(c.lastCaptureOutcome, .saved)
        XCTAssertFalse(c.capturing, "window closed after the result")
        XCTAssertEqual(restores, 1, "ducked audio restored")
        XCTAssertEqual(listener.startCount, 1)
    }

    func testCaptureNeverParsesCommandPhrases() {
        // The crux: a command-like utterance must be SAVED, never interpreted.
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "I should stop procrastinating"
        c.captureNow()
        XCTAssertEqual(spy.captured, ["I should stop procrastinating"])
        // None of the command effects ran — no parse on the capture path.
        XCTAssertEqual(spy.stopped, 0)
        XCTAssertTrue(spy.extended.isEmpty)
        XCTAssertEqual(spy.keptGoing, 0)

        // Even a bare "stop" is captured, not treated as a stop command.
        let c2 = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "stop"
        c2.captureNow()
        XCTAssertEqual(spy.captured, ["stop"])
        XCTAssertEqual(spy.stopped, 0)
    }

    func testBlankCaptureSavesNothing_reportsMissed() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = "   "   // heard only whitespace
        c.captureNow()
        XCTAssertTrue(spy.captured.isEmpty, "blank transcript saves nothing")
        XCTAssertEqual(c.lastCaptureOutcome, .missed)
        XCTAssertFalse(c.capturing)
        XCTAssertEqual(restores, 1)
    }

    func testEmptyCaptureSavesNothing() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = ""
        c.captureNow()
        XCTAssertTrue(spy.captured.isEmpty)
        XCTAssertEqual(c.lastCaptureOutcome, .missed)
    }

    func testSecondTapCancelsInFlightCapture() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = nil   // hold the window open
        c.captureNow()
        XCTAssertTrue(c.capturing)
        let stopsBefore = listener.stopCount
        c.captureNow()              // second tap = cancel
        XCTAssertFalse(c.capturing, "cancelled")
        XCTAssertGreaterThan(listener.stopCount, stopsBefore, "mic closed on cancel")
        XCTAssertTrue(spy.captured.isEmpty, "cancel saves nothing")
        XCTAssertNil(c.lastCaptureOutcome, "no confirm on a cancel")
    }

    func testCaptureWhenRecognitionUnavailableNoOps() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.canListen = false   // permission denied / no recognizer
        XCTAssertFalse(c.canCapture)
        c.captureNow()
        XCTAssertEqual(listener.startCount, 0, "no mic when recognition unavailable")
        XCTAssertFalse(c.capturing)
        XCTAssertTrue(spy.captured.isEmpty)
    }

    func testThrowingListenerDuringCaptureDoesNotBreakTimer() {
        // FAIL-SAFE: a throwing STT layer on the capture path must never stop or
        // corrupt the focus timer. Here we prove the controller recovers (not
        // stuck "capturing", audio restored, no crash) AND the milestone clock
        // keeps working afterwards — a subsequent tick still fires AT_TIME.
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: false)
        listener.shouldThrow = true
        c.captureNow()              // throws inside start → swallowed
        XCTAssertFalse(c.capturing, "recovered, not stuck capturing")
        XCTAssertTrue(spy.captured.isEmpty)
        XCTAssertEqual(restores, 1, "ducked audio restored after the throw")

        // The timer/cadence is unaffected: AT_TIME still fires on the next tick.
        listener.shouldThrow = false
        tickThrough(c, to: 1500)
        XCTAssertTrue(speaker.spoken.contains("That's your block. Add five, stop, or keep going?"))
    }

    func testCaptureIgnoredWhenInactive() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        c.endSession()              // inactive
        c.captureNow()
        XCTAssertEqual(listener.startCount, 0, "no capture when not active")
        XCTAssertTrue(spy.captured.isEmpty)
    }

    func testCaptureDoesNotStartWhileAQuestionWindowIsOpen() {
        // Don't double-open the mic: if a question reply window is live, a
        // capture tap is a no-op (the prompt window owns the mic).
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = nil   // hold the question window open
        tickThrough(c, to: 1500)
        XCTAssertTrue(c.listening)
        let startsBefore = listener.startCount
        c.captureNow()
        XCTAssertEqual(listener.startCount, startsBefore, "capture ignored mid-prompt")
        XCTAssertFalse(c.capturing)
    }

    func testEndSessionStopsAnInFlightCapture() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        listener.autoResult = nil   // hold the capture window open
        c.captureNow()
        XCTAssertTrue(c.capturing)
        c.endSession()
        XCTAssertFalse(c.capturing)
        XCTAssertGreaterThanOrEqual(listener.stopCount, 1)
    }

    // ── the question is heard before the mic opens (audit 2026-09-22, C41) ─

    func testTheListenWindowOpensOnlyOnceTheQuestionHasBeenSpoken() {
        // The mic opened a few ms after the question was queued; the session
        // went record-only and cut the question off.
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        speaker.holdLines = true
        listener.autoResult = nil
        tickThrough(c, to: 1500)
        XCTAssertTrue(speaker.spoken.contains("That's your block. Add five, stop, or keep going?"))
        XCTAssertEqual(listener.startCount, 0, "the mic stays shut while the question is being spoken")
        XCTAssertFalse(c.listening)
        speaker.finishSpeaking()
        XCTAssertEqual(listener.startCount, 1, "then it listens for the answer")
        XCTAssertTrue(c.listening)
    }

    func testASpeakOnlyLineRestoresTheBedOnceItHasBeenSpoken() {
        let c = makeController(estimateMin: 25, level: .coach, voiceReplies: true)
        speaker.holdLines = true
        tickThrough(c, to: 750)
        XCTAssertEqual(speaker.spoken, ["Halfway there — about 12 minutes left."])
        XCTAssertEqual(ducks, 1)
        XCTAssertEqual(restores, 0, "the bed stays ducked under the line")
        speaker.finishSpeaking()
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(listener.startCount, 0)
    }

    func testAQuestionCutShortByAPauseOpensNoMic() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true)
        speaker.holdLines = true
        tickThrough(c, to: 1500)
        c.pauseSession()            // stops the line → it ends → stale
        XCTAssertEqual(listener.startCount, 0, "no mic after the session was paused")
        XCTAssertFalse(c.listening)
        c.resumeSession()
        XCTAssertEqual(listener.startCount, 0)
    }

    /// A phone call or an alarm cut the synthesizer off mid-line: no
    /// didFinish, no didCancel. Nothing else closed the cycle — `busy` stayed
    /// set, the bed ducked, and the coach said nothing for the rest of the
    /// block (audit 2026-09-22, C41).
    func testALineWhoseEndIsNeverReportedStillGoesOn() {
        let c = makeController(estimateMin: 25, level: .calm, voiceReplies: true, lineTimeoutSec: 0.05)
        speaker.holdLines = true
        speaker.stopEndsLines = false
        listener.autoResult = nil
        tickThrough(c, to: 1500)
        XCTAssertEqual(listener.startCount, 0)
        settle(0.3)
        XCTAssertEqual(speaker.stopCount, 1, "the stuck line is stopped")
        XCTAssertEqual(listener.startCount, 1, "and the question gets its answer window")
        XCTAssertTrue(c.listening)
        speaker.finishSpeaking()    // its end, reported late after all
        XCTAssertEqual(listener.startCount, 1, "the window opens once")
        listener.deliver("")
        XCTAssertEqual(restores, 1)

        // A speak-only line: the bed comes back, and the next milestone fires.
        let coach = makeController(estimateMin: 25, level: .coach, voiceReplies: true, lineTimeoutSec: 0.05)
        speaker.holdLines = true
        speaker.stopEndsLines = false
        tickThrough(coach, to: 750)
        XCTAssertEqual(restores, 0)
        settle(0.3)
        XCTAssertEqual(restores, 1, "the bed is restored")
        tickThrough(coach, from: 751, to: 1200)
        XCTAssertEqual(speaker.spoken.count, 2, "the coach goes on: \(speaker.spoken)")
    }

    private func settle(_ seconds: Double) {
        let e = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 5)
    }

    // ── GUARDRAIL: zero LLM / network in the copilot path ────────────────

    func testNoNetworkOrAssistantSymbolsReachableFromCopilotPath() {
        // Static guarantee: the copilot source files import only Foundation +
        // UnstuckCore (+ AVFoundation/Speech in the voice adapter). They never
        // import UnstuckSync (the AssistantClient lives there) or reference
        // URLSession / the assistant edge function. Verified by scanning the
        // sources so a future edit that wires in a network call fails CI.
        //
        // This also covers the Phase-1.5 push-to-talk CAPTURE path: captureNow()
        // + captureFromTranscript live in these same two files, so the scan
        // proves the capture transcript is never streamed off-device.
        let root = URL(fileURLWithPath: #filePath)        // …/Tests/UnstuckAppTests/this.swift
            .deletingLastPathComponent()                   // UnstuckAppTests
            .deletingLastPathComponent()                   // Tests
            .deletingLastPathComponent()                   // repo root
        let files = [
            "Sources/UnstuckCore/Logic/FocusCopilot.swift",
            "App/Focus/FocusCopilotController.swift",
            "App/Focus/FocusCopilotVoice.swift",
        ]
        let banned = ["URLSession", "AssistantClient", "import UnstuckSync",
                      "assistant", "https://", "qwen", "DashScope", "LLM"]
        for rel in files {
            let url = root.appendingPathComponent(rel)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("missing copilot source: \(rel)"); continue
            }
            // Strip comments so the word "assistant" in a doc-comment doesn't
            // trip the guard — we only care about real code tokens.
            let code = src.split(separator: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
            }.joined(separator: "\n")
            for tok in banned {
                XCTAssertFalse(code.contains(tok),
                               "copilot source \(rel) must not reference \"\(tok)\" (zero-LLM/network guardrail)")
            }
        }
    }
}

// MARK: - the real on-device voice + ambient bed on the shared audio session
// (audit 2026-09-22, C41 / C42) — AVAudioSession works in the simulator; what
// only a phone can prove (the music resuming, the question audible) is in
// the device checks.

@MainActor
final class CopilotAudioSessionTests: XCTestCase {
    /// Permission callbacks held until the test answers them.
    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@Sendable (Bool) -> Void] = []
        func ask(_ granted: @escaping @Sendable (Bool) -> Void) { lock.withLock { pending.append(granted) } }
        func answer(_ i: Int, _ granted: Bool) { let p = lock.withLock { pending[i] }; p(granted) }
        var count: Int { lock.withLock { pending.count } }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    override func setUp() {
        super.setUp()
        VoiceAudioOwnership.set(false, by: .app)
        VoiceAudioOwnership.set(false, by: .callKit)
    }
    override func tearDown() {
        VoiceAudioOwnership.set(false, by: .app)
        VoiceAudioOwnership.set(false, by: .callKit)
        AmbientAudio.shared.stop()
        super.tearDown()
    }

    private func settle(_ seconds: Double) {
        let e = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 5)
    }

    /// First use: the window closed while the permission prompts were up
    /// (the scene goes inactive under the alert → teardown → stop). The grant
    /// then started recognition nobody read — a hot mic.
    func testAStopDuringThePermissionPromptsNeverOpensTheMic() throws {
        let prompts = Prompts()
        let voice = VoiceController(authorize: { prompts.ask($0) })
        guard voice.sttAvailable else { throw XCTSkip("no speech recognizer in this simulator") }
        let done = Flag()
        voice.startListening(onPartial: { _ in }, onFinal: { _ in }, onDone: { done.hit() })
        XCTAssertEqual(prompts.count, 1)
        voice.stopListening()
        prompts.answer(0, true)
        XCTAssertEqual(voice.micOpens, 0, "stopped while asking: the grant must not open the mic")
        XCTAssertEqual(done.count, 1, "onDone still fires once")

        // Two windows waiting on prompts: only the newer one may open it.
        let later = VoiceController(authorize: { prompts.ask($0) })
        later.startListening(onPartial: { _ in }, onFinal: { _ in }, onDone: {})
        later.startListening(onPartial: { _ in }, onFinal: { _ in }, onDone: {})
        prompts.answer(1, true)
        XCTAssertEqual(later.micOpens, 0, "the superseded window's grant opens nothing")
        prompts.answer(2, false)
        XCTAssertEqual(later.micOpens, 0)
    }

    /// Talk (or a call) holds the session: the Assistant's read-aloud landing
    /// mid-Talk switched it to .playback — Talk's mic went dead ("Couldn't
    /// access the microphone") and the line talked over the realtime voice.
    func testSpeechAndDictationLeaveALiveVoiceSessionAlone() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        VoiceAudioOwnership.set(true, by: .app)
        let voice = VoiceController(authorize: { $0(true) })
        let finished = expectation(description: "finished")
        voice.speak("Five minutes left — keep going or wrap up?") { finished.fulfill() }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(s.category, .playAndRecord, "the session is Talk's")
        let done = expectation(description: "done")
        voice.startListening(onPartial: { _ in }, onFinal: { _ in }, onDone: { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(voice.micOpens, 0)
        XCTAssertEqual(s.category, .playAndRecord)
    }

    /// Nothing handed the session back: one spoken line left the user's music
    /// ducked (and one dictation left it paused) for as long as the app ran.
    func testTheSessionIsHandedBackOnceALineHasEnded() {
        let voice = VoiceController(authorize: { $0(false) })
        let finished = expectation(description: "finished")
        voice.speak("Captured. That line is long enough to still be playing when it is stopped.") { finished.fulfill() }
        voice.stopSpeaking()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(voice.sessionReleases, 0, "not before the grace")
        settle(VoiceController.releaseGraceSec + 0.3)
        XCTAssertEqual(voice.sessionReleases, 1, "handed back with notifyOthersOnDeactivation")

        // Not while a voice session holds it.
        let held = VoiceController(authorize: { $0(false) })
        let spoke = expectation(description: "spoke")
        held.speak("Got it.") { spoke.fulfill() }
        VoiceAudioOwnership.set(true, by: .callKit)
        held.stopSpeaking()
        wait(for: [spoke], timeout: 5)
        settle(VoiceController.releaseGraceSec + 0.3)
        XCTAssertEqual(held.sessionReleases, 0, "never deactivated under a call")
    }

    /// Swiping the sheet away (or closing Focus) mid-line or mid-dictation
    /// stops it and frees the controller at once — it is the view's @State.
    /// The release rode on a weak self, and a line's end on the
    /// synthesizer's weak delegate: neither came, and the music stayed
    /// ducked or paused for as long as the app ran.
    func testTheSessionIsHandedBackAfterTheOwnerHasLetGoOfTheVoice() throws {
        let releases = Flag()
        var reading: VoiceController? = VoiceController(authorize: { $0(false) }, deactivate: { releases.hit() })
        reading?.speak("Here is a reply long enough to still be playing when the sheet is swiped away.")
        reading?.stopSpeaking()
        reading = nil
        settle(VoiceController.releaseGraceSec + 0.3)
        XCTAssertEqual(releases.count, 1, "handed back although its owner has gone")

        // Mid-dictation (still at the permission prompts: the dictation is
        // wanted, the session is ours).
        let prompts = Prompts()
        var dictating: VoiceController? = VoiceController(authorize: { prompts.ask($0) }, deactivate: { releases.hit() })
        guard dictating?.sttAvailable == true else { throw XCTSkip("no speech recognizer in this simulator") }
        dictating?.startListening(onPartial: { _ in }, onFinal: { _ in }, onDone: {})
        dictating?.stopListening()
        dictating = nil
        settle(VoiceController.releaseGraceSec + 0.3)
        XCTAssertEqual(releases.count, 2)
    }

    func testANewLineInsideTheGraceKeepsTheSession() {
        let voice = VoiceController(authorize: { $0(false) })
        let first = expectation(description: "first")
        voice.speak("That's your block.") { first.fulfill() }
        voice.stopSpeaking()
        wait(for: [first], timeout: 5)
        let second = expectation(description: "second")
        voice.speak("Added five minutes.") { second.fulfill() }   // inside the grace
        settle(VoiceController.releaseGraceSec + 0.1)
        XCTAssertEqual(voice.sessionReleases, 0, "a line is playing — the first release is void")
        voice.stopSpeaking()
        wait(for: [second], timeout: 5)
        settle(VoiceController.releaseGraceSec + 0.3)
        XCTAssertEqual(voice.sessionReleases, 1)
    }

    /// A call answered in-app, then Focus opened with the ambient bed on:
    /// .playback took the call's mic (dead air), and leaving Focus
    /// deactivated the call's session.
    func testTheAmbientBedNeverTakesTheSessionFromALiveCall() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        VoiceAudioOwnership.set(true, by: .callKit)
        AmbientAudio.shared.start()
        XCTAssertFalse(AmbientAudio.shared.isRunning, "the bed waits for the call")
        XCTAssertEqual(s.category, .playAndRecord, "the call keeps its input")
    }

    /// The copilot ducked (paused) the bed, and a call was answered before
    /// it restored it: the restore can't play into the call's session, and
    /// left it paused but "running" — start() then refused it after the
    /// call, and it stayed silent until Focus was left.
    func testABedDuckedWhenACallTookTheSessionCanStartAgainAfterIt() throws {
        AmbientAudio.shared.start()
        guard AmbientAudio.shared.isRunning else { throw XCTSkip("no audio output route in this simulator") }
        AmbientAudio.shared.duck()                      // a coach line
        VoiceAudioOwnership.set(true, by: .callKit)     // a call answered meanwhile
        AmbientAudio.shared.restore()
        XCTAssertFalse(AmbientAudio.shared.isRunning, "stopped, not paused and counted as playing")
        VoiceAudioOwnership.set(false, by: .callKit)    // the call has ended
        AmbientAudio.shared.start()                     // the next updateAudio
        XCTAssertTrue(AmbientAudio.shared.isRunning)
    }

    /// The copilot's listen window left the session record-only; the bed was
    /// restarted into it and played nothing for the rest of the session.
    func testRestoringTheBedAfterAListenWindowMakesTheSessionPlaybackAgain() throws {
        AmbientAudio.shared.start()
        guard AmbientAudio.shared.isRunning else { throw XCTSkip("no audio output route in this simulator") }
        AmbientAudio.shared.duck()
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: .duckOthers)
        AmbientAudio.shared.restore()
        XCTAssertEqual(s.category, .playback, "the bed can be heard again")
    }

    // MARK: VoiceAudioOwnership

    func testOwnershipIsPerOwnerAndAFailedActivationLetsGo() {
        VoiceAudioOwnership.set(true, by: .callKit)
        VoiceAudioOwnership.set(true, by: .app)
        VoiceAudioOwnership.set(false, by: .app)    // Talk ended during the call
        XCTAssertTrue(VoiceAudioOwnership.isHeld, "the call still holds it")
        VoiceAudioOwnership.set(false, by: .callKit)
        XCTAssertFalse(VoiceAudioOwnership.isHeld)
        // A Talk start whose activation threw (the mic busy) left the flag
        // set for the rest of the process.
        struct Busy: Error {}
        XCTAssertThrowsError(try VoiceAudioOwnership.holding(.app) { throw Busy() })
        XCTAssertFalse(VoiceAudioOwnership.isHeld)
        var released = 0
        VoiceAudioOwnership.unlessHeld { released += 1 }
        VoiceAudioOwnership.set(true, by: .app)
        VoiceAudioOwnership.unlessHeld { released += 1 }
        XCTAssertEqual(released, 1, "no release while held")
    }
}
