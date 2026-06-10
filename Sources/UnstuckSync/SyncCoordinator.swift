// SyncCoordinator — the orchestrator (port of bootstrap-listener.tsx).
// Observes auth state and drives the engine: on sign-in / initial-session
// / user-updated it applies the cache-wipe rule (clearAll iff the user
// actually changed), flushes any offline outbox, hydrates server-canonical,
// then subscribes to realtime. On sign-out it tears down realtime and
// clears the local cache INCLUDING the outbox + live session (shared-
// device privacy — a kept outbox would be replayed under the next user's
// id). `prevUserId` (UserDefaults; App Group later) distinguishes a
// same-user reload from a user switch. Mid-session sync runs through
// syncNow() (scenePhase .active / BG refresh) and a debounced post-write
// flush kick (spec 02-sync-engine §5).

import Foundation
import Supabase
import UnstuckCore
import UnstuckData

public actor SyncCoordinator {
    // Sendable + immutable → safe to read synchronously from any actor
    // (the app's @MainActor UI reaches these directly).
    public nonisolated let auth: AuthService
    public nonisolated let write: WriteThrough
    public nonisolated let calendar: CalendarClient
    public nonisolated let push: PushClient
    public nonisolated let notifications: NotificationsClient
    public nonisolated let preferences: PreferencesClient
    public nonisolated let share: CollectionShareClient
    public nonisolated let feedback: FeedbackClient
    public nonisolated let loginTracker: LoginTrackerClient
    public nonisolated let assistant: AssistantClient
    private let hydrator: Hydrator
    private let realtime: RealtimeMirror
    private let flusher: OutboxFlusher
    private let db: AppDatabase
    private let prevUserKey = "unstuck.prevUserId"
    private var observeTask: Task<Void, Never>?
    private var flushKick: Task<Void, Never>?

    public init(provider: SupabaseClientProvider, db: AppDatabase) {
        let gateway = SyncGateway(provider.client)
        self.auth = AuthService(provider.client)
        self.write = WriteThrough(db: db)
        self.calendar = CalendarClient(provider.client)
        self.push = PushClient(provider.client)
        self.notifications = NotificationsClient(provider.client)
        self.preferences = PreferencesClient(provider.client)
        self.share = CollectionShareClient(provider.client)
        self.feedback = FeedbackClient(provider.client)
        self.loginTracker = LoginTrackerClient(provider.client)
        self.assistant = AssistantClient(provider.client)
        self.hydrator = Hydrator(gateway: gateway, db: db)
        self.realtime = RealtimeMirror(client: provider.client, db: db)
        self.flusher = OutboxFlusher(gateway: gateway, db: db)
        self.db = db
    }

    /// Begin observing auth-state changes. Call once at app launch.
    public func start() async {
        guard observeTask == nil else { return }
        // Post-write kick: every WriteThrough enqueue schedules a debounced
        // flush so mid-session edits reach the server promptly (spec §5).
        await write.setOnEnqueue { [weak self] in
            Task { await self?.scheduleDebouncedFlush() }
        }
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
        flushKick?.cancel()
        flushKick = nil
    }

    /// Manual best-effort sync (flush outbox → hydrate) for the foreground
    /// (scenePhase .active) + BG-refresh triggers. No-op when signed out.
    /// Mirrors Android SyncCoordinator.syncNow().
    public func syncNow() async {
        guard let uid = auth.currentUserId else { return }
        let auth = self.auth
        await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
        await hydrator.hydrate(userId: uid)
        await pullCalendar()   // ingest Google events if connected (best-effort)
    }

    /// Pull external Google events for [-7d, +30d] and reconcile them into
    /// local EXTERNAL g_ blocks — port of Android SyncCoordinator.pullCalendar.
    /// The own-event + all-day filters and the keep-set deletion reconcile
    /// live in reconcileCalendarPull (UnstuckCore). Best-effort: no-op when
    /// signed out, without a connection, or on any network failure.
    public func pullCalendar() async {
        guard auth.currentUserId != nil else { return }
        guard let conns = try? await calendar.listConnections(), !conns.isEmpty else { return }
        let cal = Foundation.Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let fromDate = cal.date(byAdding: .day, value: -7, to: today),
              let toDate = cal.date(byAdding: .day, value: 30, to: today),
              let toExclusive = cal.date(byAdding: .day, value: 1, to: toDate) else { return }
        // Google's events.list requires RFC3339 instants for timeMin/timeMax —
        // a bare YYYY-MM-DD is rejected (400) and silently yields zero events.
        // Send full instants; reconcile locally with the date-only bounds.
        let f = ISO8601DateFormatter()
        guard let events = try? await calendar.pullEvents(
            from: f.string(from: fromDate), to: f.string(from: toExclusive)) else { return }
        let local = (try? db.fetchAllCalBlocks()) ?? []
        let plan = reconcileCalendarPull(events: events, localBlocks: local,
                                         fromYmd: Clock.dateISO(fromDate), toYmd: Clock.dateISO(toDate))
        let now = Self.isoNow()
        for b in plan.toUpsert { try? await write.upsertCalBlock(b, nowISO: now) }
        for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Drain the outbox for the current user now. Flush-only (no hydrate):
    /// a hydrate racing a transiently-failed flush would revert the
    /// optimistic local edit off the UI until the op retries.
    public func flushNow() async {
        guard let uid = auth.currentUserId else { return }
        let auth = self.auth
        await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
    }

    private func scheduleDebouncedFlush() {
        flushKick?.cancel()
        flushKick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    /// Sign out, but first: (1) drain queued offline writes (bounded 5s,
    /// guarded on the live user) — the signedOut branch clearAll() wipes the
    /// outbox, so un-flushed edits would otherwise be lost forever; (2)
    /// delete this device's push-token rows WHILE the JWT is still valid
    /// (RLS: user_id = auth.uid()) so the previous user's morning briefs /
    /// pushes never reach whoever signs in next on this device. Mirrors
    /// Android signOutAndUnregister (spec 02 §1.7 + spec 10 §1.8).
    public func signOutAndUnregister(deviceId: String?) async {
        if let uid = auth.currentUserId {
            let auth = self.auth
            let flusher = self.flusher
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await flusher.flush(userId: uid, currentUserId: { auth.currentUserId }) }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                _ = await group.next()   // whichever finishes first: drain or timeout
                group.cancelAll()
            }
        }
        if let deviceId { try? await push.unregister(deviceId: deviceId) }
        await auth.signOut()
    }

    private func handle(event: AuthChangeEvent, session: Supabase.Session?) async {
        switch event {
        case .signedIn, .initialSession, .userUpdated:
            // Lowercased to match PostgREST/realtime user_id strings —
            // Foundation's UUID.uuidString is UPPERCASE (see AuthService).
            guard let uid = session?.user.id.uuidString.lowercased() else { return }
            let syncEvent: SyncAuthEvent = {
                switch event {
                case .signedIn: return .signedIn
                case .userUpdated: return .userUpdated
                default: return .initialSession
                }
            }()
            // Lowercase the stored prev too so installs that persisted the
            // old UPPERCASE uid don't false-positive as a user switch (which
            // would clearAll a same-user re-auth's pending edits).
            let prev = UserDefaults.standard.string(forKey: prevUserKey)?.lowercased()
            if SyncDecision.shouldWipeCache(event: syncEvent, prevUserId: prev, currentUserId: uid) {
                try? db.clearAll()
            }
            UserDefaults.standard.set(uid, forKey: prevUserKey)
            // Push offline edits first so local changes reach the server,
            // then pull server-canonical, then mirror live. Guard the drain
            // on the LIVE user id so a sign-out + switch mid-flush doesn't
            // keep stamping queued ops with the prior user.
            let auth = self.auth
            await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
            await hydrator.hydrate(userId: uid)
            let hydrator = self.hydrator
            await realtime.subscribeAll(userId: uid, onMembersChanged: {
                await hydrator.hydrateCollections(userId: uid)
            })
            await pullCalendar()   // ingest Google events if connected (spec §1.7 step 4, best-effort)

        case .signedOut:
            await realtime.unsubscribeAll()
            try? db.clearAll()
            UserDefaults.standard.removeObject(forKey: prevUserKey)

        default:
            break   // tokenRefreshed / passwordRecovery / etc. — no action
        }
    }
}
