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
import Network
import Supabase
import UnstuckCore
import UnstuckData

/// A closure slot settable from any isolation domain. The app hands the
/// coordinator its "preferences went stale" hook after construction, but the
/// freshness owner's actions are built during `init` — this bridges the two.
final class HookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable () async -> Void)?
    func set(_ h: (@Sendable () async -> Void)?) { lock.withLock { hook = h } }
    func call() async {
        await lock.withLock { hook }?()
    }
}

/// A lock-guarded Bool for the NWPathMonitor callback (which runs on its own
/// queue, outside any actor).
final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    /// Set and return the PREVIOUS value.
    func swap(_ new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}

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
    /// Unified sharing v1: the `share-task` edge function (share a task by
    /// EMAIL — existing account or invite — plus roster / link).
    public nonisolated let taskShare: TaskShareClient
    /// Co-focus presence factory (Supabase Realtime Presence, `cofocus:<taskId>`)
    /// for the owner CoFocusBar + recipient PartnerPresence surfaces (M5).
    public nonisolated let coFocus: CoFocusPresenceClient
    public nonisolated let feedback: FeedbackClient
    public nonisolated let loginTracker: LoginTrackerClient
    public nonisolated let assistant: AssistantClient
    /// "Unstuck calls you" (C1): call_requests rows + the call-outcome edge fn.
    public nonisolated let calls: CallsClient
    /// The local mirror of `call_requests` (hydrate + realtime + catch-up) —
    /// what get_calls, the task editor and the call deep link read.
    public nonisolated let callsMirror: CallRequestsMirror
    /// THE FRESHNESS OWNER — the single component that answers "am I in step?"
    /// and the only thing allowed to decide a pull is needed. Realtime, the
    /// app lifecycle, the network monitor and the floor interval all report
    /// into it; nothing else schedules its own refresh.
    public nonisolated let freshness: FreshnessOwner
    private let hydrator: Hydrator
    private let catchUpPuller: CatchUpPuller
    private let realtime: RealtimeMirror
    /// Set by the app: re-read the account-wide preference rows (they live
    /// outside the local store, so no cursor pull can carry them).
    private nonisolated let preferencesHook = HookBox()
    /// Network-path watch → `.networkRegained`.
    private var pathMonitor: NWPathMonitor?
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
        let auth = AuthService(provider.client)
        self.auth = auth
        self.write = WriteThrough(db: db)
        self.calendar = CalendarClient(provider.client)
        self.push = PushClient(provider.client)
        self.notifications = NotificationsClient(provider.client)
        self.preferences = PreferencesClient(provider.client)
        self.share = CollectionShareClient(provider.client)
        self.circle = CircleClient(provider.client)
        self.taskShare = TaskShareClient(provider.client)
        self.coFocus = CoFocusPresenceClient(provider.client)
        self.feedback = FeedbackClient(provider.client)
        self.loginTracker = LoginTrackerClient(provider.client)
        self.assistant = AssistantClient(provider.client)
        self.calls = CallsClient(provider.client)
        self.callsMirror = CallRequestsMirror(db)
        let hydrator = Hydrator(gateway: gateway, db: db)
        let flusher = OutboxFlusher(gateway: gateway, db: db)
        let realtime = RealtimeMirror(client: provider.client, db: db)
        let catchUpPuller = CatchUpPuller(gateway: gateway, db: db,
                                          fullFallback: { table in
                                              await hydrator.hydrateFullReplaceTable(table)
                                          })
        self.hydrator = hydrator
        self.flusher = flusher
        self.realtime = realtime
        self.catchUpPuller = catchUpPuller
        self.collab = CollabRealtime(client: provider.client)
        self.db = db
        let prefsHook = self.preferencesHook
        // Every executor the owner drives is a sub-component built above, so
        // the whole policy lives in FreshnessOwner and is testable without a
        // coordinator, a network or a socket.
        self.freshness = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { uid in
                await hydrator.pruneStaleTaskOps()
                await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
                await hydrator.hydrate(userId: uid)
            },
            catchUp: { uid, reconcile in
                // Push before pulling, exactly as the full sync does: a queued
                // edit must reach the server before we ask what the server has,
                // or the pull reports our own stale base back at us.
                await hydrator.pruneStaleTaskOps()
                await flusher.flush(userId: uid, currentUserId: { auth.currentUserId })
                return await catchUpPuller.catchUp(userId: uid, reconcileDeletions: reconcile)
            },
            rebuildSubscriptions: { await realtime.rebuildSubscriptionsNow() },
            refreshPreferences: { await prefsHook.call() }))
    }

    /// The app's "re-read the account-wide preference rows" hook. Called by the
    /// freshness owner on every gap trigger (throttled) and immediately when a
    /// `notification_preferences` / `user_preferences` realtime event lands, so
    /// a preference changed on the web reaches this device without a relaunch.
    public func setOnPreferencesStale(_ hook: @escaping @Sendable () async -> Void) {
        preferencesHook.set(hook)
    }

    /// Begin observing auth-state changes. Call once at app launch.
    public func start() async {
        guard observeTask == nil else { return }
        // Post-write kick: every WriteThrough enqueue schedules a debounced
        // flush so mid-session edits reach the server promptly (spec §5).
        await write.setOnEnqueue { [weak self] in
            Task { await self?.scheduleDebouncedFlush() }
        }
        // Realtime REPORTS; the freshness owner decides. A delivered row is
        // liveness evidence, a (re)subscribe is a gap, a preference-row change
        // is a stale-preferences signal.
        let freshness = self.freshness
        let prefsHook = self.preferencesHook
        await realtime.setSignals(
            onRealtimeEvent: { Task { await freshness.report(.realtimeEvent) } },
            onChannelsSubscribed: { Task { await freshness.report(.channelsSubscribed) } },
            onPreferencesChanged: { Task { await prefsHook.call() } })
        startPathMonitor()
        let stream = auth.authStateChanges
        observeTask = Task { [weak self] in
            for await (event, session) in stream {
                await self?.handle(event: event, session: session)
            }
        }
    }

    /// The network coming back is a gap trigger: everything written while we
    /// were offline was broadcast to a socket that wasn't there. iOS had no
    /// network-path monitoring at all before this.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let freshness = self.freshness
        let previouslySatisfied = MutableFlag(true)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let was = previouslySatisfied.swap(satisfied)
            guard satisfied, !was else { return }
            Task { await freshness.report(.networkRegained) }
        }
        monitor.start(queue: DispatchQueue(label: "io.unstucknow.freshness.path"))
    }

    public func stop() {
        observeTask?.cancel()
        observeTask = nil
        flushKick?.cancel()
        flushKick = nil
        pathMonitor?.cancel()
        pathMonitor = nil
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
    /// Routed through the freshness owner like every other trigger — it is the
    /// ONE scheduler, so a foreground, a BG refresh and a floor tick that land
    /// together collapse into a single pull instead of three overlapping ones.
    /// Still awaits completion (BackgroundSync needs that) via `awaitIdle`.
    public func syncNow() async {
        guard let uid = auth.currentUserId else { return }
        // Bind defensively: a foreground / BG-refresh can land before the auth
        // observer has processed `initialSession`, and an unbound owner would
        // silently drop the request. `setUser` is a no-op once bound, and when
        // it is NOT, the owner correctly runs the full hydrate first.
        await freshness.setUser(uid)
        await freshness.report(.manual)
        await freshness.awaitIdle()
        kickFlushIfOutboxPending()
        await pullCalendar()   // ingest Google events if connected (best-effort)
    }

    /// Report the app's visibility. This is what arms the floor interval — and
    /// unlike the old safety net it is safe to call before the engine is ready
    /// (the owner remembers it), which is why the cold-launch ordering race
    /// that left a whole session with no periodic pull can't happen again.
    public func setVisible(_ visible: Bool) async {
        await freshness.setVisible(visible)
    }

    /// The freshness owner's view of "am I in step?" — counters, the last
    /// realtime event, the last successful pull, and how often a channel has
    /// been caught claiming health while deaf.
    public func freshnessSnapshot() async -> FreshnessStats {
        await freshness.snapshot()
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
            // Hand the session to the freshness owner. `markHydrated` tells it
            // the cold-start full pull is already done, so from here on the
            // cheap cursor catch-up is the correctness path.
            await freshness.setUser(uid)
            await freshness.markHydrated()
            let hydrator = self.hydrator
            let freshness = self.freshness
            await realtime.subscribeAll(userId: uid, onMembersChanged: {
                await hydrator.hydrateCollections(userId: uid)
            }, onResync: {
                // A socket reconnect / channel rebuild is a GAP: postgres_changes
                // has no replay, so everything written while we were away was
                // never broadcast. Report it — the owner coalesces it with
                // whatever else is arriving and runs ONE catch-up.
                await freshness.report(.socketConnected)
            })
            // Live sharing signal (RPC-backed projections refetch on the post).
            await collab.start(userId: uid)
            // Cold start, after hydrate: seed the cursors and pick up anything
            // written between the hydrate's reads and the subscriptions landing.
            await freshness.report(.coldStart)
            await pullCalendar()   // ingest Google events if connected (spec §1.7 step 4, best-effort)

        case .signedOut:
            await freshness.setUser(nil)
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

        case .tokenRefreshed:
            // The window around a refresh is exactly where a channel re-joins
            // with a token RLS won't accept and goes permanently deaf while
            // still reporting SUBSCRIBED (proven 2026-09-12). Treat it as a gap
            // and catch up; the SDK has already pushed the new token to the
            // socket by the time this lands.
            await freshness.report(.tokenRefreshed)

        default:
            break   // passwordRecovery / etc. — no action
        }
    }
}
