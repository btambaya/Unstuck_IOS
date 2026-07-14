// Co-focus presence — the pure "who's here with me" reduction for a partner-
// shared task, the port of lib/cofocus-presence.ts's `recompute`. The networked
// transport (Supabase Realtime Presence) lives in UnstuckSync's CoFocusChannel,
// which decodes each raw presence into a `CoFocusMeta` and calls this to build
// the list of OTHER peers. Kept pure here so it's unit-tested without realtime.

import Foundation

/// How a participant appears to others on the channel.
///   focusing — in a focus session on this task (owner side).
///   here     — sitting with them / body-doubling (recipient "Sit with them").
/// (nil track = observe only — you see peers but don't broadcast yourself.)
public enum CoFocusState: String, Codable, Sendable, Equatable {
    case focusing
    case here
}

/// A resolved OTHER participant on a co-focus channel (never yourself).
public struct CoFocusPeer: Equatable, Sendable, Identifiable {
    public var userId: String
    public var name: String
    public var state: CoFocusState
    /// Epoch-ms this peer joined (for "longest-present" ordering).
    public var sinceMs: Double
    // --- Live focus-session timer, carried ONLY when the peer is focusing
    // (T1b "shared view"). These let a partner render the same running/paused
    // timer the focuser sees — a calm shared indicator, not remote control.
    /// Epoch-ms the peer's focus session started (resume-adjusted, so while
    /// running: elapsed = now − sessionStartMs). nil for a non-focusing peer.
    public var sessionStartMs: Double?
    /// Whether the peer's focus session is currently paused.
    public var paused: Bool
    /// Epoch-ms the peer paused at (freezes elapsed at pausedAtMs − sessionStartMs).
    public var pausedAtMs: Double?
    /// The peer's session estimate in minutes (for the "N left" countdown).
    public var estimateMin: Int?

    public var id: String { userId }

    public init(userId: String, name: String, state: CoFocusState, sinceMs: Double,
                sessionStartMs: Double? = nil, paused: Bool = false,
                pausedAtMs: Double? = nil, estimateMin: Int? = nil) {
        self.userId = userId
        self.name = name
        self.state = state
        self.sinceMs = sinceMs
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
    }
}

/// The broadcastable timer state of the LOCAL focus session — what a focuser
/// tracks onto the presence channel so peers can render the shared timer (T1b).
/// Built from the live session (sessionStart / paused / pausedAt / estimate).
public struct CoFocusTimerState: Equatable, Sendable {
    public var sessionStartMs: Double
    public var paused: Bool
    public var pausedAtMs: Double?
    public var estimateMin: Int

    public init(sessionStartMs: Double, paused: Bool, pausedAtMs: Double?, estimateMin: Int) {
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
    }
}

/// The elapsed/remaining derivation for a focusing peer's shared timer (T1b) —
/// the pure computation both sides (owner CoFocusBar + recipient PartnerPresence)
/// and every platform share. Identical to the focuser's own FocusTimer.elapsedSec:
///   elapsed = paused ? (pausedAtMs − sessionStartMs) : (now − sessionStartMs)
///   remaining = estimateMin*60 − elapsed  (clamped ≥ 0)
/// Returns nil unless the peer is focusing AND carries a sessionStartMs.
public struct CoFocusPeerTimer: Equatable, Sendable {
    public var elapsedSec: Int
    public var remainingSec: Int
    public var paused: Bool
    public init(elapsedSec: Int, remainingSec: Int, paused: Bool) {
        self.elapsedSec = elapsedSec
        self.remainingSec = remainingSec
        self.paused = paused
    }
}

public func coFocusPeerTimer(_ peer: CoFocusPeer, now: EpochMillis) -> CoFocusPeerTimer? {
    guard peer.state == .focusing, let start = peer.sessionStartMs else { return nil }
    let elapsedMs = peer.paused ? ((peer.pausedAtMs ?? start) - start) : (now - start)
    let elapsedSec = max(0, Int((elapsedMs / 1000).rounded(.down)))
    let estimateSec = max(0, peer.estimateMin ?? 0) * 60
    let remainingSec = max(0, estimateSec - elapsedSec)
    return CoFocusPeerTimer(elapsedSec: elapsedSec, remainingSec: remainingSec, paused: peer.paused)
}

/// A decoded presence payload (all fields optional — a peer may broadcast a
/// partial/absent state, and you can even receive your own presence w/o state).
public struct CoFocusMeta: Equatable, Sendable {
    public var userId: String?
    public var name: String?
    public var state: CoFocusState?
    public var sinceMs: Double?
    /// Live focus-session timer fields (T1b), present only for a focusing peer.
    public var sessionStartMs: Double?
    public var paused: Bool?
    public var pausedAtMs: Double?
    public var estimateMin: Int?

    public init(userId: String? = nil, name: String? = nil, state: CoFocusState? = nil, sinceMs: Double? = nil,
                sessionStartMs: Double? = nil, paused: Bool? = nil, pausedAtMs: Double? = nil, estimateMin: Int? = nil) {
        self.userId = userId
        self.name = name
        self.state = state
        self.sinceMs = sinceMs
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
    }
}

/// Build the OTHER peers from the accumulated presence map (keyed by presence
/// key == user id), excluding yourself. Focusing peers first, then longest-
/// present — 1:1 with the web `recompute` sort. An unknown/absent state
/// normalises to `.here` (matches the web `m.state === 'focusing' ? … : 'here'`).
public func coFocusPeers(from presences: [String: CoFocusMeta], selfId: String) -> [CoFocusPeer] {
    var out: [CoFocusPeer] = []
    for (key, m) in presences {
        if key == selfId { continue }
        let focusing = m.state == .focusing
        out.append(CoFocusPeer(
            userId: m.userId ?? key,
            name: m.name ?? "Someone",
            state: focusing ? .focusing : .here,
            sinceMs: m.sinceMs ?? 0,
            // Carry the timer only for a focusing peer (a `here` peer never
            // broadcasts a session), so `coFocusPeerTimer` stays a clean gate.
            sessionStartMs: focusing ? m.sessionStartMs : nil,
            paused: focusing ? (m.paused ?? false) : false,
            pausedAtMs: focusing ? m.pausedAtMs : nil,
            estimateMin: focusing ? m.estimateMin : nil))
    }
    // Focusing peers first, then by longest-present (earliest sinceMs). Stable
    // final key on userId so equal peers order deterministically.
    out.sort { a, b in
        if a.state != b.state { return a.state == .focusing }
        if a.sinceMs != b.sinceMs { return a.sinceMs < b.sinceMs }
        return a.userId < b.userId
    }
    return out
}
