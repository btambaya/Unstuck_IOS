// Ported 1:1 from lib/analytics.test.ts. Date-based cases use UTC ISO
// strings (CI runs TZ=UTC), matching the web's local-zone construction.

import XCTest
@testable import UnstuckCore

private func sess(_ id: String, taskId: String?, actualSec: Int, completedAt: String) -> Session {
    Session(id: id, taskId: taskId, taskName: "task", actualSec: actualSec, completedAt: completedAt)
}
private func cap(_ id: String, sessionId: String? = nil, tag: CaptureTag, at: String) -> Capture {
    Capture(id: id, sessionId: sessionId, tag: tag, body: "x", at: at)
}

final class DayOfWeekIdxTests: XCTestCase {
    func testMondayAnchored() {
        XCTAssertEqual(dayOfWeekIdx(Time.civil(2026, 5, 18)), 0)  // Mon
        XCTAssertEqual(dayOfWeekIdx(Time.civil(2026, 5, 19)), 1)  // Tue
        XCTAssertEqual(dayOfWeekIdx(Time.civil(2026, 5, 24)), 6)  // Sun
    }
}

final class WeekdayAreaHoursTests: XCTestCase {
    func testGroupsIntoWeekdayAndArea() {
        let tasks = [mkTask(id: "t1", lifeArea: "Work"), mkTask(id: "t2", lifeArea: "Personal")]
        let sessions = [
            sess("s1", taskId: "t1", actualSec: 3600, completedAt: "2026-05-19T10:00:00.000Z"), // Tue
            sess("s2", taskId: "t2", actualSec: 1800, completedAt: "2026-05-20T14:00:00.000Z"), // Wed
        ]
        let out = weekdayAreaHours(sessions, tasks)
        XCTAssertEqual(out[1].data[0], 1)     // Tue, Work
        XCTAssertEqual(out[2].data[1], 0.5)   // Wed, Personal
    }
}

final class CalibrationTests: XCTestCase {
    func testHitRateOneWithinSlack() {
        let tasks = [mkTask(id: "t1", estimateMin: 25)]
        let sessions = [
            sess("s1", taskId: "t1", actualSec: 25 * 60, completedAt: "2026-05-21T10:00:00.000Z"),
            sess("s2", taskId: "t1", actualSec: 27 * 60, completedAt: "2026-05-21T09:59:59.000Z"),
        ]
        let dots = calibrationDots(sessions, tasks)
        XCTAssertEqual(dots.count, 2)
        XCTAssertEqual(calibrationHitRate(dots, slackMin: 5), 1)
    }

    func testHitRateZeroWhenMissBy10() {
        let tasks = [mkTask(id: "t1", estimateMin: 25)]
        let sessions = [sess("s1", taskId: "t1", actualSec: 50 * 60, completedAt: "2026-05-21T10:00:00.000Z")]
        XCTAssertEqual(calibrationHitRate(calibrationDots(sessions, tasks)), 0)
    }
}

final class InterruptionBinsTests: XCTestCase {
    func testCapture10MinInto30MinSessionLandsBin3() {
        let completedMs = Time.parseMillis("2026-01-01T10:30:00.000Z")!
        let startMs = completedMs - 30 * 60 * 1000
        let s = sess("sess", taskId: "t", actualSec: 30 * 60, completedAt: "2026-01-01T10:30:00.000Z")
        let c = cap("c", sessionId: "sess", tag: .followUp, at: iso(startMs + 10 * 60_000))
        let bins = interruptionBins([c], [s], binMin: 3, binCount: 10)
        XCTAssertEqual(bins[3], 1)
    }
}

final class PauseAnatomyTests: XCTestCase {
    func testAggregatesMinutesAndFallsBackToCount() {
        let logs = [
            ReasonLog(id: "1", reason: "Bathroom", action: .pause, at: "2026-05-21T10:00:00.000Z", durationSec: 120),
            ReasonLog(id: "2", reason: "Bathroom", action: .pause, at: "2026-05-21T10:00:00.000Z", durationSec: 240),
            ReasonLog(id: "3", reason: "Drink", action: .pause, at: "2026-05-21T10:00:00.000Z"),
        ]
        let rows = pauseAnatomy(logs)
        XCTAssertEqual(rows[0].reason, "Bathroom")
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0].minutes, 6)
        XCTAssertEqual(rows[1].reason, "Drink")
        XCTAssertEqual(rows[1].count, 1)
        XCTAssertEqual(rows[1].minutes, 0)
    }

    func testCapsAt6() {
        let logs = (0..<10).map {
            ReasonLog(id: "\($0)", reason: "R\($0)", action: .pause, at: "2026-05-21T10:00:00.000Z", durationSec: 60)
        }
        XCTAssertEqual(pauseAnatomy(logs).count, 6)
    }
}

