// FocusTimer — the pure core of the live-session state machine. Port of
// the testable logic in lib/use-focus-timer.ts. The React/SwiftUI layer
// owns the ticking clock, persistence (LIVE_SESSION), sound, and the
// transient forced "done" state; everything here is a pure function of a
// `LiveSession` + an injected `now` (epoch ms), so it's deterministic
// and unit-testable exactly like the web hook's assertions.

import Foundation

public enum FocusTimer {

    /// The empty / idle live session (mirrors the web EMPTY default).
    public static let empty = LiveSession(
        id: nil, taskId: "", sessionStart: nil, paused: false, pausedAt: nil,
        sessionEstimateMin: 25, nudge80Fired: false, overrunPromptFired: false,
        treatment: .ambient, priorAccumulatedSec: 0)

    // MARK: Derivations

    public static func estimateSec(_ live: LiveSession) -> Int {
        (live.sessionEstimateMin != 0 ? live.sessionEstimateMin : 25) * 60
    }

    /// Seconds of THIS session (excludes priorAccumulatedSec). This is
    /// the value written to the Session row's actualSec.
    public static func elapsedSec(_ live: LiveSession, now: EpochMillis) -> Int {
        guard let start = live.sessionStart else { return 0 }
        let elapsedMs: Double
        if live.paused, let pausedAt = live.pausedAt {
            elapsedMs = pausedAt - start
        } else {
            elapsedMs = now - start
        }
        return max(0, Int((elapsedMs / 1000).rounded(.down)))
    }

    /// Seconds the UI displays: session elapsed + prior task progress.
    public static func displayedElapsedSec(_ live: LiveSession, now: EpochMillis) -> Int {
        elapsedSec(live, now: now) + (live.priorAccumulatedSec ?? 0)
    }

    /// `overrunGraceSec` is seconds, or `.infinity` to never escalate.
    public static func deriveState(_ live: LiveSession, now: EpochMillis, overrunGraceSec: Double) -> FocusState {
        guard live.sessionStart != nil else { return .idle }
        if live.paused { return .pause }
        if overrunGraceSec == .infinity { return .running }
        let disp = Double(displayedElapsedSec(live, now: now))
        if disp >= Double(estimateSec(live)) + overrunGraceSec { return .overrun }
        return .running
    }

    /// Map the PREF_FOCUS_OVERRUN string to grace seconds.
    /// nil/unknown → 1; "Never" → ∞; "5 min" → 300; "10 min" → 600.
    public static func overrunGraceSeconds(pref: String?) -> Double {
        guard let pref, !pref.isEmpty else { return 1 }
        switch pref {
        case "Never": return .infinity
        case "5 min": return 5 * 60
        case "10 min": return 10 * 60
        default: return 1
        }
    }

    // MARK: Transitions (pure: current live → next live)

    /// Resume-aware start (the Save-for-later flow):
    /// - same task + paused → resume (shift sessionStart by the pause gap)
    /// - same task + running → no-op (don't reset on a double Start)
    /// - otherwise → fresh session seeded with `priorAccumulatedSec`
    public static func start(
        _ cur: LiveSession,
        taskId: String,
        estimateMin: Int? = nil,
        priorAccumulatedSec: Int? = nil,
        now: EpochMillis,
        occurrenceBlockId: String? = nil,
        newId: () -> String = newUUID
    ) -> LiveSession {
        // Re-entering the SAME occurrence (same template + same day's block) keeps
        // its state; a different occurrence of the same template starts fresh.
        if cur.sessionStart != nil, cur.taskId == taskId,
           cur.occurrenceBlockId == occurrenceBlockId, cur.paused {
            return resume(cur, now: now)
        }
        if cur.sessionStart != nil, cur.taskId == taskId,
           cur.occurrenceBlockId == occurrenceBlockId, !cur.paused {
            return cur
        }
        var next = cur
        next.id = newId()
        next.taskId = taskId
        next.sessionStart = now
        next.paused = false
        next.pausedAt = nil
        next.sessionEstimateMin = estimateMin ?? 25
        next.nudge80Fired = false
        next.overrunPromptFired = false
        next.priorAccumulatedSec = priorAccumulatedSec ?? 0
        next.occurrenceBlockId = occurrenceBlockId
        // A fresh session for a different task must not inherit a prior session's
        // shared marker; the caller (FocusModel) re-sets it for a shared focus.
        next.sharedFocusLevel = nil
        // Nor the previous session's shared-control bookkeeping — a fresh MINT
        // starts the rev chain over (one true shared session).
        next.sharedSessionRev = nil
        next.sharedSessionAtMs = nil
        next.lastAppliedRev = nil
        next.lastAppliedAtMs = nil
        next.divergedOffline = nil
        next.sharedSessionEndedBy = nil
        return next
    }

