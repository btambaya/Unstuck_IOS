// Realtime voice client for Qwen-Omni (via the Cloudflare proxy). Streams mic
// PCM16/16k up, plays the model's PCM16/24k speech back, surfaces live captions,
// and runs the agent's tool calls through the SAME executor as text mode.
// 1:1 port of the web lib/voice/realtime-client.ts (which is itself the
// Android client) — the wire protocol is identical:
//
//   session.update {modalities, instructions, input/output_audio_format:pcm16,
//                   turn_detection:server_vad, tools, tool_choice}
//   client → conversation.item.create {PRIMER}  + response.create   (opening)
//   client → input_audio_buffer.append {audio: base64}
//   server → response.audio.delta {delta: base64}           (24k speech)
//          → response.audio_transcript.delta {delta}          (captions)
//          → input_audio_buffer.speech_started                (→ barge-in)
//          → response.function_call_arguments.done {name, call_id, arguments}
//          → response.output_item.done {item: function_call}  (same, other shape)
//   client → conversation.item.create {function_call_output, call_id, output}
//          → response.create (coalesced)
//   client → conversation.item.delete {PRIMER}  on the first response.done
//
// Plus the voice integrity guard: a spoken "I've added it" with no tool call
// behind it in that response gets one hidden corrective (3 per session).
//
// Transport is URLSessionWebSocketTask (Foundation). The audio engine is behind
// the VoiceAudioIO seam so this file compiles independently of the AVAudioEngine
// implementation.
//
// LOCKING: every touch of the mutable flags goes through `withLock` (NSLock's
// scoped `withLock` is async-safe; its bare lock()/unlock() are `noasync`
// under Swift 6, and the tool-result path runs inside a Task).

