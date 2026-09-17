// Barge-in for realtime voice — the PURE part (no socket, no AVFoundation), so
// every transition and the noise gate are unit-testable with a fake clock and
// synthetic PCM (Tests/UnstuckAppTests/BargeInTests.swift). Mirrors the web
// lib/voice/barge-in.ts and the Android BargeInController so the three stay in
// lock-step (same 12 test cases).
//
// Why: the server VAD (DashScope, threshold 0.5 by default) treats any
// transient above the noise floor as speech, and no client ever sent
// response.cancel — so a gust/cough mid-reply silenced the model locally while
// the server kept generating, captions leaked, and the next turn collided with
// the still-active response. The fix is three layers:
//
//   1. session.update turn_detection tuned PER ROUTE (receiver/headset vs the
//      loudspeaker) and re-sent whenever the route changes.
//   2. A DUCK → CONFIRM → CANCEL state machine: the first hint of speech
//      (client RMS gate or server speech_started) only ducks playback −12 dB;
//      a confirm timer (200/300 ms by profile), the server agreeing, or a
//      transcription decides between a real barge-in (response.cancel + flush
//      + mute stale deltas) and a blip (restore). The manual Interrupt button
//      stays a hard cancel that never ducks.
//   3. An RMS noise gate in the capture path: floor-calibrated, hysteresis,
//      300 ms pre-roll, DIGITAL SILENCE while closed (the server's
//      silence_duration_ms timer must observe silence to end a turn), and no
//      floor adaptation while the model is playing (residual echo).
//
// Inputs are events + a monotonic clock (seconds); outputs are commands the
// transport/audio layers execute (VoiceRealtimeClient / VoiceAudioEngine).

import Foundation

// MARK: - Route profiles

/// Where the model's audio comes out — what decides the barge-in profile.
enum VoiceRoute: Sendable, Equatable {
    /// Built-in loudspeaker (Talk mode's default) or another open speaker.
    case speaker
    /// Handset receiver, wired/Bluetooth headset — mic hears little playback.
    case lowEcho

    /// From an AVAudioSession.Port raw value (kept as a String so this file has
    /// no AVFoundation dependency): only OPEN speakers are the echo-prone case;
    /// the receiver, headphones and Bluetooth headsets (which run their own AEC)
    /// are low-echo. Unknown ports default to the safer speaker profile.
    init(portType raw: String?) {
        switch raw {
        case "Receiver", "Headphones", "BluetoothHFP", "BluetoothA2DP", "BluetoothLE", "CarAudio", "USBAudio", "LineOut":
            self = .lowEcho
        default:
            self = .speaker
        }
    }
}

/// Tunables per route (spec §1). `gateMarginDb(playing:)` is the RMS gate's
/// margin above the noise floor — higher on the loudspeaker while the model
/// plays, where residual echo is the remaining false-trigger source.
struct BargeInProfile: Sendable, Equatable {
    let route: VoiceRoute
    /// server_vad threshold — above the 0.5 default because the gate + AEC
    /// already remove floor noise.
    let threshold: Double
    /// How long a DUCK lasts before it becomes a CANCEL.
    let confirmMs: Int
    private let marginIdle: Float
    private let marginPlaying: Float

    static let lowEcho = BargeInProfile(route: .lowEcho, threshold: 0.5, confirmMs: 200, marginIdle: 6, marginPlaying: 6)
    static let speaker = BargeInProfile(route: .speaker, threshold: 0.6, confirmMs: 300, marginIdle: 6, marginPlaying: 9)

    static func forRoute(_ route: VoiceRoute) -> BargeInProfile {
        switch route {
        case .lowEcho: return .lowEcho
        case .speaker: return .speaker
        }
    }

    func gateMarginDb(playing: Bool) -> Float { playing ? marginPlaying : marginIdle }
}

/// The `turn_detection` we send in session.update. `nil` = null (hold-to-talk:
/// the client commits). prefix_padding 300 matches the gate's 300 ms pre-roll;
/// 600 ms silence is inside the doc's 500–600 recommendation for short turns.
struct TurnDetection: Sendable, Equatable {
    var type: String = "server_vad"
    var threshold: Double
    var prefixPaddingMs: Int = 300
    var silenceDurationMs: Int = 600

    static func serverVAD(_ profile: BargeInProfile) -> TurnDetection {
        TurnDetection(threshold: profile.threshold)
    }

