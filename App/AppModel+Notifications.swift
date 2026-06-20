// AppModel — notification wiring (spec 10): push-action handling (the
// Start / Reschedule and Resume / Snooze / End shade actions + push-tap
// deep links), the deep-link router (the iOS port of Android
// MainScaffold's pendingDeepLink consumption), the NotificationLevel /
// reminder-lead setters (re-sync alarms + best-effort server mirror), and
// the background one-tap reschedule (Android ScheduleCommands).

import Foundation
import UnstuckCore
import UnstuckData
import UserNotifications

extension AppModel {

    /// Wire the notification subsystem once repos exist (called from
    /// start()): consume buffered notification gestures, start the
    /// reactive reminder re-sync, and catch up the Notification Log.
    func startNotifications() {
        if let repo = taskRepo { ReminderScheduler.shared.start(repo: repo) }
        NotificationLog.shared.sweepDelivered()
        PushActionHub.shared.setHandler { [weak self] action in
            await self?.handlePushAction(action)
        }
    }

    // MARK: deep-link routing (Android MainScaffold LaunchedEffect(deepLink))

    /// Route a deep link triggered from INSIDE a sheet — defer it until that
    /// sheet finishes dismissing (the host flushes via `flushPendingDeepLink` on
    /// its sheet's onDismiss). Avoids the SwiftUI present-while-dismissing race
    /// where the second sheet silently no-ops.
    func routeDeepLinkAfterDismiss(_ link: String) {
        router.pendingDeepLink = link
    }

    /// Flush a deep link captured inside a now-dismissed sheet. Called from the
    /// host sheet's onDismiss so the target presents cleanly after the first
    /// sheet is fully gone.
    func flushPendingDeepLink() {
        guard let link = router.pendingDeepLink else { return }
        router.pendingDeepLink = nil
        routeDeepLink(link)
    }

    /// Route an `unstuck://` link (push tap, notification-center row, or
    /// notification action) to the right surface.
    func routeDeepLink(_ link: String) {
        // Dismiss-before-present guard: if a sheet/cover is already up on the
        // MainTabScaffold host, presenting another silently no-ops. Defer the
        // link, dismiss the active modal(s), and let the host's onDismiss flush
        // it. Only the modal-presenting links (focus/task/capture/collections)
        // need this; a tab-switch link can apply under an open sheet, and the
        // flush path itself re-enters with nothing presented (so no loop).
        if presentsModal(link), router.hasActivePresentation {
            routeDeepLinkAfterDismiss(link)
            router.dismissAllPresentations()
            return
        }
        if link == "capture" || link == "unstuck://capture" {
            router.present(.quickCapture)
            return
        }
        if link.hasPrefix("unstuck://focus/") {
            // "Start" on the starts-now notification → begin the session +
            // open Focus (FocusModel.init starts the timer).
            let id = String(link.dropFirst("unstuck://focus/".count))
            if let t = (try? taskRepo?.fetch(id: id)) ?? nil { router.beginFocus(t) }
            else { router.select(.today) }
            return
        }
        if link.hasPrefix("unstuck://task/") {
            let id = String(link.dropFirst("unstuck://task/".count))
            if let t = (try? taskRepo?.fetch(id: id)) ?? nil {
                router.select(.today)
                router.detailTask = t
            } else {
                router.select(.today)   // stale link / task gone
            }
            return
        }
        if link == "unstuck://collections" || link.hasPrefix("unstuck://collections") {
            router.select(.lists)       // a shared collection
            return
        }
        router.select(.today)           // unstuck://today, /recap, /brief
    }

    /// True when a link opens a modal (sheet/cover) — those collide with an
    /// already-presented modal and so go through the dismiss-then-present guard.
    /// A bare tab-switch (today/recap/brief/collections-tab) doesn't.
    private func presentsModal(_ link: String) -> Bool {
        link == "capture" || link == "unstuck://capture"
            || link.hasPrefix("unstuck://focus/")
            || link.hasPrefix("unstuck://task/")
    }

    // MARK: notification gestures (PushAppDelegate → PushActionHub)

    func handlePushAction(_ action: PushAction) async {
        switch action {
        case .open(let deepLink):
            routeDeepLink(deepLink)
        case .startFocus(let taskId):
            routeDeepLink("unstuck://focus/\(taskId)")
        case .reschedule(let taskId, let blockId, let taskName, _):
            await rescheduleToNextSlot(blockId: blockId, taskId: taskId, taskName: taskName)
        case .resumeSession:
            resumeLiveSessionFromNotification()
        case .snoozeCheckin(let taskName):
            // Snooze == re-arm the same ~14-min check (spec 10 §1.6).
            PausedCheckinScheduler.schedule(taskName: taskName)
        case .endSession:
            await endLiveSessionFromNotification()
        }
    }

