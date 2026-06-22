// Real on-device Speaker / Listener for the Focus Copilot, wrapping the
// existing VoiceController (App/Voice/VoiceController.swift — the same $0,
// on-device SFSpeechRecognizer + AVSpeechSynthesizer layer the assistant
// uses). NOTHING here touches the assistant client or the network: it is
// pure OS speech, exactly like VoiceController.
//
// The adapters add the two things the copilot needs on top of VoiceController:
//   • a bounded LISTEN WINDOW (VoiceController.startListening runs until the
//     recognizer decides it's final; we cap it at `maxSeconds` and deliver the
//     best transcript heard, or "" on nothing/denial), and
//   • a single-shot `onResult` contract (fires exactly once).
//
// Both conform to the @MainActor CopilotSpeaker / CopilotListener seams so the
// controller can be unit-tested with fakes instead of real audio.

import Foundation
import UnstuckCore

/// Speaker backed by VoiceController.speak (AVSpeechSynthesizer, offline voice).
@MainActor
final class VoiceControllerSpeaker: CopilotSpeaker {
    private let voice: VoiceController
    init(_ voice: VoiceController) { self.voice = voice }

    /// TTS is essentially always available on-device; VoiceController.speak is
    /// itself a no-op if no voice exists, so this stays true.
    var canSpeak: Bool { true }

    func speak(_ text: String) { voice.speak(text) }
    func stop() { voice.stopSpeaking() }
}

/// Listener backed by VoiceController.startListening, with a hard time cap so
/// the mic only stays open for the short post-prompt window. On-device
/// recognition is preferred (audio never leaves the device); the transcript is
/// handed to the controller and then discarded — never stored or sent.
@MainActor
final class VoiceControllerListener: CopilotListener {
    private let voice: VoiceController
    private var resultHandler: (@MainActor (String) -> Void)?
    private var best: String = ""
    private var windowTask: Task<Void, Never>?
    private var delivered = false

    init(_ voice: VoiceController) { self.voice = voice }

    var canListen: Bool { voice.sttAvailable }

    func start(maxSeconds: Double, onResult: @escaping @MainActor (String) -> Void) {
        // Reset per-window state.
        stop()
        delivered = false
        best = ""
        resultHandler = onResult

        voice.startListening(
            onPartial: { [weak self] text in
                // Keep the latest partial as a fallback if no final lands before
                // the window closes. Hop to the main actor (callbacks fire off
                // the Speech framework's queue).
                Task { @MainActor in self?.best = text }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in self?.deliver(text) }
            },
            onDone: { [weak self] in
                // Recognition ended (error / silence) without a final — deliver
                // whatever partial we have (often "").
                Task { @MainActor in self?.deliver(self?.best ?? "") }
            }
        )

        // Hard cap: close the window after maxSeconds regardless.
        windowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
            await MainActor.run { self?.deliver(self?.best ?? "") }
        }
    }

    func stop() {
        windowTask?.cancel()
        windowTask = nil
        voice.stopListening()
        resultHandler = nil
        delivered = true
    }

    /// Fire `onResult` exactly once, then tear the window down.
    private func deliver(_ text: String) {
        guard !delivered else { return }
        delivered = true
        windowTask?.cancel()
        windowTask = nil
        voice.stopListening()
        let handler = resultHandler
        resultHandler = nil
        handler?(text)
    }
}
