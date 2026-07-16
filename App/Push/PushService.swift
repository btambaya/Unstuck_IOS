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
    //
    // COMPLETION-HANDLER form, NOT the async variant, on BOTH delegate methods.
    // The async variant resumes on a Swift-concurrency background thread, and
    // UIKit's compiler-generated @objc completion then runs
    // _updateStateRestorationArchive…updateSnapshot: on THAT thread — which
    // asserts main-thread (_performBlockAfterCATransactionCommitSynchronizes
    // NSAssertion → SIGABRT). That was the notification-tap crash on TestFlight
    // builds 14–25 (crash log frame 6: "@objc closure #1 in
    // PushAppDelegate.userNotificationCenter(_:didReceive:)" on Thread 13).
    // With the handler form we do the work on the main actor and invoke the
    // system completion FROM the main actor, so UIKit's snapshot work runs on
    // the main thread. (The system still holds the completion until called —
    // the iOS analog of Android's goAsync() — so no begin/endBackgroundTask.)
    /// Carries a UN* completion block across the main-actor hop. The blocks
    /// aren't imported `@Sendable`, but passing one to the main actor and
    /// calling it exactly once THERE is the whole point of the crash fix.
    private struct CompletionBox<T>: @unchecked Sendable { let call: T }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let posted = PostedNotification(notification)
        let done = CompletionBox(call: completionHandler)
        Task { @MainActor in
            NotificationLog.shared.add(posted)
            done.call([.banner, .sound])
        }
    }

    // Notification taps + action buttons (spec 10 §1.3/§1.5). See the
    // main-thread-completion note above — this is the crash-fix shape.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
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

        let posted = action != nil ? PostedNotification(response.notification) : nil
        let done = CompletionBox(call: completionHandler)
        Task { @MainActor in
            if let posted { NotificationLog.shared.add(posted) }
            if let action { await PushActionHub.shared.post(action) }
            done.call()
        }
    }
}