    // MARK: one-tap background reschedule (Android ScheduleCommands)

    /// Move a task's block to the next free slot today (else +1h), bump its
    /// move-count (a real slip signal), re-arm the reminders for the new
    /// time, and confirm with a brief notification. Runs without UI.
    func rescheduleToNextSlot(blockId: String, taskId: String, taskName: String) async {
        guard let write = self.write, let db else { return }
        let blocks = (try? db.fetchAllCalBlocks()) ?? []
        guard var block = blocks.first(where: { $0.id == blockId }) else { return }
        let task = (try? taskRepo?.fetch(id: taskId)) ?? nil
        let estimate = task?.estimateMin ?? block.durationMinutes
        let today = Clock.todayISO()
        let slot = findFreeSlotsForDate(blocks, durationMin: estimate, isoDate: today, now: Date(), limit: 1).first
        let newTime = slot?.startTime ?? Self.plusHour(block.startTime)
        block.date = slot?.date ?? today
        block.startTime = newTime
        try? await write.upsertCalBlock(block, nowISO: Self.isoNow())
        if let task {
            try? await write.upsertTask(bumpMoveCount(task, nowISO: Self.isoNow()), nowISO: Self.isoNow())
        }
        ReminderScheduler.shared.resync()
        await Self.postRescheduleConfirmation(taskName: taskName, newTime: newTime, taskId: taskId)
    }

    /// HH:MM + 60 min, clamped to the end of the day (Android plusHour).
    static func plusHour(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        let h = p.count > 0 ? p[0] : 9
        let m = p.count > 1 ? p[1] : 0
        let total = min(h * 60 + m + 60, 23 * 60 + 59)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Brief "Rescheduled" confirmation replacing the start-now/drift
    /// notification; auto-dismissed after ~8 s (Android setTimeoutAfter).
    static func postRescheduleConfirmation(taskName: String, newTime: String, taskId: String) async {
        let c = UNMutableNotificationContent()
        c.title = "Rescheduled"
        c.body = "\u{201C}\(taskName)\u{201D} moved to \(formatTime(newTime))."
        c.threadIdentifier = NotificationCategories.Thread.reminders
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["kind": "reminder", "deepLink": "unstuck://task/\(taskId)"]
        let id = "unstuck.resched.\(taskId)"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: c, trigger: nil))
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // MARK: paused check-in actions (Resume / End, app possibly backgrounded)

    /// Resume the persisted live session from the notification shade. The
    /// Focus screen (if later reopened) re-reads the store, so the session
    /// keeps counting true focus time.
    private func resumeLiveSessionFromNotification() {
        PausedCheckinScheduler.cancel()
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.paused else { return }
        let resumed = FocusTimer.resume(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(resumed)
        refreshLiveSession()
        LiveActivityController.shared.update(
            sessionStartMs: resumed.sessionStart ?? 0, paused: false,
            estimateMin: resumed.sessionEstimateMin)
    }

    /// End the persisted live session from the shade: write the Session,
    /// accumulate focus time, send the recap — same path as the in-app Done.
    private func endLiveSessionFromNotification() async {
        PausedCheckinScheduler.cancel()
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.sessionStart != nil else { return }
        let elapsed = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(nil)
        refreshLiveSession()
        LiveActivityController.shared.end()
        if let task = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil {
            let session = Session(id: cur.id ?? newUUID(), taskId: task.id, taskName: task.name,
                                  estimateMin: task.estimateMin, actualSec: elapsed, completedAt: Self.isoNow())
            finishFocus(task: task, session: session, elapsedSec: elapsed, markDone: false)
        } else {
            saveSession(Session(id: cur.id ?? newUUID(), taskId: cur.taskId, taskName: "Focus session",
                                estimateMin: cur.sessionEstimateMin, actualSec: elapsed, completedAt: Self.isoNow()))
        }
    }

    // MARK: NotificationLevel + reminder lead (spec 10 §1.12)

    /// Change the notification level: re-sync the reminder alarms and
    /// mirror the level-derived booleans to notification_preferences so
    /// the cron morning-brief + server paused-checkin cap honour it —
    /// best-effort, only when the value actually changed.
    func setNotificationLevel(_ level: NotificationLevel) {
        guard NotificationPrefs.level != level else { return }
        NotificationPrefs.level = level
        ReminderScheduler.shared.resync()
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        Task {
            try? await coord.preferences.setNotificationLevel(
                userId: uid, morningBrief: level.morningBrief, pausedCheckin: level.pausedCheckin)
        }
    }

    /// Change the global "remind me N min before" lead (0 = Off) and
    /// re-sync the alarms.
    func setReminderLeadMin(_ minutes: Int) {
        guard NotificationPrefs.reminderLeadMin != minutes else { return }
        NotificationPrefs.reminderLeadMin = minutes
        ReminderScheduler.shared.resync()
    }
}
