// App-layer unit tests for the calendar's SHARED layer (Calendar+Shared.swift):
// the per-window cache the ShareModel keeps, the ISO window arithmetic the
// Day/Week/Month surfaces request with, the own+shared merged lane layout, the
// read-only gate every mutating path keys off, and the Month marks. Pure; no
// UI, no store, no network.

import XCTest
import UnstuckCore
@testable import Unstuck

private func own(_ id: String, _ start: String, _ durationMin: Int, kind: CalBlockKind? = .task,
                 date: String = "2026-05-21", skipped: Bool = false) -> CalBlock {
    CalBlock(id: id, taskId: kind == .task ? id : nil, taskName: id, startTime: start,
             durationMinutes: durationMin, date: date,
             externalEventId: kind == .external ? "g_\(id)" : nil, kind: kind, skipped: skipped)
}

private func shared(_ id: String, _ start: String, _ durationMin: Int, date: String = "2026-05-21",
                    skipped: Bool = false, done: Bool = false, owner: String = "Anna Lee") -> SharedBlock {
    SharedBlock(blockId: id, taskId: "task-\(id)", shareId: "share-\(id)", level: .view, ownerName: owner,
                title: "Shared \(id)", date: date, startTime: start, durationMinutes: durationMin,
                done: done, skipped: skipped, kind: "task")
}

private typealias Window = SharedBlocksCache.Window

// MARK: - Window cache

final class SharedBlocksCacheTests: XCTestCase {

    func testEmptyCacheCoversNothingAndServesNothing() {
        let c = SharedBlocksCache()
        XCTAssertFalse(c.covers(Window(from: "2026-05-18", to: "2026-05-24")))
        XCTAssertTrue(c.blocks(on: "2026-05-21").isEmpty)
        XCTAssertTrue(c.windows.isEmpty)
    }

    func testStoreCoversTheWindowAndAnySubRange() {
        var c = SharedBlocksCache()
        let week = Window(from: "2026-05-18", to: "2026-05-24")
        c.store(week, blocks: [shared("a", "09:00", 30)])
        XCTAssertTrue(c.covers(week))
        XCTAssertTrue(c.covers(Window(from: "2026-05-21", to: "2026-05-21")))
        XCTAssertTrue(c.covers(Window(from: "2026-05-18", to: "2026-05-20")))
        // Anything poking outside is NOT covered (needs its own fetch).
        XCTAssertFalse(c.covers(Window(from: "2026-05-17", to: "2026-05-21")))
        XCTAssertFalse(c.covers(Window(from: "2026-05-24", to: "2026-05-25")))
        XCTAssertEqual(c.blocks(on: "2026-05-21").map(\.blockId), ["a"])
    }

    func testBlocksOnADayDropSkippedAndSortByStart() {
        var c = SharedBlocksCache()
        c.store(Window(from: "2026-05-21", to: "2026-05-21"),
                blocks: [shared("late", "14:00", 30), shared("skip", "08:00", 30, skipped: true), shared("early", "09:00", 30)])
        XCTAssertEqual(c.blocks(on: "2026-05-21").map(\.blockId), ["early", "late"])
        XCTAssertTrue(c.blocks(on: "2026-05-22").isEmpty)
    }

    func testRestoringAWindowReplacesItsDates() {
        var c = SharedBlocksCache()
        let w = Window(from: "2026-05-18", to: "2026-05-24")
        c.store(w, blocks: [shared("gone", "09:00", 30), shared("kept", "10:00", 30, date: "2026-05-22")])
        // The owner unscheduled "gone" and moved "kept" — the re-read must not
        // leave stale rows behind.
        c.store(w, blocks: [shared("kept", "11:00", 30, date: "2026-05-23")])
        XCTAssertTrue(c.blocks(on: "2026-05-21").isEmpty)
        XCTAssertTrue(c.blocks(on: "2026-05-22").isEmpty)
        XCTAssertEqual(c.blocks(on: "2026-05-23").map(\.startTime), ["11:00"])
        XCTAssertEqual(c.windows, [w])   // re-stored, not duplicated
    }

