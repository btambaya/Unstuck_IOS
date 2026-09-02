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

    private override init() { super.init() }

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
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    // MARK: PKPushRegistryDelegate (main queue)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
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
