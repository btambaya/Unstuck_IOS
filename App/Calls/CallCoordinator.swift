// CallCoordinator — the CallKit state machine for "Unstuck calls you".
//
//   VoIP push ──▶ reportIncoming ──▶ CXProvider.reportNewIncomingCall (SYNC)
//                     │
//                     ├─ same uuid as the live call → duplicate push: state untouched
//                     ├─ nobody signed in     → end .failed, silent (no outcome, no notes)
//                     ├─ outside call hours   → end .declinedElsewhere, outcome declined, notify
//                     ├─ focus session live   → end .answeredElsewhere, outcome busy, notify
//                     ├─ anchor gone          → end .remoteEnded, outcome stale (silent)
//                     └─ else ring; 30 s unanswered → .unanswered, outcome missed, notify
//   CXAnswerCallAction ──▶ performAnswer (configure audio, fulfil, outcome answered)
//   provider(_:didActivate:) ──▶ audioSessionDidActivate ──▶ launcher.start
//   CXEndCallAction / launcher.onEnded ──▶ performEnd ──▶ launcher.stop, outcome done|snoozed
//
// Everything CallKit / PushKit / AVFoundation / network is behind the seams in
// CallSeams.swift, so this file is plain Swift and fully unit-tested
// (CallCoordinatorTests). `shared` binds the real CallKit bridge.
//
// ONE END PER CALL: `endActiveCall` records `pendingEnd` and asks CallKit to
// end the call (CXEndCallAction → `performEnd`, ASYNC). Anything that wants
// to end the call while that transaction is in flight — the launcher's
// `onEnded`, a second snooze, the grace timer — is a no-op: `pendingEnd`
// already set ⇒ one CXEndCallAction, one outcome report.
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
        /// CXEndCallAction round-trips, so `performEnd` knows the reason — and
        /// so a second hang-up while it's in flight is ignored.
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

        // A retried / duplicated push for the call that is ALREADY up (same
        // callId ⇒ same CXCall UUID): Apple still requires a report per push,
        // CallKit answers it with callUUIDAlreadyExists — swallow that, and
        // touch NOTHING (phase, launcher, timers stay exactly as they are).
        if let cur = active, cur.session.uuid == session.uuid {
            provider.reportIncoming(uuid: session.uuid, callerName: "Unstuck · \(session.label)") { _ in }
            return
        }

        // Report FIRST, synchronously — every rule below runs after this line.
        provider.reportIncoming(uuid: session.uuid, callerName: "Unstuck · \(session.label)") { [weak self] error in
            self?.reportCompleted(uuid: session.uuid, error: error)
        }

        // Nobody signed in (a reactive sign-out left the VoIP token registered):
        // drop it at once — no ring, no outcome (no JWT to report with), and
        // never the previous account's notes as a notification.
        guard environment.isSignedIn else {
            provider.reportEnded(uuid: session.uuid, reason: .failed)
            return
        }

        // A second push while a call is up (CallKit allows one — maximumCallGroups=1).
        if let cur = active, cur.session.uuid != session.uuid {
            provider.reportEnded(uuid: session.uuid, reason: .answeredElsewhere)
            report(session, .busy)
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
    /// …): if we're still ringing, treat it as missed — the user never saw
    /// it. A call already ended by a receipt rule is left alone. (A duplicate
    /// push's callUUIDAlreadyExists never reaches here — see reportIncoming.)
    private func reportCompleted(uuid: UUID, error: Error?) {
        guard let error, let cur = active, cur.session.uuid == uuid, cur.phase == .ringing else { return }
        _ = error
        ringTimer?.cancel(); ringTimer = nil
        active = nil
        report(cur.session, .missed)
        notifier.post(CallNotifications.missed(cur.session))
    }

    private func endSilently(_ session: CallSession, reason: CallEndedReason, outcome: CallOutcome,
                             notification: CallNotification?) {
        provider.reportEnded(uuid: session.uuid, reason: reason)
        report(session, outcome)
        if let notification { notifier.post(notification) }
        active = nil
    }

    private func ringTimedOut(uuid: UUID) {
        guard let cur = active, cur.session.uuid == uuid, cur.phase == .ringing else { return }
        ringTimer = nil
        active = nil
        provider.reportEnded(uuid: uuid, reason: .unanswered)
        report(cur.session, .missed)
        notifier.post(CallNotifications.missed(cur.session))
    }

    private func report(_ session: CallSession, _ outcome: CallOutcome,
                        snoozeMinutes: Int? = nil, outcomeNotes: [String]? = nil) {
        reporter.report(callId: session.callId, callKitId: session.uuid, outcome: outcome,
                        snoozeMinutes: snoozeMinutes, outcomeNotes: outcomeNotes)
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
        report(cur.session, .answered)
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
            report(session, .declined)
        case .answering, .active:
            switch cur.pendingEnd ?? .hungUp {
            case .snoozed(let minutes):
                report(session, .snoozed, snoozeMinutes: minutes)
            case .hungUp:
                report(session, .done)
            case .failed(let why):
                report(session, .done, outcomeNotes: ["voice failed: \(why)"])
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

    /// The launcher's conversation ended on its own. If a hang-up is already
    /// in flight (snooze), this is just the launcher confirming — no second end.
    private func launcherEnded(uuid: UUID, reason: CallEndReason) {
        guard var cur = active, cur.session.uuid == uuid else { return }
        cur.launcherRunning = false
        active = cur
        endActiveCall(reason)
    }

    // MARK: - app-facing

    /// Hang up from our side (snooze, the model said goodbye, voice failed):
    /// ask CallKit to end the call so the UI closes; the CXEndCallAction lands
    /// in `performEnd` with `reason` as the pending end. Idempotent: a second
    /// call while the transaction is in flight is ignored (one end, one outcome).
    func endActiveCall(_ reason: CallEndReason) {
        guard var cur = active, cur.pendingEnd == nil else { return }
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
    /// the tool result string the model reads. Clamped 1…180. The SINGLE
    /// source of truth for a snooze: this hangs up (→ `performEnd` stops the
    /// launcher and reports `snoozed` once); the launcher must not end itself.
    func snoozeActiveCall(minutes: Int) -> String {
        guard let cur = active, cur.phase != .ringing else { return "error: no call is active" }
        if case .snoozed(let m)? = cur.pendingEnd {
            return "ok: I'll call back in \(m) minutes — say a quick goodbye; the call ends now"
        }
        let m = min(180, max(1, minutes))
        endActiveCall(.snoozed(minutes: m))
        return "ok: I'll call back in \(m) minutes — say a quick goodbye; the call ends now"
    }

    /// Fallback B: the user tapped the time-sensitive "call" alert (or its
    /// Answer action). Hand the session to Talk (via `onFallbackAnswer`), or
    /// buffer it until set. Dropped when nobody is signed in.
    func handleFallbackTap(_ payload: IncomingCallPayload) {
        guard environment.isSignedIn else { return }
        let session = CallSession(payload: payload, receivedAt: clock.now)
        report(session, .answered)
        if let h = onFallbackAnswer { h(session) } else { pendingFallback = session }
    }

    /// The account signed out (VoipPushRegistry.unregisterBestEffort): tear
    /// down whatever is up WITHOUT reporting or notifying — the JWT is gone
    /// and the notes belong to the previous user.
    func signedOut() {
        ringTimer?.cancel(); ringTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        awaitingLauncher = false
        if let cur = active {
            if cur.launcherRunning { launcher.stop() }
            provider.reportEnded(uuid: cur.session.uuid, reason: .failed)
        }
        active = nil
        pendingFallback = nil
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
