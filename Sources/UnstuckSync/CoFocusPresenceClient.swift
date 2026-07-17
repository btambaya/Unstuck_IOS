// CoFocusPresenceClient / CoFocusChannel — the iOS port of the web
// lib/cofocus-presence.ts transport, on supabase-swift Realtime Presence (the
// first use of Presence in the app; the rest of realtime is postgres_changes).
// Both sides key the channel off the SAME task id (the owner's task id, which
// the recipient also sees via tasks_shared_with_me), so a partner + the owner
// meet on `cofocus:<taskId>`.
//
// `track` controls whether YOU appear to others:
//   .focusing — you're in a focus session on this task (owner side).
//   .here     — you're sitting with them / body-doubling (recipient side).
//   nil       — observe only: you see who's present but don't broadcast.
//
// PRESENCE carries WHO's here + their identity + the INITIAL focus timer. The
// MUTABLE focus timer (pause / resume / extend) travels by BROADCAST, not a
// presence re-track: Supabase Realtime presence does NOT propagate a metadata
// update to an already-present key — a repeat `track()` sticks at the first
// payload on every observer (verified against prod), so a partner never saw a
// pause. Broadcast is fire-and-forget + reliable per event; the observer
// overlays the latest broadcast timer onto the peer's presence session, and the
// focuser re-announces on a new peer join so late joiners converge.
//
// The pure "who's here" reduction (exclude self, sort focusing-first) lives in
// UnstuckCore's `coFocusPeers`; this layer only wires the channel + decodes the
// raw presences into `CoFocusMeta`. Idempotent + self-cleaning: `stop()`
// untracks and tears the channel down (no leaks).

import Foundation
import Supabase
import UnstuckCore

