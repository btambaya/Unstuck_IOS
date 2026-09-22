// Ports the completion-stamp rules (lib/use-tasks.ts) + the
// isCompletedToday boundary cases (lib/task-completion.test.ts).

import XCTest
@testable import UnstuckCore

private func localDT(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, _ ss: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = hh; c.minute = mm; c.second = ss
    return Calendar.current.date(from: c)!
}
private func localISO(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, _ ss: Int = 0) -> String {
    iso(localDT(y, m, d, hh, mm, ss).timeIntervalSince1970 * 1000)
}

final class StampCompletionTests: XCTestCase {
    private let now = "2026-05-21T12:00:00.000Z"

    func testFirstDoneFlipStampsNow() {
        let t = mkTask(id: "t", done: true, completedAt: nil)
        let out = applyCompletion(t, prior: mkTask(id: "t"), nowISO: now)
        XCTAssertEqual(out.completedAt, now)
        XCTAssertEqual(out.updatedAt, now)
    }

    func testKeepsIncomingCompletedAt() {
        let explicit = "2026-05-20T08:00:00.000Z"
        let t = mkTask(id: "t", done: true, completedAt: explicit)
        XCTAssertEqual(applyCompletion(t, prior: nil, nowISO: now).completedAt, explicit)
    }

    func testPreservesPriorTimestampOnRetoggle() {
        let original = "2026-05-19T09:00:00.000Z"
        let t = mkTask(id: "t", done: true, completedAt: nil)
        let prior = mkTask(id: "t", done: true, completedAt: original)
        XCTAssertEqual(applyCompletion(t, prior: prior, nowISO: now).completedAt, original)
    }

    func testUncompleteClearsTimestamp() {
        let t = mkTask(id: "t", done: false, completedAt: "2026-05-19T09:00:00.000Z")
        let prior = mkTask(id: "t", done: true, completedAt: "2026-05-19T09:00:00.000Z")
        XCTAssertNil(applyCompletion(t, prior: prior, nowISO: now).completedAt)
    }
}

final class BumpMoveCountTests: XCTestCase {
    private let now = "2026-05-21T12:00:00.000Z"

    func testIncrementsFromNil() {
        XCTAssertEqual(bumpMoveCount(mkTask(moveCount: nil), nowISO: now).moveCount, 1)
    }
    func testIncrementsExisting() {
        XCTAssertEqual(bumpMoveCount(mkTask(moveCount: 2), nowISO: now).moveCount, 3)
    }
    func testSetsUpdatedAt() {
        XCTAssertEqual(bumpMoveCount(mkTask(moveCount: 0), nowISO: now).updatedAt, now)
    }
}

final class IsCompletedTodayBoundaryTests: XCTestCase {
    // Wed 2026-05-20 10:00 local.
    private let now = localDT(2026, 5, 20, 10, 0).timeIntervalSince1970 * 1000

    func testFalseWhenMissing() {
        XCTAssertFalse(isCompletedToday(mkTask(completedAt: nil), now: now))
    }
    func testTrueAtMidnightToday() {
        XCTAssertTrue(isCompletedToday(mkTask(completedAt: localISO(2026, 5, 20, 0, 0)), now: now))
    }
    func testTrueJustBeforeMidnightTomorrow() {
        XCTAssertTrue(isCompletedToday(mkTask(completedAt: localISO(2026, 5, 20, 23, 59, 59)), now: now))
    }
    func testFalseLateYesterday() {
        XCTAssertFalse(isCompletedToday(mkTask(completedAt: localISO(2026, 5, 19, 23, 59, 59)), now: now))
    }
    func testFalseTheMomentTomorrowStarts() {
        XCTAssertFalse(isCompletedToday(mkTask(completedAt: localISO(2026, 5, 21, 0, 0)), now: now))
    }
}

// The server CHECK clamps live in Core (audit 2026-09-22, C4) so WriteThrough
// and the wire codec apply the same rule as the assistant tools.
final class ServerCheckClampTests: XCTestCase {
    func testServerCheckClampsLiveInCore() {
        XCTAssertEqual(clampEstimateMin(nil), 25)
        XCTAssertEqual(clampEstimateMin(0), 1)
        XCTAssertEqual(clampEstimateMin(2), 2, "a 1-4 minute task keeps its estimate")
        XCTAssertEqual(clampEstimateMin(5000), 1440)
        XCTAssertEqual(clampDurationMin(2), 5, "its block floors at 5")
        XCTAssertEqual(clampDurationMin(nil, fallback: 60), 60)
        XCTAssertEqual(clampDurationMin(99999), 1440)
    }
}
