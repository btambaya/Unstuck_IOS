// ReminderScheduler — arms the three on-device reminders (LEAD / ATSTART /
// DRIFTED) as local notifications over a 48h horizon (spec 10 §1.2/§5.4).
// The which-alarms decision is the pure UnstuckCore.planReminders (unit-
// tested); this maps PlannedReminders onto UNNotificationRequests with
// UNCalendarNotificationTrigger, diffing pending identifiers so stale
// requests are removed (Android's prev − now cancellation). Re-syncs
// reactively on every blocks/tasks/live-session change (GRDB observation)
// — which is also how completing a task or starting Focus on it cancels
// its pending ATSTART/DRIFTED (the gotcha-8 inversion of Android's
// fire-time re-check) — and rebuilds on launch/foreground/settings change.

import Foundation
import UnstuckCore
import UnstuckData
import UserNotifications

@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    /// Identifier scheme: "unstuck.rem.<tag>:<blockId>" — the family + id
    /// scheme from spec 10 §4.7, so a lead, a starts-now, and a drift for
    /// the same block coexist while a re-issue updates in place.
    static let idPrefix = "unstuck.rem."

    private var observeTask: Task<Void, Never>?
    private var repo: TaskRepository?

    private init() {}

    /// Re-sync reminders whenever blocks, tasks, or the live session change
    /// while the app is alive (Android ReminderScheduler.observe).
    func start(repo: TaskRepository) {
        self.repo = repo
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let stream = self?.repo?.observeReminderInputs() else { return }
            do {
                for try await snap in stream {
                    await self?.sync(blocks: snap.blocks, tasks: snap.tasks, liveTaskId: snap.liveTaskId)
                }
            } catch {}
        }
    }

    /// Rebuild all reminders from the current store — used on foreground
    /// (the 48h horizon must re-extend) and after a settings change.
    func resync() {
        guard let repo else { return }
        Task {
            // One snapshot only (first emission); `first(where:)` trips
            // Swift 6 sending checks from a @MainActor context, so loop+break.
            do {
                for try await snap in repo.observeReminderInputs() {
                    await sync(blocks: snap.blocks, tasks: snap.tasks, liveTaskId: snap.liveTaskId)
                    break
                }
            } catch {}
        }
    }

    /// Cancel every scheduled reminder (sign-out: the next account on this
    /// device must not inherit the previous user's task reminders).
    func cancelAll() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ours)
    }

    private func sync(blocks: [CalBlock], tasks: [TaskItem], liveTaskId: String?) async {
        let plans = planReminders(
            blocks: blocks, tasks: tasks,
            level: NotificationPrefs.level,
            globalLeadMin: NotificationPrefs.reminderLeadMin,
            overrides: NotificationPrefs.overridesByTask(),
            liveTaskId: liveTaskId,
            now: Date().timeIntervalSince1970 * 1000)

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let prev = Set(pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) })
        let now = Set(plans.map { Self.idPrefix + $0.key })

        // prev − now: cancel reminders whose block moved / completed / left
        // the horizon (and ATSTART/DRIFTED for the focused task).
        let stale = prev.subtracting(now)
        if !stale.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        for plan in plans {
            let fireDate = Date(timeIntervalSince1970: plan.fireAt / 1000)
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.idPrefix + plan.key, content: content(for: plan), trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func content(for plan: PlannedReminder) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.threadIdentifier = NotificationCategories.Thread.reminders
        c.interruptionLevel = .timeSensitive
        c.sound = .default
        // No badge on any moment (spec 10 §1.1).
        switch plan.kind {
        case .lead:
            c.title = "Coming up"
            c.body = reminderLeadBody(taskName: plan.taskName, leadMin: plan.leadMinutes)
            c.userInfo = [
                "kind": "reminder",
                "deepLink": reminderDeepLink(taskId: plan.taskId),
            ]
        case .atstart, .drifted:
            let drifted = plan.kind == .drifted
            c.title = taskStartingTitle(drifted: drifted)
            c.body = taskStartingBody(taskName: plan.taskName, drifted: drifted)
            c.categoryIdentifier = NotificationCategories.taskStarting
            c.userInfo = [
                "kind": drifted ? "drifted" : "atstart",
                "deepLink": "unstuck://task/\(plan.taskId)",
                "taskId": plan.taskId,
                "blockId": plan.blockId,
                "taskName": plan.taskName,
                "drifted": drifted,
            ]
        }
        return c
    }
}
