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
    /// Loudspeaker: the mic upload is muted while the model is AUDIBLE
    /// (`GateContext.forcedClosed`), so nothing the phone plays can come back
    /// as "speech". Proven necessary on an iPhone 15 Pro Max (2026-09-17):
    /// with voice processing's echo cancellation on and the gate open, the
    /// server VAD heard the reply's own echo, transcribed it, cancelled the
    /// reply, and then ANSWERED the echo as if it were the user. Talk-over
    /// stays available on low-echo routes (earphones / Bluetooth); on the
    /// loudspeaker the Interrupt button cuts a reply, from response.created
    /// until its audio has drained.
    let halfDuplexWhilePlaying: Bool
    /// How a barge-in is CONFIRMED (2026-09-19).
    /// `.energy`: the two-sided rule — server VAD in a speech segment AND the
    ///   mic still above the gate for `confirmMs`. Right where the mic hears
    ///   little playback (receiver, earphones, Bluetooth).
    /// `.transcript`: by WORDS. Nothing ducks and no timer runs; the server's
    ///   transcription of what it heard is compared with what the model just
    ///   said. Echo → discarded (and the server's reply to it suppressed, its
    ///   item deleted). Real words → the reply stops. A cough has no words.
    ///   This is the loudspeaker answer: half-duplex (build 54) took talk-over
    ///   away entirely, and echo cancellation with ducking off (build 37→54)
    ///   was tried on the device and still let the echo cancel the reply.
    ///   Words don't care about acoustics.
    let confirm: Confirm
    enum Confirm: Sendable, Equatable { case energy, transcript }

    /// The same tunables with a different confirm — the state-machine tests
    /// (1–15) exercise the ENERGY path on the loudspeaker's timings.
    func with(confirm: Confirm) -> BargeInProfile {
        BargeInProfile(route: route, threshold: threshold, confirmMs: confirmMs, marginIdle: marginIdle,
                       marginPlaying: marginPlaying, halfDuplexWhilePlaying: halfDuplexWhilePlaying, confirm: confirm)
    }

    static let lowEcho = BargeInProfile(route: .lowEcho, threshold: 0.5, confirmMs: 200, marginIdle: 6, marginPlaying: 6, halfDuplexWhilePlaying: false, confirm: .energy)
    static let speaker = BargeInProfile(route: .speaker, threshold: 0.6, confirmMs: 300, marginIdle: 6, marginPlaying: 9, halfDuplexWhilePlaying: false, confirm: .transcript)

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
    /// Half-duplex: the gate is held closed (digital silence out, pre-roll
    /// discarded) — the loudspeaker while the model is audible. Hold-to-talk's
    /// `forcedOpen` wins over it.
    var forcedClosed = false
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
    /// `conversation.item.delete` — the server transcribed the model's own
    /// echo as a user turn; take it out of the conversation so the model
    /// never sees its words attributed to the user.
    case deleteItem(id: String)
    /// `response.create` — the user's real words arrived AFTER the server's
    /// reply to that segment was already cancelled as a suspected blip; ask
    /// again so they are not left in silence.
    case createResponse
}

enum BargeInEvent: Equatable, Sendable {
    case responseCreated(id: String?)
    /// An audio delta arrived; the controller answers with `.enqueue` via
    /// `shouldEnqueueAudio` — this event only updates bookkeeping.
    case audioDelta(id: String?)
    case responseDone(id: String?, status: String?)
    case playbackDrained
    /// The server VAD opened a segment; `itemId` is the conversation item it
    /// will commit that speech into (DashScope sends it), so a transcript can
    /// be tied back to WHEN its speech began — while a reply was busy, or not.
    case speechStarted(itemId: String?)
    case speechStopped
    /// transcription.delta or .completed for the user's input. On an energy
    /// profile an accelerator only; on a transcript profile THE confirm.
    case transcription(text: String, itemId: String?)
    /// response.audio_transcript.delta — the model's own words, kept as a
    /// rolling tail so an input transcript can be recognised as echo.
    case assistantTranscript(delta: String)
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

