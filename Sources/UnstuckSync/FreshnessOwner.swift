// FreshnessOwner — the ONE component that answers "am I in step with the
// server?", and the only thing allowed to decide that a pull is needed.
//
// Before this, iOS had three independent mechanisms that each thought they were
// the backstop: a 60s foreground timer started from the scenePhase handler (and
// silently skipped on cold launch, because it early-returned while the
// coordinator was still nil), a socket-status resync, and a per-channel
// self-heal keyed on `.unsubscribed` — a state the proven failure (a channel
// that reports SUBSCRIBED and delivers nothing, forever) never reaches. Three
// half-answers meant nobody owned the question, and every regression that
// killed realtime went unnoticed until a user reported it.
//
// Now every part of the app REPORTS to this actor and nothing else schedules a
// refresh:
//   • RealtimeMirror reports each delivered event, each (re)subscribe and each
//     socket connect;
//   • the app reports foreground/background, the network coming back, and token
//     refreshes;
//   • a floor interval ticks while the app is visible.
//
// What it does with those reports:
//   • COALESCES — overlapping triggers collapse into a single in-flight pull,
//     and a pull never runs while a hydrate is running (both go through here);
//   • runs the CURSOR CATCH-UP as the correctness path, with the full hydrate
//     kept for cold start / a missing cursor;
//   • DETECTS DEAFNESS without trusting channel status, two ways:
//       (a) silence — nothing delivered for `deafSilenceThreshold` while
//           visible and supposedly subscribed;
//       (b) the stronger oracle — a catch-up APPLIED a row old enough that a
//           healthy channel would have delivered it first.
//     Either verdict rebuilds the subscriptions and is counted, so the field
//     tells us how often this happens instead of us guessing.

import Foundation
import UnstuckCore

/// Everything that can make the client suspect it is behind. Reported by the
/// realtime mirror, the app lifecycle, the network monitor and the floor timer.
public enum FreshnessSignal: String, Sendable, Equatable, CaseIterable {
    /// The app just launched and the cold-start hydrate finished.
    case coldStart
    /// The app/tab became visible.
    case becameActive
    /// The app stopped being visible (stops the floor interval; no pull).
    case resignedActive
    /// The network came back (NWPathMonitor unsatisfied → satisfied).
    case networkRegained
    /// The realtime socket (re)connected — everything written during the gap
    /// was never broadcast to us.
    case socketConnected
    /// Channels (re)subscribed — same gap, per channel.
    case channelsSubscribed
    /// The access token was refreshed.
    case tokenRefreshed
    /// A postgres_changes event of any kind arrived. Never causes a pull; it is
    /// the liveness evidence the deafness detector reads.
    case realtimeEvent
    /// The floor interval fired while visible.
    case floorTick
    /// An explicit user/app request (pull to refresh, BG refresh task).
    case manual
    /// The deafness detector's own verdict.
    case deafnessSuspected
}

/// Counters + timestamps the freshness owner keeps so the field can be measured
/// rather than guessed at. Snapshot value — safe to hand to the UI.
public struct FreshnessStats: Sendable, Equatable {
    public var catchUps = 0
    public var fullHydrates = 0
    public var rowsApplied = 0
    public var rowsDropped = 0
    public var rowsSkippedPending = 0
    /// Rebuilds triggered because nothing had been delivered for too long.
    public var silenceRebuilds = 0
    /// Rebuilds triggered because a catch-up found a change realtime never
    /// delivered — the "connected but deaf" signature.
    public var missedEventRebuilds = 0
    public var failedPulls = 0
    public var lastRealtimeEventAt: Date?
    public var lastSuccessfulPullAt: Date?
    public var lastPullReason: String?
    public var inFlight = false
    public var visible = false
    public init() {}
}

