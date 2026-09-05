// CallCoordinator state-machine tests — no CallKit / PushKit / network:
// every seam (provider, controller, launcher, notifier, outcome reporter,
// environment, clock) is a fake. Asserts the ios-gateway-plan C1 rules:
//   report → answer → didActivate → launcher starts (never before activation),
//   unanswered after 30 s → .unanswered + "I called about …" notification,
//   busy (focus live) / stale (anchor gone) / outside-hours receipt rules,
//   snooze (call-level) → outcome snoozed + hang-up, user hang-up → done,
//   invalid payload → report then .failed, DND-filtered report → missed,
//   mute forwarded, late launcher attach, provider reset,
//   a DUPLICATE push (same callId) is a state no-op,
//   ONE end transaction + ONE outcome however many things end the call
//   (the CXEndCallAction completes ASYNCHRONOUSLY, like CallKit),
//   nobody signed in → dropped silently,
//   the outcome reporter persists, flushes in order and retries.

import XCTest
import UnstuckSync
@testable import Unstuck

// MARK: - Fakes

@MainActor
final class FakeCallProvider: CallProviding {
    struct Incoming { let uuid: UUID; let callerName: String }
    var incoming: [Incoming] = []
    var ended: [(uuid: UUID, reason: CallEndedReason)] = []
    var configured = 0
    private var completions: [UUID: [@MainActor (Error?) -> Void]] = [:]

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (Error?) -> Void) {
        incoming.append(Incoming(uuid: uuid, callerName: callerName))
        completions[uuid, default: []].append(completion)
    }
    func reportEnded(uuid: UUID, reason: CallEndedReason) { ended.append((uuid, reason)) }
    func configureAudioSession() { configured += 1 }
    /// Simulate CallKit finishing the LATEST reportNewIncomingCall for `uuid`
    /// (nil = presented).
    func complete(_ uuid: UUID, error: Error?) { completions[uuid]?.last?(error) }
}

/// Like CallKit: `CXCallController.request` returns at once and the
/// CXEndCallAction + the completion land LATER (a separate main-queue hop).
/// `flush()` delivers everything queued, in order — so the tests exercise the
/// window between "asked CallKit to end" and "CallKit ended it".
@MainActor
final class FakeCallController: CallControlling {
    weak var coordinator: CallCoordinator?
    var requested: [UUID] = []
    var failNext = false
    private var pending: [@MainActor () -> Void] = []
    var pendingCount: Int { pending.count }

    func requestEnd(uuid: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        requested.append(uuid)
        let fail = failNext
        failNext = false
        pending.append { [weak self] in
            if fail { completion(NSError(domain: "cx", code: 1)); return }
            _ = self?.coordinator?.performEnd(uuid: uuid)
            completion(nil)
        }
    }
    func flush() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

@MainActor
final class FakeLauncher: CallVoiceLauncher {
    var started: [CallSession] = []
    var stops = 0
    var muted: Bool?
    private var onEnded: (@MainActor (CallEndReason) -> Void)?
    func start(_ session: CallSession, onEnded: @escaping @MainActor (CallEndReason) -> Void) {
        started.append(session); self.onEnded = onEnded
    }
    func stop() { stops += 1; onEnded = nil }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func end(_ reason: CallEndReason) { let h = onEnded; onEnded = nil; h?(reason) }
}

@MainActor
final class FakeNotifier: CallNotifier {
    var posted: [CallNotification] = []
    func post(_ n: CallNotification) { posted.append(n) }
}

@MainActor
final class FakeReporter: CallOutcomeReporting {
    struct Report: Equatable { let callId: String; let callKitId: UUID?; let outcome: CallOutcome; let snooze: Int?; let notes: [String]? }
    var reports: [Report] = []
    var discards = 0
    func report(callId: String, callKitId: UUID?, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?) {
        reports.append(Report(callId: callId, callKitId: callKitId, outcome: outcome, snooze: snoozeMinutes, notes: outcomeNotes))
    }
    func discardAll() { discards += 1 }
    var outcomes: [CallOutcome] { reports.map(\.outcome) }
}

@MainActor
final class FakeEnvironment: CallEnvironment {
    var signedIn = true
    /// false = the killed-state proxy (no AppModel yet) — `isSignedIn` is
    /// then only "a VoIP token is stored".
    var sessionKnown = true
    var focusLive = false
    var anchorLive = true
    var withinHours = true
    var isSignedIn: Bool { signedIn }
    var isSessionKnown: Bool { sessionKnown }
    var isFocusSessionLive: Bool { focusLive }
    func anchorIsLive(taskId: String?, blockId: String?) -> Bool { anchorLive }
    func isWithinCallHours(_ date: Date) -> Bool { withinHours }
}

@MainActor
final class FakeClock: CallClock {
    final class Timer: CallTimer {
        let seconds: TimeInterval
        var block: (@MainActor () -> Void)?
        var cancelled = false
        init(_ s: TimeInterval, _ b: @escaping @MainActor () -> Void) { seconds = s; block = b }
        func cancel() { cancelled = true; block = nil }
    }
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var timers: [Timer] = []
    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> CallTimer {
        let t = Timer(seconds, block); timers.append(t); return t
    }
    var pending: [Timer] { timers.filter { !$0.cancelled && $0.block != nil } }
    func fire(_ t: Timer) { let b = t.block; t.block = nil; b?() }
    func fireAll() { pending.forEach { fire($0) } }
}

// MARK: - Harness

@MainActor
final class CallCoordinatorTests: XCTestCase {
    var provider: FakeCallProvider!
    var controller: FakeCallController!
    var launcher: FakeLauncher!
    var notifier: FakeNotifier!
    var reporter: FakeReporter!
    var env: FakeEnvironment!
    var clock: FakeClock!
    var sut: CallCoordinator!

