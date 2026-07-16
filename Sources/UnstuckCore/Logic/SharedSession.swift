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
public func canonicalElapsedSec(_ s: SharedSessionState, now: EpochMillis) -> Int {
    let ref = s.paused ? (s.pausedAtMs ?? s.sessionStartMs) : now
    return max(0, Int(((ref - s.sessionStartMs) / 1000).rounded(.down)))
}
