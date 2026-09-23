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
import UnstuckCore
@testable import Unstuck

/// A VoiceAudioIO that records nothing and touches no AVAudioSession, so a
/// client can be built and driven without a socket, a mic, or a speaker.
private final class SilentAudioIO: VoiceAudioIO, @unchecked Sendable {
    var onGateChange: (@Sendable (_ open: Bool) -> Void)?
    var onPlaybackDrained: (@Sendable () -> Void)?
    func startPlayback() {}
    func startCapture(_ onFrame: @escaping @Sendable (Data) -> Void) {}
    func enqueue(_ pcm: Data, itemId: String?) {}
    func playbackPosition() -> PlaybackPosition? { nil }
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

// MARK: - the dial's token (audit 2026-09-22, C14)

/// A call answered on the lock screen of an app suspended overnight dialled
/// with the token cached at the last foreground (the SDK refreshes only while
/// ACTIVE); the proxy's 401 hung it up and told a signed-in user to sign in
/// again. The client now resolves the token at dial time and, on a 401 before
/// the socket ever opened, forces ONE refresh and redials.
final class VoiceDialTokenTests: XCTestCase {
    /// What the client did: each dial's Authorization header, errors, and
    /// transport ends.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _dials: [String] = []
        private var _errors: [String] = []
        private var _ended: [String?] = []
        func dial(_ auth: String) { lock.withLock { _dials.append(auth) } }
        func error(_ m: String) { lock.withLock { _errors.append(m) } }
        func ended(_ e: String?) { lock.withLock { _ended.append(e) } }
        var dials: [String] { lock.withLock { _dials } }
        var errors: [String] { lock.withLock { _errors } }
        var ended: [String?] { lock.withLock { _ended } }
    }

