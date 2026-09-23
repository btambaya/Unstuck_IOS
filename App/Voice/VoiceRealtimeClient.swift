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
//          → conversation.item.truncate {item_id, content_index:0,
//            audio_end_ms}          (a reply cut on air: only what was HEARD)
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
    /// Queue a PCM16/24k chunk for playback. `itemId` = the conversation item
    /// it belongs to (the delta's `item_id`), so a cut reply can be truncated.
    func enqueue(_ pcm: Data, itemId: String?)
    /// What the user has heard of the item being played — read BEFORE
    /// `flushPlayback()`, which resets it. nil when nothing has played.
    func playbackPosition() -> PlaybackPosition?
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
    static let correctiveText = "(integrity check from the app, not the user: you said you did or would do something, but no tool ran — nothing happened. Call the right tool NOW, with sensible defaults for anything you were not told (a call label can be a few words, a call time is context.now plus what they said); do not ask again what you already asked. Then say in a few words what the result was — no apology, no explanation.)"
    /// The corrective's response is created with `tool_choice: required`: the
    /// model MUST call a tool in it. Spoken, the corrective was answered with
    /// another promise and the same question ("I'll book the call now. What
    /// time should it be?" twice, 2026-09-20 15:37); forced, the same turn
    /// booked the call (measured against DashScope, probe_dup.py P1).
    static let correctiveResponse: [String: String] = ["tool_choice": "required"]

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
    /// Client event ids on truncates, so their rejections are recognised.
    static let truncateEventPrefix = "evt_truncate_"

    private let proxyURL: String          // wss://…workers.dev (token added as a header)
    private let token: String             // Supabase access token (the Worker validates it); the fallback when `freshToken` is set
    /// Resolves the token at DIAL time (`forceRefresh` after a 401), so a
    /// dial never goes out with a token cached before the app was suspended
    /// (audit 2026-09-22, C14). MUST return within a few seconds — it is dead
    /// air on a call, and the dial watchdog (`dialTimeout`) gives up on a dial
    /// still waiting for it. nil (or no provider) = dial with `token`.
    private let freshToken: (@Sendable (_ forceRefresh: Bool) async -> String?)?
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
    /// Test seam: when set (before `start()`), a dial hands its request here
    /// instead of opening a socket. Never set in the app.
    var dialOverride: (@Sendable (URLRequest) -> Void)?
    /// Test seam: when set, every outgoing frame is handed here instead of the
    /// socket (what a barge-in actually sends). Never set in the app.
    var sendOverride: (@Sendable (String) -> Void)?
    /// How long a dial may go unopened (token wait included) before start()'s
    /// watchdog gives up, and how much longer the one redial after a 401 gets.
    /// Settable (before `start()`) only so tests don't wait 15 s.
    var dialTimeout: TimeInterval = 15
    var authRedialGrace: TimeInterval = 5

    /// What a 401 from the proxy tells the user (the token was refused even
    /// after a forced refresh, or there is no provider to refresh it).
    static let sessionExpiredMessage = "Your session expired — sign in again to use voice."

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
    /// The one forced refresh + redial after a pre-open 401 has been spent.
    private var _authRetried = false
    /// The token the current dial sent — a forced refresh that hands it back
    /// is no answer to the proxy refusing it.
    private var _dialedToken: String?
    /// The token bucket's reset, from the last `rate_limits.updated`.
    private var _tokenResetSec: Double?

    /// How long to wait before re-asking a rate-limited reply: the bucket's
    /// own reset when known, else the server's "try again in 6.9s", else 5 s;
    /// 1–30 s.
    static func retryAfterMs(message: String, tokenReset: Double?) -> Int {
        var sec: Double = tokenReset ?? 0
        if sec <= 0, let r = message.range(of: #"try again in ([0-9.]+)\s*s"#, options: .regularExpression) {
            let digits = message[r].filter { "0123456789.".contains($0) }
            sec = Double(digits) ?? 0
        }
        if sec <= 0 { sec = 5 }
        return Int((min(30, max(1, sec)) * 1000).rounded()) + 250
    }
    /// The server failed the session before it did anything: its capacity
    /// error ("thread pool exausted max_workers 100", 1 s after the socket
    /// opened — device, 2026-09-20 00:41, fine on the second try) or a drop
    /// before any reply. Not an error state: the screen reconnects quietly
    /// (`onTransportEnded` + `failedBeforeAnyReply`).
    private var _earlyFailure = false
    var failedBeforeAnyReply: Bool { withLock { _earlyFailure } }
    private var _openingCreates = 0
    /// Truncates sent this session (their event ids).
    private var _truncates = 0
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
    init(proxyURL: String, token: String,
         freshToken: (@Sendable (_ forceRefresh: Bool) async -> String?)? = nil,
         model: String, instructions: String, opening: String,
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
        self.freshToken = freshToken
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
        guard let url = dialURL else {
            transportEnded(error: "Bad voice proxy URL"); return
        }
        // Build the (lazy, not thread-safe) URLSession HERE, on the caller's
        // thread: with a token provider the dial runs later on another one,
        // and stop() touches the session too.
        _ = session
        // Nothing in URLSession fails a dial that stalls after the TCP connect,
        // so a proxy that accepts and never upgrades would hang "Connecting…"
        // for ever. 15 s, then we say so. Armed before the token wait so it
        // bounds that too. The one redial after a 401 gets 5 s more (audit
        // 2026-09-22, C14): it goes out only after a refused dial AND a forced
        // refresh (itself up to 5 s, AppModel.voiceTokenDeadline), so the
        // shared 15 s alone could run out mid-handshake on a slow link.
        let timeout = dialTimeout, grace = authRedialGrace
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard let self else { return }
            if self.withLock({ !self._open && !self._stopped && self._authRetried }) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            }
            let stuck = self.withLock { !self._open && !self._stopped }
            if stuck { self.transportEnded(error: "Couldn't reach the voice server. Check your connection and try again.") }
        }
        guard let freshToken else { dial(url, token: token); return }
        // Resolve the token at dial time (audit 2026-09-22, C14): the one this
        // client was built with may be hours expired (a call answered on the
        // lock screen of a suspended app), and must outlive the session (C15).
        let fallback = token
        Task { [weak self] in
            let fresh = await freshToken(false)
            self?.dial(url, token: fresh.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        }
        // onOpen() runs in the delegate's didOpenWithProtocol — only after the
        // handshake succeeds — so the mic/playback/"Listening" don't spin up on an
        // unreachable proxy or a rejected token. receiveLoop starts there too.
    }

    /// Strip any existing query, then add ?model= (matches the Android URL build).
    private var dialURL: URL? {
        let base = proxyURL.components(separatedBy: "?").first ?? proxyURL
        return URL(string: base + "?model=" + model)
    }

    /// Open the socket with `token` — unless stop() (or a reported failure)
    /// got there first, e.g. while the token was resolving.
    private func dial(_ url: URL, token: String) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let hook = dialOverride
        // ONE lock for the check AND the task: stop() sets `_stopped` under it
        // before it invalidates the session, so a task made here is always one
        // stop() cancels — a task made on an invalidated URLSession raises an
        // ObjC exception — and nothing is dialled (or reported) after stop().
        let (go, socket): (Bool, URLSessionWebSocketTask?) = withLock {
            if _stopped || _reportedError { return (false, nil) }
            _dialedToken = token
            if hook != nil { return (true, nil) }
            let t = session.webSocketTask(with: req)
            task = t
            return (true, t)
        }
        guard go else { return }
        voiceLog.notice("voice connect host=\(url.host ?? "nil", privacy: .public) model=\(self.model, privacy: .public) tokenLen=\(token.count, privacy: .public)")
        if let hook { hook(req); return }
        socket?.resume()
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
        handshakeEnded(status: status, error: error)
    }

    /// A 401 before the socket ever opened, not yet retried — the one case
    /// worth a forced refresh + redial.
    static func shouldRetryUnauthorized(status: Int, openedOnce: Bool, retried: Bool) -> Bool {
        status == 401 && !openedOnce && !retried
    }

    /// The connection ended with this HTTP `status` (-1 = none). Internal so
    /// tests can drive a rejection without a socket.
    func handshakeEnded(status: Int, error: (any Error)?) {
        // A pre-open 401 is a token the proxy refused — usually one that
        // expired while the app sat suspended, or a race with the refresh.
        // Force ONE refresh and redial before telling a signed-in user to sign
        // in again (audit 2026-09-22, C14). A 401 comes back before the proxy
        // reserves a slot or charges the daily session, so the redial is free.
        if let freshToken, let url = dialURL {
            let (retry, rejected): (Bool, String?) = withLock {
                guard Self.shouldRetryUnauthorized(status: status, openedOnce: _openedOnce, retried: _authRetried),
                      !_stopped, !_reportedError else { return (false, nil) }
                _authRetried = true
                task = nil
                return (true, _dialedToken)
            }
            if retry {
                voiceLog.notice("voice handshake 401 — refreshing the session once and redialling")
                Task { [weak self] in
                    let fresh = await freshToken(true)
                    guard let self else { return }
                    // The token the proxy just refused is no answer.
                    guard let fresh, !fresh.isEmpty, fresh != rejected else {
                        self.transportEnded(error: Self.sessionExpiredMessage); return
                    }
                    self.dial(url, token: fresh)
                }
                return
            }
        }
        // CFNetwork collapses every rejection into -1011 ("bad response from the
        // server"), which tells the user nothing. The status distinguishes an
        // expired token from the proxy's concurrent-session cap.
        let friendly: String?
        switch status {
        case 401: friendly = Self.sessionExpiredMessage
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
        // NEVER the event's own description: `.transcription` carries the
        // user's words, and a .public log line travels in any sysdiagnose a
        // tester sends us (audit 2026-09-21). Shape only.
        switch event {
        case .speechStarted, .speechStopped, .transcription, .interruptPressed, .gateOpen, .gateClose:
            voiceLog.notice("voice barge-in \(Self.describe(event), privacy: .public) → \(Self.describe(cmds), privacy: .public) [\(stateAfter, privacy: .public)]")
        default:
            if decisive { voiceLog.notice("voice barge-in \(Self.describe(event), privacy: .public) → \(Self.describe(cmds), privacy: .public) [\(stateAfter, privacy: .public)]") }
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
            case .truncatePlayback: return "truncate"
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

    /// An event's SHAPE for the log — never its payload. `.transcription`
    /// carries what the user said; only its length and finality are loggable.
    static func describe(_ e: BargeInEvent) -> String {
        switch e {
        case .transcription(let text, _, let final): return "transcription(chars: \(text.count), final: \(final))"
        case .assistantTranscript(let d): return "assistantTranscript(chars: \(d.count))"
        case .speechStarted: return "speechStarted"
        case .speechStopped: return "speechStopped"
        case .interruptPressed: return "interruptPressed"
        case .gateOpen: return "gateOpen"
        case .gateClose: return "gateClose"
        case .responseCreated: return "responseCreated"
        case .responseDone(_, let status): return "responseDone(\(status ?? "-"))"
        case .responseRateLimited(let ms): return "responseRateLimited(\(ms)ms)"
        case .playbackDrained: return "playbackDrained"
        case .audioDelta: return "audioDelta"
        case .tick: return "tick"
        case .benignActiveResponseError: return "benignActiveResponseError"
        case .routeChanged(let r): return "routeChanged(\(r))"
        case .pttDown: return "pttDown"
        case .pttUp: return "pttUp"
        }
    }

    /// What the USER is told when the provider fails. The raw text names the
    /// model and the organisation ("Rate limit reached for gpt-… in
    /// organization org-…"), which both reads as broken and contradicts the
    /// scope guardrail's "never reveal what model powers you" (audit
    /// 2026-09-21). The raw text stays in the device log only.
    static func friendlyError(code: String, message: String) -> String {
        let m = message.lowercased()
        if code == "rate_limit_exceeded" || m.contains("rate limit") || m.contains("quota") {
            return "The assistant is busy right now — give it a minute and ask again."
        }
        if m.contains("timeout") || m.contains("timed out") { return "That took too long — try again." }
        if m.contains("unauthorized") || m.contains("invalid_api_key") || m.contains("401") {
            return "Voice isn't available right now — we're on it."
        }
        if m.contains("safety") || m.contains("content") { return "I can't help with that one." }
        return "Something went wrong with the assistant — try again."
    }

    private func execute(_ cmds: [BargeInCommand]) {
        for c in cmds {
            switch c {
            case .duck: audio.setPlaybackGain(0.25)
            case .restore: audio.setPlaybackGain(1)
            case .flushPlayback: audio.flushPlayback()
            case .sendCancel: send(["type": "response.cancel"])
            case .truncatePlayback:
                // Read the playhead NOW — the .flushPlayback after this resets
                // it. Which item and how much of it: the engine's; whether to
                // send and the ms: AudioTruncation (Ahmad 2026-09-23).
                let heard = audio.playbackPosition()
                guard let cut = AudioTruncation.plan(heard) else {
                    voiceLog.notice("voice truncate skipped (heard \(heard?.playedFrames ?? -1, privacy: .public) of \(heard?.receivedFrames ?? -1, privacy: .public) frames)")
                    break
                }
                let n: Int = withLock { _truncates += 1; return _truncates }
                voiceLog.notice("voice truncate at \(cut.audioEndMs, privacy: .public) ms of \((heard?.receivedFrames ?? 0) * 1000 / AudioTruncation.sampleRate, privacy: .public) ms")
                send(cut.event(id: Self.truncateEventPrefix + String(n)))
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
            case .updateTurnDetection(let td):
                // ONLY the field that changed. Re-sending the whole session
                // re-uploads the instructions AND all 70 tool schemas, about
                // 11k tokens, and invalidates the cached prefix — on every
                // headset plug, unplug or CallKit speaker toggle, which is
                // common mid-call (audit 2026-09-21). A partial update is
                // supported on both paths: the proxy's enforceGuardrail
                // deliberately leaves the instructions alone when the update
                // doesn't carry them, and the OpenAI adapter maps whatever
                // fields are present.
                send(["type": "session.update", "session": ["turn_detection": TurnDetection.json(td)]])
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
                // The item id travels with the audio: a cut reply is truncated
                // by the item the user was HEARING (the proxy keeps GA's
                // item_id when it renames response.output_audio.delta).
                audio.enqueue(pcm, itemId: ev["item_id"] as? String)
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
                let details = response?["status_details"] as? [String: Any]
                let reason = (details?["reason"] as? String) ?? "-"
                voiceLog.notice("voice response.done status=\(status ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
                if status == nil || status == "completed" { checkFabrication() }
                else { withLock { _guard.responseCancelled() } }
                // A reply the server could not produce. Rate limit → the turn
                // is asked for again after the bucket's reset (the app used to
                // fall silent, 2026-09-20 23:48); anything else → told once.
                if status == "failed" {
                    let err = details?["error"] as? [String: Any]
                    let code = (err?["code"] as? String) ?? ""
                    let message = (err?["message"] as? String) ?? ""
                    if code == "rate_limit_exceeded" || message.lowercased().contains("rate limit") {
                        let ms = Self.retryAfterMs(message: message, tokenReset: withLock { _tokenResetSec })
                        let retries: Int = withLock { _bargeIn.rateLimitRetries }
                        voiceLog.notice("voice rate-limited: retry in \(ms, privacy: .public) ms (retry #\(retries + 1, privacy: .public))")
                        if retries + 1 > BargeInController.rateLimitMaxRetries {
                            onError(Self.friendlyError(code: code, message: message))
                        }
                        dispatch(.responseRateLimited(retryAfterMs: ms))
                        return
                    }
                    if !message.isEmpty { onError(Self.friendlyError(code: code, message: message)) }
                }
                // responseActive stays true until response.DONE (audio.done
                // can precede function calls): the UI stays "speaking" while
                // the buffered tail plays, then playback_drained → listening.
                dispatch(.responseDone(id: responseId, status: status))
            }
        case "rate_limits.updated":
            // OpenAI, after every response: what is left of the token bucket
            // and when it refills — the retry delay for a rate-limited reply.
            if let limits = ev["rate_limits"] as? [[String: Any]],
               let tokens = limits.first(where: { ($0["name"] as? String) == "tokens" }),
               let reset = tokens["reset_seconds"] as? Double {
                withLock { _tokenResetSec = reset }
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
            // A truncate the server refused (the item already gone, a backend
            // without the event) is best effort, not a broken session: the
            // reply was cut on the phone either way. OpenAI puts OUR event id
            // under error.event_id and its own at the top level — check both.
            let truncateRefused = [ev["event_id"], errObj?["event_id"]].contains { ($0 as? String)?.hasPrefix(Self.truncateEventPrefix) == true }
            if truncateRefused || (m?.contains("item.truncate") ?? false) {
                voiceLog.notice("voice truncate refused: \(String((m ?? "-").prefix(200)), privacy: .public)")
                return
            }
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
            if let m, !m.isEmpty {
                voiceLog.error("voice server error: \(String(m.prefix(200)), privacy: .public)")
                onError(Self.friendlyError(code: (errObj?["code"] as? String) ?? "", message: m))
            }
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
        send(["type": "response.create", "response": VoiceIntegrityGuard.correctiveResponse])
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
        if let hook = sendOverride { hook(str); return }
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
