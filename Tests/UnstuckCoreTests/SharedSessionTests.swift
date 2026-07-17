// One true shared session — unit tests for the pure reducer
// (docs/shared-session-spec.md). Mirrors the spec's semantics 1:1 so the
// web / Android ports can assert the identical cases.

import XCTest
@testable import UnstuckCore

private let T0 = Time.parseMillis("2026-07-16T10:00:00.000Z")!

private func state(
    id: String = "s1", start: Double = T0, paused: Bool = false,
    pausedAt: Double? = nil, estimate: Int = 25, rev: Int = 1,
    at: Double = T0, ended: Bool = false
) -> SharedSessionState {
    SharedSessionState(sessionId: id, sessionStartMs: start, paused: paused,
                       pausedAtMs: pausedAt, estimateMin: estimate, rev: rev,
                       atMs: at, ended: ended)
}

private func msg(
    id: String? = "s1", start: Double? = T0, paused: Bool? = false,
    pausedAt: Double? = nil, estimate: Int? = 25, rev: Int? = 1,
    at: Double? = T0, ended: Bool? = false, userId: String? = "u2"
) -> SharedSessionMsg {
    SharedSessionMsg(userId: userId, sessionId: id, sessionStartMs: start,
                     paused: paused, pausedAtMs: pausedAt, estimateMin: estimate,
                     rev: rev, atMs: at, ended: ended)
}

// MARK: - adoptable

final class SharedSessionAdoptableTests: XCTestCase {
    func testAdoptableWhenLiveAndSane() {
        XCTAssertTrue(sharedSessionAdoptable(msg(start: T0), now: T0 + 5 * 60_000))
    }

    func testNotAdoptableWithoutSessionId() {
        // Old-build broadcast (no sessionId) → display-only, never adopted.
        XCTAssertFalse(sharedSessionAdoptable(msg(id: nil), now: T0 + 1000))
    }

    func testNotAdoptableWithEmptySessionId() {
        // An EMPTY id identifies nothing — adopting it would mint a session
        // keyed to "" that no partner control could ever match.
        XCTAssertFalse(sharedSessionAdoptable(msg(id: ""), now: T0 + 1000))
    }

    func testNotAdoptableWhenEnded() {
        XCTAssertFalse(sharedSessionAdoptable(msg(ended: true), now: T0 + 1000))
    }

    func testNotAdoptableWithoutStart() {
        XCTAssertFalse(sharedSessionAdoptable(msg(start: nil), now: T0 + 1000))
    }

    func testAdoptableWithinClockSkewWindow() {
        // A partner clock a few seconds AHEAD posts a start in our future —
        // still adoptable (± 2 min skew), else a second session gets minted
        // (split-brain + double accrual). The adopter clamps for display.
        XCTAssertTrue(sharedSessionAdoptable(msg(start: T0 + 10_000), now: T0))
        XCTAssertTrue(sharedSessionAdoptable(msg(start: T0 + 120_000), now: T0))
    }

    func testNotAdoptableBeyondClockSkewWindow() {
        // More than 2 min in the future is not skew — it's a bogus broadcast.
        XCTAssertFalse(sharedSessionAdoptable(msg(start: T0 + 120_001), now: T0))
    }

    func testNotAdoptableWhenOlderThan12h() {
        // Guards a stale broadcast from a dead client (12h, exclusive).
        XCTAssertFalse(sharedSessionAdoptable(msg(start: T0), now: T0 + 12 * 3_600_000))
        XCTAssertTrue(sharedSessionAdoptable(msg(start: T0), now: T0 + 12 * 3_600_000 - 1))
    }

    func testAdoptableAtZeroAge() {
        XCTAssertTrue(sharedSessionAdoptable(msg(start: T0), now: T0))
    }
}

// MARK: - SharedSessionMsg.state (wire tolerance)

