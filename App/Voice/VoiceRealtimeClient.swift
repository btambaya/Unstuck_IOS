// Realtime voice client for Qwen-Omni (via the Cloudflare proxy). Streams mic
// PCM16/16k up, plays the model's PCM16/24k speech back, surfaces live captions,
// and runs the agent's tool calls through the SAME executor as text mode.
// 1:1 port of the web lib/voice/realtime-client.ts (which is itself the
// Android client) — the wire protocol is identical:
//
//   session.update {modalities, instructions, input/output_audio_format:pcm16,
//                   turn_detection:{server_vad, threshold, prefix_padding_ms,
//                   silence_duration_ms, interrupt_response:false,
//                   create_response:false} per ROUTE PROFILE — the CLIENT cancels
//                   and creates every reply (BargeIn.swift) (or null for
//                   hold-to-talk), tools, tool_choice}  — re-sent on route change
//   client → conversation.item.create {PRIMER}  + response.create   (opening)
//   client → input_audio_buffer.append {audio: base64}
//   server → response.audio.delta {delta: base64}           (24k speech)
//          → response.audio_transcript.delta {delta}          (captions)
//          → input_audio_buffer.speech_started/stopped        (→ barge-in)
//   client → response.cancel                                 (confirmed barge-in)
//          → response.function_call_arguments.done {name, call_id, arguments}
//          → response.output_item.done {item: function_call}  (same, other shape)
//   client → conversation.item.create {function_call_output, call_id, output}
//          → response.create (coalesced)
//   client → conversation.item.delete {PRIMER}  on the first response.done
//
// Plus the voice integrity guard: a spoken "I've added it" with no tool call
// behind it in that response gets one hidden corrective (3 per session).
//
// BARGE-IN (App/Voice/BargeIn.swift — pure, tested): the client only feeds
// events (speech_started/stopped, response ids, gate open/close from the
// audio engine, playback drained, the Interrupt button, route changes, the
// confirm-timer tick) into `BargeInController` under the lock and executes
// the commands it returns outside it — duck −12 dB, confirm, then either
// response.cancel + flush + mute stale deltas, or restore. Audio/transcript
// deltas are dropped for a cancelled response id even after a new response
// is created. "active response" protocol errors are benign.
//
// Transport is URLSessionWebSocketTask (Foundation). The audio engine is behind
// the VoiceAudioIO seam so this file compiles independently of the AVAudioEngine
// implementation.
//
// LOCKING: every touch of the mutable flags goes through `withLock` (NSLock's
// scoped `withLock` is async-safe; its bare lock()/unlock() are `noasync`
// under Swift 6, and the tool-result path runs inside a Task).

import AVFoundation
import Foundation
import os
import UnstuckCore

/// Lifecycle logging for realtime voice. Deliberately thin and content-free:
/// session boundaries, the handshake, and every failure — never a token, a
/// transcript, or an event payload. Voice can only be diagnosed from a device
/// (the mic, the route, the socket), so `log stream --predicate 'subsystem ==
/// "io.unstucknow.app"'` has to be enough to tell transport failures from
/// audio failures from "never even started".
let voiceLog = Logger(subsystem: "io.unstucknow.app", category: "voice")

/// The audio side the realtime client drives — implemented by VoiceAudioEngine.
/// Capture delivers 16 kHz mono PCM16 frames; playback consumes 24 kHz mono PCM16.
protocol VoiceAudioIO: AnyObject {
    /// Begin playback (open the output graph); safe to call before any audio.
    func startPlayback()
    /// Begin mic capture; `onFrame` is called with each ~100ms PCM16/16k frame.
    func startCapture(_ onFrame: @escaping @Sendable (Data) -> Void)
    /// Queue a PCM16/24k chunk for playback.
    func enqueue(_ pcm: Data)
    /// Barge-in: drop queued audio + cut current playback immediately.
    func flushPlayback()
    /// Playback gain, linear (0.25 = −12 dB duck, 1 = unity), short ramp.
    func setPlaybackGain(_ gain: Float)
    /// The capture gate's context (margin / adaptation freeze / hold-to-talk).
    func setGateContext(_ ctx: GateContext)
    /// Re-measure the noise floor (route change).
    func recalibrateGate()
    /// The capture gate opened (true) / closed (false). Off the main thread.
    var onGateChange: (@Sendable (_ open: Bool) -> Void)? { get set }
    /// The last scheduled playback buffer finished playing. Off the main thread.
    var onPlaybackDrained: (@Sendable () -> Void)? { get set }
    /// Tear everything down (joins capture/playback, restores the audio session).
    func shutdown()
}

