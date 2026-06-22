// FocusCopilotController — the App-layer driver for the Hands-Free Focus
// Copilot (Phase 1). It owns NO decision logic: it asks UnstuckCore.FocusCopilot
// *what* milestone is due + *what* a heard utterance means, then performs the
// speaking / listening / ducking / effect-running. The pure rules + parser are
// in Sources/UnstuckCore/Logic/FocusCopilot.swift (unit-tested in UnstuckCoreTests).
//
// Wiring (FocusView): created on session start when "Spoken focus coach" is on.
// On every 1s focus tick the view calls `tick(focusedSec:)` with the ACCUMULATED
// focus seconds (paused excluded, straight from FocusTimer.displayedElapsedSec
// minus prior). When a milestone is due it:
//   • speaks the line (on-device TTS),
//   • for a question milestone (T-5 / AT_TIME / OVERRUN) AND when "Voice replies"
//     is on, opens a ~6s on-device STT window → FocusCommandParser.parse → runs
//     the effect (extend / keepGoing / stop / capture) via the injected closures.
// AmbientAudio is ducked while speaking/listening and restored after. Teardown
// on pause / end / background.
//
// PHASE 1.5 — push-to-talk CAPTURE. A deliberate tap (the focus screen's mic
// button) calls `captureNow()`, which opens the SAME on-device CopilotListener
// window and, on a non-blank result, saves the transcript VERBATIM as a capture
// (effects.capture) — it is NEVER routed through FocusCommandParser.parse, so
// "I should stop procrastinating" is saved, never read as a stop command. A
// second tap while capturing cancels; a blank transcript saves nothing.
//
// GUARDRAILS:
//   • ZERO LLM / network: this file imports nothing that can reach the assistant
//     client or Supabase. It only touches UnstuckCore (pure) + the injected
//     Speaker/Listener (on-device speech) + AmbientAudio + the effect closures.
//   • The mic opens ONLY during a session, ONLY in the short window after a
//     question prompt OR on an explicit capture tap; the reply transcript is
//     parsed then DISCARDED, and the capture transcript is used ONLY to create
//     the verbatim capture (never streamed off-device).
//   • FAIL-SAFE: every Speaker/Listener call is wrapped so a throw / permission
//     denial / unavailable engine can NEVER stop or corrupt the focus timer — it
//     degrades to silence + the existing visual overrun buttons.
//   • Respects cadence (FocusCopilot tracks already-fired), no double-fire,
//     overrun cap 2, honors keepGoing, and stays silent when the feature is off.

import Foundation
import UnstuckCore

// MARK: - Seams (so the controller is testable with fakes; real impls wrap VoiceController)

/// On-device text-to-speech. `throws` so a fake can simulate a failing engine;
/// the controller swallows every throw (fail-safe).
@MainActor
protocol CopilotSpeaker: AnyObject {
    /// True if speaking is possible right now (a voice exists / not muted).
    var canSpeak: Bool { get }
    func speak(_ text: String) throws
    func stop()
}

/// A short on-device speech-to-text window. `start` opens the mic, streams a
/// final transcript to `onResult` (empty string if nothing heard / denied /
/// failed), and is expected to auto-close after a few seconds. The controller
/// also force-closes via `stop()`.
@MainActor
protocol CopilotListener: AnyObject {
    /// True if recognition is usable (a recognizer exists + is available).
    var canListen: Bool { get }
    /// Open the mic. `onResult` fires exactly once with the heard text (or "")
    /// on the main actor.
    func start(maxSeconds: Double, onResult: @escaping @MainActor (String) -> Void) throws
    func stop()
}

/// What the controller can do to the live session, injected by FocusView so the
/// controller never imports FocusModel/AppModel. None of these delete data.
@MainActor
struct CopilotEffects {
    /// Extend the block by N minutes (recomputes overrun in FocusTimer).
    var extend: (Int) -> Void
    /// Mark "keep going" — the controller suppresses further overrun nags.
    var keepGoing: () -> Void
    /// Finish + record the session (no task completion).
    var stop: () -> Void
    /// Save a verbatim capture attached to the current session.
    var capture: (String) -> Void
}

// MARK: - Controller

@MainActor
@Observable
final class FocusCopilotController {

    /// True while the mic is live — drives the "listening…" indicator.
    private(set) var listening = false
    /// True while a push-to-talk CAPTURE window is open (Phase 1.5). Distinct
    /// from `listening` (the question-reply window) so the capture button can
    /// show its own state + a second tap cancels only an in-flight capture.
    private(set) var capturing = false
    /// The last line spoken (for an optional on-screen caption / debugging).
    private(set) var lastSpokenLine: String?

    /// Momentary outcome of the last push-to-talk capture, for a brief on-screen
    /// confirm. Cleared by the view after it's shown.
    enum CaptureOutcome: Equatable { case saved, missed }
    private(set) var lastCaptureOutcome: CaptureOutcome?

