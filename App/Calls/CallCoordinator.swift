// CallCoordinator — the CallKit state machine for "Unstuck calls you".
//
//   VoIP push ──▶ reportIncoming ──▶ CXProvider.reportNewIncomingCall (SYNC)
//                     │
//                     ├─ outside call hours → end .declinedElsewhere, outcome declined, notify
//                     ├─ focus session live → end .answeredElsewhere, outcome busy, notify
//                     ├─ anchor gone        → end .remoteEnded, outcome stale (silent)
//                     └─ else ring; 30 s unanswered → .unanswered, outcome missed, notify
//   CXAnswerCallAction ──▶ performAnswer (configure audio, fulfil, outcome answered)
//   provider(_:didActivate:) ──▶ audioSessionDidActivate ──▶ launcher.start
//   CXEndCallAction / launcher.onEnded ──▶ performEnd ──▶ launcher.stop, outcome done|snoozed
//
// Everything CallKit / PushKit / AVFoundation / network is behind the seams in
// CallSeams.swift, so this file is plain Swift and fully unit-tested
// (CallCoordinatorTests). `shared` binds the real CallKit bridge.
//
// Killed-state launches: PushKit delivers the push before AppModel.start()
// runs. `reportIncoming` never waits on AppModel — the environment defaults
// are safe (ring), the outcome reporter buffers until a client is attached,
// and an answer that lands before the voice launcher is attached waits a
// short grace (`launcherGrace`) for `attach(launcher:)` before degrading.

import Foundation
import UnstuckSync

@MainActor
final class CallCoordinator {
    static let shared: CallCoordinator = {
        let provider = CallKitProvider()
        let c = CallCoordinator(
            provider: provider, controller: CallKitController(),
            environment: AppCallEnvironment(model: nil),
            launcher: NoopCallVoiceLauncher(), launcherAttached: false,
            notifier: SystemCallNotifier(), reporter: CallsOutcomeReporter(),
            clock: SystemCallClock())
        provider.coordinator = c
        return c
    }()

    /// Ring for this long before giving up (CallKit itself rings indefinitely).
    static let ringTimeout: TimeInterval = 30
    /// How long an answered call waits for a voice launcher to be attached
    /// (killed-state launch: AppModel + the voice stack are still booting).
    static let launcherGrace: TimeInterval = 8

    enum Phase: Equatable, Sendable { case ringing, answering, active }

    struct ActiveCall: Equatable {
        let session: CallSession
        var phase: Phase
        var muted = false
        /// Set by an app-initiated hang-up (snooze / launcher ended) before the
        /// CXEndCallAction round-trips, so `performEnd` knows the reason.
        var pendingEnd: CallEndReason?
        var launcherRunning = false
    }

    private(set) var active: ActiveCall?
    /// Fallback-B: a tapped "call" alert push whose Talk hand-off nobody has
    /// consumed yet (buffered until `onFallbackAnswer` is set).
    private(set) var pendingFallback: CallSession?
    /// Set by the integrator: open Talk with the call payload (fallback B).
    var onFallbackAnswer: ((CallSession) -> Void)? {
        didSet { if let s = pendingFallback, let h = onFallbackAnswer { pendingFallback = nil; h(s) } }
    }
    /// Weak handle to the app model once attached (CallTools needs it).
    weak var attachedModel: AppModel?
    /// The calls client once attached (Settings / task editor / tools).
    private(set) var callsClient: CallsClient?

    private let provider: CallProviding
    private let controller: CallControlling
    private var environment: CallEnvironment
    private var launcher: CallVoiceLauncher
    private var launcherAttached: Bool
    private let notifier: CallNotifier
    private let reporter: CallOutcomeReporting
    private let clock: CallClock

    private var ringTimer: CallTimer?
    private var graceTimer: CallTimer?
    private var audioActive = false
    private var awaitingLauncher = false

    init(provider: CallProviding, controller: CallControlling, environment: CallEnvironment,
         launcher: CallVoiceLauncher, launcherAttached: Bool = true,
         notifier: CallNotifier, reporter: CallOutcomeReporting, clock: CallClock) {
        self.provider = provider
        self.controller = controller
        self.environment = environment
        self.launcher = launcher
        self.launcherAttached = launcherAttached
        self.notifier = notifier
        self.reporter = reporter
        self.clock = clock
    }