enum VoiceState: Sendable { case connecting, listening, thinking, speaking, error, closed }

/// The voice integrity guard's per-response bookkeeping — pure, so the
/// "claim with no tool → corrective, capped, never loops" rule is unit-testable
/// without a socket. Mirrors the web client's respTranscript / respToolCalled /
/// respWasCorrection / nextRespToolBacked / correctionsLeft.
struct VoiceIntegrityGuard: Sendable {
    var transcript = ""
    var toolCalled = false
    var wasCorrection = false
    /// The reply AFTER a tool result is tool-backed.
    var nextResponseToolBacked = false
    static func counts(_ name: String) -> Bool { !READ_ONLY_TOOLS.contains(name) && !NAVIGATION_TOOLS.contains(name) }
    /// Per-session cap — never loop.
    var correctionsLeft = 3

    /// The corrective injected as a hidden user item (verbatim from the web).
    static let correctiveText = "(integrity check from the app, not the user: you claimed an action or said you would note something, but no tool ran — nothing actually happened. If it is still needed, call the right tool NOW, then say in a few words what you did (e.g. \"Added it now\") — no apology, no explanation. Never claim an action without its tool call.)"

    mutating func responseCreated() {
        transcript = ""
        toolCalled = nextResponseToolBacked
        nextResponseToolBacked = false
    }
    mutating func bargeIn() { transcript = "" }
    mutating func transcriptDelta(_ d: String) { transcript += d }
    /// A tool ran during this response (read-only tools don't make it "tool-backed").
    // Tool-backed = a tool that CHANGES something (not a read, not opening a
    // screen) whose result says "ok:" — the same rule as the text harness
    // (docs/assistant-tooling-rules.md §3, 2026-09-20). "Not an error" let a
    // bare "ok" from a seam that could not fail back a spoken claim.
    mutating func toolDispatched(_ name: String) { if Self.counts(name) { toolCalled = true } }
    mutating func toolFinished(_ name: String, result: String) {
        nextResponseToolBacked = result.hasPrefix("ok:") && Self.counts(name)
    }
    /// A cancelled/incomplete response (barge-in) is not a claim.
    mutating func responseCancelled() { wasCorrection = false }

    /// Called on a COMPLETED response: true when a corrective must be sent.
    mutating func shouldCorrect() -> Bool {
        if wasCorrection { wasCorrection = false; return false }
        if toolCalled || correctionsLeft <= 0 { return false }
        if !looksLikeActionClaim(transcript) { return false }
        correctionsLeft -= 1
        wasCorrection = true
        return true
    }
}