    // Dependencies (injected; all on-device / pure).
    @ObservationIgnored private let speaker: CopilotSpeaker
    @ObservationIgnored private let listener: CopilotListener
    @ObservationIgnored private let effects: CopilotEffects
    @ObservationIgnored private let estimateMinProvider: () -> Int
    @ObservationIgnored private let levelProvider: () -> NotificationLevel
    @ObservationIgnored private let voiceRepliesEnabled: () -> Bool
    @ObservationIgnored private let duck: () -> Void
    @ObservationIgnored private let restore: () -> Void
    /// Seconds the STT window stays open after a question prompt.
    @ObservationIgnored private let listenWindowSec: Double

    // State (caller-tracked cadence, mirrors the pure contract).
    @ObservationIgnored private var fired = Set<String>()
    @ObservationIgnored private var keepGoing = false
    @ObservationIgnored private var active = false
    /// Guards re-entrancy: while a prompt's speak+listen cycle is in flight we
    /// don't fire another milestone (so a burst of ticks can't stack prompts).
    @ObservationIgnored private var busy = false

    init(
        speaker: CopilotSpeaker,
        listener: CopilotListener,
        effects: CopilotEffects,
        estimateMin: @escaping () -> Int,
        level: @escaping () -> NotificationLevel,
        voiceRepliesEnabled: @escaping () -> Bool,
        duck: @escaping () -> Void = { AmbientAudio.shared.duck() },
        restore: @escaping () -> Void = { AmbientAudio.shared.restore() },
        listenWindowSec: Double = 6
    ) {
        self.speaker = speaker
        self.listener = listener
        self.effects = effects
        self.estimateMinProvider = estimateMin
        self.levelProvider = level
        self.voiceRepliesEnabled = voiceRepliesEnabled
        self.duck = duck
        self.restore = restore
        self.listenWindowSec = listenWindowSec
    }

    /// Begin a coach session (called on focus start when the feature is on).
    func startSession() {
        active = true
        fired.removeAll()
        keepGoing = false
        busy = false
    }

    /// Tear down — end / background. Stops any in-flight speech + mic, restores
    /// ducked audio, and FORGETS the cadence (a fresh session re-arms). Idempotent.
    func endSession() {
        active = false
        fired.removeAll()
        keepGoing = false
        haltSpeechAndMic()
    }

    /// Pause — stop any in-flight speech/mic + restore audio, but KEEP the
    /// fired/keepGoing cadence so Resume picks up where it left off (no replay
    /// of already-spoken milestones). Pairs with `resumeSession()`.
    func pauseSession() {
        active = false
        haltSpeechAndMic()
    }

    /// Resume after a pause — re-arm ticking without clearing the cadence.
    func resumeSession() {
        active = true
        busy = false
    }

    /// Shared teardown of the audio side — fail-safe so a throw can never reach
    /// the timer.
    private func haltSpeechAndMic() {
        busy = false
        if listening { listening = false }
        if capturing { capturing = false }
        safe { speaker.stop() }
        safe { listener.stop() }
        restore()
    }

    /// Feed the accumulated focus seconds (paused EXCLUDED) on each 1s tick.
    /// Surfaces at most one milestone per call; the pure `dueMilestone` enforces
    /// the cadence, gates, overrun cap, and keepGoing suppression.
    func tick(focusedSec: Int) {
        guard active, !busy else { return }
        let E = estimateMinProvider()
        let level = levelProvider()
        guard let milestone = FocusCopilot.dueMilestone(
            estimateMin: E, level: level, focusedSec: focusedSec,
            alreadyFired: fired, keepGoing: keepGoing
        ) else { return }

        // Mark fired up-front so a re-entrant tick can't replay it even if the
        // speak/listen cycle throws.
        fired.insert(milestone.key)
        let line = FocusCopilot.line(for: milestone, estimateMin: E, focusedSec: focusedSec)
        deliver(milestone, line: line)
    }

    // MARK: - push-to-talk capture (Phase 1.5)

    /// True if a capture can be started right now (recognition usable + a live
    /// session). Drives whether the capture button is enabled / shows a hint.
    var canCapture: Bool { listener.canListen }

    /// Deliberate-tap push-to-talk capture. Opens the SAME on-device STT window
    /// as a question reply, but the transcript is saved VERBATIM as a capture —
    /// it is NEVER parsed (no FocusCommandParser.parse on this path). A second
    /// tap while capturing CANCELS (no save). A blank/empty transcript saves
    /// nothing and reports `.missed`. Fully fail-safe: any STT/permission throw
    /// is swallowed so the focus timer can never be stopped or corrupted.
    func captureNow() {
        // Second tap while a capture is open = cancel (no save, no confirm).
        if capturing { cancelCapture(); return }
        // Don't collide with an in-flight question prompt or an inactive session.
        guard active, !busy, !listening else { return }
        guard listener.canListen else { return }

        lastCaptureOutcome = nil
        busy = true
        capturing = true
        duck()

        let opened = safe {
            try listener.start(maxSeconds: listenWindowSec) { [weak self] heard in
                self?.handleCaptured(heard)
            }
        } != nil
        if !opened {
            // Couldn't open the mic — degrade gracefully (no save, timer intact).
            capturing = false
            finishCapture()
        }
    }

