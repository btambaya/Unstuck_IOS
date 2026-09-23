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

/// Orders the /connections answers pullCalendar mirrors into
/// calendar_connections. Pulls overlap (a foreground, sign-in, "Sync now", the
/// post-connect and post-disconnect pulls), so an answer read BEFORE a server
/// connect / revoke can land after a newer read — or after the app's own
/// connect seed / disconnect delete — and write the old list back. Only an
/// answer newer than everything already applied is taken (audit 2026-09-22,
/// C18).
struct CalendarConnectionsReadGate: Sendable {
    private var sent = 0
    private var applied = 0
    /// A /connections request is about to go out: its generation.
    mutating func begin() -> Int { sent += 1; return sent }
    /// The answer to read `generation` arrived: true = apply it (and remember
    /// it), false = a newer read or a local write already superseded it.
    mutating func admit(_ generation: Int) -> Bool {
        guard generation > applied else { return false }
        applied = generation
        return true
    }
    /// The app wrote calendar_connections itself: every read already sent is
    /// older than that write.
    mutating func supersedeReadsInFlight() { applied = sent }
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
    /// Rule G (stage 2): the app asks it before every Google push of a
    /// cal_block, and a push for a row whose insert is still unresolved waits
    /// for `setOnInsertResolved`. The flusher owns and brackets it.
    public nonisolated let mirrorGate: InsertMirrorGate
    /// The Google write-backs that have not reached Google yet (audit
    /// 2026-09-22, C24): the app records and retries them, the pull never
    /// imports an event of ours whose delete or INSERT is unconfirmed as a
    /// meeting.
    public nonisolated let googleBacklog: GoogleWriteBacklog
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
        self.googleBacklog = GoogleWriteBacklog(defaults: .standard, currentUser: { auth.currentUserId })
        // Rule G's gate (stage 2) is shared: the flusher brackets every insert
        // with it, and the realtime mirror and the cal_blocks pull release a
        // confirmed push that is waiting for its row.
        let mirrorGate = InsertMirrorGate(db: db)
        let hydrator = Hydrator(gateway: gateway, db: db, mirrorGate: mirrorGate)
        let flusher = OutboxFlusher(gateway: gateway, db: db, mirrorGate: mirrorGate)
        let realtime = RealtimeMirror(client: provider.client, db: db, mirrorGate: mirrorGate)
        let catchUpPuller = CatchUpPuller(gateway: gateway, db: db,
                                          fullFallback: { table in
                                              await hydrator.hydrateFullReplaceTable(table)
                                          },
                                          refreshCollections: { uid, changed in
                                              await hydrator.refreshCollectionMembership(userId: uid,
                                                                                         collectionsChanged: changed)
                                          })
        self.hydrator = hydrator
        self.flusher = flusher
        self.mirrorGate = mirrorGate
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

    // MARK: - deterministic occurrence mints (stage 2)

    /// An insert-family op resolved (deterministic-occurrence-ids.md §3c). The
    /// flusher has already markDone'd it and, for `retimed`, written the
    /// server's row into the local store (the realtime apply path) before the
    /// hook fires, so the app mirrors from a row that carries the server's
    /// Google mapping. `mirrorWanted` = a push was deferred for it (rule G).
    /// Fired on the flusher's executor: hop to the app's actor for real work.
    public func setOnInsertResolved(_ hook: @escaping @Sendable (InsertResolution) -> Void) async {
        await flusher.setOnInsertResolved(hook)
    }

    /// The last `cal_blocks` read that succeeded this session (nil = none yet).
    public func lastCalBlocksPull() async -> CalBlocksPull? {
        await hydrator.calBlocksPull()
    }