    /// The fresh-token provider: `normal` for a dial, `forced` after a 401;
    /// records every ask (its forceRefresh flag).
    private final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private var _asks: [Bool] = []
        private let normal: String?
        private let forced: String?
        private let delayNs: UInt64
        private let forcedDelayNs: UInt64
        /// `forcedDelayNs` defaults to `delayNs`.
        init(normal: String?, forced: String? = nil, delayNs: UInt64 = 0, forcedDelayNs: UInt64? = nil) {
            self.normal = normal; self.forced = forced; self.delayNs = delayNs
            self.forcedDelayNs = forcedDelayNs ?? delayNs
        }
        func token(_ force: Bool) async -> String? {
            lock.withLock { _asks.append(force) }
            let delay = force ? forcedDelayNs : delayNs
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return force ? forced : normal
        }
        var asks: [Bool] { lock.withLock { _asks } }
    }

    private func client(_ rec: Recorder, _ provider: Provider?) -> VoiceRealtimeClient {
        var fresh: (@Sendable (Bool) async -> String?)?
        if let provider { fresh = { force in await provider.token(force) } }
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "cached", freshToken: fresh, model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { _ in },
            onCaption: { _, _, _ in },
            onError: { rec.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
        c.dialOverride = { req in rec.dial(req.value(forHTTPHeaderField: "Authorization") ?? "") }
        c.onTransportEnded = { rec.ended($0) }
        return c
    }

    /// Polls `cond` (the dial runs on a Task) — true once it holds.
    private func eventually(tries: Int = 200, _ cond: @escaping () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    func testTheDialSendsTheFreshTokenNotTheCachedOne() async {
        let rec = Recorder(), p = Provider(normal: "fresh")
        let c = client(rec, p)
        c.start()
        let dialled = await eventually { rec.dials.count == 1 }
        XCTAssertTrue(dialled)
        XCTAssertEqual(rec.dials, ["Bearer fresh"])
        XCTAssertEqual(p.asks, [false])
        c.stop()
    }

    func testNoFreshTokenFallsBackToTheCachedOne() async {
        let rec = Recorder(), p = Provider(normal: nil)
        let c = client(rec, p)
        c.start()
        let dialled = await eventually { rec.dials.count == 1 }
        XCTAssertTrue(dialled)
        XCTAssertEqual(rec.dials, ["Bearer cached"])
        c.stop()
    }

    func testWithNoProviderTheDialIsImmediateWithTheCachedToken() {
        let rec = Recorder()
        let c = client(rec, nil)
        c.start()
        XCTAssertEqual(rec.dials, ["Bearer cached"], "the legacy path is unchanged")
        c.stop()
    }

    func testA401BeforeOpenRefreshesOnceAndRedials() async {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-2")
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        let redialled = await eventually { rec.dials.count == 2 }
        XCTAssertTrue(redialled)
        XCTAssertEqual(rec.dials, ["Bearer fresh-1", "Bearer fresh-2"])
        XCTAssertEqual(p.asks, [false, true])
        XCTAssertEqual(rec.errors, [], "a signed-in user is not told to sign in again")
        XCTAssertEqual(rec.ended.count, 0, "the call is not hung up")
        c.stop()
    }

    func testASecond401TellsTheUserToSignInAgain() async {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-2")
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        _ = await eventually { rec.dials.count == 2 }
        c.handshakeEnded(status: 401, error: nil)
        let reported = await eventually { !rec.errors.isEmpty }
        XCTAssertTrue(reported)
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.sessionExpiredMessage])
        XCTAssertEqual(rec.ended, [VoiceRealtimeClient.sessionExpiredMessage])
        XCTAssertEqual(p.asks, [false, true], "one forced refresh, never a loop")
        XCTAssertEqual(rec.dials.count, 2)
        c.stop()
    }

    func testAFailedForcedRefreshEndsWithoutRedialling() async {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: nil)
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        let reported = await eventually { !rec.errors.isEmpty }
        XCTAssertTrue(reported)
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.sessionExpiredMessage])
        XCTAssertEqual(rec.dials, ["Bearer fresh-1"], "no second dial with the refused token")
        c.stop()
    }

    func testAForcedRefreshHandingBackTheRefusedTokenIsNoAnswer() async {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-1")
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        let reported = await eventually { !rec.errors.isEmpty }
        XCTAssertTrue(reported)
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.sessionExpiredMessage])
        XCTAssertEqual(rec.dials.count, 1)
        c.stop()
    }

    func testWithNoProviderA401IsReportedAtOnce() {
        let rec = Recorder()
        let c = client(rec, nil)
        c.start()
        c.handshakeEnded(status: 401, error: nil)
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.sessionExpiredMessage])
        XCTAssertEqual(rec.ended.count, 1)
        XCTAssertEqual(rec.dials.count, 1)
        c.stop()
    }

    func testOtherRejectionsAreNotRetried() async {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-2")
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 429, error: nil)
        // Both of the proxy's 429s — its concurrent-session cap and its daily
        // cap — in plain words, never "already running" alone (C47).
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.voiceLimitMessage])
        XCTAssertEqual(p.asks, [false], "no forced refresh for a busy proxy")
        XCTAssertEqual(rec.dials.count, 1)
        c.stop()
    }

    /// The launcher's END CONTRACT: nothing after stop(), even while the
    /// token is still resolving.
    func testStopWhileTheTokenResolvesNeverDials() async throws {
        let rec = Recorder(), p = Provider(normal: "fresh", delayNs: 300_000_000)
        let c = client(rec, p)
        c.start()
        c.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(p.asks, [false])
        XCTAssertEqual(rec.dials, [])
        XCTAssertEqual(rec.errors, [])
        XCTAssertEqual(rec.ended.count, 0)
    }

    func testStopDuringTheForcedRefreshNeverRedials() async throws {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-2", delayNs: 300_000_000)
        let c = client(rec, p)
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        c.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(rec.dials.count, 1)
        XCTAssertEqual(rec.errors, [])
        XCTAssertEqual(rec.ended.count, 0)
    }

    // The dial watchdog (audit 2026-09-22, C14): it bounds the token wait and
    // the forced refresh too, and the one redial after a 401 gets its grace.

    private static let unreachable = "Couldn't reach the voice server. Check your connection and try again."

    func testAStalledTokenWaitEndsOnceAndItsLateTokenIsNeverDialled() async throws {
        let rec = Recorder(), p = Provider(normal: "fresh", delayNs: 800_000_000)
        let c = client(rec, p)
        c.dialTimeout = 0.2
        c.authRedialGrace = 30   // no 401, so no grace: the end must come at dialTimeout
        c.start()
        let ended = await eventually { !rec.ended.isEmpty }
        XCTAssertTrue(ended)
        try await Task.sleep(nanoseconds: 1_000_000_000)   // the provider answers meanwhile
        XCTAssertEqual(rec.ended, [Self.unreachable])
        XCTAssertEqual(rec.errors, [Self.unreachable])
        XCTAssertEqual(rec.dials, [], "nothing is dialled once the dial was given up")
        c.stop()
    }

    /// Before the grace, a redial that went out late in the shared window
    /// (after a refused dial and a forced refresh) was given up mid-handshake.
    func testTheRedialAfterA401IsNotCutAtTheDialTimeout() async throws {
        let rec = Recorder(), p = Provider(normal: "fresh-1", forced: "fresh-2")
        let c = client(rec, p)
        c.dialTimeout = 0.3
        c.authRedialGrace = 2
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        _ = await eventually { rec.dials.count == 2 }
        try await Task.sleep(nanoseconds: 900_000_000)   // well past dialTimeout
        XCTAssertEqual(rec.ended.count, 0, "the redial is still inside its grace")
        // It never opens here, so the watchdog ends it — once — at dialTimeout + grace.
        let ended = await eventually(tries: 500) { !rec.ended.isEmpty }
        XCTAssertTrue(ended)
        XCTAssertEqual(rec.ended, [Self.unreachable])
        XCTAssertEqual(rec.dials, ["Bearer fresh-1", "Bearer fresh-2"])
        c.stop()
    }

    func testAStalledForcedRefreshIsBoundedAndItsLateTokenIsNeverDialled() async throws {
        let rec = Recorder()
        let p = Provider(normal: "fresh-1", forced: "fresh-2", forcedDelayNs: 1_200_000_000)
        let c = client(rec, p)
        c.dialTimeout = 0.2
        c.authRedialGrace = 0.3
        c.start()
        _ = await eventually { rec.dials.count == 1 }
        c.handshakeEnded(status: 401, error: nil)
        let ended = await eventually { !rec.ended.isEmpty }
        XCTAssertTrue(ended)
        try await Task.sleep(nanoseconds: 1_300_000_000)   // the forced refresh answers meanwhile
        XCTAssertEqual(rec.ended, [Self.unreachable])
        XCTAssertEqual(rec.errors, [Self.unreachable])
        XCTAssertEqual(rec.dials, ["Bearer fresh-1"], "no redial after the dial was given up")
        XCTAssertEqual(p.asks, [false, true])
        c.stop()
    }

    func testOnlyAPreOpen401IsRetriedAndOnlyOnce() {
        XCTAssertTrue(VoiceRealtimeClient.shouldRetryUnauthorized(status: 401, openedOnce: false, retried: false))
        XCTAssertFalse(VoiceRealtimeClient.shouldRetryUnauthorized(status: 401, openedOnce: false, retried: true))
        XCTAssertFalse(VoiceRealtimeClient.shouldRetryUnauthorized(status: 401, openedOnce: true, retried: false))
        for status in [-1, 101, 403, 429, 500] {
            XCTAssertFalse(VoiceRealtimeClient.shouldRetryUnauthorized(status: status, openedOnce: false, retried: false))
        }
    }

    /// AppModel's fallback: the stream-cached token stands in when the fresh
    /// read fails (an unsigned build's keychain) — but never after a FORCED
    /// refresh, which follows the proxy refusing exactly that token.
    func testTheCachedTokenIsNeverTheAnswerToAForcedRefresh() {
        XCTAssertEqual(AppModel.voiceDialToken(fresh: "f", cached: "c", forceRefresh: false), "f")
        XCTAssertEqual(AppModel.voiceDialToken(fresh: "f", cached: "c", forceRefresh: true), "f")
        XCTAssertEqual(AppModel.voiceDialToken(fresh: nil, cached: "c", forceRefresh: false), "c")
        XCTAssertEqual(AppModel.voiceDialToken(fresh: "", cached: "c", forceRefresh: false), "c")
        XCTAssertNil(AppModel.voiceDialToken(fresh: nil, cached: "c", forceRefresh: true))
        XCTAssertNil(AppModel.voiceDialToken(fresh: nil, cached: nil, forceRefresh: false))
        XCTAssertNil(AppModel.voiceDialToken(fresh: nil, cached: "", forceRefresh: false))
    }

    /// The proxy hard-closes a session at 15 min and keeps using the
    /// connect-time token until then (voice-proxy MAX_SESSION_MS, C15).
    @MainActor
    func testADialledTokenOutlivesTheProxysSessionCap() {
        let minValidity = AppModel.voiceTokenMinValidity
        let deadline = AppModel.voiceTokenDeadline
        let topUp = AppModel.voiceTokenTopUpDeadline
        XCTAssertGreaterThan(minValidity, 15 * 60)
        XCTAssertLessThan(topUp, deadline)
        XCTAssertLessThan(deadline, 15, "inside the client's dial watchdog")
    }
}

