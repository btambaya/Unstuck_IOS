// ReminderScheduler decision logic (spec 10 §1.2) — the pure
// planReminders port of Android ReminderScheduler.sync(), plus the
// NotificationLevel gates, the Notification Center's Upcoming
// computation, the relative-time labels, and the accent mapping.

import XCTest
@testable import UnstuckCore

final class NotificationLevelTests: XCTestCase {
    func testCalmGates() {
        let l = NotificationLevel.calm
        XCTAssertFalse(l.atStart)
        XCTAssertFalse(l.drifted)
        XCTAssertFalse(l.pausedCheckin)
        XCTAssertFalse(l.morningBrief)
        XCTAssertFalse(l.nudges)
    }

    func testBalancedGates() {
        let l = NotificationLevel.balanced
        XCTAssertTrue(l.atStart)
        XCTAssertFalse(l.drifted)
        XCTAssertTrue(l.pausedCheckin)
        XCTAssertTrue(l.morningBrief)
        XCTAssertTrue(l.nudges)
    }

    func testCoachGates() {
        let l = NotificationLevel.coach
        XCTAssertTrue(l.atStart)
        XCTAssertTrue(l.drifted)
        XCTAssertTrue(l.pausedCheckin)
        XCTAssertTrue(l.morningBrief)
        XCTAssertTrue(l.nudges)
    }

    func testFromLabelFallsBackToBalanced() {
        XCTAssertEqual(NotificationLevel.fromLabel("Calm"), .calm)
        XCTAssertEqual(NotificationLevel.fromLabel("Coach"), .coach)
        XCTAssertEqual(NotificationLevel.fromLabel("???"), .balanced)
        XCTAssertEqual(NotificationLevel.fromLabel(""), .balanced)
    }
}

final class PlanRemindersTests: XCTestCase {
    /// A local-zone datetime as epoch ms (planReminders computes block
    /// starts in the device's local zone, matching Android).
    private func localMs(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Double {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!.timeIntervalSince1970 * 1000
    }

    private let now = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 21; c.hour = 7; c.minute = 0
        return Calendar.current.date(from: c)!.timeIntervalSince1970 * 1000
    }()

    private func keys(_ plans: [PlannedReminder]) -> Set<String> { Set(plans.map(\.key)) }

    func testCoachArmsAllThreeForAnUpcomingTaskBlock() {
        let b = mkBlock(id: "b1", taskId: "t1", startTime: "09:00", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .coach, globalLeadMin: 10, now: now)
        XCTAssertEqual(keys(plans), ["lead:b1", "atstart:b1", "drifted:b1"])
        let lead = plans.first { $0.kind == .lead }!
        let atstart = plans.first { $0.kind == .atstart }!
        let drifted = plans.first { $0.kind == .drifted }!
        let start = localMs(2026, 5, 21, 9, 0)
        XCTAssertEqual(lead.fireAt, start - 10 * 60_000)
        XCTAssertEqual(lead.leadMinutes, 10)
        XCTAssertEqual(atstart.fireAt, start)
        XCTAssertEqual(drifted.fireAt, start + REMINDER_DRIFT_MS)
    }