    /// The recurrence top-up's pull (§3c "topUpAfterCatchUp"): run one freshness
    /// pull now, exactly as `syncNow` does, and return the `cal_blocks` stamp
    /// afterwards. The top-up only runs when that stamp advanced. nil when
    /// signed out or when no `cal_blocks` read has succeeded yet.
    public func pullForRecurrenceTopUp() async -> CalBlocksPull? {
        guard let uid = auth.currentUserId else { return nil }
        await freshness.setUser(uid)
        await freshness.report(.manual)
        await freshness.awaitIdle()
        guard auth.currentUserId == uid else { return nil }
        return await hydrator.calBlocksPull()
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

    private var connectionsGate = CalendarConnectionsReadGate()

    /// The app just wrote calendar_connections itself (the connect seed, a
    /// disconnect's local delete): a /connections answer already in flight
    /// was read before that and must not overwrite it (audit 2026-09-22, C18).
    public func noteLocalConnectionsWrite() {
        connectionsGate.supersedeReadsInFlight()
    }

    /// The server's connection rows differ from the stored ones in anything
    /// but `lastSyncCursor`. /events re-stamps that cursor on every pull and
    /// nothing on iOS reads it, so comparing it rewrote the table (and re-fired
    /// its observers) on every foreground (audit 2026-09-22, C18).
    static func connectionsChanged(_ remote: [CalendarConnection], from local: [CalendarConnection]) -> Bool {
        func comparable(_ rows: [CalendarConnection]) -> [CalendarConnection] {
            rows.map { var c = $0; c.lastSyncCursor = nil; return c }.sorted { $0.id < $1.id }
        }
        return comparable(remote) != comparable(local)
    }

    /// Pull external Google events for [-7d, +30d] and reconcile them into
    /// local EXTERNAL g_ blocks — port of Android SyncCoordinator.pullCalendar.
    /// The own-event + all-day filters and the keep-set deletion reconcile
    /// live in reconcileCalendarPull (UnstuckCore). Best-effort: no-op when
    /// signed out or while backing off a 429. A connection the server could
    /// not read (revoked token / 429 / 5xx — `failures`) is EXCLUDED from the
    /// deletion reconcile: its meetings stay until a successful pull says
    /// otherwise, and a 401 / invalid_grant flags it for "Reconnect Google".
    /// Also mirrors the server's connection list into the local
    /// calendar_connections table (the polling refresh RealtimeMirror relies
    /// on). Returns false when /connections or /events could not be read, or
    /// Google answered for none of the connections (rate limit / outage) —
    /// "Sync now" says so instead of ending silently.
    @discardableResult
    public func pullCalendar() async -> Bool {
        guard let uid = auth.currentUserId else { return true }
        if let until = calendarBackoffUntil, until > Date() { return true }
        let statuses: [CalendarClient.ConnectionStatus]
        let generation = connectionsGate.begin()
        do { statuses = try await calendar.listConnectionStatuses() } catch { return false }
        // Every write below re-checks the user first: a sign-out or a user
        // switch can run on this actor at any suspension (the request above,
        // /events, each write), and the old account's meetings — local-only g_
        // rows every hydrate keeps — must never land in, or be deleted from,
        // the next user's store (audit 2026-09-22, C18).
        guard auth.currentUserId == uid else { return true }
        // An answer read before a newer one (or before the app's own connect
        // seed / disconnect delete) was already applied: it would put the old
        // list back — and purge meetings a newer pull just imported. That
        // newer read covers this pull (audit 2026-09-22, C18).
        guard connectionsGate.admit(generation) else { return true }
        // calendar_connections is in neither realtime nor the catch-up, so
        // without this an in-session connect (or a disconnect on web/Android)
        // never reached the local table the bar and googleConnection(for:)
        // read until the next cold launch. Server-canonical like the hydrate,
        // an empty list included; skipped when only the sync cursor moved
        // (audit 2026-09-22, C18).
        let remoteConnections = statuses.map(\.connection)
        let localConnections = (try? Repository<CalendarConnection>(db, orderColumn: "connectedAt").all()) ?? []
        if Self.connectionsChanged(remoteConnections, from: localConnections) {
            try? db.replaceAll(CalendarConnection.self, with: remoteConnections)
        }
        guard !statuses.isEmpty else {
            // No connection left (disconnected on web / Android): reconcile
            // never runs without one, so the imported meetings would sit on the
            // grid, block free slots and steer the assistant for good. Only g_
            // ids — the Google import, deleted locally, never through the
            // outbox (audit 2026-09-22, C18).
            for b in ((try? db.fetchExternalCalBlocks()) ?? []) where b.id.hasPrefix("g_") {
                guard auth.currentUserId == uid else { return true }
                _ = try? await write.deleteCalBlock(id: b.id, nowISO: Self.isoNow())
            }
            return true
        }
        var status = CalendarSyncStatus(
            needsReauthConnectionIds: Set(statuses.filter(\.needsReauth).map(\.connection.id)),
            lastError: statuses.compactMap(\.lastError).first)
        let cal = Foundation.Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let fromDate = cal.date(byAdding: .day, value: -7, to: today),
              let toDate = cal.date(byAdding: .day, value: 30, to: today),
              let toExclusive = cal.date(byAdding: .day, value: 1, to: toDate) else { return true }
        // Google's events.list requires RFC3339 instants for timeMin/timeMax —
        // a bare YYYY-MM-DD is rejected (400) and silently yields zero events.
        // Send full instants; reconcile locally with the date-only bounds.
        let f = ISO8601DateFormatter()
        let toISO = f.string(from: toExclusive)
        let firstPage: CalendarClient.CalendarPull
        do {
            firstPage = try await calendar.pullEvents(from: f.string(from: fromDate), to: toISO)
        } catch CalendarSyncError.rateLimited {
            guard auth.currentUserId == uid else { return true }
            calendarBackoffUntil = Date().addingTimeInterval(Self.calendarRateLimitBackoff)
            status.backoffUntil = calendarBackoffUntil
            publishCalendarStatus(status)
            return false
        } catch CalendarSyncError.needsReauth {
            guard auth.currentUserId == uid else { return true }
            status.needsReauthConnectionIds.formUnion(statuses.map(\.connection.id))
            publishCalendarStatus(status)
            return true   // the bar already offers "Reconnect Google"
        } catch {
            return false   // offline / 5xx: nothing to reconcile, nothing to delete
        }
        guard auth.currentUserId == uid else { return true }
        // A calendar that came back as one full page was cut short by the
        // server (C25): read the rest of the window before judging anything.
        let client = calendar
        let (pull, truncated) = await Self.readRemainingPages(
            firstPage, pageSize: Self.googleEventsPageSize, maxRounds: Self.calendarPageFollowUps
        ) { from, connectionId in
            try await client.pullEvents(from: from, to: toISO, connectionId: connectionId)
        }
        guard auth.currentUserId == uid else { return true }
        for failure in pull.failures where failure.needsReauth {
            status.needsReauthConnectionIds.insert(failure.connectionId)
            if status.lastError == nil { status.lastError = failure.reason }
        }
        if pull.failures.contains(where: \.rateLimited) {
            calendarBackoffUntil = Date().addingTimeInterval(Self.calendarRateLimitBackoff)
            status.backoffUntil = calendarBackoffUntil
        }
        // A calendar Google no longer lets the account read (404 / 410:
        // unshared, deleted) is not a failure: its meetings really are gone.
        // Keyed by connection, it used to freeze that account's deletions on
        // every pull for good, since the server never drops the calendar from
        // the selection (audit 2026-09-22, C25). A connection read only in
        // part (a transient failure, a window still cut short) keeps its
        // meetings until a complete read says otherwise.
        let failed = Set(pull.failures.filter { !$0.calendarGone }.map(\.connectionId)).union(truncated)
        let local = (try? db.fetchAllCalBlocks()) ?? []
        let plan = reconcileCalendarPull(events: pull.events, localBlocks: local,
                                         fromYmd: Clock.dateISO(fromDate), toYmd: Clock.dateISO(toDate),
                                         allDayEventIds: pull.allDayEventIds, failedConnectionIds: failed,
                                         unconfirmedEventIds: googleBacklog.unconfirmedEventIds(),
                                         liveConnectionIds: Set(statuses.map(\.connection.id)))
        let now = Self.isoNow()
        // reconcileCalendarPull returns every in-window event whether or not it
        // changed; writing only the ones that differ keeps a foreground from
        // committing (and re-planning reminders) once per meeting (audit
        // 2026-09-22, C18).
        let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in plan.toUpsert where localById[b.id] != b {
            guard auth.currentUserId == uid else { return true }
            try? await write.upsertCalBlock(b, nowISO: now)
        }
        for id in plan.toDelete {
            guard auth.currentUserId == uid else { return true }
            _ = try? await write.deleteCalBlock(id: id, nowISO: now)
        }
        guard auth.currentUserId == uid else { return true }
        publishCalendarStatus(status)
        // Google itself failed for every connection (429 / 5xx / 403 /
        // unreachable) — the function still answers 200 with those in
        // `failures`, so this used to end on "Synced" with no meetings. The
        // back-off above is already set for a 429, which is what picks "Google
        // is busy" over the connectivity caption (audit 2026-09-22, C18).
        return !pull.readNothing(from: statuses.map(\.connection))
    }

    /// calendar-sync reads ONE page per calendar (providers/google.ts
    /// listCalendarEvents: maxResults=250, orderBy=startTime, nextPageToken
    /// never followed) and reports nothing for the rest. A busy team calendar
    /// lost everything after its 250th event in the window, and the reconcile
    /// then deleted those meetings as "gone in Google" — they vanished, or
    /// flickered as the page boundary moved (audit 2026-09-22, C25).
    static let googleEventsPageSize = 250
    /// Follow-up reads per pull before a connection is left "truncated".
    static let calendarPageFollowUps = 4

    /// Read what the server cut off: a calendar that came back with a full
    /// page is read again for its connection from its last event's start
    /// (Google returns every event still running then, so nothing between is
    /// skipped; duplicates are dropped), until no calendar comes back full.
    /// Returns the merged pull and the connections still cut short (no
    /// progress, a follow-up that failed or reported a failing calendar, or
    /// out of rounds) — their meetings are kept, never deletion-reconciled,
    /// this pull. A follow-up's failures stay out of the pull's own: the
    /// first read did answer, and "Sync now" must not call it a failed sync.
    static func readRemainingPages(
        _ first: CalendarClient.CalendarPull, pageSize: Int, maxRounds: Int,
        fetch: @Sendable (_ from: String, _ connectionId: String) async throws -> CalendarClient.CalendarPull
    ) async -> (CalendarClient.CalendarPull, Set<String>) {
        func key(_ e: ExternalEvent) -> String { "\(e.connectionId)|\(e.calendarId)|\(e.id)" }
        /// Per connection: the earliest last start among its full calendars.
        func fullPages(_ events: [ExternalEvent]) -> [String: EpochMillis] {
            var out: [String: EpochMillis] = [:]
            for (_, group) in Dictionary(grouping: events, by: { "\($0.connectionId)|\($0.calendarId)" })
            where group.count >= pageSize {
                guard let last = group.compactMap({ Time.parseMillis($0.start) }).max() else { continue }
                let conn = group[0].connectionId
                out[conn] = min(out[conn] ?? last, last)
            }
            return out
        }
        // Sent as a UTC instant like the first read's bounds: Google's own
        // "+01:00" offset would reach the function as a space in the query.
        let utc = ISO8601DateFormatter()
        var events = first.events
        var allDay = first.allDayEventIds
        var seen = Set(events.map(key))
        var truncated = Set<String>()
        var tails = fullPages(first.events)
        var round = 0
        while !tails.isEmpty {
            guard round < maxRounds else { truncated.formUnion(tails.keys); break }
            round += 1
            var next: [String: EpochMillis] = [:]
            for (conn, from) in tails.sorted(by: { $0.key < $1.key }) {
                let fromISO = utc.string(from: Date(timeIntervalSince1970: from / 1000))
                guard let more = try? await fetch(fromISO, conn) else { truncated.insert(conn); continue }
                for e in more.events where seen.insert(key(e)).inserted { events.append(e) }
                allDay.formUnion(more.allDayEventIds)
                if more.failures.contains(where: { !$0.calendarGone }) { truncated.insert(conn) }
                guard let again = fullPages(more.events)[conn] else { continue }
                if again > from { next[conn] = again } else { truncated.insert(conn) }
            }
            tails = next
        }
        return (CalendarClient.CalendarPull(events: events, allDayEventIds: allDay, failures: first.failures), truncated)
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
            let hydrator = self.hydrator
            await Self.drainBeforeSignOut(timeoutNs: 5_000_000_000,
                                          prune: { await hydrator.pruneStaleTaskOps() },
                                          flush: { await flusher.flush(userId: uid, currentUserId: { auth.currentUserId }) })
        }
        if let deviceId { try? await push.unregister(deviceId: deviceId) }
        await auth.signOut()
    }