// MARK: - Truncating a reply cut on air (Ahmad 2026-09-23)
//
// Zubair's voice session 2026-09-23 05:05:56–05:06:17 (assistant_turns): he
// talked over "Ah, good question. I can nudge you in a couple of ways…" after
// it had finished generating, said "Carry on", and got a new topic — the
// server still held the WHOLE reply. Driven through the real client, the
// real PlaybackLedger and the real frames it sends.

/// A VoiceAudioIO whose playhead the test moves: buffers go through the REAL
/// PlaybackLedger, so a barge-in's truncate is computed as on the phone.
private final class ScriptedPlayheadAudioIO: VoiceAudioIO, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = PlaybackLedger()
    private var _playhead = 0
    var onGateChange: (@Sendable (_ open: Bool) -> Void)?
    var onPlaybackDrained: (@Sendable () -> Void)?
    /// The player's timeline (frames at 24 kHz), as heard.
    var playhead: Int {
        get { lock.withLock { _playhead } }
        set { lock.withLock { _playhead = newValue } }
    }
    func startPlayback() {}
    func startCapture(_ onFrame: @escaping @Sendable (Data) -> Void) {}
    func enqueue(_ pcm: Data, itemId: String?) {
        lock.withLock { ledger.scheduled(itemId: itemId, frames: pcm.count / 2, playhead: _playhead) }
    }
    func playbackPosition() -> PlaybackPosition? { lock.withLock { ledger.position(at: _playhead) } }
    /// stop() + play(): a new timeline, as in VoiceAudioEngine.
    func flushPlayback() { lock.withLock { ledger.reset(); _playhead = 0 } }
    func setPlaybackGain(_ gain: Float) {}
    func setGateContext(_ ctx: GateContext) {}
    func recalibrateGate() {}
    func shutdown() {}
}

/// Every frame the client sends, and every error / state it reports.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [[String: Any]] = []
    private var _errors: [String] = []
    private var _states: [VoiceState] = []
    func sent(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        lock.withLock { _frames.append(obj) }
    }
    func error(_ m: String) { lock.withLock { _errors.append(m) } }
    func state(_ s: VoiceState) { lock.withLock { _states.append(s) } }
    var types: [String] { lock.withLock { _frames.compactMap { $0["type"] as? String } } }
    var frames: [[String: Any]] { lock.withLock { _frames } }
    var truncates: [[String: Any]] { lock.withLock { _frames.filter { $0["type"] as? String == "conversation.item.truncate" } } }
    var errors: [String] { lock.withLock { _errors } }
    var states: [VoiceState] { lock.withLock { _states } }
}

final class VoiceTruncateTests: XCTestCase {