/// Sendable factory the app uses to build a co-focus channel per partner-shared
/// task. Wraps the shared SupabaseClient (kept encapsulated in UnstuckSync),
/// mirroring CircleClient / CollectionShareClient conventions.
public struct CoFocusPresenceClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    public func channel(taskId: String, selfId: String, selfName: String) -> CoFocusChannel {
        CoFocusChannel(client: client, taskId: taskId, selfId: selfId, selfName: selfName)
    }

    /// One-shot adoption probe — the JOIN check of join-or-mint (one true
    /// shared session): join `cofocus:<taskId>`, announce `hello` (any focuser
    /// re-broadcasts its timer), and wait ≤ `timeoutMs` for an ADOPTABLE
    /// session state (has a sessionId, not ended, started < 12h ago). Tears its
    /// channel down before returning. nil ⇒ no live shared session → MINT.
    ///
    /// supabase-swift dedupes channels by topic, so if another surface already
    /// holds this topic's channel (a PartnerPresence row observing it) we
    /// piggyback on it — no re-subscribe, and crucially NO removeChannel on the
    /// way out (that would kill the other surface's stream).
    public func probe(taskId: String, selfId: String, timeoutMs: UInt64 = 1_500) async -> SharedSessionMsg? {
        let ch = client.channel("cofocus:\(taskId)") { config in config.presence.key = selfId }
        let preexisting = ch.status == .subscribed || ch.status == .subscribing
        let (stream, continuation) = AsyncStream<SharedSessionMsg>.makeStream()
        let sub = ch.onBroadcast(event: "timer") { json in
            if let msg = CoFocusChannel.decodeControl(json) { continuation.yield(msg) }
        }
        if !preexisting {
            do { try await ch.subscribeWithError() } catch {
                sub.cancel()
                continuation.finish()
                await client.removeChannel(ch)
                return nil
            }
        }
        // RANDOM hello id (not selfId): a focuser that filters hellos by its
        // own user id would ignore a same-user probe — but the same user
        // focusing on ANOTHER device is exactly who must answer for
        // multi-device adoption.
        try? await ch.broadcast(event: "hello", message: HelloBroadcast(userId: UUID().uuidString.lowercased()))
        // First adoptable message vs the timeout — whichever lands first.
        let found: SharedSessionMsg? = await withTaskGroup(of: SharedSessionMsg?.self) { group in
            group.addTask {
                for await msg in stream {
                    if sharedSessionAdoptable(msg, now: Date().timeIntervalSince1970 * 1000) { return msg }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        sub.cancel()
        continuation.finish()
        if !preexisting { await client.removeChannel(ch) }
        return found
    }
}

/// One live presence channel (`cofocus:<taskId>`). Accumulates join/leave diffs
/// into a presence map, overlays each focusing peer's latest broadcast timer,
/// recomputes the OTHER peers via the pure `coFocusPeers`, and pushes them to
/// `onPeers`.
public actor CoFocusChannel {
    private let client: SupabaseClient
    private let taskId: String
    private let selfId: String
    private let selfName: String
    private var channel: RealtimeChannelV2?
    private var subscription: RealtimeSubscription?
    private var broadcastSub: RealtimeSubscription?
    private var helloSub: RealtimeSubscription?
    private var pumpTask: Task<Void, Never>?
    private var presences: [String: CoFocusMeta] = [:]
    /// Latest live-timer BROADCAST per peer (userId → timer). Authoritative for
    /// the mutable timer (pause/resume/extend); overlays the presence session.
    /// See the file header for why presence re-track can't carry this.
    private var broadcastTimers: [String: CoFocusTimerState] = [:]
    private var onPeers: (@Sendable ([CoFocusPeer]) -> Void)?
    /// Control surface (one true shared session): EVERY received `timer`
    /// message — including the new sessionId/rev/atMs/ended fields, including
    /// old-build messages without them — is handed to the app layer, which runs
    /// the pure LWW reducer + side effects. Display overlay stays internal.
    /// The Bool rides `rejoinPending`-at-receipt (Rejoin reconciliation v2):
    /// true ⇒ this is the FIRST same-session exchange after a rejoin — the app
    /// layer widens its most-ahead gate to it (flag or no flag).
    private var onControl: (@Sendable (SharedSessionMsg, Bool) -> Void)?
    /// Stable session-join timestamp so a track state-flip (observe → here)
    /// doesn't reset "since".
    private let sinceMs: Double
    /// The latest track state + focus-timer we broadcast, retained so a re-track
    /// (state flip / timer change) rebuilds the full payload. `timer` is only
    /// carried into the wire payload while `track == .focusing` (T1b).
    private var track: CoFocusState?
    private var timer: CoFocusTimerState?
    /// The full shared-session state (sessionId/rev/atMs — one true shared
    /// session) that rides along with every timer track/broadcast. nil for a
    /// display-only timer (never expected from this build's focusing path).
    private var shared: SharedSessionState?
    /// A final `ended` state that arrived while the channel was still
    /// subscribing (`channel` nil) — queued and sent as soon as the subscribe
    /// completes, so a finish racing the join is never silently dropped.
    private var pendingEnded: SharedSessionState?
    /// True while the local session is DIVERGED (offline controls that never
    /// delivered): every outgoing `timer` announcement — hello replies, rejoin
    /// re-announces, presence timer fields — is suppressed so a diverged
    /// client doesn't fight the channel with stale state. The app layer flips
    /// this alongside the live session's `divergedOffline` flag.
    private var controlsSuppressed = false
    /// Reports a CONTROL broadcast that could not be delivered (socket down /
    /// channel not joined / send error), with the affected sessionId — the app
    /// layer sets `divergedOffline` on that live session. Only genuine rev+1
    /// control sends report; idempotent re-announces don't (they're retried on
    /// every rejoin anyway).
    private var onDeliveryFailure: (@Sendable (String) -> Void)?
    /// Reports the SOCKET dropping while we announce a shared session, with
    /// that session's id — the app layer marks it diverged even when no local
    /// control happens during the outage (the offline RUNNER must not be
    /// rewound by the partner's mid-outage pause on rejoin; pairs with the
    /// divergence grace so a lone client self-clears).
    private var onSocketDown: (@Sendable (String) -> Void)?
    /// The diverged re-exchange grace expired with nobody focusing left in
    /// presence (or the bounded re-hellos exhausted): there is no state to
    /// converge with — the app layer clears `divergedOffline`, un-suppresses,
    /// and re-announces (its rev is already monotonic).
    private var onDivergedAlone: (@Sendable (String) -> Void)?
    /// Watches the shared realtime SOCKET for drop → reconnect (see
    /// startStatusMonitors for the supabase-swift 2.46 diagnosis).
    private var monitorTask: Task<Void, Never>?
    /// Watches OUR channel for an unexpected server-side close (`phx_close`).
    private var channelStatusTask: Task<Void, Never>?
    /// Re-entrancy guard: a `.connected` replay racing `start()`'s own join
    /// (or a foreground re-exchange) must not run two joinChannels at once.
    private var joining = false
    /// Post-re-exchange divergence grace (spec §Convergence amendments): after
    /// a DIVERGED (or rejoin-pending) client sends hello, wait ~5s for a
    /// same-session answer. On expiry: a focusing peer still in presence →
    /// re-hello + re-arm (≤3 tries); nobody focusing AND presence synced →
    /// diverged reports `onDivergedAlone`, un-flagged pending self-clears.
    private var divergenceGraceTask: Task<Void, Never>?
    private var divergenceGraceTries = 0
    /// Rejoin reconciliation v2 §2 — armed on EVERY rejoin (reconnect refire,
    /// forced rejoin, phx_close rebuild, start-rebind of an existing session),
    /// cleared by the first same-session exchange (a received same-session
    /// state, or our own genuine rev+1 control send). While pending, the
    /// idempotent state re-announces stay suppressed — a rejoin must never
    /// impose local state by rev authority (the live-reproduced build-28
    /// failure: an unflagged offline pause bumped rev, and the rejoin
    /// re-announce bulldozed the healthy partner's clock).
    private var rejoinPending = false
    /// v2 §4 — true once a full `presence_state` snapshot landed AFTER the
    /// last rejoin. The grace's "alone" conclusion requires it: an unsynced
    /// presence map counts as a focusing peer present, never as empty (the
    /// stale-presences race: concluding "alone" off a cleared/stale map
    /// re-announced stale state over a live, not-yet-visible partner).
    private var presenceSyncedSinceRejoin = false
    /// v2 §5 — socket un-parking. supabase-swift's ConnectionManager only
    /// auto-reconnects on the ws-error and heartbeat-timeout paths;
    /// `handleClose` (a server/send-failure close) just flips state to
    /// `.disconnected` and stops — the socket PARKS there forever (verified
    /// against 2.46: no initiateReconnect in handleClose). While we observe
    /// `.disconnected`, this task nudges `connect()` on a bounded backoff;
    /// every successful connect lands in the monitor's `.connected` arm.
    private var unparkTask: Task<Void, Never>?
    private var unparkAttempt = 0

    public init(client: SupabaseClient, taskId: String, selfId: String, selfName: String) {
        self.client = client
        self.taskId = taskId
        self.selfId = selfId
        self.selfName = selfName
        self.sinceMs = Date().timeIntervalSince1970 * 1000
    }

    /// Join the channel: wire the presence + broadcast streams BEFORE subscribing
    /// (both must be registered pre-subscribe), subscribe, then track our own
    /// state (if any). Idempotent — re-joining tears the old channel down first.
    /// `shared` is the full shared-session snapshot (one true shared session)
    /// carried on every timer track/broadcast; `onControl` receives every
    /// incoming `timer` message for the app-layer reducer. `suppressControls`
    /// binds in the DIVERGED state (a relaunch mid-divergence must not
    /// re-announce stale state); `onDeliveryFailure` reports an undeliverable
    /// control broadcast (the app layer flags `divergedOffline`).
    /// `rejoin` (Rejoin reconciliation v2 §1) marks a REBIND of an EXISTING
    /// session (relaunch / candidacy flap): the join tracks IDENTITY ONLY (no
    /// timer/session fields) and sends `hello{diverged: flag}` — never a state
    /// re-announce; `rejoinPending` arms and the first same-session exchange
    /// (or the grace fallback) reconciles. The genuine FIRST subscribe of a
    /// fresh session (mint/adopt) keeps the full announce.
    public func start(track: CoFocusState?, timer: CoFocusTimerState? = nil,
                      shared: SharedSessionState? = nil,
                      suppressControls: Bool = false,
                      rejoin: Bool = false,
                      onPeers: @escaping @Sendable ([CoFocusPeer]) -> Void,
                      onControl: (@Sendable (SharedSessionMsg, Bool) -> Void)? = nil,
                      onDeliveryFailure: (@Sendable (String) -> Void)? = nil,
                      onSocketDown: (@Sendable (String) -> Void)? = nil,
                      onDivergedAlone: (@Sendable (String) -> Void)? = nil) async {
        await stop()
        self.onPeers = onPeers
        self.onControl = onControl
        self.onDeliveryFailure = onDeliveryFailure
        self.onSocketDown = onSocketDown
        self.onDivergedAlone = onDivergedAlone
        self.track = track
        self.timer = timer
        self.shared = shared
        self.controlsSuppressed = suppressControls
        if rejoin { armRejoin() }
        let joined = await joinChannel()
        // The socket-status monitors run REGARDLESS of the join outcome: a
        // bind that failed offline (an OFFLINE MINT included) must still see
        // the eventual reconnect, join the channel, and announce itself — so
        // the callbacks stay armed too. A failed bind is NOT itself flagged as
        // divergence (the bind broadcast is the idempotent (re-)announce of
        // state the store already holds); the monitor's socket-down signal
        // reports `onSocketDown` and the app layer decides.
        startStatusMonitors()
        guard joined else { return }
        // Announce ourselves so any focuser re-broadcasts its timer to us (works
        // whether or not we track presence).
        await sendHello()
        if track != nil {
            if rejoin { await trackIdentity() } else { await applyTrack() }
        }
        // A rebind mid-divergence (relaunch) or of an existing session: the
        // hello above is the re-exchange — arm the grace so a lone client
        // self-clears (the flag AND/OR the rejoin-pending gate).
        if controlsSuppressed || rejoinPending { armDivergenceGrace(resetTries: true) }
    }

    /// Create (or re-acquire — supabase-swift dedupes by topic) the channel,
    /// wire the presence/timer/hello streams, subscribe, and start the pump +
    /// the channel-close observer. Shared by `start()` and the phx_close
    /// rebuild. False ⇒ subscribe failed (streams torn down, `channel` nil).
    private func joinChannel() async -> Bool {
        // Single-flight: the monitor's `.connected` replay (or a foreground
        // re-exchange) can race the initial join — never run two at once.
        guard !joining else { return false }
        joining = true
        defer { joining = false }
        // Presence key = our user id, so both sides self-exclude consistently.
        let ch = client.channel("cofocus:\(taskId)") { config in config.presence.key = selfId }
        let (stream, continuation) = AsyncStream<ChannelEvent>.makeStream()
        // Both callbacks are @Sendable and capture only the continuation — the
        // actor applies each event off the stream, serialized.
        let sub = ch.onPresenceChange { action in
            // A `presence_state` frame is the FULL authoritative snapshot (initial
            // join AND every post-reconnect resync); a `presence_diff` is an
            // incremental change. Tag it so apply() REPLACES on a snapshot (so a
            // peer that left while we were disconnected doesn't linger) vs MERGE a diff.
            continuation.yield(.presence(PresenceDiff(
                joins: action.joins, leaves: action.leaves,
                isSnapshot: action.rawMessage.event == "presence_state")))
        }
        let bsub = ch.onBroadcast(event: "timer") { json in
            continuation.yield(.timer(json))
        }
        // A joining peer announces itself with `hello`; a focuser replies with its
        // current timer so a LATE joiner converges — including an observe-only
        // peer that never tracks presence (so a presence-join re-announce can't
        // see it). A hello carrying `diverged: true` came from a DIVERGED peer:
        // the reply bypasses our own control suppression (see handle()).
        let hsub = ch.onBroadcast(event: "hello") { json in
            let diverged = (try? json["payload"]?.decode(as: HelloBroadcast.self))?.diverged == true
            continuation.yield(.hello(diverged: diverged))
        }
        do {
            try await ch.subscribeWithError()
        } catch {
            sub.cancel()
            bsub.cancel()
            hsub.cancel()
            continuation.finish()
            return false
        }
        channel = ch
        subscription = sub
        broadcastSub = bsub
        helloSub = hsub
        pumpTask = Task { [weak self] in
            for await ev in stream { await self?.handle(ev) }
        }
        startChannelCloseObserver(ch)
        // A finish raced the subscribe: send the queued FINAL state first —
        // `ended` is terminal, nothing else this channel says matters more.
        // Drained HERE (not in start) so every (re)join path — initial bind,
        // reconnect recovery, phx_close rebuild — delivers it.
        if let pending = pendingEnded {
            pendingEnded = nil
            try? await ch.broadcast(event: "timer", message: TimerBroadcast(state: pending, userId: selfId))
        }
        return true
    }

    /// Flip our presence state in place (observe → here → focusing) without
    /// tearing down the channel — the recipient "Sit with them" toggle. Carries
    /// the focus timer through when flipping to `.focusing`.
    public func setTrack(_ track: CoFocusState?, timer: CoFocusTimerState? = nil,
                         shared: SharedSessionState? = nil) async {
        guard let ch = channel else { return }
        self.track = track
        self.timer = timer
        self.shared = shared
        if track != nil { await applyTrack() }
        else { await ch.untrack() }
    }

    /// Re-broadcast an updated focus timer (pause / resume / extend / start), so
    /// a focusing peer's shared timer updates live on the other side (T1b). A
    /// no-op unless we're currently tracking as `.focusing`. `shared` carries
    /// the full control snapshot (rev+1 by the caller) alongside — this is THE
    /// control-send path, so an undeliverable send reports `onDeliveryFailure`.
    public func updateTimer(_ timer: CoFocusTimerState?, shared: SharedSessionState? = nil) async {
        self.timer = timer
        self.shared = shared
        guard track == .focusing else { return }
        guard channel != nil else {
            // The channel never came up (offline at bind): this control can't
            // go out — flag divergence.
            if let s = shared { onDeliveryFailure?(s.sessionId) }
            return
        }
        await applyTrack(control: true)
    }

    /// Flip control suppression (the transport side of `divergedOffline`).
    /// While suppressed, hello replies + rejoin re-announces + the presence
    /// timer fields all go quiet. Re-tracks presence on a change so the wire
    /// stops (or resumes) carrying the timer — WITHOUT a timer broadcast: on
    /// un-suppress the app immediately follows with the convergence control
    /// (`updateTimer`), and announcing the pre-convergence state first would
    /// briefly re-assert exactly the stale state we suppressed.
    public func setControlsSuppressed(_ suppressed: Bool) async {
        guard controlsSuppressed != suppressed else { return }
        controlsSuppressed = suppressed
        if !suppressed {
            // Convergence happened (or the app cleared the flag): the pending
            // divergence grace has nothing left to decide.
            divergenceGraceTask?.cancel(); divergenceGraceTask = nil
            divergenceGraceTries = 0
        }
        if channel != nil, track != nil { await applyTrack(announce: false) }
    }

    /// Refresh the retained announce state WITHOUT any wire traffic — the
    /// DIVERGED choke point keeps the (suppressed) channel current so a forced
    /// diverged-hello reply carries the TRUE local state (an offline pause
    /// included), not the pre-divergence snapshot.
    public func syncLocalState(timer: CoFocusTimerState?, shared: SharedSessionState?) {
        self.timer = timer
        self.shared = shared
    }

    /// Broadcast the session's FINAL state (`ended: true`) — finish/cancel ends
    /// it for both sides. One-shot + best-effort (the caller tears down right
    /// after); independent of the stored track/timer so it works mid-teardown.
    /// If the channel is still subscribing (`channel` nil), the state is
    /// QUEUED and sent the moment the subscribe completes — never dropped.
    public func broadcastEnded(_ state: SharedSessionState) async {
        guard let ch = channel else {
            pendingEnded = state
            return
        }
        try? await ch.broadcast(event: "timer", message: TimerBroadcast(state: state, userId: selfId))
    }

    /// Leave + tear down (untrack, cancel the streams, remove the channel).
    public func stop() async {
        releaseLocalState()
        if let ch = channel {
            await ch.untrack()
            await client.removeChannel(ch)
        }
        channel = nil
    }

    /// Release this actor's hold on the channel WITHOUT unsubscribing it.
    /// supabase-swift dedupes channels BY TOPIC (`client.channel(topic)`
    /// returns the registered instance) and `removeChannel` unconditionally
    /// unsubscribes it — so when ANOTHER surface still owns this topic (the
    /// session-lifetime co-focus channel while a PartnerPresence row unmounts),
    /// a full `stop()` would kill its live stream and an `untrack` would wipe
    /// the presence it re-tracked under the same key. Detach only cancels OUR
    /// callbacks + clears OUR state; the underlying channel stays subscribed.
    public func detach() async {
        releaseLocalState()
        channel = nil
    }

    private func releaseLocalState() {
        pumpTask?.cancel(); pumpTask = nil
        subscription?.cancel(); subscription = nil
        broadcastSub?.cancel(); broadcastSub = nil
        helloSub?.cancel(); helloSub = nil
        monitorTask?.cancel(); monitorTask = nil
        channelStatusTask?.cancel(); channelStatusTask = nil
        divergenceGraceTask?.cancel(); divergenceGraceTask = nil
        divergenceGraceTries = 0
        unparkTask?.cancel(); unparkTask = nil
        unparkAttempt = 0
        rejoinPending = false
        presenceSyncedSinceRejoin = false
        presences = [:]
        broadcastTimers = [:]
        onPeers = nil
        onControl = nil
        onDeliveryFailure = nil
        onSocketDown = nil
        onDivergedAlone = nil
        track = nil
        timer = nil
        shared = nil
        pendingEnded = nil
        controlsSuppressed = false
    }

    // MARK: - reconnect recovery (offline & reconnect convergence)

    /// Watch the shared realtime SOCKET across outages. supabase-swift 2.46
    /// diagnosis (why this exists):
    ///  • The client auto-reconnects (ConnectionManager: ws error / heartbeat
    ///    timeout → 7s-delay reconnect) and exposes
    ///    `RealtimeClientV2.statusChange` (`AsyncStream<RealtimeClientStatus>`:
    ///    disconnected/connecting/connected) — the reliable reconnect signal.
    ///  • A socket drop does NOT reset per-channel state: the channel sits at a
    ///    stale `.subscribed` (only a server `phx_close` drives
    ///    `.unsubscribed`), and both the SDK's post-reconnect
    ///    `rejoinChannels()` and any `subscribe()` call NO-OP on `.subscribed`
    ///    (ChannelStateManager) — so after a plain drop the channel is dead
    ///    server-side (no fresh `phx_join`) unless we intervene.
    /// So: on `.disconnected` we proactively `unsubscribe()` (forces the state
    /// machine to `.unsubscribed` during the outage, ARMING both the SDK's own
    /// rejoin and ours), and on re-`.connected` we drive `subscribeWithError()`
    /// (deduped with any in-flight attempt), then re-exchange. The in-loop
    /// awaits keep drop → reconnect handling strictly ordered (the stream
    /// buffers unbounded — no transitions are lost).
    private func startStatusMonitors() {
        monitorTask?.cancel()
        let realtime = client.realtimeV2
        monitorTask = Task { [weak self] in
            var sawDrop = false
            // statusChange REPLAYS the current status (AsyncValueSubject): a
            // monitor started while the socket is already down sees the
            // `.disconnected` immediately (the offline-mint case), and a
            // healthy start's `.connected` replay no-ops in recover (no drop,
            // channel already up).
            for await status in realtime.statusChange {
                if Task.isCancelled { return }
                switch status {
                case .disconnected:
                    if !sawDrop {
                        sawDrop = true
                        await self?.handleSocketDropped()
                    }
                    // v2 §5: a parked socket never un-parks itself (SDK
                    // handleClose does NOT reconnect) — nudge connect().
                    await self?.startSocketUnpark()
                case .connected:
                    let dropped = sawDrop
                    sawDrop = false
                    await self?.cancelSocketUnpark(resetAttempts: true)
                    await self?.recoverAfterReconnect(afterDrop: dropped)
                case .connecting:
                    // Someone (the SDK's own error/heartbeat reconnect, our
                    // nudge, or a subscribe) is already driving a connect —
                    // stand the nudger down; `.disconnected` re-arms it.
                    await self?.cancelSocketUnpark(resetAttempts: false)
                @unknown default:
                    break
                }
            }
        }
    }

    /// v2 §5 — bounded-backoff `connect()` nudges while the socket sits
    /// `.disconnected` (2s, 4s, 8s, 16s, then a 30s cap — persistent: an
    /// airplane-mode outage keeps failing cheaply until connectivity returns).
    /// Single-flight; cancelled on `.connecting`/`.connected` and at teardown.
    private func startSocketUnpark() {
        guard unparkTask == nil else { return }
        let realtime = client.realtimeV2
        unparkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let attempt = await self?.bumpUnparkAttempt() else { return }
                let delaySec = min(30.0, pow(2.0, Double(min(attempt, 6))))
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                guard !Task.isCancelled, realtime.status == .disconnected else { return }
                // Either succeeds (monitor's `.connected` arm cancels us and
                // runs the rejoin cycle) or fails back to `.disconnected` —
                // loop for the next, longer-spaced nudge.
                await realtime.connect()
            }
        }
    }

    private func bumpUnparkAttempt() -> Int {
        unparkAttempt += 1
        return unparkAttempt
    }

    private func cancelSocketUnpark(resetAttempts: Bool) {
        unparkTask?.cancel(); unparkTask = nil
        if resetAttempts { unparkAttempt = 0 }
    }

    /// The socket dropped. Two jobs:
    ///  1. Socket-down ALONE marks divergence (sessionId-guarded in the app
    ///     layer): while the socket is down the partner's controls can't reach
    ///     us and ours can't reach them — the offline RUNNER must not be
    ///     rewound by the partner's mid-outage pause on rejoin, even when NO
    ///     local control happens during the outage. The divergence grace
    ///     clears a lone client after reconnect.
    ///  2. Force our channel's state machine to `.unsubscribed` now — the
    ///     leave frame goes nowhere (socket's down) and the state manager
    ///     force-transitions after its bounded server-close wait — so that on
    ///     reconnect a REAL fresh `phx_join` happens instead of a no-op on
    ///     the stale `.subscribed`.
    private func handleSocketDropped() async {
        if let sid = shared?.sessionId { onSocketDown?(sid) }
        guard let ch = channel, ch.status == .subscribed else { return }
        await ch.unsubscribe()
    }

    /// The socket reconnected: make sure our channel genuinely re-joined,
    /// then run the v2 REJOIN cycle (hello-only). Handles ALL three shapes:
    ///  • `channel == nil` — the bind never succeeded (offline mint) or a
    ///    failed rebuild: join from scratch;
    ///  • after a drop — force an unsubscribe first if the stale
    ///    `.subscribed` survived (the drop can race the prearm), re-subscribe,
    ///    and RE-ARM the channel-close observer (its task consumed itself on
    ///    the prearm's expected unsubscribe);
    ///  • a healthy `.connected` replay (no drop, channel up) — no-op.
    /// Rejoin reconciliation v2 §1: a rejoin NEVER re-announces state (the
    /// build-28 re-announce imposed an unflagged offline pause on the healthy
    /// partner by rev authority) — identity-only presence + `hello{diverged}`;
    /// `rejoinPending` arms and the first same-session exchange (or the grace
    /// fallback, which for a flagged offline mint delivers the delayed
    /// announce via `onDivergedAlone`) reconciles.
    private func recoverAfterReconnect(afterDrop: Bool) async {
        if channel == nil {
            armRejoin()
            guard await joinChannel() else { return }
        } else if afterDrop, let ch = channel {
            armRejoin()
            guard await forceRejoin(ch) else { return }
        } else {
            return
        }
        if track != nil { await trackIdentity() }
        await sendHello()
        armDivergenceGrace(resetTries: true)
    }

    /// Force a genuine re-join of the EXISTING channel instance: unsubscribe a
    /// stale `.subscribed` first (a plain drop leaves the state machine there,
    /// where both the SDK's rejoin and `subscribe()` no-op), re-subscribe, and
    /// re-arm the close observer around our own EXPECTED unsubscribe. Shares
    /// the `joining` single-flight guard with joinChannel — a monitor replay
    /// racing a foreground re-exchange must not run two rejoins at once.
    private func forceRejoin(_ ch: RealtimeChannelV2) async -> Bool {
        guard !joining else { return false }
        joining = true
        defer { joining = false }
        channelStatusTask?.cancel(); channelStatusTask = nil
        if ch.status == .subscribed { await ch.unsubscribe() }
        try? await ch.subscribeWithError()
        guard ch.status == .subscribed else { return false }
        startChannelCloseObserver(ch)
        return true
    }

    /// Arm the v2 rejoin gate: `rejoinPending` until the first same-session
    /// exchange, and the presence map counts as UNSYNCED until the fresh
    /// join's `presence_state` snapshot lands (v2 §4).
    private func armRejoin() {
        rejoinPending = true
        presenceSyncedSinceRejoin = false
    }

    /// Re-assert presence IDENTITY after a rejoin — name/state/since only,
    /// carrying NO timer or session fields (v2 §1: no state on the wire by
    /// rev authority on any rejoin). Peers re-learn the live timer from the
    /// first post-reconciliation broadcast (hello replies / controls / the
    /// grace fallback's announce), which is the authoritative path anyway.
    private func trackIdentity() async {
        guard let ch = channel, let track else { return }
        try? await ch.track(TrackPayload(
            userId: selfId, name: selfName, state: track.rawValue, sinceMs: sinceMs.rounded(),
            sessionStartMs: nil, paused: nil, pausedAtMs: nil, estimateMin: nil,
            sessionId: nil, rev: nil, atMs: nil, ended: nil))
    }

    /// Watch OUR channel for a server-side close (`phx_close` → `.subscribed`
    /// → `.unsubscribed`). That close also REMOVES the channel from the
    /// client's routing table, so re-subscribing the same instance would never
    /// receive again — a fresh `client.channel(topic)` re-registration is
    /// required (mirrors RealtimeMirror's self-heal rationale). Our own
    /// teardown cancels this observer before removing the channel; the
    /// socket-drop prearm unsubscribes while the socket is NOT connected; and
    /// the recover/re-exchange paths cancel it around their own EXPECTED
    /// unsubscribes and RE-ARM it after every successful re-subscribe (the
    /// task consumes itself on the first observed close) — so a close observed
    /// while the socket IS connected is the genuine server-side case.
    private func startChannelCloseObserver(_ ch: RealtimeChannelV2) {
        channelStatusTask?.cancel()
        channelStatusTask = Task { [weak self] in
            var wasSubscribed = false
            for await status in ch.statusChange {
                if Task.isCancelled { return }
                switch status {
                case .subscribed:
                    wasSubscribed = true
                case .unsubscribed:
                    if wasSubscribed {
                        // Hand off to an UNSTRUCTURED task: the rebuild wires a
                        // new observer and cancels this one — subscribing from
                        // within the dying task would see its cancellation.
                        let actor = self
                        Task { await actor?.handleChannelClosed(ch) }
                        return
                    }
                case .subscribing, .unsubscribing:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    /// A live channel closed under us. Socket down ⇒ the drop path owns
    /// recovery (prearm + reconnect). Socket up ⇒ server-side `phx_close`:
    /// rebuild on a fresh (re-registered) instance, re-track, re-exchange.
    /// No-ops after stop()/detach() released the callbacks (`onPeers == nil`)
    /// — a straggling close observation must never resurrect a dead channel.
    private func handleChannelClosed(_ closed: RealtimeChannelV2) async {
        guard channel === closed, onPeers != nil,
              client.realtimeV2.status == .connected else { return }
        pumpTask?.cancel(); pumpTask = nil
        subscription?.cancel(); subscription = nil
        broadcastSub?.cancel(); broadcastSub = nil
        helloSub?.cancel(); helloSub = nil
        channel = nil
        presences = [:]
        broadcastTimers = [:]
        // No removeChannel: the server close already unregistered the topic.
        // joinChannel re-registers it (client.channel dedupes if it didn't)
        // and rebuilds presence from the fresh `presence_state` snapshot.
        // v2 §1: the rebuild is a REJOIN — identity-only track + hello, never
        // a state re-announce; rejoinPending + the grace reconcile.
        armRejoin()
        guard await joinChannel() else { return }
        if track != nil { await trackIdentity() }
        await sendHello()
        armDivergenceGrace(resetTries: true)
    }

    /// Foreground / manual re-exchange (belt-and-braces beside the socket
    /// monitor — the scenePhase `.active` hook calls this through the app's
    /// syncNow): un-park a dead socket, ensure the channel is genuinely
    /// joined (driving the forced rejoin if the SDK's lifecycle reconnect
    /// landed without one), and `hello` so any focuser re-broadcasts its
    /// state — which is what lets a rejoining/diverged client converge.
    /// Rejoin reconciliation v2 §1/§5: NEVER a state re-announce here — a
    /// "healthy" status read may be a lie (a dead socket goes unnoticed for
    /// up to ~2 heartbeats), so the old idempotent applyTrack could impose
    /// unflagged offline state by rev authority. Hello-only on EVERY branch.
    public func reexchange() async {
        // v2 §5: supabase-swift's handleClose parks the socket at
        // `.disconnected` (no auto-reconnect on that path) — foreground must
        // drive connect() explicitly before any rejoin can succeed. A socket
        // we just un-parked ALWAYS forces the rejoin below: the channel's
        // `.subscribed` from before the park is dead server-side (no fresh
        // phx_join happens on its own).
        var unparked = false
        if client.realtimeV2.status == .disconnected {
            await client.realtimeV2.connect()
            unparked = true
        }
        if channel == nil {
            // The bind never succeeded (offline at start — an offline mint):
            // the foreground re-exchange is the recovery trigger.
            armRejoin()
            guard await joinChannel() else { return }
            if track != nil { await trackIdentity() }
        } else if let ch = channel,
                  unparked || ch.status != .subscribed || client.realtimeV2.status != .connected {
            // Not genuinely joined (incl. a socket that read `.disconnected`
            // above and just reconnected): force a real re-join.
            armRejoin()
            guard await forceRejoin(ch) else { return }
            if track != nil { await trackIdentity() }
        }
        // Always hello — even on a healthy-reading channel (the read may be
        // stale; a hello is cheap and a focuser's reply is what reconciles).
        await sendHello()
        // Rejoin/diverged re-exchange: arm the alone-fallback grace (≤3
        // re-hellos toward a focusing peer, then clear-and-announce).
        if controlsSuppressed || rejoinPending { armDivergenceGrace(resetTries: true) }
    }

    /// Track the current state + (for a focuser) the INITIAL live timer, then
    /// broadcast the timer. Timer fields are only attached while `.focusing`; a
    /// `.here`/observe peer omits them, so the wire payload matches web + Android
    /// field-for-field. Presence gives a fresh joiner an instant value; the
    /// broadcast is what reliably delivers subsequent pause/resume/extend.
    /// While DIVERGED (`controlsSuppressed`) the timer/shared fields are
    /// omitted from presence too — stale state stays off the wire entirely.
    /// `control` marks a genuine rev+1 control send (delivery failure flags
    /// divergence); `announce: false` re-tracks presence without the trailing
    /// timer broadcast (the un-suppress path).
    private func applyTrack(control: Bool = false, announce: Bool = true) async {
        guard let ch = channel, let track else { return }
        let t = (track == .focusing && !controlsSuppressed) ? timer : nil
        // Epoch-ms are ROUNDED to whole before hitting the wire: our source is
        // Date().timeIntervalSince1970*1000, a FRACTIONAL Double, and supabase-swift
        // serializes a fractional Double as a JSON decimal (e.g. 1784151661971.73).
        // Android decodes these fields as Long (longOrNull), which REJECTS decimals →
        // the whole timer payload is dropped and an Android partner sees no timer.
        // An integral Double serializes as an integer literal, which every platform
        // parses. (web accepts either; iOS accepts either on the way back in.)
        // Shared-session fields ride on presence too (fresh joiners get an
        // instant, adoptable-looking render); broadcast stays the authoritative
        // control path (a presence re-track doesn't propagate — file header).
        let s = (track == .focusing && !controlsSuppressed) ? shared : nil
        try? await ch.track(TrackPayload(
            userId: selfId, name: selfName, state: track.rawValue, sinceMs: sinceMs.rounded(),
            sessionStartMs: (t?.sessionStartMs).map { $0.rounded() }, paused: t?.paused,
            pausedAtMs: (t?.pausedAtMs).map { $0.rounded() }, estimateMin: t?.estimateMin,
            sessionId: s?.sessionId, rev: s?.rev, atMs: (s?.atMs).map { $0.rounded() },
            ended: s.map { $0.ended }))
        if announce { await broadcastTimer(control: control) }
    }

    /// Broadcast the live focus timer (fire-and-forget, reliable per event) so an
    /// ALREADY-present peer sees pause/resume/extend — which a presence re-track
    /// would silently drop. No-op unless we're focusing with a timer (or while
    /// control-suppressed — a diverged client stays quiet). Sends the FULL
    /// shared-session state (sessionId/rev/atMs/ended) when available, so
    /// receivers can adopt/apply it (one true shared session); old builds ignore
    /// the extra fields and keep the read-only shared view.
    ///
    /// Delivery-failure detection (`control` sends only): the SDK's throwing
    /// `broadcast(event:message: some Codable)` only throws on ENCODING — the
    /// delivery itself goes through the non-throwing JSONObject overload, which
    /// silently REST-falls-back when not `.subscribed` (errors swallowed) and
    /// buffers the socket frame when disconnected (flushed post-reconnect with
    /// a STALE joinRef the server drops). So an outage is detected by GATING on
    /// the observable states — socket `.connected` + channel `.subscribed` —
    /// with the catch kept as belt for encode errors.
    /// `bypassSuppression` answers a DIVERGED peer's hello: a focuser ALWAYS
    /// replies with its state — even while itself diverged — because the
    /// diverged receiver resolves via most-ahead, not plain LWW (this breaks
    /// the both-diverged suppress-deadlock). Only that reply bypasses.
    private func broadcastTimer(control: Bool = false, bypassSuppression: Bool = false) async {
        guard let ch = channel, track == .focusing, let t = timer,
              !controlsSuppressed || bypassSuppression else { return }
        // Rejoin reconciliation v2 §2: while `rejoinPending` the idempotent
        // re-announces stay suppressed (no local state on the wire by rev
        // authority until the first exchange reconciles). A genuine rev+1
        // CONTROL still sends — fresh user intent, applied locally first,
        // plain LWW on the receiver — and, as an outbound same-session
        // exchange, completes the pending gate itself (also protecting the
        // fresh control from being reverted by a most-ahead adopt of the
        // partner's pre-control reply). The forced diverged-hello reply keeps
        // bypassing WITHOUT clearing (we still owe the incoming state a
        // reconciliation).
        if rejoinPending {
            guard control || bypassSuppression else { return }
            if control { rejoinPending = false }
        }
        // Round epoch-ms to whole so they serialize as JSON integers, not decimals
        // (see applyTrack) — a fractional Double breaks Android's Long decode.
        let msg = TimerBroadcast(userId: selfId, sessionStartMs: t.sessionStartMs.rounded(),
                                 paused: t.paused, pausedAtMs: t.pausedAtMs.map { $0.rounded() },
                                 estimateMin: t.estimateMin,
                                 sessionId: shared?.sessionId, rev: shared?.rev,
                                 atMs: (shared?.atMs).map { $0.rounded() },
                                 ended: shared.map { $0.ended })
        let controlSid = control ? shared?.sessionId : nil
        if let sid = controlSid,
           client.realtimeV2.status != .connected || ch.status != .subscribed {
            onDeliveryFailure?(sid)
            return
        }
        do { try await ch.broadcast(event: "timer", message: msg) }
        catch { if let sid = controlSid { onDeliveryFailure?(sid) } }
    }

    /// Announce our arrival so focusers re-broadcast their current timer to
    /// us. Carries `diverged: true` while our controls are suppressed — a
    /// focusing peer then replies even if IT is diverged too (deadlock break).
    private func sendHello() async {
        guard let ch = channel else { return }
        try? await ch.broadcast(
            event: "hello",
            message: HelloBroadcast(userId: selfId, diverged: controlsSuppressed ? true : nil))
    }

    private func handle(_ ev: ChannelEvent) async {
        switch ev {
        case .presence(let diff): applyPresence(diff)
        case .timer(let json): applyTimerBroadcast(json)
        // A peer joined → re-announce our timer. A DIVERGED peer's hello is
        // answered even while we're suppressed ourselves (most-ahead resolves
        // it on their side; both-diverged converges through these replies).
        case .hello(let diverged): await broadcastTimer(bypassSuppression: diverged)
        }
    }

    // MARK: - divergence grace (spec §Convergence-protocol amendments + v2 §4)

    /// After a diverged/rejoin re-exchange hello, wait ~5s for a same-session answer.
    private static let divergenceGraceNs: UInt64 = 5_000_000_000

    /// Arm (or re-arm) the post-hello grace. `resetTries` on every FRESH
    /// re-exchange trigger (rejoin / foreground / rebuild); the expiry re-arms
    /// without a reset so the ≤3 bound holds within one convergence attempt.
    private func armDivergenceGrace(resetTries: Bool) {
        guard controlsSuppressed || rejoinPending else { return }
        if resetTries { divergenceGraceTries = 0 }
        divergenceGraceTask?.cancel()
        divergenceGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.divergenceGraceNs)
            guard !Task.isCancelled else { return }
            await self?.divergenceGraceExpired()
        }
    }

    /// The grace expired with the divergence / rejoin gate still unresolved.
    /// The decision is the pure `divergenceGraceExpiry` (v2 §4):
    ///  • a focusing peer in presence — or a presence map that hasn't SYNCED
    ///    since the rejoin, which proves nothing and counts as one — may just
    ///    be slow: re-hello and re-arm, bounded to 3 tries;
    ///  • synced + nobody focusing (or retries exhausted): genuinely alone.
    ///    DIVERGED → report `onDivergedAlone` (the app clears the flag and
    ///    re-announces via the delivery-verified control path, re-flagging on
    ///    failure). Un-flagged rejoin-pending → self-clear and resume
    ///    announcing (idempotent same rev; safe — no focusing peer to fight).
    ///  • retries exhausted with presence NEVER synced: the join is broken —
    ///    stand down (conclude nothing off an unsynced map); the next rejoin
    ///    cycle (socket monitor / foreground re-exchange) restarts the grace.
    private func divergenceGraceExpired() async {
        guard controlsSuppressed || rejoinPending else { return }
        let focusing = coFocusPeers(from: presences, selfId: selfId)
            .contains { $0.state == .focusing }
        switch divergenceGraceExpiry(focusingPeerPresent: focusing,
                                     presenceSynced: presenceSyncedSinceRejoin,
                                     tries: divergenceGraceTries) {
        case .rehello:
            divergenceGraceTries += 1
            await sendHello()
            armDivergenceGrace(resetTries: false)
        case .standDown:
            break
        case .clearAndAnnounce:
            if controlsSuppressed {
                if let sid = shared?.sessionId { onDivergedAlone?(sid) }
            } else {
                rejoinPending = false
                if track != nil { await applyTrack() }
            }
        }
    }

    private func applyPresence(_ diff: PresenceDiff) {
        // v2 §4: a full snapshot is the post-(re)join presence SYNC — only
        // after one may the grace trust an empty map to mean "alone".
        if diff.isSnapshot { presenceSyncedSinceRejoin = true }
        if diff.isSnapshot {
            // Full (re)subscribe snapshot: rebuild from scratch so peers that
            // left during a socket drop (whose leave we never saw) don't linger.
            var next: [String: CoFocusMeta] = [:]
            for (key, presence) in diff.joins {
                next[key] = Self.decodeMeta(presence, fallbackKey: key)
            }
            presences = next
            // Drop cached broadcast timers for peers no longer present.
            broadcastTimers = broadcastTimers.filter { presences.keys.contains($0.key) }
        } else {
            // Incremental diff: Phoenix-safe order — LEAVES before JOINS, so a key
            // present in both (a re-track / coalesced change) ends up present, not
            // removed by a stale leave.
            for key in diff.leaves.keys {
                presences.removeValue(forKey: key)
                broadcastTimers.removeValue(forKey: key)
            }
            for (key, presence) in diff.joins {
                presences[key] = Self.decodeMeta(presence, fallbackKey: key)
            }
        }
        emitPeers()
    }

    /// A peer broadcast an updated live timer — hand EVERY message to the
    /// control surface (the app-layer LWW reducer decides; a message without a
    /// sessionId is an old build's → display-only), then overlay it on the
    /// peer's presence session (authoritative for the visible timer) and
    /// re-emit. The callback receives the broadcast ENVELOPE
    /// `{event,type,payload}`; our fields live under `payload`.
    private func applyTimerBroadcast(_ json: JSONObject) {
        guard let msg = Self.decodeControl(json) else { return }
        // Rejoin reconciliation v2 §2: the FIRST same-session state received
        // after a rejoin completes the exchange — clear the pending gate and
        // surface its pre-clear value with the control, so the app layer runs
        // most-ahead reconciliation on exactly this first exchange (flag or
        // no flag). The grace has nothing left to decide unless the DIVERGED
        // machinery still owns it.
        let wasRejoinPending = rejoinPending
        if rejoinPending, let sid = msg.sessionId,
           shared == nil || sid == shared?.sessionId {
            rejoinPending = false
            if !controlsSuppressed {
                divergenceGraceTask?.cancel(); divergenceGraceTask = nil
                divergenceGraceTries = 0
            }
        }
        // Control first — includes same-user-other-device messages (one user,
        // two devices, one session) that the peers display excludes below.
        onControl?(msg, wasRejoinPending)
        guard let uid = msg.userId, uid != selfId, let start = msg.sessionStartMs else { return }
        if msg.ended == true {
            // Final state: drop the overlay (the ender's presence leave follows,
            // but don't show a stale running clock in the gap).
            broadcastTimers.removeValue(forKey: uid)
        } else {
            broadcastTimers[uid] = CoFocusTimerState(
                sessionStartMs: start, paused: msg.paused ?? false,
                pausedAtMs: msg.pausedAtMs, estimateMin: msg.estimateMin ?? 25)
        }
        emitPeers()
    }

    /// Decode a broadcast `timer` envelope into the platform-neutral control
    /// message. Tolerant: every field optional (old builds omit the new ones).
    static func decodeControl(_ json: JSONObject) -> SharedSessionMsg? {
        guard let wire = try? json["payload"]?.decode(as: TimerBroadcast.self) else { return nil }
        return SharedSessionMsg(
            userId: wire.userId, sessionId: wire.sessionId,
            sessionStartMs: wire.sessionStartMs, paused: wire.paused,
            pausedAtMs: wire.pausedAtMs, estimateMin: wire.estimateMin,
            rev: wire.rev, atMs: wire.atMs, ended: wire.ended)
    }

    /// Emit the OTHER peers, overlaying each focusing peer's latest broadcast
    /// timer (authoritative for pause/resume/extend) onto its presence session.
    private func emitPeers() {
        var peers = coFocusPeers(from: presences, selfId: selfId)
        for i in peers.indices where peers[i].state == .focusing {
            if let bt = broadcastTimers[peers[i].userId] {
                peers[i].sessionStartMs = bt.sessionStartMs
                peers[i].paused = bt.paused
                peers[i].pausedAtMs = bt.pausedAtMs
                peers[i].estimateMin = bt.estimateMin
            }
        }
        onPeers?(peers)
    }

    /// Decode one raw presence into a CoFocusMeta (tolerant — your own presence
    /// can arrive without state, and any decode failure degrades to the key).
    private static func decodeMeta(_ presence: PresenceV2, fallbackKey: String) -> CoFocusMeta {
        let wire = try? presence.decodeState(as: MetaWire.self)
        return CoFocusMeta(
            userId: wire?.userId ?? fallbackKey,
            name: wire?.name,
            state: wire?.state.flatMap(CoFocusState.init(rawValue:)),
            sinceMs: wire?.sinceMs,
            sessionStartMs: wire?.sessionStartMs,
            paused: wire?.paused,
            pausedAtMs: wire?.pausedAtMs,
            estimateMin: wire?.estimateMin)
    }

    private enum ChannelEvent: Sendable {
        case presence(PresenceDiff)
        case timer(JSONObject)
        /// `diverged` = the joining peer declared itself diverged (its reply
        /// must bypass our own control suppression).
        case hello(diverged: Bool)
    }
    private struct PresenceDiff: Sendable {
        let joins: [String: PresenceV2]
        let leaves: [String: PresenceV2]
        /// True for a `presence_state` full snapshot (initial join / post-reconnect
        /// resync) → apply() REPLACES; false for an incremental `presence_diff` → MERGE.
        let isSnapshot: Bool
    }
    private struct TrackPayload: Codable, Sendable {
        let userId: String
        let name: String
        let state: String
        let sinceMs: Double
        // Focus-timer fields (T1b) — nil for a non-focuser, so Codable's
        // `encodeIfPresent` omits them (matching the web/Android payload shape).
        let sessionStartMs: Double?
        let paused: Bool?
        let pausedAtMs: Double?
        let estimateMin: Int?
        // One-true-shared-session fields — the session identity + control rev
        // ride on presence too, so fresh joiners see the full state instantly.
        let sessionId: String?
        let rev: Int?
        let atMs: Double?
        let ended: Bool?
    }
    private struct MetaWire: Decodable {
        var userId: String?
        var name: String?
        var state: String?
        var sinceMs: Double?
        var sessionStartMs: Double?
        var paused: Bool?
        var pausedAtMs: Double?
        var estimateMin: Int?
        // One-true-shared-session fields (tolerated, currently display-unused —
        // the broadcast path is the authoritative control surface).
        var sessionId: String?
        var rev: Int?
        var atMs: Double?
        var ended: Bool?
    }
}

/// The live-timer BROADCAST payload (event `timer`). Same fields as the
/// presence timer, plus `userId` so the observer keys it, plus the one-true-
/// shared-session control fields (sessionId/rev/atMs/ended). Optionals so the
/// receiver is tolerant of old builds; new builds treat a message without a
/// `sessionId` as view-only (never adopt/control it).
struct TimerBroadcast: Codable, Sendable {
    let userId: String?
    let sessionStartMs: Double?
    let paused: Bool?
    let pausedAtMs: Double?
    let estimateMin: Int?
    let sessionId: String?
    let rev: Int?
    let atMs: Double?
    let ended: Bool?

    init(userId: String?, sessionStartMs: Double?, paused: Bool?, pausedAtMs: Double?,
         estimateMin: Int?, sessionId: String?, rev: Int?, atMs: Double?, ended: Bool?) {
        self.userId = userId
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
        self.sessionId = sessionId
        self.rev = rev
        self.atMs = atMs
        self.ended = ended
    }

    /// The full-state snapshot form (all epoch-ms rounded — Android Long decode).
    init(state: SharedSessionState, userId: String) {
        self.init(userId: userId, sessionStartMs: state.sessionStartMs.rounded(),
                  paused: state.paused, pausedAtMs: state.pausedAtMs.map { $0.rounded() },
                  estimateMin: state.estimateMin, sessionId: state.sessionId,
                  rev: state.rev, atMs: state.atMs.rounded(), ended: state.ended)
    }
}

/// The `hello` join-announcement payload — who joined (a focuser replies with
/// its `timer`, so late joiners converge without a presence re-track), plus
/// `diverged: true` when the sender's local session is DIVERGED (offline
/// controls that never delivered). A focuser ALWAYS answers a diverged hello
/// with its state — even while itself diverged — because a diverged receiver
/// resolves via most-ahead, not plain LWW; this breaks the both-diverged
/// suppress-deadlock. Optional so old builds' hellos (no field) decode.
struct HelloBroadcast: Codable, Sendable {
    let userId: String
    let diverged: Bool?

    init(userId: String, diverged: Bool? = nil) {
        self.userId = userId
        self.diverged = diverged
    }
}