public actor FreshnessOwner {
    /// The executors the owner drives. Injected so the whole policy is testable
    /// without a network, a database or a socket.
    public struct Actions: Sendable {
        /// Full server-canonical pull (prune → flush → hydrate). Cold start and
        /// nothing else, unless a catch-up says it needs one.
        public var fullSync: @Sendable (_ userId: String) async -> Void
        /// Cursor catch-up. `reconcileDeletions` asks for the id sweep too.
        public var catchUp: @Sendable (_ userId: String, _ reconcileDeletions: Bool) async -> CatchUpPuller.Outcome
        /// Tear down and re-establish every realtime subscription.
        public var rebuildSubscriptions: @Sendable () async -> Void
        /// Re-read the account-wide preference rows (they are not in the local
        /// store, so the cursor pull can't carry them).
        public var refreshPreferences: @Sendable () async -> Void
        /// Bring back any realtime channel that isn't live (a no-op for a
        /// healthy set). `networkRegained` resets its back-off. The deafness
        /// rules can't see a set that never subscribed — an offline launch —
        /// so the network, foreground and floor triggers ask for this
        /// directly (audit 2026-09-22, C30).
        public var ensureRealtime: @Sendable (_ networkRegained: Bool) async -> Void

        public init(fullSync: @escaping @Sendable (String) async -> Void,
                    catchUp: @escaping @Sendable (String, Bool) async -> CatchUpPuller.Outcome,
                    rebuildSubscriptions: @escaping @Sendable () async -> Void = {},
                    refreshPreferences: @escaping @Sendable () async -> Void = {},
                    ensureRealtime: @escaping @Sendable (Bool) async -> Void = { _ in }) {
            self.fullSync = fullSync
            self.catchUp = catchUp
            self.rebuildSubscriptions = rebuildSubscriptions
            self.refreshPreferences = refreshPreferences
            self.ensureRealtime = ensureRealtime
        }
    }

    // MARK: - policy constants

    /// The floor interval while visible. Kept at the existing mobile figure.
    public static let floorInterval: TimeInterval = 60
    /// Silence that makes a "healthy" channel suspect. Long enough that a quiet
    /// account doesn't rebuild all day, short enough that a deaf channel is
    /// caught inside one sitting.
    public static let deafSilenceThreshold: TimeInterval = 600
    /// A rebuild costs ~11 joins — never more than one per this window.
    public static let rebuildCooldown: TimeInterval = 60
    /// A catch-up row younger than this may simply have beaten its own
    /// broadcast; older than this and a healthy channel would have delivered it.
    public static let missedEventGrace: TimeInterval = 10
    /// The id-only deletion sweep runs at most this often on a plain tick; a
    /// gap trigger always forces one.
    public static let reconcileInterval: TimeInterval = 300
    /// Preferences are re-read at most this often (they have no local store, so
    /// each refresh is real requests).
    public static let preferencesInterval: TimeInterval = 60

    // MARK: - state

    private let actions: Actions
    private let now: @Sendable () -> Date
    private var userId: String?
    private var visible = false
    private var hasHydratedThisSession = false
    private var subscribed = false

    private var running = false
    private var pending: (reason: FreshnessSignal, reconcile: Bool)?
    private var lastReconcileAt: Date?
    private var lastPreferencesAt: Date?
    private var lastRebuildAt: Date?
    private var lastSilenceCheckAt: Date?
    private var tickerTask: Task<Void, Never>?
    private var stats = FreshnessStats()
    /// Tests await this to know the owner has gone quiet.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(actions: Actions, now: @escaping @Sendable () -> Date = { Date() }) {
        self.actions = actions
        self.now = now
    }

    // MARK: - session

    /// Bind (or unbind) the signed-in user. Unbinding stops everything and
    /// forgets the session's freshness history.
    public func setUser(_ uid: String?) {
        guard uid != userId else { return }
        userId = uid
        hasHydratedThisSession = false
        subscribed = false
        pending = nil
        lastReconcileAt = nil
        lastPreferencesAt = nil
        lastSilenceCheckAt = nil
        stats.lastRealtimeEventAt = nil
        if uid == nil { stopTicker() } else if visible { startTicker() }
    }

    /// The cold-start hydrate already ran (SyncCoordinator does it on the auth
    /// event); the owner takes over from there.
    public func markHydrated() {
        hasHydratedThisSession = true
        stats.fullHydrates += 1
        stats.lastSuccessfulPullAt = now()
    }

    /// Visibility is reported, not inferred — and it is what arms the floor
    /// interval. Unlike the old safety net this is safe to call before the sync
    /// engine exists: the state is remembered and applied when a user binds.
    public func setVisible(_ isVisible: Bool) {
        guard isVisible != visible else { return }
        visible = isVisible
        stats.visible = isVisible
        if isVisible {
            if userId != nil { startTicker() }
            report(.becameActive)
        } else {
            stopTicker()
        }
    }

    public func snapshot() -> FreshnessStats { stats }

    /// The local store holds rows the server never took (changes the user
    /// just discarded): the next pull is the full server-canonical hydrate —
    /// the catch-up never re-reads a row this device already has (audit
    /// 2026-09-22, C28).
    public func requireFullHydrate() {
        hasHydratedThisSession = false
        request(.manual, reconcile: true)
    }

    // MARK: - reporting

    /// The single entry point. Everything else in the app calls THIS instead of
    /// scheduling its own refresh.
    public func report(_ signal: FreshnessSignal) {
        switch signal {
        case .realtimeEvent:
            stats.lastRealtimeEventAt = now()
            return                       // liveness evidence only — never a pull

        case .resignedActive:
            return                       // handled by setVisible

        case .channelsSubscribed:
            subscribed = true
            stats.lastRealtimeEventAt = stats.lastRealtimeEventAt ?? now()
            lastSilenceCheckAt = now()
            request(signal, reconcile: true)

        case .becameActive, .networkRegained:
            ensureRealtime(networkRegained: signal == .networkRegained)
            request(signal, reconcile: true)

        case .socketConnected, .tokenRefreshed, .coldStart, .deafnessSuspected:
            request(signal, reconcile: true)

        case .floorTick:
            ensureRealtime(networkRegained: false)
            checkForDeafness()
            request(signal, reconcile: false)

        case .manual:
            request(signal, reconcile: false)
        }
    }

    // MARK: - deafness detection (never trust channel status)

    /// Rule (a): the socket says it's fine, the channels say SUBSCRIBED, and
    /// nothing at all has arrived for `deafSilenceThreshold` while the user is
    /// looking at the app. That is exactly the shape of the proven
    /// joined-but-deaf failure, so treat it as suspect: catch up AND rebuild.
    private func checkForDeafness() {
        guard visible, subscribed, userId != nil else { return }
        let t = now()
        let since = stats.lastRealtimeEventAt ?? lastRebuildAt
        guard let since, t.timeIntervalSince(since) >= Self.deafSilenceThreshold else { return }
        if let last = lastSilenceCheckAt, t.timeIntervalSince(last) < Self.deafSilenceThreshold { return }
        lastSilenceCheckAt = t
        stats.silenceRebuilds += 1
        print("[freshness] channel claims healthy but has delivered nothing for \(Int(t.timeIntervalSince(since)))s — rebuilding")
        scheduleRebuild()
        request(.deafnessSuspected, reconcile: true)
    }

    /// Rule (b), the stronger one: a catch-up APPLIED a row whose server stamp
    /// is older than `missedEventGrace`. A healthy channel would have delivered
    /// that row long before the pull found it, so the channel is deaf even
    /// though its status never changed.
    private func judgeMissedEvents(_ outcome: CatchUpPuller.Outcome, reason: FreshnessSignal) {
        // Only a pull that nothing else explains can accuse the channel. After
        // a background stretch, a reconnect or a token refresh the channel was
        // legitimately not listening, and THIS pull is what closes that gap —
        // finding old rows there says nothing about a deaf channel.
        guard reason == .floorTick || reason == .manual else { return }
        // `appliedStampsMs` only carries rows from tables this device was
        // already caught up on, and only rows strictly newer than the mark the
        // pull asked from — a first-run pull and the deliberate boundary re-read
        // are both excluded at the source.
        guard subscribed, !outcome.appliedStampsMs.isEmpty else { return }
        let cutoff = (now().timeIntervalSince1970 - Self.missedEventGrace) * 1000
        guard outcome.appliedStampsMs.contains(where: { $0 <= cutoff }) else { return }
        stats.missedEventRebuilds += 1
        print("[freshness] catch-up applied \(outcome.rowsApplied) row(s) realtime never delivered — channel is deaf, rebuilding")
        scheduleRebuild()
    }

    /// Fire-and-forget: a rebuild must never hold up the pull.
    private func ensureRealtime(networkRegained: Bool) {
        guard userId != nil else { return }
        let ensure = actions.ensureRealtime
        Task { await ensure(networkRegained) }
    }

    private func scheduleRebuild() {
        let t = now()
        if let last = lastRebuildAt, t.timeIntervalSince(last) < Self.rebuildCooldown { return }
        lastRebuildAt = t
        let rebuild = actions.rebuildSubscriptions
        Task { await rebuild() }
    }

    // MARK: - the one scheduler

    private func request(_ reason: FreshnessSignal, reconcile: Bool) {
        guard userId != nil else { return }
        if running {
            // Coalesce: overlapping triggers collapse into ONE trailing pull,
            // and the strongest requirement (a deletion sweep) wins.
            pending = (reason: reason, reconcile: (pending?.reconcile ?? false) || reconcile)
            return
        }
        running = true
        stats.inFlight = true
        Task { await self.drain(reason: reason, reconcile: reconcile) }
    }

    private func drain(reason: FreshnessSignal, reconcile: Bool) async {
        var next: (reason: FreshnessSignal, reconcile: Bool)? = (reason, reconcile)
        while let step = next {
            pending = nil
            await perform(reason: step.reason, reconcile: step.reconcile)
            next = pending
        }
        running = false
        stats.inFlight = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// One pull. A hydrate and a catch-up can never overlap because both run
    /// here, behind `running`.
    private func perform(reason: FreshnessSignal, reconcile: Bool) async {
        guard let uid = userId else { return }
        stats.lastPullReason = reason.rawValue
        if !hasHydratedThisSession {
            // First pull of the session, or the cursors are gone: the full
            // server-canonical hydrate is the fallback the catch-up needs.
            await actions.fullSync(uid)
            guard userId == uid else { return }
            hasHydratedThisSession = true
            stats.fullHydrates += 1
            stats.lastSuccessfulPullAt = now()
            return
        }
        var wantReconcile = reconcile
        if !wantReconcile, let last = lastReconcileAt, now().timeIntervalSince(last) >= Self.reconcileInterval {
            wantReconcile = true
        } else if lastReconcileAt == nil {
            wantReconcile = true
        }
        let outcome = await actions.catchUp(uid, wantReconcile)
        guard userId == uid else { return }
        stats.catchUps += 1
        stats.rowsApplied += outcome.rowsApplied
        stats.rowsDropped += outcome.idsDropped
        stats.rowsSkippedPending += outcome.rowsSkippedPending
        if !outcome.failedTables.isEmpty { stats.failedPulls += 1 }
        if wantReconcile { lastReconcileAt = now() }
        if outcome.failedTables.isEmpty { stats.lastSuccessfulPullAt = now() }
        judgeMissedEvents(outcome, reason: reason)
        await refreshPreferencesIfDue(reason: reason)
    }

    /// Account-wide preference rows live outside the local store, so the cursor
    /// pull can't carry them. Re-read them on the gap triggers (and at most once
    /// a minute) — that is what makes a notification level / lead time /
    /// timezone / ritual / interview-flag change on the web reach this device
    /// without a relaunch.
    private func refreshPreferencesIfDue(reason: FreshnessSignal) async {
        let gapTrigger: Set<FreshnessSignal> = [.becameActive, .networkRegained, .socketConnected,
                                                .channelsSubscribed, .tokenRefreshed, .deafnessSuspected,
                                                .manual]
        guard gapTrigger.contains(reason) else { return }
        if let last = lastPreferencesAt, now().timeIntervalSince(last) < Self.preferencesInterval { return }
        lastPreferencesAt = now()
        await actions.refreshPreferences()
    }

    // MARK: - floor interval

    private func startTicker() {
        guard tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.floorInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.report(.floorTick)
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    // MARK: - test support

    /// Resume once no pull is in flight. Used by tests; harmless in production.
    public func awaitIdle() async {
        guard running else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