    /// JSON for the `turn_detection` field; NSNull for hold-to-talk.
    static func json(_ td: TurnDetection?) -> Any {
        guard let td else { return NSNull() }
        return ["type": td.type, "threshold": td.threshold,
                "prefix_padding_ms": td.prefixPaddingMs, "silence_duration_ms": td.silenceDurationMs]
    }
}

// MARK: - Capture gate context

/// What the RMS gate needs from the state machine (spec §3). Pushed to the
/// audio engine whenever it changes.
struct GateContext: Sendable, Equatable {
    /// openDb = floor + margin (6 dB; 9 dB on the speaker profile while playing).
    var marginDb: Float = 6
    /// No floor adaptation while the model plays / generates (residual echo
    /// would inflate the floor).
    var freezeAdaptation = false
    /// Hold-to-talk: the button is down → the gate is forced open.
    var forcedOpen = false
    /// server_vad needs digital silence while closed (its silence timer must
    /// see silence); hold-to-talk (turn_detection null) appends nothing.
    var emitSilenceWhenClosed = true
}

// MARK: - State machine

/// Everything the transport / audio / UI layers can be told to do.
enum BargeInCommand: Equatable, Sendable {
    /// Playback gain −12 dB (linear 0.25), 20 ms ramp.
    case duck
    /// Playback gain back to unity, 50 ms ramp.
    case restore
    /// Drop queued + playing model audio now.
    case flushPlayback
    /// `response.cancel` — only ever emitted while a response is active.
    case sendCancel
    /// Hold-to-talk release: `input_audio_buffer.commit` + `response.create`.
    case commitAndRespond
    /// Arm the confirm timer: deliver `.tick` after this many ms.
    case startConfirmTimer(ms: Int)
    /// Re-send session.update with this turn_detection (route change / mode).
    case updateTurnDetection(TurnDetection?)
    /// The gate's context changed.
    case updateGate(GateContext)
    /// The reply being cancelled must not linger on screen.
    case clearCaption
    case uiState(VoiceState)
}

enum BargeInEvent: Equatable, Sendable {
    case responseCreated(id: String?)
    /// An audio delta arrived; the controller answers with `.enqueue` via
    /// `shouldEnqueueAudio` — this event only updates bookkeeping.
    case audioDelta(id: String?)
    case responseDone(id: String?, status: String?)
    case playbackDrained
    case speechStarted
    case speechStopped
    /// transcription.delta or .completed for the user's input (accelerator only).
    case transcription
    case gateOpen
    case gateClose
    case interruptPressed
    case tick
    case routeChanged(VoiceRoute)
    case pttDown
    case pttUp
    /// An `error` whose message contains "active response" (either form).
    case benignActiveResponseError
}

/// Pure barge-in state machine (spec §2). Value type: the client mutates it
/// under its lock and executes the returned commands outside it.
struct BargeInController: Sendable {
    enum State: Equatable, Sendable {
        case idle
        /// A response is generating and/or its audio is still queued.
        case speaking
        /// Ducked, waiting for confirmation. `trigger` = who ducked us.
        case ducked(since: TimeInterval, trigger: Trigger)
        /// Hold-to-talk button down.
        case hold
    }
    enum Trigger: Equatable, Sendable { case gate, server }

    private(set) var state: State = .idle
    private(set) var profile: BargeInProfile
    /// turn_detection null; the client commits on release.
    let holdToTalk: Bool

    private(set) var responseActive = false
    private(set) var activeResponseId: String?
    private(set) var cancelledResponseId: String?
    private(set) var playbackQueued = false
    private(set) var gateOpen = false
    private(set) var gateOpenSince: TimeInterval?
    /// The server VAD is inside a speech segment (speech_started … stopped).
    private(set) var serverSpeaking = false
    /// The server saw a blip and WILL create a reply for it — cancel that one
    /// the moment it is created.
    private(set) var suppressNextResponse = false
    /// Drop audio/transcript deltas until the next (non-cancelled) response.
    private(set) var muted = false
    /// How many DUCK→restore cycles happened (the "noisy room?" chip, spec §8).
    private(set) var falseBargeIns = 0

    private var lastGate: GateContext?

    init(profile: BargeInProfile, holdToTalk: Bool = false) {
        self.profile = profile
        self.holdToTalk = holdToTalk
    }

    /// The turn_detection for this mode + profile.
    var turnDetection: TurnDetection? { holdToTalk ? nil : .serverVAD(profile) }

