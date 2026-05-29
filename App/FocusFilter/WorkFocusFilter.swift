// iOS Focus Filter: when the user has a Work (or any) Focus on, this
// intent pares Unstuck down (e.g. hide non-today tasks). perform() writes
// the App-Group flag; RootView reconciles on scenePhase=.active too (iOS
// 18 perform() can be flaky). The app reads AppGroup.focusFilterActive().

import AppIntents
import UnstuckShared

struct WorkFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Unstuck Work Focus"
    static let description = IntentDescription("Pare Unstuck down to today's work while a Focus is on.")

    @Parameter(title: "Today only", default: true)
    var hideNonToday: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: hideNonToday ? "Today only" : "All tasks")
    }

    func perform() async throws -> some IntentResult {
        AppGroup.setFocusFilter(hideNonToday: hideNonToday)
        return .result()
    }
}
