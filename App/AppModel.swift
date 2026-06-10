// App-level state + composition root. Builds the offline store + sync
// coordinator from the injected SyncConfig (SUPABASE_HOST + ANON_KEY in
// Info.plist, sourced from Config.xcconfig / Secrets.xcconfig), starts
// the auth→hydrate→subscribe loop, and exposes signed-in state to the UI.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckShared
import UnstuckSync
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let router = AppRouter()
    private(set) var coordinator: SyncCoordinator?
    private(set) var db: AppDatabase?
    private(set) var taskRepo: TaskRepository?
    private(set) var liveStore: LiveSessionStore?
    var signedIn = false
    var configured = true
    /// Local-only WriteThrough used by the XCUITest demo boot (no coordinator).
    var uiTestWrite: WriteThrough?
    // Per-collection serial RPC queue. The optimistic local write happens
    // synchronously on the main actor; the server RPC dispatch is chained so two
    // rapid edits to the same shared collection can't reach the server out of
    // order (replaces Android's collectionMutex).
    private var collectionRPCChains: [String: Task<Void, Never>] = [:]

    /// Enqueue a shared-collection RPC, ordered after any pending RPC for the
    /// same collection.
    func enqueueCollectionRPC(_ collectionId: String, _ op: @escaping @Sendable () async -> Void) {
        let prev = collectionRPCChains[collectionId]
        collectionRPCChains[collectionId] = Task { await prev?.value; await op() }
    }
    // Local first-run flag; struggles also sync to user_preferences.
    var onboarded = UserDefaults.standard.bool(forKey: "unstuck.onboarded")

    func completeOnboarding(struggles: [String]) {
        UserDefaults.standard.set(struggles, forKey: "unstuck.adhdStruggles")
        UserDefaults.standard.set(true, forKey: "unstuck.onboarded")
        onboarded = true
        if let coord = coordinator, let uid = coord.auth.currentUserId {
            Task { try? await coord.preferences.setAdhdStruggles(userId: uid, struggles: struggles) }
        }
    }

    func sendSessionRecap(taskName: String, away: Bool = false) {
        guard let n = coordinator?.notifications else { return }
        Task { try? await n.sessionRecap(taskName: taskName, away: away) }
    }

    /// Coordinate the paused-too-long cap; calls back (main actor) with
    /// whether the local notification should fire.
    func requestPausedCheckin(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let n = coordinator?.notifications else { completion(true); return }
        Task {
            let allowed = (try? await n.pausedCheckin()) ?? true
            await MainActor.run { completion(allowed) }
        }
    }

    #if DEBUG
    /// Boot straight into the signed-in app with seeded local data and no
    /// network — for XCUITest. Triggered by the UITEST_SEED launch env var.
    func startUITestMode() {
        guard coordinator == nil, db == nil else { return }
        guard let database = try? AppDatabase.makeInMemory() else { return }
        db = database
        taskRepo = TaskRepository(database)
        liveStore = LiveSessionStore(database)
        uiTestWrite = WriteThrough(db: database)
        DemoSeed.seed(database)
        configured = true
        signedIn = true
        onboarded = true
        UserDefaults.standard.set(true, forKey: "unstuck.onboarded")
        // Debug hook: jump straight into Focus on launch (crash isolation).
        if ProcessInfo.processInfo.environment["UITEST_FOCUS"] == "1",
           let t = (try? taskRepo?.fetch(id: "t-proposal")) ?? nil {
            router.beginFocus(t)
        }
    }
    #endif

    func start() async {
        guard coordinator == nil else { return }
        guard let config = Self.loadConfig() else {
            configured = false
            return
        }
        guard let database = try? AppDatabase.make(path: Self.databasePath()) else { return }
        db = database
        taskRepo = TaskRepository(database)
        liveStore = LiveSessionStore(database)
        let provider = SupabaseClientProvider(config)
        let coord = SyncCoordinator(provider: provider, db: database)
        coordinator = coord
        signedIn = coord.auth.currentUserId != nil
        await coord.start()
        await observeAuth(coord)

        // Register the APNs token (now or when it arrives).
        PushRegistrar.shared.onToken = { [weak self] hex in self?.registerPush(hex) }
        if let existing = PushRegistrar.shared.apnsTokenHex { registerPush(existing) }

        // Register Live Activity per-update push tokens as they're issued.
        LiveActivityController.shared.onPushToken = { [weak self] activityId, token in
            self?.registerLiveActivityToken(activityId: activityId, token: token)
        }

        // BG app refresh (spec 02-sync-engine §5): flush + hydrate, then
        // rebuild the Start-Next widget snapshot (the in-app updater only
        // runs while TodayModel is alive — mirrors Android's SyncWorker).
        BackgroundSync.perform = { [weak coord, weak self] in
            await coord?.syncNow()
            await self?.refreshWidgetSnapshot()
        }

        // Reminder scheduler + notification log + buffered push gestures
        // (spec 10): must come after repos exist so a cold launch from a
        // notification tap can resolve its task.
        startNotifications()
    }

    /// Foreground/manual sync trigger (scenePhase .active, BG refresh):
    /// flush the outbox + hydrate for the current user. No-op signed out.
    /// Also re-extends the 48h reminder horizon (spec 10 §5.3) and catches
    /// the Notification Log up on anything delivered while away.
    func syncNow() {
        ReminderScheduler.shared.resync()
        NotificationLog.shared.sweepDelivered()
        guard let coord = coordinator else { return }
        Task { await coord.syncNow() }
    }

    /// Recompute + write the Start-Next widget snapshot from the local
    /// store, then poke WidgetKit (used by the BG refresh task).
    func refreshWidgetSnapshot() {
        guard let repo = taskRepo else { return }
        let tasks = (try? repo.all()) ?? []
        let next = pickStartNext(tasks: tasks, blocks: [], liveTaskId: nil)
        let openCount = tasks.filter { !$0.done && !($0.later ?? false) }.count
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    func registerPush(_ tokenHex: String) {
        guard let coord = coordinator else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        Task { try? await coord.push.register(deviceId: deviceId, apnsToken: tokenHex) }
    }

    func registerLiveActivityToken(activityId: String, token: String) {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        Task {
            try? await coord.push.registerLiveActivityToken(
                userId: uid, deviceId: deviceId, activityId: activityId, pushToken: token, sessionId: nil)
        }
    }

    private func observeAuth(_ coord: SyncCoordinator) async {
        // Reflect auth changes into UI state. Runs for the app lifetime.
        Task { [weak self] in
            for await (event, session) in coord.auth.authStateChanges {
                _ = event
                let isAuthed = session != nil
                await MainActor.run {
                    self?.signedIn = isAuthed
                    // Re-register the APNs token on every transition to
                    // authenticated (spec 10 §1.8): sign-out deletes this
                    // device's token row, so a user switch within one launch
                    // must recreate it for the NEW user.
                    if isAuthed, let hex = PushRegistrar.shared.apnsTokenHex {
                        self?.registerPush(hex)
                    }
                }
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        // OAuth / magic-link PKCE callback → the auth client; everything
        // else (unstuck://task/…, /focus/…, /today, capture) routes to the
        // matching surface (spec 10 §1.7 push-tap deep links).
        if url.host == "auth-callback" {
            guard let coord = coordinator else { return }
            Task { _ = await coord.auth.handleCallback(url: url) }
            return
        }
        routeDeepLink(url.absoluteString)
    }

    /// The optimistic write API (local GRDB + server outbox), for features.
    /// Drives the UI instantly via each repository's ValueObservation. Falls
    /// back to the local-only writer in the XCUITest demo boot.
    var write: WriteThrough? { coordinator?.write ?? uiTestWrite }

    /// Sign out via the coordinator's spec'd path: drain the outbox
    /// (bounded), unregister this device's push token while the JWT is
    /// still valid, then sign out (spec 02 §1.7 signOutAndUnregister).
    /// Also wipe the device-local notification state (spec 10 §1.8/§1.11):
    /// the log + per-task reminder overrides, every scheduled reminder, and
    /// the pending paused check-in — so the next account on this device
    /// starts clean and never sees the previous user's task names.
    func signOut() {
        guard let coord = coordinator else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        NotificationLog.shared.clear()
        NotificationPrefs.clearUserContent()
        PausedCheckinScheduler.cancel()
        Task {
            await ReminderScheduler.shared.cancelAll()
            await coord.signOutAndUnregister(deviceId: deviceId)
        }
    }

    func saveTask(_ task: TaskItem) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertTask(task, nowISO: now) }
    }

    /// Save a task + reconcile its recurrence: materialize future cal_blocks
    /// (regenerateForTask) and drop mismatched ones. `existingBlocks` is the
    /// task's current blocks from the observed store. The horizon is anchored on
    /// the task's EARLIEST existing task-block (its real start day/time) so a
    /// recurrence change keeps the series in place instead of snapping it to
    /// 09:00 today — matching the Android setRecurrence anchor.
    func saveTaskWithRecurrence(_ task: TaskItem, existingBlocks: [CalBlock]) {
        saveTask(task)
        guard let write = coordinator?.write else { return }
        let anchor = existingBlocks.filter { isTaskBlock($0) }
            .min { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
        let startTime = anchor?.startTime ?? "09:00"
        let startDate: Date = anchor.flatMap { a in
            let parts = a.date.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? Time.civil(parts[0], parts[1], parts[2]) : nil
        } ?? Date()
        let plan = regenerateForTask(
            task: task, recurrence: task.recurrence, existingBlocks: existingBlocks,
            todayIso: Clock.todayISO(), startTime: startTime, startDate: startDate)
        let now = Self.isoNow()
        Task {
            for block in plan.toUpsert { try? await write.upsertCalBlock(block, nowISO: now) }
            for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
        }
    }

    func deleteTask(_ id: String) {
        guard let write = coordinator?.write else { return }
        Task { try? await write.deleteTask(id: id, nowISO: Self.isoNow()) }
    }

    func saveTag(_ tag: TagRow) {
        guard let write = coordinator?.write else { return }
        Task { try? await write.upsertTag(tag, nowISO: Self.isoNow()) }
    }
    /// Delete a tag and strip its name from every task (case-insensitive
    /// cascade), mirroring the web/Android deleteTag — otherwise tasks keep a
    /// dangling reference to a vocabulary entry that no longer exists.
    func deleteTag(_ id: String) {
        guard let write = coordinator?.write else { return }
        var name: String?
        if let db, let fetched = try? db.fetchById(TagRow.self, id: id) { name = fetched.name }
        let tasks = (try? taskRepo?.all()) ?? []
        Task {
            try? await write.deleteTag(id: id, nowISO: Self.isoNow())
            guard let name else { return }
            for t in tasks where (t.tags ?? []).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                var next = t
                let stripped = (t.tags ?? []).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
                next.tags = stripped.isEmpty ? nil : stripped
                next.updatedAt = Self.isoNow()
                try? await write.upsertTask(next, nowISO: Self.isoNow())
            }
        }
    }
    func saveLifeArea(_ area: LifeArea) {
        guard let write = coordinator?.write else { return }
        Task { try? await write.upsertLifeArea(area, nowISO: Self.isoNow()) }
    }
    func deleteLifeArea(_ id: String) {
        guard let write = coordinator?.write else { return }
        Task { try? await write.deleteLifeArea(id: id, nowISO: Self.isoNow()) }
    }

    var calendar: CalendarClient? { coordinator?.calendar }

    /// Save a cal_block (create or edit) + reconcile Google: PATCH if it
    /// already has an event id, otherwise INSERT and persist the new id.
    func saveBlock(_ block: CalBlock) {
        guard let write = coordinator?.write else { return }
        Task {
            try? await write.upsertCalBlock(block, nowISO: Self.isoNow())
            // Only TASK blocks mirror to Google (spec §1.6): external g_
            // blocks are read-only mirrors of the remote calendar and must
            // never be (re-)pushed; placeholders have nothing to push.
            guard isTaskBlock(block) else { return }
            guard let calendar = coordinator?.calendar, let database = db,
                  let conn = (try? database.firstCalendarConnection()) ?? nil else { return }
            let range = blockToIsoRange(block)
            // Always write task blocks to the user's PRIMARY calendar —
            // selectedCalendarIds can include read-only/subscribed calendars
            // (which 403 on insert). "primary" is Google's alias for the
            // main, always-writable calendar (Android pushBlockUpsert).
            let calId = "primary"
            if let eventId = block.externalEventId {
                try? await calendar.patchEvent(eventId: eventId, connectionId: conn.id, calendarId: calId,
                                               summary: block.taskName, start: range.start, end: range.end)
            } else if let newId = try? await calendar.insertEvent(
                connectionId: conn.id, calendarId: calId,
                summary: block.taskName, start: range.start, end: range.end) {
                var updated = block
                updated.externalEventId = newId
                try? await write.upsertCalBlock(updated, nowISO: Self.isoNow())
            }
        }
    }

    /// Delete a block locally + on Google (if it was pushed). External g_
    /// blocks never delete the underlying Google event — they only mirror
    /// it (Android pushBlockDelete returns early for EXTERNAL).
    func deleteBlock(_ block: CalBlock) {
        guard let write = coordinator?.write else { return }
        Task {
            if let eventId = block.externalEventId, !isExternalBlock(block),
               let calendar = coordinator?.calendar,
               let database = db, let conn = (try? database.firstCalendarConnection()) ?? nil {
                // Task blocks are inserted on "primary" — delete there too.
                try? await calendar.deleteEvent(eventId: eventId, connectionId: conn.id,
                                                calendarId: "primary")
            }
            try? await write.deleteCalBlock(id: block.id, nowISO: Self.isoNow())
        }
    }

    /// Move a block to a new day/time (drag-to-reschedule) + bump the task's
    /// moveCount. Pushes the change to Google.
    func moveBlock(_ block: CalBlock, toDate iso: String, startTime: String) {
        var next = block
        next.date = iso
        next.startTime = startTime
        saveBlock(next)
        guard let taskId = block.taskId, isUUID(taskId), let write = coordinator?.write,
              let repo = taskRepo, let task = (try? repo.fetch(id: taskId)) ?? nil else { return }
        let bumped = bumpMoveCount(task, nowISO: Self.isoNow())
        Task { try? await write.upsertTask(bumped, nowISO: Self.isoNow()) }
    }

    /// Schedule a task into the first free slot on `date` (default today).
    func scheduleTask(_ task: TaskItem, on date: Date = Date()) {
        let blocks = (try? db?.blocks(forTask: task.id)) ?? []
        let iso = Clock.dateISO(date)
        let slots = findFreeSlotsForDate(blocks, durationMin: task.estimateMin, isoDate: iso, now: date, limit: 1)
        scheduleTaskAt(task, date: iso, startTime: slots.first?.startTime ?? "09:00")
    }

    /// Schedule a task at an explicit day + time. Persist-or-move (1:1 with the
    /// Android scheduleTask): reuse/move the task's existing block in place,
    /// bump moveCount only on a real date/time change, and diff recurrence via
    /// regenerateForTask — so re-tapping "Schedule" or dragging an already-
    /// scheduled task doesn't create duplicate blocks or falsely trip the slip
    /// detector. Brand-new tasks (e.g. move-to-task promote) fall through to a
    /// single insert.
    func scheduleTaskAt(_ task: TaskItem, date iso: String, startTime: String) {
        guard let write = coordinator?.write else { return }
        let existing = ((try? db?.blocks(forTask: task.id)) ?? []).filter { isTaskBlock($0) }
        let now = Self.isoNow()

        func earliest(_ blocks: [CalBlock]) -> CalBlock? {
            blocks.min { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
        }

        if let recurrence = task.recurrence {
            let parts = iso.split(separator: "-").compactMap { Int($0) }
            let startDate = parts.count == 3 ? Time.civil(parts[0], parts[1], parts[2]) : Date()
            let plan = regenerateForTask(task: task, recurrence: recurrence, existingBlocks: existing,
                                         todayIso: Clock.todayISO(), startTime: startTime, startDate: startDate)
            Task {
                for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
                for b in plan.toUpsert { try? await write.upsertCalBlock(b, nowISO: now) }
            }
            // Guarantee the chosen slot is materialized (the horizon regen skips
            // today / off-pattern picks). Only when nothing already covers it.
            let coversChosen = existing.contains { $0.date == iso } || plan.toUpsert.contains { $0.date == iso }
            if !coversChosen {
                saveBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name,
                                   startTime: startTime, durationMinutes: task.estimateMin, date: iso, kind: .task))
            }
            if let anchor = earliest(existing), anchor.date != iso || anchor.startTime != startTime {
                let bumped = bumpMoveCount(task, nowISO: now)
                Task { try? await write.upsertTask(bumped, nowISO: now) }
            }
        } else if let cur = earliest(existing) {
            if cur.date != iso || cur.startTime != startTime {
                var moved = cur
                moved.date = iso
                moved.startTime = startTime
                saveBlock(moved)   // moves the Google event too (PATCH) when pushed
                let bumped = bumpMoveCount(task, nowISO: now)
                Task { try? await write.upsertTask(bumped, nowISO: now) }
            }
        } else {
            saveBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name,
                               startTime: startTime, durationMinutes: task.estimateMin, date: iso, kind: .task))
        }
    }

    /// Manual "Sync now" pull — the reconciled [-7d, +30d] Google pull
    /// (own-event + all-day filters, deletion reconcile) lives on the
    /// coordinator, which also runs it from the sign-in pipeline + syncNow.
    func pullGoogleCalendar() async {
        guard let coord = coordinator else { return }
        await coord.pullCalendar()
    }

    func saveSession(_ session: Session) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertSession(session, nowISO: now) }
    }

    func saveReasonLog(_ log: ReasonLog) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertReasonLog(log, nowISO: now) }
    }

    func saveCapture(_ capture: Capture) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertCapture(capture, nowISO: now) }
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: config

    static func loadConfig() -> SyncConfig? {
        let info = Bundle.main.infoDictionary
        guard let host = info?["SUPABASE_HOST"] as? String, !host.isEmpty,
              let key = info?["SUPABASE_ANON_KEY"] as? String, !key.isEmpty,
              let url = URL(string: "https://\(host)"),
              let redirect = URL(string: "unstuck://auth-callback")
        else { return nil }
        return SyncConfig(url: url, anonKey: key, authRedirectURL: redirect)
    }

    static func databasePath() -> String {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unstuck.sqlite").path
    }
}