    /// The gate context the audio engine should be running with right now.
    var gateContext: GateContext {
        GateContext(marginDb: profile.gateMarginDb(playing: playbackQueued),
                    freezeAdaptation: playbackQueued || responseActive,
                    forcedOpen: state == .hold,
                    emitSilenceWhenClosed: !holdToTalk)
    }

    /// True while the model is (or is about to be) audible — the Interrupt
    /// button's enablement and the DUCK precondition.
    var modelBusy: Bool { responseActive || playbackQueued }

    /// Whether an audio delta for `id` should be played.
    func shouldEnqueueAudio(id: String?) -> Bool {
        if muted { return false }
        if let id, id == cancelledResponseId { return false }
        if let id, let active = activeResponseId, id != active { return false }
        return true
    }

    /// Whether a transcript (caption) delta for `id` should be shown.
    func acceptsTranscript(id: String?) -> Bool { shouldEnqueueAudio(id: id) }

    /// The initial session.update / after a route change / mode change.
    var uiStateNow: VoiceState {
        if state == .hold { return .listening }
        if playbackQueued { return .speaking }
        if responseActive { return .thinking }
        return .listening
    }

    // MARK: events

    mutating func handle(_ event: BargeInEvent, now: TimeInterval) -> [BargeInCommand] {
        var out: [BargeInCommand] = []
        switch event {
        case .responseCreated(let id):
            if let id, id == cancelledResponseId { break }   // never resurrect a cancelled reply
            responseActive = true
            activeResponseId = id
            if suppressNextResponse {
                // The reply the server made from a false-start blip.
                suppressNextResponse = false
                cancelledResponseId = id
                muted = true
                out.append(.sendCancel)
                out.append(.uiState(.listening))
            } else {
                muted = false
                out.append(.uiState(.thinking))
                if state == .idle { state = .speaking }
            }

        case .audioDelta(let id):
            guard shouldEnqueueAudio(id: id) else { break }
            playbackQueued = true
            if state == .idle { state = .speaking }
            out.append(.uiState(.speaking))

        case .responseDone(let id, _):
            // Only the ACTIVE response's done counts (or an id-less one): a
            // cancelled reply's late done must not clear the flag for the new
            // reply that has already started.
            if let id, let active = activeResponseId, id != active { break }
            responseActive = false
            if !playbackQueued {
                if state == .speaking { state = .idle }
                out.append(.uiState(.listening))
            } else {
                out.append(.uiState(.speaking))
            }

        case .playbackDrained:
            playbackQueued = false
            if !responseActive {
                if state == .speaking { state = .idle }
                out.append(.uiState(.listening))
            }

        case .gateOpen:
            gateOpen = true
            gateOpenSince = now
            if state == .speaking, modelBusy {
                out += duck(now: now, trigger: .gate)
            }

        case .gateClose:
            gateOpen = false
            gateOpenSince = nil
            if case .ducked(_, let trigger) = state, trigger == .gate {
                // Below threshold before confirm and the server never agreed:
                // nothing was committed server-side, just restore.
                out += restoreToSpeaking()
            }

        case .speechStarted:
            serverSpeaking = true
            switch state {
            case .speaking where modelBusy:
                out += duck(now: now, trigger: .server)
            case .ducked(_, let trigger) where trigger == .gate:
                // The server agrees with the gate — that's speech.
                out += cancel()
            default:
                break
            }

        case .speechStopped:
            serverSpeaking = false
            if case .ducked(_, let trigger) = state, trigger == .server {
                // The server saw a blip and WILL commit + reply to it.
                suppressNextResponse = true
                out += restoreToSpeaking()
            }

        case .transcription:
            if case .ducked = state { out += cancel() }

        case .tick:
            // Compare in whole milliseconds: `now - since` is floating point
            // and 2.8 − 2.5 is a hair under 0.3.
            if case .ducked(let since, _) = state,
               Int(((now - since) * 1000).rounded()) >= profile.confirmMs {
                // CONFIRM needs evidence from both sides: the server VAD is
                // inside a speech segment AND the mic is still above the
                // gate — sound that lasted the whole confirm window. The
                // timer alone confirmed nothing: the server's speech_stopped
                // can only arrive after silence_duration_ms (600) of silence,
                // i.e. never inside a 300 ms window, so every VAD blip on a
                // loudspeaker — a tap, a chair, a cough — cancelled the reply
                // (Ahmad's iPhone, 2026-09-17: "interrupted by any noise").
                if gateOpen && serverSpeaking {
                    out += cancel()
                } else {
                    // A blip. If the server is still in its segment it WILL
                    // commit + reply to it — suppress that reply, as the
                    // speech_stopped path does. Nothing committed otherwise.
                    if serverSpeaking { suppressNextResponse = true }
                    out += restoreToSpeaking()
                }
            }

        case .interruptPressed:
            if state == .hold { break }
            if modelBusy {
                out += cancel(hard: true)
            }

        case .benignActiveResponseError:
            // "no active response" / "already has an active response": the
            // server and we disagree about what's generating — resync, never
            // an error state.
            responseActive = false
            switch state {
            case .ducked:
                out.append(.restore)
                state = playbackQueued ? .speaking : .idle
            case .speaking where !playbackQueued:
                state = .idle
            default:
                break
            }
            out.append(.uiState(uiStateNow))

        case .routeChanged(let route):
            let next = BargeInProfile.forRoute(route)
            if next != profile {
                profile = next
                if !holdToTalk { out.append(.updateTurnDetection(turnDetection)) }
            }

        case .pttDown:
            guard holdToTalk, state != .hold else { break }
            if modelBusy { out += cancel(hard: true) }
            state = .hold
            out.append(.uiState(.listening))

        case .pttUp:
            guard holdToTalk, state == .hold else { break }
            // The press already cancelled + flushed whatever was playing; the
            // reply to this turn arrives as a fresh response.created.
            state = .idle
            out.append(.commitAndRespond)
            out.append(.uiState(.thinking))
        }

        // The gate context is derived; push it only when it changed.
        let ctx = gateContext
        if ctx != lastGate {
            lastGate = ctx
            out.append(.updateGate(ctx))
        }
        return out
    }

