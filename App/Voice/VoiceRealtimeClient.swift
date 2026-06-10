// Realtime voice client for Qwen-Omni (via the Cloudflare proxy). Streams mic
// PCM16/16k up, plays the model's PCM16/24k speech back, surfaces live captions,
// and runs the agent's tool calls through the SAME dispatcher as text mode.
// 1:1 port of the Android VoiceRealtimeClient — the wire protocol is identical
// (verified against the live DashScope endpoint):
//
//   session.update {modalities, instructions, input/output_audio_format:pcm16,
//                   turn_detection:server_vad, tools, tool_choice}
//   client → input_audio_buffer.append {audio: base64}
//   server → response.audio.delta {delta: base64}           (24k speech)
//          → response.audio_transcript.delta {delta}          (captions)
//          → input_audio_buffer.speech_started                (→ barge-in)
//          → response.function_call_arguments.done {name, call_id, arguments}
//   client → conversation.item.create {function_call_output, call_id, output}
//          → response.create
//
// Transport is URLSessionWebSocketTask (Foundation). The audio engine is behind
// the VoiceAudioIO seam so this file compiles independently of the AVAudioEngine
// implementation (Phase 1).

import Foundation

/// The audio side the realtime client drives — implemented by VoiceAudioEngine
/// (Phase 1). Capture delivers 16 kHz mono PCM16 frames; playback consumes
/// 24 kHz mono PCM16. Kept as a protocol so the protocol client (Phase 0) and
/// the AVAudioEngine plumbing (Phase 1) build + test independently.
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

enum VoiceState: Sendable { case connecting, listening, speaking, error, closed }

/// `@unchecked Sendable`: the socket (URLSessionWebSocketTask) is thread-safe to
/// send on from any thread, and the few mutable flags are guarded by `lock`.
/// Mirrors the Android client's `@Volatile` flags + single OkHttp socket.
final class VoiceRealtimeClient: @unchecked Sendable {
    private let proxyURL: String          // wss://…workers.dev (token added as a header)
    private let token: String             // Supabase access token (the Worker validates it)
    private let model: String
    private let instructions: String      // system prompt + live context
    private let tools: [[String: Any]]    // tool schemas (OpenAI/DashScope shape)
    private let audio: VoiceAudioIO
    // Args are passed as the raw JSON STRING (Sendable) — `[String: Any]` can't
    // cross the Task boundary under Swift 6; the dispatcher parses it.
    private let runTool: @Sendable (_ name: String, _ argsJSON: String) async -> String
    private let onState: @Sendable (VoiceState) -> Void
    private let onCaption: @Sendable (_ role: String, _ text: String, _ done: Bool) -> Void
    private let onError: @Sendable (String) -> Void

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0   // long-lived socket
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var _open = false
    private var _stopped = false
    // After a manual interrupt we drop still-in-flight audio from the cancelled
    // response until the next turn begins (user speaks / a new response starts).
    private var _muted = false
    private func get(_ kp: () -> Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return kp() }

    init(proxyURL: String, token: String, model: String, instructions: String,
         tools: [[String: Any]], audio: VoiceAudioIO,
         runTool: @escaping @Sendable (_ name: String, _ argsJSON: String) async -> String,
         onState: @escaping @Sendable (VoiceState) -> Void,
         onCaption: @escaping @Sendable (_ role: String, _ text: String, _ done: Bool) -> Void,
         onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.proxyURL = proxyURL
        self.token = token
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.audio = audio
        self.runTool = runTool
        self.onState = onState
        self.onCaption = onCaption
        self.onError = onError
    }

    // MARK: lifecycle

    func start() {
        onState(.connecting)
        // Strip any existing query, then add ?model= (matches the Android URL build).
        let base = proxyURL.components(separatedBy: "?").first ?? proxyURL
        guard let url = URL(string: base + "?model=" + model) else {
            onError("Bad voice proxy URL"); onState(.error); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        onOpen()
        receiveLoop()
    }

    func stop() {
        lock.lock()
        if _stopped { lock.unlock(); return }
        _stopped = true; _open = false
        let socket = task
        task = nil
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
        audio.shutdown()
        onState(.closed)
    }

    /// Manual interrupt: cut playback now, tell the server to stop generating,
    /// and reopen the mic. Stale audio from the cancelled response is dropped
    /// until the next turn begins.
    func interrupt() {
        guard get({ _open }) else { return }
        lock.lock(); _muted = true; lock.unlock()
        audio.flushPlayback()
        send(["type": "response.cancel"])
        onState(.listening)
    }

    // MARK: socket

    private func onOpen() {
        lock.lock(); _open = true; lock.unlock()
        send(sessionUpdate())
        audio.startPlayback()
        audio.startCapture { [weak self] frame in
            guard let self, self.get({ self._open }) else { return }
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
                guard self.get({ self._open }) else { return }   // expected on stop()
                self.lock.lock(); self._open = false; self.lock.unlock()
                self.audio.shutdown()
                self.onError(String(err.localizedDescription.prefix(160)))
                self.onState(.error)
            case .success(let message):
                if case let .string(text) = message { self.handle(text) }
                // (binary frames aren't used by this protocol)
                if self.get({ self._open }) { self.receiveLoop() }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = ev["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            lock.lock(); _muted = false; lock.unlock()
            audio.flushPlayback(); onState(.listening)
        case "response.created":
            lock.lock(); _muted = false; lock.unlock()
        case "response.audio.delta":
            if get({ _muted }) { return }   // stale audio from a cancelled response
            if let b64 = ev["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                audio.enqueue(pcm); onState(.speaking)
            }
        case "response.audio_transcript.delta":
            if let d = ev["delta"] as? String { onCaption("assistant", d, false) }
        case "response.audio_transcript.done":
            onCaption("assistant", "", true)
        case "conversation.item.input_audio_transcription.completed":
            if let t = ev["transcript"] as? String { onCaption("user", t, true) }
        case "response.audio.done", "response.done":
            onState(.listening)
        case "response.function_call_arguments.done":
            handleToolCall(ev)
        case "error":
            let m = (ev["error"] as? [String: Any])?["message"] as? String ?? (ev["error"] as? String)
            if let m, !m.isEmpty { onError(String(m.prefix(160))) }
            onState(.error)
        default:
            break
        }
    }

    private func handleToolCall(_ ev: [String: Any]) {
        guard let name = ev["name"] as? String, let callId = ev["call_id"] as? String else { return }
        let argsJSON = (ev["arguments"] as? String) ?? "{}"
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runTool(name, argsJSON)
            // Feed the tool result back + ask the model to continue (speak).
            self.send(["type": "conversation.item.create",
                       "item": ["type": "function_call_output", "call_id": callId, "output": result]])
            self.send(["type": "response.create"])
        }
    }

    // MARK: send helpers

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { _ in }   // best-effort; failures surface via receiveLoop
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