    static let callId = "0f1e2d3c-4b5a-4697-8877-665544332211"

    override func setUp() {
        super.setUp()
        provider = FakeCallProvider(); controller = FakeCallController(); launcher = FakeLauncher()
        notifier = FakeNotifier(); reporter = FakeReporter(); env = FakeEnvironment(); clock = FakeClock()
        sut = CallCoordinator(provider: provider, controller: controller, environment: env,
                              launcher: launcher, launcherAttached: true,
                              notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = sut
    }

    func payload(taskId: String? = "task-1", notes: [String] = ["Ask about the invoice", "Confirm Friday"]) -> IncomingCallPayload {
        IncomingCallPayload(callId: Self.callId, label: "speak to James", notes: notes,
                            taskId: taskId, blockId: taskId == nil ? nil : "block-1",
                            taskName: "Speak to James", startTime: nil, firstAction: "open the thread",
                            captures: [], name: "Ahmad")
    }

    var uuid: UUID { UUID(uuidString: Self.callId)! }

    /// report → answer → didActivate.
    func answerAndActivate() {
        sut.reportIncoming(payload())
        XCTAssertTrue(sut.performAnswer(uuid: uuid))
        sut.audioSessionDidActivate()
    }

    // MARK: - report / answer / activate

    func testReportIsSynchronousAndUsesCallIdAsUUID() {
        sut.reportIncoming(payload())
        XCTAssertEqual(provider.incoming.count, 1)
        XCTAssertEqual(provider.incoming[0].uuid, uuid)
        XCTAssertEqual(provider.incoming[0].callerName, "Unstuck · speak to James")
        XCTAssertEqual(sut.active?.phase, .ringing)
        XCTAssertEqual(clock.pending.count, 1)
        XCTAssertEqual(clock.pending[0].seconds, CallCoordinator.ringTimeout)
        XCTAssertTrue(provider.ended.isEmpty)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testAnswerWaitsForAudioActivationBeforeStartingLauncher() {
        sut.reportIncoming(payload())
        XCTAssertTrue(sut.performAnswer(uuid: uuid))
        XCTAssertEqual(provider.configured, 1, "category/mode configured before fulfil")
        XCTAssertEqual(sut.active?.phase, .answering)
        XCTAssertEqual(reporter.outcomes, [.answered])
        XCTAssertTrue(clock.pending.isEmpty, "ring timer cancelled on answer")
        XCTAssertTrue(launcher.started.isEmpty, "NO audio before didActivate")

        sut.audioSessionDidActivate()
        XCTAssertEqual(launcher.started.count, 1)
        XCTAssertEqual(launcher.started[0].callId, Self.callId)
        XCTAssertEqual(sut.active?.phase, .active)
    }

    func testAnswerForUnknownUUIDIsRefused() {
        sut.reportIncoming(payload())
        XCTAssertFalse(sut.performAnswer(uuid: UUID()))
        XCTAssertEqual(sut.active?.phase, .ringing)
    }

    func testEveryReportCarriesTheCallKitId() {
        answerAndActivate()
        XCTAssertTrue(sut.performEnd(uuid: uuid))
        XCTAssertEqual(reporter.reports.map(\.callKitId), [uuid, uuid])
        XCTAssertEqual(reporter.reports.map(\.callId), [Self.callId, Self.callId])
    }

    // MARK: - duplicate push (same callId ⇒ same UUID)

    func testDuplicatePushWhileRingingIsAStateNoOp() {
        sut.reportIncoming(payload())
        let timer = clock.pending[0]
        sut.reportIncoming(payload())   // APNs retried / the server re-sent
        XCTAssertEqual(provider.incoming.count, 2, "Apple rule: a report per push")
        XCTAssertEqual(sut.active?.phase, .ringing)
        XCTAssertEqual(clock.pending.count, 1, "the SAME ring timer, not a fresh 30 s")
        XCTAssertTrue(clock.pending[0] === timer)
        XCTAssertTrue(provider.ended.isEmpty)
        XCTAssertTrue(reporter.reports.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
        // CallKit answers the second report with callUUIDAlreadyExists — swallowed.
        provider.complete(uuid, error: NSError(domain: "CXErrorDomainIncomingCall", code: 2))
        XCTAssertEqual(sut.active?.phase, .ringing, "not treated as missed")
        XCTAssertTrue(reporter.reports.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
        // Still answerable, exactly once.
        XCTAssertTrue(sut.performAnswer(uuid: uuid))
        XCTAssertEqual(reporter.outcomes, [.answered])
    }

    func testDuplicatePushWhileAnsweredLeavesTheLauncherUntouched() {
        answerAndActivate()
        sut.reportIncoming(payload())
        provider.complete(uuid, error: NSError(domain: "CXErrorDomainIncomingCall", code: 2))
        XCTAssertEqual(provider.incoming.count, 2)
        XCTAssertEqual(sut.active?.phase, .active)
        XCTAssertEqual(sut.active?.launcherRunning, true)
        XCTAssertEqual(launcher.started.count, 1, "no restart")
        XCTAssertEqual(launcher.stops, 0)
        XCTAssertEqual(reporter.outcomes, [.answered], "no busy / missed for the duplicate")
        XCTAssertTrue(provider.ended.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    // MARK: - unanswered

    func testUnansweredAfterThirtySecondsNotifiesWithNotesAndActions() {
        sut.reportIncoming(payload())
        clock.fireAll()
        XCTAssertEqual(provider.ended.count, 1)
        XCTAssertEqual(provider.ended[0].reason, .unanswered)
        XCTAssertEqual(reporter.outcomes, [.missed])
        XCTAssertNil(sut.active)
        XCTAssertEqual(notifier.posted.count, 1)
        let n = notifier.posted[0]
        XCTAssertEqual(n.title, "I called about speak to James")
        XCTAssertEqual(n.body, "Ask about the invoice\nConfirm Friday")
        XCTAssertEqual(n.categoryId, NotificationCategories.taskStarting)
        XCTAssertEqual(n.userInfo["taskId"], "task-1")
        XCTAssertEqual(n.userInfo["blockId"], "block-1")
        XCTAssertEqual(n.userInfo["deepLink"], "unstuck://task/task-1")
        XCTAssertTrue(n.timeSensitive)
    }

    func testUnansweredWithoutTaskHasNoActionsAndOpensToday() {
        sut.reportIncoming(payload(taskId: nil))
        clock.fireAll()
        let n = notifier.posted[0]
        XCTAssertNil(n.categoryId)
        XCTAssertEqual(n.userInfo["deepLink"], "unstuck://today")
        XCTAssertNil(n.userInfo["taskId"])
    }

    func testUnansweredWithNoNotesSaysSo() {
        sut.reportIncoming(payload(notes: []))
        clock.fireAll()
        XCTAssertEqual(notifier.posted[0].body, "No notes on this one.")
    }

    // MARK: - receipt rules

    func testBusyRuleWhenFocusSessionLive() {
        env.focusLive = true
        sut.reportIncoming(payload())
        XCTAssertEqual(provider.incoming.count, 1, "still reported (Apple rule)")
        XCTAssertEqual(provider.ended.map(\.reason), [.answeredElsewhere])
        XCTAssertEqual(reporter.outcomes, [.busy])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].title, "I called about speak to James — you were mid-focus")
        XCTAssertNil(sut.active)
        XCTAssertTrue(clock.pending.isEmpty, "no ring timer")
    }

    func testStaleRuleWhenAnchorGoneIsSilent() {
        env.anchorLive = false
        sut.reportIncoming(payload())
        XCTAssertEqual(provider.ended.map(\.reason), [.remoteEnded])
        XCTAssertEqual(reporter.outcomes, [.stale])
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertNil(sut.active)
    }

    func testOutsideCallHoursDeclinesQuietlyWithNotification() {
        env.withinHours = false
        env.focusLive = true   // hours rule wins (evaluated first)
        sut.reportIncoming(payload())
        XCTAssertEqual(provider.ended.map(\.reason), [.declinedElsewhere])
        XCTAssertEqual(reporter.outcomes, [.declined])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(notifier.posted[0].body.contains("outside your call hours"))
    }

    func testInvalidPayloadStillReportsThenFails() {
        sut.reportIncoming(dictionary: ["aps": ["alert": "x"], "foo": 1])
        XCTAssertEqual(provider.incoming.count, 1)
        XCTAssertEqual(provider.incoming[0].callerName, "Unstuck")
        XCTAssertEqual(provider.ended.count, 1)
        XCTAssertEqual(provider.ended[0].reason, .failed)
        XCTAssertEqual(provider.ended[0].uuid, provider.incoming[0].uuid)
        XCTAssertTrue(reporter.reports.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertNil(sut.active)
    }

    func testValidDictionaryPayloadDecodesTopLevelAndNested() {
        sut.reportIncoming(dictionary: [
            "aps": ["content-available": 1],
            "callId": Self.callId, "label": "speak to James", "notes": ["A"],
        ])
        XCTAssertEqual(sut.active?.session.notes, ["A"])
        sut.providerDidReset()
        sut.reportIncoming(dictionary: [
            "aps": ["alert": "call"],
            "data": ["kind": "call", "callId": Self.callId, "label": "nested", "notes": ["B", "C"]],
        ])
        XCTAssertEqual(sut.active?.session.label, "nested")
        XCTAssertEqual(sut.active?.session.notes, ["B", "C"])
    }

    func testReportFailureWhileRingingIsMissed() {
        sut.reportIncoming(payload())
        provider.complete(uuid, error: NSError(domain: "CXErrorDomainIncomingCall", code: 5))   // filteredByDoNotDisturb
        XCTAssertNil(sut.active)
        XCTAssertEqual(reporter.outcomes, [.missed])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testReportSuccessCompletionIsNoop() {
        sut.reportIncoming(payload())
        provider.complete(uuid, error: nil)
        XCTAssertEqual(sut.active?.phase, .ringing)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testSecondCallWhileOneIsActiveIsBusy() {
        answerAndActivate()
        var second = payload()
        second.callId = "11111111-2222-4333-8444-555555555555"
        sut.reportIncoming(second)
        XCTAssertEqual(provider.incoming.count, 2)
        XCTAssertEqual(provider.ended.last?.uuid, UUID(uuidString: second.callId))
        XCTAssertEqual(provider.ended.last?.reason, .answeredElsewhere)
        XCTAssertEqual(reporter.reports.last?.outcome, .busy)
        XCTAssertEqual(reporter.reports.last?.callKitId, UUID(uuidString: second.callId))
        XCTAssertEqual(sut.active?.session.callId, Self.callId, "first call untouched")
    }

    // MARK: - nobody signed in (reactive sign-out left the token registered)

    func testSignedOutDeviceDropsTheCallSilently() {
        env.signedIn = false
        sut.reportIncoming(payload())
        XCTAssertEqual(provider.incoming.count, 1, "still reported (Apple rule)")
        XCTAssertEqual(provider.ended.map(\.reason), [.failed])
        XCTAssertNil(sut.active)
        XCTAssertTrue(reporter.reports.isEmpty, "no JWT to report with")
        XCTAssertTrue(notifier.posted.isEmpty, "never the previous account's notes")
        XCTAssertTrue(clock.pending.isEmpty)
        XCTAssertFalse(sut.performAnswer(uuid: uuid))

        sut.handleFallbackTap(payload())
        XCTAssertNil(sut.pendingFallback)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testSignedOutTeardownIsSilent() {
        answerAndActivate()
        sut.signedOut()
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertEqual(provider.ended.map(\.reason), [.failed])
        XCTAssertNil(sut.active)
        XCTAssertEqual(reporter.outcomes, [.answered], "nothing reported on the way out")
        XCTAssertEqual(reporter.discards, 1, "whatever is still queued belongs to the old session — dropped, on disk too")
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertTrue(clock.pending.isEmpty)
        // A late CXEndCallAction for the torn-down call is harmless.
        XCTAssertFalse(sut.performEnd(uuid: uuid))
    }

    // MARK: - sign-in within one launch re-arms PushKit

    func testSignedInRearmsVoip() {
        var rearms = 0
        let c = CallCoordinator(provider: provider, controller: controller, environment: env,
                                launcher: launcher, launcherAttached: true,
                                notifier: notifier, reporter: reporter, clock: clock,
                                rearmVoip: { rearms += 1 })
        c.signedIn()
        c.signedIn()
        XCTAssertEqual(rearms, 2, "every sign-in transition re-arms (rearm itself is a no-op while registered)")
        XCTAssertNil(c.authWatch, "no auth watch until attach(model:client:)")
    }

    // MARK: - fallback B (alert tap) on a killed-state launch

    func testFallbackTapBeforeTheSessionIsKnownIsDeferredNotDropped() {
        // PushAppDelegate fires before AppModel.start(): the environment only
        // has the killed-state proxy, which is FALSE precisely when the server
        // used the alert transport (no VoIP token). The tap must wait.
        env.sessionKnown = false
        env.signedIn = false
        sut.handleFallbackTap(payload())
        XCTAssertNotNil(sut.deferredFallbackTap)
        XCTAssertNil(sut.pendingFallback)
        XCTAssertTrue(reporter.reports.isEmpty, "nothing decided yet")
        // The real session arrives (attach(model:) → attach(environment:)).
        let real = FakeEnvironment()
        real.signedIn = true
        sut.attach(environment: real)
        XCTAssertNil(sut.deferredFallbackTap)
        XCTAssertEqual(reporter.outcomes, [.answered])
        XCTAssertEqual(sut.pendingFallback?.callId, Self.callId, "handed to Talk (buffered until the handler is set)")
    }

    func testDeferredFallbackTapIsDroppedWhenTheRealSessionIsSignedOut() {
        env.sessionKnown = false
        sut.handleFallbackTap(payload())
        XCTAssertNotNil(sut.deferredFallbackTap)
        let real = FakeEnvironment()
        real.signedIn = false
        sut.attach(environment: real)
        XCTAssertNil(sut.deferredFallbackTap)
        XCTAssertNil(sut.pendingFallback)
        XCTAssertTrue(reporter.reports.isEmpty, "nobody signed in → dropped, silently")
    }

    func testAttachWithAStillUnknownSessionKeepsTheDeferredTap() {
        env.sessionKnown = false
        sut.handleFallbackTap(payload())
        let stillProxy = FakeEnvironment()
        stillProxy.sessionKnown = false
        sut.attach(environment: stillProxy)
        XCTAssertNotNil(sut.deferredFallbackTap)
        XCTAssertTrue(reporter.reports.isEmpty)
        sut.signedOut()
        XCTAssertNil(sut.deferredFallbackTap, "sign-out forgets it")
    }

    func testFallbackSnoozeGoesThroughThePersistedReporterClamped() {
        sut.handleFallbackTap(payload())
        sut.reportFallbackSnooze(callId: Self.callId, minutes: 15)
        XCTAssertEqual(reporter.reports.last, FakeReporter.Report(callId: Self.callId, callKitId: nil, outcome: .snoozed, snooze: 15, notes: nil))
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed], "ordered after the tap's answered")
        sut.reportFallbackSnooze(callId: Self.callId, minutes: 0)
        XCTAssertEqual(reporter.reports.last?.snooze, 1)
        sut.reportFallbackSnooze(callId: Self.callId, minutes: 999)
        XCTAssertEqual(reporter.reports.last?.snooze, 180)
    }

    // MARK: - ending

    func testUserHangUpStopsLauncherAndReportsDone() {
        answerAndActivate()
        XCTAssertTrue(sut.performEnd(uuid: uuid))
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertNil(sut.active)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testDeclineWhileRingingIsLoggedWithoutNotification() {
        sut.reportIncoming(payload())
        XCTAssertTrue(sut.performEnd(uuid: uuid))
        XCTAssertEqual(reporter.outcomes, [.declined])
        XCTAssertTrue(launcher.started.isEmpty)
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    /// The CXEndCallAction is ASYNC: between snoozeActiveCall and CallKit's
    /// action the call is still up with `pendingEnd` set; nothing is reported
    /// until the action lands, then exactly once.
    func testSnoozeReportsSnoozedWithMinutesAndHangsUp() {
        answerAndActivate()
        let result = sut.snoozeActiveCall(minutes: 10)
        XCTAssertTrue(result.hasPrefix("ok:"), result)
        XCTAssertTrue(result.contains("10 minutes"))
        XCTAssertEqual(controller.requested, [uuid])
        XCTAssertEqual(sut.active?.pendingEnd, .snoozed(minutes: 10))
        XCTAssertEqual(launcher.stops, 0, "the launcher keeps talking until CallKit ends the call")
        XCTAssertEqual(reporter.outcomes, [.answered], "nothing reported before the action lands")

        controller.flush()
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertEqual(reporter.reports.last, FakeReporter.Report(callId: Self.callId, callKitId: uuid, outcome: .snoozed, snooze: 10, notes: nil))
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
        XCTAssertNil(sut.active)
    }

    func testSnoozeClampsAndRefusesWhenNoCall() {
        XCTAssertEqual(sut.snoozeActiveCall(minutes: 10), "error: no call is active")
        sut.reportIncoming(payload())
        XCTAssertEqual(sut.snoozeActiveCall(minutes: 10), "error: no call is active", "not while ringing")
        XCTAssertTrue(sut.performAnswer(uuid: uuid)); sut.audioSessionDidActivate()
        _ = sut.snoozeActiveCall(minutes: 999)
        controller.flush()
        XCTAssertEqual(reporter.reports.last?.snooze, 180)
    }

    /// The race the launcher used to lose: snooze_call → the coordinator's
    /// hang-up is in flight, and the launcher's session also ends (the model
    /// says goodbye, the socket closes) BEFORE CallKit's CXEndCallAction
    /// lands. One end transaction, one outcome — never two.
    func testSnoozeThenLauncherEndingIsOneEndAndOneOutcome() {
        answerAndActivate()
        _ = sut.snoozeActiveCall(minutes: 10)
        XCTAssertEqual(controller.requested.count, 1)
        launcher.end(.hungUp)                       // launcher confirms on its own, mid-flight
        XCTAssertEqual(controller.requested.count, 1, "no second CXEndCallAction")
        XCTAssertEqual(sut.active?.pendingEnd, .snoozed(minutes: 10), "the snooze wins, not the later hang-up")
        controller.flush()
        XCTAssertEqual(controller.requested.count, 1)
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
        XCTAssertEqual(reporter.reports.last?.snooze, 10)
        XCTAssertEqual(launcher.stops, 0, "the launcher already stopped itself — no double stop")
        XCTAssertNil(sut.active)
        // A straggler CXEndCallAction after the fact is ignored, not re-reported.
        XCTAssertFalse(sut.performEnd(uuid: uuid))
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
    }

    func testDoubleSnoozeIsOneEndTransaction() {
        answerAndActivate()
        let a = sut.snoozeActiveCall(minutes: 10)
        let b = sut.snoozeActiveCall(minutes: 25)
        XCTAssertTrue(a.hasPrefix("ok:"))
        XCTAssertTrue(b.hasPrefix("ok:"))
        XCTAssertTrue(b.contains("10 minutes"), "the second snooze repeats the first, it can't change it")
        XCTAssertEqual(controller.requested.count, 1)
        controller.flush()
        XCTAssertEqual(reporter.outcomes, [.answered, .snoozed])
        XCTAssertEqual(reporter.reports.last?.snooze, 10)
    }

    func testLauncherEndingItselfHangsUpAndReportsDone() {
        answerAndActivate()
        launcher.end(.hungUp)
        XCTAssertEqual(controller.requested, [uuid])
        XCTAssertEqual(reporter.outcomes, [.answered], "reported when CallKit ends it, not before")
        controller.flush()
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertEqual(launcher.stops, 0, "launcher already stopped itself — no double stop")
        XCTAssertNil(sut.active)
    }

    func testLauncherFailureNotifiesWithNotes() {
        answerAndActivate()
        launcher.end(.failed("socket closed"))
        controller.flush()
        XCTAssertEqual(reporter.reports.last?.outcome, .done)
        XCTAssertEqual(reporter.reports.last?.notes, ["voice failed: socket closed"])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].title, "Couldn't start the call — here's what it was about")
        XCTAssertEqual(notifier.posted[0].body, "Ask about the invoice\nConfirm Friday")
    }

    func testEndTransactionFailureSettlesLocally() {
        answerAndActivate()
        controller.failNext = true
        launcher.end(.hungUp)
        controller.flush()
        XCTAssertEqual(provider.ended.map(\.reason), [.remoteEnded])
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertNil(sut.active)
    }

    func testMuteIsForwardedToLauncher() {
        answerAndActivate()
        XCTAssertTrue(sut.performSetMuted(uuid: uuid, muted: true))
        XCTAssertEqual(launcher.muted, true)
        XCTAssertEqual(sut.active?.muted, true)
        XCTAssertFalse(sut.performSetMuted(uuid: UUID(), muted: true))
    }

    func testAudioDeactivationStopsLauncherButKeepsCallUntilEndAction() {
        answerAndActivate()
        sut.audioSessionDidDeactivate()
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertNotNil(sut.active)
        XCTAssertTrue(sut.performEnd(uuid: uuid))
        XCTAssertEqual(launcher.stops, 1, "not stopped twice")
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
    }

    func testProviderResetClearsEverything() {
        answerAndActivate()
        sut.providerDidReset()
        XCTAssertNil(sut.active)
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    // MARK: - killed-state launch: launcher attached late

    func testAnswerBeforeLauncherAttachedWaitsThenStarts() {
        let late = CallCoordinator(provider: provider, controller: controller, environment: env,
                                   launcher: NoopCallVoiceLauncher(), launcherAttached: false,
                                   notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = late
        late.reportIncoming(payload())
        XCTAssertTrue(late.performAnswer(uuid: uuid))
        late.audioSessionDidActivate()
        XCTAssertEqual(late.active?.phase, .answering, "waiting for a launcher")
        XCTAssertEqual(clock.pending.count, 1)
        XCTAssertEqual(clock.pending[0].seconds, CallCoordinator.launcherGrace)

        late.attach(launcher: launcher)
        XCTAssertEqual(launcher.started.count, 1)
        XCTAssertEqual(late.active?.phase, .active)
        XCTAssertTrue(clock.pending.isEmpty, "grace timer cancelled")
    }

    func testAnswerWithNoLauncherDegradesAfterGrace() {
        let late = CallCoordinator(provider: provider, controller: controller, environment: env,
                                   launcher: NoopCallVoiceLauncher(), launcherAttached: false,
                                   notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = late
        late.reportIncoming(payload())
        XCTAssertTrue(late.performAnswer(uuid: uuid))
        late.audioSessionDidActivate()
        clock.fireAll()
        controller.flush()
        XCTAssertNil(late.active)
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertEqual(reporter.reports.last?.notes, ["voice failed: voice unavailable"])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].title, "Couldn't start the call — here's what it was about")
    }

    func testNoopLauncherEndsCallAsFailedWithNotes() {
        let noop = CallCoordinator(provider: provider, controller: controller, environment: env,
                                   launcher: NoopCallVoiceLauncher(), launcherAttached: true,
                                   notifier: notifier, reporter: reporter, clock: clock)
        controller.coordinator = noop
        noop.reportIncoming(payload())
        XCTAssertTrue(noop.performAnswer(uuid: uuid))
        noop.audioSessionDidActivate()
        XCTAssertEqual(controller.requested.count, 1)
        controller.flush()
        XCTAssertNil(noop.active)
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertEqual(notifier.posted.count, 1)
    }

    // MARK: - fallback B

    func testFallbackTapBuffersUntilHandlerSet() {
        sut.handleFallbackTap(payload())
        XCTAssertNotNil(sut.pendingFallback)
        XCTAssertEqual(reporter.outcomes, [.answered])
        var got: CallSession?
        sut.onFallbackAnswer = { got = $0 }
        XCTAssertEqual(got?.callId, Self.callId)
        XCTAssertNil(sut.pendingFallback)
    }
}

// MARK: - CallsOutcomeReporter (persisted, ordered, retried)

@MainActor
final class CallsOutcomeReporterTests: XCTestCase {
    /// Records sends; throws (transient) for the first `failures` calls, and
    /// answers a PERMANENT `CallOutcomeRejected` for any callId in `rejected`.
    @MainActor
    final class Recorder {
        var sent: [CallsOutcomeReporter.Item] = []
        var attempts = 0
        var failures: Int
        var rejected: [String: Int] = [:]
        init(failures: Int = 0, rejected: [String: Int] = [:]) { self.failures = failures; self.rejected = rejected }
        func sender() -> CallsOutcomeReporter.Sender {
            { [self] item in
                await MainActor.run { self.attempts += 1 }
                if let code = await MainActor.run(body: { self.rejected[item.callId] }) {
                    throw CallOutcomeRejected(status: code, message: "not_found")
                }
                let fail = await MainActor.run { () -> Bool in
                    if self.failures > 0 { self.failures -= 1; return true }
                    return false
                }
                if fail { throw NSError(domain: "net", code: 1) }
                await MainActor.run { self.sent.append(item) }
            }
        }
    }

    @MainActor
    final class SleepLog {
        var delays: [TimeInterval] = []
        func sleeper() -> @Sendable (TimeInterval) async -> Void {
            { [self] s in await MainActor.run { self.delays.append(s) } }
        }
    }

    private var suite: UserDefaults!
    private var suiteName = ""
    private let uuid = UUID(uuidString: "0f1e2d3c-4b5a-4697-8877-665544332211")!

    override func setUp() {
        super.setUp()
        suiteName = "CallsOutcomeReporterTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func settle(_ r: CallsOutcomeReporter) async {
        while let t = r.flushTask { await t.value }
    }

    func testQueuedBeforeAttachIsPersistedAndFlushedInOrder() async {
        let first = CallsOutcomeReporter(defaults: suite, sleep: { _ in })
        first.report(callId: "c1", callKitId: uuid, outcome: .answered, snoozeMinutes: nil, outcomeNotes: nil)
        first.report(callId: "c1", callKitId: uuid, outcome: .done, snoozeMinutes: nil, outcomeNotes: ["voice failed: x"])
        XCTAssertEqual(first.queue.count, 2, "no client yet → held")
        XCTAssertNotNil(suite.data(forKey: CallsOutcomeReporter.queueKey), "persisted the moment it's queued")

        // A relaunch: the queue comes back from disk and flushes once attached.
        let relaunch = CallsOutcomeReporter(defaults: suite, sleep: { _ in })
        XCTAssertEqual(relaunch.queue.map(\.outcome), [.answered, .done])
        let rec = Recorder()
        relaunch.attach(send: rec.sender())
        await settle(relaunch)
        XCTAssertEqual(rec.sent.map(\.outcome), [.answered, .done], "in order")
        XCTAssertEqual(rec.sent.first?.callKitId, uuid.uuidString.lowercased())
        XCTAssertEqual(rec.sent.last?.notes, ["voice failed: x"])
        XCTAssertTrue(relaunch.queue.isEmpty)
        XCTAssertNil(suite.data(forKey: CallsOutcomeReporter.queueKey), "drained → nothing on disk")
    }

    func testRetriesWithBackoffThenSucceeds() async {
        let log = SleepLog()
        let r = CallsOutcomeReporter(defaults: suite, sleep: log.sleeper())
        let rec = Recorder(failures: 2)
        r.attach(send: rec.sender())
        r.report(callId: "c1", callKitId: uuid, outcome: .missed, snoozeMinutes: nil, outcomeNotes: nil)
        r.report(callId: "c2", callKitId: nil, outcome: .snoozed, snoozeMinutes: 10, outcomeNotes: nil)
        await settle(r)
        XCTAssertEqual(rec.attempts, 4, "2 failures + success for c1, then c2")
        XCTAssertEqual(log.delays, [2, 5], "backoff between attempts")
        XCTAssertEqual(rec.sent.map(\.callId), ["c1", "c2"], "c2 waits for c1 — never reordered")
        XCTAssertEqual(rec.sent.last?.snooze, 10)
        XCTAssertTrue(r.queue.isEmpty)
    }

    func testAPermanentRejectionDropsThatItemAndTheDrainContinues() async {
        // A 404 for a callId (row deleted server-side, or another account's
        // report) used to sit at the head forever, holding every later
        // outcome hostage. Now it is dropped (logged) at once — no backoff —
        // and the next items land.
        let log = SleepLog()
        let r = CallsOutcomeReporter(defaults: suite, sleep: log.sleeper())
        let rec = Recorder(rejected: ["dead": 404])
        r.attach(send: rec.sender())
        r.report(callId: "dead", callKitId: uuid, outcome: .answered, snoozeMinutes: nil, outcomeNotes: nil)
        r.report(callId: "c2", callKitId: nil, outcome: .missed, snoozeMinutes: nil, outcomeNotes: nil)
        r.report(callId: "c3", callKitId: nil, outcome: .snoozed, snoozeMinutes: 20, outcomeNotes: nil)
        await settle(r)
        XCTAssertEqual(rec.sent.map(\.callId), ["c2", "c3"], "the dead item is gone, the rest flushed in order")
        XCTAssertEqual(rec.attempts, 3, "no retries for a permanent refusal")
        XCTAssertTrue(log.delays.isEmpty, "no backoff either")
        XCTAssertTrue(r.queue.isEmpty)
        XCTAssertNil(suite.data(forKey: CallsOutcomeReporter.queueKey))
        XCTAssertEqual(r.dropped.map(\.item.callId), ["dead"])
        XCTAssertEqual((r.dropped.first?.error as? CallOutcomeRejected)?.status, 404)
    }

    func testATransientFailureStillRetriesAfterADroppedItem() async {
        let log = SleepLog()
        let r = CallsOutcomeReporter(defaults: suite, sleep: log.sleeper())
        let rec = Recorder(failures: 1, rejected: ["dead": 422])
        r.attach(send: rec.sender())
        r.report(callId: "dead", callKitId: nil, outcome: .done, snoozeMinutes: nil, outcomeNotes: nil)
        r.report(callId: "c2", callKitId: nil, outcome: .done, snoozeMinutes: nil, outcomeNotes: nil)
        await settle(r)
        XCTAssertEqual(rec.sent.map(\.callId), ["c2"])
        XCTAssertEqual(rec.attempts, 3, "dead ×1, c2 fails once then lands")
        XCTAssertEqual(log.delays, [2])
    }

    func testDiscardAllForgetsTheQueueInMemoryAndOnDisk() async {
        let r = CallsOutcomeReporter(defaults: suite, sleep: { _ in })
        r.report(callId: "c1", callKitId: uuid, outcome: .answered, snoozeMinutes: nil, outcomeNotes: nil)
        r.report(callId: "c1", callKitId: uuid, outcome: .done, snoozeMinutes: nil, outcomeNotes: nil)
        XCTAssertEqual(r.queue.count, 2)
        XCTAssertNotNil(suite.data(forKey: CallsOutcomeReporter.queueKey))
        r.discardAll()
        XCTAssertTrue(r.queue.isEmpty)
        XCTAssertNil(suite.data(forKey: CallsOutcomeReporter.queueKey), "nothing carries into the next account")
        // A relaunch finds nothing to replay.
        XCTAssertTrue(CallsOutcomeReporter(defaults: suite, sleep: { _ in }).queue.isEmpty)
        // A later report on the new session still flows.
        let rec = Recorder()
        r.attach(send: rec.sender())
        r.report(callId: "new", callKitId: nil, outcome: .missed, snoozeMinutes: nil, outcomeNotes: nil)
        await settle(r)
        XCTAssertEqual(rec.sent.map(\.callId), ["new"])
    }

    func testAfterThreeFailuresTheItemIsReEnqueuedAndRetriedLater() async {
        let log = SleepLog()
        let r = CallsOutcomeReporter(defaults: suite, sleep: log.sleeper())
        let rec = Recorder(failures: 3)
        r.attach(send: rec.sender())
        r.report(callId: "c1", callKitId: uuid, outcome: .done, snoozeMinutes: nil, outcomeNotes: nil)
        await settle(r)
        // First flush gave up after 3 attempts — still queued + on disk.
        XCTAssertEqual(rec.attempts, 3)
        XCTAssertEqual(r.queue.count, 1, "re-enqueued, never dropped")
        XCTAssertNotNil(suite.data(forKey: CallsOutcomeReporter.queueKey))
        // The deferred retry (retryLater) succeeds on the 4th attempt.
        let deadline = Date().addingTimeInterval(5)
        while r.queue.count == 1, Date() < deadline { await Task.yield(); await settle(r) }
        XCTAssertEqual(rec.attempts, 4)
        XCTAssertEqual(rec.sent.map(\.callId), ["c1"])
        XCTAssertEqual(log.delays, [2, 5, 15], "2 s / 5 s between the three attempts, 15 s before the re-enqueued item is retried")
        XCTAssertTrue(r.queue.isEmpty)
    }
}
