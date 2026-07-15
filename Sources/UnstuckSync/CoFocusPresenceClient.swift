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
    /// Stable session-join timestamp so a track state-flip (observe → here)
    /// doesn't reset "since".
    private let sinceMs: Double
    /// The latest track state + focus-timer we broadcast, retained so a re-track
    /// (state flip / timer change) rebuilds the full payload. `timer` is only
    /// carried into the wire payload while `track == .focusing` (T1b).
    private var track: CoFocusState?
    private var timer: CoFocusTimerState?

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
    public func start(track: CoFocusState?, timer: CoFocusTimerState? = nil,
                      onPeers: @escaping @Sendable ([CoFocusPeer]) -> Void) async {
        await stop()
        self.onPeers = onPeers
        self.track = track
        self.timer = timer
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
        // see it). Payload is ignored beyond "someone joined".
        let hsub = ch.onBroadcast(event: "hello") { _ in
            continuation.yield(.hello)
        }
        do {
            try await ch.subscribeWithError()
        } catch {
            sub.cancel()
            bsub.cancel()
            hsub.cancel()
            continuation.finish()
            self.onPeers = nil
            return
        }
        channel = ch
        subscription = sub
        broadcastSub = bsub
        helloSub = hsub
        pumpTask = Task { [weak self] in
            for await ev in stream { await self?.handle(ev) }
        }
        // Announce ourselves so any focuser re-broadcasts its timer to us (works
        // whether or not we track presence).
        await sendHello()
        if track != nil { await applyTrack() }
    }

    /// Flip our presence state in place (observe → here → focusing) without
    /// tearing down the channel — the recipient "Sit with them" toggle. Carries
    /// the focus timer through when flipping to `.focusing`.
    public func setTrack(_ track: CoFocusState?, timer: CoFocusTimerState? = nil) async {
        guard let ch = channel else { return }
        self.track = track
        self.timer = timer
        if track != nil { await applyTrack() }
        else { await ch.untrack() }
    }

    /// Re-broadcast an updated focus timer (pause / resume / extend / start), so
    /// a focusing peer's shared timer updates live on the other side (T1b). A
    /// no-op unless we're currently tracking as `.focusing`.
    public func updateTimer(_ timer: CoFocusTimerState?) async {
        self.timer = timer
        guard channel != nil, track == .focusing else { return }
        await applyTrack()
    }

    /// Leave + tear down (untrack, cancel the streams, remove the channel).
    public func stop() async {
        pumpTask?.cancel(); pumpTask = nil
        subscription?.cancel(); subscription = nil
        broadcastSub?.cancel(); broadcastSub = nil
        helloSub?.cancel(); helloSub = nil
        presences = [:]
        broadcastTimers = [:]
        onPeers = nil
        track = nil
        timer = nil
        if let ch = channel {
            await ch.untrack()
            await client.removeChannel(ch)
        }
        channel = nil
    }

    /// Track the current state + (for a focuser) the INITIAL live timer, then
    /// broadcast the timer. Timer fields are only attached while `.focusing`; a
    /// `.here`/observe peer omits them, so the wire payload matches web + Android
    /// field-for-field. Presence gives a fresh joiner an instant value; the
    /// broadcast is what reliably delivers subsequent pause/resume/extend.
    private func applyTrack() async {
        guard let ch = channel, let track else { return }
        let t = track == .focusing ? timer : nil
        // Epoch-ms are ROUNDED to whole before hitting the wire: our source is
        // Date().timeIntervalSince1970*1000, a FRACTIONAL Double, and supabase-swift
        // serializes a fractional Double as a JSON decimal (e.g. 1784151661971.73).
        // Android decodes these fields as Long (longOrNull), which REJECTS decimals →
        // the whole timer payload is dropped and an Android partner sees no timer.
        // An integral Double serializes as an integer literal, which every platform
        // parses. (web accepts either; iOS accepts either on the way back in.)
        try? await ch.track(TrackPayload(
            userId: selfId, name: selfName, state: track.rawValue, sinceMs: sinceMs.rounded(),
            sessionStartMs: (t?.sessionStartMs).map { $0.rounded() }, paused: t?.paused,
            pausedAtMs: (t?.pausedAtMs).map { $0.rounded() }, estimateMin: t?.estimateMin))
        await broadcastTimer()
    }

    /// Broadcast the live focus timer (fire-and-forget, reliable per event) so an
    /// ALREADY-present peer sees pause/resume/extend — which a presence re-track
    /// would silently drop. No-op unless we're focusing with a timer.
    private func broadcastTimer() async {
        guard let ch = channel, track == .focusing, let t = timer else { return }
        // Round epoch-ms to whole so they serialize as JSON integers, not decimals
        // (see applyTrack) — a fractional Double breaks Android's Long decode.
        let msg = TimerBroadcast(userId: selfId, sessionStartMs: t.sessionStartMs.rounded(),
                                 paused: t.paused, pausedAtMs: t.pausedAtMs.map { $0.rounded() },
                                 estimateMin: t.estimateMin)
        try? await ch.broadcast(event: "timer", message: msg)
    }

    /// Announce our arrival so focusers re-broadcast their current timer to us.
    private func sendHello() async {
        guard let ch = channel else { return }
        try? await ch.broadcast(event: "hello", message: HelloBroadcast(userId: selfId))
    }

    private func handle(_ ev: ChannelEvent) async {
        switch ev {
        case .presence(let diff): applyPresence(diff)
        case .timer(let json): applyTimerBroadcast(json)
        case .hello: await broadcastTimer()   // a peer joined → re-announce our timer
        }
    }

    private func applyPresence(_ diff: PresenceDiff) {
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

    /// A peer broadcast an updated live timer — overlay it (authoritative over
    /// the peer's presence session) and re-emit. The callback receives the
    /// broadcast ENVELOPE `{event,type,payload}`; our fields live under `payload`.
    private func applyTimerBroadcast(_ json: JSONObject) {
        guard let wire = try? json["payload"]?.decode(as: TimerBroadcast.self),
              let uid = wire.userId, uid != selfId, let start = wire.sessionStartMs else { return }
        broadcastTimers[uid] = CoFocusTimerState(
            sessionStartMs: start, paused: wire.paused ?? false,
            pausedAtMs: wire.pausedAtMs, estimateMin: wire.estimateMin ?? 25)
        emitPeers()
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
        case hello
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
    }
    /// The live-timer BROADCAST payload (event `timer`). Same fields as the
    /// presence timer, plus `userId` so the observer keys it. Optionals so the
    /// receiver is tolerant; the sender sets all but `pausedAtMs` (only paused).
    private struct TimerBroadcast: Codable, Sendable {
        let userId: String?
        let sessionStartMs: Double?
        let paused: Bool?
        let pausedAtMs: Double?
        let estimateMin: Int?
    }
    /// The `hello` join-announcement payload — just who joined (a focuser replies
    /// with its `timer`, so late joiners converge without a presence re-track).
    private struct HelloBroadcast: Codable, Sendable {
        let userId: String
    }
}
