// Ports the behavioral assertions of lib/use-focus-timer.test.ts onto
// the pure engine. The web hook drives wall-clock time + localStorage;
// here we inject `now` (epoch ms) so the same scenarios are exact.

import XCTest
@testable import UnstuckCore

private let T0 = Time.parseMillis("2026-05-21T10:00:00.000Z")!
private func grace(_ p: String? = nil) -> Double { FocusTimer.overrunGraceSeconds(pref: p) }

final class FormatMMSSTests: XCTestCase {
    func testPositive() {
        XCTAssertEqual(formatMMSS(0), "00:00")
        XCTAssertEqual(formatMMSS(65), "01:05")
        XCTAssertEqual(formatMMSS(3600), "60:00")
    }
    func testNegative() {
        XCTAssertEqual(formatMMSS(-65), "-01:05")
    }
}

final class SharedFocusMarkerTests: XCTestCase {
    // A fresh session for a DIFFERENT task must not inherit a prior session's
    // shared marker (else a following own-task focus would wrongly log onto an
    // owner). start() resets it; the caller re-stamps for a shared focus.
    func testFreshStartClearsSharedMarker() {
        var live = FocusTimer.start(.empty, taskId: "shared-1", estimateMin: 25, now: T0)
        live.sharedFocusLevel = .partner
        let next = FocusTimer.start(live, taskId: "own-2", estimateMin: 25, now: T0 + 60_000)
        XCTAssertNil(next.sharedFocusLevel)
        XCTAssertEqual(next.taskId, "own-2")
    }

    // Resuming the SAME paused task preserves its shared marker (the session is
    // continued, not recreated).
    func testResumePreservesSharedMarker() {
        var live = FocusTimer.start(.empty, taskId: "shared-1", estimateMin: 25, now: T0)
        live.sharedFocusLevel = .assign
        live = FocusTimer.pause(live, now: T0 + 30_000)
        let resumed = FocusTimer.start(live, taskId: "shared-1", estimateMin: 25, now: T0 + 60_000)
        XCTAssertEqual(resumed.sharedFocusLevel, .assign)
        XCTAssertFalse(resumed.paused)
    }

    // Old persisted live_session JSON (pre-045, no key) decodes to nil, not a crash.
    func testLiveSessionDecodesWithoutSharedMarker() throws {
        let json = """
        {"id":"s1","taskId":"t1","sessionStart":1000,"paused":false,
         "sessionEstimateMin":25,"nudge80Fired":false,"overrunPromptFired":false,
         "treatment":"ambient"}
        """
        let live = try JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
        XCTAssertNil(live.sharedFocusLevel)
        XCTAssertEqual(live.taskId, "t1")
    }
}

final class FocusTimerBasicTests: XCTestCase {

    func testIdleByDefault() {
        let live = FocusTimer.empty
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0, overrunGraceSec: grace()), .idle)
        XCTAssertEqual(live.taskId, "")
    }

    func testStartTransitionsToRunning() {
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 5, now: T0)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0, overrunGraceSec: grace()), .running)
        XCTAssertEqual(live.taskId, "task-1")
        XCTAssertEqual(FocusTimer.estimateSec(live), 300)
    }

    func testPauseThenResume() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 5, now: T0)
        live = FocusTimer.pause(live, now: T0 + 1000)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0 + 1000, overrunGraceSec: grace()), .pause)
        live = FocusTimer.resume(live, now: T0 + 2000)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0 + 2000, overrunGraceSec: grace()), .running)
    }

    func testCancelBackToIdle() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 5, now: T0)
        live = FocusTimer.cancel(live)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0, overrunGraceSec: grace()), .idle)
        XCTAssertEqual(live.taskId, "")
    }

    func testExtendAddsMinutes() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 5, now: T0)
        live = FocusTimer.extend(live, minutes: 10)
        XCTAssertEqual(FocusTimer.estimateSec(live), 15 * 60)
    }

    func testSetTreatmentPersists() {
        let live = FocusTimer.setTreatment(.empty, .monk)
        XCTAssertEqual(live.treatment, .monk)
    }
}

final class FocusTimerResumeAwareTests: XCTestCase {

    func testStartOnSamePausedTaskResumesWithoutResettingElapsed() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        let atPauseNow = T0 + 5 * 60_000
        live = FocusTimer.pause(live, now: atPauseNow)
        let elapsedAtPause = FocusTimer.elapsedSec(live, now: atPauseNow)
        XCTAssertEqual(elapsedAtPause, 300)

