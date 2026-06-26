// Siri "ask" intents — spoken answers WITHOUT opening the app.
//
// These run in a separate process from the app while it's backgrounded, so they
// cannot read the app-private GRDB store. Instead they read the small App-Group
// snapshot the app already writes on task changes / sync / foreground
// (StartNextSnapshot in UnstuckShared) — exactly what the home-screen widget
// reads. `openCount` is the app's "pending" definition (done==false && !later);
// `taskName`/`estimateMin` are the Start-Next pick. The snapshot is refreshed by
// the BG-refresh task + on every foreground, so the answer is current within the
// usual app cadence (it can lag if the app hasn't run in a long while).

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
        let n = AppGroup.readStartNext().openCount
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
        let snap = AppGroup.readStartNext()
        guard let name = snap.taskName else {
            return .result(dialog: "You're all clear — nothing queued up.")
        }
        if let est = snap.estimateMin {
            return .result(dialog: "Next up: \(name) — about \(est) minutes.")
        }
        return .result(dialog: "Next up: \(name).")
    }
}
