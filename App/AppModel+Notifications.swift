// AppModel — notification wiring (spec 10): push-action handling (the
// Start / Reschedule and Resume / Snooze / End shade actions + push-tap
// deep links), the deep-link router (the iOS port of Android
// MainScaffold's pendingDeepLink consumption), the NotificationLevel /
// reminder-lead setters (re-sync alarms + best-effort server mirror), and
// the background one-tap reschedule (Android ScheduleCommands).

import AVFoundation
import Foundation
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckShared
import UnstuckSync
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

    /// Apply any hands-free writes a Siri intent / the widget queued while the
    /// app was closed (create task / complete / add-to-list / capture). Runs
    /// through the SAME validated mutators the UI uses — addTask / toggleDone /
    /// setOccurrenceDone / addCollectionItem / saveCapture — so each op flows
    /// into the normal outbox (no duplicated row logic). Called on launch /
    /// scenePhase=.active / background-entry / BG-refresh / after the first
    /// hydrate of a sign-in.
    ///
    /// Targeted ops (complete / add-to-list) resolve against the local store:
    /// a completion id is looked up in the raw task rows AND the projected
    /// recurring occurrences (the widget's Start-Next tile carries an
    /// occurrence's cal_block id whenever a recurring task is scheduled today —
    /// a raw-row-only lookup silently dropped those, while the tile had already
    /// advanced). A target that can't be found is dropped ONLY once the store
    /// is hydrated for this sign-in; before that the op stays queued for the
    /// next drain (`handsFreeWriteMayDrop`). Returns true if anything was applied.
    @discardableResult
    func drainSiriWriteQueue() -> Bool {
        // Need an authed writer: a queue drained while signed OUT (the writer
        // still exists between accounts) would land the previous person's
        // hands-free captures in whoever signs in next.
        guard signedIn, write != nil else { return false }
        let ops = AppGroup.readWriteQueue()
        guard !ops.isEmpty else { return false }
        let tasks = (try? taskRepo?.all()) ?? []
        let blocks = (try? db?.fetchAllCalBlocks()) ?? []
        let collections = (try? db?.fetchAllCollections()) ?? []
        // "Hydrated" = the first full hydrate pass of this sign-in has run
        // (profile facts are the LAST table in that pass; the flag also flips
        // on an offline failure, so an offline relaunch — whose local rows
        // are already this account's — never strands the queue).
        let hydrated = profileFactsHydrated
        var processed = Set<String>()
        var applied = false
        for op in ops {
            var targetFound = true
            switch op.kind {
            case .createTask:
                if let name = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    addTask(name: name, estimateMin: op.estimateMin ?? 25)
                    applied = true
                }
            case .completeTask:
                switch op.taskId.flatMap({ resolveHandsFreeCompletion(id: $0, tasks: tasks, blocks: blocks) }) {
                case .task(let t):
                    if !t.done { toggleDone(t); applied = true }
                case .occurrence(let block):
                    if !block.done { setOccurrenceDone(block, done: true); applied = true }
                case nil:
                    targetFound = false
                }
            case .addToList:
                if let cid = op.collectionId,
                   let body = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    if let col = collections.first(where: { $0.id == cid }) {
                        addCollectionItem(col, body: body)
                        applied = true
                    } else {
                        targetFound = false
                    }
                }
            case .capture:
                if let body = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    saveCapture(Capture(id: newUUID(), tag: .idea, body: body, at: Self.isoNow()))
                    applied = true
                }
            }
            // An unresolved target before the first hydrate is "not pulled
            // yet", not "gone" — leave the op queued for the next drain.
            if handsFreeWriteMayDrop(targetFound: targetFound, storeHydrated: hydrated) {
                processed.insert(op.id)
            }
        }
        AppGroup.removeWrites(ids: processed)
        return applied
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
            // Siri "Ask Unstuck …" — open the assistant panel and send the
            // stashed prompt through the Qwen agent (client-side tool execution).
            let prompt = AppGroup.consumePendingAssistantPrompt()
            // The AI kill-switch wins: with the assistant off the link is
            // DROPPED — nothing opens and the stashed prompt is never sent.
            guard assistantEnabled else { return }
            // Without the AI-consent OK nothing is sent: the prompt waits in
            // the composer, and Send asks first (AppModel.withAIConsent).
            guard aiConsentGranted else {
                openAssistant(draft: prompt)
                return
            }
            openAssistant()
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
            //
            // RECURRING: resolve the id through `focusRowForId` rather than a
            // bare task fetch. A reminder carries the block's taskId — the
            // hidden TEMPLATE for a series — and focusing the template ran the
            // session with no occurrence attached, so "Done" marked the
            // template done (ending the series) and left today's occurrence
            // open. The assistant's re-open sends the OCCURRENCE row id (a
            // cal_block id), which a task fetch could never resolve, so it
            // silently landed on Today instead of the live session.
            let id = String(link.dropFirst("unstuck://focus/".count))
            let tasks = (try? taskRepo?.all()) ?? []
            let blocks = (try? db?.fetchAllCalBlocks()) ?? []
            if let t = focusRowForId(id, tasks: tasks, blocks: blocks, todayISO: Clock.todayISO()) {
                router.beginFocus(t)
            } else if let t = (try? taskRepo?.fetch(id: id)) ?? nil {
                router.beginFocus(t)
            } else {
                router.select(.today)
            }
            return
        }
        if link.hasPrefix("unstuck://task/") {
            var id = String(link.dropFirst("unstuck://task/".count))
            let exact = id.hasSuffix(Self.exactTaskLinkSuffix)
            if exact { id = String(id.dropLast(Self.exactTaskLinkSuffix.count)) }
            router.select(.today)
            // RECURRING (audit 2026-09-22, C3): resolve the id through
            // `taskLinkRowForId`, as the focus branch above does. Reminders
            // (local + server-pushed), the "Rescheduled" confirmation, Inbox
            // "Open" and the bell's logged reminder rows carry the block's
            // taskId — the hidden TEMPLATE for a series — and the template
            // editor's "Mark done" ended the whole series. The day's
            // occurrence opens instead; a cal_block id (the month peek) opens
            // that exact day. An `exactTaskLink` (a call's receipt, the
            // assistant's open_screen) opens the series itself.
            let local: TaskItem?
            if exact {
                local = (try? taskRepo?.fetch(id: id)) ?? nil
            } else {
                let tasks = (try? taskRepo?.all()) ?? []
                let blocks = (try? db?.fetchAllCalBlocks()) ?? []
                local = taskLinkRowForId(id, tasks: tasks, blocks: blocks, todayISO: Clock.todayISO())
            }
            switch Self.taskLinkRoute(id: id, isLocal: local != nil) {
            case .owner:
                router.detailTask = local
            case .shared:
                // Not in my store ⇒ not my task: a `task_share` / `invite_claimed`
                // push for a task someone shared WITH me (RLS keeps the row off
                // my device). Open the recipient's read-only detail; it loads
                // `shared_task_detail` and says so if the share is gone.
                router.sharedDetail = SharedDetailTarget(id: id)
            case .today:
                break
            }
            return
        }
        if link == "unstuck://collections" || link.hasPrefix("unstuck://collections") {
            router.select(.lists)       // a shared collection
            // `unstuck://collections/<id>` (share push, unified sharing v1):
            // park the id; the Collections tab pushes it once the row exists.
            if let id = Self.collectionLinkId(link) { router.openCollectionId = id }
            return
        }
        if link.hasPrefix("unstuck://call/") {
            // "Unstuck is calling" — stamped by send-call on the APNs fallback
            // alert (no VoIP token) and kept in the bell's Recent list. Used to
            // fall through every prefix check and land on Today.
            openCall(id: String(link.dropFirst("unstuck://call/".count)))
            return
        }
        // Assistant `open_screen` modal targets (AppModel+Routing.openScreen)
        // — router-presented sheets, so they take the dismiss-then-present
        // guard above like every other modal link.
        if link == "unstuck://insights" {
            router.present(.insights)
            return
        }
        if link == "unstuck://inbox" {
            router.present(.inbox)
            return
        }
        if link == "unstuck://settings" || link.hasPrefix("unstuck://settings?") {
            // Slim settings (2026-09-24): every old section name is an alias
            // (SettingsDestination). The bare link stays the hub — the server
            // sends it on purpose for invites and shares; People is one tap.
            switch SettingsDestination.from(link: link) {
            case .areas:
                // Areas & tags live on Tasks now: the tab + its sheet.
                router.select(.tasks)
                router.present(.areasTags)
            case .focus where liveSession?.sessionStart != nil:
                // Focus options live on the Focus screen: open the live
                // session (its ⋯ Options). With nothing running, the hub.
                openScreen("focus")
            case .hub, .focus:
                router.present(.settings(section: nil))
            case let destination:
                router.present(.settings(section: destination.rawValue))
            }
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

    /// `unstuck://call/<call_requests.id>`: a call that is ringing / in
    /// progress / buffered on the CallCoordinator resumes there (Talk
    /// take-over); a request the server is ringing RIGHT NOW is handed to the
    /// same fallback path a tap on the alert takes; a finished (or stale) call
    /// opens the receipt where it lives — the anchored task's "Call me"
    /// section — else the assistant (the conversation that books calls and
    /// answers "what was that call about?"). Never a silent Today.
    func openCall(id: String) {
        guard !id.isEmpty else { router.select(.today); return }
        if CallCoordinator.shared.resumeFromDeepLink(callId: id) { return }
        guard let coord = coordinator else { router.select(.today); return }
        // The local mirror first (offline-safe, and the realtime / catch-up
        // path keeps it current); the live read only when the mirror can't
        // answer — it has nothing yet, or not this id (a card from another
        // device that raced the mirror).
        if let local = try? coord.callsMirror.get(id: id) {
            routeResolvedCall(local)
            return
        }
        let calls = coord.calls
        Task {
            let req = try? await calls.get(id: id)
            if let req { try? coord.callsMirror.upsert(req) }
            routeResolvedCall(req)
        }
    }

    /// The tail of `openCall` once the row is known (nil = not found / offline).
    func routeResolvedCall(_ req: CallRequest?) {
        if let req, req.status == "calling" {
            // Still ringing on the server: take it now, like the alert's Answer.
            let payload = IncomingCallPayload(callId: req.id, label: req.label, notes: req.notes,
                                              taskId: req.taskId, blockId: req.blockId)
            CallCoordinator.shared.handleFallbackTap(payload)
            return
        }
        if let taskId = req?.taskId, let task = (try? taskRepo?.fetch(id: taskId)) ?? nil {
            routeDeepLink(Self.exactTaskLink(task.id))
            return
        }
        if assistantEnabled { openAssistant() } else { router.select(.today) }
    }

    /// Where `unstuck://task/<id>` lands. Pure (tested): a task in my local
    /// store is mine → the owner editor; any other non-empty id is a task
    /// shared WITH me → the shared-task sheet; an empty id → just Today.
    enum TaskLinkRoute: Equatable { case owner, shared, today }
    nonisolated static func taskLinkRoute(id: String, isLocal: Bool) -> TaskLinkRoute {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .today }
        return isLocal ? .owner : .shared
    }

    /// `unstuck://task/<id>` that opens exactly `id`, never re-resolved to a
    /// day's occurrence (audit 2026-09-22, C3). For the senders anchored to
    /// the SERIES: a call's receipt lives in the series editor's "Call me"
    /// section, which an occurrence row doesn't show (call links, the bell's
    /// call rows, the missed-call alert), and the assistant's open_screen
    /// names the task itself. Safe now that the series editor offers no
    /// "Mark done" on an open series (owner decision).
    nonisolated static let exactTaskLinkSuffix = "?exact"
    nonisolated static func exactTaskLink(_ id: String) -> String { "unstuck://task/\(id)\(exactTaskLinkSuffix)" }

    /// The `<id>` of `unstuck://collections/<id>` (nil for the bare tab link,
    /// a trailing slash, or a query-only tail).
    nonisolated static func collectionLinkId(_ link: String) -> String? {
        let prefix = "unstuck://collections/"
        guard link.hasPrefix(prefix) else { return nil }
        let tail = String(link.dropFirst(prefix.count))
            .split(whereSeparator: { $0 == "?" || $0 == "#" || $0 == "/" }).first.map(String.init) ?? ""
        return tail.isEmpty ? nil : tail
    }

    /// True when a link opens a modal (sheet/cover) — those collide with an
    /// already-presented modal and so go through the dismiss-then-present guard.
    /// A bare tab-switch (today/recap/brief/collections-tab) doesn't.
    private func presentsModal(_ link: String) -> Bool {
        link == "capture" || link == "unstuck://capture"
            || link == "unstuck://new-task"
            || link == "unstuck://focus-next"
            || link == "unstuck://assistant"
            || link == "unstuck://insights"
            || link == "unstuck://inbox"
            || link == "unstuck://settings" || link.hasPrefix("unstuck://settings?")
            || link.hasPrefix("unstuck://focus/")
            || link.hasPrefix("unstuck://task/")
    }

    // MARK: notification gestures (PushAppDelegate → PushActionHub)

    func handlePushAction(_ action: PushAction) async {
        // Signed out, a tapped notification belongs to the account that left:
        // its route used to be parked in the router and opened in the NEXT
        // account's session, and a Reschedule wrote through the writer that
        // outlives the sign-out (audit 2026-09-22, C35).
        guard signedIn else { return }
        switch action {
        case .open(let deepLink):
            routeDeepLink(deepLink)
        case .startFocus(let taskId):
            routeDeepLink("unstuck://focus/\(taskId)")
        case .reschedule(let taskId, let blockId, let taskName, _):
            await rescheduleToNextSlot(blockId: blockId, taskId: taskId, taskName: taskName)
            // The move reaches the server before the system's completion is
            // called — until then the web and the server's calls kept the old
            // slot, and an after-block call rang about a block the user had
            // moved (audit 2026-09-22, C31; Android: the drain inside goAsync).
            await flushHoldingBackgroundTime(limit: Self.shadeActionFlushLimit)
        case .resumeSession(let sessionId):
            resumeLiveSessionFromNotification(sessionId: sessionId)
        case .snoozeCheckin(let taskName, let sessionId):
            // Snooze == re-arm the same ~14-min check (spec 10 §1.6). The nag
            // that was snoozed HAS fired — settle its budget slot first, then
            // arm (and peek the cap for) the next one. Only while the session
            // it was about is still paused (audit 2026-09-22, C38).
            guard let cur = (try? liveStore?.get()) ?? nil,
                  Self.pausedCheckinActsOn(cur, sessionId: sessionId) else { return }
            cancelPausedCheckin()
            armPausedCheckin(taskName: taskName, sessionId: cur.id)
        case .endSession(let sessionId):
            await endLiveSessionFromNotification(sessionId: sessionId)
            // The Session row and the focus minutes, likewise (C31). Writes
            // finishFocus queues a moment later ride the post-write flush,
            // which holds its own background time.
            await flushHoldingBackgroundTime(limit: Self.shadeActionFlushLimit)
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
        // Through the block save, so a pushed block's Google event moves with
        // it (a bare upsert left it at the old time; audit 2026-09-22, C24).
        // No un-park here: the move-count bump below writes the task row it
        // read before this save.
        await saveBlockAwaiting(block, unpark: false)
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

    /// May a paused check-in's action touch `cur`? Only the session the nag
    /// was armed for (`sessionId`; nil = a nag from a build before this
    /// check), and only while it is still paused — a nag that outlived its
    /// session (displaced, or re-pointed to another day and resumed) must not
    /// end or resume a RUNNING one (audit 2026-09-22, C38).
    nonisolated static func pausedCheckinActsOn(_ cur: LiveSession?, sessionId: String?) -> Bool {
        guard let cur, cur.sessionStart != nil, cur.paused else { return false }
        return sessionId == nil || cur.id == sessionId
    }

    /// Resume the persisted live session from the notification shade, and
    /// have an open Focus screen follow it (C37).
    private func resumeLiveSessionFromNotification(sessionId: String?) {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              Self.pausedCheckinActsOn(cur, sessionId: sessionId) else { return }
        cancelPausedCheckin()   // the nag fired (that's what was tapped) → claims its slot
        let now = Date().timeIntervalSince1970 * 1000
        if let closed = FocusTimer.closedPauseLog(cur, now: now) { saveReasonLog(closed) }
        let resumed = FocusTimer.resume(cur, now: now)
        try? liveStore.set(resumed)
        refreshLiveSession()
        LiveActivityController.shared.update(
            sessionStartMs: resumed.sessionStart ?? 0, paused: false,
            estimateMin: resumed.sessionEstimateMin)
        noteLiveSessionChangedOffScreen()
    }

    /// End the persisted live session from the shade: write the Session,
    /// accumulate focus time, send the recap — same path as the in-app Done.
    /// For a partner-shared session, refreshLiveSession() (below) broadcasts
    /// `ended: true` on the shared channel BEFORE teardown — best-effort: the
    /// channel may be down while backgrounded, in which case the partner
    /// converges via the ledger + stale-reap.
    private func endLiveSessionFromNotification(sessionId: String?) async {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              Self.pausedCheckinActsOn(cur, sessionId: sessionId) else { return }
        cancelPausedCheckin()
        // Ending from the paused nag ends the pause too — log its length.
        if let closed = FocusTimer.closedPauseLog(cur, now: Date().timeIntervalSince1970 * 1000) { saveReasonLog(closed) }
        let elapsed = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        // Ended off the Focus screen — a session left running then paused can
        // measure a whole night: capped at the estimate + grace like the
        // shared paths (audit 2026-09-22, C43).
        let capped = Self.cappedSharedElapsedSec(rawSec: elapsed, estimateMin: cur.sessionEstimateMin)
        try? liveStore.set(nil)
        refreshLiveSession()
        LiveActivityController.shared.end()
        // A Focus screen still up would keep this clock and log it again on
        // Done (audit 2026-09-22, C37) — as the assistant's finish does.
        if router.focusTask != nil { router.focusTask = nil; router.sharedFocus = nil }
        noteLiveSessionChangedOffScreen()
        // A SHARED session (a recipient's focus on someone else's task) has no
        // local row — taskRepo.fetch(cur.taskId) misses, so the own-Session
        // fallback below would mint a phantom "Focus session" row polluting the
        // recipient's analytics while the OWNER is credited ZERO. Mirror
        // finalizeDisplacedFocus: accrue the CAPPED elapsed onto the OWNER via
        // log_shared_focus and RETURN before the fallback. The cap guards a
        // session resurrected across a background/kill (wall-clock elapsed);
        // idempotent per session id (migration 046).
        if let level = cur.sharedFocusLevel, levelCanComplete(level) {
            await logSharedFocusDurable(taskId: cur.taskId, actualSec: capped,
                                        estimateMin: cur.sessionEstimateMin,
                                        sessionId: cur.id ?? newUUID())
            releaseCaptures(ofSession: cur.id)   // no own Session row (C44)
            return
        }
        if let task = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil {
            let session = Session(id: cur.id ?? newUUID(), taskId: task.id, taskName: task.name,
                                  estimateMin: cur.sessionEstimateMin, actualSec: capped, completedAt: Self.isoNow())
            // One true shared session: an OWNER session on a partner-shared task
            // accrues via the ledger only (same session id as the partner's
            // finalize — exactly once), with the same capped amount.
            let sharedLedger = accruesViaSharedLedger(cur, taskId: task.id)
            finishFocus(task: task, session: session, elapsedSec: capped, markDone: false,
                        sharedLedger: sharedLedger)
        } else {
            saveSession(Self.goneTaskSession(cur, elapsedSec: capped))
        }
    }

    // MARK: proactive calls (calls build-out; migration 072)

    /// A toggle / time change in Settings › Notifications & calls: cache it, mark it pending,
    /// and write `notification_preferences.call_*` through — the dispatcher
    /// reads those columns, so nothing rings until the write lands. A failed
    /// push stays pending and the next hydrate re-pushes it (never pulls the
    /// server's older value over it). Only when the value actually changed.
    func setCallProactivePrefs(_ prefs: CallProactivePrefs) {
        guard prefs != callProactivePrefs || CallSettings.proactive != prefs else { return }
        callProactivePrefs = prefs
        CallSettings.proactive = prefs
        CallSettings.pendingProactivePush = true
        callPrefsPushGen += 1
        let gen = callPrefsPushGen
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        Task { [weak self] in
            do {
                try await coord.preferences.setCallProactivePrefs(userId: uid, prefs: prefs)
                guard let self, coord.auth.currentUserId == uid, self.callPrefsPushGen == gen else { return }
                CallSettings.pendingProactivePush = false
            } catch {}
        }
    }

    /// The server's proactive-call row landed (hydrate / a preferences
    /// realtime event): the account is the source of truth, so it replaces
    /// the cache — unless a change made here is still waiting to go up.
    func applyServerCallProactivePrefs(_ server: CallProactivePrefs) {
        guard !CallSettings.pendingProactivePush else { return }
        if CallSettings.proactive != server { CallSettings.proactive = server }
        if callProactivePrefs != server {
            callProactivePrefs = server
            // A proactive call switched on elsewhere now rings here (C13).
            askForCallMicrophoneIfNeeded()
        }
    }

    // MARK: the microphone for calls (audit 2026-09-22, C13)

    /// Ask for the microphone once a call can ring on this phone. Calls
    /// booked on the web, on Android or by the server (proactive, after a
    /// block, retries) ring here without iOS ever asking, and a lock-screen
    /// answer can't show the prompt — so the first answered call couldn't
    /// hear them. Only while the app is ACTIVE (never from a scene-less VoIP
    /// boot or the background), signed in, onboarded, Calls on here, and
    /// still undetermined: iOS shows the prompt once ever, so afterwards
    /// this is a cheap read. The mirror counts rows of any status, so a
    /// first failed call still asks on the next open.
    func askForCallMicrophoneIfNeeded() {
        guard UIApplication.shared.applicationState == .active,
              AVAudioApplication.shared.recordPermission == .undetermined,
              signedIn, onboarded, let coord = coordinator, coord.auth.currentUserId != nil,
              CallSettings.expectsCalls(hasCallRows: (try? coord.callsMirror.isEmpty()) == false) else { return }
        CallSettingsView.ensureMicrophone { _ in }
    }

    /// The moments scenePhase can't give askForCallMicrophoneIfNeeded: a
    /// cold launch (.active can land before start() built the coordinator —
    /// the observation's first value is that check) and call rows that land
    /// while the app is open (a first sign-in's hydrate, a call booked on
    /// the web just now). Ends once iOS has an answer.
    func startCallMicrophoneBackstop() {
        guard let mirror = coordinator?.callsMirror,
              AVAudioApplication.shared.recordPermission == .undetermined else { return }
        Task { [weak self] in
            do {
                for try await _ in mirror.observeLive() {
                    guard let self, AVAudioApplication.shared.recordPermission == .undetermined else { return }
                    self.askForCallMicrophoneIfNeeded()
                }
            } catch {}
        }
    }

    /// Settings › Notifications & calls opened: re-read the server row (best-effort) so a
    /// toggle flipped on another device shows here without waiting for the
    /// next gap trigger.
    func refreshCallProactivePrefs() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let prefs = coord.preferences
        Task { [weak self] in
            guard let server = try? await prefs.callProactivePrefs(userId: uid),
                  let self, coord.auth.currentUserId == uid else { return }
            self.applyServerCallProactivePrefs(server)
        }
    }

    // MARK: NotificationLevel + reminder lead (spec 10 §1.12)

    /// Change the notification level (Settings): re-sync the reminder alarms
    /// and write the level — plus its derived booleans, for the cron
    /// morning-brief + server paused-checkin cap — through to
    /// `notification_preferences`, the same columns the web reads back. Only
    /// when the value actually changed. Same path as the assistant's
    /// `set_notification_level` (setNotificationLevelAwaiting).
    func setNotificationLevel(_ level: NotificationLevel) {
        guard NotificationPrefs.level != level else { return }
        Task { await setNotificationLevelAwaiting(level) }
    }

    /// Change the global "remind me N min before" lead (0 = Off): re-sync the
    /// alarms and write `reminder_lead_min` through (was: local only, so the
    /// web and a second device kept a different lead).
    func setReminderLeadMin(_ minutes: Int) {
        guard NotificationPrefs.reminderLeadMin != minutes else { return }
        Task { await setReminderLeadAwaiting(minutes) }
    }

    /// The server's level + lead landed (hydrate): the server is the
    /// account-wide source of truth, so a non-null value replaces the local
    /// cache; null (never set on any device) keeps the local one. Re-arms the
    /// alarms when anything changed.
    func applyServerNotificationPrefs(_ row: NotificationPrefsRow) {
        var changed = false
        if let level = NotificationPrefs.level(fromServer: row.level), level != NotificationPrefs.level {
            NotificationPrefs.level = level
            changed = true
        }
        if let lead = row.reminderLeadMin, lead != NotificationPrefs.reminderLeadMin {
            NotificationPrefs.reminderLeadMin = lead
            changed = true
        }
        if changed { ReminderScheduler.shared.resync() }
    }
}