    /// The first session.update's gate context (marks it as sent).
    mutating func initialGateContext() -> GateContext {
        let ctx = gateContext
        lastGate = ctx
        return ctx
    }

    // MARK: transitions

    private mutating func duck(now: TimeInterval, trigger: Trigger) -> [BargeInCommand] {
        state = .ducked(since: now, trigger: trigger)
        return [.duck, .startConfirmTimer(ms: profile.confirmMs)]
    }

    private mutating func restoreToSpeaking() -> [BargeInCommand] {
        state = modelBusy ? .speaking : .idle
        falseBargeIns += 1
        return [.restore]
    }

    /// CANCEL: stop the reply for good. `hard` = the Interrupt button, which
    /// never went through DUCKED; the restore is idempotent either way and
    /// keeps the NEXT reply at unity.
    private mutating func cancel(hard: Bool = false) -> [BargeInCommand] {
        var out: [BargeInCommand] = []
        if responseActive {
            cancelledResponseId = activeResponseId
            out.append(.sendCancel)
        } else if let active = activeResponseId {
            // Only the buffered tail was left; make sure late deltas for it
            // (if any) stay dropped.
            cancelledResponseId = active
        }
        out.append(.flushPlayback)
        playbackQueued = false
        muted = true
        out.append(.restore)
        out.append(.clearCaption)
        out.append(.uiState(.listening))
        state = .idle
        return out
    }
}

// MARK: - RMS noise gate

/// Client-side RMS gate over the 16 kHz mono PCM16 capture stream (spec §3).
/// Chops the (variable-size) converted buffers into 20 ms sub-frames; the
/// output is the PCM to upload — live audio (after the 300 ms pre-roll) while
/// open, digital silence of the same size while closed, or nothing during
/// calibration / in hold-to-talk while released.
///
/// Runs on the capture tap thread; `context` is set from other threads by the
/// engine under its lock and copied in per call.
struct RMSGate: Sendable {
    /// 20 ms @ 16 kHz.
    static let subFrameSamples = 320
    static let calibrationFrames = 25          // 500 ms
    static let preRollFrames = 15              // 300 ms
    static let holdFrames = 10                 // 200 ms below closeDb before closing
    static let hysteresisDb: Float = 3
    static let floorMinDb: Float = -70
    static let floorMaxDb: Float = -35
    static let adaptAlpha: Float = 0.05
    /// +10 dB per minute ⇒ per 20 ms sub-frame.
    static let maxUpwardPerFrame: Float = 10 / (60 * 50)

    struct Output: Equatable, Sendable {
        /// Bytes to upload, in order (pre-roll first on open).
        var pcm = Data()
        var opened = false
        var closed = false
        /// Sub-frames that were emitted as digital silence.
        var silenceFrames = 0
        /// dBFS of the last processed sub-frame (diagnostics only).
        var levelDb: Float = -90
    }

