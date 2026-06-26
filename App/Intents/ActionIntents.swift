// Siri "do" intents — Phase 1: open the app to the right surface.
//
// Each intent sets a pending route in the App Group and opens the app
// (openAppWhenRun); the app consumes the route on scenePhase=.active and drives
// SwiftUI navigation (AppModel.consumePendingSiriRoute → routeDeepLink). We do
// NOT navigate from perform() directly: a background/extension process can't
// touch the @MainActor AppModel/router reliably, and the reconcile-on-active
// hand-off is the same pattern WorkFocusFilter already trusts.
//
// Phase 3 adds truly hands-free variants (create/complete without opening the
// app) via a shared write-queue; these open-app intents remain the explicit
// "take me there" path.

import AppIntents
import UnstuckShared

/// "Add a task in UnstuckNow" → opens the New Task sheet.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let description = IntentDescription(
        "Open UnstuckNow to add a new task.",
        categoryName: "Doing")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://new-task")
        return .result()
    }
}

/// "Capture a thought in UnstuckNow" → opens the quick-capture inbox sheet.
struct CaptureThoughtIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Thought"
    static let description = IntentDescription(
        "Open UnstuckNow to jot something into your inbox.",
        categoryName: "Doing")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://capture")
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
