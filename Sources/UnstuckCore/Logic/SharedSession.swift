// One true shared session (partner co-focus v2) — the pure reducer shared by
// all three platforms (docs/shared-session-spec.md). A partner-shared task has
// AT MOST ONE live session, identified by a single `sessionId`; pause / resume /
// extend / finish from either side applies to both. Every `timer` broadcast is
// a FULL-STATE snapshot carrying `(rev, atMs)`; receivers REPLACE their local
// session's shared fields iff the incoming pair is strictly newer (last-writer-
// wins). This file is pure — the transport lives in UnstuckSync's
// CoFocusChannel and the side effects in AppModel+SharedSession.

import Foundation

/// The complete shared state of a live partner session — exactly the `timer`
/// wire payload (minus `userId`). All epoch-ms are WHOLE numbers on the wire
/// (Android's Long decode rejects decimals).
public struct SharedSessionState: Codable, Equatable, Sendable {
    /// The one session id every participant shares (client-minted uuid).
    public var sessionId: String
    /// Epoch-ms; resume-adjusted, so while running elapsed = now − start.
    public var sessionStartMs: Double
    public var paused: Bool
    public var pausedAtMs: Double?
    public var estimateMin: Int
    /// Monotonic control revision — bumped on every LOCAL control broadcast.
    public var rev: Int
    /// Sender wall clock (epoch-ms) at the control — the LWW tiebreak.
    public var atMs: Double
    /// True exactly once, on finish/cancel — ends the session for both sides.
    public var ended: Bool

    public init(sessionId: String, sessionStartMs: Double, paused: Bool,
                pausedAtMs: Double?, estimateMin: Int, rev: Int, atMs: Double, ended: Bool) {
        self.sessionId = sessionId
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
        self.rev = rev
        self.atMs = atMs
        self.ended = ended
    }
}

/// A received `timer` message — every field optional so old-build payloads
/// (no sessionId/rev/atMs/ended) still decode and degrade to display-only.
public struct SharedSessionMsg: Equatable, Sendable {
    public var userId: String?
    public var sessionId: String?
    public var sessionStartMs: Double?
    public var paused: Bool?
    public var pausedAtMs: Double?
    public var estimateMin: Int?
    public var rev: Int?
    public var atMs: Double?
    public var ended: Bool?

    public init(userId: String? = nil, sessionId: String? = nil, sessionStartMs: Double? = nil,
                paused: Bool? = nil, pausedAtMs: Double? = nil, estimateMin: Int? = nil,
                rev: Int? = nil, atMs: Double? = nil, ended: Bool? = nil) {
        self.userId = userId
        self.sessionId = sessionId
        self.sessionStartMs = sessionStartMs
        self.paused = paused
        self.pausedAtMs = pausedAtMs
        self.estimateMin = estimateMin
        self.rev = rev
        self.atMs = atMs
        self.ended = ended
    }

    /// The full shared state, when the message carries the required NEW fields
    /// (a message without a — or with an EMPTY — `sessionId` is not
    /// controllable: view-only, never adopt/control from it). A missing/zero
    /// `estimateMin` floors to 25 so an adopted session never renders a 0-min
    /// ring or caps its accrual at the grace window alone.
    public var state: SharedSessionState? {
        guard let sessionId, !sessionId.isEmpty, let sessionStartMs else { return nil }
        let estimate = estimateMin.flatMap { $0 > 0 ? $0 : nil } ?? 25
        return SharedSessionState(
            sessionId: sessionId, sessionStartMs: sessionStartMs,
            paused: paused ?? false, pausedAtMs: pausedAtMs,
            estimateMin: estimate, rev: rev ?? 0, atMs: atMs ?? 0,
            ended: ended ?? false)
    }
}

/// How long a broadcast session stays adoptable — guards a stale broadcast
/// from a dead client (mirrors the server-side 12h clamp, migration 047).
public let sharedSessionMaxAgeMs: Double = 12 * 3_600_000

/// Clock-skew tolerance for adoption: a partner whose wall clock runs a few
/// seconds AHEAD broadcasts a `sessionStartMs` in our future — rejecting it
/// would mint a second session (split-brain + double accrual). 2 minutes.
public let sharedSessionMaxSkewMs: Double = 120_000

/// A message is adoptable iff it identifies a session (a non-empty
/// `sessionId`), the session hasn't ended, and its start is sane:
/// `-2min <= now − start < 12h` (the lower bound tolerates partner clock
/// skew; adopters clamp the start to `now` for local display).
public func sharedSessionAdoptable(_ msg: SharedSessionMsg, now: EpochMillis) -> Bool {
    guard let sid = msg.sessionId, !sid.isEmpty, msg.ended != true,
          let start = msg.sessionStartMs else { return false }
    let age = now - start
    return age >= -sharedSessionMaxSkewMs && age < sharedSessionMaxAgeMs
}

