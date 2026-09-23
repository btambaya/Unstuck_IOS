// CallCoordinator — the CallKit state machine for "Unstuck calls you".
//
//   VoIP push ──▶ reportIncoming ──▶ CXProvider.reportNewIncomingCall (SYNC)
//                     │
//                     ├─ same uuid as the live call → duplicate push: state untouched
//                     ├─ nobody signed in     → end .failed, silent (no outcome, no notes)
//                     ├─ calls switched off   → end .declinedElsewhere, outcome declined, notify
//                     ├─ no AI-consent OK     → end .declinedElsewhere, outcome declined, notify
//                     │                         (never connected to the assistant — AIConsent)
//                     ├─ outside call hours   → end .declinedElsewhere, outcome declined, notify
//                     ├─ focus session live   → end .answeredElsewhere, outcome busy, notify
//                     ├─ anchor known over    → end .remoteEnded, outcome stale (silent);
//                     │                         one not synced here yet rings (web/Android audit 2026-09-23, A6)
//                     └─ else ring; 30 s unanswered → .unanswered, outcome missed —
//                        the "I called about X" notification is handed to the
//                        REPORTER and posted only once call-outcome answers
//                        `retry: false` (a first miss is re-rung by the server
//                        5 min later — `retry: true` — and must stay quiet)
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
// The push also STARTS the app model (`bootApp` → AppModel.startWithoutScene)
// right after the report: a launch with no scene (the app was swiped away)
// never runs RootView's .task, so nothing else would ever attach them.

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
            notifier: SystemCallNotifier(),
            reporter: CallsOutcomeReporter(notifier: SystemCallNotifier(),
                                           backgroundTime: CallsOutcomeReporter.systemBackgroundTime),
            clock: SystemCallClock(),
            rearmVoip: { VoipPushRegistry.shared.rearm() },
            bootApp: { Task { await AppModel.shared.startWithoutScene() } },
            holdVoiceAudio: { VoiceAudioOwnership.set($0, by: .callKit) })
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
    /// Fallback-B, one step earlier: a tap that landed BEFORE the real session
    /// was known (a cold launch off the alert — PushAppDelegate fires before
    /// AppModel.start()). Decided in `attach(environment:)`; never dropped on
    /// the VoIP-token proxy, which is false exactly when transport B is used.
    private(set) var deferredFallbackTap: IncomingCallPayload?
    /// Set by the integrator: open Talk with the call payload (fallback B).
    var onFallbackAnswer: ((CallSession) -> Void)? {
        didSet { if let s = pendingFallback, let h = onFallbackAnswer { pendingFallback = nil; h(s) } }
    }
    /// Weak handle to the app model once attached (CallTools needs it).
    weak var attachedModel: AppModel?
    /// The calls client once attached (Settings / task editor / tools).
    private(set) var callsClient: CallsClient?
    /// The auth watcher `attach(model:client:)` installs (re-arms PushKit on
    /// every sign-in within one launch).
    var authWatch: Task<Void, Never>?

    private let provider: CallProviding
    private let controller: CallControlling
    private var environment: CallEnvironment
    private var launcher: CallVoiceLauncher
    private var launcherAttached: Bool
    private let notifier: CallNotifier
    private let reporter: CallOutcomeReporting
    private let clock: CallClock
    /// Re-register for VoIP pushes (VoipPushRegistry.rearm in production).
    private let rearmVoip: @MainActor () -> Void
    /// Start AppModel when a push arrives before it attached —
    /// AppModel.startWithoutScene in production.
    private let bootApp: @MainActor () -> Void
    /// Mark the shared audio session as the call's (VoiceAudioOwnership,
    /// `.callKit`) from the answer until CallKit takes the audio back. Only
    /// Talk's own activation used to set it, so during a call the ambient bed
    /// switched the session to `.playback` (no input) or deactivated it — a
    /// connected call with dead air (audit 2026-09-22, C42). Set at the answer,
    /// not at didActivate: CallKit activates the session BEFORE it tells us,
    /// and a release landing in between killed the call just the same.
    private let holdVoiceAudio: @MainActor (Bool) -> Void

    private var ringTimer: CallTimer?
    private var graceTimer: CallTimer?
    private var audioActive = false
    private var awaitingLauncher = false

    init(provider: CallProviding, controller: CallControlling, environment: CallEnvironment,
         launcher: CallVoiceLauncher, launcherAttached: Bool = true,
         notifier: CallNotifier, reporter: CallOutcomeReporting, clock: CallClock,
         rearmVoip: @escaping @MainActor () -> Void = {},
         bootApp: @escaping @MainActor () -> Void = {},
         holdVoiceAudio: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.provider = provider
        self.controller = controller
        self.environment = environment
        self.launcher = launcher
        self.launcherAttached = launcherAttached
        self.notifier = notifier
        self.reporter = reporter
        self.clock = clock
        self.rearmVoip = rearmVoip
        self.bootApp = bootApp
        self.holdVoiceAudio = holdVoiceAudio
    }

    // MARK: - attach (late binding from AppModel / the integrator)

    /// Bind the environment. A fallback tap deferred until the session was
    /// known is decided now (handed off, or dropped if nobody is signed in).
    func attach(environment: CallEnvironment) {
        self.environment = environment
        if let p = deferredFallbackTap, environment.isSessionKnown {
            deferredFallbackTap = nil
            handleFallbackTap(p)
        }
    }

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

        // No AppModel attached yet: a VoIP push to an app the user swiped
        // away relaunches it with NO scene (iOS discarded the session), so
        // RootView's .task never ran start() — the voice launcher and the
        // outcome sender were never attached, the answer waited out the grace
        // and failed, and the server re-rang the row (audit 2026-09-22, C16).
        // Start it here, after the report (Apple's rule) and for every push
        // outcome. Fire-and-forget: the rules below run on the killed-state
        // environment and the attaches land a moment later, inside the grace.
        // Idempotent where a scene does connect (start() guards on its
        // coordinator); a duplicate push returned above, so it never boots twice.
        if !environment.isSessionKnown { bootApp() }

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

        // Receipt rules — evaluated locally, after reporting. Android order:
        // signed in → the kill-switch → hours → focus → anchor, with the
        // AI-consent OK right after the kill-switch: a call is a
        // conversation with the assistant, so without it the call never
        // connects to the AI.
        if !environment.isCallsEnabled {
            endSilently(session, reason: .declinedElsewhere, outcome: .declined,
                        notification: CallNotifications.callsOff(session))
            return
        }
        if !environment.hasAIConsent {
            endSilently(session, reason: .declinedElsewhere, outcome: .declined,
                        notification: CallNotifications.noAIConsent(session))
            return
        }
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
        reportMissed(cur.session)
    }

    /// A miss: the outcome goes up with the "I called about X" notification
    /// attached — the reporter posts it once the server answers `retry:
    /// false` (or refuses the report for good), and swallows it on `retry:
    /// true` (the server re-rings in 5 min; the second miss notifies). Never
    /// posted here at the timeout: the flag arrives asynchronously.
    private func reportMissed(_ session: CallSession) {
        reporter.report(callId: session.callId, callKitId: session.uuid, outcome: .missed,
                        snoozeMinutes: nil, outcomeNotes: nil,
                        notifyUnlessRetry: CallNotifications.missed(session))
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
        reportMissed(cur.session)
    }

    private func report(_ session: CallSession, _ outcome: CallOutcome,
                        snoozeMinutes: Int? = nil, outcomeNotes: [String]? = nil) {
        reporter.report(callId: session.callId, callKitId: session.uuid, outcome: outcome,
                        snoozeMinutes: snoozeMinutes, outcomeNotes: outcomeNotes, notifyUnlessRetry: nil)
    }

    // MARK: - CallKit events (forwarded by CallKitProvider)

    func providerDidReset() {
        ringTimer?.cancel(); ringTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        if active?.launcherRunning == true { launcher.stop() }
        active = nil
        audioActive = false
        awaitingLauncher = false
        holdVoiceAudio(false)
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
        holdVoiceAudio(true)
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
        // The call is over; CallKit's didDeactivate follows (clears it too).
        holdVoiceAudio(false)
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
            case .outOfMinutes(let line):
                // The same outcome note dispatch_calls writes on a call it
                // skips for the minutes (077), so the row reads alike.
                report(session, .done, outcomeNotes: [CallNotifications.minutesUsedOutcome])
                notifier.post(CallNotifications.minutesUsed(session, line: line))
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
        holdVoiceAudio(true)
        if active?.phase == .answering { startVoice() }
    }

    /// provider(_:didDeactivate:) — CallKit took the audio away (the call
    /// ended, or a cellular call displaced us). Stop the conversation; the
    /// CXEndCallAction (if any) settles the outcome.
    func audioSessionDidDeactivate() {
        audioActive = false
        holdVoiceAudio(false)
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
        if let e = snoozeRefusal(minutes: m) { return e }
        endActiveCall(.snoozed(minutes: m))
        return "ok: I'll call back in \(m) minutes — say a quick goodbye; the call ends now"
    }

    /// A call-back is a booking too: "call me back in two hours" at 20:30
    /// was answered ok, then declined quietly on receipt at 22:30 by this
    /// phone's hours (audit 2026-09-22, C12). Refused here instead, with the
    /// call left up. Only this CallKit path refuses: the server applies no
    /// window to snoozes, and fallback B (the alert transport) never applies
    /// the phone's hours, so a call-back there does arrive.
    private func snoozeRefusal(minutes: Int) -> String? {
        let m = min(180, max(1, minutes))
        let at = clock.now.addingTimeInterval(TimeInterval(m * 60))
        guard !environment.isWithinCallHours(at) else { return nil }
        let hours = CallSettings.hoursLabel(start: CallSettings.windowStart, end: CallSettings.windowEnd,
                                            refusing: CallSettings.minuteOfDay(at))
        return "error: a call-back in \(m) minutes would ring at \(CallSettings.hhmm(at)), outside this iPhone's call hours (\(hours)), so it would be declined — ask them for a shorter wait, or for a time inside those hours to book with request_call"
    }

    /// Fallback B: the user tapped the time-sensitive "call" alert (or its
    /// Answer action). Hand the session to Talk (via `onFallbackAnswer`), or
    /// buffer it until set. Dropped when nobody is signed in — but that is
    /// decided on the REAL session: the tap foregrounds the app, so when the
    /// environment only has the killed-state proxy (no AppModel yet) the tap
    /// is deferred until `attach(environment:)` rather than dropped (the
    /// proxy — "a VoIP token is stored" — is false precisely when the server
    /// fell back to the alert transport).
    func handleFallbackTap(_ payload: IncomingCallPayload) {
        guard environment.isSessionKnown else { deferredFallbackTap = payload; return }
        guard environment.isSignedIn else { return }
        let session = CallSession(payload: payload, receivedAt: clock.now)
        // No AI-consent OK: Talk never opens with the call — declined, and
        // the notes land with the reason (the receipt rule's twin).
        guard environment.hasAIConsent else {
            report(session, .declined)
            notifier.post(CallNotifications.noAIConsent(session))
            return
        }
        report(session, .answered)
        if let h = onFallbackAnswer { h(session) } else { pendingFallback = session }
    }

    /// `unstuck://call/<id>` route hook (AppModel.openCall): true when this
    /// coordinator already holds the call — ringing / answered (Talk is, or is
    /// about to be, up), a fallback tap buffered for a launcher that isn't
    /// attached yet (handed off now when it is), or one deferred until the
    /// session is known (decided by `attach(environment:)`). The server stamps
    /// the payload's `callId` with the call_requests row id, so the ids match.
    func resumeFromDeepLink(callId: String) -> Bool {
        if let cur = active, cur.session.callId == callId { return true }
        if let p = pendingFallback, p.callId == callId {
            if let h = onFallbackAnswer { pendingFallback = nil; h(p) }
            return true
        }
        if let d = deferredFallbackTap, d.callId == callId { return true }
        return false
    }

    /// Fallback B's "call me back in N": there is no CallKit call to hang up,
    /// so the `snoozed` outcome is reported straight through the PERSISTED,
    /// ordered reporter (after the `answered` that the tap queued) — never a
    /// fire-and-forget request that a tunnel or a 5xx could lose, leaving the
    /// row `answered` with no snooze_until and the dispatcher never re-ringing.
    /// Clamped 1…180 like the CallKit snooze.
    func reportFallbackSnooze(callId: String, minutes: Int) {
        let m = min(180, max(1, minutes))
        reporter.report(callId: callId, callKitId: nil, outcome: .snoozed, snoozeMinutes: m, outcomeNotes: nil,
                        notifyUnlessRetry: nil)
    }

    /// The account signed in (or switched) within this launch: re-arm PushKit
    /// so the next booked call rings through CallKit instead of degrading to
    /// the alert banner — a sign-out dropped the VoIP registration and only
    /// `attach(model:client:)` (once per launch) used to re-arm it.
    func signedIn() {
        rearmVoip()
    }

    /// The account signed out (VoipPushRegistry.unregisterBestEffort): tear
    /// down whatever is up WITHOUT reporting or notifying — the JWT is gone
    /// and the notes belong to the previous user — and forget any outcome
    /// still queued for it (unsendable now; the next account's server would
    /// answer not_found for every one of them).
    func signedOut() {
        ringTimer?.cancel(); ringTimer = nil
        graceTimer?.cancel(); graceTimer = nil
        awaitingLauncher = false
        if let cur = active {
            if cur.launcherRunning { launcher.stop() }
            provider.reportEnded(uuid: cur.session.uuid, reason: .failed)
        }
        active = nil
        holdVoiceAudio(false)
        pendingFallback = nil
        deferredFallbackTap = nil
        reporter.discardAll()
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
             body: body(s.notes) + "\n(outside your call hours — Settings › Calls)", quiet: true)
    }
    /// The master switch is off on this phone: declined quietly, the notes
    /// still land (Android's `enabled` rule) — with the honest reason.
    static func callsOff(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.off.\(s.callId)", title: "I called about \(s.label)",
             body: body(s.notes) + "\n(calls are off on this iPhone — Settings › Calls)", quiet: true)
    }
    /// The account hasn't agreed to AI data sharing: the call never connected
    /// to the assistant. Declined quietly; the notes land with the way on.
    static func noAIConsent(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.consent.\(s.callId)", title: "I called about \(s.label)",
             body: body(s.notes) + "\n(calls use the assistant — turn on AI data sharing in Settings › Interface to take them)",
             quiet: true)
    }
    static func voiceFailed(_ s: CallSession) -> CallNotification {
        make(s, id: "unstuck.call.failed.\(s.callId)", title: "Couldn't start the call — here's what it was about", body: body(s.notes))
    }
    /// The call ended because today's voice minutes ran out (Ahmad
    /// 2026-09-23): the plain line first ("You've used today's 10 voice
    /// minutes. They reset at midnight."), then what it was about. A normal
    /// alert — neither time-sensitive (nothing is ringing) nor passive: they
    /// were on the call a moment ago, and a passive one shows no banner.
    static func minutesUsed(_ s: CallSession, line: String) -> CallNotification {
        make(s, id: "unstuck.call.minutes.\(s.callId)", title: "I called about \(s.label)",
             body: s.notes.isEmpty ? line : line + "\n" + s.notes.joined(separator: "\n"), timeSensitive: false)
    }
    /// call_requests.outcome_notes for such a call — dispatch_calls' own words
    /// for a call it skipped (migration 077).
    static let minutesUsedOutcome = "voice minutes used today"

    private static func body(_ notes: [String]) -> String {
        notes.isEmpty ? "No notes on this one." : notes.joined(separator: "\n")
    }

    private static func make(_ s: CallSession, id: String, title: String, body: String, quiet: Bool = false,
                             timeSensitive: Bool? = nil) -> CallNotification {
        var info: [String: String] = ["kind": "call_missed", "callId": s.callId]
        if let t = s.taskId {
            info["taskId"] = t
            info["taskName"] = s.taskName ?? s.label
            // The call's task itself — a series opens its own editor (C3).
            info["deepLink"] = AppModel.exactTaskLink(t)
            if let b = s.blockId { info["blockId"] = b }
        } else {
            info["deepLink"] = "unstuck://today"
        }
        return CallNotification(
            id: id, title: title, body: body,
            categoryId: s.taskId != nil ? NotificationCategories.taskStarting : nil,
            threadId: thread, userInfo: info, timeSensitive: timeSensitive ?? !quiet, quiet: quiet)
    }
}
