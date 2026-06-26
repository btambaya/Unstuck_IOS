// Siri "ask" intents — spoken answers WITHOUT opening the app.
//
// These run in a separate process from the app while it's backgrounded, so they
// cannot read the app-private GRDB store. Instead they read the App-Group
// `UnstuckSnapshot` the app writes on launch / every foreground sync /
// background-entry / BG-refresh (counts + task & list names, using the SAME
// bucketing the UI shows). The answer is current within the usual app cadence
// (it can lag if the app hasn't run in a long while).

import AppIntents
import UnstuckShared

/// "Hey Siri, how many tasks do I have left in UnstuckNow?"
struct PendingTaskCountIntent: AppIntent {
    static let title: LocalizedStringResource = "How Many Tasks Left"
    static let description = IntentDescription(
        "Hear how many tasks you still have to do.",
        categoryName: "Asking")
    /// Background — speaks the answer, never opens the app.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let n = AppGroup.readSnapshot().pendingCount
        let dialog: IntentDialog
        switch n {
        case 0: dialog = "You're all clear — nothing left to do."
        case 1: dialog = "You have 1 task left."
        default: dialog = "You have \(n) tasks left."
        }
        return .result(dialog: dialog)
    }
}

/// "Hey Siri, what's my next task in UnstuckNow?"
struct NextTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "What's My Next Task"
    static let description = IntentDescription(
        "Hear the next thing to focus on.",
        categoryName: "Asking")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = AppGroup.readSnapshot()
        guard let name = snap.nextTaskName else {
            return .result(dialog: "You're all clear — nothing queued up.")
        }
        if let est = snap.nextEstimateMin {
            return .result(dialog: "Next up: \(name) — about \(est) minutes.")
        }
        return .result(dialog: "Next up: \(name).")
    }
}

/// "Hey Siri, what's on my UnstuckNow today?"
struct TodayPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "What's On Today"
    static let description = IntentDescription(
        "Hear what's on your plate for today.",
        categoryName: "Asking")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = AppGroup.readSnapshot()
        let today = snap.tasks.filter { $0.today }
        guard !today.isEmpty else {
            return .result(dialog: "Nothing scheduled for today — enjoy the breathing room.")
        }
        // Speak up to the first three by name, then summarise the rest.
        let names = today.prefix(3).map { $0.name }
        let listed = names.joined(separator: ", ")
        let extra = today.count - names.count
        let dialog: IntentDialog
        if extra > 0 {
            dialog = "You have \(today.count) for today: \(listed), and \(extra) more."
        } else if today.count == 1 {
            dialog = "Just one for today: \(listed)."
        } else {
            dialog = "Today: \(listed)."
        }
        return .result(dialog: dialog)
    }
}