        // 15 minutes pass while saved-for-later, then Start on same task.
        let resumeNow = atPauseNow + 15 * 60_000
        live = FocusTimer.start(live, taskId: "task-1", estimateMin: 25, now: resumeNow)
        XCTAssertEqual(FocusTimer.deriveState(live, now: resumeNow, overrunGraceSec: grace()), .running)
        XCTAssertEqual(FocusTimer.elapsedSec(live, now: resumeNow), elapsedAtPause)
    }

    func testStartOnDifferentTaskStartsFresh() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        live = FocusTimer.pause(live, now: T0 + 3 * 60_000)
        let freshNow = T0 + 3 * 60_000
        live = FocusTimer.start(live, taskId: "task-2", estimateMin: 25, now: freshNow)
        XCTAssertEqual(live.taskId, "task-2")
        XCTAssertEqual(FocusTimer.deriveState(live, now: freshNow, overrunGraceSec: grace()), .running)
        XCTAssertLessThanOrEqual(FocusTimer.elapsedSec(live, now: freshNow), 1)
    }

    func testStartOnSameRunningTaskIsNoOp() {
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        let elapsedBefore = FocusTimer.elapsedSec(live, now: T0 + 2 * 60_000)
        let live2 = FocusTimer.start(live, taskId: "task-1", estimateMin: 25, now: T0 + 2 * 60_000)
        XCTAssertEqual(FocusTimer.elapsedSec(live2, now: T0 + 2 * 60_000), elapsedBefore)
        XCTAssertEqual(live2.sessionStart, live.sessionStart)
    }
}

final class FocusTimerResumePreservesElapsedTests: XCTestCase {

    func testElapsedDoesNotAdvanceWhilePausedAndSurvivesResume() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        let pauseNow = T0 + 5 * 60_000
        live = FocusTimer.pause(live, now: pauseNow)
        let elapsedAtPause = FocusTimer.elapsedSec(live, now: pauseNow)
        XCTAssertEqual(elapsedAtPause, 300)

        // 60s paused — elapsed must not advance.
        XCTAssertEqual(FocusTimer.elapsedSec(live, now: pauseNow + 60_000), elapsedAtPause)

        let resumeNow = pauseNow + 60_000
        live = FocusTimer.resume(live, now: resumeNow)
        XCTAssertEqual(FocusTimer.elapsedSec(live, now: resumeNow), elapsedAtPause)

        // 10s later → ~elapsedAtPause + 10.
        XCTAssertEqual(FocusTimer.elapsedSec(live, now: resumeNow + 10_000), elapsedAtPause + 10)
    }
}

final class FocusTimerPriorAccumulatedTests: XCTestCase {

    func testStartWithPriorSeedsDisplayed() {
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, priorAccumulatedSec: 600, now: T0)
        XCTAssertLessThanOrEqual(FocusTimer.elapsedSec(live, now: T0), 1)
        XCTAssertEqual(FocusTimer.displayedElapsedSec(live, now: T0), 600)
        XCTAssertEqual(live.priorAccumulatedSec, 600)
    }

    func testDefaultsPriorToZero() {
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        XCTAssertEqual(live.priorAccumulatedSec, 0)
        XCTAssertEqual(FocusTimer.displayedElapsedSec(live, now: T0), FocusTimer.elapsedSec(live, now: T0))
    }

    func testPauseResumePreservesPrior() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, priorAccumulatedSec: 300, now: T0)
        live = FocusTimer.pause(live, now: T0 + 1000)
        XCTAssertEqual(live.priorAccumulatedSec, 300)
        live = FocusTimer.resume(live, now: T0 + 2000)
        XCTAssertEqual(live.priorAccumulatedSec, 300)
    }

    func testOverrunFiresOnDisplayedNotRawElapsed() {
        let g = grace("5 min")  // 300s grace
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, priorAccumulatedSec: 24 * 60, now: T0)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0, overrunGraceSec: g), .running)
        // +7 min → displayed = 420 + 1440 = 1860 ≥ 1500 + 300.
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0 + 7 * 60_000, overrunGraceSec: g), .overrun)
    }

    func testDoneClearsSessionStartAndResetsElapsed() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, priorAccumulatedSec: 600, now: T0)
        XCTAssertLessThanOrEqual(FocusTimer.elapsedSec(live, now: T0), 1)
        live = FocusTimer.done(live)
        XCTAssertNil(live.sessionStart)
        XCTAssertEqual(FocusTimer.elapsedSec(live, now: T0 + 99_000), 0)
    }

    func testStartOnSamePausedTaskIgnoresPrior() {
        var live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 25, now: T0)
        live = FocusTimer.pause(live, now: T0 + 1000)
        live = FocusTimer.start(live, taskId: "task-1", estimateMin: 25, priorAccumulatedSec: 9999, now: T0 + 2000)
        XCTAssertEqual(live.priorAccumulatedSec, 0)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0 + 2000, overrunGraceSec: grace()), .running)
    }

    func testNeverGraceMeansNeverOverrun() {
        let live = FocusTimer.start(.empty, taskId: "task-1", estimateMin: 1, now: T0)
        XCTAssertEqual(FocusTimer.deriveState(live, now: T0 + 60 * 60_000, overrunGraceSec: grace("Never")), .running)
    }
}

