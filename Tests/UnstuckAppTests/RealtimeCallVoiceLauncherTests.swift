// RealtimeCallVoiceLauncher against a fake realtime session — no socket, no
// AVFoundation, no AppModel. Asserts the C1 launcher contract:
//   composition (base instructions + call script, verbatim opening in the
//   primer, call tools only + snooze_call), snooze → the coordinator ONLY
//   (the launcher never ends itself — the coordinator's async CXEndCallAction
//   stops it and reports `snoozed` exactly once), transport drop → `.failed` /
//   clean close → `.hungUp` exactly once, nothing after stop(), mute
//   passthrough (also when set before start), non-call tools refused, the
//   fallback-B Talk configuration, and the audio engine's `.callKit`
//   ownership never touching setActive.

import AVFoundation
import XCTest
import UnstuckSync
@testable import Unstuck

/// A realtime session the launcher can drive without a socket.
final class FakeRealtimeSession: CallRealtimeSession, @unchecked Sendable {
    let config: CallVoiceSessionConfig
    var starts = 0
    var stops = 0
    var mutes: [Bool] = []
    init(_ config: CallVoiceSessionConfig) { self.config = config }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func setMicMuted(_ muted: Bool) { mutes.append(muted) }
    /// Drive it like the model would.
    func tool(_ name: String, _ args: String = "{}") async -> String { await config.runTool(name, args) }
    /// The transport went away (nil = clean close).
    func drop(_ error: String?) { config.onTransportEnded(error) }
}

/// Records what the engine asks of the AVAudioSession.
final class FakeAudioSessionControl: VoiceAudioSessionControlling, @unchecked Sendable {
    var configured: [AVAudioSession.CategoryOptions] = []
    var setActiveCalls: [Bool] = []
    func configureVoiceChat(options: AVAudioSession.CategoryOptions) throws { configured.append(options) }
    func setActive(_ active: Bool) throws { setActiveCalls.append(active) }
}

@MainActor
final class RealtimeCallVoiceLauncherTests: XCTestCase {
    private var sessions: [FakeRealtimeSession] = []
    private var appToolCalls: [String] = []
    private var snoozes: [Int] = []
    private var snoozeResult: (Int) -> String = { "ok: I'll call back in \($0) minutes — say a quick goodbye; the call ends now" }
    private var fallbackSnoozes: [(callId: String, minutes: Int)] = []
    private var sessionStarts = 0
    private var sessionEnds = 0
    private var ended: [CallEndReason] = []
    private var launcher: RealtimeCallVoiceLauncher!

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let callId = "0f1e2d3c-4b5a-4697-8877-665544332211"

    override func setUp() async throws {
        try await super.setUp()
        sessions = []; appToolCalls = []; snoozes = []; fallbackSnoozes = []
        sessionStarts = 0; sessionEnds = 0; ended = []
        snoozeResult = { "ok: I'll call back in \($0) minutes — say a quick goodbye; the call ends now" }
        launcher = RealtimeCallVoiceLauncher()
        launcher.bind(deps())
    }

    private func deps(configured: Bool = true, token: String? = "tok") -> RealtimeCallVoiceLauncher.Deps {
        RealtimeCallVoiceLauncher.Deps(
            isVoiceConfigured: { configured },
            accessToken: { token },
            voiceInstructions: { "BASE VOICE INSTRUCTIONS" },
            voiceTools: { Self.voiceTools },
            runAppTool: { [unowned self] name, _ in appToolCalls.append(name); return "ok: \(name)" },
            snooze: { [unowned self] m in snoozes.append(m); return snoozeResult(m) },
            reportFallbackSnooze: { [unowned self] id, m in fallbackSnoozes.append((id, m)) },
            sessionWillStart: { [unowned self] in sessionStarts += 1 },
            sessionDidEnd: { [unowned self] in sessionEnds += 1 },
            makeSession: { [unowned self] c in let s = FakeRealtimeSession(c); sessions.append(s); return s },
            now: { Self.now })
    }

    /// A slice of VOICE_TOOLS: some call tools + non-call tools; no update_call.
    static let voiceTools: [[String: Any]] = [
        ["type": "function", "name": "create_task", "description": "Create a task.", "parameters": ["type": "object", "properties": [:], "required": []]],
        ["type": "function", "name": "complete_task", "description": "Mark a task done.", "parameters": ["type": "object", "properties": [:], "required": ["taskId"]]],
        ["type": "function", "name": "schedule_task", "description": "Place a task.", "parameters": ["type": "object", "properties": [:], "required": []]],
        ["type": "function", "name": "add_capture", "description": "Save a capture.", "parameters": ["type": "object", "properties": [:], "required": ["body"]]],
        ["type": "function", "name": "start_focus", "description": "Start focus.", "parameters": ["type": "object", "properties": [:], "required": ["taskId"]]],
        ["type": "function", "name": "delete_task", "description": "Delete.", "parameters": ["type": "object", "properties": [:], "required": []]],
    ]