    // MARK: - attach (late binding from AppModel / the integrator)

    func attach(environment: CallEnvironment) { self.environment = environment }

    func attach(client: CallsClient) {
        callsClient = client
        reporter.attach(client: client)
    }

    /// Install the real voice launcher. If a call was answered while the
    /// default Noop was installed, the conversation starts now.
    func attach(launcher: CallVoiceLauncher) {
        self.launcher = launcher
        launcherAttached = true
        if awaitingLauncher, audioActive, active?.phase == .answering {
            graceTimer?.cancel(); graceTimer = nil
            awaitingLauncher = false
            startVoice()
        }
    }

    // MARK: - inbound (PushKit)

    /// Decode + report. An UNDECODABLE payload still reports a CallKit call
    /// (Apple kills the app + throttles VoIP pushes when a push reports none)
    /// and ends it at once as `.failed` — no notification, nothing to say.
    func reportIncoming(dictionary: [AnyHashable: Any]) {
        if let payload = IncomingCallPayload(dictionary: dictionary) {
            reportIncoming(payload)
        } else {
            reportInvalid()
        }
    }

    func reportIncoming(_ payload: IncomingCallPayload) {
        let session = CallSession(payload: payload, receivedAt: clock.now)
        // Report FIRST, synchronously — every rule below runs after this line.
        provider.reportIncoming(uuid: session.uuid, callerName: "Unstuck · \(session.label)") { [weak self] error in
            self?.reportCompleted(uuid: session.uuid, error: error)
        }

        // A second push while a call is up (CallKit allows one — maximumCallGroups=1).
        if let cur = active, cur.session.uuid != session.uuid {
            provider.reportEnded(uuid: session.uuid, reason: .answeredElsewhere)
            reporter.report(callId: session.callId, outcome: .busy, snoozeMinutes: nil, outcomeNotes: nil)
            notifier.post(CallNotifications.busy(session))
            return
        }
        active = ActiveCall(session: session, phase: .ringing)

        // Receipt rules — evaluated locally, after reporting.
        if !environment.isWithinCallHours(session.receivedAt) {
            endSilently(session, reason: .declinedElsewhere, outcome: .declined,
                        notification: CallNotifications.outsideHours(session))
            return
        }
        if environment.isFocusSessionLive {
            endSilently(session, reason: .answeredElsewhere, outcome: .busy,
                        notification: CallNotifications.busy(session))
            return
        }
        if !environment.anchorIsLive(taskId: session.taskId, blockId: session.blockId) {
            endSilently(session, reason: .remoteEnded, outcome: .stale, notification: nil)
            return
        }
        ringTimer = clock.after(Self.ringTimeout) { [weak self] in self?.ringTimedOut(uuid: session.uuid) }
    }

    private func reportInvalid() {
        let uuid = UUID()
        provider.reportIncoming(uuid: uuid, callerName: "Unstuck") { _ in }
        provider.reportEnded(uuid: uuid, reason: .failed)
    }

    /// `reportNewIncomingCall` failed (Do Not Disturb / a Focus filtered it,
    /// duplicate UUID, …): if we're still ringing, treat it as missed — the
    /// user never saw it. A call already ended by a receipt rule is left alone.
    private func reportCompleted(uuid: UUID, error: Error?) {
        guard let error, let cur = active, cur.session.uuid == uuid, cur.phase == .ringing else { return }
        _ = error
        ringTimer?.cancel(); ringTimer = nil
        active = nil
        reporter.report(callId: cur.session.callId, outcome: .missed, snoozeMinutes: nil, outcomeNotes: nil)
        notifier.post(CallNotifications.missed(cur.session))
    }

    private func endSilently(_ session: CallSession, reason: CallEndedReason, outcome: CallOutcome,
                             notification: CallNotification?) {
        provider.reportEnded(uuid: session.uuid, reason: reason)
        reporter.report(callId: session.callId, outcome: outcome, snoozeMinutes: nil, outcomeNotes: nil)
        if let notification { notifier.post(notification) }
        active = nil
    }