/// Recurring occurrences: the session runs on the TEMPLATE task, so a start on
/// a different day's block matches on taskId. Same-task starts continue the
/// session (resume if paused / no-op if running) and RE-POINT it at the
/// occurrence being started — "Mark complete" ticks `occurrenceBlockId`, so
/// silently keeping Monday's block completed the wrong day (web/Android parity).
final class FocusTimerOccurrenceRepointTests: XCTestCase {
    private func paused(on occurrence: String) -> LiveSession {
        let live = FocusTimer.start(.empty, taskId: "tpl", estimateMin: 30, priorAccumulatedSec: 120,
                                    now: T0, occurrenceBlockId: occurrence, newId: { "s-mon" })
        return FocusTimer.pause(live, now: T0 + 5 * 60_000)
    }

    func testSameTaskSameOccurrencePausedResumesInPlace() {
        let live = paused(on: "mon")
        let now = T0 + 20 * 60_000
        let next = FocusTimer.start(live, taskId: "tpl", estimateMin: 30, now: now, occurrenceBlockId: "mon")
        XCTAssertEqual(next.id, "s-mon", "the same session — not a mint")
        XCTAssertEqual(next.occurrenceBlockId, "mon")
        XCTAssertFalse(next.paused)
        XCTAssertEqual(FocusTimer.elapsedSec(next, now: now), 300, "elapsed carries over the pause gap")
        XCTAssertEqual(next.sessionEstimateMin, 30)
        XCTAssertEqual(next.priorAccumulatedSec, 120)
    }

    func testSameTaskSameOccurrenceRunningIsANoOp() {
        let live = FocusTimer.start(.empty, taskId: "tpl", estimateMin: 30, now: T0, occurrenceBlockId: "mon")
        let next = FocusTimer.start(live, taskId: "tpl", estimateMin: 25, now: T0 + 2 * 60_000, occurrenceBlockId: "mon")
        XCTAssertEqual(next, live, "a double Start never resets the clock, the estimate, or the occurrence")
    }

    func testSameTaskDifferentOccurrencePausedResumesAndRepoints() {
        let live = paused(on: "mon")
        let now = T0 + 24 * 3_600_000
        let next = FocusTimer.start(live, taskId: "tpl", estimateMin: 30, now: now, occurrenceBlockId: "tue")
        XCTAssertEqual(next.id, "s-mon", "continuity: the paused session is resumed, not replaced")
        XCTAssertEqual(next.occurrenceBlockId, "tue", "…but attached to TODAY's block")
        XCTAssertFalse(next.paused)
        XCTAssertNil(next.pausedAt)
        XCTAssertEqual(FocusTimer.elapsedSec(next, now: now), 300, "the clock continues untouched")
        XCTAssertEqual(next.sessionEstimateMin, 30)
        XCTAssertEqual(next.priorAccumulatedSec, 120)
    }

    func testSameTaskDifferentOccurrenceRunningRepointsWithoutTouchingTheClock() {
        let live = FocusTimer.start(.empty, taskId: "tpl", estimateMin: 30, now: T0, occurrenceBlockId: "mon", newId: { "s-mon" })
        let now = T0 + 3 * 60_000
        let next = FocusTimer.start(live, taskId: "tpl", estimateMin: 45, now: now, occurrenceBlockId: "tue")
        XCTAssertEqual(next.id, "s-mon")
        XCTAssertEqual(next.occurrenceBlockId, "tue")
        XCTAssertEqual(next.sessionStart, live.sessionStart)
        XCTAssertEqual(next.sessionEstimateMin, 30, "the running session's estimate wins over the new start's")
        XCTAssertFalse(next.paused)
        var expected = live
        expected.occurrenceBlockId = "tue"
        XCTAssertEqual(next, expected, "the ONLY change is the occurrence")
    }