final class SharedSessionMsgStateTests: XCTestCase {
    func testStateNilForEmptySessionId() {
        // An empty sessionId is as uncontrollable as a missing one.
        XCTAssertNil(msg(id: "").state)
        XCTAssertNil(msg(id: nil).state)
    }

    func testEstimateFloorsTo25WhenZeroOrAbsent() {
        // A 0/absent estimate would render a 0-min ring and cap accrual at the
        // grace window alone — floor it to the canonical 25.
        XCTAssertEqual(msg(estimate: 0).state?.estimateMin, 25)
        XCTAssertEqual(msg(estimate: nil).state?.estimateMin, 25)
        XCTAssertEqual(msg(estimate: -5).state?.estimateMin, 25)
        XCTAssertEqual(msg(estimate: 40).state?.estimateMin, 40)
    }
}

// MARK: - sharedSessionStep (apply-iff-newer LWW)

final class SharedSessionStepTests: XCTestCase {
    func testAppliesStrictlyNewerRev() {
        let local = state(rev: 2, at: T0)
        let incoming = msg(paused: true, pausedAt: T0 + 60_000, rev: 3, at: T0 + 60_000)
        let (apply, next) = sharedSessionStep(local: local, incoming: incoming)
        XCTAssertTrue(apply)
        // Full-state REPLACE: every shared field comes from the wire.
        XCTAssertEqual(next, incoming.state)
        XCTAssertTrue(next.paused)
        XCTAssertEqual(next.pausedAtMs, T0 + 60_000)
        XCTAssertEqual(next.rev, 3)
    }

    func testSameRevNewerAtMsWins() {
        // Concurrent controls at the same rev — sender wall clock breaks the tie.
        let local = state(rev: 3, at: T0 + 1000)
        let (apply, next) = sharedSessionStep(local: local, incoming: msg(estimate: 35, rev: 3, at: T0 + 2000))
        XCTAssertTrue(apply)
        XCTAssertEqual(next.estimateMin, 35)
    }

    func testSameRevSameAtMsDoesNotApply() {
        let local = state(rev: 3, at: T0)
        let (apply, next) = sharedSessionStep(local: local, incoming: msg(rev: 3, at: T0))
        XCTAssertFalse(apply)
        XCTAssertEqual(next, local)
    }

    func testOlderRevDoesNotApplyEvenWithNewerAtMs() {
        // rev dominates; atMs is only the tiebreak.
        let local = state(rev: 4, at: T0)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(rev: 3, at: T0 + 99_000))
        XCTAssertFalse(apply)
    }

    func testDifferentSessionIdDoesNotApply() {
        let local = state(id: "s1", rev: 1, at: T0)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(id: "OTHER", rev: 9, at: T0 + 9000))
        XCTAssertFalse(apply)
    }

    func testLocallyEndedSessionRejectsEverything() {
        let local = state(rev: 1, at: T0, ended: true)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(rev: 9, at: T0 + 9000))
        XCTAssertFalse(apply)
    }

    func testOldBuildMessageWithoutSessionIdDoesNotApply() {
        // A `timer` without the new fields is display-only (backward compat).
        let local = state(rev: 1, at: T0)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(id: nil, rev: 9, at: T0 + 9000))
        XCTAssertFalse(apply)
    }

    func testEndedControlApplies() {
        // finish/cancel from the other side.
        let local = state(rev: 2, at: T0)
        let (apply, next) = sharedSessionStep(local: local, incoming: msg(rev: 3, at: T0 + 5000, ended: true))
        XCTAssertTrue(apply)
        XCTAssertTrue(next.ended)
    }

    func testEndedIsTerminalBypassesLWW() {
        // `ended` applies even with an OLDER (rev, atMs): a racing local
        // control must never resurrect a session the partner already ended.
        let local = state(rev: 5, at: T0 + 60_000)
        let (apply, next) = sharedSessionStep(local: local, incoming: msg(rev: 3, at: T0 + 1000, ended: true))
        XCTAssertTrue(apply)
        XCTAssertTrue(next.ended)
    }

    func testEndedSameRevSameAtMsStillApplies() {
        let local = state(rev: 3, at: T0)
        let (apply, next) = sharedSessionStep(local: local, incoming: msg(rev: 3, at: T0, ended: true))
        XCTAssertTrue(apply)
        XCTAssertTrue(next.ended)
    }

    func testEndedForDifferentSessionDoesNotApply() {
        // Terminal, but still session-scoped.
        let local = state(id: "s1", rev: 1, at: T0)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(id: "OTHER", rev: 9, at: T0 + 9000, ended: true))
        XCTAssertFalse(apply)
    }

    func testEndedOnLocallyEndedSessionDoesNotReapply() {
        let local = state(rev: 1, at: T0, ended: true)
        let (apply, _) = sharedSessionStep(local: local, incoming: msg(rev: 2, at: T0 + 1000, ended: true))
        XCTAssertFalse(apply)
    }

    func testResumeShiftIsAppliedNotRecomputed() {
        // Peers never recompute the resume shift — they REPLACE sessionStart
        // with the sender's posted (already-shifted) value.
        let local = state(start: T0, paused: true, pausedAt: T0 + 60_000, rev: 2, at: T0 + 60_000)
        let shifted = T0 + 30_000   // the sender's resume-adjusted start
        let (apply, next) = sharedSessionStep(
            local: local, incoming: msg(start: shifted, paused: false, pausedAt: nil, rev: 3, at: T0 + 90_000))
        XCTAssertTrue(apply)
        XCTAssertEqual(next.sessionStartMs, shifted)
        XCTAssertFalse(next.paused)
        XCTAssertNil(next.pausedAtMs)
    }
}

