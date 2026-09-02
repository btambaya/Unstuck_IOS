// Assistant navigation — maps the tool contract's screen vocabulary
// (open_screen: today | tasks | calendar | week | month | focus | insights |
// lists | captures | settings | people | notifications, + the web's aliases)
// onto the existing tab / sheet / deep-link machinery. Extension only: no
// stored state; everything routes through AppRouter + routeDeepLink so the
// dismiss-before-present guard and the AI kill-switch keep applying.

import Foundation
import UnstuckCore

extension AppModel {

    /// Open a screen by contract name. `id` deep-links a task (tasks) or a
    /// list (lists). Returns false only for an unknown screen name.
    @discardableResult
    func openScreen(_ screen: String, id: String? = nil) -> Bool {
        switch screen.lowercased() {
        case "today", "dashboard", "home":
            dismissForNavigation()
            router.select(.today)
        case "tasks":
            if let id, let task = (try? taskRepo?.fetch(id: id)) ?? nil {
                routeDeepLink("unstuck://task/\(task.id)")
            } else {
                dismissForNavigation()
                router.select(.tasks)
            }
        case "calendar", "day", "week", "month":
            dismissForNavigation()
            router.select(.calendar)
        case "focus":
            // A live session opens the Focus screen on ITS task (the occurrence
            // row for a recurring one); with nothing running, Today's Start-Next.
            if let live = liveSession, live.sessionStart != nil {
                let tasks = (try? taskRepo?.all()) ?? []
                let blocks = (try? db?.fetchAllCalBlocks()) ?? []
                let target: TaskItem? = live.occurrenceBlockId
                    .flatMap { bid in projectOccurrences(tasks, blocks, fromISO: "0000-00-00").first { $0.id == bid } }
                    ?? tasks.first { $0.id == live.taskId }
                if let target {
                    if router.focusTask?.id != target.id { routeDeepLink("unstuck://focus/\(target.id)") }
                    return true
                }
            }
            dismissForNavigation()
            router.select(.today)
        case "insights", "analytics":
            dismissForNavigation()
            router.present(.insights)
        case "lists", "collections":
            dismissForNavigation()
            router.select(.lists)
            if let id { routeDeepLink("unstuck://collections/\(id)") }
        case "captures", "inbox":
            dismissForNavigation()
            router.present(.inbox)
        case "settings":
            dismissForNavigation()
            router.present(.settings(section: nil))
        case "people":
            dismissForNavigation()
            router.present(.settings(section: "People"))
        case "notifications":
            dismissForNavigation()
            router.present(.settings(section: "Notifications"))
        case "areas":
            dismissForNavigation()
            router.present(.settings(section: "Areas"))
        default:
            return false
        }
        return true
    }

    /// The assistant panel (or voice overlay) is up while it navigates; SwiftUI
    /// can't present a second sheet from the same host, so close ours first.
    private func dismissForNavigation() {
        router.showAssistant = false
        router.activeSheet = nil
        router.detailTask = nil
    }
}