/// `@unchecked Sendable`: the socket (URLSessionWebSocketTask) is thread-safe to
/// send on from any thread, and the few mutable flags are guarded by `lock`.
final class VoiceRealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Client-chosen id for the hidden opening primer so it can be deleted after
    /// the first response — 32 hex chars keeps every realtime backend happy.
    static let primerItemId = "a0e1f2d3c4b5a6978869504132231405"
    /// Client event id on the primer delete, so ONLY its rejection is swallowed.
    static let primerDeleteEvent = "evt_primer_delete_0001"

    private let proxyURL: String          // wss://…workers.dev (token added as a header)
    private let token: String             // Supabase access token (the Worker validates it)
    private let model: String
    private let instructions: String      // system prompt + live context
    /// What the assistant should DO the moment the session opens — sent as a
    /// synthetic user item the user never sees, deleted after the first reply.
    private let opening: String
    private let tools: [[String: Any]]    // tool schemas (OpenAI/DashScope shape)
    private var audio: VoiceAudioIO
    /// Monotonic seconds for the barge-in confirm timer (injectable for tests).
    private let now: @Sendable () -> TimeInterval
    /// Where playback comes out — decides the barge-in profile. Read at open
    /// and on every AVAudioSession route change; `initialRoute` overrides the
    /// first read (tests / a caller that already knows).
    private let routeProvider: @Sendable () -> VoiceRoute
    private let initialRoute: VoiceRoute?
    private var routeObserver: (any NSObjectProtocol)?
    // Args are passed as the raw JSON STRING (Sendable) — `[String: Any]` can't
    // cross the Task boundary under Swift 6; the executor parses it.
    private let runTool: @Sendable (_ name: String, _ argsJSON: String) async -> String
    private let onState: @Sendable (VoiceState) -> Void
    private let onCaption: @Sendable (_ role: String, _ text: String, _ done: Bool) -> Void
    private let onError: @Sendable (String) -> Void
    /// The TRANSPORT went away on its own — the socket failed, was rejected,
    /// or closed cleanly (`nil`). Fired at most once and NEVER for our own
    /// `stop()`. Set it BEFORE `start()`. The CallKit launcher hangs up on
    /// this; a protocol-level `error` event (which only flips the state to
    /// `.error`) does NOT end the transport. Optional, so Talk mode is unchanged.
    var onTransportEnded: (@Sendable (_ error: String?) -> Void)?

    // A per-session URLSession with `self` as the WebSocket delegate (so onOpen
    // fires only AFTER the handshake). It RETAINS the delegate until
    // invalidateAndCancel() in stop(), which also releases the session's queue.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // The socket is long-lived (no idle timeout), but the DIAL must fail:
        // with waitsForConnectivity a stalled connect yields no delegate call at
        // all — measured past 100 s — and the screen sits on "Connecting…" for
        // ever. The watchdog in start() is the backstop for the rest.
        cfg.timeoutIntervalForRequest = 0
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var _open = false
    private var _stopped = false
    /// The barge-in state machine (muted / responseActive / cancelled id /
    /// playbackQueued / gate / profile all live here). Mutated ONLY under
    /// `lock`; its commands run outside it.
    private var _bargeIn: BargeInController
    /// The user muted the MIC (CallKit's mute button → the launcher): captured
    /// frames are dropped before upload, so the server VAD hears silence.
    private var _micMuted = false
    /// Last seen AVAudioSession port set (see observeRoute).
    private var _routeFingerprint = ""
    // Guards against double error-reporting from the receive loop AND the
    // didCompleteWithError delegate for the same failed connection.
    private var _reportedError = false
    private var _primerDeleted = false
    /// Any response.created seen this session, and how many opening
    /// response.creates went out (the first + at most one retry).
    private var _anyResponse = false
    private var _openedOnce = false
    /// The server failed the session before it did anything: its capacity
    /// error ("thread pool exausted max_workers 100", 1 s after the socket
    /// opened — device, 2026-09-20 00:41, fine on the second try) or a drop
    /// before any reply. Not an error state: the screen reconnects quietly
    /// (`onTransportEnded` + `failedBeforeAnyReply`).
    private var _earlyFailure = false
    var failedBeforeAnyReply: Bool { withLock { _earlyFailure } }
    private var _openingCreates = 0
    private var _guard = VoiceIntegrityGuard()
    /// Both event shapes can carry the same call — dispatch once.
    private var _handledCalls = Set<String>()
    /// One coalesced response.create after tool outputs — a response.create per
    /// parallel call races "already has an active response" errors.
    private var _continueTask: Task<Void, Never>?

    /// Synchronous scoped locking — the ONLY way the flags are touched.
    /// Callable from async contexts (NSLock's bare lock()/unlock() are not).
    private func withLock<T>(_ body: () -> T) -> T { lock.withLock(body) }

    /// Settings key for the hold-to-talk fallback (spec §8). Talk mode passes
    /// `holdToTalk: VoiceRealtimeClient.holdToTalkPreferred`; a CallKit call
    /// never does (there is no press UI on the lock screen).
    static let holdToTalkKey = "unstuck.voice.holdToTalk"
    static var holdToTalkPreferred: Bool { UserDefaults.standard.bool(forKey: holdToTalkKey) }

    /// `holdToTalk`: turn_detection null; the caller drives `pttDown()` /
    /// `pttUp()` (default false — server VAD). `initialRoute`: skip the
    /// AVAudioSession read for the first profile. `now`: monotonic clock.
    init(proxyURL: String, token: String, model: String, instructions: String, opening: String,
         tools: [[String: Any]], audio: VoiceAudioIO,
         runTool: @escaping @Sendable (_ name: String, _ argsJSON: String) async -> String,
         onState: @escaping @Sendable (VoiceState) -> Void,
         onCaption: @escaping @Sendable (_ role: String, _ text: String, _ done: Bool) -> Void,
         onError: @escaping @Sendable (String) -> Void,
         holdToTalk: Bool = false,
         initialRoute: VoiceRoute? = nil,
         routeProvider: @escaping @Sendable () -> VoiceRoute = { VoiceRoute(portType: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.proxyURL = proxyURL
        self.now = now
        self.routeProvider = routeProvider
        self.initialRoute = initialRoute
        self._bargeIn = BargeInController(profile: .forRoute(initialRoute ?? .speaker), holdToTalk: holdToTalk)
        self.token = token
        self.model = model
        self.instructions = instructions
        self.opening = opening
        self.tools = tools
        self.audio = audio
        self.runTool = runTool
        self.onState = onState
        self.onCaption = onCaption
        self.onError = onError
        super.init()
    }

    // MARK: lifecycle

    func start() {
        onState(.connecting)
        // Strip any existing query, then add ?model= (matches the Android URL build).
        let base = proxyURL.components(separatedBy: "?").first ?? proxyURL
        guard let url = URL(string: base + "?model=" + model) else {
            transportEnded(error: "Bad voice proxy URL"); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        voiceLog.notice("voice connect host=\(url.host ?? "nil", privacy: .public) model=\(self.model, privacy: .public) tokenLen=\(self.token.count, privacy: .public)")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        // Nothing in URLSession fails a dial that stalls after the TCP connect,
        // so a proxy that accepts and never upgrades would hang "Connecting…"
        // for ever. 15 s, then we say so.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            let stuck = self.withLock { !self._open && !self._stopped }
            if stuck { self.transportEnded(error: "Couldn't reach the voice server. Check your connection and try again.") }
        }
        // onOpen() runs in the delegate's didOpenWithProtocol — only after the
        // handshake succeeds — so the mic/playback/"Listening" don't spin up on an
        // unreachable proxy or a rejected token. receiveLoop starts there too.
    }

    // URLSessionWebSocketDelegate: the socket finished its upgrade handshake.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        voiceLog.notice("voice socket open (subprotocol=\(`protocol` ?? "none", privacy: .public))")
        onOpen()
        receiveLoop()
    }

    // The connection ended/failed (incl. a pre-handshake failure — unreachable
    // proxy, rejected token — where didOpen never fires and receiveLoop never
    // started). Ignore the invalidation we trigger ourselves on stop(). A clean
    // remote close (no error) ends the session as `.closed` rather than leaving
    // a dead socket behind a live "Listening…".
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // The HTTP status is the difference between "the proxy rejected us"
        // (401 → a bad/expired token) and "we never reached it" — the socket
        // API only surfaces the generic -1011 for both.
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if let ns = error as NSError? {
            voiceLog.error("voice socket failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) http=\(status, privacy: .public)")
        }
        // CFNetwork collapses every rejection into -1011 ("bad response from the
        // server"), which tells the user nothing. The status distinguishes an
        // expired token from the proxy's concurrent-session cap.
        let friendly: String?
        switch status {
        case 401: friendly = "Your session expired — sign in again to use voice."
        case 403: friendly = "Voice isn't available on this build."
        case 429: friendly = "A voice session is already running. Close it and try again in a moment."
        case let s where s >= 500: friendly = "The voice server is unavailable right now (\(s))."
        default: friendly = error.map { String($0.localizedDescription.prefix(160)) }
        }
        transportEnded(error: friendly)
    }

    func stop() {
        let first: (socket: URLSessionWebSocketTask?, cont: Task<Void, Never>?)? = withLock {
            if _stopped { return nil }
            _stopped = true; _open = false
            let pair = (task, _continueTask)
            task = nil
            _continueTask = nil
            return pair
        }
        guard let first else { return }
        first.cont?.cancel()
        first.socket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()   // release the session + its op queue + the delegate retain
        stopObservingRoute()
        audio.shutdown()
        onState(.closed)
    }

    /// Manual interrupt = HARD cancel (never ducks): cut playback now, tell the
    /// server to stop generating (only if a response is active — DashScope
    /// errors "Conversation has no active response" otherwise), and reopen the
    /// mic. Stale audio/captions from the cancelled response are dropped until
    /// the next response begins. A cancelled reply is never scored as a claim.
    /// No-op while nothing is generating or queued.
    func interrupt() {
        guard withLock({ _open }) else { return }
        dispatch(.interruptPressed)
    }

    /// Hold-to-talk (`holdToTalk: true` only): the orb went down — cancels a
    /// playing reply and opens the gate; nothing is appended while released.
    func pttDown() {
        guard withLock({ _open }) else { return }
        dispatch(.pttDown)
    }

    /// Hold-to-talk: the orb was released — commit the buffer + ask for a reply.
    func pttUp() {
        guard withLock({ _open }) else { return }
        dispatch(.pttUp)
    }

    // MARK: barge-in

    /// Feed one event to the state machine under the lock, then execute what
    /// it asks for outside it. A CANCEL (any command list carrying
    /// flushPlayback) also resets the integrity guard's transcript.
    private func dispatch(_ event: BargeInEvent) {
        let t = now()
        let (cmds, stateAfter): ([BargeInCommand], String) = withLock {
            let c = _bargeIn.handle(event, now: t)
            if c.contains(.flushPlayback) { _guard.bargeIn() }
            let e = _bargeIn.lastEchoScore
            return (c, "\(_bargeIn.state) gate=\(_bargeIn.gateOpen) server=\(_bargeIn.serverSpeaking) echo=\(e.hits)/\(e.heard) ref=\(e.spoken)")
        }
        // The barge-in decisions, content-free: which event, what it decided.
        // Ducks/restores/cancels are a handful per session; routine events
        // (audio deltas, ticks that decided nothing) stay out of the log.
        let decisive = cmds.contains { c in
            switch c { case .duck, .restore, .sendCancel, .flushPlayback, .createResponse, .deleteItem: return true; default: return false }
        }
        switch event {
        case .speechStarted, .speechStopped, .transcription, .interruptPressed, .gateOpen, .gateClose:
            voiceLog.notice("voice barge-in \(String(describing: event), privacy: .public) → \(Self.describe(cmds), privacy: .public) [\(stateAfter, privacy: .public)]")
        default:
            if decisive { voiceLog.notice("voice barge-in \(String(describing: event), privacy: .public) → \(Self.describe(cmds), privacy: .public) [\(stateAfter, privacy: .public)]") }
        }
        execute(cmds)
    }

    /// Command kinds only (no payloads) for the log line above.
    private static func describe(_ cmds: [BargeInCommand]) -> String {
        let kinds: [String] = cmds.compactMap { c in
            switch c {
            case .duck: return "duck"
            case .restore: return "restore"
            case .sendCancel: return "cancel"
            case .deleteItem: return "delete-echo"
            case .createResponse: return "respond"
            case .userTurn: return "turn"
            case .flushPlayback: return "flush"
            case .startConfirmTimer(let ms): return "timer\(ms)"
            case .uiState(let s): return "ui:\(s)"
            default: return nil
            }
        }
        return kinds.isEmpty ? "-" : kinds.joined(separator: ",")
    }

    private func execute(_ cmds: [BargeInCommand]) {
        for c in cmds {
            switch c {
            case .duck: audio.setPlaybackGain(0.25)
            case .restore: audio.setPlaybackGain(1)
            case .flushPlayback: audio.flushPlayback()
            case .sendCancel: send(["type": "response.cancel"])
            case .deleteItem(let id): send(["type": "conversation.item.delete", "item_id": id])
            case .createResponse: send(["type": "response.create"])
            case .commitAndRespond:
                send(["type": "input_audio_buffer.commit"])
                send(["type": "response.create"])
            case .startConfirmTimer(let ms):
                // Stale ticks are harmless: the controller checks the elapsed
                // time against the CURRENT duck, so a timer from an earlier
                // episode never confirms a later one early.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    guard let self, self.withLock({ self._open }) else { return }
                    self.dispatch(.tick)
                }
            case .updateTurnDetection:
                // session.update is allowed mid-session; re-send the whole
                // thing (instructions/tools unchanged) so a backend that
                // replaces rather than merges keeps them.
                send(sessionUpdate())
            case .updateGate(let ctx): audio.setGateContext(ctx)
            case .clearCaption:
                // A completed EMPTY user caption = "new turn": the screen
                // clears the streaming reply and keeps the last user line.
                onCaption("user", "", true)
            case .userTurn(let text):
                // The user's completed words — only for a turn the controller
                // judged real; echo and coughs never reach the screen.
                onCaption("user", text, true)
            case .uiState(let s): onState(s)
            }
        }
    }

    /// Re-profile on every AVAudioSession route change (speaker ↔ receiver /
    /// headset — including CallKit's mid-call speaker toggle): new
    /// turn_detection if the profile changed, and a fresh gate floor either way.
    private func observeRoute() {
        guard routeObserver == nil else { return }
        withLock { _routeFingerprint = Self.routeFingerprint() }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.withLock({ self._open }) else { return }
            // The notification also fires for category/override changes with
            // the SAME ports; only a real port change (speaker ↔ receiver,
            // headset in/out — a different mic too) costs a 500 ms recalibration.
            let fp = Self.routeFingerprint()
            let changed: Bool = self.withLock {
                guard fp != self._routeFingerprint else { return false }
                self._routeFingerprint = fp
                return true
            }
            guard changed else { return }
            let route = self.routeProvider()
            self.audio.recalibrateGate()
            self.dispatch(.routeChanged(route))
        }
    }

    /// Input + output port types of the current route, for change detection.
    private static func routeFingerprint() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        return r.inputs.map(\.portType.rawValue).joined(separator: ",") + "|"
            + r.outputs.map(\.portType.rawValue).joined(separator: ",")
    }

    private func stopObservingRoute() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// Mute/unmute the mic upload (CallKit's mute button → the launcher). The
    /// capture graph keeps running (hardware AEC stays primed); frames are
    /// dropped before they reach the socket.
    func setMicMuted(_ muted: Bool) {
        withLock { _micMuted = muted }
    }

    // MARK: socket

    private func onOpen() {
        // Profile for the route we're actually on BEFORE the first
        // session.update (a CallKit call on the receiver → low-echo).
        let route = initialRoute ?? routeProvider()
        let gateCtx: GateContext = withLock {
            _open = true
            _openedOnce = true
            _ = _bargeIn.handle(.routeChanged(route), now: now())
            return _bargeIn.initialGateContext()
        }
        send(sessionUpdate())
        // Personal-assistant opening (Ahmad, 2026-08-29): the assistant speaks
        // FIRST. DashScope 400s a response.create with NO user element in the
        // conversation, so a synthetic user item primes it. It must be ONE-SHOT:
        // left in the conversation it becomes a standing instruction the model
        // re-executes after every barge-in ("hi, I'm your assistant…" on loop —
        // prod tester bug, 2026-08-30). Known id → deleted on the first response.done.
        send(["type": "conversation.item.create",
              "item": ["id": Self.primerItemId, "type": "message", "role": "user",
                       "content": [["type": "input_text", "text": opening]]]])
        send(["type": "response.create"])
        withLock { _openingCreates = 1 }
        scheduleOpeningWatchdog()
        audio.onPlaybackDrained = { [weak self] in self?.dispatch(.playbackDrained) }
        audio.onGateChange = { [weak self] open in self?.dispatch(open ? .gateOpen : .gateClose) }
        audio.setGateContext(gateCtx)
        audio.startPlayback()
        // The gate decides what reaches the socket: live audio (after its
        // 300 ms pre-roll) while open, digital silence while closed, nothing
        // during its 500 ms floor calibration or in hold-to-talk while released.
        audio.startCapture { [weak self] frame in
            guard let self, self.withLock({ self._open && !self._micMuted }) else { return }
            self.send(["type": "input_audio_buffer.append",
                       "audio": frame.base64EncodedString()])
        }
        observeRoute()
        onState(.listening)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.transportEnded(error: String(err.localizedDescription.prefix(160)))
            case .success(let message):
                if case let .string(text) = message { self.handle(text) }
                // (binary frames aren't used by this protocol)
                if self.withLock({ self._open }) { self.receiveLoop() }
            }
        }
    }

    /// The transport is gone on its own (never via stop()). Reports ONCE:
    /// with an error → onError + `.error`; a clean close → `.closed`; then
    /// `onTransportEnded`. Every failure path (pre-handshake, receive, send,
    /// bad URL) funnels through here so nothing is reported twice.
    private func transportEnded(error: String?) {
        voiceLog.notice("voice transport ended (\(error ?? "clean close", privacy: .public))")
        let first: Bool = withLock {
            if _stopped || _reportedError { return false }   // our own invalidate / already reported
            _open = false; _reportedError = true
            return true
        }
        guard first else { return }
        stopObservingRoute()
        audio.shutdown()
        // Dead on arrival (a server error, or a drop after the handshake
        // before any reply): no error state — the screen reconnects, or
        // reports if it has already tried.
        let early: Bool = withLock {
            if _openedOnce, !_anyResponse, error != nil, onTransportEnded != nil { _earlyFailure = true }
            return _earlyFailure
        }
        if early, let hook = onTransportEnded {
            hook(error)
            return
        }
        if let error {
            onError(error)
            onState(.error)
        } else {
            onState(.closed)
        }
        onTransportEnded?(error)
    }

    /// One server event, already decoded from the socket frame. Internal (not
    /// private) so the caption/barge-in tests can drive REAL event JSON
    /// through the real switch instead of restating what it emits.
    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = ev["type"] as? String else { return }
        let response = ev["response"] as? [String: Any]
        let responseId = (ev["response_id"] as? String) ?? (response?["id"] as? String)
        switch type {
        case "input_audio_buffer.speech_started":
            // The server VAD heard something. While the model is audible this
            // DUCKS (−12 dB) and starts the confirm timer; the state machine
            // turns it into response.cancel + flush + mute (a real barge-in)
            // or a restore (a blip that speech_stopped ends first).
            dispatch(.speechStarted(itemId: ev["item_id"] as? String))
        case "input_audio_buffer.speech_stopped":
            dispatch(.speechStopped)
        case "response.created":
            withLock { _guard.responseCreated(); _anyResponse = true }
            // The model heard the user and is reasoning — "Thinking" until the
            // first audio delta (or an immediate cancel if this reply is the
            // one the server made from a false-start blip).
            dispatch(.responseCreated(id: responseId))
        case "response.audio.delta":
            // Stale audio from a cancelled response (even after a NEW response
            // was created) is dropped by id; muted drops everything until the
            // next response starts.
            guard withLock({ _bargeIn.shouldEnqueueAudio(id: responseId) }) else { return }
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                audio.enqueue(pcm)
                dispatch(.audioDelta(id: responseId))
            }
        case "response.audio_transcript.delta":
            // The echo reference sees EVERY word the model produced, before
            // the caption/cancel gate: a reply cancelled mid-air still played
            // its first second, and that second comes back through the mic.
            if let d = (ev["delta"] as? String) ?? (ev["text"] as? String), !d.isEmpty {
                dispatch(.assistantTranscript(delta: d))
            }
            // Captions for a cancelled reply never leak through (same id rule).
            guard withLock({ _bargeIn.acceptsTranscript(id: responseId) }) else { return }
            if let d = ev["delta"] as? String {
                withLock { _guard.transcriptDelta(d) }
                onCaption("assistant", d, false)
            }
        case "response.audio_transcript.done":
            // Belt and braces for the echo reference: the whole reply at once,
            // in case the deltas lagged the audio (device log 2026-09-19).
            if let t = ev["transcript"] as? String, !t.isEmpty { dispatch(.assistantTranscript(delta: t)) }
            onCaption("assistant", "", true)
        case "conversation.item.input_audio_transcription.delta":
            // Energy profiles: a confirm accelerator that may never arrive.
            // Transcript profiles (loudspeaker): THE confirm — see BargeIn.
            // DashScope: `text` is the confirmed part (empty until the segment
            // ends) and `stash` the live guess, cumulative, first word ~200 ms
            // after speech_started; the OpenAI shape is `delta`. The guess is
            // what lets the controller cut a reply while the user is still
            // talking (2026-09-20).
            let confirmed = (ev["text"] as? String) ?? (ev["delta"] as? String) ?? ""
            let guess = (ev["stash"] as? String) ?? ""
            let piece = confirmed.isEmpty ? guess : confirmed + guess
            dispatch(.transcription(text: piece, itemId: ev["item_id"] as? String, final: false))
        case "conversation.item.input_audio_transcription.completed":
            // THE decision point since build 66: the controller answers with
            // `.userTurn` (caption) + `.createResponse` for a real turn, or
            // `.deleteItem` for echo / no words — nothing is shown or asked
            // for those (the echo used to appear as the user's line and wipe
            // the reply's caption).
            let t = (ev["transcript"] as? String) ?? ""
            dispatch(.transcription(text: t, itemId: ev["item_id"] as? String, final: true))
        case "response.audio.done", "response.done":
            // `response.done` is terminal for the WHOLE reply, so it closes the
            // caption segment too — a backend that never sends
            // response.audio_transcript.done would otherwise let the next
            // segment's deltas run straight into this one's last word. The
            // reducer treats a second segment-end as a no-op.
            if type == "response.done" { onCaption("assistant", "", true) }
            // First response finished → the opening primer has served its
            // purpose; remove it so it can never be re-executed after an
            // interruption. Best effort: a backend without item.delete just
            // leaves it (the primer text also says "once only").
            let deletePrimer: Bool = withLock {
                let d = !_primerDeleted
                _primerDeleted = true
                return d
            }
            if deletePrimer {
                send(["type": "conversation.item.delete", "item_id": Self.primerItemId, "event_id": Self.primerDeleteEvent])
            }
            if type == "response.done" {
                // A cancelled/incomplete response (barge-in) is not a claim:
                // never score it, and never inject a corrective mid-utterance.
                let status = response?["status"] as? String
                let reason = ((response?["status_details"] as? [String: Any])?["reason"] as? String) ?? "-"
                voiceLog.notice("voice response.done status=\(status ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
                if status == nil || status == "completed" { checkFabrication() }
                else { withLock { _guard.responseCancelled() } }
                // responseActive stays true until response.DONE (audio.done
                // can precede function calls): the UI stays "speaking" while
                // the buffered tail plays, then playback_drained → listening.
                dispatch(.responseDone(id: responseId, status: status))
            }
        case "response.function_call_arguments.done":
            handleToolCall(name: ev["name"] as? String, callId: ev["call_id"] as? String, arguments: ev["arguments"] as? String)
        case "response.output_item.done":
            // Some realtime backends deliver function calls (or their name)
            // ONLY on the output_item event — dispatch from here too, deduped
            // by call_id, or calls silently never execute while the model
            // believes it acted (harness audit, 2026-09-01).
            if let item = ev["item"] as? [String: Any], item["type"] as? String == "function_call" {
                handleToolCall(name: item["name"] as? String, callId: item["call_id"] as? String, arguments: item["arguments"] as? String)
            }
        case "error":
            let errObj = ev["error"] as? [String: Any]
            let m = errObj?["message"] as? String ?? (ev["error"] as? String)
            // Swallow ONLY the primer-delete rejection (matched by our client
            // event id or the primer's item id) — a blanket "item…not found"
            // swallow also hid rejected tool outputs.
            let evId = (ev["event_id"] as? String) ?? (errObj?["event_id"] as? String)
            if evId == Self.primerDeleteEvent || (m?.contains(Self.primerItemId) ?? false) { return }
            // A server error before ANY reply started: the session is dead on
            // arrival (the socket closes right after). Not surfaced — the
            // screen reconnects once or twice; only if that fails does the
            // user see a message.
            let early: Bool = withLock {
                guard !_anyResponse, onTransportEnded != nil else { return false }
                _earlyFailure = true
                return true
            }
            if early {
                voiceLog.notice("voice server failed before any reply: \(m ?? "-", privacy: .public)")
                return
            }
            // Benign realtime-protocol hiccups — cancelling/creating a response
            // that is (or isn't) active ("no active response" / "already has an
            // active response") — are NON-fatal: resync and keep listening.
            if let m, m.lowercased().contains("active response") {
                dispatch(.benignActiveResponseError); return
            }
            // Hold-to-talk: a tap too short to capture anything makes the
            // commit fail ("buffer too small" / "buffer is empty"). Not an
            // error state — just keep listening for the next press.
            if let m, withLock({ _bargeIn.holdToTalk }), m.lowercased().contains("buffer") {
                onState(withLock { _bargeIn.uiStateNow }); return
            }
            if let m, !m.isEmpty { onError(String(m.prefix(160))) }
            onState(.error)
        default:
            break
        }
    }

    /// Spoken claim of a completed action with NO tool call in that response →
    /// bounce one hidden corrective so the model acts for real and corrects
    /// itself out loud. Capped per session; never bounces a correction's own
    /// follow-up, so it cannot loop.
    private func checkFabrication() {
        let correct: Bool = withLock { _guard.shouldCorrect() }
        guard correct else { return }
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": VoiceIntegrityGuard.correctiveText]]]])
        send(["type": "response.create"])
    }

    private func handleToolCall(name: String?, callId: String?, arguments: String?) {
        guard let name, let callId else { return }
        let fresh: Bool = withLock {
            if _handledCalls.contains(callId) { return false }   // both event shapes fired
            _handledCalls.insert(callId)
            _guard.toolDispatched(name)
            return true
        }
        guard fresh else { return }
        let argsJSON = arguments ?? "{}"
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runTool(name, argsJSON)
            // Feed the tool result back; the reply after it is tool-backed only
            // when the tool really changed something.
            self.send(["type": "conversation.item.create",
                       "item": ["type": "function_call_output", "call_id": callId, "output": result]])
            self.withLock { self._guard.toolFinished(name, result: result) }
            self.scheduleContinue()
        }
    }

    /// One coalesced response.create ~120ms after the last tool output.
    private func scheduleContinue() {
        withLock {
            _continueTask?.cancel()
            _continueTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { return }
                self.withLock { self._continueTask = nil }
                self.send(["type": "response.create"])
            }
        }
    }

    /// The opening reply went missing once on the device (2026-09-20 00:04:
    /// socket open, primer + response.create sent, and nothing came back — no
    /// response.created, no error — until the user spoke 6 s later; the same
    /// code had greeted in 2 s the session before). Ask again, once, if
    /// nothing has started 2.5 s in. A duplicate while a reply IS starting
    /// only earns an "already has an active response" error, which is benign.
    private func scheduleOpeningWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self else { return }
            let retry: Bool = self.withLock {
                guard self._open, !self._anyResponse, self._openingCreates < 2 else { return false }
                self._openingCreates += 1
                return true
            }
            guard retry else { return }
            voiceLog.notice("voice opening retry: no response 2.5 s after the first response.create")
            self.send(["type": "response.create"])
        }
    }

    // MARK: send helpers

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { [weak self] err in
            guard let self, let err else { return }
            // A send failure means the socket is gone — but the mic keeps encoding
            // and queuing appends, so without this the session would silently
            // wedge ("Listening…" with a dead socket). Tear down once.
            self.transportEnded(error: String(err.localizedDescription.prefix(160)))
        }
    }

    private func sessionUpdate() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": instructions,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                // Per route profile (BargeInProfile); NSNull for hold-to-talk.
                "turn_detection": TurnDetection.json(withLock { _bargeIn.turnDetection }),
                "tools": tools,
                "tool_choice": "auto",
            ],
        ]
    }
}
