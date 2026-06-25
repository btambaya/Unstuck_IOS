// On-device speech for the assistant — $0 per use (OS frameworks, no cloud API).
// iOS analog of the Android VoiceController:
//  • STT: SFSpeechRecognizer, preferring on-device recognition (audio never
//    leaves the device) so you can dictate into the chat; streams partial text.
//  • TTS: AVSpeechSynthesizer, preferring an offline/enhanced voice, reads
//    assistant replies aloud.
// Best-effort throughout: if a recognizer / permission / voice is unavailable it
// silently no-ops so the chat stays usable as text-only. This is the lightweight
// "speak & listen" layer over the TEXT assistant — distinct from the realtime
// "Talk" mode (VoiceRealtimeClient + VoiceAudioEngine).
//
// `@unchecked Sendable`: callbacks are @Sendable and fire from the Speech
// framework's queue; the SwiftUI consumer hops to the main actor.

import AVFoundation
import Speech

final class VoiceController: @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Guards `onDone` to fire at most once per dictation (see begin()).
    private var doneFired = false
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()

    /// True if speech recognition is usable right now (a recognizer exists + is
    /// available). Authorization is requested lazily on first `startListening`.
    var sttAvailable: Bool { (recognizer?.isAvailable ?? false) }

    // MARK: speech-to-text

    /// Start listening. `onPartial` streams the live transcript; `onFinal` fires
    /// with the best result; `onDone` always fires when listening ends (ok or
    /// error). Requests mic + speech permission on first use.
    func startListening(onPartial: @escaping @Sendable (String) -> Void,
                        onFinal: @escaping @Sendable (String) -> Void,
                        onDone: @escaping @Sendable () -> Void) {
        stopListening()
        guard let recognizer, recognizer.isAvailable else { onDone(); return }

        // Authorize speech + mic, then begin. Either denial → graceful no-op.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { onDone(); return }
            AVAudioApplication.requestRecordPermission { granted in
                guard granted, let self else { onDone(); return }
                self.begin(recognizer: recognizer, onPartial: onPartial, onFinal: onFinal, onDone: onDone)
            }
        }
    }

    private func begin(recognizer: SFSpeechRecognizer,
                       onPartial: @escaping @Sendable (String) -> Void,
                       onFinal: @escaping @Sendable (String) -> Void,
                       onDone: @escaping @Sendable () -> Void) {
        // onDone must fire EXACTLY ONCE per dictation. The recognition handler is
        // re-invoked with an error when the task is cancelled right after a final
        // result, which fired onDone a SECOND time. Because onFinal (writes the
        // draft) and onDone (reads it → send) are separate main-actor Tasks with
        // no ordering guarantee, onFinal could repopulate the draft BETWEEN the
        // two onDone fires — so the chat auto-sent the same dictated prompt twice.
        // Gate completion so a session reports done a single time.
        lock.lock(); doneFired = false; lock.unlock()
        let done: @Sendable () -> Void = { [weak self] in
            guard let self else { onDone(); return }
            self.lock.lock(); let first = !self.doneFired; self.doneFired = true; self.lock.unlock()
            if first { onDone() }
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: [])
        } catch { done(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Keep audio on-device when the model supports it (privacy + $0).
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock(); request = req; lock.unlock()   // guarded — stopListening() reads under lock

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { stopListening(); done(); return }

        let recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !text.isEmpty { onFinal(text) }
                    self?.stopListening(); done()
                } else if !text.isEmpty {
                    onPartial(text)
                }
            }
            if error != nil {
                self?.stopListening(); done()
            }
        }
        lock.lock(); task = recognitionTask; lock.unlock()   // guarded
    }

    func stopListening() {
        lock.lock(); defer { lock.unlock() }
        if engine.isRunning { engine.stop() }
        // Remove the tap UNCONDITIONALLY: if engine.start() threw after the tap
        // was installed (mic contended / route race), the engine isn't running but
        // the tap is still attached — leaving it makes the NEXT installTap a fatal
        // AVAudioEngine precondition crash. removeTap is a safe no-op when none.
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: text-to-speech

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: t)
        u.voice = preferredVoice()
        // Route TTS through playback so it isn't muted by the record session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        synth.speak(u)
    }

    /// Prefer an enhanced/offline voice for the current locale, else the default.
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.hasPrefix(String(lang.prefix(2))) && $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Release the shared audio session. speak()/begin() activate it with the
    /// playback/record category; without deactivating, that category leaks into
    /// whatever plays next. .notifyOthersOnDeactivation lets other apps resume.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func shutdown() {
        stopListening()
        stopSpeaking()
        // STT/TTS each set the session active but never released it; do so on
        // teardown so the category doesn't bleed into the next session.
        deactivateSession()
    }
}