    func testSameTaskWithoutAnOccurrenceKeepsTheCurrentOne() {
        // Starting the template itself (no block) must not detach a session
        // from the occurrence it was minted on — web parity (`occ &&`).
        let live = paused(on: "mon")
        let now = T0 + 10 * 60_000
        let next = FocusTimer.start(live, taskId: "tpl", estimateMin: 30, now: now, occurrenceBlockId: nil)
        XCTAssertEqual(next.id, "s-mon")
        XCTAssertEqual(next.occurrenceBlockId, "mon")
        XCTAssertFalse(next.paused)
    }

    func testDifferentTaskStartsANewSessionOnItsOwnOccurrence() {
        let live = paused(on: "mon")
        let now = T0 + 10 * 60_000
        let next = FocusTimer.start(live, taskId: "other", estimateMin: 15, priorAccumulatedSec: 0,
                                    now: now, occurrenceBlockId: "other-tue", newId: { "s-new" })
        XCTAssertEqual(next.id, "s-new", "a different task mints a fresh session")
        XCTAssertEqual(next.taskId, "other")
        XCTAssertEqual(next.occurrenceBlockId, "other-tue")
        XCTAssertEqual(next.sessionStart, now)
        XCTAssertEqual(FocusTimer.elapsedSec(next, now: now), 0)
        XCTAssertEqual(next.sessionEstimateMin, 15)
        XCTAssertEqual(next.priorAccumulatedSec, 0)
        // And a different task WITHOUT an occurrence carries none over.
        let plain = FocusTimer.start(live, taskId: "plain", estimateMin: 25, now: now, newId: { "s-plain" })
        XCTAssertNil(plain.occurrenceBlockId)
    }
}

/// The pause's reason log is kept on the live session and re-saved with the
/// pause length when the pause ends (Insights "What pauses you" / "How fast
/// you come back", analytics cross-check P0-3).
final class FocusTimerPauseLengthTests: XCTestCase {
    private let t0: EpochMillis = 1_789_480_800_000
    private let log = ReasonLog(id: "r1", taskId: "t", reason: "Phone", action: .pause, at: "2026-09-15T14:00:05Z")

    private func running() -> LiveSession {
        LiveSession(id: "s1", taskId: "t", sessionStart: t0, sessionEstimateMin: 25, treatment: .ambient)
    }

    func testResumeHandsBackTheLogWithHowLongThePauseLasted() {
        var paused = FocusTimer.pause(running(), now: t0 + 10 * 60_000)
        paused.pendingPauseLog = log
        let closed = FocusTimer.closedPauseLog(paused, now: t0 + 10 * 60_000 + 185_400)
        XCTAssertEqual(closed?.id, "r1")                 // the SAME row → an upsert, not a second log
        XCTAssertEqual(closed?.durationSec, 185)
        XCTAssertEqual(closed?.reason, "Phone")
        let resumed = FocusTimer.resume(paused, now: t0 + 10 * 60_000 + 185_400)
        XCTAssertNil(resumed.pendingPauseLog)
        XCTAssertNil(FocusTimer.closedPauseLog(resumed, now: t0 + 20 * 60_000))   // not paused → nothing
    }

    func testJustPauseHasNoLogAndANewPauseStartsClean() {
        let paused = FocusTimer.pause(running(), now: t0 + 60_000)
        XCTAssertNil(FocusTimer.closedPauseLog(paused, now: t0 + 120_000))
        var stale = running()
        stale.pendingPauseLog = log
        XCTAssertNil(FocusTimer.pause(stale, now: t0 + 60_000).pendingPauseLog)
        var ended = FocusTimer.pause(running(), now: t0 + 60_000)
        ended.pendingPauseLog = log
        XCTAssertNil(FocusTimer.done(ended).pendingPauseLog)
    }

    func testOldPersistedSessionsWithoutTheFieldStillDecode() throws {
        let json = #"{"id":"s1","taskId":"t","sessionStart":1,"paused":true,"pausedAt":2,"sessionEstimateMin":25,"nudge80Fired":false,"overrunPromptFired":false,"treatment":"ambient"}"#
        let ls = try JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
        XCTAssertNil(ls.pendingPauseLog)
    }
}
