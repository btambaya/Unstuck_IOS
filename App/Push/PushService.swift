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
        // Action categories (Start/Reschedule, Resume/Snooze/End) must be
        // registered before any notification is scheduled or received.
        NotificationCategories.registerAll()
        // BG refresh must register its handler before launch completes.
        BackgroundSync.register()
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

    // Show recap/check-in banners while the app is foregrounded, and append
    // them to the in-app Notification Log (spec 10 §1.7/§1.10).
    // nonisolated: UNUserNotificationCenterDelegate isn't main-actor-bound,
    // unlike UIApplicationDelegate, so this must opt out of the isolation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let posted = PostedNotification(notification)
        await MainActor.run { NotificationLog.shared.add(posted) }
        return [.banner, .sound]
    }

    // Notification taps + action buttons (spec 10 §1.3/§1.5). The async
    // variant holds the system completion until the GRDB write finishes
    // (the iOS analog of Android's goAsync()); a background-task assertion
    // keeps the process alive for the no-UI Reschedule path.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let info = content.userInfo
        let deepLink = info["deepLink"] as? String
        let taskId = info["taskId"] as? String ?? ""
        let blockId = info["blockId"] as? String ?? ""
        let taskName = (info["taskName"] as? String)
            ?? (content.body.isEmpty ? "your task" : content.body)
        let drifted = info["drifted"] as? Bool ?? false

        let action: PushAction?
        switch response.actionIdentifier {
        case NotificationCategories.actionStart:
            action = .startFocus(taskId: taskId)
        case NotificationCategories.actionReschedule:
            action = .reschedule(taskId: taskId, blockId: blockId, taskName: taskName, drifted: drifted)
        case NotificationCategories.actionResume:
            action = .resumeSession
        case NotificationCategories.actionSnooze:
            action = .snoozeCheckin(taskName: taskName)
        case NotificationCategories.actionEnd:
            action = .endSession
        case UNNotificationDefaultActionIdentifier:
            action = .open(deepLink: deepLink ?? "unstuck://today")
        default:
            action = nil   // dismissed
        }
        guard let action else { return }

        let posted = PostedNotification(response.notification)
        let bgTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "unstuck.notif.action", expirationHandler: nil)
        }
        await MainActor.run { NotificationLog.shared.add(posted) }
        await PushActionHub.shared.post(action)
        await MainActor.run { UIApplication.shared.endBackgroundTask(bgTask) }
    }
}