    private func client(_ audio: VoiceAudioIO, _ wire: Wire) -> VoiceRealtimeClient {
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: audio,
            runTool: { _, _ in "ok" },
            onState: { wire.state($0) },
            onCaption: { _, _, _ in },
            onError: { wire.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
        c.sendOverride = { wire.sent($0) }
        return c
    }

    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    /// `frames` of 24 kHz PCM16 for `item` — the GA response.output_audio.delta
    /// as the proxy relays it (renamed, item_id kept).
    private func audio(_ response: String, _ item: String, frames: Int) -> String {
        json(["type": "response.audio.delta", "response_id": response, "item_id": item,
              "output_index": 0, "content_index": 0, "delta": Data(count: frames * 2).base64EncodedString()])
    }
    private func words(_ response: String, _ text: String) -> String {
        json(["type": "response.audio_transcript.delta", "response_id": response, "delta": text])
    }
    private func speechStarted(_ item: String) -> String { json(["type": "input_audio_buffer.speech_started", "item_id": item]) }
    /// OpenAI's live transcription delta shape.
    private func hearing(_ item: String, _ text: String) -> String {
        json(["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "delta": text])
    }

    func testZubairsTalkOverTruncatesTheItemHeHeardAtWhereHeStopped_thenTheNextRepliesItem() {
        let io = ScriptedPlayheadAudioIO(), wire = Wire()
        let c = client(io, wire)
        // Reply 1 arrives whole (2 s of audio) and finishes generating.
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(audio("r1", "item_A", frames: 24_000))
        c.handle(audio("r1", "item_A", frames: 24_000))
        c.handle(words("r1", "Ah, good question. I can nudge you in a couple of ways."))
        c.handle(json(["type": "response.done", "response": ["id": "r1", "status": "completed"]]))
        // 1.5 s of it heard, then he talks over it.
        io.playhead = 36_000
        c.handle(speechStarted("item_u"))
        c.handle(hearing("item_u", "Wait, so how does"))
        XCTAssertFalse(wire.types.contains("response.cancel"), "nothing was generating — only playback was cut")
        XCTAssertEqual(wire.truncates.count, 1)
        let first = wire.truncates[0]
        XCTAssertEqual(first["item_id"] as? String, "item_A")
        XCTAssertEqual(first["content_index"] as? Int, 0)
        XCTAssertEqual(first["audio_end_ms"] as? Int, 1500, "what he HEARD, not the 2000 ms received")
        XCTAssertEqual((first["event_id"] as? String)?.hasPrefix(VoiceRealtimeClient.truncateEventPrefix), true)

        // Reply 2 — a new item on a new timeline — is cut 250 ms in while
        // still generating: cancelled, then truncated by ITS item.
        c.handle(json(["type": "response.created", "response": ["id": "r2"]]))
        c.handle(audio("r2", "item_B", frames: 24_000))
        io.playhead = 6_000
        c.handle(speechStarted("item_v"))
        c.handle(hearing("item_v", "Actually tell me tomorrow instead"))
        XCTAssertEqual(wire.truncates.count, 2)
        XCTAssertEqual(wire.truncates[1]["item_id"] as? String, "item_B")
        XCTAssertEqual(wire.truncates[1]["audio_end_ms"] as? Int, 250)
        let types = wire.types
        let cancel = types.lastIndex(of: "response.cancel"), truncate = types.lastIndex(of: "conversation.item.truncate")
        XCTAssertNotNil(cancel)
        XCTAssertLessThan(cancel!, truncate!, "cancel, then truncate (the reference client's order)")
        XCTAssertNotEqual(wire.truncates[0]["event_id"] as? String, wire.truncates[1]["event_id"] as? String)
    }

    func testAReplyNotYetHeardIsCancelledButNotTruncated() {
        let io = ScriptedPlayheadAudioIO(), wire = Wire()
        let c = client(io, wire)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(words("r1", "Here is the plan for today."))
        c.handle(audio("r1", "item_A", frames: 24_000))
        io.playhead = 0   // on air, but not a frame of it heard yet
        c.handle(speechStarted("item_u"))
        c.handle(hearing("item_u", "Wait, what about Friday"))
        XCTAssertTrue(wire.types.contains("response.cancel"))
        XCTAssertEqual(wire.truncates.count, 0, "nothing of it was heard")
    }

    func testAReplyStillGeneratingIsTruncatedAtWhatArrived_evenWhenAllOfThatWasHeard() {
        // Review, 2026-09-23: the server's copy of a reply still generating
        // runs past what reached the phone. Heard to the end of what arrived
        // is not heard to its end.
        let io = ScriptedPlayheadAudioIO(), wire = Wire()
        let c = client(io, wire)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(words("r1", "Here's your week. Monday you have the dentist, then"))
        c.handle(audio("r1", "item_A", frames: 24_000))
        io.playhead = 30_000   // the 1 s that arrived was heard; the rest is on its way
        c.handle(speechStarted("item_u"))
        c.handle(hearing("item_u", "Wait, what about Friday"))
        XCTAssertTrue(wire.types.contains("response.cancel"))
        XCTAssertEqual(wire.truncates.count, 1)
        XCTAssertEqual(wire.truncates.first?["item_id"] as? String, "item_A")
        XCTAssertEqual(wire.truncates.first?["audio_end_ms"] as? Int, 1000, "what arrived and was heard — never past it")
    }

    func testAFinishedReplyHeardToItsEndIsNotTruncated() {
        let io = ScriptedPlayheadAudioIO(), wire = Wire()
        let c = client(io, wire)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(words("r1", "Here is the plan for today."))
        c.handle(audio("r1", "item_A", frames: 24_000))
        c.handle(json(["type": "response.done", "response": ["id": "r1", "status": "completed"]]))
        io.playhead = 30_000   // heard whole; its drain not reported yet
        c.handle(speechStarted("item_u"))
        c.handle(hearing("item_u", "Wait, what about Friday"))
        XCTAssertEqual(wire.truncates.count, 0, "nothing of it was unheard")
    }

    func testARefusedTruncateIsNotASessionError() {
        let wire = Wire()
        let c = client(ScriptedPlayheadAudioIO(), wire)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        // OpenAI: our event id under error.event_id, its own at the top.
        c.handle(json(["type": "error", "event_id": "event_srv_1",
                       "error": ["type": "invalid_request_error", "code": "invalid_value",
                                 "message": "Audio content of 262ms is already shorter than 1500ms",
                                 "event_id": VoiceRealtimeClient.truncateEventPrefix + "1"]]))
        // A backend without the event names it.
        c.handle(json(["type": "error", "error": ["message": "Unsupported event type: conversation.item.truncate"]]))
        XCTAssertEqual(wire.errors, [])
        XCTAssertFalse(wire.states.contains(.error))
        // Any other error still surfaces.
        c.handle(json(["type": "error", "error": ["message": "Something else broke"]]))
        XCTAssertEqual(wire.errors.count, 1)
        XCTAssertTrue(wire.states.contains(.error))
    }
}

// MARK: - the proxy's limits, in plain words (audit 2026-09-22, C47)

/// The proxy refuses with 429 (its concurrent-session cap AND its daily cap)
/// and ends a live session with 1008 "daily voice limit reached" or 1000
/// "session time limit" (its 15-minute cap). Users read "A voice session is
/// already running" or a raw "Socket is not connected"; a limit before the
/// first reply was taken for a dead-on-arrival session and quietly redialled,
/// spending more of the budget; and a call cut at 15 minutes reported
/// "Couldn't start the call".
final class VoiceLimitTests: XCTestCase {
    private final class Rec: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [String] = [], _states: [VoiceState] = [], _ended: [String?] = [], _notes: [String] = []
        func error(_ m: String) { lock.withLock { _errors.append(m) } }
        func state(_ s: VoiceState) { lock.withLock { _states.append(s) } }
        func end(_ e: String?) { lock.withLock { _ended.append(e) } }
        func note(_ n: String) { lock.withLock { _notes.append(n) } }
        var errors: [String] { lock.withLock { _errors } }
        var states: [VoiceState] { lock.withLock { _states } }
        var ended: [String?] { lock.withLock { _ended } }
        var notes: [String] { lock.withLock { _notes } }
    }

    /// A client whose socket has OPENED (the delegate's didOpen), with an
    /// owner hooked for dead-on-arrival reconnects, as Talk and calls have.
    private func openClient(_ rec: Rec) -> VoiceRealtimeClient {
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { rec.state($0) },
            onCaption: { _, _, _ in },
            onError: { rec.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
        c.sendOverride = { _ in }
        c.onTransportEnded = { rec.end($0) }
        c.onServerEnded = { rec.note($0) }
        let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/v")!)
        c.urlSession(URLSession.shared, webSocketTask: socket, didOpenWithProtocol: nil)
        return c
    }
    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testTheProxysClosesMapToPlainWords() {
        XCTAssertEqual(VoiceRealtimeClient.serverCloseMessage(code: 1008, reason: "daily voice limit reached"), VoiceRealtimeClient.dailyLimitMessage)
        XCTAssertEqual(VoiceRealtimeClient.serverCloseMessage(code: 1000, reason: "session time limit"), VoiceRealtimeClient.sessionTimeLimitMessage)
        XCTAssertNil(VoiceRealtimeClient.serverCloseMessage(code: 1000, reason: "bye"), "a clean close")
        XCTAssertNil(VoiceRealtimeClient.serverCloseMessage(code: 1001, reason: ""))
        let other = VoiceRealtimeClient.serverCloseMessage(code: 1011, reason: "upstream: org-XYZ internal error")
        XCTAssertEqual(other, VoiceRealtimeClient.serverClosedMessage)
        XCTAssertFalse(other?.contains("org-XYZ") ?? true, "a relayed upstream reason is never shown")
    }

    func testAHandshake429NamesBothLimitsNeverJustAlreadyRunning() {
        let rec = Rec()
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" }, onState: { rec.state($0) }, onCaption: { _, _, _ in },
            onError: { rec.error($0) }, initialRoute: .speaker, routeProvider: { .speaker }, now: { 0 })
        c.handshakeEnded(status: 429, error: nil)
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.voiceLimitMessage])
        XCTAssertTrue(VoiceRealtimeClient.voiceLimitMessage.contains("today's voice time"))
        XCTAssertTrue(VoiceRealtimeClient.voiceLimitMessage.contains("another voice session"))
    }

