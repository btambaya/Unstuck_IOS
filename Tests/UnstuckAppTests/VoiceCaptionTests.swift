// The Talk screen's caption line, driven from REAL server events through the
// real VoiceRealtimeClient.handle switch (no restatement of what it emits) and
// reduced by the real VoiceCaptionState.
//
// Two defects these pin down, both of which made the on-screen text wrong even
// when the audio was fine:
//
//  1. `conversation.item.input_audio_transcription.completed` — the ASR of what
//     the USER said — is a separate async job and routinely lands AFTER the
//     reply's first `response.audio_transcript.delta`s. The old sink cleared the
//     caption on every user event, so the reply lost its first word or two.
//  2. A turn with a tool call speaks in two segments; their deltas were
//     concatenated with no separator ("Let me check.You have three today.").

import AVFoundation
import XCTest
@testable import Unstuck

/// A VoiceAudioIO that records nothing and touches no AVAudioSession, so a
/// client can be built and driven without a socket, a mic, or a speaker.
private final class SilentAudioIO: VoiceAudioIO, @unchecked Sendable {
    var onGateChange: (@Sendable (_ open: Bool) -> Void)?
    var onPlaybackDrained: (@Sendable () -> Void)?
    func startPlayback() {}
    func startCapture(_ onFrame: @escaping @Sendable (Data) -> Void) {}
    func enqueue(_ pcm: Data) {}
    func flushPlayback() {}
    func setPlaybackGain(_ gain: Float) {}
    func setGateContext(_ ctx: GateContext) {}
    func recalibrateGate() {}
    func shutdown() {}
}

/// Collects the `onCaption` callbacks a client emits and reduces them exactly
/// as VoiceSessionModel does.
private final class CaptionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _state = VoiceCaptionState()
    private var _calls: [(role: String, text: String, done: Bool)] = []

    func apply(_ role: String, _ text: String, _ done: Bool) {
        lock.withLock {
            _calls.append((role, text, done))
            _state.apply(role: role, text: text, done: done)
        }
    }
    var state: VoiceCaptionState { lock.withLock { _state } }
    var caption: String { state.caption }
    var userTranscript: String { state.userTranscript }
    var calls: [(role: String, text: String, done: Bool)] { lock.withLock { _calls } }
}

final class VoiceCaptionTests: XCTestCase {

    // MARK: driving the real client

    private func client(_ sink: CaptionSink) -> VoiceRealtimeClient {
        VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { _ in },
            onCaption: { role, text, done in sink.apply(role, text, done) },
            onError: { _ in },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
    }

    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func created(_ id: String) -> String { json(["type": "response.created", "response": ["id": id]]) }
    private func delta(_ id: String, _ d: String) -> String {
        json(["type": "response.audio_transcript.delta", "response_id": id, "delta": d])
    }
    private func transcriptDone(_ id: String) -> String {
        json(["type": "response.audio_transcript.done", "response_id": id])
    }
    private func userSaid(_ t: String) -> String {
        json(["type": "conversation.item.input_audio_transcription.completed", "transcript": t])
    }
    private func responseDone(_ id: String) -> String {
        json(["type": "response.done", "response": ["id": id]])
    }

    // MARK: 1 — a late user ASR result must not eat the reply's first words

    func testTheUsersTranscriptArrivingMidReplyDoesNotEatItsFirstWords() {
        let sink = CaptionSink()
        let c = client(sink)
        // The real order on a device: the reply starts before the ASR lands.
        c.handle(created("r1"))
        c.handle(delta("r1", "You have "))
        c.handle(delta("r1", "three things "))
        c.handle(userSaid("what's on today"))          // ← the late ASR
        c.handle(delta("r1", "left today."))
        c.handle(transcriptDone("r1"))

        XCTAssertEqual(sink.caption, "You have three things left today.")
        // The client really did emit the user callback (the test is driving the
        // race, not skipping it).
        XCTAssertTrue(sink.calls.contains { $0.role == "user" && $0.text == "what's on today" })
    }