// MARK: - canonicalElapsedSec

final class CanonicalElapsedTests: XCTestCase {
    func testRunningElapsedIsNowMinusStart() {
        XCTAssertEqual(canonicalElapsedSec(state(start: T0), now: T0 + 125_000), 125)
    }

    func testPausedElapsedFreezesAtPausedAt() {
        let s = state(start: T0, paused: true, pausedAt: T0 + 90_000)
        XCTAssertEqual(canonicalElapsedSec(s, now: T0 + 999_000), 90)
    }

    func testPausedWithoutPausedAtFallsBackToNow() {
        // Web/Android parity: a paused state MISSING pausedAt uses `now` (the
        // pause instant is unknown; freezing at the start would zero the
        // elapsed — under-counting accrual and mis-ranking most-ahead).
        let s = state(start: T0, paused: true, pausedAt: nil)
        XCTAssertEqual(canonicalElapsedSec(s, now: T0 + 999_000), 999)
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(canonicalElapsedSec(state(start: T0 + 5000), now: T0), 0)
    }

    func testFloorsFractionalSeconds() {
        XCTAssertEqual(canonicalElapsedSec(state(start: T0), now: T0 + 1999), 1)
    }

    func testEndedStateFreezesAtSendersClock() {
        // Both sides pass the ender's atMs as `now` → identical accrual numbers.
        let s = state(start: T0, rev: 4, at: T0 + 300_000, ended: true)
        XCTAssertEqual(canonicalElapsedSec(s, now: s.atMs), 300)
    }
}

// MARK: - resolveDivergence (offline & reconnect convergence)