    private func ringTimedOut(uuid: UUID) {
        guard let cur = active, cur.session.uuid == uuid, cur.phase == .ringing else { return }
        ringTimer = nil
        active = nil
        provider.reportEnded(uuid: uuid, reason: .unanswered)
        reporter.report(callId: cur.session.callId, outcome: .missed, snoozeMinutes: nil, outcomeNotes: nil)
        notifier.post(CallNotifications.missed(cur.session))
    }

    // MARK: - CallKit events (forwarded by CallKitProvider)

    func providerDidReset() {
        ringTimer?.cancel(); ringTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        if active?.launcherRunning == true { launcher.stop() }
        active = nil
        audioActive = false
        awaitingLauncher = false
    }

    /// CXProviderDelegate.providerDidBegin — configure (never activate) the
    /// audio session early so the first activation already has the right
    /// category/mode.
    func providerDidBegin() {
        provider.configureAudioSession()
    }

    /// CXAnswerCallAction. Returns true when the bridge should `fulfill()`.
    /// Audio is NOT started here — we wait for `audioSessionDidActivate`.
    func performAnswer(uuid: UUID) -> Bool {
        guard var cur = active, cur.session.uuid == uuid, cur.phase == .ringing else { return false }
        ringTimer?.cancel(); ringTimer = nil
        provider.configureAudioSession()
        cur.phase = .answering
        active = cur
        reporter.report(callId: cur.session.callId, outcome: .answered, snoozeMinutes: nil, outcomeNotes: nil)
        if audioActive { startVoice() }   // rare: audio already up (reset mid-call)
        return true
    }

    /// CXEndCallAction — the user hung up / declined, or our own requestEnd
    /// round-tripped. Returns true when the bridge should `fulfill()`.
    func performEnd(uuid: UUID) -> Bool {
        guard let cur = active, cur.session.uuid == uuid else { return false }
        ringTimer?.cancel(); ringTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        awaitingLauncher = false
        if cur.launcherRunning { launcher.stop() }
        active = nil
        let session = cur.session
        switch cur.phase {
        case .ringing:
            // Declined from the CallKit UI. Logged; no notification — they saw it.
            reporter.report(callId: session.callId, outcome: .declined, snoozeMinutes: nil, outcomeNotes: nil)
        case .answering, .active:
            switch cur.pendingEnd ?? .hungUp {
            case .snoozed(let minutes):
                reporter.report(callId: session.callId, outcome: .snoozed, snoozeMinutes: minutes, outcomeNotes: nil)
            case .hungUp:
                reporter.report(callId: session.callId, outcome: .done, snoozeMinutes: nil, outcomeNotes: nil)
            case .failed(let why):
                reporter.report(callId: session.callId, outcome: .done, snoozeMinutes: nil,
                                outcomeNotes: ["voice failed: \(why)"])
                notifier.post(CallNotifications.voiceFailed(session))
            }
        }
        return true
    }

    /// CXSetMutedCallAction → the launcher's mic gate.
    func performSetMuted(uuid: UUID, muted: Bool) -> Bool {
        guard var cur = active, cur.session.uuid == uuid else { return false }
        cur.muted = muted
        active = cur
        launcher.setMuted(muted)
        return true
    }

    /// provider(_:didActivate:) — CallKit activated the AVAudioSession. ONLY
    /// now may the voice engine touch audio.
    func audioSessionDidActivate() {
        audioActive = true
        if active?.phase == .answering { startVoice() }
    }

    /// provider(_:didDeactivate:) — CallKit took the audio away (the call
    /// ended, or a cellular call displaced us). Stop the conversation; the
    /// CXEndCallAction (if any) settles the outcome.
    func audioSessionDidDeactivate() {
        audioActive = false
        if var cur = active, cur.launcherRunning {
            launcher.stop()
            cur.launcherRunning = false
            active = cur
        }
    }

