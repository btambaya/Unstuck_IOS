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