    func testBalancedSkipsDrifted() {
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .balanced, globalLeadMin: 10, now: now)
        XCTAssertEqual(keys(plans), ["lead:b1", "atstart:b1"])
    }

    func testCalmArmsLeadOnly() {
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .calm, globalLeadMin: 10, now: now)
        XCTAssertEqual(keys(plans), ["lead:b1"])
    }

    func testLeadZeroIsNeverArmed() {
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .balanced, globalLeadMin: 0, now: now)
        XCTAssertEqual(keys(plans), ["atstart:b1"])
    }

    func testDoneTaskSchedulesNothing() {
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1", done: true)],
                                  level: .coach, globalLeadMin: 10, now: now)
        XCTAssertTrue(plans.isEmpty)
    }

    func testExternalEventGetsOnlyALeadWithGlobalLead() {
        // External calendar events have a blank task id — the LEAD is keyed
        // off the block id, and atstart/drifted never arm.
        let b = CalBlock(id: "g_evt", taskId: nil, taskName: "Standup", startTime: "09:00",
                         durationMinutes: 30, date: "2026-05-21",
                         externalEventId: "evt", kind: .external)
        let plans = planReminders(blocks: [b], tasks: [], level: .coach,
                                  globalLeadMin: 15, overrides: ["": 5], now: now)
        XCTAssertEqual(keys(plans), ["lead:g_evt"])
        XCTAssertEqual(plans[0].leadMinutes, 15)
        XCTAssertEqual(plans[0].taskId, "")
    }

    func testPlaceholderBlocksAreSkipped() {
        let b = mkBlock(id: "b1", taskId: "placeholder", date: "2026-05-21", kind: .placeholder)
        let plans = planReminders(blocks: [b], tasks: [], level: .coach, globalLeadMin: 10, now: now)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPerTaskOverrideBeatsGlobalLead() {
        let b = mkBlock(id: "b1", taskId: "t1", startTime: "09:00", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .calm, globalLeadMin: 10, overrides: ["t1": 5], now: now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].leadMinutes, 5)
        XCTAssertEqual(plans[0].fireAt, localMs(2026, 5, 21, 9, 0) - 5 * 60_000)
    }

    func testOverrideZeroDisablesLead() {
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .calm, globalLeadMin: 10, overrides: ["t1": 0], now: now)
        XCTAssertTrue(plans.isEmpty)
    }

    func testPastFireTimesAreDropped() {
        // Block at 06:00, now 07:00 → lead + atstart in the past; only the
        // drift (06:10) is also past. Nothing arms.
        let b = mkBlock(id: "b1", taskId: "t1", startTime: "06:00", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .coach, globalLeadMin: 10, now: now)
        XCTAssertTrue(plans.isEmpty)
    }

    func testBeyondHorizonIsDropped() {
        // 3 days out > the 48h horizon.
        let b = mkBlock(id: "b1", taskId: "t1", startTime: "09:00", date: "2026-05-24")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .coach, globalLeadMin: 10, now: now)
        XCTAssertTrue(plans.isEmpty)
    }

    func testFocusedTaskSuppressesAtStartAndDriftedButKeepsLead() {
        // The gotcha-8 inversion: starting Focus on the task cancels its
        // pending starts-now / drift requests on the next re-sync.
        let b = mkBlock(id: "b1", taskId: "t1", date: "2026-05-21")
        let plans = planReminders(blocks: [b], tasks: [mkTask(id: "t1")],
                                  level: .coach, globalLeadMin: 10, liveTaskId: "t1", now: now)
        XCTAssertEqual(keys(plans), ["lead:b1"])
    }

    func testKeyMatchesAndroidTagBlockIdScheme() {
        let p = PlannedReminder(kind: .atstart, blockId: "b9", taskId: "t9",
                                taskName: "X", fireAt: 0, leadMinutes: 0)
        XCTAssertEqual(p.key, "atstart:b9")
    }

    func testCopyHelpers() {
        XCTAssertEqual(reminderLeadBody(taskName: "Write spec", leadMin: 10), "Write spec — in 10 minutes.")
        XCTAssertEqual(taskStartingTitle(drifted: false), "Time to start")
        XCTAssertEqual(taskStartingTitle(drifted: true), "Didn't get to it?")
        XCTAssertEqual(taskStartingBody(taskName: "Write spec", drifted: false), "\u{201C}Write spec\u{201D} starts now.")
        XCTAssertEqual(taskStartingBody(taskName: "Write spec", drifted: true),
                       "\u{201C}Write spec\u{201D} was set for a little while ago — want to start now?")
        XCTAssertEqual(reminderDeepLink(taskId: "t1"), "unstuck://task/t1")
        XCTAssertEqual(reminderDeepLink(taskId: ""), "unstuck://today")
    }
}