    /// The budget ran out on the first reply of a session: before, that looked
    /// dead on arrival — swallowed, redialled twice (each dial a session unit),
    /// then "The voice server dropped the session twice".
    func testADailyLimitCloseIsToldAndNeverQuietlyRedialled() {
        let rec = Rec()
        let c = openClient(rec)
        c.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertFalse(c.failedBeforeAnyReply, "a limit is not dead on arrival — redialling meets it again")
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.dailyLimitMessage])
        XCTAssertEqual(rec.ended, [VoiceRealtimeClient.dailyLimitMessage])
        XCTAssertTrue(rec.states.contains(.error))
        // An early server error swallowed for the reconnect doesn't hide it either.
        let rec2 = Rec()
        let c2 = openClient(rec2)
        c2.handle(json(["type": "error", "error": ["message": "upstream busy"]]))
        XCTAssertTrue(c2.failedBeforeAnyReply)
        c2.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertFalse(c2.failedBeforeAnyReply)
        XCTAssertEqual(rec2.errors, [VoiceRealtimeClient.dailyLimitMessage])
        c.stop(); c2.stop()
    }

    /// The 15-minute cap is a clean end: Talk says why under "Ended"; a call
    /// hangs up as a normal end (the launcher maps nil to .hungUp), not
    /// "Couldn't start the call — here's what it was about".
    func testTheSessionTimeLimitIsACleanEndWithANote() {
        let rec = Rec()
        let c = openClient(rec)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.serverClosed(code: 1000, reason: "session time limit")
        XCTAssertEqual(rec.errors, [], "not an error")
        XCTAssertEqual(rec.ended, [nil], "a clean end for the call")
        XCTAssertEqual(rec.notes, [VoiceRealtimeClient.sessionTimeLimitMessage])
        XCTAssertEqual(rec.states.last, .closed)
        c.stop()
    }

    /// A close the server started with nothing said: after a reply it is a
    /// clean end; before any, a session that never happened (dead on arrival,
    /// Android parity) — never a call reported done.
    func testACleanServerCloseBeforeAnyReplyIsDeadOnArrival() {
        let rec = Rec()
        let c = openClient(rec)
        c.serverClosed(code: 1000, reason: "")
        XCTAssertTrue(c.failedBeforeAnyReply)
        XCTAssertEqual(rec.ended, [VoiceRealtimeClient.serverClosedMessage])
        XCTAssertEqual(rec.errors, [], "not shown — the owner reconnects or reports")
        let rec2 = Rec()
        let c2 = openClient(rec2)
        c2.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c2.serverClosed(code: 1000, reason: "")
        XCTAssertEqual(rec2.ended, [nil])
        XCTAssertEqual(rec2.states.last, .closed)
        // Reported once, whichever of receive / didCloseWith / didComplete lands.
        c2.serverClosed(code: 1000, reason: "")
        XCTAssertEqual(rec2.ended.count, 1)
        c.stop(); c2.stop()
    }
}

