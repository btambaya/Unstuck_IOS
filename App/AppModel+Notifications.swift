// AppModel — notification wiring (spec 10): push-action handling (the
// Start / Reschedule and Resume / Snooze / End shade actions + push-tap
// deep links), the deep-link router (the iOS port of Android
// MainScaffold's pendingDeepLink consumption), the NotificationLevel /
// reminder-lead setters (re-sync alarms + best-effort server mirror), and
// the background one-tap reschedule (Android ScheduleCommands).

import Foundation
import UnstuckCore
import UnstuckData
import UnstuckShared
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

    /// Consume a route a Siri "open the app" App Intent stashed in the App Group
    /// (Add task, Capture, Start focus, Open today). Called on scenePhase=.active
    /// AND at the end of start(). Guarded on repos being ready so a cold-launch
    /// .active that fires before start() finishes leaves the route for start() to
    /// pick up — consumePendingRoute() clears it, so it routes exactly once.
    func consumePendingSiriRoute() {
        guard db != nil, AppGroup.hasPendingRoute() else { return }
        guard let route = AppGroup.consumePendingRoute() else { return }
        routeDeepLink(route)
    }

    /// Apply any hands-free writes a Siri intent queued while the app was closed
    /// (create task / complete / add-to-list / capture). Runs through the SAME
    /// validated mutators the UI uses — addTask/toggleDone/addCollectionItem/
    /// saveCapture — so each op flows into the normal outbox (no duplicated row
    /// logic). Called on launch / scenePhase=.active / background-entry /
    /// BG-refresh. Every op is marked processed (best-effort: a vanished target
    /// is dropped, never retried forever). Returns true if anything was applied.
    @discardableResult
    func drainSiriWriteQueue() -> Bool {
        guard write != nil else { return false }   // need an authed writer
        let ops = AppGroup.readWriteQueue()
        guard !ops.isEmpty else { return false }
        let tasks = (try? taskRepo?.all()) ?? []
        let collections = (try? db?.fetchAllCollections()) ?? []
        var processed = Set<String>()
        for op in ops {
            switch op.kind {
            case .createTask:
                if let name = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    addTask(name: name, estimateMin: op.estimateMin ?? 25)
                }
            case .completeTask:
                if let tid = op.taskId, let t = tasks.first(where: { $0.id == tid }), !t.done {
                    toggleDone(t)
                }
            case .addToList:
                if let cid = op.collectionId,
                   let body = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
                   let col = collections.first(where: { $0.id == cid }) {
                    addCollectionItem(col, body: body)
                }
            case .capture:
                if let body = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    saveCapture(Capture(id: newUUID(), tag: .idea, body: body, at: Self.isoNow()))
                }
            }
            processed.insert(op.id)
        }
        AppGroup.removeWrites(ids: processed)
        return !processed.isEmpty
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
        if link == "unstuck://new-task" {
            // Siri "Add a task" — open the New Task sheet.
            router.present(.newTask)
            return
        }
        if link == "unstuck://assistant" {
            // Siri "Ask Unstuck …" — open the assistant bubble and send the
            // stashed prompt through the Qwen agent (client-side tool execution).
            let prompt = AppGroup.consumePendingAssistantPrompt()
            router.bubbleStartTab = .assistant
            router.showBubble = true
            if let prompt, !prompt.isEmpty { assistant.send(prompt) }
            return
        }
        if link == "unstuck://focus-next" {
            // Siri "Start a focus session" — begin Focus on the Start-Next pick.
            // On a COLD Siri launch `_shareState` is still nil, so the exclude
            // set would be empty and Siri could start focus on a task I've
            // assigned away. Build the ShareModel + best-effort refresh it so
            // `assignedOutIds` is current before the pick — bounded, so a slow /
            // failed network never hangs the focus start (mirrors how
            // BackgroundSync.perform refreshes shareState before the widget snapshot).
            let share = shareState   // build the lazy model so it can populate
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await share.refresh() }
                    group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                    _ = await group.next()   // whichever finishes first: refresh or timeout
                    group.cancelAll()
                }
                let tasks = (try? taskRepo?.all()) ?? []
                let blocks = (try? db?.fetchAllCalBlocks()) ?? []
                // Never surface a task I've assigned away as the background "start
                // next" pick — it's someone else's now (parity with the widget).
                if let next = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: liveTaskId,
                                            excludeIds: share.assignedOutIds) {
                    router.beginFocus(next)
                } else {
                    router.select(.today)   // nothing to focus — land on Today
                }
            }
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
        if link == "unstuck://tasks" || link.hasPrefix("unstuck://tasks") {
            // Shared-task pushes (task_share / shared_session_start / _end /
            // shared_task_done) deep-link here. Recipients can't open the raw
            // task detail (RLS), so Today — where "Shared with you" + Delegated
            // surface these — is the calm landing.
            router.select(.today)
            return
        }
        router.select(.today)           // unstuck://today, /recap, /brief
    }

    /// True when a link opens a modal (sheet/cover) — those collide with an
    /// already-presented modal and so go through the dismiss-then-present guard.
    /// A bare tab-switch (today/recap/brief/collections-tab) doesn't.
    private func presentsModal(_ link: String) -> Bool {
        link == "capture" || link == "unstuck://capture"
            || link == "unstuck://new-task"
            || link == "unstuck://focus-next"
            || link == "unstuck://assistant"
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
    /// For a partner-shared session, refreshLiveSession() (below) broadcasts
    /// `ended: true` on the shared channel BEFORE teardown — best-effort: the
    /// channel may be down while backgrounded, in which case the partner
    /// converges via the ledger + stale-reap.
    private func endLiveSessionFromNotification() async {
        PausedCheckinScheduler.cancel()
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.sessionStart != nil else { return }
        let elapsed = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(nil)
        refreshLiveSession()
        LiveActivityController.shared.end()
        // A SHARED session (a recipient's focus on someone else's task) has no
        // local row — taskRepo.fetch(cur.taskId) misses, so the own-Session
        // fallback below would mint a phantom "Focus session" row polluting the
        // recipient's analytics while the OWNER is credited ZERO. Mirror
        // finalizeDisplacedFocus: accrue the CAPPED elapsed onto the OWNER via
        // log_shared_focus and RETURN before the fallback. The cap guards a
        // session resurrected across a background/kill (wall-clock elapsed);
        // idempotent per session id (migration 046).
        if let level = cur.sharedFocusLevel, levelCanComplete(level) {
            let capped = Self.cappedSharedElapsedSec(rawSec: elapsed, estimateMin: cur.sessionEstimateMin)
            await logSharedFocusDurable(taskId: cur.taskId, actualSec: capped,
                                        estimateMin: cur.sessionEstimateMin,
                                        sessionId: cur.id ?? newUUID())
            return
        }
        if let task = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil {
            let session = Session(id: cur.id ?? newUUID(), taskId: task.id, taskName: task.name,
                                  estimateMin: task.estimateMin, actualSec: elapsed, completedAt: Self.isoNow())
            // One true shared session: an OWNER session on a partner-shared task
            // accrues via the ledger only (same session id as the partner's
            // finalize — exactly once). This path can resurrect a session across
            // a background/kill, so the ledger amount is CAPPED like the shared
            // paths (estimate + grace); the Session row keeps the raw elapsed,
            // as today.
            let sharedLedger = accruesViaSharedLedger(cur, taskId: task.id)
            let capped = Self.cappedSharedElapsedSec(rawSec: elapsed, estimateMin: cur.sessionEstimateMin)
            finishFocus(task: task, session: session, elapsedSec: elapsed, markDone: false,
                        sharedLedger: sharedLedger, ledgerSec: sharedLedger ? capped : nil)
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