final class ResolveDivergenceTests: XCTestCase {
    // Tracker criterion 1 (+3): lose internet, DON'T pause → the local timer
    // ran on wall clock; a stale (behind) partner re-announce on reconnect
    // must NOT rewind it — keep local + broadcast the convergence control.
    func testLocalRanAheadOfflineKeepsAndBroadcasts() {
        let now = T0 + 100_000
        let local = state(start: T0, rev: 7, at: T0 + 90_000)          // elapsed 100
        let incoming = state(start: T0 + 10_000, rev: 4, at: T0)       // elapsed 90
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now),
                       .keepAndBroadcast(rev: 8))
    }

    // Tracker criterion 2 (+3): lose internet and PAUSE → it paused locally;
    // on reconnect the partner's still-running clock is the most ahead → adopt
    // it wholesale (un-pausing onto THE session clock).
    func testPartnerRanAheadOfLocalOfflinePauseAdopts() {
        let now = T0 + 100_000
        let local = state(start: T0, paused: true, pausedAt: T0 + 50_000,
                          rev: 6, at: T0 + 50_000)                     // frozen at 50
        let incoming = state(start: T0, rev: 4, at: T0)                // elapsed 100
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now), .adopt)
    }

    // Tracker criterion 3: on regaining internet the MOST-AHEAD clock wins —
    // an incoming paused-but-ahead state also beats a behind local.
    func testIncomingPausedButAheadAdopts() {
        let now = T0 + 100_000
        let local = state(start: T0 + 40_000, rev: 9, at: now)                       // elapsed 60
        let incoming = state(start: T0, paused: true, pausedAt: T0 + 80_000,
                             rev: 2, at: T0 + 80_000)                                // frozen at 80
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now), .adopt)
    }

    // Tracker criterion 4: the online partner needs NO special logic — the
    // convergence control broadcast at max(local, incoming)+1 applies through
    // its plain LWW reducer.
    func testConvergenceBroadcastAppliesOnThePartnerViaPlainLWW() {
        let now = T0 + 100_000
        let local = state(start: T0, rev: 7, at: T0 + 90_000)
        let partnerView = state(start: T0 + 10_000, rev: 4, at: T0)
        guard case .keepAndBroadcast(let rev) =
                resolveDivergence(local: local, incoming: partnerView, now: now) else {
            return XCTFail("expected keepAndBroadcast")
        }
        XCTAssertEqual(rev, 8)   // strictly newer than BOTH sides' floors
        let convergence = msg(start: T0, rev: rev, at: now)
        let (apply, next) = sharedSessionStep(local: partnerView, incoming: convergence)
        XCTAssertTrue(apply)
        XCTAssertEqual(next.sessionStartMs, T0)   // the most-ahead clock, both sides
    }

    func testRevIsMaxOfBothSidesPlusOne() {
        let now = T0 + 100_000
        // Incoming rev HIGHER than local: the convergence control must still
        // beat it — max of both, plus one.
        let local = state(start: T0, rev: 2, at: T0)                   // elapsed 100
        let incoming = state(start: T0 + 20_000, rev: 9, at: now)      // elapsed 80
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now),
                       .keepAndBroadcast(rev: 10))
    }

    // Slack boundary (~3s = 3000 ms): a difference of EXACTLY the slack is
    // "the same clock up to skew" → plain LWW; one second beyond converges.
    func testSlackBoundary() {
        let now = T0 + 100_000
        let local = state(start: T0, rev: 5, at: T0)                   // elapsed 100
        XCTAssertEqual(resolveDivergence(
            local: local, incoming: state(start: T0 - 3000, rev: 4, at: T0), now: now), .lww)
        XCTAssertEqual(resolveDivergence(
            local: local, incoming: state(start: T0 - 4000, rev: 4, at: T0), now: now), .adopt)
        XCTAssertEqual(resolveDivergence(
            local: local, incoming: state(start: T0 + 3000, rev: 4, at: T0), now: now), .lww)
        XCTAssertEqual(resolveDivergence(
            local: local, incoming: state(start: T0 + 4000, rev: 4, at: T0), now: now),
            .keepAndBroadcast(rev: 6))
    }

    func testIdenticalClocksFallBackToLWW() {
        let now = T0 + 100_000
        let local = state(start: T0, rev: 5, at: T0)
        XCTAssertEqual(resolveDivergence(
            local: local, incoming: state(start: T0, rev: 6, at: T0 + 1000), now: now), .lww)
    }

    func testEndedIncomingFallsBackToLWW() {
        // Web/Android parity: callers pre-filter `ended` into the terminal
        // step; the resolver returns .lww (the STEP reducer owns terminality
        // and applies `ended` bypassing the (rev, atMs) gate — the elapsed
        // comparison never enters).
        let now = T0 + 100_000
        let local = state(start: T0, rev: 9, at: now)                  // elapsed 100, way ahead
        let incoming = state(start: T0 + 60_000, rev: 2, at: T0, ended: true)
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now), .lww)
        // ...and the step it falls back to DOES end the session (terminal
        // bypasses the older (rev, atMs)):
        let (apply, next) = sharedSessionStep(
            local: local, incoming: msg(start: T0 + 60_000, rev: 2, at: T0, ended: true))
        XCTAssertTrue(apply)
        XCTAssertTrue(next.ended)
    }

    // Regression guard for the NON-diverged path: the elapsed comparison
    // NEVER applies to live controls — a stale RUNNING re-announce (older
    // rev, "ahead" clock) must not un-pause an online pause. Plain LWW only.
    func testStaleRunningReannounceCannotUnpauseNonDivergedPause() {
        let local = state(start: T0, paused: true, pausedAt: T0 + 30_000,
                          rev: 5, at: T0 + 30_000)
        let stale = msg(start: T0, paused: false, pausedAt: nil, rev: 4, at: T0 + 60_000)
        let (apply, next) = sharedSessionStep(local: local, incoming: stale)
        XCTAssertFalse(apply)
        XCTAssertTrue(next.paused)
    }

    // Rev-floor integrity after ADOPT (spec §Convergence amendments): adopting
    // is wholesale, CURSORS INCLUDED. An offline client whose rev inflated to
    // 9 adopts the partner's rev-5 state → its floor becomes (5, inc.atMs), so
    // the partner's next control (rev 6) applies. A floor left at the stale
    // rev 9 would reject rev 6 — and our next re-announce would then revert
    // the partner's control on their side.
    func testAdoptResetsRevFloorSoPartnersNextControlApplies() {
        let now = T0 + 100_000
        // Diverged local: paused offline at 40s, rev inflated to 9.
        let local = state(start: T0, paused: true, pausedAt: T0 + 40_000,
                          rev: 9, at: T0 + 95_000)
        // Partner kept running: elapsed 100 — most ahead → adopt.
        let incoming = state(start: T0, rev: 5, at: T0 + 60_000)
        XCTAssertEqual(resolveDivergence(local: local, incoming: incoming, now: now), .adopt)

        // Wholesale adoption: the local floor IS the incoming (rev, atMs).
        let adopted = incoming
        XCTAssertEqual(adopted.rev, 5)

        // The partner's post-convergence pause at rev 6 must apply.
        let partnerPause = msg(start: T0, paused: true, pausedAt: now + 5000,
                               rev: 6, at: now + 5000)
        let (apply, next) = sharedSessionStep(local: adopted, incoming: partnerPause)
        XCTAssertTrue(apply)
        XCTAssertTrue(next.paused)

        // Regression shape: the POISONED floor (stale local rev 9 retained
        // after adopt) would have rejected exactly that control.
        var poisoned = incoming
        poisoned.rev = local.rev          // sharedSessionRev not reset
        poisoned.atMs = local.atMs
        XCTAssertFalse(sharedSessionStep(local: poisoned, incoming: partnerPause).apply)
    }

    // Both-diverged deadlock break (spec §Convergence amendments): each side's
    // hello declares divergence, each side ANSWERS (the reply bypasses its own
    // suppression) — safe because a diverged receiver resolves via MOST-AHEAD,
    // not plain LWW. Both sides then converge on the same (most-ahead) clock.
    func testBothDivergedConvergeOnTheMostAheadClock() {
        let now = T0 + 100_000
        let a = state(start: T0, rev: 9, at: T0 + 90_000)              // elapsed 100 (ahead)
        let b = state(start: T0 + 20_000, rev: 7, at: T0 + 80_000)     // elapsed 80

        // A (diverged) receives B's forced reply → keep + broadcast at
        // max(9, 7) + 1 = 10.
        XCTAssertEqual(resolveDivergence(local: a, incoming: b, now: now),
                       .keepAndBroadcast(rev: 10))
        // B (diverged) receives A's forced reply → adopt A wholesale.
        XCTAssertEqual(resolveDivergence(local: b, incoming: a, now: now), .adopt)

        // And A's convergence control then applies on B via plain LWW (B's
        // adopted floor = A's state; rev 10 > 9) — one shared clock, both sides.
        let convergence = msg(start: T0, rev: 10, at: now)
        let (apply, next) = sharedSessionStep(local: a, incoming: convergence)
        XCTAssertTrue(apply)
        XCTAssertEqual(next.sessionStartMs, T0)
    }

    // Socket-down alone must mark divergence (spec §Convergence amendments):
    // an offline RUNNER makes NO local control — its rev never inflates — so
    // under plain LWW the partner's mid-outage pause (higher rev, frozen way
    // back) would apply on rejoin and REWIND the runner. Diverged-marked, the
    // most-ahead comparison keeps the runner's clock and re-broadcasts it.
    func testOfflineRunnerMarkedDivergedIsNotRewoundByMidOutagePause() {
        let now = T0 + 100_000
        // The runner: no offline control, rev still 3, clock ran to 100s.
        let runner = state(start: T0, rev: 3, at: T0)
        // The partner paused mid-outage at 40s (rev 4 — strictly newer).
        let partnerPause = msg(start: T0, paused: true, pausedAt: T0 + 40_000,
                               rev: 4, at: T0 + 40_000)

        // WITHOUT the socket-down divergence mark: plain LWW applies the
        // pause and rewinds the runner to a 40s frozen clock. (This is why
        // `.disconnected` alone must flag divergence.)
        let lww = sharedSessionStep(local: runner, incoming: partnerPause)
        XCTAssertTrue(lww.apply)
        XCTAssertEqual(canonicalElapsedSec(lww.next, now: now), 40)

        // WITH the mark: most-ahead keeps the runner (elapsed 100 vs 40) and
        // broadcasts the genuine convergence control at max(3, 4) + 1.
        XCTAssertEqual(resolveDivergence(local: runner, incoming: partnerPause.state!, now: now),
                       .keepAndBroadcast(rev: 5))
    }
}