// MARK: - turn-taking through the real client (audit 2026-09-22, C46)

final class VoiceTurnEventTests: XCTestCase {
    private func client(_ wire: Wire) -> VoiceRealtimeClient {
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { wire.state($0) },
            onCaption: { _, _, _ in },
            onError: { wire.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { 0 })
        c.sendOverride = { wire.sent($0) }
        return c
    }
    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    /// OpenAI's transcription.failed was ignored: the turn was never asked
    /// for. It now puts the turn in hand ("Thinking…"; the hold's tick asks).
    func testAFailedTranscriptionPutsTheTurnInHand() {
        let wire = Wire()
        let c = client(wire)
        c.handle(json(["type": "input_audio_buffer.speech_started", "item_id": "u"]))
        c.handle(json(["type": "input_audio_buffer.speech_stopped", "item_id": "u"]))
        XCTAssertFalse(wire.states.contains(.thinking))
        c.handle(json(["type": "conversation.item.input_audio_transcription.failed", "item_id": "u", "content_index": 0,
                       "error": ["type": "transcription_error", "code": "rate_limit_exceeded", "message": "Rate limit reached"]]))
        XCTAssertEqual(wire.states.last, .thinking)
        XCTAssertEqual(wire.errors, [], "nothing to tell the user — the reply is coming")
    }

    /// "Already has an active response" is a reply generating, not nothing.
    func testACreateRefusedByALiveReplyKeepsTheScreenOnIt() {
        let wire = Wire()
        let c = client(wire)
        c.handle(json(["type": "response.created", "response": ["id": "r1"]]))
        c.handle(json(["type": "error", "error": ["type": "invalid_request_error", "code": "conversation_already_has_active_response",
                                                  "message": "Conversation already has an active response in progress: resp_r1."]]))
        XCTAssertEqual(wire.states.last, .thinking, "not Listening over a live reply")
        XCTAssertFalse(wire.states.contains(.error))
        XCTAssertFalse(wire.types.contains("response.create"), "and nothing re-created into the refusal")
    }
}

// MARK: - Daily voice minutes (Ahmad 2026-09-23)
//
// "Let's cap at 10 minutes of calls a day … one stretch or multiple": the
// voice proxy tells the client what is left (`unstuck.voice_budget`), warns
// once at about a minute, and closes 1008 "daily voice limit reached" when
// they are gone (workers/voice-proxy/README.md "Voice minutes"). Driven
// through the real client with a fake clock.