    private func session(notes: [String] = ["Ask about the invoice", "Confirm Friday"]) -> CallSession {
        CallSession(payload: IncomingCallPayload(callId: Self.callId, label: "speak to James", notes: notes,
                                                 taskId: "task-1", blockId: "block-1", taskName: "Speak to James",
                                                 firstAction: "open the thread", name: "Ahmad Tambaya"),
                    receivedAt: Self.now)
    }

    @discardableResult
    private func start(_ s: CallSession? = nil) -> FakeRealtimeSession {
        launcher.start(s ?? session()) { [unowned self] r in ended.append(r) }
        return sessions.last!
    }

    // MARK: - composition

    func testComposesBaseInstructionsPlusCallScriptAndVerbatimOpening() {
        let s = session()
        let live = start(s)
        let c = live.config
        XCTAssertTrue(c.instructions.hasPrefix("BASE VOICE INSTRUCTIONS\n\n"))
        XCTAssertTrue(c.instructions.hasSuffix(CallScript.instructions(s, now: Self.now)))
        XCTAssertTrue(c.instructions.contains("THIS IS A PHONE CALL"))
        XCTAssertEqual(c.opening, CallScript.opening(s, now: Self.now))
        XCTAssertTrue(c.opening.hasPrefix("Hi Ahmad — you asked me to call about speak to James. Your notes: Ask about the invoice; Confirm Friday."))
        // The primer carries the opening verbatim and is what goes on the wire as the opening.
        XCTAssertTrue(c.primer.contains("\"\(c.opening)\""))
        XCTAssertTrue(c.primer.contains("EXACTLY"))
        XCTAssertEqual(live.starts, 1)
        XCTAssertEqual(sessionStarts, 1)
    }

    func testToolsAreCallToolsOnlyPlusSnoozeCall() {
        let live = start()
        XCTAssertEqual(live.config.toolNames, CallScript.callTools)
        XCTAssertEqual(live.config.toolNames, ["complete_task", "add_capture", "schedule_task", "start_focus", "update_call", "snooze_call"])
        XCTAssertFalse(live.config.toolNames.contains("create_task"))
        XCTAssertFalse(live.config.toolNames.contains("delete_task"))
        // VOICE_TOOLS schemas are passed through untouched.
        let complete = live.config.tools.first { $0["name"] as? String == "complete_task" }
        XCTAssertEqual(complete?["description"] as? String, "Mark a task done.")
        // snooze_call: {minutes: integer, default 10}.
        let snooze = live.config.tools.first { $0["name"] as? String == "snooze_call" }
        let params = snooze?["parameters"] as? [String: Any]
        let minutes = (params?["properties"] as? [String: Any])?["minutes"] as? [String: Any]
        XCTAssertEqual(minutes?["type"] as? String, "integer")
        XCTAssertEqual(minutes?["default"] as? Int, 10)
        XCTAssertEqual((params?["required"] as? [String]) ?? ["x"], [])
        // update_call falls back to the launcher's own schema when VOICE_TOOLS lacks it.
        let update = live.config.tools.first { $0["name"] as? String == "update_call" }
        XCTAssertEqual(((update?["parameters"] as? [String: Any])?["required"] as? [String]), ["callId"])
    }

    func testVoiceToolsUpdateCallSchemaWinsOverTheFallback() {
        var tools = Self.voiceTools
        tools.append(["type": "function", "name": "update_call", "description": "FROM VOICE_TOOLS", "parameters": ["type": "object", "properties": [:], "required": ["callId"]]])
        let schemas = RealtimeCallVoiceLauncher.callToolSchemas(from: tools)
        let update = schemas.first { $0["name"] as? String == "update_call" }
        XCTAssertEqual(update?["description"] as? String, "FROM VOICE_TOOLS")
    }

    // MARK: - snooze

