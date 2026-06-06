// App-level state + composition root. Builds the offline store + sync
// coordinator from the injected SyncConfig (SUPABASE_HOST + ANON_KEY in
// Info.plist, sourced from Config.xcconfig / Secrets.xcconfig), starts
// the auth→hydrate→subscribe loop, and exposes signed-in state to the UI.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckSync

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
                await MainActor.run { self?.signedIn = session != nil }
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        guard let coord = coordinator else { return }
        Task { _ = await coord.auth.handleCallback(url: url) }
    }

    /// The optimistic write API (local GRDB + server outbox), for features.
    /// Drives the UI instantly via each repository's ValueObservation. Falls
    /// back to the local-only writer in the XCUITest demo boot.
    var write: WriteThrough? { coordinator?.write ?? uiTestWrite }

    func signOut() {
        guard let coord = coordinator else { return }
        Task { await coord.auth.signOut() }
    }

    func saveTask(_ task: TaskItem) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertTask(task, nowISO: now) }
    }

    /// Save a task + reconcile its recurrence: materialize future cal_blocks
    /// (regenerateForTask) and drop mismatched ones. `existingBlocks` is the
    /// task's current blocks from the observed store.
    func saveTaskWithRecurrence(_ task: TaskItem, existingBlocks: [CalBlock]) {
        saveTask(task)
        guard let write = coordinator?.write else { return }
        let plan = regenerateForTask(
            task: task, recurrence: task.recurrence, existingBlocks: existingBlocks,
            todayIso: Clock.todayISO(), startTime: "09:00", startDate: Date())
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
            guard let calendar = coordinator?.calendar, let database = db,
                  let conn = (try? database.firstCalendarConnection()) ?? nil else { return }
            let range = blockToIsoRange(block)
            let calId = conn.selectedCalendarIds.first ?? "primary"
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

    /// Delete a block locally + on Google (if it was pushed).
    func deleteBlock(_ block: CalBlock) {
        guard let write = coordinator?.write else { return }
        Task {
            if let eventId = block.externalEventId, let calendar = coordinator?.calendar,
               let database = db, let conn = (try? database.firstCalendarConnection()) ?? nil {
                try? await calendar.deleteEvent(eventId: eventId, connectionId: conn.id,
                                                calendarId: conn.selectedCalendarIds.first ?? "primary")
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

    /// Ingest pulled Google events as local external cal_blocks (g_ ids;
    /// not synced — they live device-side, preserved across hydrate).
    func ingestExternalBlocks(_ events: [ExternalEvent]) {
        guard let db else { return }
        for ev in events { try? db.save(externalEventToBlock(ev, calendarId: ev.calendarId)) }
    }

    func pullGoogleCalendar() async {
        guard let calendar = coordinator?.calendar else { return }
        let f = ISO8601DateFormatter()
        let now = Date()
        let from = f.string(from: now.addingTimeInterval(-7 * 86_400))
        let to = f.string(from: now.addingTimeInterval(14 * 86_400))
        if let events = try? await calendar.pullEvents(from: from, to: to) {
            ingestExternalBlocks(events)
        }
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
