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

    nonisolated static let accountSignedInKey = "unstuck.push.accountSignedIn"

    /// Whether an account is signed in on this device, persisted: the launch
    /// path (before AppModel.start) and a killed-state VoIP push have no
    /// session to ask. true = signed in; false = signed out here (the sign-out
    /// scrub wrote it); nil = never recorded (an install from before this
    /// flag) — callers keep their old behaviour then. A signed-out device
    /// neither registers for pushes nor shows or logs one: the server's row
    /// for the previous account survives an offline or reactive sign-out, so
    /// its briefs, share pushes and calls kept reaching the phone (audit
    /// 2026-09-22, C36).
    nonisolated static var accountSignedIn: Bool? {
        get { UserDefaults.standard.object(forKey: accountSignedInKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: accountSignedInKey) }
    }

    /// When the outstanding registerForRemoteNotifications() was made (its
    /// token arrives via didReceive) — so the launch path and a sign-in don't
    /// both ask.
    private(set) var apnsRequestedAt: Date?

    /// How long an unanswered request holds off the next one. A re-register
    /// right after sign-out's unregister (sign-out → sign-in in one process)
    /// is not verified to always call back, and a request that never answered
    /// used to block every later one until a relaunch — the next account got
    /// no alert pushes (audit 2026-09-22, C36).
    nonisolated static let apnsRequestLapse: TimeInterval = 30

    /// Pure: whether `requestAPNsToken` asks now.
    nonisolated static func shouldRequestAPNs(accountSignedIn: Bool?, requestedAt: Date?, now: Date) -> Bool {
        guard accountSignedIn != false else { return false }
        guard let requestedAt else { return true }
        return now.timeIntervalSince(requestedAt) >= apnsRequestLapse
    }

    /// Ask APNs for the alert-push token, if notifications are allowed and
    /// this device isn't signed out. A signed-out launch skips it (see
    /// `accountSignedIn`), so the next sign-in asks here; a signed-in
    /// foreground with no token yet asks again (AppModel.syncNow).
    func requestAPNsToken() {
        let now = Date()
        guard Self.shouldRequestAPNs(accountSignedIn: Self.accountSignedIn, requestedAt: apnsRequestedAt, now: now)
        else { return }
        apnsRequestedAt = now
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard [.authorized, .provisional, .ephemeral].contains(status) else { apnsRequestedAt = nil; return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// AppModel.start, once the stored session has been read: record whether
    /// an account is signed in here. An install from before the flag that
    /// launches signed out records false AND drops both registrations then
    /// and there: the launch path had already asked for both (the flag was
    /// unset), and a token that came back before this point was kept — so the
    /// old account's briefs and share pushes kept reaching a phone signed out
    /// on build 85 or earlier (audit 2026-09-22, C36). Only while protected
    /// data is available: before the first unlock after a reboot the session
    /// (and this flag) read as absent even on a signed-in phone.
    func recordLaunch(sessionFound: Bool, protectedDataAvailable: Bool) {
        if sessionFound {
            Self.accountSignedIn = true
        } else if Self.accountSignedIn == nil, protectedDataAvailable {
            Self.accountSignedIn = false
            unregisterFromAPNs()
            VoipPushRegistry.shared.unregisterBestEffort()
        }
    }

    /// Sign-out: stop this device receiving the account's alert pushes. The
    /// server row is deleted only by an online button sign-out; after an
    /// offline or reactive one the old account's morning briefs and share
    /// pushes kept arriving. Unregistered, the phone drops them and APNs
    /// answers 410, which the senders prune on (audit 2026-09-22, C36).
    func unregisterFromAPNs() {
        apnsRequestedAt = nil
        apnsTokenHex = nil
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    func didFailToRegister() {
        apnsRequestedAt = nil
    }
    /// The PushKit VoIP token (C1 "Unstuck calls you"), hex. Persisted by
    /// VoipPushRegistry; surfaces here so Settings can show "this iPhone can
    /// take calls" and so a refresh re-registers BOTH tokens.
    private(set) var voipTokenHex: String? = VoipPushRegistry.storedToken
    /// Wired by CallCoordinator.attach(model:) → AppModel.registerPush.
    var onVoipToken: ((String) -> Void)?

    func didReceive(_ tokenHex: String) {
        apnsRequestedAt = nil
        // A registration that was in flight when the account signed out: undo
        // it rather than keep (or upload) a token nobody is signed in for.
        guard Self.accountSignedIn != false else {
            UIApplication.shared.unregisterForRemoteNotifications()
            return
        }
        apnsTokenHex = tokenHex
        onToken?(tokenHex)
    }

    func didReceiveVoip(_ tokenHex: String) {
        voipTokenHex = tokenHex
        onVoipToken?(tokenHex)
    }

    func didInvalidateVoip() {
        voipTokenHex = nil
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
        // PushKit VoIP registry (C1): must exist before launch completes so a
        // VoIP push can wake the app from a killed state and report its
        // CallKit call synchronously. Touching CallCoordinator.shared here
        // also builds the CXProvider up front.
        VoipPushRegistry.shared.start()
        _ = CallCoordinator.shared
        // Skip the auth prompt under XCUITest so the system alert doesn't block
        // the run (the demo boot needs no push).
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" { return true }
        #endif
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            // Not while signed out (PushRegistrar.accountSignedIn): this used
            // to re-register the token the sign-out had dropped.
            if granted { PushRegistrar.shared.requestAPNsToken() }
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
        Task { @MainActor in PushRegistrar.shared.didFailToRegister() }
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
    // the main thread. (The completion is the iOS analog of Android's
    // goAsync(): a background action's completion waits until PushActionHub
    // has applied it and flushed, under a background task of its own — C31.)
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
            NotificationLog.shared.add(posted)   // a no-op while signed out
            // Signed out, a push that still reaches the phone belongs to the
            // account that left: never put it on screen (audit 2026-09-22, C36).
            done.call(PushRegistrar.accountSignedIn == false ? [] : [.banner, .sound])
        }
    }

    /// `kind` of a push, whether the server put it at the top level or under
    /// `data` (the call fallback push uses `data.kind='call'`).
    nonisolated static func callKind(_ info: [AnyHashable: Any]) -> String? {
        if let k = info["kind"] as? String { return k }
        return (info["data"] as? [AnyHashable: Any])?["kind"] as? String
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

        // Fallback B for "Unstuck calls you": a time-sensitive alert push with
        // kind='call' (no VoIP token registered). A tap on it — or its
        // "Answer" action (category UNSTUCK_CALL) — opens the call
        // conversation in Talk with the same payload the VoIP path would get.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == NotificationCategories.actionAnswerCall,
           IncomingCallPayload.isCallPush(kind: PushAppDelegate.callKind(info)),
           let payload = IncomingCallPayload(dictionary: info) {
            let posted = PostedNotification(response.notification)
            let done = CompletionBox(call: completionHandler)
            Task { @MainActor in
                NotificationLog.shared.add(posted)
                CallCoordinator.shared.handleFallbackTap(payload)
                done.call()
            }
            return
        }

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
