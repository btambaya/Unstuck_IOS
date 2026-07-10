// UNNotificationCategory registry — the iOS mapping of Android's
// notification channels + shade actions (spec 10 §1.1/§5.1). Category
// identifiers are stable across releases (gotcha 6) so pending requests
// keep matching their action handlers.

import Foundation
import UserNotifications

enum NotificationCategories {
    // Categories
    static let taskStarting = "unstuck.taskStarting"   // A2/A4 — Start / Reschedule
    static let paused = "unstuck.paused"               // B2 — Resume / Snooze / End

    // Action identifiers
    static let actionStart = "unstuck.action.start"
    static let actionReschedule = "unstuck.action.reschedule"
    static let actionResume = "unstuck.action.resume"
    static let actionSnooze = "unstuck.action.snooze"
    static let actionEnd = "unstuck.action.end"

    /// Thread identifiers grouping notifications like Android's channels.
    enum Thread {
        static let reminders = "unstuck_reminders"
        static let recap = "unstuck_recap"
        static let paused = "unstuck_paused"
        static let daily = "unstuck_daily"
        static let nudges = "unstuck_nudges"
        static let collab = "unstuck_collab"

        /// Map the server's `data.kind` to a thread (Android channelFor).
        static func forKind(_ kind: String?) -> String {
            switch kind {
            case "session_recap": return recap
            case "paused_checkin": return paused
            case "morning_brief", "evening_preview", "daily_nudge": return daily
            case "reminder", "event_soon": return reminders
            case "collection_share",
                 "task_share", "shared_session_start", "shared_session_end", "shared_task_done":
                return collab
            default: return recap
            }
        }
    }

    /// Register all actionable categories. Called once at launch, before
    /// any notification is scheduled or received.
    static func registerAll() {
        // Start opens the app straight into Focus (needs .foreground);
        // Reschedule runs in the background without opening the app.
        let start = UNNotificationAction(identifier: actionStart, title: "Start", options: [.foreground])
        let reschedule = UNNotificationAction(identifier: actionReschedule, title: "Reschedule", options: [])
        let starting = UNNotificationCategory(
            identifier: taskStarting, actions: [start, reschedule], intentIdentifiers: [], options: [])

        let resume = UNNotificationAction(identifier: actionResume, title: "Resume", options: [])
        let snooze = UNNotificationAction(identifier: actionSnooze, title: "Snooze", options: [])
        let end = UNNotificationAction(identifier: actionEnd, title: "End", options: [])
        let pausedCat = UNNotificationCategory(
            identifier: paused, actions: [resume, snooze, end], intentIdentifiers: [], options: [])

        UNUserNotificationCenter.current().setNotificationCategories([starting, pausedCat])
    }
}

/// One user gesture on a notification (tap or action button), decoupled
/// from the delegate so AppModel can consume it whenever it's ready — on a
/// cold launch from a notification the delegate fires before AppModel.start()
/// has built the coordinator, so gestures are buffered (the iOS analog of
/// Android's pendingDeepLink StateFlow).
enum PushAction: Sendable {
    case open(deepLink: String)
    case startFocus(taskId: String)
    case reschedule(taskId: String, blockId: String, taskName: String, drifted: Bool)
    case resumeSession
    case snoozeCheckin(taskName: String)
    case endSession
}

@MainActor
final class PushActionHub {
    static let shared = PushActionHub()
    private var pending: [PushAction] = []
    private var handler: (@MainActor (PushAction) async -> Void)?

    /// Dispatch now if AppModel is wired, else buffer for start().
    func post(_ action: PushAction) async {
        if let handler { await handler(action) } else { pending.append(action) }
    }

    /// Wire the consumer + drain anything buffered during launch.
    func setHandler(_ h: @escaping @MainActor (PushAction) async -> Void) {
        handler = h
        let buffered = pending
        pending = []
        Task { for a in buffered { await h(a) } }
    }
}
