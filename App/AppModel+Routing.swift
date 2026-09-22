// Assistant navigation — maps the tool contract's screen vocabulary
// (open_screen: today | tasks | calendar | day | week | month | focus |
// insights | lists | captures | settings | people | notifications | areas, +
// the web's aliases) onto the existing tab / sheet / deep-link machinery.
// Extension only: no stored state; everything routes through AppRouter +
// routeDeepLink so the dismiss-before-present guard and the AI kill-switch
// keep applying.
//
// Modal targets (insights / inbox / settings sections) go through
// `routeDeepLink`'s deferred path: the assistant sheet (or Talk cover) is up
// while it navigates, and presenting a second sheet on the same host while
// the first is still dismissing silently no-ops — so the link is parked on
// `router.pendingDeepLink`, the modals are torn down, and the host's
// `onDismiss` flush presents the target once they're gone.

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
                // The task the model named — a series opens its own editor
                // (owner decision, audit 2026-09-22 C3).
                routeDeepLink(Self.exactTaskLink(task.id))
            } else {
                dismissForNavigation()
                router.select(.tasks)
            }
        case "calendar":
            dismissForNavigation()
            router.select(.calendar)
        case "day", "week", "month":
            // The mode actually switches — landing on the tab in whatever mode
            // it was left in made "show me the week" a no-op.
            router.calendarMode = Self.calendarMode(for: screen)
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
            routeDeepLink("unstuck://insights")
        case "lists", "collections":
            dismissForNavigation()
            router.select(.lists)
            if let id { routeDeepLink("unstuck://collections/\(id)") }
        case "captures", "inbox":
            routeDeepLink("unstuck://inbox")
        case "settings":
            routeDeepLink("unstuck://settings")
        case "people":
            routeDeepLink("unstuck://settings?section=People")
        case "notifications":
            routeDeepLink("unstuck://settings?section=Notifications")
        case "areas":
            routeDeepLink("unstuck://settings?section=Areas")
        default:
            return false
        }
        return true
    }

    /// The assistant panel (or voice overlay) is up while it navigates to a
    /// TAB; SwiftUI applies a tab switch under a sheet, but the user should
    /// see the destination, so close ours first. Modal targets don't come
    /// through here — they take routeDeepLink's dismiss-then-present path.
    private func dismissForNavigation() {
        router.showAssistant = false
        router.showTalk = false
        router.activeSheet = nil
        router.detailTask = nil
    }

    /// `day` / `week` / `month` → the calendar mode (anything else: day).
    nonisolated static func calendarMode(for screen: String) -> AppRouter.CalendarMode {
        switch screen.lowercased() {
        case "week": return .week
        case "month": return .month
        default: return .day
        }
    }

    /// The `section=` of an `unstuck://settings?section=…` link, normalised to
    /// the names SettingsView pushes (Notifications / Interface / People /
    /// Areas). Case-insensitive; "Areas & tags" and "tags" mean Areas. nil =
    /// the Settings hub.
    nonisolated static func settingsSection(in link: String) -> String? {
        guard let comps = URLComponents(string: link),
              let raw = comps.queryItems?.first(where: { $0.name == "section" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        switch raw {
        case "notifications", "notification": return "Notifications"
        case "interface": return "Interface"
        case "people", "connections", "circle": return "People"
        case "areas", "areas & tags", "areas-and-tags", "tags", "areas-tags": return "Areas"
        default: return nil
        }
    }
}
