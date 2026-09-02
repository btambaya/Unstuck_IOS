// Raw-PCM audio for realtime voice. Capture: 16 kHz mono PCM16 (what Qwen-Omni
// expects), delivered in ~100ms frames. Playback: 24 kHz mono PCM16 streamed
// from the model. iOS analog of the Android VoiceAudioEngine.
//
// ECHO / BARGE-IN: iOS gives us hardware acoustic echo cancellation for free via
// the input node's VOICE-PROCESSING audio unit (`setVoiceProcessingEnabled`) +
// the AVAudioSession `.voiceChat` mode — the OS uses the playback as the echo
// reference, so the loudspeaker route is far less echo-prone than Android's
// manual setup. We therefore run FULL-DUPLEX (mic stays open while the model
// speaks) and rely on the server VAD (+ the manual Interrupt) for barge-in. If
// real-device testing shows residual self-triggering on the built-in speaker,
// gate `onFrame` on `!isPlaying` for a half-duplex fallback (see note below).
//
// AUDIO SESSION OWNERSHIP (the classic silent-call bug): in Talk mode the
// engine configures + activates the shared AVAudioSession and deactivates it
// on shutdown. In a CallKit call (`.callKit`) CallKit owns activation — it
// activates the session and tells the app via provider(_:didActivate:), and
// deactivates it when the call ends — so the engine only re-asserts the
// category/mode (the same values the CallKit bridge already set) and NEVER
// calls setActive; deactivation on shutdown is a no-op. Activating it
// ourselves races CallKit's activation and yields a connected call with no
// audio either way.
//
// NOTE: this compiles and wires the full graph, but end-to-end audio (levels,
// echo, sample-rate drift) can only be validated on a real device.

import AVFoundation

/// Who activates / deactivates the shared AVAudioSession for a voice session.
enum VoiceAudioSessionOwnership: Sendable {
    /// Talk mode: the engine configures AND activates the session, and
    /// deactivates it on shutdown.
    case app
    /// A CallKit call: CallKit activates/deactivates. The engine re-asserts
    /// category+mode only and never touches setActive.
    case callKit
}

/// The AVAudioSession surface the engine touches — a seam so the ownership
/// rule is unit-testable without AVFoundation (RealtimeCallVoiceLauncherTests).
protocol VoiceAudioSessionControlling: AnyObject, Sendable {
    /// `.playAndRecord` / `.voiceChat` with `options`.
    func configureVoiceChat(options: AVAudioSession.CategoryOptions) throws
    /// setActive(true) / setActive(false, notifyOthersOnDeactivation).
    func setActive(_ active: Bool) throws
}