import Foundation
import UnstuckCore

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
    mutating func toolDispatched(_ name: String) { if !READ_ONLY_TOOLS.contains(name) { toolCalled = true } }
    mutating func toolFinished(_ name: String, result: String) {
        nextResponseToolBacked = !result.hasPrefix("error") && !READ_ONLY_TOOLS.contains(name)
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
    private let audio: VoiceAudioIO
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
        cfg.timeoutIntervalForRequest = 0   // long-lived socket
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var _open = false
    private var _stopped = false
    // After a barge-in / manual interrupt we drop still-in-flight audio from the
    // cancelled response until the next response starts (response.created).
    private var _muted = false
    /// The user muted the MIC (CallKit's mute button → the launcher): captured
    /// frames are dropped before upload, so the server VAD hears silence.
    private var _micMuted = false
    // Whether a model response is currently being generated. Guards
    // response.cancel so we never cancel when nothing is active — DashScope
    // rejects that with "Conversation has no active response".
    private var _responseActive = false
    // Guards against double error-reporting from the receive loop AND the
    // didCompleteWithError delegate for the same failed connection.
    private var _reportedError = false
    private var _primerDeleted = false
    private var _guard = VoiceIntegrityGuard()
    /// Both event shapes can carry the same call — dispatch once.
    private var _handledCalls = Set<String>()
    /// One coalesced response.create after tool outputs — a response.create per
    /// parallel call races "already has an active response" errors.
    private var _continueTask: Task<Void, Never>?

    /// Synchronous scoped locking — the ONLY way the flags are touched.
    /// Callable from async contexts (NSLock's bare lock()/unlock() are not).
    private func withLock<T>(_ body: () -> T) -> T { lock.withLock(body) }

    init(proxyURL: String, token: String, model: String, instructions: String, opening: String,
         tools: [[String: Any]], audio: VoiceAudioIO,
         runTool: @escaping @Sendable (_ name: String, _ argsJSON: String) async -> String,
         onState: @escaping @Sendable (VoiceState) -> Void,
         onCaption: @escaping @Sendable (_ role: String, _ text: String, _ done: Bool) -> Void,
         onError: @escaping @Sendable (String) -> Void) {
        self.proxyURL = proxyURL
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
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        // onOpen() runs in the delegate's didOpenWithProtocol — only after the
        // handshake succeeds — so the mic/playback/"Listening" don't spin up on an
        // unreachable proxy or a rejected token. receiveLoop starts there too.
    }

    // URLSessionWebSocketDelegate: the socket finished its upgrade handshake.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen()
        receiveLoop()
    }

    // The connection ended/failed (incl. a pre-handshake failure — unreachable
    // proxy, rejected token — where didOpen never fires and receiveLoop never
    // started). Ignore the invalidation we trigger ourselves on stop(). A clean
    // remote close (no error) ends the session as `.closed` rather than leaving
    // a dead socket behind a live "Listening…".
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        transportEnded(error: error.map { String($0.localizedDescription.prefix(160)) })
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
        audio.shutdown()
        onState(.closed)
    }

    /// Manual interrupt: cut playback now, tell the server to stop generating,
    /// and reopen the mic. Stale audio from the cancelled response is dropped
    /// until the next response begins. A cancelled reply is never scored as a claim.
    func interrupt() {
        guard withLock({ _open }) else { return }
        let active: Bool = withLock { _muted = true; _guard.bargeIn(); return _responseActive }
        audio.flushPlayback()
        // Only cancel when a response is actually generating — cancelling with
        // nothing active makes DashScope error "Conversation has no active response".
        if active { send(["type": "response.cancel"]) }
        onState(.listening)
    }

    /// Mute/unmute the mic upload (CallKit's mute button → the launcher). The
    /// capture graph keeps running (hardware AEC stays primed); frames are
    /// dropped before they reach the socket.
    func setMicMuted(_ muted: Bool) {
        withLock { _micMuted = muted }
    }

    // MARK: socket

    private func onOpen() {
        withLock { _open = true }
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
        audio.startPlayback()
        audio.startCapture { [weak self] frame in
            guard let self, self.withLock({ self._open && !self._micMuted }) else { return }
            self.send(["type": "input_audio_buffer.append",
                       "audio": frame.base64EncodedString()])
        }
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
        let first: Bool = withLock {
            if _stopped || _reportedError { return false }   // our own invalidate / already reported
            _open = false; _reportedError = true
            return true
        }
        guard first else { return }
        audio.shutdown()
        if let error {
            onError(error)
            onState(.error)
        } else {
            onState(.closed)
        }
        onTransportEnded?(error)
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = ev["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            // Barge-in: MUTE until the next response starts — the cancelled
            // reply's in-flight audio deltas kept arriving and played over the
            // user. response.created flips muted back off for the new reply.
            withLock { _muted = true; _guard.bargeIn() }
            audio.flushPlayback(); onState(.listening)
        case "response.created":
            withLock { _muted = false; _responseActive = true; _guard.responseCreated() }
            // The model heard the user and is reasoning — surface a distinct
            // "Thinking" state until the first audio delta.
            onState(.thinking)
        case "response.audio.delta":
            if withLock({ _muted }) { return }   // stale audio from a cancelled response
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                audio.enqueue(pcm); onState(.speaking)
            }
        case "response.audio_transcript.delta":
            if let d = ev["delta"] as? String {
                withLock { _guard.transcriptDelta(d) }
                onCaption("assistant", d, false)
            }
        case "response.audio_transcript.done":
            onCaption("assistant", "", true)
        case "conversation.item.input_audio_transcription.completed":
            if let t = ev["transcript"] as? String { onCaption("user", t, true) }
        case "response.audio.done", "response.done":
            // First response finished → the opening primer has served its
            // purpose; remove it so it can never be re-executed after an
            // interruption. Best effort: a backend without item.delete just
            // leaves it (the primer text also says "once only").
            let deletePrimer: Bool = withLock {
                _responseActive = false
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
                let status = (ev["response"] as? [String: Any])?["status"] as? String
                if status == nil || status == "completed" { checkFabrication() }
                else { withLock { _guard.responseCancelled() } }
            }
            onState(.listening)
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
            // Benign realtime-protocol hiccups — cancelling/creating a response
            // that is (or isn't) active — are NON-fatal; Android tolerates them.
            if let m, m.lowercased().contains("active response") {
                withLock { _responseActive = false }
                onState(.listening); return
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
                "turn_detection": ["type": "server_vad"],
                "tools": tools,
                "tool_choice": "auto",
            ],
        ]
    }
}