    /// Transcript confirm (see BargeInProfile.Confirm). The last ~160 tokens
    /// the model spoke, across replies — echo of the PREVIOUS reply can land
    /// after the next response was created.
    private(set) var spokenTail: [String] = []
    private var spokenSet: Set<String> = []
    /// The response whose audio is (or was last) queued for playback — the
    /// one an interruption should stop, as opposed to a NEWER response the
    /// server may already have created for the interrupting turn.
    private(set) var playingResponseId: String?
    /// Per speech segment (speech_started … stopped): did any input
    /// transcript arrive, and did we cancel a suppressed reply for it?
    private var transcriptSeenThisSegment = false
    private var suppressedCancelledThisSegment = false
    /// Speech segments that began WHILE a reply was busy, keyed by the item id
    /// the server commits them into — the only words that can be an
    /// interruption or an echo. Value: the response that was active when the
    /// segment began, so a response created LATER is the server's reply to
    /// that segment (device log 2026-09-19: the echo of the greeting was
    /// committed as the user's turn and answered 10 ms before its transcript
    /// arrived). The transcript of the user's own previous turn — the question
    /// a reply answers — began before the reply did and is never in here.
    private var busySegments: [String: String?] = [:]
    /// The same for a segment the server sent no item id for.
    private var lastSegmentBusy: (busy: Bool, activeAtStart: String?) = (false, nil)

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
                    emitSilenceWhenClosed: !holdToTalk,
                    // The whole reply, not just while audio is queued: the
                    // queue runs dry for a moment at the start of a reply
                    // (device log 2026-09-17, 14:21:09) and between bursts,
                    // and each gap let the gate open on room noise and duck
                    // the next words to −12 dB.
                    forcedClosed: profile.halfDuplexWhilePlaying && modelBusy && state != .hold)
    }

    /// True while the model is (or is about to be) audible — the Interrupt
    /// button's enablement and the DUCK precondition.
    var modelBusy: Bool { responseActive || playbackQueued }

    /// Whether an audio delta for `id` should be played.
    func shouldEnqueueAudio(id: String?) -> Bool {
        if let id, id == cancelledResponseId { return false }
        // The reply on air finishes: the server may create — and we may cancel
        // — a NEWER response while this one is still streaming (its reply to
        // an echo), and that must not drop the rest of what is playing.
        if let id, let playing = playingResponseId, id == playing { return true }
        if muted { return false }
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
                // The reply the server made from a false-start blip (or an
                // echo). Cancelled BY ID: the reply already on air keeps
                // playing — `muted` would have dropped its remaining audio
                // too (device log 2026-09-19: every greeting cut mid-way).
                suppressNextResponse = false
                cancelledResponseId = id
                suppressedCancelledThisSegment = true
                out.append(.sendCancel)
                out.append(.uiState(playbackQueued ? .speaking : .listening))
            } else {
                muted = false
                out.append(.uiState(.thinking))
                if state == .idle { state = .speaking }
            }

        case .audioDelta(let id):
            guard shouldEnqueueAudio(id: id) else { break }
            playbackQueued = true
            if let id { playingResponseId = id }
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
            playingResponseId = nil
            if !responseActive {
                if state == .speaking { state = .idle }
                out.append(.uiState(.listening))
            }

        case .gateOpen:
            gateOpen = true
            gateOpenSince = now
            if state == .speaking, modelBusy, profile.confirm == .energy {
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

        case .speechStarted(let itemId):
            serverSpeaking = true
            transcriptSeenThisSegment = false
            suppressedCancelledThisSegment = false
            if let itemId, modelBusy { busySegments[itemId] = activeResponseId }
            lastSegmentBusy = (modelBusy, activeResponseId)
            switch state {
            case .speaking where modelBusy && profile.confirm == .transcript:
                // Words decide. The server VAD hears the loudspeaker's echo
                // on every reply, so ducking here would dim every reply.
                break
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
            if profile.confirm == .transcript, modelBusy, !transcriptSeenThisSegment {
                // The segment ended and no words came: a blip (a cough, the
                // reply's own tail). The server WILL commit + reply to it —
                // suppress that. If words arrive late and are real, the
                // transcription branch lifts this and asks again.
                suppressNextResponse = true
            }
            if case .ducked(_, let trigger) = state, trigger == .server {
                // The server saw a blip and WILL commit + reply to it.
                suppressNextResponse = true
                out += restoreToSpeaking()
            }

        case .transcription(let text, let itemId):
            switch profile.confirm {
            case .energy:
                // The accelerator is subject to the same two-sided rule as
                // the tick: transcription deltas also stream for the PREVIOUS
                // turn and for the model's own echo (device log 2026-09-17:
                // a speech_started and a delta 0.4 ms apart cancelled a reply
                // the user never interrupted). A transcript with the mic
                // already closed is not the user talking over.
                if case .ducked = state, gateOpen { out += cancel() }
            case .transcript:
                let tokens = Self.tokens(text)
                guard !tokens.isEmpty else { break }    // "um", "…", one letter: no words, not an interruption — and not proof of speech either
                transcriptSeenThisSegment = true
                // Only words from a segment that began while a reply was busy
                // can be an interruption or an echo. A normal turn, or the late
                // transcript of the question this reply answers, is captions only.
                // Match by item id when both sides carry one; otherwise (a
                // server that ids transcripts but not speech_started, or the
                // other way round) fall back to the last segment we saw.
                let segment: (busy: Bool, activeAtStart: String?)? = {
                    if let itemId, let known = busySegments[itemId] { return (true, known) }
                    return lastSegmentBusy.busy ? lastSegmentBusy : nil
                }()
                guard let segment else { break }
                // A response created since the segment began is the server's
                // reply TO that segment — to the echo, or to the interruption.
                let replyToSegment: String? = {
                    guard let a = activeResponseId, a != segment.activeAtStart, a != cancelledResponseId else { return nil }
                    return a
                }()
                if isEcho(tokens) {
                    // The model's own words came back through the mic. Take the
                    // echo out of the conversation and kill the server's reply
                    // to it — before it plays, if we are quick; mid-air if not.
                    if let itemId { out.append(.deleteItem(id: itemId)) }
                    if let reply = replyToSegment {
                        cancelledResponseId = reply
                        responseActive = false
                        out.append(.sendCancel)
                        if playingResponseId == reply {
                            out.append(.flushPlayback)
                            playbackQueued = false
                            playingResponseId = nil
                            out.append(.clearCaption)
                            out.append(.uiState(.listening))
                            if state == .speaking { state = .idle }
                        }
                    } else if !suppressedCancelledThisSegment {
                        suppressNextResponse = true
                    }
                } else if modelBusy {
                    // Real words over the reply: stop it — once. A later
                    // transcript of the same words must not cancel again.
                    suppressNextResponse = false
                    if let itemId { busySegments[itemId] = nil }
                    lastSegmentBusy = (false, nil)
                    if let reply = replyToSegment, reply != playingResponseId {
                        // The server already answered the interruption; only
                        // the OLD reply's queued audio has to go.
                        out.append(.flushPlayback)
                        playbackQueued = false
                        playingResponseId = nil
                        out.append(.clearCaption)
                        out.append(.uiState(.thinking))
                    } else {
                        out += cancel()
                        if suppressedCancelledThisSegment {
                            // Their reply was cancelled as a suspected blip
                            // before the words arrived — ask again.
                            suppressedCancelledThisSegment = false
                            out.append(.createResponse)
                        }
                    }
                }
            }

        case .assistantTranscript(let delta):
            let t = Self.tokens(delta)
            guard !t.isEmpty else { break }
            spokenTail.append(contentsOf: t)
            if spokenTail.count > 160 { spokenTail.removeFirst(spokenTail.count - 160) }
            spokenSet = Set(spokenTail)

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

    // MARK: transcript confirm

    /// Lower-cased word tokens, punctuation stripped, one-letter tokens
    /// dropped ("a", "I" match everything).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    /// Echo: (nearly) every word heard is a word the model recently said.
    /// 70 %, not 100 %: transcription drops and mangles words. A user talking
    /// OVER the reply mixes their words in and pulls the ratio down.
    func isEcho(_ heard: [String]) -> Bool {
        guard !heard.isEmpty, !spokenSet.isEmpty else { return false }
        let hits = heard.filter { spokenSet.contains($0) }.count
        return Double(hits) / Double(heard.count) >= 0.7
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
    /// −58, not the −70 web/Android use: iOS voice processing (noise
    /// suppression) leaves the idle mic near digital silence, so the measured
    /// floor pinned to the clamp and the gate opened 6–9 dB above it — on
    /// nothing (device log 2026-09-17: opens at −65, −67, −70 dBFS). Speech
    /// through the AGC sits well above −40 dBFS.
    static let floorMinDb: Float = -58
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
        if !out.opened && !out.closed { out.levelDb = db }   // the flipping sub-frame's level
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

        // Half-duplex (loudspeaker while the model is audible): nothing from
        // the mic reaches the server — its own echo is what tripped the VAD.
        // The pre-roll is discarded too, or the reply's tail would be
        // prefixed to the user's next turn.
        if context.forcedClosed && !context.forcedOpen {
            if isOpen || forcedOpen {
                forcedOpen = false
                isOpen = false
                out.closed = true
                consecutiveAbove = 0
                belowFrames = 0
            }
            preRoll.removeAll()
            if context.emitSilenceWhenClosed {
                out.pcm.append(Data(count: bytes.count))
                out.silenceFrames += 1
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
