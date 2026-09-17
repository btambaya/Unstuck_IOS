// Raw-PCM audio for realtime voice. Capture: 16 kHz mono PCM16 (what Qwen-Omni
// expects), delivered in ~100ms frames. Playback: 24 kHz mono PCM16 streamed
// from the model. iOS analog of the Android VoiceAudioEngine.
//
// ECHO / BARGE-IN: iOS gives us hardware acoustic echo cancellation for free via
// the input node's VOICE-PROCESSING audio unit (`setVoiceProcessingEnabled`) +
// the AVAudioSession `.voiceChat` mode — the OS uses the playback as the echo
// reference, so the loudspeaker route is less echo-prone than Android's
// manual setup. NOT echo-free, though: on an iPhone 15 Pro Max (2026-09-17)
// the residual echo still opened the gate and the server VAD heard the reply
// as speech. So the LOUDSPEAKER profile is half-duplex while the model is
// audible (`GateContext.forcedClosed` — the gate uploads digital silence);
// low-echo routes (earphones / Bluetooth) run full-duplex with server-VAD
// barge-in; the Interrupt button always works.
//
// BARGE-IN SUPPORT (App/Voice/BargeIn.swift owns the logic; this file only
// executes it): an RMS NOISE GATE runs in the capture tap right after the
// 16 kHz conversion — floor-calibrated, hysteresis, 300 ms pre-roll, digital
// silence while closed — and reports open/close through `onGateChange`;
// playback can be DUCKED (`setPlaybackGain`) while the state machine decides
// whether a sound was speech; and `onPlaybackDrained` fires when the last
// scheduled buffer has actually been heard (so the UI knows "speaking" ended
// and the Interrupt button covers the buffered tail).
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
// CONFIGURATION CHANGES (proven on an iPhone 15 Pro Max / iOS 26.7, 2026-09-17,
// from the device syslog): ~100 ms after engine.start() the voice-processing
// unit settles on the built-in speaker and the OUTPUT hardware flips from
// 48 kHz to 44.1 kHz. AVAudioEngine reacts to that by STOPPING ITSELF
// ("iounit configuration changed > stopping the engine") and posting
// AVAudioEngineConfigurationChange — and nothing else. The mic tap we then
// install never fires, every reply buffer is scheduled onto a dead engine
// ("Engine is not running … Cannot play yet!"), and no API reports an error:
// the greeting's TEXT arrives, its audio doesn't, and the user's voice never
// reaches the server. Restarting on that notification is Apple's documented
// contract; this file observes it (`restartAfterConfigurationChange`). The
// simulator never reconfigures the IO unit, which is why every sim run passed.

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

/// Whether a realtime voice session (Talk or a call) currently owns the shared
/// AVAudioSession. Ambient focus audio and the guided tour both end with
/// `setActive(false, .notifyOthersOnDeactivation)`, which would deactivate the
/// session under a live conversation: the engine stays "running" with no audio
/// in or out and no error anywhere. They consult this first. Audit, 2026-09-11.
enum VoiceAudioOwnership {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _held = false
    static var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return _held }
    static func set(_ held: Bool) { lock.lock(); _held = held; lock.unlock() }
}