    /// Cancel an in-flight capture (second tap / teardown). No save, no confirm.
    private func cancelCapture() {
        capturing = false
        safe { listener.stop() }
        finishCapture()
    }

    /// A transcript came back from the capture window (possibly ""). Save it
    /// VERBATIM — `captureFromTranscript` only trims + rejects blanks, it does
    /// NOT parse. The transcript is used ONLY to build the capture, then goes
    /// out of scope (never stored elsewhere, never sent).
    private func handleCaptured(_ heard: String) {
        capturing = false
        if let body = FocusCopilot.captureFromTranscript(heard) {
            effects.capture(body)
            lastCaptureOutcome = .saved
            _ = safe { try speaker.speak("Captured.") }
        } else {
            lastCaptureOutcome = .missed
            _ = safe { try speaker.speak("Didn't catch that.") }
        }
        finishCapture()
    }

    private func finishCapture() {
        if capturing { capturing = false }
        restore()
        busy = false
    }

    /// Clear the momentary capture confirm after the view has shown it.
    func clearCaptureOutcome() { lastCaptureOutcome = nil }

    // MARK: - delivery

    private func deliver(_ milestone: FocusMilestone, line: String) {
        busy = true
        lastSpokenLine = line

        // Speak (fail-safe). If TTS is unavailable, we still proceed to the
        // listening window for question milestones (the user may have read the
        // visual overrun buttons); a fully-silent path just ends cleanly.
        duck()
        let spoke = safe { try speaker.speak(line) } != nil ? true : false
        _ = spoke   // (kept for clarity; speaking is best-effort)

        // Speak-only milestone, or Voice replies off, or recognizer unavailable
        // → no mic. Restore audio and finish.
        guard milestone.asksQuestion, voiceRepliesEnabled(), listener.canListen else {
            finishPrompt()
            return
        }

        // Open the short on-device STT window. onResult fires once (the
        // CopilotListener contract guarantees it's on the main actor); we parse +
        // run the effect, then close. Flip the indicator on BEFORE start so a
        // listener that delivers synchronously still leaves a consistent state
        // (handleHeard flips it back off).
        listening = true
        let opened = safe {
            try listener.start(maxSeconds: listenWindowSec) { [weak self] heard in
                self?.handleHeard(heard)
            }
        } != nil
        if !opened {
            // Couldn't open the mic — degrade gracefully (visual buttons remain).
            finishPrompt()
        }
    }

    /// A heard utterance came back from the listener (possibly ""). Parse it —
    /// the transcript is used ONLY here and then discarded (never stored/sent) —
    /// and run the mapped effect.
    private func handleHeard(_ heard: String) {
        listening = false
        let command = FocusCommandParser.parse(heard)
        let effect = command.effect
        // Transcript `heard` is used ONLY to parse, then goes out of scope —
        // never stored, never sent.

        // For STOP, speak the farewell BEFORE running the effect (the effect
        // ends the session + may tear this controller down). For everything
        // else, act then acknowledge.
        if case .stop = effect {
            if let ack = effect.ack { _ = safe { try speaker.speak(ack) } }
            finishPrompt()
            runEffect(effect)
            return
        }

        runEffect(effect)
        if let ack = effect.ack {
            _ = safe { try speaker.speak(ack) }
        }
        finishPrompt()
    }

    /// Apply a parsed effect to the live session via the injected closures.
    private func runEffect(_ effect: FocusEffect) {
        switch effect {
        case .extend(let n):
            effects.extend(n)
            // Extending pushes the estimate out; allow the overrun re-checks to
            // re-arm against the new estimate.
            fired = fired.filter { !$0.hasPrefix("overrun") }
        case .keepGoing:
            keepGoing = true
            effects.keepGoing()
        case .stop:
            effects.stop()
        case .capture(let text):
            effects.capture(text)
        case .none:
            break
        }
    }

    private func finishPrompt() {
        if listening { listening = false }
        restore()
        busy = false
    }

    // MARK: - fail-safe wrapper

    /// Run a throwing copilot side effect, swallowing ANY error (TTS/STT
    /// failure, permission denial, route race). The focus timer must never be
    /// affected by the copilot — this is the single choke point that guarantees
    /// it. Returns Void? so callers can detect success without a throw.
    @discardableResult
    private func safe(_ body: () throws -> Void) -> Void? {
        do { try body(); return () } catch { return nil }
    }
}