    func testTheUsersTranscriptStillClearsAFinishedReplyFromThePreviousTurn() {
        let sink = CaptionSink()
        let c = client(sink)
        c.handle(created("r1"))
        c.handle(delta("r1", "Three things left today."))
        c.handle(transcriptDone("r1"))
        c.handle(responseDone("r1"))
        XCTAssertEqual(sink.caption, "Three things left today.")
        // Next turn: the user speaks, the ASR lands before the new reply.
        c.handle(userSaid("move the dentist to friday"))
        XCTAssertEqual(sink.caption, "", "last turn's reply is stale once a new turn is transcribed")
        XCTAssertEqual(sink.userTranscript, "move the dentist to friday")
    }

    func testBargeInClearsTheLiveReplyEvenMidStream() {
        let sink = CaptionSink()
        let c = client(sink)
        c.handle(created("r1"))
        c.handle(delta("r1", "Here is the whole plan for"))
        XCTAssertEqual(sink.caption, "Here is the whole plan for")
        // BargeInCommand.clearCaption — an EMPTY user caption, "new turn".
        sink.apply("user", "", true)
        XCTAssertEqual(sink.caption, "", "a barge-in always wipes the line")
        XCTAssertFalse(sink.state.replyStreaming)
    }

    // MARK: 2 — successive segments keep a space between them

    func testTwoReplySegmentsInOneTurnAreSeparated() {
        let sink = CaptionSink()
        let c = client(sink)
        // Segment 1: narration before the tool call.
        c.handle(created("r1"))
        c.handle(delta("r1", "Let me check."))
        c.handle(transcriptDone("r1"))
        c.handle(responseDone("r1"))
        // Segment 2: the answer, after the tool result came back.
        c.handle(created("r2"))
        c.handle(delta("r2", "You have"))
        c.handle(delta("r2", " three today."))
        c.handle(transcriptDone("r2"))

        XCTAssertEqual(sink.caption, "Let me check. You have three today.")
        XCTAssertFalse(sink.caption.contains("check.You"), "segments must not run together")
    }

    func testASegmentBreakNeverDoublesAnExistingSpace() {
        var s = VoiceCaptionState()
        s.apply(role: "assistant", text: "Let me check. ", done: false)
        s.apply(role: "assistant", text: "", done: true)
        s.apply(role: "assistant", text: "You have three.", done: false)
        XCTAssertEqual(s.caption, "Let me check. You have three.")

        var t = VoiceCaptionState()
        t.apply(role: "assistant", text: "Let me check.", done: false)
        t.apply(role: "assistant", text: "", done: true)
        t.apply(role: "assistant", text: " You have three.", done: false)
        XCTAssertEqual(t.caption, "Let me check. You have three.")
    }

    func testDeltasInsideOneSegmentAreNeverSeparated() {
        let sink = CaptionSink()
        let c = client(sink)
        c.handle(created("r1"))
        for d in ["Mo", "ving ", "the den", "tist."] { c.handle(delta("r1", d)) }
        XCTAssertEqual(sink.caption, "Moving the dentist.")
    }

    // MARK: the whole turn, end to end

    func testAToolBackedTurnWithALateTranscriptReadsCorrectly() {
        let sink = CaptionSink()
        let c = client(sink)
        c.handle(created("r1"))
        c.handle(delta("r1", "Checking your week."))
        c.handle(userSaid("how does my week look"))    // late ASR, mid-segment
        c.handle(transcriptDone("r1"))
        c.handle(responseDone("r1"))
        c.handle(created("r2"))
        c.handle(delta("r2", "Tuesday is"))
        c.handle(delta("r2", " the busy one."))
        c.handle(transcriptDone("r2"))
        XCTAssertEqual(sink.caption, "Checking your week. Tuesday is the busy one.")
    }

    // MARK: the reducer's own contract

    func testResetClearsEverything() {
        var s = VoiceCaptionState()
        s.apply(role: "user", text: "hello", done: true)
        s.apply(role: "assistant", text: "Hi there.", done: false)
        XCTAssertFalse(s.caption.isEmpty)
        s.reset()
        XCTAssertEqual(s, VoiceCaptionState())
    }