    /// snooze_call is the coordinator's: the launcher returns its result and
    /// does NOT end itself — the coordinator's (async) CXEndCallAction lands
    /// in performEnd, which calls stop() and reports `snoozed` once. Ending
    /// here too used to fire onEnded → a second endActiveCall.
    func testSnoozeHandsOffToTheCoordinatorAndNeverEndsItself() async {
        let live = start()
        let r = await live.tool("snooze_call", #"{"minutes":10}"#)
        XCTAssertTrue(r.hasPrefix("ok"))
        XCTAssertEqual(snoozes, [10])
        XCTAssertTrue(ended.isEmpty, "no onEnded — the coordinator owns the end")
        XCTAssertEqual(live.stops, 0, "still talking until CallKit ends the call")
        XCTAssertEqual(sessionEnds, 0)
        // The coordinator's performEnd → stop(): silent, once.
        launcher.stop()
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(sessionEnds, 1)
        XCTAssertTrue(ended.isEmpty)
        // Nothing after: a late transport drop / a second snooze are ignored.
        live.drop("socket closed")
        let again = await live.tool("snooze_call", "{}")
        XCTAssertEqual(again, "error: the call has ended")
        XCTAssertTrue(ended.isEmpty)
        XCTAssertEqual(snoozes, [10])
        XCTAssertEqual(live.stops, 1)
    }

    func testSnoozeDefaultsToTenAndPassesTheRawMinutesForTheCoordinatorToClamp() async {
        let a = start()
        _ = await a.tool("snooze_call", "{}")
        XCTAssertEqual(snoozes, [10])
        let b = start()
        _ = await b.tool("snooze_call", #"{"minutes":999}"#)
        XCTAssertEqual(snoozes, [10, 999], "the raw minutes reach the coordinator, which clamps")
        XCTAssertTrue(ended.isEmpty)
    }

    func testSnoozeErrorLeavesTheCallRunning() async {
        snoozeResult = { _ in "error: no call is active" }
        let live = start()
        let r = await live.tool("snooze_call", #"{"minutes":5}"#)
        XCTAssertEqual(r, "error: no call is active")
        XCTAssertEqual(snoozes, [5])
        XCTAssertTrue(ended.isEmpty)
        XCTAssertEqual(live.stops, 0)
    }

    /// End to end through a REAL CallCoordinator over the CallCoordinatorTests
    /// fakes, with CallKit's ASYNC end: answer → didActivate → launcher starts
    /// → snooze_call → the coordinator asks CallKit to end (in flight) → the
    /// model says goodbye and the transport closes BEFORE the CXEndCallAction
    /// lands → still ONE end transaction; the action lands → ONE `snoozed`
    /// outcome with the minutes, the launcher stopped exactly once.
    func testSnoozeThroughTheCoordinatorIsOneEndAndOneOutcomeDespiteTheRace() async {
        let provider = FakeCallProvider(), controller = FakeCallController(), notifier = FakeNotifier()
        let reporter = FakeReporter(), env = FakeEnvironment(), clock = FakeClock()
        clock.now = Self.now
        let coordinator = CallCoordinator(provider: provider, controller: controller, environment: env,
                                          launcher: launcher, launcherAttached: true,
                                          notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = coordinator
        var d = deps()
        d.snooze = { coordinator.snoozeActiveCall(minutes: $0) }
        launcher.bind(d)

        coordinator.reportIncoming(session().payload)
        XCTAssertTrue(coordinator.performAnswer(uuid: UUID(uuidString: Self.callId)!))
        XCTAssertTrue(sessions.isEmpty, "voice never starts before CallKit activates audio")
        coordinator.audioSessionDidActivate()
        XCTAssertEqual(sessions.count, 1)
        let live = sessions[0]
        XCTAssertEqual(live.starts, 1)
        XCTAssertEqual(launcher.activeSession?.callId, Self.callId)

        let r = await live.tool("snooze_call", #"{"minutes":10}"#)
        XCTAssertTrue(r.hasPrefix("ok: I'll call back in 10 minutes"))
        XCTAssertEqual(controller.requested.count, 1, "the coordinator's hang-up is in flight")
        XCTAssertEqual(live.stops, 0, "nothing stopped until CallKit ends the call")
        XCTAssertEqual(reporter.outcomes, [.answered], "nothing reported yet")
        XCTAssertEqual(coordinator.active?.pendingEnd, .snoozed(minutes: 10))

        // The race: the conversation ends on its own while the end is in flight.
        live.drop(nil)
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(sessionEnds, 1)
        XCTAssertNil(launcher.activeSession)
        XCTAssertEqual(controller.requested.count, 1, "no second CXEndCallAction from onEnded")
        XCTAssertEqual(reporter.outcomes, [.answered])

        controller.flush()   // CallKit's CXEndCallAction lands
        XCTAssertEqual(reporter.reports.last, FakeReporter.Report(callId: Self.callId, callKitId: UUID(uuidString: Self.callId), outcome: .snoozed, snooze: 10, notes: nil))
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed], "exactly one outcome for the end")
        XCTAssertEqual(controller.requested.count, 1)
        XCTAssertNil(coordinator.active)
        XCTAssertEqual(live.stops, 1, "stopped exactly once")
        XCTAssertEqual(sessionEnds, 1)
    }

    /// The plain path (no race): snooze → CallKit ends → performEnd stops the
    /// launcher itself → `snoozed` once, stop once.
    func testSnoozeThroughTheCoordinatorStopsTheLauncherFromPerformEnd() async {
        let provider = FakeCallProvider(), controller = FakeCallController(), notifier = FakeNotifier()
        let reporter = FakeReporter(), env = FakeEnvironment(), clock = FakeClock()
        clock.now = Self.now
        let coordinator = CallCoordinator(provider: provider, controller: controller, environment: env,
                                          launcher: launcher, launcherAttached: true,
                                          notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = coordinator
        var d = deps()
        d.snooze = { coordinator.snoozeActiveCall(minutes: $0) }
        launcher.bind(d)
        coordinator.reportIncoming(session().payload)
        XCTAssertTrue(coordinator.performAnswer(uuid: UUID(uuidString: Self.callId)!))
        coordinator.audioSessionDidActivate()
        let live = sessions[0]
        _ = await live.tool("snooze_call", #"{"minutes":15}"#)
        controller.flush()
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
        XCTAssertEqual(reporter.reports.last?.snooze, 15)
        XCTAssertEqual(controller.requested.count, 1)
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(sessionEnds, 1)
        XCTAssertNil(coordinator.active)
        XCTAssertNil(launcher.activeSession)
        // A late drop from the old socket is ignored (generation moved on).
        live.drop("late")
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
        XCTAssertEqual(controller.requested.count, 1)
    }

    // MARK: - end contract

    func testTransportFailureEndsFailedExactlyOnce() {
        let live = start()
        live.drop("socket closed")
        live.drop("socket closed")
        XCTAssertEqual(ended, [.failed("socket closed")])
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(sessionEnds, 1)
        XCTAssertNil(launcher.activeSession)
    }

    func testCleanRemoteCloseEndsHungUp() {
        let live = start()
        live.drop(nil)
        XCTAssertEqual(ended, [.hungUp])
        XCTAssertEqual(live.stops, 1)
    }

    func testNothingAfterStop() async {
        let live = start()
        launcher.stop()
        XCTAssertEqual(live.stops, 1)
        XCTAssertEqual(sessionEnds, 1)
        live.drop("socket closed")
        live.drop(nil)
        let r = await live.tool("complete_task", #"{"taskId":"task-1"}"#)
        XCTAssertEqual(r, "error: the call has ended")
        XCTAssertTrue(ended.isEmpty)
        XCTAssertTrue(appToolCalls.isEmpty)
        XCTAssertEqual(live.stops, 1, "stop() is idempotent")
        launcher.stop()
        XCTAssertEqual(live.stops, 1)
    }

    func testAStaleSessionsCallbacksAreIgnoredAfterANewStart() {
        let first = start()
        let second = start()
        XCTAssertEqual(first.stops, 1, "a new start tears the previous session down silently")
        XCTAssertTrue(ended.isEmpty)
        first.drop("late failure from the old socket")
        XCTAssertTrue(ended.isEmpty)
        second.drop("real")
        XCTAssertEqual(ended, [.failed("real")])
    }

    // MARK: - tools + mute

    func testCallToolsGoToTheAppExecutorAndOthersAreRefused() async {
        let live = start()
        let complete = await live.tool("complete_task", #"{"taskId":"task-1"}"#)
        let update = await live.tool("update_call", #"{"callId":"x","notes":["a"]}"#)
        let create = await live.tool("create_task", #"{"name":"nope"}"#)
        XCTAssertEqual(complete, "ok: complete_task")
        XCTAssertEqual(update, "ok: update_call")
        XCTAssertEqual(create, "error: create_task isn't available during a call")
        XCTAssertEqual(appToolCalls, ["complete_task", "update_call"])
        XCTAssertTrue(ended.isEmpty)
    }

    func testMuteIsForwardedAndAppliedWhenSetBeforeStart() {
        launcher.setMuted(true)                       // CallKit mute before audio activates
        let live = start()
        XCTAssertEqual(live.mutes, [true])
        launcher.setMuted(false)
        XCTAssertEqual(live.mutes, [true, false])
        launcher.setMuted(true)
        launcher.stop()                               // stop() resets the mute for the next call
        let next = start()
        XCTAssertEqual(next.mutes, [false])
    }

    // MARK: - guards

    /// start() when no session is expected to be created.
    private func startDegraded() {
        launcher.start(session()) { [unowned self] r in ended.append(r) }
    }

    func testUnboundOrUnconfiguredFailsImmediately() {
        let unbound = RealtimeCallVoiceLauncher()
        var reasons: [CallEndReason] = []
        unbound.start(session()) { reasons.append($0) }
        XCTAssertEqual(reasons, [.failed("voice launcher not bound")])

        launcher.bind(deps(configured: false))
        startDegraded()
        XCTAssertEqual(ended, [.failed("voice not configured")])
        XCTAssertTrue(sessions.isEmpty)

        ended = []
        launcher.bind(deps(token: nil))
        startDegraded()
        XCTAssertEqual(ended, [.failed("not signed in")])
        XCTAssertTrue(sessions.isEmpty)
    }

    func testMakeSessionNilFailsWithoutStartingTheTalkScratch() {
        var d = deps()
        d.makeSession = { _ in nil }
        launcher.bind(d)
        startDegraded()
        XCTAssertEqual(ended, [.failed("voice unavailable")])
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(sessionStarts, 0)
        XCTAssertEqual(sessionEnds, 0)
    }

    // MARK: - fallback B

    func testTalkConfigurationForFallbackSnoozesByReportingTheOutcome() async {
        let s = session()
        guard let cfg = launcher.talkConfiguration(for: s) else { return XCTFail("bound launcher gives a configuration") }
        XCTAssertEqual(cfg.toolNames, CallScript.callTools)
        XCTAssertEqual(cfg.opening, CallScript.opening(s, now: Self.now))
        XCTAssertTrue(cfg.primer.contains(cfg.opening))
        let r = await cfg.runTool("snooze_call", #"{"minutes":15}"#)
        XCTAssertTrue(r.hasPrefix("ok: I'll call back in 15 minutes"))
        XCTAssertEqual(fallbackSnoozes.map(\.callId), [Self.callId])
        XCTAssertEqual(fallbackSnoozes.map(\.minutes), [15])
        XCTAssertTrue(snoozes.isEmpty, "no CallKit call to snooze")
        XCTAssertTrue(sessions.isEmpty, "the Talk screen owns its own session")
        let complete = await cfg.runTool("complete_task", "{}")
        let create = await cfg.runTool("create_task", "{}")
        XCTAssertEqual(complete, "ok: complete_task")
        XCTAssertEqual(create, "error: create_task isn't available during a call")
        XCTAssertNil(RealtimeCallVoiceLauncher().talkConfiguration(for: s), "unbound → nil")
    }

    func testPendingSessionIsTakenOnce() {
        XCTAssertNil(launcher.takePendingSession())
        let s = session()
        launcher.pendingSession = s
        XCTAssertEqual(launcher.takePendingSession(), s)
        XCTAssertNil(launcher.pendingSession)
        XCTAssertNil(launcher.takePendingSession())
    }

    // MARK: - audio session ownership (the silent-call rule)

    func testCallKitOwnershipNeverActivatesOrDeactivatesTheAudioSession() {
        let control = FakeAudioSessionControl()
        let engine = VoiceAudioEngine(sessionOwnership: .callKit, sessionControl: control)
        XCTAssertTrue(engine.activateSession())
        XCTAssertEqual(control.setActiveCalls, [], "CallKit activates — never setActive(true)")
        XCTAssertEqual(control.configured, [VoiceAudioEngine.callKitSessionOptions], "category/mode only, same options as the CallKit bridge")
        XCTAssertFalse(VoiceAudioEngine.callKitSessionOptions.contains(.defaultToSpeaker), "the route is the user's CallKit choice")
        engine.deactivateSession()
        engine.shutdown()
        XCTAssertEqual(control.setActiveCalls, [], "CallKit deactivates — never setActive(false)")
    }

    func testAppOwnershipKeepsTalkModeActivation() {
        let control = FakeAudioSessionControl()
        let engine = VoiceAudioEngine(sessionOwnership: .app, sessionControl: control)
        XCTAssertTrue(engine.activateSession())
        XCTAssertEqual(control.configured, [VoiceAudioEngine.talkSessionOptions])
        XCTAssertTrue(VoiceAudioEngine.talkSessionOptions.contains(.defaultToSpeaker))
        XCTAssertEqual(control.setActiveCalls, [true])
        engine.deactivateSession()
        XCTAssertEqual(control.setActiveCalls, [true, false])
        // The default engine is Talk mode.
        XCTAssertEqual(VoiceAudioEngine().sessionOwnership, .app)
    }
}