final class VoiceMinutesTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _t: TimeInterval = 0
        var t: TimeInterval { get { lock.withLock { _t } } set { lock.withLock { _t = newValue } } }
    }
    private final class Rec: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [String] = [], _ended: [String?] = [], _minutes: [VoiceMinutes] = []
        func error(_ m: String) { lock.withLock { _errors.append(m) } }
        func end(_ e: String?) { lock.withLock { _ended.append(e) } }
        func minutes(_ m: VoiceMinutes) { lock.withLock { _minutes.append(m) } }
        var errors: [String] { lock.withLock { _errors } }
        var ended: [String?] { lock.withLock { _ended } }
        var minutes: [VoiceMinutes] { lock.withLock { _minutes } }
    }

    private var suites: [String] = []
    override func tearDown() {
        for s in suites { UserDefaults.standard.removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "VoiceMinutesTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// A client whose socket has OPENED, hooked like Talk and calls are.
    private func client(_ rec: Rec, _ wire: Wire, _ clock: Clock, account: String? = nil,
                        memory: UserDefaults? = nil) -> VoiceRealtimeClient {
        let c = VoiceRealtimeClient(
            proxyURL: "wss://example.invalid/v", token: "t", model: "m",
            instructions: "i", opening: "o", tools: [], audio: SilentAudioIO(),
            runTool: { _, _ in "ok" },
            onState: { wire.state($0) },
            onCaption: { _, _, _ in },
            onError: { rec.error($0) },
            initialRoute: .speaker,
            routeProvider: { .speaker },
            now: { clock.t })
        c.sendOverride = { wire.sent($0) }
        c.onTransportEnded = { rec.end($0) }
        c.onMinutes = { rec.minutes($0) }
        c.minutesAccount = account
        if let memory { c.minutesDefaults = memory }
        return c
    }
    private func open(_ c: VoiceRealtimeClient) {
        let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://example.invalid/v")!)
        c.urlSession(URLSession.shared, webSocketTask: socket, didOpenWithProtocol: nil)
    }
    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func budget(_ ms: Int, warn: Bool = false) -> String {
        json(["type": "unstuck.voice_budget", "remaining_ms": ms, "warn": warn])
    }

    // MARK: the event

    func testTheBudgetEventParses() {
        XCTAssertEqual(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": 540_000, "warn": false]),
                       VoiceMinutes(remainingMs: 540_000, warn: false))
        XCTAssertEqual(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": 59_999.6, "warn": true]),
                       VoiceMinutes(remainingMs: 60_000, warn: true))
        XCTAssertEqual(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": 3_600_000])?.warn, false, "warn defaults to false")
        XCTAssertEqual(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": -5, "warn": false])?.remainingMs, 0)
        // The refusal's figure, off the wire: a JSON 0 (or 1) is a number, not a Bool.
        let wire = try! JSONSerialization.jsonObject(with: Data(#"{"type":"unstuck.voice_budget","remaining_ms":0,"warn":false}"#.utf8)) as! [String: Any]
        XCTAssertEqual(VoiceMinutes(event: wire), VoiceMinutes(remainingMs: 0, warn: false))
        let one = try! JSONSerialization.jsonObject(with: Data(#"{"type":"unstuck.voice_budget","remaining_ms":1}"#.utf8)) as! [String: Any]
        XCTAssertEqual(VoiceMinutes(event: one)?.remainingMs, 1)
        let flag = try! JSONSerialization.jsonObject(with: Data(#"{"type":"unstuck.voice_budget","remaining_ms":true}"#.utf8)) as! [String: Any]
        XCTAssertNil(VoiceMinutes(event: flag))
        XCTAssertNil(VoiceMinutes(event: ["type": "unstuck.voice_budget", "warn": true]), "no figure, no event")
        XCTAssertNil(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": "60000"]))
        XCTAssertNil(VoiceMinutes(event: ["type": "unstuck.voice_budget", "remaining_ms": true]))
        XCTAssertNil(VoiceMinutes(event: ["type": "response.done", "remaining_ms": 1]))
        XCTAssertEqual(VoiceMinutes(remainingMs: 90_000, warn: false).remainingMs(after: 31.5), 58_500)
        XCTAssertEqual(VoiceMinutes(remainingMs: 1_000, warn: false).remainingMs(after: 5), 0)
    }

    func testThePlainWords() {
        XCTAssertEqual(VoiceMinutes.usedMessage(allowanceMinutes: 10), "You've used today's 10 voice minutes. They reset at midnight.")
        XCTAssertEqual(VoiceMinutes.usedMessage(allowanceMinutes: 60), "You've used today's 60 voice minutes. They reset at midnight.")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 600_000), "10 min left today")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 540_001), "10 min left today", "whole minutes, rounded up")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 540_000), "9 min left today")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 60_000), "1 min left today")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 59_999), "Under a minute left today")
        XCTAssertEqual(VoiceMinutes.label(remainingMs: 3_600_000), "60 min left today", "the team's day")
        XCTAssertNil(VoiceMinutes.label(remainingMs: 0), "the limit's own message says it")
        // The spoken notice is the app's note, not the user's words, and no
        // action claim the integrity guard would bounce.
        XCTAssertTrue(VoiceMinutes.noticeText.hasPrefix("(note from the app, not the user"))
        XCTAssertFalse(looksLikeActionClaim("We've got about a minute left today."))
    }

    func testTheAllowanceIsSixtyOnlyWhenMoreThanTenMinutesWereSeenToday() {
        XCTAssertEqual(VoiceMinutes.allowanceMinutes(largestSeenMs: 0), 10)
        XCTAssertEqual(VoiceMinutes.allowanceMinutes(largestSeenMs: 600_000), 10)
        XCTAssertEqual(VoiceMinutes.allowanceMinutes(largestSeenMs: 600_001), 60)
        let d = defaults()
        let a = VoiceMinutesMemory(account: "A", defaults: d)
        XCTAssertEqual(a.record(3_540_000, day: "2026-09-23"), 3_540_000)
        XCTAssertEqual(a.record(20_000, day: "2026-09-23"), 3_540_000, "the day's largest stays")
        XCTAssertEqual(a.largestSeenMs(day: "2026-09-24"), 0, "a new day starts from nothing")
        XCTAssertEqual(VoiceMinutesMemory(account: "B", defaults: d).largestSeenMs(day: "2026-09-23"), 0, "per account")
    }

    // MARK: the warning, through the real client

    func testTheWarningHasTheAssistantSayItOnce_asTheAppsNote() {
        let rec = Rec(), wire = Wire(), clock = Clock()
        let c = client(rec, wire, clock)
        c.handle(budget(540_000))
        XCTAssertEqual(rec.minutes, [VoiceMinutes(remainingMs: 540_000, warn: false)])
        XCTAssertEqual(wire.types, [], "a figure is only shown")
        clock.t = 10
        c.handle(budget(60_000, warn: true))
        XCTAssertEqual(wire.types, ["conversation.item.create", "response.create"], "nothing on air: said now")
        let item = wire.frames[0]["item"] as? [String: Any]
        XCTAssertEqual(item?["type"] as? String, "message")
        XCTAssertEqual(item?["role"] as? String, "user", "the proxy relays user messages only")
        let content = (item?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["text"] as? String, VoiceMinutes.noticeText)
        XCTAssertNil(wire.frames[1]["response"], "a plain create: the proxy strips per-response instructions")
        clock.t = 20
        c.handle(budget(50_000, warn: true))
        XCTAssertEqual(wire.types.count, 2, "once per session")
        c.stop()
    }

    /// The notice's reply is a line about the time, not an action: the
    /// integrity guard never bounces it — a "…I'll make it quick" would
    /// otherwise force a tool call out of it. The same words in any other
    /// reply still are bounced.
    func testTheNoticesReplyIsNeverTakenForAnActionClaim() {
        let said = "We've got about a minute left today — I'll make it quick."
        XCTAssertTrue(looksLikeActionClaim(said), "the words alone would trip the guard")
        func reply(_ c: VoiceRealtimeClient, _ id: String) {
            c.handle(json(["type": "response.created", "response": ["id": id]]))
            c.handle(json(["type": "response.audio_transcript.delta", "response_id": id, "delta": said]))
            c.handle(json(["type": "response.done", "response": ["id": id, "status": "completed"]]))
        }
        func correctives(_ w: Wire) -> Int {
            w.frames.filter { f in
                let item = f["item"] as? [String: Any]
                let text = ((item?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return text == VoiceIntegrityGuard.correctiveText
            }.count
        }
        let wire = Wire(), clock = Clock()
        let c = client(Rec(), wire, clock)
        c.handle(budget(60_000, warn: true))
        XCTAssertEqual(wire.types.last, "response.create", "the notice was asked for")
        reply(c, "n1")
        XCTAssertEqual(correctives(wire), 0)
        reply(c, "r2")
        XCTAssertEqual(correctives(wire), 1, "an ordinary reply is still held to its word")
        c.stop()
    }

    func testTheWarningWaitsForTheOpeningsReply() {
        let rec = Rec(), wire = Wire(), clock = Clock()
        let c = client(rec, wire, clock)
        open(c)   // session.update, the primer, the opening's create
        let before = wire.types.count
        c.handle(budget(45_000, warn: true))   // the session's first frame
        XCTAssertEqual(wire.types.count, before, "the opening's reply is being created — never talked over")
        c.stop()
    }

    // MARK: out of minutes

    /// Refused at connect (under 5 s left): the socket is accepted, told 0 ms,
    /// and closed 1008 — the plain line, never a redial.
    func testARefusalAtConnectReadsPlainly_andIsNeverRedialled() {
        let rec = Rec(), wire = Wire(), clock = Clock()
        let c = client(rec, wire, clock)
        open(c)
        c.handle(budget(0))
        c.serverClosed(code: 1008, reason: "daily voice limit reached")
        let line = "You've used today's 10 voice minutes. They reset at midnight."
        XCTAssertEqual(rec.errors, [line])
        XCTAssertEqual(rec.ended, [line])
        XCTAssertEqual(c.minutesUsedNote, line, "a call ends normally on it")
        XCTAssertFalse(c.failedBeforeAnyReply, "no quiet reconnect into the same refusal")
        c.stop()
    }

    func testMinutesThatRunOutMidSessionNameTheTeamsAllowance() {
        let rec = Rec(), wire = Wire(), clock = Clock()
        let c = client(rec, wire, clock)
        open(c)
        c.handle(budget(700_000))   // 11 min 40 s left: more than a standard day
        clock.t = 300
        c.handle(budget(340_000))   // a correction: another device spent a minute
        clock.t = 640               // the minutes, not the 15-minute cap, end it
        c.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertEqual(rec.errors, ["You've used today's 60 voice minutes. They reset at midnight."])
        c.stop()
    }

    /// A team member late in their day (under 10 minutes left): the account's
    /// larger figure from earlier today still names 60; another account 10.
    func testTheAllowanceIsRememberedPerAccountForTheDay() {
        let memory = defaults()
        let clock = Clock()
        let morning = client(Rec(), Wire(), clock, account: "team", memory: memory)
        morning.handle(budget(3_600_000))
        morning.stop()
        let rec = Rec()
        let evening = client(rec, Wire(), clock, account: "team", memory: memory)
        open(evening)
        evening.handle(budget(20_000))
        clock.t = 20
        evening.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertEqual(rec.errors, ["You've used today's 60 voice minutes. They reset at midnight."])
        evening.stop()
        let other = Rec()
        let test = client(other, Wire(), clock, account: "test-account", memory: memory)
        open(test)
        test.handle(budget(0))
        test.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertEqual(other.errors, ["You've used today's 10 voice minutes. They reset at midnight."])
        test.stop()
    }

    /// The same close is the proxy's daily REPLY budget when minutes are left,
    /// and can't be the minutes with no figure at all (the read failed — that
    /// session is capped and closed 1000 — or a proxy from before 077).
    func testTheSameCloseWithMinutesLeftOrNoFigureIsTheReplyBudget() {
        let rec = Rec(), clock = Clock()
        let c = client(rec, Wire(), clock)
        open(c)
        c.handle(budget(300_000))
        clock.t = 10
        c.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertEqual(rec.errors, [VoiceRealtimeClient.dailyLimitMessage])
        XCTAssertNil(c.minutesUsedNote, "a call that ends so is not the minutes")
        c.stop()
        let rec2 = Rec()
        let c2 = client(rec2, Wire(), Clock())
        open(c2)
        c2.serverClosed(code: 1008, reason: "daily voice limit reached")
        XCTAssertEqual(rec2.errors, [VoiceRealtimeClient.dailyLimitMessage])
        XCTAssertNil(c2.minutesUsedNote)
        c2.stop()
    }
}
