// SyncCoordinator — the orchestrator (port of bootstrap-listener.tsx).
// Observes auth state and drives the engine: on sign-in / initial-session
// / user-updated it applies the cache-wipe rule, flushes any offline
// outbox, hydrates server-canonical, then subscribes to realtime. On
// sign-out it tears down realtime and wipes the local cache (shared-device
// privacy). `prevUserId` (UserDefaults; App Group later) distinguishes a
// same-user reload from a user switch.

import Foundation
import Supabase
import UnstuckData

public actor SyncCoordinator {
    // Sendable + immutable → safe to read synchronously from any actor
    // (the app's @MainActor UI reaches these directly).
    public nonisolated let auth: AuthService
    public nonisolated let write: WriteThrough
    public nonisolated let calendar: CalendarClient
    private let hydrator: Hydrator
    private let realtime: RealtimeMirror
    private let flusher: OutboxFlusher
    private let db: AppDatabase
    private let prevUserKey = "unstuck.prevUserId"
    private var observeTask: Task<Void, Never>?

    public init(provider: SupabaseClientProvider, db: AppDatabase) {
        let gateway = SyncGateway(provider.client)
        self.auth = AuthService(provider.client)
        self.write = WriteThrough(db: db)
        self.calendar = CalendarClient(provider.client)
        self.hydrator = Hydrator(gateway: gateway, db: db)
        self.realtime = RealtimeMirror(client: provider.client, db: db)
        self.flusher = OutboxFlusher(gateway: gateway, db: db)
        self.db = db
    }

    /// Begin observing auth-state changes. Call once at app launch.
    public func start() {
        guard observeTask == nil else { return }
        let stream = auth.authStateChanges
        observeTask = Task { [weak self] in
            for await (event, session) in stream {
                await self?.handle(event: event, session: session)
            }
        }
    }

    public func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    private func handle(event: AuthChangeEvent, session: Supabase.Session?) async {
        switch event {
        case .signedIn, .initialSession, .userUpdated:
            guard let uid = session?.user.id.uuidString else { return }
            let syncEvent: SyncAuthEvent = {
                switch event {
                case .signedIn: return .signedIn
                case .userUpdated: return .userUpdated
                default: return .initialSession
                }
            }()
            let prev = UserDefaults.standard.string(forKey: prevUserKey)
            if SyncDecision.shouldWipeCache(event: syncEvent, prevUserId: prev, currentUserId: uid) {
                try? db.wipeSyncedTables()
            }
            UserDefaults.standard.set(uid, forKey: prevUserKey)
            // Push offline edits first so local changes reach the server,
            // then pull server-canonical, then mirror live.
            await flusher.flush(userId: uid)
            await hydrator.hydrate()
            await realtime.subscribeAll(userId: uid)

        case .signedOut:
            await realtime.unsubscribeAll()
            try? db.wipeSyncedTables()
            UserDefaults.standard.removeObject(forKey: prevUserKey)

        default:
            break   // tokenRefreshed / passwordRecovery / etc. — no action
        }
    }
}
