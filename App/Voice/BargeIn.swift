// Barge-in for realtime voice — the PURE part (no socket, no AVFoundation), so
// every transition and the noise gate are unit-testable with a fake clock and
// synthetic PCM (Tests/UnstuckAppTests/BargeInTests.swift).
//
// The contract with the server (DashScope Qwen-Omni realtime) since build 66,
// 2026-09-19: server_vad with `interrupt_response:false` and
// `create_response:false`. Measured against the live proxy that day:
//
//   * with the defaults the server CANCELS its own reply the moment its VAD
//     hears speech (response.done status=cancelled, reason=turn_detected). On
//     the loudspeaker that "speech" is the reply's own echo, so replies came
//     out in fragments — nothing a client could prevent after the fact;
//   * with both flags off it still segments (speech_started(item_id) …
//     speech_stopped), commits and transcribes what it heard (the completed
//     transcript ~300 ms after speech_stopped), but neither truncates nor
//     answers anything by itself;
//   * a `response.create` in the same breath as a `response.cancel` drops the
//     connection ("thread pool exhausted"); sent after the cancelled
//     response.done (~300 ms later) it works.
//
// So the CLIENT owns turn-taking:
//
//   1. REPLY: a speech segment's completed transcript with real words →
//      `response.create`. No words (a cough, an echo the transcriber heard
//      as Chinese) → the item is deleted, nothing is answered. If a reply is
//      still generating, cancel it first and create only when its done
//      arrives (`pendingCreate`) — and never before `turnHoldMs` of quiet,
//      so a pause mid-sentence does not get the fragment answered.
//   2. INTERRUPT: on low-echo routes (receiver, earphones, Bluetooth) the
//      DUCK → CONFIRM → CANCEL energy machine: the first hint of speech ducks
//      −12 dB; the server VAD in a segment AND the mic above the gate for
//      confirmMs cancels; a blip restores. On the loudspeaker the mic hears
//      every reply, so WORDS decide: the first real words of a segment that
//      began while a reply was on air stop it.
//   3. ECHO: a transcript that is (≥70 %) words the model itself just said,
//      from a segment that began while a reply was on air or within 1.5 s of
//      its audio draining, is echo → nothing answered, nothing shown, and
//      the item deleted once the next segment starts (the user's question
//      often shares the segment with the echo's tail and arrives as a later
//      piece of the same item). The reference is the reply on air and the one before it, not a
//      long tail, so a real sentence sharing everyday words with older
//      replies does not look like echo.
//   4. An RMS noise gate in the capture path: floor-calibrated, hysteresis,
//      300 ms pre-roll, DIGITAL SILENCE while closed (the server's
//      silence_duration_ms timer must observe silence to end a turn), and no
//      floor adaptation while the model is playing (residual echo).
//
// Hold-to-talk (turn_detection null) is unchanged: the client commits and
// creates on release. Inputs are events + a monotonic clock (seconds);
// outputs are commands the transport/audio layers execute
// (VoiceRealtimeClient / VoiceAudioEngine).

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
/// `interrupt_response` / `create_response` are OFF (see the header): the
/// server segments and transcribes; the client cancels and creates.
struct TurnDetection: Sendable, Equatable {
    var type: String = "server_vad"
    var threshold: Double
    var prefixPaddingMs: Int = 300
    var silenceDurationMs: Int = 600
    var interruptResponse = false
    var createResponse = false

    static func serverVAD(_ profile: BargeInProfile) -> TurnDetection {
        TurnDetection(threshold: profile.threshold)
    }