    var context = GateContext()
    private(set) var isCalibrated = false
    private(set) var floorDb: Float = -60
    private(set) var isOpen = false

    private var calibration: [Float] = []
    private var residual: [Int16] = []
    private var preRoll: [Data] = []
    private var consecutiveAbove = 0
    private var belowFrames = 0
    /// Forced-open (hold) is tracked separately from the level-driven state so
    /// releasing the button returns to the level gate cleanly.
    private var forcedOpen = false

    init() {}

    /// Throw the floor away and measure again (route change).
    mutating func recalibrate() {
        isCalibrated = false
        calibration.removeAll()
        consecutiveAbove = 0
        belowFrames = 0
    }

    /// dBFS RMS of one sub-frame, floored at −90.
    static func rmsDb(_ samples: ArraySlice<Int16>) -> Float {
        guard !samples.isEmpty else { return -90 }
        var acc: Double = 0
        for s in samples { let f = Double(s); acc += f * f }
        let rms = (acc / Double(samples.count)).squareRoot() / 32768
        guard rms > 0 else { return -90 }
        return max(-90, Float(20 * log10(rms)))
    }

    /// Feed converted capture samples; get the bytes to upload.
    mutating func push(_ samples: [Int16]) -> Output {
        var out = Output()
        residual.append(contentsOf: samples)
        var start = 0
        while residual.count - start >= Self.subFrameSamples {
            let slice = residual[start..<(start + Self.subFrameSamples)]
            process(slice, into: &out)
            start += Self.subFrameSamples
        }
        if start > 0 { residual.removeFirst(start) }
        return out
    }

    private mutating func process(_ frame: ArraySlice<Int16>, into out: inout Output) {
        let db = Self.rmsDb(frame)
        out.levelDb = db
        let bytes = Data(bytes: Array(frame), count: frame.count * 2)

        // Calibration: the first 500 ms, median (robust to a cough).
        if !isCalibrated {
            calibration.append(db)
            pushPreRoll(bytes)
            if calibration.count >= Self.calibrationFrames {
                let sorted = calibration.sorted()
                floorDb = min(Self.floorMaxDb, max(Self.floorMinDb, sorted[sorted.count / 2]))
                isCalibrated = true
                calibration.removeAll()
            }
            return
        }

        // Hold-to-talk: forced open while pressed, nothing while released.
        if context.forcedOpen {
            if !forcedOpen {
                forcedOpen = true
                if !isOpen { flushPreRoll(into: &out) }
                isOpen = true
                out.opened = true
            }
            out.pcm.append(bytes)
            return
        } else if forcedOpen {
            forcedOpen = false
            isOpen = false
            out.closed = true
            consecutiveAbove = 0
            belowFrames = 0
        }

        let openDb = floorDb + context.marginDb
        let closeDb = openDb - Self.hysteresisDb

        if isOpen {
            out.pcm.append(bytes)
            if db < closeDb {
                belowFrames += 1
                if belowFrames >= Self.holdFrames {
                    isOpen = false
                    out.closed = true
                    belowFrames = 0
                    consecutiveAbove = 0
                }
            } else {
                belowFrames = 0
            }
            return
        }

        // Closed.
        if db >= openDb {
            consecutiveAbove += 1
        } else {
            consecutiveAbove = 0
            if !context.freezeAdaptation { adapt(db) }
        }
        if consecutiveAbove >= 2 {
            isOpen = true
            out.opened = true
            belowFrames = 0
            consecutiveAbove = 0
            flushPreRoll(into: &out)
            out.pcm.append(bytes)
            return
        }
        pushPreRoll(bytes)
        if context.emitSilenceWhenClosed {
            out.pcm.append(Data(count: bytes.count))
            out.silenceFrames += 1
        }
    }

    private mutating func adapt(_ db: Float) {
        var next = floorDb + Self.adaptAlpha * (db - floorDb)
        if next > floorDb { next = min(next, floorDb + Self.maxUpwardPerFrame) }
        floorDb = min(Self.floorMaxDb, max(Self.floorMinDb, next))
    }

    private mutating func pushPreRoll(_ bytes: Data) {
        preRoll.append(bytes)
        if preRoll.count > Self.preRollFrames { preRoll.removeFirst(preRoll.count - Self.preRollFrames) }
    }

    private mutating func flushPreRoll(into out: inout Output) {
        for f in preRoll { out.pcm.append(f) }
        preRoll.removeAll()
    }
}
