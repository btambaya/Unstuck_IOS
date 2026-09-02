// CallCoordinator state-machine tests — no CallKit / PushKit / network:
// every seam (provider, controller, launcher, notifier, outcome reporter,
// environment, clock) is a fake. Asserts the ios-gateway-plan C1 rules:
//   report → answer → didActivate → launcher starts (never before activation),
//   unanswered after 30 s → .unanswered + "I called about …" notification,
//   busy (focus live) / stale (anchor gone) / outside-hours receipt rules,
//   snooze (call-level) → outcome snoozed + hang-up, user hang-up → done,
//   invalid payload → report then .failed, DND-filtered report → missed,
//   mute forwarded, late launcher attach, provider reset.

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
    private var completions: [UUID: @MainActor (Error?) -> Void] = [:]

    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (Error?) -> Void) {
        incoming.append(Incoming(uuid: uuid, callerName: callerName))
        completions[uuid] = completion
    }
    func reportEnded(uuid: UUID, reason: CallEndedReason) { ended.append((uuid, reason)) }
    func configureAudioSession() { configured += 1 }
    /// Simulate CallKit finishing reportNewIncomingCall (nil = presented).
    func complete(_ uuid: UUID, error: Error?) { completions[uuid]?(error) }
}

@MainActor
final class FakeCallController: CallControlling {
    weak var coordinator: CallCoordinator?
    var requested: [UUID] = []
    var failNext = false
    /// Like CallKit: the CXEndCallAction lands back in the provider delegate.
    func requestEnd(uuid: UUID, completion: @escaping @MainActor (Error?) -> Void) {
        requested.append(uuid)
        if failNext { failNext = false; completion(NSError(domain: "cx", code: 1)); return }
        _ = coordinator?.performEnd(uuid: uuid)
        completion(nil)
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
    struct Report: Equatable { let callId: String; let outcome: CallOutcome; let snooze: Int?; let notes: [String]? }
    var reports: [Report] = []
    func report(callId: String, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?) {
        reports.append(Report(callId: callId, outcome: outcome, snooze: snoozeMinutes, notes: outcomeNotes))
    }
    var outcomes: [CallOutcome] { reports.map(\.outcome) }
}

@MainActor
final class FakeEnvironment: CallEnvironment {
    var focusLive = false
    var anchorLive = true
    var withinHours = true
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
        XCTAssertEqual(sut.active?.session.callId, Self.callId, "first call untouched")
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

    func testSnoozeReportsSnoozedWithMinutesAndHangsUp() {
        answerAndActivate()
        let result = sut.snoozeActiveCall(minutes: 10)
        XCTAssertTrue(result.hasPrefix("ok:"), result)
        XCTAssertTrue(result.contains("10 minutes"))
        XCTAssertEqual(controller.requested, [uuid])
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertEqual(reporter.reports.last, FakeReporter.Report(callId: Self.callId, outcome: .snoozed, snooze: 10, notes: nil))
        XCTAssertNil(sut.active)
    }

    func testSnoozeClampsAndRefusesWhenNoCall() {
        XCTAssertEqual(sut.snoozeActiveCall(minutes: 10), "error: no call is active")
        sut.reportIncoming(payload())
        XCTAssertEqual(sut.snoozeActiveCall(minutes: 10), "error: no call is active", "not while ringing")
        XCTAssertTrue(sut.performAnswer(uuid: uuid)); sut.audioSessionDidActivate()
        _ = sut.snoozeActiveCall(minutes: 999)
        XCTAssertEqual(reporter.reports.last?.snooze, 180)
    }

    func testLauncherEndingItselfHangsUpAndReportsDone() {
        answerAndActivate()
        launcher.end(.hungUp)
        XCTAssertEqual(controller.requested, [uuid])
        XCTAssertEqual(reporter.outcomes, [.answered, .done])
        XCTAssertEqual(launcher.stops, 0, "launcher already stopped itself — no double stop")
        XCTAssertNil(sut.active)
    }

    func testLauncherFailureNotifiesWithNotes() {
        answerAndActivate()
        launcher.end(.failed("socket closed"))
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
