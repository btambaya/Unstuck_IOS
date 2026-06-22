// App-layer tests for FocusCopilotController — the speak/listen/duck wiring
// around the pure UnstuckCore.FocusCopilot. Uses fake Speaker / Listener so no
// real audio or Speech framework runs, and a manual "tick" clock (we just call
// tick(focusedSec:) with the focus seconds we want). Asserts the GUARDRAILS:
//   • fires the right line at the right tick,
//   • a heard transcript → the right effect (extend/keepGoing/stop/capture),
//   • permission-denied (canListen=false) degrades to speak-only,
//   • a THROWING speaker/listener never breaks the controller (fail-safe),
//   • NO LLM/network is reachable from the copilot path.

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
    func speak(_ text: String) throws {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        spoken.append(text)
    }
    func stop() { stopCount += 1 }
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
        voiceReplies: Bool = true
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
            listenWindowSec: 6
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

    // ── GUARDRAIL: zero LLM / network in the copilot path ────────────────

    func testNoNetworkOrAssistantSymbolsReachableFromCopilotPath() {
        // Static guarantee: the copilot source files import only Foundation +
        // UnstuckCore (+ AVFoundation/Speech in the voice adapter). They never
        // import UnstuckSync (the AssistantClient lives there) or reference
        // URLSession / the assistant edge function. Verified by scanning the
        // sources so a future edit that wires in a network call fails CI.
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
