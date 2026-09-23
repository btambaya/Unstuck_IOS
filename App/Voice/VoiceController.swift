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
// THE SHARED AUDIO SESSION (audit 2026-09-22, C41): dictation activates it as
// `.record` and speech as `.playback` with `.duckOthers`, and nothing handed
// it back — the user's music stayed paused or ducked after one dictation or
// one spoken line. It is released with `.notifyOthersOnDeactivation` once
// neither is in use (after a short grace, so the Focus copilot's speak →
// listen → acknowledge doesn't bounce the music between them), never under a
// live Talk session or call (VoiceAudioOwnership), whose session neither may
// touch at all, and never under the Focus ambient bed.
//
// `@unchecked Sendable`: callbacks are @Sendable and fire from the Speech
// framework's queue; the SwiftUI consumer hops to the main actor. The mutable
// state is guarded by `lock`, always taken BEFORE VoiceAudioOwnership's.

import AVFoundation
import Speech

final class VoiceController: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    /// Speech + mic permission, `true` when both are granted. A seam so a
    /// stop during the permission prompts is testable without the OS prompts.
    private let authorize: @Sendable (_ granted: @escaping @Sendable (Bool) -> Void) -> Void
    /// Hands the shared session back. A seam so a release that lands after
    /// the owner has let go of this controller is observable in tests.
    private let deactivate: @Sendable () -> Void

    /// Bumped by every start and stop: a dictation whose permission callbacks
    /// come back after a stop — or after a newer start — is stale and must
    /// not open the mic. It did: the copilot's window closed during the
    /// first-use permission prompt, and the grant then started recognition
    /// nobody read, the mic hot and the session record-only (audit
    /// 2026-09-22, C41).
    private var listenGeneration = 0
    /// A dictation is wanted (started, not stopped): the session stays ours.
    private var listenWanted = false
    /// The line being spoken, and what runs when it has ended.
    private var utterance: AVSpeechUtterance?
    private var utteranceEnded: (@Sendable () -> Void)?
    /// Bumped by every speak and every dictation: a release scheduled before
    /// either is void.
    private var sessionUse = 0
    /// The session was handed back (diagnostics + tests).
    var sessionReleases: Int { lock.withLock { _sessionReleases } }
    private var _sessionReleases = 0
    /// Dictations that got past the permission prompts to the mic
    /// (diagnostics + tests).
    var micOpens: Int { lock.withLock { _micOpens } }
    private var _micOpens = 0

    /// How long the session stays ours after the last use.
    static let releaseGraceSec: Double = 0.4

    init(authorize: @escaping @Sendable (_ granted: @escaping @Sendable (Bool) -> Void) -> Void = VoiceController.systemAuthorize,
         deactivate: @escaping @Sendable () -> Void = VoiceController.systemDeactivate) {
        self.authorize = authorize
        self.deactivate = deactivate
        super.init()
        synth.delegate = self
    }

    /// `.notifyOthersOnDeactivation`, so music that dictation paused or
    /// speech ducked comes back.
    @Sendable static func systemDeactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// The OS prompts: speech recognition, then the microphone.
    @Sendable static func systemAuthorize(_ granted: @escaping @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { granted(false); return }
            AVAudioApplication.requestRecordPermission { granted($0) }
        }
    }

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
        guard recognizer?.isAvailable == true else { onDone(); return }
        // A live Talk session or call owns the session and the mic: `.record`
        // here would take its input away.
        guard !VoiceAudioOwnership.isHeld else { onDone(); return }
        let generation: Int = lock.withLock {
            listenGeneration += 1
            listenWanted = true
            sessionUse += 1
            return listenGeneration
        }

        // Authorize speech + mic, then begin. Either denial → graceful no-op.
        authorize { [weak self] granted in
            guard let self else { onDone(); return }
            guard granted else { self.end(generation); onDone(); return }
            self.begin(generation: generation, onPartial: onPartial, onFinal: onFinal, onDone: onDone)
        }
    }

    private func begin(generation: Int,
                       onPartial: @escaping @Sendable (String) -> Void,
                       onFinal: @escaping @Sendable (String) -> Void,
                       onDone: @escaping @Sendable () -> Void) {
        // onDone must fire EXACTLY ONCE per dictation. The recognition handler is
        // re-invoked with an error when the task is cancelled right after a final
        // result, which fired onDone a SECOND time. Because onFinal (writes the
        // draft) and onDone (reads it → send) are separate main-actor Tasks with
        // no ordering guarantee, onFinal could repopulate the draft BETWEEN the
        // two onDone fires — so the chat auto-sent the same dictated prompt twice.
        // Gate completion so a session reports done a single time — per
        // dictation, so a late fire from the previous one can't use up this
        // one's.
        let once = DoneOnce()
        let done: @Sendable () -> Void = { if once.claim() { onDone() } }

        // Everything up to the running engine happens under the lock, and only
        // for the current dictation: a stop that lands meanwhile waits for it
        // and then tears it down, and a stale one never touches the mic.
        lock.lock()
        guard let recognizer, generation == listenGeneration, listenWanted, !VoiceAudioOwnership.isHeld else {
            lock.unlock(); end(generation); done(); return
        }
        _micOpens += 1
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: [])
        } catch { lock.unlock(); end(generation); done(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Keep audio on-device when the model supports it (privacy + $0).
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { lock.unlock(); end(generation); done(); return }
        lock.unlock()

        let recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !text.isEmpty { onFinal(text) }
                    self?.end(generation); done()
                } else if !text.isEmpty {
                    onPartial(text)
                }
            }
            if error != nil {
                self?.end(generation); done()
            }
        }
        let current: Bool = lock.withLock {
            guard generation == listenGeneration else { return false }
            task = recognitionTask
            return true
        }
        if !current { recognitionTask.cancel() }
    }

    func stopListening() {
        let wasListening: Bool = lock.withLock {
            listenGeneration += 1
            return closeMic()
        }
        if wasListening { releaseWhenIdle() }
    }

    /// Dictation `generation` has ended by itself (final, error, denial):
    /// close the mic — only if it is still the current one. Its recognition
    /// handler fires late when its task is cancelled, and calling
    /// stopListening() there shut down whatever dictation had started since.
    private func end(_ generation: Int) {
        let wasListening: Bool = lock.withLock {
            guard generation == listenGeneration else { return false }
            return closeMic()
        }
        if wasListening { releaseWhenIdle() }
    }

    /// Tear the mic down. `lock` held. True if a dictation was on.
    private func closeMic() -> Bool {
        let was = listenWanted || request != nil
        listenWanted = false
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
        return was
    }

    // MARK: text-to-speech

    /// Speak `text`. `onFinish` fires once when the line has been spoken or
    /// was cut short (stopSpeaking, a newer line) — at once when there is
    /// nothing to say, or while a Talk session or call owns the audio (it
    /// switched a live one to `.playback`: the conversation's mic went dead
    /// and the line talked over it — audit 2026-09-22, C41).
    func speak(_ text: String, onFinish: (@Sendable () -> Void)? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !VoiceAudioOwnership.isHeld else { onFinish?(); return }
        let u = AVSpeechUtterance(string: t)
        u.voice = preferredVoice()
        let cut: (@Sendable () -> Void)? = lock.withLock {
            let previous = utteranceEnded
            utterance = u
            utteranceEnded = onFinish
            sessionUse += 1
            return previous
        }
        // The line this one cuts has ended too.
        cut?()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
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
        // Also a line queued a moment ago that isn't "speaking" yet: it would
        // play out after the stop, and its end is what hands the session back.
        let current: AVSpeechUtterance? = lock.withLock { utterance }
        synth.stopSpeaking(at: .immediate)
        // Ended here, not by the synthesizer's didCancel: its delegate is weak,
        // and the owners stop on the way out (the sheet swiped away, Focus
        // closed) and free this controller at once — the callback never came
        // and the session stayed ducked (audit 2026-09-22, C41). A late
        // didCancel for it is a no-op.
        if let current { spoken(current) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        spoken(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        spoken(utterance)
    }

    /// `u` has ended: if it is the current line, hand the session back once
    /// idle and tell whoever asked for it.
    private func spoken(_ u: AVSpeechUtterance) {
        let ended: (@Sendable () -> Void)?? = lock.withLock {
            guard u === utterance else { return .none }
            let e = utteranceEnded
            utterance = nil
            utteranceEnded = nil
            return .some(e)
        }
        guard let ended else { return }
        releaseWhenIdle()
        ended?()
    }

    // MARK: the shared session

    /// Hand the shared session back once nothing here has used it for
    /// `releaseGraceSec`: `.notifyOthersOnDeactivation`, so music that
    /// dictation paused or speech ducked comes back. Not under a Talk session
    /// or call (checked atomically with a Talk start), nor while the Focus
    /// ambient bed plays in the same session — deactivating stops it.
    ///
    /// The grace holds this controller: its owners are views' `@State`, freed
    /// the moment the sheet or Focus goes away — exactly when the last use
    /// ends — and a weak capture dropped the release then (audit 2026-09-22,
    /// C41). 0.4 s, and nothing here holds the closure: no cycle.
    private func releaseWhenIdle() {
        let use: Int = lock.withLock { sessionUse }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseGraceSec) { [self] in
            let bedPlaying = MainActor.assumeIsolated { AmbientAudio.shared.isRunning }
            lock.withLock {
                guard use == sessionUse, !listenWanted, utterance == nil, !bedPlaying else { return }
                VoiceAudioOwnership.unlessHeld {
                    deactivate()
                    _sessionReleases += 1
                }
            }
        }
    }

    func shutdown() {
        stopListening()
        stopSpeaking()
    }
}

/// `onDone` once per dictation (see VoiceController.begin).
private final class DoneOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// True the first time only.
    func claim() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
