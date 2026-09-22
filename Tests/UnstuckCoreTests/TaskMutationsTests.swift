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

/// Tasks key areas and tags by NAME, so a rename/delete of the vocabulary row
/// rewrites the tasks that carry it (audit 2026-09-22, C19).
final class LabelCascadeTests: XCTestCase {
    private let now = "2026-09-22T12:00:00.000Z"

    func testAreaRenameMovesOnlyAnExactMatch() {
        let moved = relabelingArea(mkTask(lifeArea: "Personal"), from: "Personal", to: "Life", nowISO: now)
        XCTAssertEqual(moved?.lifeArea, "Life")
        XCTAssertEqual(moved?.updatedAt, now)
        XCTAssertNil(relabelingArea(mkTask(lifeArea: "Work"), from: "Personal", to: "Life", nowISO: now))
        XCTAssertNil(relabelingArea(mkTask(lifeArea: nil), from: "Personal", to: "Life", nowISO: now))
        XCTAssertNil(relabelingArea(mkTask(lifeArea: "personal"), from: "Personal", to: "Life", nowISO: now),
                     "exact match, like the web/Android cascade and the Today filter")
    }

    func testAreaDeleteClearsTheLabel() {
        let cleared = relabelingArea(mkTask(lifeArea: "Work"), from: "Work", to: nil, nowISO: now)
        XCTAssertNotNil(cleared)
        XCTAssertNil(cleared?.lifeArea)
        XCTAssertEqual(cleared?.updatedAt, now)
    }

    func testTagRenameIsCaseInsensitiveAndNeverDuplicates() {
        let renamed = renamingTag(mkTask(tags: ["DEEP", "x"]), from: "deep", to: "Focus", nowISO: now)
        XCTAssertEqual(renamed?.tags, ["Focus", "x"])
        XCTAssertEqual(renamed?.updatedAt, now)
        XCTAssertEqual(renamingTag(mkTask(tags: ["deep", "focus"]), from: "deep", to: "focus", nowISO: now)?.tags, ["focus"],
                       "a task already carrying the new name keeps one copy")
        XCTAssertNil(renamingTag(mkTask(tags: ["x"]), from: "deep", to: "Focus", nowISO: now))
        XCTAssertNil(renamingTag(mkTask(tags: nil), from: "deep", to: "Focus", nowISO: now))
    }

    func testTagDeleteStripsEveryCaseAndEmptiesToNil() {
        let stripped = strippingTag(mkTask(tags: ["Deep", "x", "deep"]), name: "deep", nowISO: now)
        XCTAssertEqual(stripped?.tags, ["x"])
        XCTAssertEqual(stripped?.updatedAt, now)
        let emptied = strippingTag(mkTask(tags: ["deep"]), name: "DEEP", nowISO: now)
        XCTAssertNotNil(emptied)
        XCTAssertNil(emptied?.tags, "an emptied list is nil, not []")
        XCTAssertNil(strippingTag(mkTask(tags: ["x"]), name: "deep", nowISO: now))
    }

    func testLabelNameTakenIgnoresCase() {
        XCTAssertTrue(labelNameTaken("home", among: ["Home", "Work"]))
        XCTAssertFalse(labelNameTaken("Garden", among: ["Home", "Work"]))
        XCTAssertFalse(labelNameTaken("Home", among: []))
    }

    func testAnAreaFilterFollowsARenameAndFallsBackToAllOnADelete() {
        let work = LifeArea(id: "a1", name: "Work", color: "indigo", sortOrder: 0)
        let personal = LifeArea(id: "a2", name: "Personal", color: "green", sortOrder: 1)
        var life = personal; life.name = "Life"
        XCTAssertEqual(areaFilterFollowing("Personal", from: [work, personal], to: [work, life]), "Life",
                       "a renamed area keeps its pill selected under the new name")
        XCTAssertNil(areaFilterFollowing("Personal", from: [work, personal], to: [work]),
                     "a deleted area falls back to All")
        XCTAssertEqual(areaFilterFollowing("Work", from: [work, personal], to: [work, life]), "Work")
        XCTAssertNil(areaFilterFollowing(nil, from: [work, personal], to: [work, life]))
        var twin = work; twin.id = "a3"
        var office = twin; office.name = "Office"
        XCTAssertEqual(areaFilterFollowing("Work", from: [work, twin], to: [work, office]), "Work",
                       "an area still named Work keeps the filter when its twin is renamed")
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