final class ReEntryDistributionTests: XCTestCase {
    func testTenMinGapLandsBin2() {
        let startMs = Time.parseMillis("2026-01-01T10:00:00.000Z")!
        let sessions = [
            sess("s1", taskId: "t", actualSec: 25 * 60, completedAt: iso(startMs + 25 * 60_000)),
            sess("s2", taskId: "t", actualSec: 25 * 60, completedAt: iso(startMs + (25 + 35) * 60_000)),
        ]
        let bins = reEntryDistribution(sessions, binMin: 5, binCount: 12)
        XCTAssertEqual(bins[2], 1)
    }
}

final class SlippingTests: XCTestCase {
    func testFlagsOlderThan21Days() {
        let now = Date().timeIntervalSince1970 * 1000
        let old = iso(now - 30 * DAY_MS)
        XCTAssertEqual(slipping([mkTask(id: "t1", name: "Old", createdAt: old)]).count, 1)
    }
    func testFlagsRescheduled3Plus() {
        XCTAssertEqual(slipping([mkTask(id: "t1", name: "Moved", moveCount: 4)]).count, 1)
    }
    func testIgnoresDone() {
        XCTAssertEqual(slipping([mkTask(id: "t1", done: true, moveCount: 5)]).count, 0)
    }
}

final class CaptureBreakdownTests: XCTestCase {
    func testCountsByTag() {
        let captures = [
            cap("1", tag: .followUp, at: "2026-05-21T10:00:00.000Z"),
            cap("2", tag: .followUp, at: "2026-05-21T10:00:00.000Z"),
            cap("3", tag: .distraction, at: "2026-05-21T10:00:00.000Z"),
        ]
        let out = captureBreakdown(captures)
        XCTAssertEqual(out[.followUp], 2)
        XCTAssertEqual(out[.distraction], 1)
        XCTAssertEqual(out[.idea], 0)
    }
}

final class TimeOfDayHeatmapTests: XCTestCase {
    // timeOfDayHeatmap buckets sessions by LOCAL hour-of-day, so the UTC fixture
    // timestamps below only land in the expected hour bucket when local == UTC.
    // Pin the process default to UTC rather than relying on an external `TZ=UTC`.
    private var savedTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
    }

    override func tearDown() {
        NSTimeZone.default = savedTimeZone
        super.tearDown()
    }

    func testSkipsWeekendsAndClamps() {
        let sessions = [
            sess("s1", taskId: "t", actualSec: 3600, completedAt: "2026-05-23T10:00:00.000Z"), // Sat — skipped
            sess("s2", taskId: "t", actualSec: 1800, completedAt: "2026-05-19T08:00:00.000Z"), // Tue 8am bucket 0
        ]
        let grid = timeOfDayHeatmap(sessions)
        XCTAssertEqual(grid[1][0], 0.5)
        XCTAssertEqual(grid.count, 5)
    }
}

final class TopInsightsTests: XCTestCase {
    func testEmptyDataNoFallbacks() {
        XCTAssertEqual(topInsights(sessions: [], tasks: [], captures: [], reasonLogs: []), [])
    }
    func testSurfacesSlippingTask() {
        let out = topInsights(sessions: [], tasks: [mkTask(name: "Old slip", moveCount: 5)], captures: [], reasonLogs: [])
        XCTAssertTrue(out.contains { $0.title.contains("Old slip") })
    }

    func testRichDataSurfacesWeekdayAndCalibration() {
        // 5 Monday sessions of 25 min on a 25-min-estimate task → best
        // weekday + 100% calibration insights (sessions ≥ REAL_DATA_THRESHOLD).
        let tasks = [mkTask(id: "t1", estimateMin: 25)]
        let sessions = (0..<5).map {
            sess("s\($0)", taskId: "t1", actualSec: 25 * 60, completedAt: "2026-05-18T10:0\($0):00.000Z") // Mon
        }
        let out = topInsights(sessions: sessions, tasks: tasks, captures: [], reasonLogs: [])
        XCTAssertTrue(out.contains { $0.title.contains("strongest day") })
        XCTAssertTrue(out.contains { $0.title.contains("Estimates within 5 min") })
    }
}