// MARK: - FocusTimer.adopt (join half of join-or-mint)

final class FocusTimerAdoptTests: XCTestCase {
    func testAdoptSeedsSessionFromWireState() {
        let wire = state(id: "shared-uuid", start: T0 - 176_000, estimate: 40, rev: 5, at: T0 - 1000)
        var cur = LiveSession.empty
        cur.treatment = .monk
        let adopted = FocusTimer.adopt(cur, taskId: "task-1", state: wire, priorAccumulatedSec: 300, now: T0)
        XCTAssertEqual(adopted.id, "shared-uuid")
        XCTAssertEqual(adopted.taskId, "task-1")
        XCTAssertEqual(adopted.sessionStart, T0 - 176_000)
        XCTAssertFalse(adopted.paused)
        XCTAssertEqual(adopted.sessionEstimateMin, 40)
        XCTAssertEqual(adopted.priorAccumulatedSec, 300)
        XCTAssertEqual(adopted.treatment, .monk)          // treatment kept
        XCTAssertEqual(adopted.sharedSessionRev, 5)       // rev chain continues
        XCTAssertEqual(adopted.lastAppliedRev, 5)         // LWW floor = the wire
        XCTAssertEqual(adopted.lastAppliedAtMs, T0 - 1000)
        XCTAssertNil(adopted.sharedSessionAtMs)           // no LOCAL control yet
        XCTAssertNil(adopted.sharedFocusLevel)            // caller re-stamps
        // Joins mid-clock — exactly what the tester expects (~02:56 here).
        XCTAssertEqual(FocusTimer.elapsedSec(adopted, now: T0), 176)
    }

