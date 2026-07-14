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
/// into a presence map, recomputes the OTHER peers via the pure `coFocusPeers`,
/// and pushes them to `onPeers`.
public actor CoFocusChannel {
    private let client: SupabaseClient
    private let taskId: String
    private let selfId: String
    private let selfName: String
    private var channel: RealtimeChannelV2?
    private var subscription: RealtimeSubscription?
    private var pumpTask: Task<Void, Never>?
    private var presences: [String: CoFocusMeta] = [:]
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

    /// Join the channel: wire the presence diff stream BEFORE subscribing
    /// (presence callbacks must be registered pre-subscribe), subscribe, then
    /// track our own state (if any). Idempotent — re-joining tears the old
    /// channel down first.
    public func start(track: CoFocusState?, timer: CoFocusTimerState? = nil,
                      onPeers: @escaping @Sendable ([CoFocusPeer]) -> Void) async {
        await stop()
        self.onPeers = onPeers
        self.track = track
        self.timer = timer
        // Presence key = our user id, so both sides self-exclude consistently.
        let ch = client.channel("cofocus:\(taskId)") { config in config.presence.key = selfId }
        let (stream, continuation) = AsyncStream<PresenceDiff>.makeStream()
        // The callback is @Sendable and captures only the continuation — the
        // actor applies each diff off the stream.
        let sub = ch.onPresenceChange { action in
            // A `presence_state` frame is the FULL authoritative snapshot (initial
            // join AND every post-reconnect resync); a `presence_diff` is an
            // incremental change. Tag it so apply() can REPLACE on a snapshot (so a
            // peer that left while we were disconnected doesn't linger) vs MERGE a diff.
            continuation.yield(PresenceDiff(
                joins: action.joins, leaves: action.leaves,
                isSnapshot: action.rawMessage.event == "presence_state"))
        }
        do {
            try await ch.subscribeWithError()
        } catch {
            sub.cancel()
            continuation.finish()
            self.onPeers = nil
            return
        }
        channel = ch
        subscription = sub
        pumpTask = Task { [weak self] in
            for await diff in stream { await self?.apply(diff) }
        }
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

    /// Re-track with an updated focus timer (pause / resume / extend / start), so
    /// a focusing peer's shared timer updates live on the other side (T1b). A
    /// no-op unless we're currently tracking as `.focusing`.
    public func updateTimer(_ timer: CoFocusTimerState?) async {
        self.timer = timer
        guard channel != nil, track == .focusing else { return }
        await applyTrack()
    }

    /// Leave + tear down (untrack, cancel the stream, remove the channel).
    public func stop() async {
        pumpTask?.cancel(); pumpTask = nil
        subscription?.cancel(); subscription = nil
        presences = [:]
        onPeers = nil
        track = nil
        timer = nil
        if let ch = channel {
            await ch.untrack()
            await client.removeChannel(ch)
        }
        channel = nil
    }

    /// Track the current state + (for a focuser) the live timer. Timer fields are
    /// only attached while `.focusing`; a `.here`/observe peer omits them, so the
    /// wire payload matches web + Android field-for-field.
    private func applyTrack() async {
        guard let ch = channel, let track else { return }
        let t = track == .focusing ? timer : nil
        try? await ch.track(TrackPayload(
            userId: selfId, name: selfName, state: track.rawValue, sinceMs: sinceMs,
            sessionStartMs: t?.sessionStartMs, paused: t?.paused,
            pausedAtMs: t?.pausedAtMs, estimateMin: t?.estimateMin))
    }

    private func apply(_ diff: PresenceDiff) {
        if diff.isSnapshot {
            // Full (re)subscribe snapshot: rebuild from scratch so peers that
            // left during a socket drop (whose leave we never saw) don't linger.
            var next: [String: CoFocusMeta] = [:]
            for (key, presence) in diff.joins {
                next[key] = Self.decodeMeta(presence, fallbackKey: key)
            }
            presences = next
        } else {
            // Incremental diff: Phoenix-safe order — LEAVES before JOINS, so a key
            // present in both (a re-track / coalesced change) ends up present, not
            // removed by a stale leave.
            for key in diff.leaves.keys {
                presences.removeValue(forKey: key)
            }
            for (key, presence) in diff.joins {
                presences[key] = Self.decodeMeta(presence, fallbackKey: key)
            }
        }
        onPeers?(coFocusPeers(from: presences, selfId: selfId))
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
}