    func testRowsOutsideTheWindowAreIgnored() {
        var c = SharedBlocksCache()
        c.store(Window(from: "2026-05-18", to: "2026-05-24"),
                blocks: [shared("in", "09:00", 30), shared("out", "09:00", 30, date: "2026-06-01")])
        XCTAssertEqual(c.blocks(on: "2026-05-21").map(\.blockId), ["in"])
        XCTAssertTrue(c.blocks(on: "2026-06-01").isEmpty)
    }

    func testOverlappingWindowsKeepEachOthersDates() {
        var c = SharedBlocksCache()
        c.store(Window(from: "2026-05-01", to: "2026-05-31"), blocks: [shared("m", "09:00", 30, date: "2026-05-05")])
        c.store(Window(from: "2026-05-18", to: "2026-05-24"), blocks: [shared("w", "09:00", 30, date: "2026-05-21")])
        XCTAssertEqual(c.blocks(on: "2026-05-05").map(\.blockId), ["m"])
        XCTAssertEqual(c.blocks(on: "2026-05-21").map(\.blockId), ["w"])
        XCTAssertEqual(c.windows.count, 2)
    }

    func testEvictsTheOldestWindowBeyondTheCap() {
        var c = SharedBlocksCache()
        let months = ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05"]
        for (i, m) in months.enumerated() {
            c.store(Window(from: "\(m)-01", to: "\(m)-28"), blocks: [shared("b\(i)", "09:00", 30, date: "\(m)-10")])
        }
        XCTAssertEqual(c.windows.count, SharedBlocksCache.maxWindows)
        XCTAssertEqual(c.windows.first?.from, "2026-02-01")
        XCTAssertTrue(c.blocks(on: "2026-01-10").isEmpty)      // evicted with its window
        XCTAssertEqual(c.blocks(on: "2026-05-10").map(\.blockId), ["b4"])
        XCTAssertFalse(c.covers(Window(from: "2026-01-10", to: "2026-01-10")))
    }

    func testEvictionKeepsDatesStillCoveredByAnotherWindow() {
        var c = SharedBlocksCache()
        // A month window first (oldest), then four week windows — one of which
        // overlaps the month. Evicting the month must not drop the overlap.
        c.store(Window(from: "2026-05-01", to: "2026-05-31"), blocks: [shared("m", "09:00", 30, date: "2026-05-21")])
        c.store(Window(from: "2026-05-18", to: "2026-05-24"), blocks: [shared("w", "09:00", 30, date: "2026-05-21")])
        c.store(Window(from: "2026-06-01", to: "2026-06-07"), blocks: [])
        c.store(Window(from: "2026-06-08", to: "2026-06-14"), blocks: [])
        c.store(Window(from: "2026-06-15", to: "2026-06-21"), blocks: [])
        XCTAssertEqual(c.windows.count, 4)
        XCTAssertEqual(c.blocks(on: "2026-05-21").map(\.blockId), ["w"])
        XCTAssertTrue(c.blocks(on: "2026-05-05").isEmpty)
    }

    func testClear() {
        var c = SharedBlocksCache()
        c.store(Window(from: "2026-05-21", to: "2026-05-21"), blocks: [shared("a", "09:00", 30)])
        c.clear()
        XCTAssertTrue(c.windows.isEmpty)
        XCTAssertTrue(c.blocks(on: "2026-05-21").isEmpty)
    }
}

// MARK: - Window arithmetic

final class CalWindowTests: XCTestCase {

    func testDaysIsInclusiveAndOrdered() {
        XCTAssertEqual(CalWindow.days(from: "2026-05-30", to: "2026-06-02"),
                       ["2026-05-30", "2026-05-31", "2026-06-01", "2026-06-02"])
        XCTAssertEqual(CalWindow.days(from: "2026-05-21", to: "2026-05-21"), ["2026-05-21"])
        XCTAssertTrue(CalWindow.days(from: "2026-05-22", to: "2026-05-21").isEmpty)
        XCTAssertTrue(CalWindow.days(from: "nope", to: "2026-05-21").isEmpty)
    }