    func testAdoptPausedState() {
        let wire = state(start: T0 - 60_000, paused: true, pausedAt: T0 - 10_000, rev: 2, at: T0 - 10_000)
        let adopted = FocusTimer.adopt(.empty, taskId: "t", state: wire, now: T0)
        XCTAssertTrue(adopted.paused)
        XCTAssertEqual(adopted.pausedAt, T0 - 10_000)
        XCTAssertEqual(FocusTimer.elapsedSec(adopted, now: T0), 50)
    }

    func testAdoptClampsFutureStartToNow() {
        // A partner clock a few seconds AHEAD posts a start in our future
        // (adoptable within the 2-min skew window) — clamp to `now` for local
        // display so the ring never renders a negative elapsed.
        let wire = state(start: T0 + 45_000, rev: 1, at: T0 + 45_000)
        let adopted = FocusTimer.adopt(.empty, taskId: "t", state: wire, now: T0)
        XCTAssertEqual(adopted.sessionStart, T0)
        XCTAssertEqual(FocusTimer.elapsedSec(adopted, now: T0), 0)
    }

    func testAdoptKeepsPastStartUnclamped() {
        let wire = state(start: T0 - 5000, rev: 1, at: T0 - 5000)
        let adopted = FocusTimer.adopt(.empty, taskId: "t", state: wire, now: T0)
        XCTAssertEqual(adopted.sessionStart, T0 - 5000)
    }

