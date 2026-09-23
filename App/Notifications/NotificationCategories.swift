// UNNotificationCategory registry — the iOS mapping of Android's
// notification channels + shade actions (spec 10 §1.1/§5.1). Category
// identifiers are stable across releases (gotcha 6) so pending requests
// keep matching their action handlers.

import Foundation
import UnstuckSync
import UserNotifications

enum NotificationCategories {
    // Categories
    static let taskStarting = "unstuck.taskStarting"   // A2/A4 — Start / Reschedule
    static let paused = "unstuck.paused"               // B2 — Resume / Snooze / End
    /// "Unstuck calls you", fallback B: the server's time-sensitive alert push
    /// (send-call, no VoIP token) carries `aps.category = UNSTUCK_CALL` — the
    /// identifier is the SERVER's, verbatim. Its one action, Answer, opens the
    /// call conversation exactly like tapping the alert.
    static let call = "UNSTUCK_CALL"

    // Action identifiers
    static let actionStart = "unstuck.action.start"
    static let actionReschedule = "unstuck.action.reschedule"
    static let actionResume = "unstuck.action.resume"
    static let actionSnooze = "unstuck.action.snooze"
    static let actionEnd = "unstuck.action.end"
    static let actionAnswerCall = "unstuck.action.answerCall"

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
            case "collection_share", "circle_invite", "invite_claimed",
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

        // Answer opens the app into the call's Talk screen (needs .foreground).
        let answer = UNNotificationAction(identifier: actionAnswerCall, title: "Answer", options: [.foreground])
        let callCat = UNNotificationCategory(
            identifier: call, actions: [answer], intentIdentifiers: [], options: [])

        UNUserNotificationCenter.current().setNotificationCategories([starting, pausedCat, callCat])
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

    /// Registered without `.foreground` (NotificationCategories.registerAll):
    /// iOS runs it with the app in the background, launching it with no
    /// scene if it isn't running.
    var runsInBackground: Bool {
        switch self {
        case .reschedule, .resumeSession, .snoozeCheckin, .endSession: return true
        case .open, .startFocus: return false
        }
    }
}

@MainActor
final class PushActionHub {
    static let shared = PushActionHub()
    /// Buffered until start() wires the handler; `handled` is resumed once it
    /// has run (a background action's poster waits on it).
    private var pending: [(action: PushAction, handled: CheckedContinuation<Void, Never>?)] = []
    private var handler: (@MainActor (PushAction) async -> Void)?
    /// Starts the app model for a background action that found none (a test
    /// seam; production: the one a VoIP push starts, C16).
    var bootApp: @MainActor () -> Void = { Task { await AppModel.shared.startWithoutScene() } }
    /// Background time for a background action (a test seam; production: a
    /// UIApplication background task).
    var backgroundTime: CallsOutcomeReporter.BackgroundTime =
        CallsOutcomeReporter.systemBackgroundTime(named: "unstuck.shade-action")
    /// How long a background action may keep the system's completion waiting
    /// to be applied — the model's boot and the action's flush included.
    var deadline: TimeInterval = 20

    /// Dispatch now if AppModel is wired, else buffer for start(). A
    /// background action returns only once it has been applied, or at
    /// `deadline`, holding background time throughout (audit 2026-09-22,
    /// C31): it was buffered in memory and the completion called at once, so
    /// with no scene to run start() the app was suspended — often killed —
    /// before an End or a Reschedule ever happened. The caller calls the
    /// system's completion after this returns.
    func post(_ action: PushAction) async {
        guard action.runsInBackground else {
            if let handler { await handler(action) } else { pending.append((action, nil)) }
            return
        }
        let release = backgroundTime { }
        if handler == nil { bootApp() }
        _ = await AuthService.firstWithin(deadline) { [self] in
            await apply(action)
            return true
        }
        release()
    }

    /// Run the action now, or once start() wires the handler.
    private func apply(_ action: PushAction) async {
        if let handler {
            await handler(action)
            return
        }
        await withCheckedContinuation { pending.append((action, $0)) }
    }

    /// Wire the consumer + drain anything buffered during launch.
    func setHandler(_ h: @escaping @MainActor (PushAction) async -> Void) {
        handler = h
        let buffered = pending
        pending = []
        Task {
            for p in buffered {
                await h(p.action)
                p.handled?.resume()
            }
        }
    }
}