/// `(rev, atMs)` strict ordering — rev first, sender wall clock as tiebreak.
public func sharedSessionNewer(rev: Int, atMs: Double, thanRev: Int, thanAtMs: Double) -> Bool {
    if rev != thanRev { return rev > thanRev }
    return atMs > thanAtMs
}

/// Apply-iff-newer LWW: apply `incoming` to the local shared state iff it
/// carries the new fields (`state != nil`), targets the SAME session, the local
/// session hasn't already ended, and `(rev, atMs)` is strictly newer than the
/// local pair. On apply the local state is REPLACED wholesale (full-state
/// snapshots, spec §Decisions 1); local-only fields (treatment, prior
/// accumulated seconds, shared markers, nudge flags) live outside this struct.
///
/// `ended` is TERMINAL: an incoming finish/cancel applies whenever it targets
/// the same (not-locally-ended) session, BYPASSING the `(rev, atMs)` check —
/// a racing local control (same/higher rev) must never resurrect a session
/// the partner already ended.
public func sharedSessionStep(
    local: SharedSessionState, incoming: SharedSessionMsg
) -> (apply: Bool, next: SharedSessionState) {
    guard let inc = incoming.state,
          inc.sessionId == local.sessionId,
          !local.ended
    else { return (false, local) }
    if inc.ended { return (true, inc) }
    guard sharedSessionNewer(rev: inc.rev, atMs: inc.atMs, thanRev: local.rev, thanAtMs: local.atMs)
    else { return (false, local) }
    return (true, inc)
}

/// Elapsed seconds derived from the SHARED timestamps — both sides compute the
/// identical number (up to clock skew), so whichever finalize wins the
/// exactly-once ledger writes ~the same accrual. For an `ended` state pass the
/// sender's `atMs` as `now` so the number freezes at the ender's clock.
/// A paused state MISSING its `pausedAtMs` falls back to `now` (web/Android
/// parity): the pause instant is unknown, and freezing at the start would
/// zero the elapsed — under-counting accrual and mis-ranking the most-ahead
/// comparison.
public func canonicalElapsedSec(_ s: SharedSessionState, now: EpochMillis) -> Int {
    let ref = s.paused ? (s.pausedAtMs ?? now) : now
    return max(0, Int(((ref - s.sessionStartMs) / 1000).rounded(.down)))
}

// MARK: - Offline divergence (spec §Offline & reconnect convergence)

/// Elapsed-comparison slack for the most-ahead convergence rule: two clocks
/// within ~3s of each other are "the same clock up to skew/latency" — they
/// fall back to plain (rev, atMs) LWW instead of the elapsed comparison.
public let sharedSessionDivergenceSlackMs: Double = 3000

/// The outcome of `resolveDivergence` — how a DIVERGED client reconciles its
/// local session with a same-session state received after reconnecting.
public enum SharedSessionDivergenceResolution: Equatable, Sendable {
    /// The incoming clock is ahead: adopt the incoming state WHOLESALE and
    /// clear the diverged flag.
    case adopt
    /// The local clock is ahead: keep it, clear the diverged flag, and
    /// broadcast the local state as a GENUINE convergence control at `rev` —
    /// `max(local.rev, incoming.rev) + 1` — which the partner applies via
    /// normal LWW (no special logic needed on the online side).
    case keepAndBroadcast(rev: Int)
    /// Within slack — the clocks agree; fall back to plain (rev, atMs) LWW.
    case lww
}

/// Most-ahead convergence for a DIVERGED client (one that made controls it
/// couldn't deliver — offline pause/resume/extend). On receiving a state for
/// the SAME session, compare `canonicalElapsedSec` of both sides at the
/// RECEIVER's clock (`now`), with `sharedSessionDivergenceSlackMs` slack:
/// whichever clock is further ahead wins (tester criteria 3–4: "on regaining
/// internet I get the timer that's THE MOST AHEAD" — both sides converge on
/// it). This comparison applies ONLY while diverged: non-diverged clients keep
/// plain LWW, so a stale running re-announce can never un-pause a live pause.
///
/// `ended` stays terminal throughout — callers pre-filter an incoming `ended`
/// into the normal terminal step; defensively, an ended incoming resolves to
/// `.lww` here (web/Android parity — the STEP reducer owns ended-terminality
/// and applies it bypassing the (rev, atMs) gate; the elapsed comparison never
/// enters).
public func resolveDivergence(
    local: SharedSessionState, incoming: SharedSessionState, now: EpochMillis
) -> SharedSessionDivergenceResolution {
    if incoming.ended { return .lww }
    let deltaMs = Double(canonicalElapsedSec(incoming, now: now)
                         - canonicalElapsedSec(local, now: now)) * 1000
    if deltaMs > sharedSessionDivergenceSlackMs { return .adopt }
    if deltaMs < -sharedSessionDivergenceSlackMs {
        return .keepAndBroadcast(rev: max(local.rev, incoming.rev) + 1)
    }
    return .lww
}