    /// The bounded pre-sign-out drain: prune, then flush, until the timeout.
    /// Prune first, like every other flush: this was the one drain that could
    /// push a queued task edit over a newer web change (audit 2026-09-22, C9).
    /// If the timeout fires during the prune, its tasks GET is cancelled and it
    /// gives up, so flushing then would send the UNPRUNED ops. They are
    /// skipped instead: parked at sign-out, restored and pruned at the next
    /// sign-in.
    static func drainBeforeSignOut(timeoutNs: UInt64,
                                   prune: @escaping @Sendable () async -> Void,
                                   flush: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await prune()
                guard !Task.isCancelled else { return }
                await flush()
            }
            group.addTask { try? await Task.sleep(nanoseconds: timeoutNs) }
            _ = await group.next()   // whichever finishes first: drain or timeout
            group.cancelAll()
        }
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
                await hydrator.resetCalBlocksPull()
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
            // Ingest Google events if connected (spec §1.7 step 4, best-effort)
            // OFF the auth loop: the pull now really waits on the network and
            // on Google, and the loop handles one event at a time, so awaiting
            // it here held a sign-out's teardown (and every later auth event)
            // for as long as Google took. Its captured-uid guards make a late
            // or overlapping pull safe (audit 2026-09-22, C18).
            Task { [weak self] in _ = await self?.pullCalendar() }

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
            await hydrator.resetCalBlocksPull()
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
