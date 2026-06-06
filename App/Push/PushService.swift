// Push registration: request notification permission, register with APNs,
// and hand the token to AppModel → PushClient → register-push-token. The
// "Push Notifications" + Time-Sensitive capabilities must be enabled on
// the target for registration to succeed on device (it no-ops without
// the aps-environment entitlement; the code path is otherwise complete).

import SwiftUI
import UserNotifications

@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()
    private(set) var apnsTokenHex: String?
    /// Set by AppModel once the coordinator exists; called when a token arrives.
    var onToken: ((String) -> Void)?

    func didReceive(_ tokenHex: String) {
        apnsTokenHex = tokenHex
        onToken?(tokenHex)
    }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Skip the auth prompt under XCUITest so the system alert doesn't block
        // the run (the demo boot needs no push).
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" { return true }
        #endif
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushRegistrar.shared.didReceive(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] APNs registration failed: \(error.localizedDescription)")
    }

    // Show recap/check-in banners while the app is foregrounded.
    // nonisolated: UNUserNotificationCenterDelegate isn't main-actor-bound,
    // unlike UIApplicationDelegate, so this must opt out of the isolation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
