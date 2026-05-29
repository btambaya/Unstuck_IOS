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
    }

    func registerPush(_ tokenHex: String) {
        guard let coord = coordinator else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        Task { try? await coord.push.register(deviceId: deviceId, apnsToken: tokenHex) }
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
    /// Drives the UI instantly via each repository's ValueObservation.
    var write: WriteThrough? { coordinator?.write }

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

    var calendar: CalendarClient? { coordinator?.calendar }

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