/// The real shared AVAudioSession.
final class SystemVoiceAudioSession: VoiceAudioSessionControlling {
    func configureVoiceChat(options: AVAudioSession.CategoryOptions) throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }
    func setActive(_ active: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        if active {
            try s.setActive(true, options: [])
        } else {
            try s.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}

final class VoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    static let inRate: Double = 16_000
    static let outRate: Double = 24_000
    /// Talk mode: two-way voice on the loudspeaker by default.
    static let talkSessionOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
    /// CallKit mode: identical to CallKitProvider.configureAudioSession — the
    /// call's route (receiver / speaker / headset) is the user's CallKit choice,
    /// so NO defaultToSpeaker here.
    static let callKitSessionOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// What the model emits / what we schedule for playback: 24k mono Float32.
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: VoiceAudioEngine.outRate,
                                           channels: 1, interleaved: false)!
    /// What we upload: 16k mono Int16.
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: VoiceAudioEngine.inRate,
                                              channels: 1, interleaved: true)!

    private var captureConverter: AVAudioConverter?
    private var started = false
    private let lock = NSLock()

    let sessionOwnership: VoiceAudioSessionOwnership
    private let sessionControl: VoiceAudioSessionControlling

    /// Mic capture couldn't start (audio-session activation or engine.start()
    /// failed — typically the mic is held by another app). The owner (the voice
    /// session) wires this to surface a note + end the session, instead of
    /// leaving the UI stuck on "Listening…" with a dead mic. Mirrors the Android
    /// engine's `onCaptureError`. Fires off the main thread; hop as needed.
    var onCaptureError: (@Sendable () -> Void)?
    /// Accumulates converted Int16 bytes until ~100ms (3200 bytes) is ready.
    private var pending = Data()
    private static let frameBytes = Int(inRate / 10) * 2   // 100ms mono pcm16 = 3200 bytes

    /// `.app` (default) keeps Talk mode's behaviour; `.callKit` for a
    /// CallKit-managed call (see the file header).
    init(sessionOwnership: VoiceAudioSessionOwnership = .app,
         sessionControl: VoiceAudioSessionControlling = SystemVoiceAudioSession()) {
        self.sessionOwnership = sessionOwnership
        self.sessionControl = sessionControl
    }

    // MARK: session

    /// Configure (+ in `.app` mode activate) the shared audio session for
    /// two-way voice. `.callKit`: category/mode only, best-effort — CallKit
    /// has already activated the session; setActive is NEVER called.
    func activateSession() -> Bool {
        switch sessionOwnership {
        case .app:
            do {
                try sessionControl.configureVoiceChat(options: Self.talkSessionOptions)
                try sessionControl.setActive(true)
                return true
            } catch {
                return false
            }
        case .callKit:
            try? sessionControl.configureVoiceChat(options: Self.callKitSessionOptions)
            return true
        }
    }

    /// `.app`: setActive(false, notifyOthers). `.callKit`: no-op — CallKit
    /// deactivates when the call ends (provider(_:didDeactivate:)).
    func deactivateSession() {
        guard sessionOwnership == .app else { return }
        try? sessionControl.setActive(false)
    }

    // MARK: graph

    /// Build + start the engine once (idempotent). Enables voice processing on
    /// the input node for hardware AEC, attaches the player for output.
    private func ensureStarted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }
        guard activateSession() else { return false }

        // Hardware AEC: route both directions through the voice-processing AU.
        // Best-effort — older devices / simulators may reject it.
        try? engine.inputNode.setVoiceProcessingEnabled(true)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // Touch the input node's format so the engine prepares the input HAL.
        _ = engine.inputNode.outputFormat(forBus: 0)

        engine.prepare()
        do { try engine.start() } catch { deactivateSession(); return false }
        started = true
        return true
    }

    // MARK: VoiceAudioIO

    func startPlayback() {
        guard ensureStarted() else { return }
        if !player.isPlaying { player.play() }
    }

    func startCapture(_ onFrame: @escaping @Sendable (Data) -> Void) {
        // ensureStarted() returns false when the audio session can't be
        // activated or the engine won't start — almost always the mic being
        // held by another app. Report it (Android bails the same way in
        // startCapture) instead of returning silently into a dead "Listening…".
        guard ensureStarted() else { onCaptureError?(); return }
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        captureConverter = AVAudioConverter(from: hwFormat, to: captureFormat)

        // Tap the mic at the hardware format; convert each buffer to 16k Int16,
        // accumulate into 100ms frames, hand each frame to the uploader.
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.captureConverter else { return }
            guard let frame = self.convertToCapture(buffer, converter) else { return }
            self.lock.lock()
            self.pending.append(frame)
            var out: [Data] = []
            while self.pending.count >= Self.frameBytes {
                out.append(self.pending.prefix(Self.frameBytes))
                self.pending.removeFirst(Self.frameBytes)
            }
            self.lock.unlock()
            for f in out { onFrame(f) }
        }
    }

    /// Convert one captured buffer (hardware format) → 16k mono Int16 bytes.
    private func convertToCapture(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> Data? {
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err != nil || outBuf.frameLength == 0 { return nil }
        guard let ch = outBuf.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
    }

    func enqueue(_ pcm: Data) {
        guard !pcm.isEmpty, let buffer = Self.pcm16ToBuffer(pcm, format: playFormat) else { return }
        // Check `started` AND schedule under the same lock shutdown() holds, so a
        // concurrent teardown can't stop/detach the player between the guard and
        // the scheduleBuffer (the prior TOCTOU could schedule onto a dead engine).
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// 24k mono PCM16 little-endian → a Float32 AVAudioPCMBuffer for the player.
    private static func pcm16ToBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            let out = dst[0]
            for i in 0..<sampleCount {
                out[i] = Float(Int16(littleEndian: src[i])) / 32768.0
            }
        }
        return buffer
    }

    func flushPlayback() {
        guard started else { return }
        // Barge-in: drop only PLAYBACK. `pending` is the CAPTURE accumulator —
        // clearing it here would discard ~100ms of the user's just-spoken audio
        // that triggered the barge-in (Android's flushPlayback touches only
        // playback). Capture state is cleared on teardown, not here.
        player.stop()                 // drops scheduled buffers
        player.play()                 // ready for the next response
    }

    func shutdown() {
        // Flip `started` under the lock so any concurrent enqueue() — which now
        // checks `started` AND schedules under this same lock — is serialized
        // against this teardown: it either schedules fully before we flip, or
        // sees started == false and bails. The AVAudioEngine teardown stays
        // OUTSIDE the lock: removeTap waits for an executing render callback, and
        // that callback also takes `lock`, so holding it here would deadlock.
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        guard wasStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        captureConverter = nil
        deactivateSession()
    }

    /// True while the model's audio is playing — exposed for an optional
    /// half-duplex fallback (gate `onFrame` on `!isPlaying`) if a device shows
    /// loudspeaker self-triggering. Unused while we run full-duplex.
    var isPlaying: Bool { player.isPlaying }
}
