// Interactive widget buttons (iOS 17 Button(intent:)). These run in the widget
// process and only touch the App Group — no app-target types needed.
//
// Complete is hands-free: it queues a completeTask op (drained by the app into
// its outbox) and optimistically patches the snapshot so the tile updates at
// once. Start opens the app to a focus session on the Start-Next pick.

import AppIntents
import Foundation
import WidgetKit
import UnstuckShared

/// "Done" — complete the task the widget currently shows.
struct CompleteStartNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Start Next"
    static let description = IntentDescription("Mark the Start-Next task done.")

    func perform() async throws -> some IntentResult {
        let snap = AppGroup.readStartNext()
        guard let id = snap.taskId else { return .result() }
        AppGroup.enqueueWrite(PendingWrite(
            id: UUID().uuidString, kind: .completeTask, taskId: id, createdAt: Date()))
        AppGroup.optimisticComplete(taskId: id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// "Start" — open the app and begin Focus on the Start-Next pick.
struct StartFocusWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Start focusing on the Start-Next task.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppGroup.setPendingRoute("unstuck://focus-next")
        return .result()
    }
}
