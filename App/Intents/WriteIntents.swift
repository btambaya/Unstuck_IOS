// Siri "do" intents that run HANDS-FREE — no app launch (openAppWhenRun = false).
//
// They can't touch the app-private store from this process, so they enqueue a
// normalized op to the App-Group write-queue and return a spoken confirmation.
// The app drains the queue into its real outbox via the validated mutators on
// next launch / foreground / background-entry / BG-refresh (see
// AppModel.drainSiriWriteQueue) — one write authority. Eventual consistency: the
// change lands within seconds when the app can run, else on its next launch.
// This is the simpler path the user chose over instant direct-to-backend writes.

import AppIntents
import Foundation
import UnstuckShared

/// "Add a task in UnstuckNow to call the bank."
struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let description = IntentDescription(
        "Add a new task to UnstuckNow, hands-free.",
        categoryName: "Doing")
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var taskText: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .result(dialog: "I didn't catch the task.") }
        AppGroup.enqueueWrite(PendingWrite(
            id: UUID().uuidString, kind: .createTask, text: name, createdAt: Date()))
        return .result(dialog: "Got it — added \"\(name)\".")
    }
}

/// "Capture a thought in UnstuckNow."
struct CaptureThoughtIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Thought"
    static let description = IntentDescription(
        "Drop a thought into your UnstuckNow inbox, hands-free.",
        categoryName: "Doing")
    static let openAppWhenRun = false

    @Parameter(title: "Thought", requestValueDialog: "What's on your mind?")
    var thought: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let body = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .result(dialog: "I didn't catch that.") }
        AppGroup.enqueueWrite(PendingWrite(
            id: UUID().uuidString, kind: .capture, text: body, createdAt: Date()))
        return .result(dialog: "Saved to your inbox.")
    }
}

/// "Complete the taxes task in UnstuckNow." Resolves the task by name via the
/// snapshot-backed TaskEntity (Siri disambiguates if several match).
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete a Task"
    static let description = IntentDescription(
        "Mark a task done in UnstuckNow, hands-free.",
        categoryName: "Doing")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: TaskEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppGroup.enqueueWrite(PendingWrite(
            id: UUID().uuidString, kind: .completeTask, taskId: task.id, createdAt: Date()))
        return .result(dialog: "Nice — marked \"\(task.name)\" done.")
    }
}

/// "Add milk to my Groceries list in UnstuckNow." Resolves the list by name via
/// the snapshot-backed CollectionEntity.
struct AddToListIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to a List"
    static let description = IntentDescription(
        "Add an item to one of your UnstuckNow lists, hands-free.",
        categoryName: "Doing")
    static let openAppWhenRun = false

    @Parameter(title: "Item", requestValueDialog: "What should I add?")
    var item: String

    @Parameter(title: "List")
    var list: CollectionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let body = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .result(dialog: "I didn't catch the item.") }
        AppGroup.enqueueWrite(PendingWrite(
            id: UUID().uuidString, kind: .addToList, text: body,
            collectionId: list.id, createdAt: Date()))
        return .result(dialog: "Added \"\(body)\" to \(list.name).")
    }
}
