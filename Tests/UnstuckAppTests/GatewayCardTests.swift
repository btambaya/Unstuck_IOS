// Unit tests for the gateway card's pure action logic (GatewayActions) and its
// dismiss/done bookkeeping (GatewayMomentState) — the iOS mirror of the
// gateway-card.tsx runAction/settle rules:
//   • carry_tasks is recurring-safe (tomorrow already taken → today's block is
//     SKIPPED, not moved), bumps moveCount on every real carry, and reports
//     nothing (nil) when nothing moved;
//   • schedule moves only the SOONEST live upcoming block, else creates a
//     fresh one, and does nothing for a task that no longer exists;
//   • a dismissal persists (cross-launch) and the ✓ done-state clears only for
//     the confirmation that set it;
//   • the brief/moment memo recomputes only when an input changes;
//   • the assistant's settings deep-link section parsing.

import XCTest
import UnstuckCore
@testable import Unstuck

@MainActor
final class GatewayCardTests: XCTestCase {
    private let today = "2026-09-02"
    private let tomorrow = "2026-09-03"
    private let nowISO = "2026-09-02T18:00:00.000Z"

    private func task(_ id: String, name: String = "Task", moveCount: Int? = nil, estimate: Int = 30,
                      recurrence: Recurrence? = nil) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: estimate, moveCount: moveCount, recurrence: recurrence,
                 createdAt: "2026-08-01T00:00:00.000Z", updatedAt: "2026-08-01T00:00:00.000Z")
    }

    private func block(_ id: String, task: String, date: String, time: String = "10:00",
                       done: Bool = false, skipped: Bool = false) -> CalBlock {
        CalBlock(id: id, taskId: task, taskName: "n", startTime: time, durationMinutes: 30, date: date,
                 kind: .task, done: done, skipped: skipped)
    }

    // MARK: carry_tasks

    func testCarryMovesTodaysBlockToTomorrowAndBumpsMoveCount() {
        let t = task("t1", moveCount: nil)
        let b = block("b1", task: "t1", date: today)
        let w = GatewayActions.carryTasks(taskIds: ["t1"], tasks: [t], blocks: [b],
                                          todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.blocks[0].id, "b1")
        XCTAssertEqual(w.blocks[0].date, tomorrow, "the block itself moves — no duplicate")
        XCTAssertFalse(w.blocks[0].skipped)
        XCTAssertEqual(w.tasks.count, 1)
        XCTAssertEqual(w.tasks[0].moveCount, 1, "an honest slip counter is what makes Slip Radar honest")
        XCTAssertEqual(w.tasks[0].updatedAt, nowISO)
        XCTAssertEqual(w.confirmation, "Carried 1 to tomorrow.")
    }

    func testCarryIsRecurringSafeWhenTomorrowAlreadyHasAnOccurrence() {
        let t = task("r1", moveCount: 2, recurrence: .daily(until: nil))
        let todayOcc = block("o-today", task: "r1", date: today)
        let tomorrowOcc = block("o-tomorrow", task: "r1", date: tomorrow)
        let w = GatewayActions.carryTasks(taskIds: ["r1"], tasks: [t], blocks: [todayOcc, tomorrowOcc],
                                          todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.blocks[0].id, "o-today")
        XCTAssertEqual(w.blocks[0].date, today, "today's occurrence stays on today…")
        XCTAssertTrue(w.blocks[0].skipped, "…but is marked skipped — same outcome, no double-up")
        XCTAssertEqual(w.tasks[0].moveCount, 3, "still counts as a move")
        XCTAssertEqual(w.confirmation, "Carried 1 to tomorrow.")
    }

    func testCarryTreatsASkippedTomorrowAsFree() {
        let t = task("t1")
        let todayB = block("b1", task: "t1", date: today)
        let skippedTomorrow = block("b2", task: "t1", date: tomorrow, skipped: true)
        let w = GatewayActions.carryTasks(taskIds: ["t1"], tasks: [t], blocks: [todayB, skippedTomorrow],
                                          todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
        XCTAssertEqual(w.blocks[0].date, tomorrow, "a skipped tomorrow doesn't count as taken")
        XCTAssertFalse(w.blocks[0].skipped)
    }

    func testCarryOnlyWhatWasActuallyOnToday() {
        let t1 = task("t1"), t2 = task("t2"), t3 = task("t3")
        let done = block("b1", task: "t1", date: today, done: true)
        let yesterday = block("b2", task: "t2", date: "2026-09-01")
        let live = block("b3", task: "t3", date: today)
        let w = GatewayActions.carryTasks(taskIds: ["t1", "t2", "t3", "ghost"], tasks: [t1, t2, t3],
                                          blocks: [done, yesterday, live],
                                          todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
        XCTAssertEqual(w.blocks.map(\.id), ["b3"], "done / other-day / unknown tasks are left alone")
        XCTAssertEqual(w.tasks.map(\.id), ["t3"])
        XCTAssertEqual(w.confirmation, "Carried 1 to tomorrow.")
    }

    func testCarryNothingIsHonest() {
        let w = GatewayActions.carryTasks(taskIds: ["t1"], tasks: [task("t1")], blocks: [],
                                          todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
        XCTAssertTrue(w.blocks.isEmpty)
        XCTAssertTrue(w.tasks.isEmpty)
        XCTAssertNil(w.confirmation, "nothing moved → no ✓ (\"Carried 0 to tomorrow\" was a lie) and the moment stays up")
    }

    // MARK: schedule

    func testScheduleMovesALiveUpcomingBlock() {
        let t = task("t1", name: "Gym")
        let anchor = block("b1", task: "t1", date: "2026-09-04", time: "18:00")
        let w = GatewayActions.schedule(taskId: "t1", date: "2026-09-05", time: "07:30", tasks: [t], blocks: [anchor],
                                        todayIso: today, newId: "new")
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.blocks[0].id, "b1", "reuses the live block — no duplicate")
        XCTAssertEqual(w.blocks[0].date, "2026-09-05")
        XCTAssertEqual(w.blocks[0].startTime, "07:30")
        XCTAssertTrue(w.tasks.isEmpty, "schedule never bumps moveCount (web parity)")
        XCTAssertEqual(w.confirmation, "Blocked — Gym, 2026-09-05 07:30.")
    }

    func testScheduleKeepsAnchorTimeWhenNoneGiven() {
        let anchor = block("b1", task: "t1", date: "2026-09-04", time: "18:00")
        let w = GatewayActions.schedule(taskId: "t1", date: "2026-09-05", time: nil, tasks: [task("t1")],
                                        blocks: [anchor], todayIso: today, newId: "new")
        XCTAssertEqual(w.blocks[0].startTime, "18:00")
        XCTAssertEqual(w.confirmation, "Blocked — Task, 2026-09-05.")
    }

    func testScheduleAnchorsTheSoonestLiveBlockNotStoreOrder() {
        let t = task("t1", name: "Gym")
        let later = block("b-later", task: "t1", date: "2026-09-10", time: "08:00")
        let soonerLateInDay = block("b-soon-pm", task: "t1", date: "2026-09-04", time: "18:00")
        let soonerEarly = block("b-soon-am", task: "t1", date: "2026-09-04", time: "07:00")
        let w = GatewayActions.schedule(taskId: "t1", date: "2026-09-05", time: nil, tasks: [t],
                                        blocks: [later, soonerLateInDay, soonerEarly], todayIso: today, newId: "new")
        XCTAssertEqual(w.blocks.map(\.id), ["b-soon-am"], "min by (date, startTime) — not the first in store order")
        XCTAssertEqual(w.blocks[0].startTime, "07:00")
    }

    func testScheduleDoesNothingForATaskThatNoLongerExists() {
        let orphan = block("b1", task: "gone", date: "2026-09-04")
        let w = GatewayActions.schedule(taskId: "gone", date: "2026-09-05", time: "09:00", tasks: [task("other")],
                                        blocks: [orphan], todayIso: today, newId: "new")
        XCTAssertTrue(w.blocks.isEmpty, "no block titled “Task” for a ghost")
        XCTAssertTrue(w.tasks.isEmpty)
        XCTAssertNil(w.confirmation)
    }

    func testScheduleIgnoresSkippedAndHistoricalBlocksAndCreatesFresh() {
        let t = task("t1", name: "Gym", estimate: 45)
        let skipped = block("b1", task: "t1", date: "2026-09-04", skipped: true)
        let past = block("b2", task: "t1", date: "2026-08-20")
        let w = GatewayActions.schedule(taskId: "t1", date: "2026-09-05", time: nil, tasks: [t],
                                        blocks: [skipped, past], todayIso: today, newId: "fresh")
        XCTAssertEqual(w.blocks.count, 1)
        let b = w.blocks[0]
        XCTAssertEqual(b.id, "fresh", "history is never dragged around — a fresh block instead")
        XCTAssertEqual(b.taskId, "t1")
        XCTAssertEqual(b.taskName, "Gym")
        XCTAssertEqual(b.date, "2026-09-05")
        XCTAssertEqual(b.startTime, "09:00", "default time")
        XCTAssertEqual(b.durationMinutes, 45, "task estimate")
        XCTAssertEqual(b.kind, .task)
    }

    // MARK: create_task

    func testCreateTaskDefaultsEstimateTo25() {
        let w = GatewayActions.createTask(name: "Get Maleek’s birthday gift", estimateMin: nil, id: "n1", nowISO: nowISO)
        XCTAssertEqual(w.tasks.count, 1)
        XCTAssertEqual(w.tasks[0].id, "n1")
        XCTAssertEqual(w.tasks[0].name, "Get Maleek’s birthday gift")
        XCTAssertEqual(w.tasks[0].estimateMin, 25)
        XCTAssertFalse(w.tasks[0].done)
        XCTAssertEqual(w.tasks[0].createdAt, nowISO)
        XCTAssertTrue(w.blocks.isEmpty)
        XCTAssertEqual(w.confirmation, "Added “Get Maleek’s birthday gift”.")
    }

    func testCreateTaskHonoursAGivenEstimate() {
        let w = GatewayActions.createTask(name: "X", estimateMin: 10, id: "n1", nowISO: nowISO)
        XCTAssertEqual(w.tasks[0].estimateMin, 10)
    }

    // MARK: dismiss persistence + done state

    func testSettlePersistsTheDismissalMergedWithDisk() {
        var persisted: [Set<String>] = []
        let s = GatewayMomentState(dismissed: ["a"], persist: { persisted.append($0) })
        s.settle("b", confirmation: "Carried 2 to tomorrow.", alreadyOnDisk: ["c"])
        XCTAssertTrue(s.isDismissed("b"))
        XCTAssertTrue(s.isDismissed("a"))
        XCTAssertTrue(s.isDismissed("c"), "another surface's dismissals since mount are kept")
        XCTAssertEqual(persisted, [["a", "b", "c"]], "written through once, as the merged set")
        XCTAssertEqual(s.momentDone, "Carried 2 to tomorrow.")
    }

    func testDismissWithoutConfirmationShowsNoDoneLine() {
        let s = GatewayMomentState(dismissed: [], persist: { _ in })
        s.settle("evening-sweep:2026-09-02", confirmation: nil)
        XCTAssertTrue(s.isDismissed("evening-sweep:2026-09-02"))
        XCTAssertNil(s.momentDone)
    }

    func testDoneStateClearsOnlyForItsOwnConfirmation() {
        let s = GatewayMomentState(dismissed: [], persist: { _ in })
        s.settle("m1", confirmation: "Added “X”.")
        s.clearDone(if: "Carried 1 to tomorrow.")
        XCTAssertEqual(s.momentDone, "Added “X”.", "an older timer must not wipe a newer ✓")
        s.clearDone(if: "Added “X”.")
        XCTAssertNil(s.momentDone, "the ✓ is a moment, not a mute button — the next moment can surface")
    }

    func testANewerActionReplacesTheDoneLine() {
        let s = GatewayMomentState(dismissed: [], persist: { _ in })
        s.settle("m1", confirmation: "first")
        s.settle("m2", confirmation: "second")
        XCTAssertEqual(s.momentDone, "second")
        s.clearDone(if: "first")
        XCTAssertEqual(s.momentDone, "second")
        XCTAssertTrue(s.isDismissed("m1") && s.isDismissed("m2"))
    }

    // MARK: brief / moment memo (C7)

    func testMemoComputesOncePerDistinctKey() {
        let memo = GatewayMemo<Int, String>()
        var calls = 0
        XCTAssertEqual(memo.value(for: 1) { calls += 1; return "one" }, "one")
        XCTAssertEqual(memo.value(for: 1) { calls += 1; return "again" }, "one", "same key → cached, closure not run")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(memo.value(for: 2) { calls += 1; return "two" }, "two")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(memo.computeCount, 2)
    }

    func testInputsKeyChangesOnlyWhenAnEngineInputChanges() {
        let base = GatewayInputs(tasks: [task("t1")], blocks: [block("b1", task: "t1", date: today)], sessions: [],
                                 facts: [], struggles: ["Starting"], rituals: .defaults, dismissed: [],
                                 todayIso: today, minute: 100)
        XCTAssertEqual(base, base)
        var typed = base                     // a keystroke in the composer changes none of these
        typed.minute = 100
        XCTAssertEqual(typed, base)
        var dismissed = base
        dismissed.dismissed = ["evening-sweep:2026-09-02"]
        XCTAssertNotEqual(dismissed, base)
        var nextMinute = base
        nextMinute.minute = 101
        XCTAssertNotEqual(nextMinute, base, "the time-gated moments move once a minute")
        var moved = base
        moved.tasks = [task("t1", moveCount: 3)]
        XCTAssertNotEqual(moved, base)
        let t0 = Date(timeIntervalSince1970: 60 * 1000 + 5)
        let t1 = Date(timeIntervalSince1970: 60 * 1000 + 59)
        let t2 = Date(timeIntervalSince1970: 60 * 1001)
        XCTAssertEqual(GatewayInputs.minute(of: t0), GatewayInputs.minute(of: t1))
        XCTAssertNotEqual(GatewayInputs.minute(of: t1), GatewayInputs.minute(of: t2))
    }

    // MARK: assistant routing helpers (C2)

    func testSettingsSectionParsing() {
        XCTAssertNil(AppModel.settingsSection(in: "unstuck://settings"))
        XCTAssertEqual(AppModel.settingsSection(in: "unstuck://settings?section=People"), "People")
        XCTAssertEqual(AppModel.settingsSection(in: "unstuck://settings?section=notifications"), "Notifications")
        XCTAssertEqual(AppModel.settingsSection(in: "unstuck://settings?section=Areas"), "Areas")
        XCTAssertEqual(AppModel.settingsSection(in: "unstuck://settings?section=tags"), "Areas")
        XCTAssertEqual(AppModel.settingsSection(in: "unstuck://settings?section=Interface"), "Interface")
        XCTAssertNil(AppModel.settingsSection(in: "unstuck://settings?section=bogus"), "unknown → the hub")
        XCTAssertEqual(AppModel.calendarMode(for: "week"), .week)
        XCTAssertEqual(AppModel.calendarMode(for: "Month"), .month)
        XCTAssertEqual(AppModel.calendarMode(for: "day"), .day)
    }

    // MARK: prefs bridge — cross-launch persistence (web keys + shapes)

    private func freshDefaults() -> UserDefaults {
        let name = "test.gateway.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDismissalsSurviveARelaunch() {
        let d = freshDefaults()
        let first = PAPrefs(defaults: d)
        first.dismiss("evening-sweep:2026-09-02")
        first.dismiss("slip-radar:t1:3")
        first.dismiss("slip-radar:t1:3")   // idempotent
        let relaunched = PAPrefs(defaults: d)
        XCTAssertEqual(relaunched.dismissed, ["evening-sweep:2026-09-02", "slip-radar:t1:3"])
        XCTAssertTrue(relaunched.isDismissed("slip-radar:t1:3"))
        // Same on-disk shape as the web (a JSON string array under the web key).
        XCTAssertEqual(d.string(forKey: PAPrefsStore.dismissedKey), #"["evening-sweep:2026-09-02","slip-radar:t1:3"]"#)
    }

    func testDismissedListIsCappedAtTheNewest200() {
        let d = freshDefaults()
        PAPrefsStore.setDismissed((0..<250).map { "m\($0)" }, d)
        let prefs = PAPrefs(defaults: d)
        XCTAssertEqual(prefs.dismissed.count, 200)
        XCTAssertEqual(prefs.dismissed.first, "m50")
        XCTAssertEqual(prefs.dismissed.last, "m249")
        prefs.dismiss("m250")
        XCTAssertEqual(prefs.dismissed.count, 200)
        XCTAssertEqual(prefs.dismissed.first, "m51")
        XCTAssertEqual(prefs.dismissed.last, "m250")
    }

    func testRitualPrefsDefaultAndPersistLikeTheWeb() {
        let d = freshDefaults()
        let prefs = PAPrefs(defaults: d)
        XCTAssertEqual(prefs.rituals, .defaults, "morning + evening on, weekly ones opt-in")
        prefs.setRitual(.friday, on: true)
        prefs.setRitual(.morning, on: false)
        let relaunched = PAPrefs(defaults: d)
        XCTAssertTrue(relaunched.rituals.friday)
        XCTAssertFalse(relaunched.rituals.morning)
        XCTAssertTrue(relaunched.rituals.evening)
        // A partial blob written by the web keeps the defaults for what it omits.
        d.set(#"{"sunday":true}"#, forKey: PAPrefsStore.ritualsKey)
        let fromWeb = PAPrefs(defaults: d)
        XCTAssertTrue(fromWeb.rituals.sunday)
        XCTAssertTrue(fromWeb.rituals.morning)
        XCTAssertFalse(fromWeb.rituals.friday)
        // The set_ritual tool path (a NAME from the model) lands in the same store.
        XCTAssertTrue(PAPrefsStore.setRitual("friday", on: true, d))
        XCTAssertFalse(PAPrefsStore.setRitual("weekly", on: true, d))
        fromWeb.reload()
        XCTAssertTrue(fromWeb.rituals.friday)
    }

    func testScrubResetsBothForTheNextAccount() {
        let d = freshDefaults()
        let prefs = PAPrefs(defaults: d)
        prefs.setRitual(.sunday, on: true)
        prefs.dismiss("x")
        prefs.scrub()
        XCTAssertEqual(prefs.rituals, .defaults)
        XCTAssertTrue(prefs.dismissed.isEmpty)
        XCTAssertNil(d.object(forKey: PAPrefsStore.ritualsKey))
        XCTAssertNil(d.object(forKey: PAPrefsStore.dismissedKey))
    }
}
