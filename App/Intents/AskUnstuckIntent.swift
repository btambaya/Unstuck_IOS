// "Ask Unstuck …" — the freeform agent bridge. Apple's Siri can't natively
// understand a third-party app's tasks, so anything conversational ("what does
// my afternoon look like?", "move my taxes to Friday") routes to the app's OWN
// Qwen assistant, which already has the full 11-tool vocabulary.
//
// The assistant executes tools CLIENT-side (it needs the @MainActor AppModel +
// GRDB), so this opens the app: it stashes the prompt + an assistant route, and
// the app consumes them on scenePhase=.active — presents the assistant bubble and
// sends the prompt (AppModel.routeDeepLink "unstuck://assistant").

import AppIntents
import UnstuckShared

struct AskUnstuckIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Unstuck"
    static let description = IntentDescription(
        "Ask Unstuck's assistant anything about your tasks and schedule.",
        categoryName: "Asking")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask Unstuck?")
    var prompt: String

    func perform() async throws -> some IntentResult {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        AppGroup.setPendingAssistantPrompt(q.isEmpty ? nil : q)
        AppGroup.setPendingRoute("unstuck://assistant")
        return .result()
    }
}