    /// JSON for the `turn_detection` field; NSNull for hold-to-talk.
    static func json(_ td: TurnDetection?) -> Any {
        guard let td else { return NSNull() }
        return ["type": td.type, "threshold": td.threshold,
                "prefix_padding_ms": td.prefixPaddingMs, "silence_duration_ms": td.silenceDurationMs,
                "interrupt_response": td.interruptResponse, "create_response": td.createResponse]
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
    /// Arm a timer: deliver `.tick` after this many ms (the energy confirm,
    /// and the fallback for a cancelled reply whose done never comes).
    case startConfirmTimer(ms: Int)
    /// Re-send session.update with this turn_detection (route change / mode).
    case updateTurnDetection(TurnDetection?)
    /// The gate's context changed.
    case updateGate(GateContext)
    /// The reply being cancelled must not linger on screen.
    case clearCaption
    case uiState(VoiceState)
    /// `conversation.item.delete` — the segment was the model's own echo, or
    /// had no words (a cough, "um", an echo the transcriber heard as
    /// Chinese); take it out so the model never sees it as the user's turn.
    case deleteItem(id: String)
    /// `response.create` — a user turn is complete (its transcript has real
    /// words) and nothing is generating. The server never creates replies by
    /// itself (create_response:false).
    case createResponse
    /// The user's completed words, for the caption — REAL turns only. Every
    /// completed transcript used to be shown as the user's line and start a
    /// new turn on screen, so the reply's own echo wiped the reply's caption
    /// a second in and left "a Chinese phrase" there (Ahmad, 2026-09-19).
    case userTurn(String)
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
    /// transcription.delta (`final: false`) or .completed (`final: true`) for
    /// the user's input. Deltas can stop a reply early; only the completed
    /// transcript decides what is answered.
    case transcription(text: String, itemId: String?, final: Bool)
    /// response.audio_transcript.delta — the model's own words, the echo
    /// reference.
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
    /// Drop audio/transcript deltas until the next (non-cancelled) response.
    private(set) var muted = false
    /// How many DUCK→restore cycles happened (the "noisy room?" chip, spec §8).
    private(set) var falseBargeIns = 0

    /// A real turn waiting to be asked for: `since` = the last moment the
    /// user was heard (their completed transcript, or a further speech start
    /// while nothing plays). Asked once the hold has elapsed, the server VAD
    /// is silent and no reply is generating — a `response.create` in the same
    /// breath as a `response.cancel` drops the connection (measured 2026-09-19).
    private var pendingTurnSince: TimeInterval?
    var pendingCreate: Bool { pendingTurnSince != nil }
    /// A pause mid-sentence ends a VAD segment (600 ms of silence) and the
    /// fragment was answered on its own; the continuation then cancelled that
    /// reply and got its own — "it kept tripping itself" on long questions
    /// (device log 2026-09-20 00:25). Half a second more before asking
    /// bridges a pause of ~1.2 s; a longer one still gets cancel-and-re-ask.
    static let turnHoldMs = 500
    /// If a cancelled reply's done never comes (or the cancel found nothing),
    /// ask anyway. 2.5 s: a done took 1.9 s once (a tool call in flight).
    static let pendingCreateFallbackMs = 2500

    /// Echo reference: the words of the reply on air and of the one before
    /// it (a reply's tail echoes after the next response was created). Not a
    /// long history — everyday words pile up and a real question starts to
    /// look like echo (device log 2026-09-19 23:01: 8/12 on a real one).
    private(set) var spokenCurrent: [String] = []
    private(set) var spokenPrevious: [String] = []
    private var spokenSet: Set<String> = []
    static let spokenCap = 400
    /// The response whose audio is (or was last) queued for playback.
    private(set) var playingResponseId: String?

    /// One server VAD speech segment (speech_started … stopped), by the item
    /// id the server commits it into.
    struct Segment: Equatable, Sendable {
        var itemId: String?
        /// Began while a reply was on air / generating, or within the drain
        /// grace — only those words can be echo or an interruption. A segment
        /// that began while nothing played is the user, whatever it says.
        var echoPossible: Bool
        /// The reply's AUDIO was on air when it began (as opposed to the
        /// drain grace, where only the reply's tail can still echo).
        var onAir = false
        /// `response.create` already issued (or pending) for it.
        var responded = false
        /// Judged echo by its words. The transcriber can complete one segment
        /// in pieces ("Coming up on." then "Day.", device log 2026-09-20
        /// 00:04:43): a short later piece is more of the same echo, not a turn.
        var echoJudged = false
    }
    private var segments: [Segment] = []
    static let segmentHistory = 8
    /// Items judged echo / no words, whose `conversation.item.delete` is HELD
    /// until the next segment starts or a reply is asked for: the user often
    /// starts talking inside the same VAD segment as the reply's echo tail,
    /// and their words then arrive as a later completed transcript for the
    /// same item — deleted already, it would answer nothing.
    private(set) var pendingDeletes: [String] = []
    /// The reply whose audio just finished, and when: its LAST words echo back
    /// after the queue has drained (device log 2026-09-19 22:39:35: drained,
    /// then 30 ms later a segment that transcribed as the reply's tail). A
    /// segment starting inside this window counts as begun on air.
    private var lastDrained: (id: String?, at: TimeInterval)?
    static let drainEchoGraceSec: TimeInterval = 1.5
    /// For the device log: the last echo decision, as hits/heard/reference.
    private(set) var lastEchoScore: (hits: Int, heard: Int, spoken: Int) = (0, 0, 0)

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
        // The reply on air keeps streaming whatever else is going on.
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
            muted = false
            pendingTurnSince = nil
            // A new reply: the one before it is now the "previous" reference.
            spokenPrevious = spokenCurrent
            spokenCurrent = []
            spokenSet = Set(spokenPrevious.map(Self.stem))
            out.append(.uiState(.thinking))
            if state == .idle { state = .speaking }

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
            if pendingCreate {
                // The reply we cancelled is finished server-side: the user's
                // turn can be asked for once its hold is up and they are quiet.
                let ask = tryAsk(now: now)
                out += ask.isEmpty ? [.startConfirmTimer(ms: Self.turnHoldMs)] : ask
            } else if !playbackQueued {
                if state == .speaking { state = .idle }
                out.append(.uiState(.listening))
            } else {
                out.append(.uiState(.speaking))
            }

        case .playbackDrained:
            playbackQueued = false
            lastDrained = (playingResponseId, now)
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
            // Echo needs AUDIO: the reply on air, or just drained — its tail is
            // still in the room and comes back as a segment of its own. A
            // model that is only thinking (its transcript arrives ~1 s before
            // its audio) has said nothing aloud yet.
            let onAir = playbackQueued
            let inGrace = !onAir && lastDrained.map { now - $0.at <= Self.drainEchoGraceSec } == true
            out += flushPendingDeletes(except: itemId)
            segments.append(Segment(itemId: itemId, echoPossible: onAir || inGrace, onAir: onAir))
            // They go on talking before their turn was asked for: hold from here.
            if pendingCreate, !(onAir || inGrace) { pendingTurnSince = now }
            if segments.count > Self.segmentHistory { segments.removeFirst(segments.count - Self.segmentHistory) }
            switch state {
            case .speaking where modelBusy && profile.confirm == .transcript:
                // Words decide. The server VAD hears the loudspeaker's echo
                // on every reply, so ducking here would dim every reply.
                break
            case .speaking where modelBusy:
                out += duck(now: now, trigger: .server)
            case .ducked(_, let trigger) where trigger == .gate:
                // The server agrees with the gate — that's speech.
                out += cancel(now: now)
            default:
                break
            }

        case .speechStopped:
            serverSpeaking = false
            // A held turn is asked for `turnHoldMs` after the user's last
            // sound, whether or not that segment produced a transcript.
            if pendingCreate { out.append(.startConfirmTimer(ms: Self.turnHoldMs)) }
            if case .ducked(_, let trigger) = state, trigger == .server {
                // A blip: nothing confirmed it. Its completed transcript decides
                // whether anything is answered (no words → nothing).
                out += restoreToSpeaking()
            }

        case .transcription(let text, let itemId, let final):
            // Energy routes: an accelerator, under the same two-sided rule as
            // the tick — a transcript with the mic already closed is not the
            // user talking over (deltas also stream for the model's echo).
            if profile.confirm == .energy, case .ducked = state, gateOpen { out += cancel(now: now) }
            let tokens = Self.tokens(text)
            let index = segmentIndex(for: itemId)
            let alreadyCancelled = activeResponseId != nil && activeResponseId == cancelledResponseId
            if !final {
                // Streaming words. On the loudspeaker the first REAL ones of a
                // segment we saw begin, while a reply is busy, stop it — once.
                // A segment we never saw begin never cuts a reply.
                guard profile.confirm == .transcript, !tokens.isEmpty, modelBusy, !alreadyCancelled, let index else { break }
                let segment = segments[index]
                if segment.echoJudged { break }
                if segment.echoPossible {
                    // The live guess grows word by word while they speak; the
                    // reply is cut the moment it is clearly theirs, not when
                    // the segment ends (which, on the loudspeaker, is when the
                    // reply pauses — device log 2026-09-20 00:04: three
                    // interruptions "ignored until it finished").
                    lastEchoScore = score(tokens)
                    guard isEarlyInterruption(tokens, onAir: segment.onAir) else { break }
                }
                out += cancel(now: now)
                break
            }
            if index.map({ segments[$0].responded }) == true { break }   // a completed transcript re-sent
            let id = (index.map { segments[$0].itemId } ?? nil) ?? itemId
            guard let index else {
                guard !tokens.isEmpty else {
                    if let id { out.append(.deleteItem(id: id)) }   // no words, no segment: nothing to wait for
                    break
                }
                // No segment we saw begin: a server that sends no
                // speech_started, or the ASR of the turn a reply is already
                // answering, landing late (it used to wipe the reply's first
                // words — VoiceCaptionTests). Caption it; answer it only if
                // nothing is on air; never cut a reply on it.
                out.append(.userTurn(text))
                if !holdToTalk, !modelBusy {
                    pendingTurnSince = now
                    out.append(.startConfirmTimer(ms: Self.turnHoldMs))
                    out.append(.uiState(.thinking))
                }
                break
            }
            let segment = segments[index]
            var notATurn = tokens.isEmpty                       // a cough, "um", "…", an echo heard as Chinese
            if !notATurn, segment.echoJudged, tokens.count < 3 {
                notATurn = true                                 // a later piece of the echo already judged
            } else if !notATurn, segment.echoPossible || segment.echoJudged {
                lastEchoScore = score(tokens)
                notATurn = isEcho(tokens, onAir: segment.onAir)  // the model's own words, back through the mic
            }
            if notATurn {
                if !tokens.isEmpty { segments[index].echoJudged = true }
                if let id, !pendingDeletes.contains(id) { pendingDeletes.append(id) }
                break
            }
            // The user's turn — possibly riding on the echo's tail inside the
            // same segment; then the whole item is theirs and stays.
            if let id { pendingDeletes.removeAll { $0 == id } }
            segments[index].echoJudged = false
            out.append(.userTurn(text))
            if holdToTalk { break }   // the release already committed + asked
            segments[index].responded = true
            out += flushPendingDeletes(except: nil)   // before the ask: the model never sees the echo items
            if modelBusy && !alreadyCancelled { out += cancel(now: now) }
            // Not asked for yet: the hold first (they may be mid-sentence),
            // and, if a cancel is in flight, its done — or the fallback.
            pendingTurnSince = now
            out.append(.startConfirmTimer(ms: Self.turnHoldMs))
            if responseActive { out.append(.startConfirmTimer(ms: Self.pendingCreateFallbackMs)) }
            out.append(.uiState(.thinking))

        case .assistantTranscript(let delta):
            let t = Self.tokens(delta)
            guard !t.isEmpty else { break }
            spokenCurrent.append(contentsOf: t)
            if spokenCurrent.count > Self.spokenCap { spokenCurrent.removeFirst(spokenCurrent.count - Self.spokenCap) }
            spokenSet = Set((spokenPrevious + spokenCurrent).map(Self.stem))

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
                    out += cancel(now: now)
                } else {
                    out += restoreToSpeaking()
                }
            }
            out += tryAsk(now: now)

        case .interruptPressed:
            if state == .hold { break }
            pendingTurnSince = nil   // the user wants silence, not the next reply
            if modelBusy {
                out += cancel(now: now, hard: true)
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
            if pendingCreate {
                // Our cancel found nothing to cancel — the reply had already
                // finished. Its done is not coming; ask once the hold is up.
                let ask = tryAsk(now: now)
                out += ask.isEmpty ? [.startConfirmTimer(ms: Self.turnHoldMs)] : ask
            } else {
                out.append(.uiState(uiStateNow))
            }

        case .routeChanged(let route):
            let next = BargeInProfile.forRoute(route)
            if next != profile {
                profile = next
                if !holdToTalk { out.append(.updateTurnDetection(turnDetection)) }
            }

        case .pttDown:
            guard holdToTalk, state != .hold else { break }
            if modelBusy { out += cancel(now: now, hard: true) }
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

    /// The segment a transcript belongs to: by item id when both sides carry
    /// one; otherwise (id-less on either side) the most recent segment. Two
    /// different ids is no match — never attribute one item's words to
    /// another's segment.
    private func segmentIndex(for itemId: String?) -> Int? {
        if let itemId, let i = segments.lastIndex(where: { $0.itemId == itemId }) { return i }
        guard let last = segments.indices.last else { return nil }
        return (itemId == nil || segments[last].itemId == nil) ? last : nil
    }

    /// The held turn, asked for when it is ready: the hold has elapsed since
    /// the user was last heard, the server VAD is silent, and no reply is
    /// generating — or the cancelled reply's done never came (the fallback).
    private mutating func tryAsk(now: TimeInterval) -> [BargeInCommand] {
        guard let since = pendingTurnSince else { return [] }
        let elapsed = Int(((now - since) * 1000).rounded())
        if responseActive {
            guard elapsed >= Self.pendingCreateFallbackMs else { return [] }
            responseActive = false
        } else {
            guard elapsed >= Self.turnHoldMs, !serverSpeaking else { return [] }
        }
        pendingTurnSince = nil
        return [.createResponse, .uiState(.thinking)]
    }

    /// The held deletes, as commands — all of them, or all but one item's.
    private mutating func flushPendingDeletes(except itemId: String?) -> [BargeInCommand] {
        let due = pendingDeletes.filter { $0 != itemId }
        pendingDeletes.removeAll { $0 != itemId }
        return due.map { .deleteItem(id: $0) }
    }

    private func score(_ heard: [String]) -> (hits: Int, heard: Int, spoken: Int) {
        let e = echoEvidence(heard)
        return (e.hits, e.heard, spokenPrevious.count + spokenCurrent.count)
    }

    /// Words that carry no content — the transcriber adds and drops them
    /// freely ("Monday's open" came back as "Monday is open", device log
    /// 2026-09-19 23:50), and a real interruption is full of them ("How about
    /// Tuesday?" shares two of three with "How about you?"). They only count
    /// when an utterance has nothing else ("How about you?", "Okay.").
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as",
        "into", "over", "about", "up", "down", "out", "off", "than", "then", "too", "also",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "may", "might", "shall", "must",
        "i", "me", "my", "mine", "you", "your", "yours", "youre", "youve", "youll", "youd", "he", "him", "his", "she", "her", "hers",
        "it", "its", "im", "ive", "ill", "id", "we", "us", "our", "ours", "weve", "well", "they", "them", "their", "theyre",
        "this", "that", "these", "those", "there", "here", "what", "which", "who", "whom", "whose", "how", "when", "where", "why",
        "not", "no", "yes", "ok", "okay", "oh", "um", "uh", "hmm", "just", "really", "very", "quite",
    ]

    /// Plurals and possessives fold ("mondays" / "players" → "monday" /
    /// "player"): the model writes Monday's, the transcriber Monday is.
    static func stem(_ t: String) -> String {
        guard t.count >= 4, t.hasSuffix("s") else { return t }
        return String(t.dropLast())
    }

    /// Content words heard vs the reference (whole utterance if it has none),
    /// and the stretches BEFORE the first / AFTER the last content word the
    /// model said: how many words each, and whether either holds a content
    /// word the model never said.
    private struct EchoEvidence {
        var hits = 0, heard = 0
        var fallback = false
        var leading = 0, leadingMisses = 0
        var trailing = 0, trailingMisses = 0
        var firstContentIsHit = false
    }
    /// A heard word matches a said one outright, or is the START of one at
    /// least two letters longer: the transcriber heard "Alright" as "All
    /// right" and caught "anything" mid-word as "any" (device log 2026-09-20
    /// 00:25, both cut the reply). Three letters at least, so "on" is not
    /// "Monday".
    private func matches(_ t: String) -> Bool {
        let s = Self.stem(t)
        if spokenSet.contains(s) { return true }
        guard s.count >= 3 else { return false }
        return spokenSet.contains { $0.count >= s.count + 2 && $0.hasPrefix(s) }
    }

    private func echoEvidence(_ heard: [String]) -> EchoEvidence {
        var e = EchoEvidence()
        let isContent: (String) -> Bool = { !Self.stopWords.contains($0) }
        let isHit: (String) -> Bool = { isContent($0) && self.matches($0) }
        // A content word the model never said — of three letters or more:
        // "go" alone cut a reply ("Have to go", same log).
        let isMiss: (String) -> Bool = { isContent($0) && !self.matches($0) && $0.count >= 3 }
        let content = heard.filter(isContent)
        let judged = content.isEmpty ? heard : content
        e.hits = judged.filter(matches).count
        e.heard = judged.count
        e.fallback = content.isEmpty
        e.firstContentIsHit = content.first.map(isHit) ?? false
        let first = heard.firstIndex(where: isHit)
        let last = heard.lastIndex(where: isHit)
        let head = heard[..<(first ?? heard.count)]
        let tail = last.map { heard[($0 + 1)...] } ?? heard[...]
        e.leading = head.count
        e.leadingMisses = head.filter(isMiss).count
        e.trailing = tail.count
        e.trailingMisses = tail.filter(isMiss).count
        return e
    }

    /// While a segment is still open, from the transcriber's live guess: cut
    /// the reply only on clear evidence — three or more words, the first
    /// content word not one the model said (the user's words come first in a
    /// mixed segment; an echo's do not), at least one content word the model
    /// never said, and not echo by the usual rules. A garbled echo ("Lucks
    /// pretty solid") stays echo; "How will this be like" cuts at word five.
    func isEarlyInterruption(_ heard: [String], onAir: Bool) -> Bool {
        guard heard.count >= 3, !spokenSet.isEmpty else { return heard.count >= 3 && spokenSet.isEmpty }
        let e = echoEvidence(heard)
        guard !e.fallback, !e.firstContentIsHit, e.leadingMisses + e.trailingMisses >= 1 else { return false }
        return !isEcho(heard, onAir: onAir)
    }

    /// Lower-cased word tokens, punctuation and APOSTROPHES stripped, one-letter
    /// tokens dropped ("a", "I" match everything). The model writes Tuesday’s
    /// with a curly apostrophe and the transcriber writes Tuesday's with a
    /// straight one — that one character failed a three-word echo at 2/3
    /// (device log 2026-09-19 22:39:30), so both become "tuesdays". Tokens
    /// without a Latin letter or digit are dropped: the transcriber sometimes
    /// hears the loudspeaker's echo as Chinese ("嘿。" for "Hey", same log),
    /// and this assistant speaks English — such a transcript is noise, never
    /// an instruction to stop.
    static func tokens(_ text: String) -> [String] {
        let noApostrophes = text.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        return noApostrophes.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count >= 2 && $0.unicodeScalars.contains { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))) } }
    }

    /// Echo: the content words heard are words the model just said. Not all
    /// of them — the transcriber garbles short echoes ("Saturday's clear" →
    /// "Saturday's players", 1 of 2). While the reply's audio is ON AIR half
    /// is enough: echo is the likeliest source of a match, and a two-word
    /// interruption that shares one topic word can be repeated once the reply
    /// ends. In the drain grace only the reply's tail can echo, so a
    /// follow-up sharing one word ("Tuesday morning" after "Tuesday's wide
    /// open") stays a turn: 60 %. Filler-only utterances: 70 % of all words.
    func isEcho(_ heard: [String], onAir: Bool = true) -> Bool {
        guard !heard.isEmpty, !spokenSet.isEmpty else { return false }
        let e = echoEvidence(heard)
        // Their words and the echo's in ONE segment: a question riding on the
        // echo's tail ("…coming up on Friday. What about Monday?" — the reply
        // ended, they spoke before the VAD's 600 ms), or their interruption
        // with the echo of what played after it ("How will this be like?
        // You've got a few tasks wrapped up", device log 2026-09-20). Three
        // or more words before the first / after the last word the model
        // said, with a content word among them it never said, are theirs,
        // whatever the ratio. A garbled echo differs by one word.
        if !e.fallback, e.trailing >= 3, e.trailingMisses >= 1 { return false }
        if !e.fallback, e.leading >= 3, e.leadingMisses >= 1 { return false }
        let threshold: Double = e.fallback ? 0.7 : (onAir ? 0.5 : 0.6)
        return Double(e.hits) / Double(e.heard) >= threshold
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
    private mutating func cancel(now: TimeInterval, hard: Bool = false) -> [BargeInCommand] {
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
        if playbackQueued {
            // The last of the flushed audio is already in the room and comes
            // back as a segment of its own, exactly as after a natural drain
            // (device log 2026-09-20 00:04:43: "And Friday." 90 ms after a flush).
            lastDrained = (playingResponseId, now)
            playingResponseId = nil
        }
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