final class UpcomingRemindersTests: XCTestCase {
    private let now = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 21; c.hour = 7; c.minute = 0
        return Calendar.current.date(from: c)!.timeIntervalSince1970 * 1000
    }()

    func testFiltersSortsAndDedupes() {
        let blocks = [
            mkBlock(id: "b2", taskId: "t2", taskName: "Later", startTime: "11:00", date: "2026-05-21"),
            mkBlock(id: "b1", taskId: "t1", taskName: "Soon", startTime: "09:00", date: "2026-05-21"),
            // duplicate (task, time) — de-duped
            mkBlock(id: "b1x", taskId: "t1", taskName: "Soon", startTime: "09:00", date: "2026-05-21"),
            // done task — skipped
            mkBlock(id: "b3", taskId: "t3", taskName: "Done", startTime: "10:00", date: "2026-05-21"),
            // past — skipped
            mkBlock(id: "b4", taskId: "t4", taskName: "Past", startTime: "06:00", date: "2026-05-21"),
            // beyond 48h — skipped
            mkBlock(id: "b5", taskId: "t5", taskName: "Far", startTime: "09:00", date: "2026-05-25"),
            // external — skipped (Upcoming lists task reminders only)
            CalBlock(id: "g_1", taskId: nil, taskName: "Ext", startTime: "12:00",
                     durationMinutes: 30, date: "2026-05-21", externalEventId: "e", kind: .external),
        ]
        let tasks = [mkTask(id: "t1"), mkTask(id: "t2"), mkTask(id: "t3", done: true),
                     mkTask(id: "t4"), mkTask(id: "t5")]
        let up = upcomingReminders(blocks: blocks, tasks: tasks, now: now)
        XCTAssertEqual(up.map(\.name), ["Soon", "Later"])
        XCTAssertEqual(up.map(\.taskId), ["t1", "t2"])
    }

    func testCapsAtTwenty() {
        let blocks = (0..<30).map { i in
            mkBlock(id: "b\(i)", taskId: "t\(i)", startTime: String(format: "%02d:%02d", 9 + i / 60, i % 60),
                    date: "2026-05-21")
        }
        let tasks = (0..<30).map { mkTask(id: "t\($0)") }
        XCTAssertEqual(upcomingReminders(blocks: blocks, tasks: tasks, now: now).count, 20)
    }
}

final class RelativeTimeTests: XCTestCase {
    func testRelFuture() {
        XCTAssertEqual(relFuture(35 * 60_000), "in 35m")
        XCTAssertEqual(relFuture(4 * 3_600_000), "in 4h")
        XCTAssertEqual(relFuture(2 * 86_400_000), "in 2d")
        XCTAssertEqual(relFuture(-5_000), "in 0m")
    }

    func testRelPast() {
        XCTAssertEqual(relPast(10_000), "just now")
        XCTAssertEqual(relPast(5 * 60_000), "5m ago")
        XCTAssertEqual(relPast(3 * 3_600_000), "3h ago")
        XCTAssertEqual(relPast(2 * 86_400_000), "2d ago")
    }
}

final class NotificationAccentTests: XCTestCase {
    func testAccentByKind() {
        XCTAssertEqual(notificationAccent(kind: "paused_checkin"), .amber)
        XCTAssertEqual(notificationAccent(kind: "atstart"), .amber)
        XCTAssertEqual(notificationAccent(kind: "drifted"), .amber)
        XCTAssertEqual(notificationAccent(kind: "session_recap"), .green)
        XCTAssertEqual(notificationAccent(kind: "morning_brief"), .primaryDeep)
        XCTAssertEqual(notificationAccent(kind: "evening_preview"), .primaryDeep)
        XCTAssertEqual(notificationAccent(kind: "daily_nudge"), .primaryDeep)
        XCTAssertEqual(notificationAccent(kind: "collection_share"), .coral)
        XCTAssertEqual(notificationAccent(kind: "anything"), .coral)
    }
}
