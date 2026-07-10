// Share-session signals — the pure transition that fires "start / finish" pings
// to the people you've shared a task with (the View-level promise: "they get
// notified when you start & finish it"). Direct port of the web
// lib/use-share-session-signals.ts `sessionSignalStep` reducer, unit-tested to
// the same cases.
//
// Keyed on the SESSION id, so a genuinely-new session is told apart from a
// mid-session reload — the reloaded session is "adopted" and its start is never
// re-announced (but its end still fires). Shared-status is an input, so if the
// share badges resolve AFTER a session began, the start still fires once they
// load. Pausing is not an edge (sid + startedTask stay set through a pause);
// only a real start, a task switch, or done/cancel move the needle.
//
// The observer that drives this off the live focus session + outgoing badges,
// and invokes share-notify for each fire, lives in the app layer (AppModel).

import Foundation

/// Reducer state (same shape as the web `SigState`).
public struct SigState: Equatable, Sendable {
    /// Have we made our first observation yet? (Before that, we ADOPT.)
    public var inited: Bool
    /// The session alive at first observation (a reload) — its start is never
    /// announced. Remembered so its end can still fire.
    public var adoptedSid: String?
    /// The session id currently tracked.
    public var curSid: String?
    /// The shared taskId we announced a start for (pairs the end).
    public var startedTask: String?

    public init(inited: Bool, adoptedSid: String?, curSid: String?, startedTask: String?) {
        self.inited = inited
        self.adoptedSid = adoptedSid
        self.curSid = curSid
        self.startedTask = startedTask
    }
}

/// The initial (pre-first-observation) state.
public func initSigState() -> SigState {
    SigState(inited: false, adoptedSid: nil, curSid: nil, startedTask: nil)
}

/// A start/finish signal to fire — `kind` is the exact share-notify edge-fn kind.
public enum SigFireKind: String, Sendable, Equatable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
}

public struct SigFire: Equatable, Sendable {
    public let kind: SigFireKind
    public let taskId: String
    public init(kind: SigFireKind, taskId: String) {
        self.kind = kind
        self.taskId = taskId
    }
}

/// Pure transition: given the prior state and the current (session id, shared
/// taskId), return the next state + any start/end signals to fire.
///
/// `sid`    — the live session id (nil = idle). `live.id ?? live.taskId`.
/// `shared` — the taskId iff it has at least one outgoing share, else nil.
public func sessionSignalStep(
    _ s: SigState, sid: String?, shared: String?
) -> (state: SigState, fires: [SigFire]) {
    var fires: [SigFire] = []

    // First observation: adopt the current session without announcing a start (a
    // reload mid-session must not re-fire). Remember it (if shared) for its end.
    if !s.inited {
        return (SigState(inited: true, adoptedSid: sid, curSid: sid, startedTask: shared), fires)
    }

    // Session boundary: end the previous, maybe start the new.
    if sid != s.curSid {
        if let started = s.startedTask { fires.append(SigFire(kind: .sessionEnd, taskId: started)) }
        var startedTask: String?
        if let shared {
            if sid != s.adoptedSid { fires.append(SigFire(kind: .sessionStart, taskId: shared)) }
            startedTask = shared   // track for the future end either way
        }
        var next = s
        next.curSid = sid
        next.startedTask = startedTask
        return (next, fires)
    }

    // Same session continuing — badges may have just resolved.
    if let sid, !sid.isEmpty, s.startedTask == nil, let shared {
        if sid != s.adoptedSid { fires.append(SigFire(kind: .sessionStart, taskId: shared)) }
        var next = s
        next.startedTask = shared
        return (next, fires)
    }

    return (s, fires)
}