    private func startVoice() {
        guard var cur = active, cur.phase == .answering else { return }
        guard launcherAttached else {
            awaitingLauncher = true
            graceTimer = clock.after(Self.launcherGrace) { [weak self] in
                guard let self, self.awaitingLauncher else { return }
                self.awaitingLauncher = false
                self.endActiveCall(.failed("voice unavailable"))
            }
            return
        }
        cur.phase = .active
        cur.launcherRunning = true
        active = cur
        let uuid = cur.session.uuid
        launcher.start(cur.session) { [weak self] reason in
            self?.launcherEnded(uuid: uuid, reason: reason)
        }
    }

    private func launcherEnded(uuid: UUID, reason: CallEndReason) {
        guard var cur = active, cur.session.uuid == uuid else { return }
        cur.launcherRunning = false
        active = cur
        endActiveCall(reason)
    }

    // MARK: - app-facing

    /// Hang up from our side (snooze, the model said goodbye, voice failed):
    /// ask CallKit to end the call so the UI closes; the CXEndCallAction lands
    /// in `performEnd` with `reason` as the pending end.
    func endActiveCall(_ reason: CallEndReason) {
        guard var cur = active else { return }
        cur.pendingEnd = reason
        active = cur
        let uuid = cur.session.uuid
        controller.requestEnd(uuid: uuid) { [weak self] error in
            guard let self, error != nil, self.active?.session.uuid == uuid else { return }
            // CallKit refused the transaction — settle locally so nothing dangles.
            self.provider.reportEnded(uuid: uuid, reason: .remoteEnded)
            _ = self.performEnd(uuid: uuid)
        }
    }

    /// The call-level `snooze_call` tool: "call me back in N minutes". Returns
    /// the tool result string the model reads. Clamped 1…180.
    func snoozeActiveCall(minutes: Int) -> String {
        guard let cur = active, cur.phase != .ringing else { return "error: no call is active" }
        let m = min(180, max(1, minutes))
        endActiveCall(.snoozed(minutes: m))
        return "ok: I'll call back in \(m) minutes — say a quick goodbye; the call ends now"
    }

    /// Fallback B: the user tapped the time-sensitive "call" alert. Hand the
    /// session to Talk (via `onFallbackAnswer`), or buffer it until set.
    func handleFallbackTap(_ payload: IncomingCallPayload) {
        let session = CallSession(payload: payload, receivedAt: clock.now)
        reporter.report(callId: session.callId, outcome: .answered, snoozeMinutes: nil, outcomeNotes: nil)
        if let h = onFallbackAnswer { h(session) } else { pendingFallback = session }
    }
}

/// The local notifications the call path posts. Pure builders (tested).
enum CallNotifications {
    static let thread = "unstuck_reminders"

    /// Unanswered after 30 s / filtered by Focus: "I called about <label>" with
    /// the notes as lines; Start / Reschedule when a task is anchored.
    static func missed(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.missed.\(s.callId)", title: "I called about \(s.label)", body: body(s.notes))
    }
    static func busy(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.busy.\(s.callId)", title: "I called about \(s.label) — you were mid-focus", body: body(s.notes))
    }
    static func outsideHours(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.hours.\(s.callId)", title: "I called about \(s.label)",
             body: body(s.notes) + "\n(outside your call hours — Settings › Calls)")
    }
    static func voiceFailed(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.failed.\(s.callId)", title: "Couldn't start the call — here's what it was about", body: body(s.notes))
    }

    private static func body(_ notes: [String]) -> String {
        notes.isEmpty ? "No notes on this one." : notes.joined(separator: "\n")
    }

    private static func make(_ s: CallSession, id: String, title: String, body: String) -> CallNotification {
        var info: [String: String] = ["kind": "call_missed", "callId": s.callId]
        if let t = s.taskId {
            info["taskId"] = t
            info["taskName"] = s.taskName ?? s.label
            info["deepLink"] = "unstuck://task/\(t)"
            if let b = s.blockId { info["blockId"] = b }
        } else {
            info["deepLink"] = "unstuck://today"
        }
        return CallNotification(
            id: id, title: title, body: body,
            categoryId: s.taskId != nil ? NotificationCategories.taskStarting : nil,
            threadId: thread, userInfo: info, timeSensitive: true)
    }
}
