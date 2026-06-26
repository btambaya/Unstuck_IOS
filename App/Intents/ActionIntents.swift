// Siri "do" intents that OPEN the app to the right surface.
//
// Each intent sets a pending route in the App Group and opens the app
// (openAppWhenRun); the app consumes the route on scenePhase=.active and drives
// SwiftUI navigation (AppModel.consumePendingSiriRoute → routeDeepLink). We do
// NOT navigate from perform() directly: a background/extension process can't
// touch the @MainActor AppModel/router reliably, and the reconcile-on-active
// hand-off is the same pattern WorkFocusFilter already trusts.
//
// Hands-free create/complete/add/capture (no app launch) live in WriteIntents;
// these open-app intents are the explicit "take me there" path. AddTaskIntent
// stays available in the Shortcuts app as an open-app alternative to the
// hands-free CreateTaskIntent.

import AppIntents
import UnstuckShared

/// "Add a task in UnstuckNow" (open-app variant) → opens the New Task sheet.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task (Open App)"
    static let description = IntentDescription(
        "Open UnstuckNow to add a new task.",
        categoryName: "Doing")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://new-task")
        return .result()
    }
}

/// "Start a focus session in UnstuckNow" → begins Focus on the Start-Next pick.
struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Focus Session"
    static let description = IntentDescription(
        "Open UnstuckNow and start focusing on your next task.",
        categoryName: "Doing")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://focus-next")
        return .result()
    }
}

/// "Open UnstuckNow" / "Show my UnstuckNow today" → the Today tab.
struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription(
        "Open UnstuckNow to your Today view.",
        categoryName: "Doing")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://today")
        return .result()
    }
}