    func testAnUnknownRoleIsIgnored() {
        var s = VoiceCaptionState()
        s.apply(role: "system", text: "nope", done: false)
        XCTAssertEqual(s, VoiceCaptionState())
    }
}

// MARK: - dead on arrival → reconnect, not an error

/// The server failed a session 1 s after the socket opened ("thread pool
/// exausted max_workers 100", device 2026-09-20 00:41) and the user saw
/// "Socket is not connected"; the second try was fine. A server error before
/// ANY reply is not surfaced — the screen reconnects quietly.
final class VoiceReconnectTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [String] = []
        private var _states: [VoiceState] = []
        func error(_ m: String) { lock.lock(); _errors.append(m); lock.unlock() }
        func state(_ s: VoiceState) { lock.lock(); _states.append(s); lock.unlock() }
        var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }
        var states: [VoiceState] { lock.lock(); defer { lock.unlock() }; return _states }
    }

    private func client(_ sink: Sink, hooked: Bool) -> VoiceRealtimeClient {
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { sink.state($0) },
            onCaption: { _, _, _ in },
            onError: { sink.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
        if hooked { c.onTransportEnded = { _ in } }
        return c
    }
    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private var capacityError: String {
        json(["type": "error", "error": ["code": "COMMON_ERROR", "message": "thread pool exausted max_workers 100"]])
    }

    func testAServerErrorBeforeAnyReplyIsSwallowedForTheReconnect() {
        let sink = Sink()
        let c = client(sink, hooked: true)
        c.handle(capacityError)
        XCTAssertTrue(c.failedBeforeAnyReply)
        XCTAssertEqual(sink.errors, [], "not the user's problem yet")
        XCTAssertFalse(sink.states.contains(.error))
    }

    func testTheSameErrorAfterAReplyStartedIsReported() {
        let sink = Sink()
        let c = client(sink, hooked: true)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(capacityError)
        XCTAssertFalse(c.failedBeforeAnyReply)
        // The USER gets plain words, never the provider's text: it names the
        // model and the organisation ("Rate limit reached for gpt-… in
        // organization org-…"), which reads as broken and contradicts the
        // scope guardrail's "never reveal what model powers you" (audit
        // 2026-09-21). The raw text goes to the device log instead.
        XCTAssertEqual(sink.errors, ["Something went wrong with the assistant — try again."])
        XCTAssertTrue(sink.states.contains(.error))
    }

    func testWithNoScreenToReconnectTheErrorIsReportedAtOnce() {
        let sink = Sink()
        let c = client(sink, hooked: false)
        c.handle(capacityError)
        XCTAssertFalse(c.failedBeforeAnyReply)
        XCTAssertEqual(sink.errors, ["Something went wrong with the assistant — try again."])
    }

    /// The mapping itself: the user never sees the model, the organisation or
    /// a stack of provider jargon, and a rate limit reads as "busy, try again"
    /// rather than as a bug (audit 2026-09-21).
    func testProviderErrorsAreMappedToPlainWords() {
        let rateLimited = VoiceRealtimeClient.friendlyError(
            code: "rate_limit_exceeded",
            message: "Rate limit reached for gpt-realtime-2.1-mini (for limit gpt-4o-mini-realtime) in organization org-KNkOJ3 on tokens per min (TPM): Limit 40000")
        XCTAssertEqual(rateLimited, "The assistant is busy right now — give it a minute and ask again.")
        for raw in [rateLimited,
                    VoiceRealtimeClient.friendlyError(code: "", message: "Request timed out."),
                    VoiceRealtimeClient.friendlyError(code: "", message: "invalid_api_key"),
                    VoiceRealtimeClient.friendlyError(code: "", message: "thread pool exausted max_workers 100")] {
            for leak in ["gpt", "org-", "openai", "qwen", "TPM", "api_key"] {
                XCTAssertFalse(raw.lowercased().contains(leak.lowercased()), "\(raw) leaks \(leak)")
            }
            XCTAssertFalse(raw.isEmpty)
        }
    }
}
