// SyncCoordinator — the orchestrator (port of bootstrap-listener.tsx).
// Observes auth state and drives the engine: on sign-in / initial-session
// / user-updated it applies the cache-wipe rule (clearAll iff the user
// actually changed), flushes any offline outbox, hydrates server-canonical,
// then subscribes to realtime. On sign-out it tears down realtime and
// clears the local cache INCLUDING the outbox + live session (shared-
// device privacy — a kept outbox would be replayed under the next user's
// id) — but any op that could NOT be drained first (offline sign-out) is
// PARKED under the signing-out user first and restored on that user's
// next sign-in, so an offline sign-out never discards un-pushed edits.
// `prevUserId` (UserDefaults; App Group later) distinguishes a same-user
// reload from a user switch. Mid-session sync runs through syncNow()
// (scenePhase .active / BG refresh) and a debounced post-write flush kick
// (spec 02-sync-engine §5).

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
    /// Trusted-circle + per-task sharing transport (RPCs + circle-invite /
    /// share-notify edge fns). Reachable from the app via `coordinator.circle`.
    public nonisolated let circle: CircleClient
    /// Co-focus presence factory (Supabase Realtime Presence, `cofocus:<taskId>`)
    /// for the owner CoFocusBar + recipient PartnerPresence surfaces (M5).
    public nonisolated let coFocus: CoFocusPresenceClient
    public nonisolated let feedback: FeedbackClient
    public nonisolated let loginTracker: LoginTrackerClient
    public nonisolated let assistant: AssistantClient
    /// "Unstuck calls you" (C1): call_requests rows + the call-outcome edge fn.
    public nonisolated let calls: CallsClient
    private let hydrator: Hydrator
    private let realtime: RealtimeMirror
    /// Live change-signal for sharing (posts NotificationCenter; the UI refetches
    /// the RPC-backed projections). Recipients can't mirror shared task rows (RLS).
    private let collab: CollabRealtime
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
        self.circle = CircleClient(provider.client)
        self.coFocus = CoFocusPresenceClient(provider.client)
        self.feedback = FeedbackClient(provider.client)
        self.loginTracker = LoginTrackerClient(provider.client)
        self.assistant = AssistantClient(provider.client)
        self.calls = CallsClient(provider.client)
        self.hydrator = Hydrator(gateway: gateway, db: db)
        self.realtime = RealtimeMirror(client: provider.client, db: db)
        self.collab = CollabRealtime(client: provider.client)
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

    /// Fires after EVERY `profile_facts` hydrate completes (success, failure or
    /// offline) — the app's `profileFactsHydrated` signal. Set before `start()`
    /// so the first sign-in hydrate is observed.
    public func setOnProfileFactsHydrated(_ hook: @escaping @Sendable () -> Void) async {
        await hydrator.setOnProfileFactsHydrated(hook)
    }

    // MARK: - shared collections (outbox `rpc` ops)

    /// A shared-list item RPC the server REFUSED (RLS / a revoked share / a
    /// bad call): the outbox dropped it (terminal) and the app must roll the
    /// optimistic row back to the server's copy with a visible error —
    /// `(collectionId, fn, error)`.
    public func setOnCollectionRPCRejected(_ hook: @escaping @Sendable (_ collectionId: String, _ fn: String, _ error: Error) -> Void) async {
        await flusher.setOnRPCRejected { table, rowId, fn, error in
            guard table == "collections" else { return }
            hook(rowId, fn, error)
        }
    }

    /// Re-pull collections + membership from the server (RLS-scoped) — after
    /// a share / unshare / leave / invite claim so the OWNER's client learns
    /// the list is shared (members[] / myRole) at once instead of after the
    /// next full hydrate, and to roll an optimistic row back after a refused
    /// RPC. No-op when signed out.
    public func rehydrateCollections() async {
        guard let uid = auth.currentUserId else { return }
        await hydrator.hydrateCollections(userId: uid)
    }

    /// Manual best-effort sync (flush outbox → hydrate) for the foreground
    /// (scenePhase .active) + BG-refresh triggers. No-op when signed out.
    /// Mirrors Android SyncCoordinator.syncNow().
    public func syncNow() async {
        guard let uid = auth.currentUserId else { return }
        let auth = self.auth
        // Drop stale local task ops the server already superseded BEFORE flushing,
        // so a queued done=false can't clobber a completion made on another
        // platform (which the hydrate would then pull back). Then push + pull.
        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
        await hydrator.hydrate(userId: uid)
        kickFlushIfOutboxPending()
        await pullCalendar()   // ingest Google events if connected (best-effort)
    }

    /// A hydrate can itself ENQUEUE ops — profile_facts rows the server has
    /// never seen get pushed up (web hydrate parity). Those land after the
    /// pre-hydrate flush, so kick the debounced flush rather than leaving them
    /// for the next foreground / auth event.
    private func kickFlushIfOutboxPending() {
        guard ((try? OutboxStore(db).count()) ?? 0) > 0 else { return }
        scheduleDebouncedFlush()
    }

    // MARK: - Google calendar pull

    /// The connected calendars' health after the last pull — what the UI
    /// needs to offer "Reconnect Google" (a dead refresh token) and to stay
    /// quiet while backing off a 429.
    public struct CalendarSyncStatus: Sendable, Equatable {
        public var needsReauthConnectionIds: Set<String> = []
        public var lastError: String?
        public var backoffUntil: Date?
        public init(needsReauthConnectionIds: Set<String> = [], lastError: String? = nil, backoffUntil: Date? = nil) {
            self.needsReauthConnectionIds = needsReauthConnectionIds
            self.lastError = lastError
            self.backoffUntil = backoffUntil
        }
        public var needsReauth: Bool { !needsReauthConnectionIds.isEmpty }
    }

    /// Google rate-limited us (429): pull again no sooner than this.
    private var calendarBackoffUntil: Date?
    private var onCalendarStatus: (@Sendable (CalendarSyncStatus) -> Void)?
    public private(set) var calendarStatus = CalendarSyncStatus()

    /// Observe calendar health changes (the app mirrors them into UI state).
    public func setOnCalendarStatus(_ hook: @escaping @Sendable (CalendarSyncStatus) -> Void) {
        onCalendarStatus = hook
    }

    /// How long a 429 silences the pull.
    static let calendarRateLimitBackoff: TimeInterval = 15 * 60

    /// Pull external Google events for [-7d, +30d] and reconcile them into
    /// local EXTERNAL g_ blocks — port of Android SyncCoordinator.pullCalendar.
    /// The own-event + all-day filters and the keep-set deletion reconcile
    /// live in reconcileCalendarPull (UnstuckCore). Best-effort: no-op when
    /// signed out, without a connection, on any network failure, or while
    /// backing off a 429. A connection the server could not read (revoked
    /// token / 429 / 5xx — `failures`) is EXCLUDED from the deletion
    /// reconcile: its meetings stay until a successful pull says otherwise,
    /// and a 401 / invalid_grant flags it for "Reconnect Google".
    public func pullCalendar() async {
        guard auth.currentUserId != nil else { return }
        if let until = calendarBackoffUntil, until > Date() { return }
        guard let statuses = try? await calendar.listConnectionStatuses(), !statuses.isEmpty else { return }
        var status = CalendarSyncStatus(
            needsReauthConnectionIds: Set(statuses.filter(\.needsReauth).map(\.connection.id)),
            lastError: statuses.compactMap(\.lastError).first)
        let cal = Foundation.Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let fromDate = cal.date(byAdding: .day, value: -7, to: today),
              let toDate = cal.date(byAdding: .day, value: 30, to: today),
              let toExclusive = cal.date(byAdding: .day, value: 1, to: toDate) else { return }
        // Google's events.list requires RFC3339 instants for timeMin/timeMax —
        // a bare YYYY-MM-DD is rejected (400) and silently yields zero events.
        // Send full instants; reconcile locally with the date-only bounds.
        let f = ISO8601DateFormatter()
        let pull: CalendarClient.CalendarPull
        do {
            pull = try await calendar.pullEvents(from: f.string(from: fromDate), to: f.string(from: toExclusive))
        } catch CalendarSyncError.rateLimited {
            calendarBackoffUntil = Date().addingTimeInterval(Self.calendarRateLimitBackoff)
            status.backoffUntil = calendarBackoffUntil
            publishCalendarStatus(status)
            return
        } catch CalendarSyncError.needsReauth {
            status.needsReauthConnectionIds.formUnion(statuses.map(\.connection.id))
            publishCalendarStatus(status)
            return
        } catch {
            return   // offline / 5xx: nothing to reconcile, nothing to delete
        }
        for failure in pull.failures where failure.needsReauth {
            status.needsReauthConnectionIds.insert(failure.connectionId)
            if status.lastError == nil { status.lastError = failure.reason }
        }
        if pull.failures.contains(where: \.rateLimited) {
            calendarBackoffUntil = Date().addingTimeInterval(Self.calendarRateLimitBackoff)
            status.backoffUntil = calendarBackoffUntil
        }
        let failed = Set(pull.failures.map(\.connectionId))
        let local = (try? db.fetchAllCalBlocks()) ?? []
        let plan = reconcileCalendarPull(events: pull.events, localBlocks: local,
                                         fromYmd: Clock.dateISO(fromDate), toYmd: Clock.dateISO(toDate),
                                         allDayEventIds: pull.allDayEventIds, failedConnectionIds: failed)
        let now = Self.isoNow()
        for b in plan.toUpsert { try? await write.upsertCalBlock(b, nowISO: now) }
        for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
        publishCalendarStatus(status)
    }

    private func publishCalendarStatus(_ status: CalendarSyncStatus) {
        guard status != calendarStatus else { return }
        calendarStatus = status
        onCalendarStatus?(status)
    }

    /// The user re-consented (or disconnected): forget the stale verdicts so
    /// the next pull starts clean.
    public func resetCalendarStatus() {
        calendarBackoffUntil = nil
        publishCalendarStatus(CalendarSyncStatus())
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Drain the outbox for the current user now. No hydrate (a hydrate
    /// racing a transiently-failed flush would revert the optimistic local
    /// edit off the UI until the op retries), but it DOES prune stale task
    /// ops first — exactly like syncNow()/the auth-event path, and like
    /// Android which pairs every flush with a prune. Without the prune, a
    /// queued op the server already superseded (e.g. a completion made on
    /// the web) would re-push and clobber the newer server state before the
    /// next prune+hydrate. The prune only touches the server when task ops
    /// are actually queued, so it's free in the common empty-outbox case.
    public func flushNow() async {
        guard let uid = auth.currentUserId else { return }
        let auth = self.auth
        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
    }

    /// The realtime self-heal path: identical to syncNow() minus the calendar
    /// pull (the reconnect has nothing to do with Google).
    private func resyncAfterReconnect(userId uid: String) async {
        guard auth.currentUserId == uid else { return }
        let auth = self.auth
        await hydrator.pruneStaleTaskOps()
        await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
        await hydrator.hydrate(userId: uid)
        kickFlushIfOutboxPending()
    }

    /// Schedule the debounced post-write flush from OUTSIDE the WriteThrough
    /// hook — for writers that commit through the synchronous WriteThrough
    /// path (`upsertCollectionSync`), which can't reach the actor's hook.
    public func kickFlush() {
        scheduleDebouncedFlush()
    }

    /// Ops still waiting to reach the server (quarantined ones included) —
    /// the Settings sign-out row reads this to say "N changes haven't synced
    /// yet" before the user leaves. Whatever can't drain is parked, never lost.
    public nonisolated func pendingOutboxCount() -> Int {
        (try? OutboxStore(db).count()) ?? 0
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
    /// guarded on the live user) — whatever still can't be pushed (offline)
    /// is PARKED under this user by the signedOut branch before clearAll()
    /// wipes the outbox, and restored on their next sign-in; (2)
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
                // A user switch without an observed sign-out (session replaced
                // in place): the previous user's un-pushed ops are parked for
                // them, never wiped and never replayed under the new user.
                if let prev, prev != uid { _ = try? OutboxStore(db).park(userId: prev) }
                try? db.clearAll()
            }
            UserDefaults.standard.set(uid, forKey: prevUserKey)
            // Ops parked at THIS user's last sign-out (offline sign-out) rejoin
            // the queue — appended after anything already pending, original
            // order — and flush below like any other offline edit. Other users'
            // parked ops stay parked.
            if let restored = try? OutboxStore(db).restoreParked(userId: uid), restored > 0 {
                print("[sync] restored \(restored) parked op(s) for \(uid)")
            }
            // Prune stale task ops (server already newer) so they can't clobber
            // another platform's change, then push offline edits, pull
            // server-canonical, and mirror live. Guard the drain on the LIVE user
            // id so a sign-out + switch mid-flush doesn't stamp ops with the prior user.
            let auth = self.auth
            await hydrator.pruneStaleTaskOps()
            await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
            await hydrator.hydrate(userId: uid)
            kickFlushIfOutboxPending()
            let hydrator = self.hydrator
            await realtime.subscribeAll(userId: uid, onMembersChanged: {
                await hydrator.hydrateCollections(userId: uid)
            }, onResync: { [weak self] in
                // Realtime self-heal backfill (socket reconnect / channel
                // rebuild): a full server-canonical pull catches anything the
                // dropped connection missed. The REST hydrate is the reliable
                // source of truth around which realtime self-heals. Same
                // prune → flush → hydrate → kick sequence as syncNow(): the
                // socket usually reconnects BEFORE any other trigger fires when
                // the network returns, and a bare hydrate here would show the
                // server's stale rows over queued offline edits until the next
                // safety-net tick.
                await self?.resyncAfterReconnect(userId: uid)
            })
            // Live sharing signal (RPC-backed projections refetch on the post).
            await collab.start(userId: uid)
            await pullCalendar()   // ingest Google events if connected (spec §1.7 step 4, best-effort)

        case .signedOut:
            await realtime.unsubscribeAll()
            await collab.stop()
            // Whatever the bounded pre-sign-out drain could NOT push (offline /
            // slow link / a reactive revocation that never drained at all) is
            // parked under the user who owned it — restored on THEIR next
            // sign-in, never replayed under anyone else — instead of being
            // wiped with the cache. `prevUserKey` still names that user here.
            if let owner = UserDefaults.standard.string(forKey: prevUserKey)?.lowercased() {
                let parked = (try? OutboxStore(db).park(userId: owner)) ?? 0
                if parked > 0 { print("[sync] parked \(parked) un-pushed op(s) for \(owner)") }
            }
            try? db.clearAll()
            UserDefaults.standard.removeObject(forKey: prevUserKey)

        default:
            break   // tokenRefreshed / passwordRecovery / etc. — no action
        }
    }
}
