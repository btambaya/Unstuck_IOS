// PushKit VoIP registration + delivery for "Unstuck calls you".
//
// RULES (Apple, iOS 13+): every VoIP push MUST report a CallKit call before
// the completion handler runs — otherwise the system terminates the app and
// stops delivering VoIP pushes. So `didReceiveIncomingPushWith` reports
// synchronously via CallCoordinator.shared, even on a killed-state launch,
// and never waits on AppModel bootstrap. An undecodable payload still
// reports (then ends as .failed) — see CallCoordinator.reportIncoming(dictionary:).
//
// The registry is created at launch (PushAppDelegate.didFinishLaunching) so
// PushKit can wake the app from a killed state. The queue is `.main`, so the
// delegate methods run on the main thread → a `@preconcurrency` conformance
// keeps them main-actor isolated (the non-Sendable payload dictionary never
// crosses an isolation boundary).
//
// Token: hex → PushRegistrar.didReceiveVoip → AppModel.registerPush (both
// tokens go up in one register-push-token call via PushClient.voipTokenProvider,
// which reads the UserDefaults mirror below from any thread).
//
// SIGN-OUT: `unregisterBestEffort()` (called from AppModel.scrubDeviceLocal
// UserContent, i.e. the Sign-out button AND every reactive session→nil) wipes
// the stored token, drops the PushKit registration (desiredPushTypes = []),
// and tears down any call in progress silently — so a call the server had
// already queued for the previous account can't ring this device, and even
// if a push slips through before PushKit catches up, the coordinator sees
// "nobody signed in", reports the call and ends it at once. The server-side
// row is deleted by SyncCoordinator.signOutAndUnregister when the JWT is
// still valid; this is the device half that works without one. `rearm()`
// (CallCoordinator.attach(model:client:) once signed in) re-registers.
// The drop has to OUTLIVE the launch: `start()` used to re-register on every
// launch, the token came back, and the killed-state check read it as "signed
// in" — so a signed-out phone rang for the previous account again. A
// signed-out device (PushRegistrar.accountSignedIn == false) now stays
// unregistered until a sign-in re-arms it, and the killed-state check reads
// that flag, not the token (audit 2026-09-22, C36).

import Foundation
import PushKit
import UnstuckSync

/// Main-actor isolated: the registry is created on the main queue and every
/// PushKit callback is delivered there (`PKPushRegistry(queue: .main)`), so the
/// delegate conformance is `@preconcurrency` (SE-0423) and its methods stay
/// main-actor isolated — the runtime asserts the queue. That also makes
/// `shared` concurrency-safe under Swift 6 without `@unchecked Sendable`.
@MainActor
final class VoipPushRegistry: NSObject, @preconcurrency PKPushRegistryDelegate {
    static let shared = VoipPushRegistry()
    nonisolated static let tokenKey = "unstuck.push.voipToken"

    private var registry: PKPushRegistry?
    /// When PushKit registration was (last) requested — `start()` / a retry.
    /// Settings › Notifications & calls shows the one-time "needs VoIP registration — retry"
    /// note when no token has arrived `VoipRegistrationNudge.graceSeconds`
    /// after a signed-in launch.
    private(set) var registrationStartedAt: Date?

    private override init() { super.init() }

    /// Seconds since registration was requested (nil before `start()`).
    var secondsSinceRegistrationStart: TimeInterval? {
        registrationStartedAt.map { Date().timeIntervalSince($0) }
    }

    /// The Settings nudge's verdict, from the live facts (pure policy in
    /// VoipRegistrationNudge).
    func shouldShowNudge(signedIn: Bool, now: Date = Date()) -> Bool {
        VoipRegistrationNudge.shouldShow(
            tokenPresent: Self.storedToken != nil, signedIn: signedIn,
            secondsSinceStart: registrationStartedAt.map { now.timeIntervalSince($0) },
            dismissed: CallSettings.voipNudgeDismissed)
    }

    /// The nudge's retry: drop and re-request the VoIP registration so PushKit
    /// issues credentials again (`didUpdate` → the token goes up with
    /// register-push-token). Marks the nudge acted on.
    func retryRegistration() {
        CallSettings.voipNudgeDismissed = true
        registrationStartedAt = Date()
        guard let r = registry else { start(); return }
        r.desiredPushTypes = []
        r.desiredPushTypes = [.voIP]
    }

    /// The last VoIP token PushKit issued (device-scoped, persisted).
    nonisolated static var storedToken: String? {
        guard let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty else { return nil }
        return t
    }

    /// Call once, at launch, before `didFinishLaunching` returns.
    func start() {
        guard registry == nil else { return }
        PushClient.voipTokenProvider = { VoipPushRegistry.storedToken }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        let types = Self.launchPushTypes(accountSignedIn: PushRegistrar.accountSignedIn)
        r.desiredPushTypes = types
        registry = r
        registrationStartedAt = types.isEmpty ? nil : Date()
    }

    /// What `start()` registers for: nothing on a device that is signed out
    /// (explicitly `[]`, which drops any registration left over), VoIP
    /// otherwise — including an install that predates the flag (nil).
    nonisolated static func launchPushTypes(accountSignedIn: Bool?) -> Set<PKPushType> {
        accountSignedIn == false ? [] : [.voIP]
    }

    /// Sign-out (AppModel.scrubDeviceLocalUserContent): forget the token, stop
    /// PushKit delivery, and drop any call in progress without a report or a
    /// notification. Idempotent; never throws; needs no session.
    func unregisterBestEffort() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        PushRegistrar.shared.didInvalidateVoip()
        registry?.desiredPushTypes = []
        CallCoordinator.shared.signedOut()
    }

    /// Re-register for VoIP pushes after a sign-in (a fresh token arrives via
    /// `didUpdate` and goes up with register-push-token). No-op while
    /// already registered.
    func rearm() {
        guard let r = registry, !(r.desiredPushTypes ?? []).contains(.voIP) else { return }
        r.desiredPushTypes = [.voIP]
        registrationStartedAt = Date()
    }

    // MARK: PKPushRegistryDelegate (main queue)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        // A token for a registration sign-out already dropped (it was in
        // flight) is not kept: stored, it would read as "signed in" and go up
        // with the next register-push-token.
        guard registry.desiredPushTypes?.contains(.voIP) == true else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        PushRegistrar.shared.didReceiveVoip(hex)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        PushRegistrar.shared.didInvalidateVoip()
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        defer { completion() }   // AFTER the synchronous report below
        guard type == .voIP else { return }
        CallCoordinator.shared.reportIncoming(dictionary: payload.dictionaryPayload)
    }
}