    func testDaysIsCappedAtTheServersWindow() {
        XCTAssertEqual(CalWindow.days(from: "2026-01-01", to: "2026-12-31").count, 62)
    }

    func testWeekContainingIsMondayAnchored() {
        // 2026-05-21 is a Thursday → Mon 18 … Sun 24.
        XCTAssertEqual(CalWindow.week(containing: "2026-05-21"), Window(from: "2026-05-18", to: "2026-05-24"))
        XCTAssertEqual(CalWindow.week(containing: "2026-05-18"), Window(from: "2026-05-18", to: "2026-05-24"))
        XCTAssertEqual(CalWindow.week(containing: "2026-05-24"), Window(from: "2026-05-18", to: "2026-05-24"))
        // Sunday 2026-05-17 belongs to the PREVIOUS Monday's week.
        XCTAssertEqual(CalWindow.week(containing: "2026-05-17"), Window(from: "2026-05-11", to: "2026-05-17"))
        XCTAssertEqual(CalWindow.week(containing: "bad"), Window(from: "bad", to: "bad"))
    }

    func testWeekOffsetMatchesTheWeekViewsPaging() {
        let thu = Time.civil(2026, 5, 21)
        XCTAssertEqual(CalWindow.week(offset: 0, today: thu), Window(from: "2026-05-18", to: "2026-05-24"))
        XCTAssertEqual(CalWindow.week(offset: 1, today: thu), Window(from: "2026-05-25", to: "2026-05-31"))
        XCTAssertEqual(CalWindow.week(offset: -2, today: thu), Window(from: "2026-05-04", to: "2026-05-10"))
    }

    func testMonthContaining() {
        XCTAssertEqual(CalWindow.month(containing: Time.civil(2026, 5, 21)), Window(from: "2026-05-01", to: "2026-05-31"))
        XCTAssertEqual(CalWindow.month(containing: Time.civil(2026, 2, 10)), Window(from: "2026-02-01", to: "2026-02-28"))
        XCTAssertEqual(CalWindow.month(containing: Time.civil(2028, 2, 1)), Window(from: "2028-02-01", to: "2028-02-29"))
        // Every month fits the server's 62-day cap.
        let w = CalWindow.month(containing: Time.civil(2026, 7, 4))
        XCTAssertLessThanOrEqual(CalWindow.days(from: w.from, to: w.to).count, 31)
    }
}

// MARK: - The read-only gate

final class CalLaneItemGuardTests: XCTestCase {

    func testOnlyMyOwnTaskBlocksAreEditable() {
        XCTAssertTrue(CalLaneItem.own(own("t", "09:00", 30)).isEditable)
        XCTAssertFalse(CalLaneItem.own(own("g", "09:00", 30, kind: .external)).isEditable)
        XCTAssertFalse(CalLaneItem.own(own("p", "09:00", 30, kind: .placeholder)).isEditable)
        // A shared block is NEVER editable — whatever its level or kind.
        XCTAssertFalse(CalLaneItem.shared(shared("s", "09:00", 30)).isEditable)
        var assigned = shared("s2", "09:00", 30)
        assigned.level = .assign
        XCTAssertFalse(CalLaneItem.shared(assigned).isEditable)
    }

    func testIdentityAndSharedFlag() {
        let o = CalLaneItem.own(own("abc", "09:00", 30))
        let s = CalLaneItem.shared(shared("abc", "09:00", 30))
        XCTAssertEqual(o.id, "own:abc")
        XCTAssertEqual(s.id, "shared:abc")
        XCTAssertNotEqual(o.id, s.id)   // the same uuid on both sides never collides
        XCTAssertFalse(o.isShared)
        XCTAssertTrue(s.isShared)
        XCTAssertEqual(s.startTime, "09:00")
        XCTAssertEqual(s.durationMinutes, 30)
    }
}