    /// ADOPT an in-flight shared session from the co-focus channel — the JOIN
    /// half of join-or-mint (one true shared session). Bypasses the mint: the
    /// id / start / paused / pausedAt / estimate come from the broadcast state,
    /// so the focus screen opens mid-clock on the same session the partner is
    /// running. Keeps the current treatment; the caller re-stamps
    /// sharedFocusLevel + priorAccumulatedSec (and occurrenceBlockId).
    /// `lastAppliedRev/AtMs` are seeded from the adopted state so the LWW floor
    /// starts where the wire left off, and the next local control broadcasts
    /// `rev + 1`. A partner clock running AHEAD can post a start in our future
    /// (adoptable within the 2-min skew window) — clamp it to `now` for local
    /// display so elapsed never renders negative.
    public static func adopt(
        _ cur: LiveSession,
        taskId: String,
        state: SharedSessionState,
        priorAccumulatedSec: Int? = nil,
        now: EpochMillis,
        occurrenceBlockId: String? = nil
    ) -> LiveSession {
        var next = cur
        next.id = state.sessionId
        next.taskId = taskId
        next.sessionStart = min(state.sessionStartMs, now)
        next.paused = state.paused
        next.pausedAt = state.pausedAtMs
        next.sessionEstimateMin = state.estimateMin
        next.nudge80Fired = false
        next.overrunPromptFired = false
        next.priorAccumulatedSec = priorAccumulatedSec ?? 0
        next.occurrenceBlockId = occurrenceBlockId
        next.sharedFocusLevel = nil
        next.sharedSessionRev = state.rev
        next.sharedSessionAtMs = nil
        next.lastAppliedRev = state.rev
        next.lastAppliedAtMs = state.atMs
        next.divergedOffline = nil
        next.sharedSessionEndedBy = nil
        return next
    }

    public static func pause(_ cur: LiveSession, now: EpochMillis) -> LiveSession {
        guard cur.sessionStart != nil else { return cur }
        var next = cur
        next.paused = true
        next.pausedAt = now
        return next
    }

    public static func resume(_ cur: LiveSession, now: EpochMillis) -> LiveSession {
        guard let start = cur.sessionStart else { return cur }
        let pausedDuration = cur.pausedAt != nil ? now - cur.pausedAt! : 0
        var next = cur
        next.paused = false
        next.pausedAt = nil
        next.sessionStart = start + pausedDuration
        return next
    }

    /// Ends the session: clears sessionStart so elapsed resets to 0 (the
    /// Session-row writeback already happened with the pre-done elapsed).
    /// The UI separately forces a transient `.done` display state.
    public static func done(_ cur: LiveSession) -> LiveSession {
        var next = cur
        next.id = nil
        next.sessionStart = nil
        next.paused = false
        next.pausedAt = nil
        return next
    }

    public static func cancel(_ cur: LiveSession) -> LiveSession {
        var next = empty
        next.treatment = cur.treatment
        return next
    }

    public static func extend(_ cur: LiveSession, minutes: Int) -> LiveSession {
        var next = cur
        next.sessionEstimateMin = cur.sessionEstimateMin + minutes
        next.overrunPromptFired = false
        return next
    }

    public static func setTreatment(_ cur: LiveSession, _ t: FocusTreatment) -> LiveSession {
        var next = cur
        next.treatment = t
        return next
    }
}

public extension LiveSession {
    /// The idle/empty live session. Lets call sites use leading-dot
    /// syntax (`.empty`) where a `LiveSession` is expected.
    static var empty: LiveSession { FocusTimer.empty }
}

/// Seconds as MM:SS (or -MM:SS for negatives). Port of `formatMMSS`.
public func formatMMSS(_ sec: Int) -> String {
    let sign = sec < 0 ? "-" : ""
    let abs = Swift.abs(sec)
    return "\(sign)\(String(format: "%02d", abs / 60)):\(String(format: "%02d", abs % 60))"
}
