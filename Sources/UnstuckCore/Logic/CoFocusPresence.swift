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

    public var id: String { userId }

    public init(userId: String, name: String, state: CoFocusState, sinceMs: Double) {
        self.userId = userId
        self.name = name
        self.state = state
        self.sinceMs = sinceMs
    }
}

/// A decoded presence payload (all fields optional — a peer may broadcast a
/// partial/absent state, and you can even receive your own presence w/o state).
public struct CoFocusMeta: Equatable, Sendable {
    public var userId: String?
    public var name: String?
    public var state: CoFocusState?
    public var sinceMs: Double?

    public init(userId: String? = nil, name: String? = nil, state: CoFocusState? = nil, sinceMs: Double? = nil) {
        self.userId = userId
        self.name = name
        self.state = state
        self.sinceMs = sinceMs
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
        out.append(CoFocusPeer(
            userId: m.userId ?? key,
            name: m.name ?? "Someone",
            state: m.state == .focusing ? .focusing : .here,
            sinceMs: m.sinceMs ?? 0))
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