// MARK: - Merged lane layout

final class MergedLanesTests: XCTestCase {

    func testOverlappingOwnAndSharedSplitSideBySide() {
        let laid = mergedLanes(own: [own("mine", "09:00", 60)], shared: [shared("theirs", "09:30", 60)])
        XCTAssertEqual(laid.map(\.item.id), ["own:mine", "shared:theirs"])
        XCTAssertEqual(laid.map(\.lane), [0, 1])
        XCTAssertEqual(laid.map(\.lanes), [2, 2])
    }

    func testNonOverlappingStayFullWidth() {
        let laid = mergedLanes(own: [own("mine", "09:00", 30)], shared: [shared("theirs", "11:00", 30)])
        XCTAssertEqual(laid.map(\.lane), [0, 0])
        XCTAssertEqual(laid.map(\.lanes), [1, 1])
        XCTAssertEqual(laid[1].startMin, 11 * 60)
        XCTAssertEqual(laid[1].endMin, 11 * 60 + 30)
    }

    func testSkippedSharedOccurrencesAreDropped() {
        let laid = mergedLanes(own: [], shared: [shared("skip", "09:00", 30, skipped: true), shared("live", "10:00", 30)])
        XCTAssertEqual(laid.map(\.item.id), ["shared:live"])
    }

    func testSharedOnlyAndEmpty() {
        XCTAssertTrue(mergedLanes(own: [], shared: []).isEmpty)
        let laid = mergedLanes(own: [], shared: [shared("a", "09:00", 30), shared("b", "09:00", 30)])
        XCTAssertEqual(laid.map(\.lanes), [2, 2])
    }

    func testGenericPassMatchesTheCalBlockLayout() {
        let blocks = [own("a", "09:00", 60), own("b", "09:30", 60), own("c", "12:00", 15), own("d", "12:05", 5)]
        let classic = layoutLanes(blocks)
        let generic = layoutLanes(blocks, startTime: \.startTime, durationMinutes: \.durationMinutes)
        XCTAssertEqual(classic.map(\.block.id), generic.map(\.item.id))
        XCTAssertEqual(classic.map(\.lane), generic.map(\.lane))
        XCTAssertEqual(classic.map(\.lanes), generic.map(\.lanes))
        XCTAssertEqual(classic.map(\.startMin), generic.map(\.startMin))
        XCTAssertEqual(classic.map(\.endMin), generic.map(\.endMin))
    }

    func testZeroDurationStillOccupiesAMinute() {
        let laid = mergedLanes(own: [], shared: [shared("z", "09:00", 0)])
        XCTAssertEqual(laid[0].endMin, laid[0].startMin + 1)
    }
}

// MARK: - Month marks

final class MonthDayMarksTests: XCTestCase {

    func testCountsPlannedTaskBlocksAndSharedBlocks() {
        let marks = monthDayMarks(
            own: [own("t1", "09:00", 30), own("t2", "10:00", 30), own("g", "11:00", 30, kind: .external),
                  own("skip", "12:00", 30, skipped: true)],
            shared: [shared("s1", "09:00", 30), shared("s2", "10:00", 30, skipped: true)])
        XCTAssertEqual(marks, MonthDayMarks(planned: 2, shared: 1))
        XCTAssertFalse(marks.isEmpty)
    }

    func testEmptyDay() {
        let marks = monthDayMarks(own: [], shared: [])
        XCTAssertEqual(marks, MonthDayMarks(planned: 0, shared: 0))
        XCTAssertTrue(marks.isEmpty)
        // External-only + skipped-only still reads empty.
        XCTAssertTrue(monthDayMarks(own: [own("g", "09:00", 30, kind: .external)],
                                    shared: [shared("s", "09:00", 30, skipped: true)]).isEmpty)
    }
}
