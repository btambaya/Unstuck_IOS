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

    func testPausedWithoutPausedAtFallsBackToZero() {
        let s = state(start: T0, paused: true, pausedAt: nil)
        XCTAssertEqual(canonicalElapsedSec(s, now: T0 + 999_000), 0)
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
        let next = FocusTimer.start(live, taskId: "t2", estimateMin: 25, now: T0 + 1000)
        XCTAssertNil(next.sharedSessionRev)
        XCTAssertNil(next.sharedSessionAtMs)
        XCTAssertNil(next.lastAppliedRev)
        XCTAssertNil(next.lastAppliedAtMs)
        XCTAssertNil(next.sharedSessionEndedBy)
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
        XCTAssertNil(live.sharedSessionEndedBy)
    }
}