/// The real shared AVAudioSession.
final class SystemVoiceAudioSession: VoiceAudioSessionControlling {
    func configureVoiceChat(options: AVAudioSession.CategoryOptions) throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }
    func setActive(_ active: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        VoiceAudioOwnership.set(active)
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
    /// The uploader handed to startCapture — kept so the tap can be
    /// reinstalled after the engine restarts on a configuration change.
    private var onFrame: (@Sendable (Data) -> Void)?
    private var tapInstalled = false
    /// Serialises graph mutations (tap install/remove, restart, shutdown)
    /// against each other. Never taken on the render thread, and never held
    /// together with `lock` across a removeTap (removeTap waits for the render
    /// callback, and that callback takes `lock`).
    private let graphLock = NSLock()
    private var configObserver: (any NSObjectProtocol)?
    private var restartPolicy = EngineRestartPolicy()
    /// Restarts performed so far (diagnostics + tests).
    private(set) var configurationRestarts = 0

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

    // Barge-in plumbing (see the file header).
    var onGateChange: (@Sendable (_ open: Bool) -> Void)?
    var onPlaybackDrained: (@Sendable () -> Void)?
    /// Owned by the capture tap thread; context/recalibration requests are
    /// handed over under `lock` and applied at the next buffer.
    private var gate = RMSGate()
    private var gateContextPending: GateContext?
    private var recalibratePending = false
    /// Buffers scheduled but not yet played back, tagged with a generation so
    /// the completion handlers a flush/shutdown fires (or late ones from a
    /// stopped player) don't count against the next reply's tail.
    private var outstanding = 0
    private var playGeneration = 0
    private var gainRamp = 0
    /// Diagnostics: when the queue last ran dry, and how many buffers played
    /// since it last refilled — the device log's answer to "did the audio
    /// itself have gaps?" (`voice playback queued gapMs=…` / `drained`).
    private var lastDrainedAt: TimeInterval?
    private var playedSinceQueued = 0

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
        guard activateSession() else { voiceLog.error("voice audio session activation failed"); return false }

        // Hardware AEC/NS/AGC only where the echo path needs it. On the
        // BUILT-IN SPEAKER the profile is half-duplex (the upload is muted for
        // the whole reply), so the echo canceller buys nothing there — and its
        // double-talk suppressor costs a lot: it attenuates OUR playback
        // whenever the mic hears loud near-end sound (device, 2026-09-17: a
        // hand on the table made the reply "break up like a laggy call" with
        // the client doing nothing at all). Receiver / earphones / Bluetooth
        // keep it: they run full-duplex and the earpiece leaks.
        // Best-effort — older devices / simulators may reject it.
        let route = VoiceRoute(portType: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue)
        if Self.wantsVoiceProcessing(for: route) { try? engine.inputNode.setVoiceProcessingEnabled(true) }
        voiceLog.notice("voice engine route=\(String(describing: route), privacy: .public) voiceProcessing=\(self.engine.inputNode.isVoiceProcessingEnabled, privacy: .public)")
        if engine.inputNode.isVoiceProcessingEnabled {
            engine.inputNode.isVoiceProcessingAGCEnabled = true
            // We duck the model ourselves (BargeIn); tell the system not to
            // fight it by ducking "other audio" (which is us) on its own.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        // 20 ms IO buffers: the gate decides per 20 ms sub-frame, and a
        // barge-in should cut within a few of them. A preference, not an
        // activation — safe under CallKit ownership too.
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.02)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // Touch the input node's format so the engine prepares the input HAL.
        _ = engine.inputNode.outputFormat(forBus: 0)

        engine.prepare()
        do { try engine.start() } catch {
            voiceLog.error("voice engine start failed: \(String(describing: error), privacy: .public)")
            deactivateSession(); return false
        }
        started = true
        observeConfigurationChanges()
        return true
    }

    /// Voice processing is worth its double-talk suppressor everywhere except
    /// the loudspeaker, where the profile is half-duplex anyway.
    static func wantsVoiceProcessing(for route: VoiceRoute) -> Bool { route != .speaker }

    // MARK: configuration changes (see the file header)

    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// iOS stopped the engine underneath us (route change, or the voice
    /// processor re-clocking the speaker right after start). Drop what was
    /// queued for the old graph, re-tap the mic at the CURRENT hardware
    /// format, start again. A restart that fails, or one that keeps
    /// re-triggering, ends the session through `onCaptureError` — loudly,
    /// never a silent dead "Listening…".
    private func restartAfterConfigurationChange() {
        graphLock.lock(); defer { graphLock.unlock() }
        lock.lock()
        guard started else { lock.unlock(); return }
        let allowed = restartPolicy.allowRestart(now: ProcessInfo.processInfo.systemUptime)
        // Buffers scheduled on the old graph will never play back: retire
        // their completions (generation) and the drain count they held.
        playGeneration += 1
        let dropped = outstanding
        outstanding = 0
        recalibratePending = true      // the route, and its noise floor, may have changed
        if allowed { configurationRestarts += 1 }
        lock.unlock()
        guard allowed else {
            voiceLog.error("voice engine configuration changes are looping — ending the session")
            onCaptureError?()
            return
        }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop()
        let hw = engine.inputNode.inputFormat(forBus: 0)
        voiceLog.notice("voice engine restarting after configuration change #\(self.configurationRestarts, privacy: .public) hw=\(hw.sampleRate, privacy: .public)Hz ch=\(hw.channelCount, privacy: .public) dropped=\(dropped, privacy: .public)")
        engine.prepare()
        do { try engine.start() } catch {
            voiceLog.error("voice engine restart failed: \(String(describing: error), privacy: .public)")
            onCaptureError?()
            return
        }
        player.play()
        if let onFrame, !installCaptureTap(onFrame) { onCaptureError?(); return }
        // The dropped tail will never report back — tell the state machine
        // playback is over so it doesn't wait on "speaking" for ever.
        if dropped > 0 { onPlaybackDrained?() }
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
        guard ensureStarted() else { voiceLog.error("voice capture could not start"); onCaptureError?(); return }
        graphLock.lock(); defer { graphLock.unlock() }
        self.onFrame = onFrame
        if !installCaptureTap(onFrame) { onCaptureError?() }
    }

    /// Tap the mic at the CURRENT hardware format — re-read on every install,
    /// it changes with the route — and build the 16 kHz converter to match.
    /// Each buffer is converted, run through the RMS gate (live audio /
    /// pre-roll / digital silence / nothing during calibration), accumulated
    /// into 100 ms frames, and handed to the uploader. Returns false when the
    /// input is unusable (no converter, degenerate format — which also makes
    /// installTap raise): every buffer would be dropped in silence, which is
    /// indistinguishable from "not talking". Callers fail loudly on false.
    /// Audit, 2026-09-11.
    private func installCaptureTap(_ onFrame: @escaping @Sendable (Data) -> Void) -> Bool {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        let converter = AVAudioConverter(from: hwFormat, to: captureFormat)
        captureConverter = converter
        voiceLog.notice("voice capture hw=\(hwFormat.sampleRate, privacy: .public)Hz ch=\(hwFormat.channelCount, privacy: .public) converter=\(converter != nil, privacy: .public)")
        guard let converter, hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            voiceLog.error("voice capture unusable input format — no converter")
            return false
        }
        // The converter is captured by the tap itself: a restart removes the
        // tap (waiting for an in-flight callback) before installing a new one
        // with a new converter, so the render thread never reads a shared slot.
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let samples = self.convertToCapture(buffer, converter) else { return }
            self.lock.lock()
            if self.recalibratePending { self.recalibratePending = false; self.gate.recalibrate() }
            if let ctx = self.gateContextPending { self.gateContextPending = nil; self.gate.context = ctx }
            let gated = self.gate.push(samples)
            let floor = self.gate.floorDb, margin = self.gate.context.marginDb
            self.pending.append(gated.pcm)
            var out: [Data] = []
            while self.pending.count >= Self.frameBytes {
                out.append(self.pending.prefix(Self.frameBytes))
                self.pending.removeFirst(Self.frameBytes)
            }
            self.lock.unlock()
            // Levels only — never audio. A few lines per session; they are
            // what tells a false barge-in from a real one on a device.
            if gated.opened || gated.closed {
                voiceLog.notice("voice gate \(gated.opened ? "open" : "close", privacy: .public) level=\(Int(gated.levelDb), privacy: .public)dB floor=\(Int(floor), privacy: .public)dB margin=\(Int(margin), privacy: .public)dB")
            }
            if gated.opened { self.onGateChange?(true) }
            for f in out { onFrame(f) }
            if gated.closed { self.onGateChange?(false) }
        }
        tapInstalled = true
        return true
    }

    func setGateContext(_ ctx: GateContext) {
        lock.lock(); gateContextPending = ctx; lock.unlock()
    }

    func recalibrateGate() {
        lock.lock(); recalibratePending = true; lock.unlock()
    }

    /// Convert one captured buffer (hardware format) → 16k mono Int16 samples.
    private func convertToCapture(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> [Int16]? {
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
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    func enqueue(_ pcm: Data) {
        guard !pcm.isEmpty, let buffer = Self.pcm16ToBuffer(pcm, format: playFormat) else { return }
        // Check `started` AND schedule under the same lock shutdown() holds, so a
        // concurrent teardown can't stop/detach the player between the guard and
        // the scheduleBuffer (the prior TOCTOU could schedule onto a dead engine).
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        if !player.isPlaying { player.play() }
        outstanding += 1
        if outstanding == 1 {
            let now = ProcessInfo.processInfo.systemUptime
            let gap = lastDrainedAt.map { Int(((now - $0) * 1000).rounded()) } ?? -1
            playedSinceQueued = 0
            voiceLog.notice("voice playback queued gapMs=\(gap, privacy: .public)")
        }
        let gen = playGeneration
        // `.dataPlayedBack` = the buffer has been HEARD (not merely consumed by
        // the mixer), so the last one's completion is the playback_drained event.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferPlayed(generation: gen)
        }
    }

    private func bufferPlayed(generation: Int) {
        lock.lock()
        guard generation == playGeneration, outstanding > 0 else { lock.unlock(); return }
        outstanding -= 1
        playedSinceQueued += 1
        let drained = outstanding == 0
        if drained {
            lastDrainedAt = ProcessInfo.processInfo.systemUptime
            voiceLog.notice("voice playback drained played=\(self.playedSinceQueued, privacy: .public)")
        }
        lock.unlock()
        if drained { onPlaybackDrained?() }
    }

    /// Duck (0.25 = −12 dB) / restore playback with a short linear ramp: 20 ms
    /// down (a duck must be fast), 50 ms up. `player.volume` is the mixer
    /// input gain — immediate and independent of the system's own ducking.
    func setPlaybackGain(_ gain: Float) {
        let target = max(0, min(1, gain))
        lock.lock()
        gainRamp += 1
        let ramp = gainRamp
        let from = player.volume
        lock.unlock()
        let steps = 4
        let totalMs = target < from ? 20 : 50
        for i in 1...steps {
            let v = from + (target - from) * Float(i) / Float(steps)
            let delay = DispatchTimeInterval.milliseconds(totalMs * i / steps)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let live = self.gainRamp == ramp
                self.lock.unlock()
                if live { self.player.volume = v }
            }
        }
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
        // Bump the generation BEFORE stop(): stop() may run the dropped
        // buffers' completion handlers synchronously, and they must not fire
        // onPlaybackDrained (the caller already knows) or count against the
        // next reply — and they take `lock`, so it can't be held across stop().
        lock.lock()
        playGeneration += 1
        outstanding = 0
        lock.unlock()
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
        playGeneration += 1
        outstanding = 0
        gainRamp += 1
        lock.unlock()
        guard wasStarted else { return }
        graphLock.lock(); defer { graphLock.unlock() }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        onFrame = nil
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
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

/// Loop guard for engine restarts on configuration changes: a restart that
/// itself provoked another change would otherwise spin for ever with the mic
/// flapping. Allows `maxRestarts` within a sliding `window` (seconds); the
/// engine ends the session past that. Pure — unit-tested.
struct EngineRestartPolicy: Sendable {
    var maxRestarts = 6
    var window: TimeInterval = 10
    private var stamps: [TimeInterval] = []

    init(maxRestarts: Int = 6, window: TimeInterval = 10) {
        self.maxRestarts = maxRestarts
        self.window = window
    }

    /// True if a restart may go ahead now (and records it).
    mutating func allowRestart(now: TimeInterval) -> Bool {
        stamps.removeAll { now - $0 > window }
        guard stamps.count < maxRestarts else { return false }
        stamps.append(now)
        return true
    }
}