    func testFreshStartClearsSharedControlBookkeeping() {
        // A new MINT for another task must not inherit the old rev chain.
        var live = FocusTimer.adopt(.empty, taskId: "t1", state: state(rev: 7, at: T0), now: T0)
        live.sharedSessionEndedBy = "Ann"
        live.sharedSessionAtMs = T0
        live.divergedOffline = true
        let next = FocusTimer.start(live, taskId: "t2", estimateMin: 25, now: T0 + 1000)
        XCTAssertNil(next.sharedSessionRev)
        XCTAssertNil(next.sharedSessionAtMs)
        XCTAssertNil(next.lastAppliedRev)
        XCTAssertNil(next.lastAppliedAtMs)
        XCTAssertNil(next.divergedOffline)
        XCTAssertNil(next.sharedSessionEndedBy)
    }

    func testAdoptClearsDivergedFlag() {
        // Adopting a fresh in-flight session starts CONVERGED by definition.
        var cur = LiveSession.empty
        cur.divergedOffline = true
        let adopted = FocusTimer.adopt(cur, taskId: "t", state: state(rev: 3, at: T0), now: T0)
        XCTAssertNil(adopted.divergedOffline)
    }

    func testOldLiveSessionBlobDecodesWithoutNewFields() throws {
        // Pre-feature persisted JSON (no shared-session keys) keeps decoding.
        let json = """
        {"id":"s1","taskId":"t1","sessionStart":1000,"paused":false,
         "sessionEstimateMin":25,"nudge80Fired":false,"overrunPromptFired":false,
         "treatment":"ambient"}
        """
        let live = try JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
        XCTAssertNil(live.sharedSessionRev)
        XCTAssertNil(live.sharedSessionAtMs)
        XCTAssertNil(live.lastAppliedRev)
        XCTAssertNil(live.lastAppliedAtMs)
        XCTAssertNil(live.divergedOffline)
        XCTAssertNil(live.sharedSessionEndedBy)
    }

    func testDivergedFlagRoundTripsThroughTheBlob() throws {
        // The flag must survive a relaunch (a diverged rebind joins
        // receive-only) and stay optional for other-platform stores.
        var live = LiveSession.empty
        live.sessionStart = 1000
        live.divergedOffline = true
        let data = try JSONEncoder().encode(live)
        let back = try JSONDecoder().decode(LiveSession.self, from: data)
        XCTAssertEqual(back.divergedOffline, true)
    }
}
