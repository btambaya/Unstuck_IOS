// Round-2 cross-platform parity fixes — the pure decision helpers behind:
//  • the PKCE recovery probe (spent ONLY by a code-exchange .signedIn whose
//    token differs from the one in hand — never the stored-session
//    .initialSession, which used to classify the reset link against the OLD
//    token and skip the set-new-password screen);
//  • wake-window calibration (one sample per local day, the FIRST input —
//    a failed write retries with the same time, never a later one);
//  • the paused check-in budget settled at FIRE time (a quick pause/resume
//    must not burn one of the 3 daily push slots);
//  • Focus screen re-entry adopting a live session AS-IS (a paused session
//    stays paused; a different occurrence of the same template mints);
//  • the pending shared-focus ledger parked per user across sign-out;
//  • the owner's local members merge after share / list;
//  • the refused shared-list RPC message.

import UIKit
import XCTest
import UnstuckCore
import UnstuckData
import UnstuckSync
@testable import Unstuck

final class RecoveryProbeTests: XCTestCase {
    func testStoredSessionInitialSessionDoesNotSpendTheProbe() {
        XCTAssertFalse(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: false, armedToken: "old", token: "old"))
        XCTAssertFalse(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: false, armedToken: nil, token: "old"),
                       "an .initialSession replay is never the exchange, even with no token in hand")
    }

    func testSignedInWithTheSameTokenIsNotTheExchange() {
        // A .signedIn re-emitted for the session already in hand (SDK replay).
        XCTAssertFalse(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: true, armedToken: "old", token: "old"))
    }

    func testSignedInWithANewTokenIsTheExchange() {
        XCTAssertTrue(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: true, armedToken: "old", token: "fresh"))
        XCTAssertTrue(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: true, armedToken: nil, token: "fresh"),
                      "signed out when the link was tapped: the first .signedIn is the exchange")
    }

    func testSignedInWithoutATokenIsIgnored() {
        XCTAssertFalse(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: true, armedToken: nil, token: nil))
        XCTAssertFalse(AppModel.shouldConsumeRecoveryProbe(isSignedInEvent: true, armedToken: nil, token: ""))
    }
}

final class WakeWindowSampleToSendTests: XCTestCase {
    private func sample(_ date: String, _ time: String) -> WakeWindowSample {
        WakeWindowSample(localDate: date, firstInputLocal: time, weekday: 1)
    }

    func testFirstForegroundOfTheDaySendsNow() {
        let now = sample("2026-06-08", "06:10")
        XCTAssertEqual(AppModel.wakeWindowSampleToSend(lastRecordedDate: "2026-06-07", pending: nil, now: now), now)
        XCTAssertEqual(AppModel.wakeWindowSampleToSend(lastRecordedDate: nil, pending: nil, now: now), now)
    }

    func testNothingOnceTodayIsRecorded() {
        let now = sample("2026-06-08", "14:00")
        XCTAssertNil(AppModel.wakeWindowSampleToSend(lastRecordedDate: "2026-06-08", pending: nil, now: now))
        XCTAssertNil(AppModel.wakeWindowSampleToSend(lastRecordedDate: "2026-06-08",
                                                     pending: sample("2026-06-08", "06:10"), now: now))
    }

    func testARetryReportsTheStashedFirstInputNotALaterTime() {
        // 06:10 write failed offline; the 14:00 foreground must retry 06:10.
        let first = sample("2026-06-08", "06:10")
        let later = sample("2026-06-08", "14:00")
        XCTAssertEqual(AppModel.wakeWindowSampleToSend(lastRecordedDate: "2026-06-07", pending: first, now: later), first)
    }

    func testAStaleStashFromYesterdayIsIgnored() {
        let stale = sample("2026-06-07", "06:10")
        let now = sample("2026-06-08", "07:30")
        XCTAssertEqual(AppModel.wakeWindowSampleToSend(lastRecordedDate: nil, pending: stale, now: now), now)
    }

    /// A call ringing a locked phone boots the model in the background
    /// (startWithoutScene, audit 2026-09-22 C16) — that's not the day's
    /// first input.
    func testABackgroundLaunchIsNeverTheDaysFirstInput() {
        XCTAssertFalse(AppModel.isWakeSignal(.background))
        XCTAssertTrue(AppModel.isWakeSignal(.active))
        XCTAssertTrue(AppModel.isWakeSignal(.inactive))
    }
}

final class PausedCheckinBudgetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "PausedCheckinBudgetTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFiredIsTheArmedInstantHavingPassed() {
        XCTAssertFalse(PausedCheckinBudget.fired(fireAt: nil, now: 1_000), "nothing armed")
        XCTAssertFalse(PausedCheckinBudget.fired(fireAt: 0, now: 1_000))
        XCTAssertFalse(PausedCheckinBudget.fired(fireAt: 1_840, now: 1_000), "a quick pause/resume: not delivered → NOT consumed")
        XCTAssertTrue(PausedCheckinBudget.fired(fireAt: 1_840, now: 1_840))
        XCTAssertTrue(PausedCheckinBudget.fired(fireAt: 1_840, now: 5_000), "the nag reached the lock screen → its slot is owed")
    }

    func testHasFiredReadsTheMarkerAndClearMarkerForgetsIt() {
        let armed = Date(timeIntervalSince1970: 1_000)
        defaults.set(armed.timeIntervalSince1970 + PausedCheckinBudget.delay, forKey: PausedCheckinBudget.fireAtKey)
        XCTAssertFalse(PausedCheckinBudget.hasFired(now: armed.addingTimeInterval(60), defaults: defaults))
        XCTAssertTrue(PausedCheckinBudget.hasFired(now: armed.addingTimeInterval(15 * 60), defaults: defaults))
        PausedCheckinBudget.clearMarker(defaults: defaults)
        XCTAssertFalse(PausedCheckinBudget.hasFired(now: armed.addingTimeInterval(15 * 60), defaults: defaults))
    }

    func testDelayMatchesTheLocalNotificationTrigger() {
        XCTAssertEqual(PausedCheckinBudget.delay, 14 * 60)
    }
}

@MainActor
final class FocusReentryTests: XCTestCase {
    private func live(taskId: String, occurrence: String? = nil, paused: Bool) -> LiveSession {
        var s = FocusTimer.start(.empty, taskId: taskId, estimateMin: 25, now: 1_000_000, occurrenceBlockId: occurrence)
        if paused { s = FocusTimer.pause(s, now: 1_060_000) }
        return s
    }

    func testReopeningTheSameSessionAttachesAsIs() {
        XCTAssertTrue(FocusModel.reopensExistingSession(live(taskId: "t1", paused: true), focusId: "t1", occurrenceBlockId: nil))
        XCTAssertTrue(FocusModel.reopensExistingSession(live(taskId: "t1", paused: false), focusId: "t1", occurrenceBlockId: nil))
        XCTAssertTrue(FocusModel.reopensExistingSession(live(taskId: "tpl", occurrence: "mon", paused: true),
                                                        focusId: "tpl", occurrenceBlockId: "mon"))
    }

    func testAnotherTaskOrOccurrenceOrNoSessionMints() {
        XCTAssertFalse(FocusModel.reopensExistingSession(live(taskId: "t1", paused: true), focusId: "t2", occurrenceBlockId: nil))
        XCTAssertFalse(FocusModel.reopensExistingSession(live(taskId: "tpl", occurrence: "mon", paused: true),
                                                         focusId: "tpl", occurrenceBlockId: "tue"),
                       "Tuesday's occurrence must not resume Monday's paused session")
        XCTAssertFalse(FocusModel.reopensExistingSession(.empty, focusId: "t1", occurrenceBlockId: nil))
    }

    func testOpeningTheFocusScreenOnAPausedSessionKeepsItPaused() throws {
        // The bug: FocusModel.init ran FocusTimer.start, whose same-task+paused
        // branch is `resume` — a mere tap on the Today card un-paused the
        // session (and, co-focused, broadcast a rev+1 resume nobody pressed).
        let db = try AppDatabase.makeInMemory()
        let store = LiveSessionStore(db)
        let paused = live(taskId: "t1", paused: true)
        try store.set(paused)
        let task = TaskItem(id: "t1", name: "Write", estimateMin: 25,
                            createdAt: "2026-06-01T00:00:00.000Z", updatedAt: "2026-06-01T00:00:00.000Z")
        let fm = FocusModel(task: task, store: store)
        XCTAssertTrue(fm.live.paused, "re-entry adopts the paused session as-is")
        XCTAssertEqual(fm.live.id, paused.id, "same session, not a fresh mint")
        XCTAssertEqual(try store.get()?.paused, true)
        // Resume stays an explicit gesture.
        fm.resume()
        XCTAssertFalse(fm.live.paused)
    }
}

/// A repeating task's focus starts from ITS day, never the series' lifetime
/// total (web/Android audit 2026-09-23, W10/A13). Every occurrence session
/// accrues onto the TEMPLATE's totalFocused, so from day 2 that number is
/// the whole series' history: seeded into the ring, day 4 of a 25-min habit
/// opened at 75:00 — overrun from the first second, the over-time prompt and
/// the spoken coach firing at once. Both the Focus screen (FocusModel) and
/// the assistant's start_focus (startFocusJoinOrMint) seeded it.
@MainActor
final class RepeatingFocusPriorTests: XCTestCase {
    private let stamp = "2026-09-01T08:00:00.000Z"
    private var today: String { Clock.todayISO() }

    /// Day 4 of a daily 25-min habit focused 25 min on each of 3 days.
    private func series(id: String = "w10-tpl") -> TaskItem {
        TaskItem(id: id, name: "Stretch", estimateMin: 25, totalFocused: 4_500,
                 recurrence: .daily(until: nil), createdAt: stamp, updatedAt: stamp)
    }
    private func day(of tpl: TaskItem) -> CalBlock {
        CalBlock(id: "\(tpl.id)-td", taskId: tpl.id, taskName: tpl.name, startTime: "09:00",
                 durationMinutes: 25, date: today, kind: .task)
    }

    private func assertStartsAtZero(_ live: LiveSession, file: StaticString = #filePath, line: UInt = #line) {
        let now = live.sessionStart ?? 0
        XCTAssertEqual(live.priorAccumulatedSec ?? 0, 0, "no prior from the series' lifetime", file: file, line: line)
        XCTAssertEqual(FocusTimer.displayedElapsedSec(live, now: now), 0, file: file, line: line)
        XCTAssertEqual(FocusTimer.deriveState(live, now: now, overrunGraceSec: 1), .running,
                       "not over time at the first second", file: file, line: line)
    }

    /// The Focus screen on a day's row (the projected occurrence — it carries
    /// the template's totalFocused, which the old call site seeded).
    func testTheFocusScreenOnARepeatingTasksDayStartsAtZero() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        let tpl = series()
        let block = day(of: tpl)
        let row = try XCTUnwrap(projectOccurrences([tpl], [block], fromISO: today).first)
        let fm = FocusModel(task: row, store: store, occurrence: (tpl.id, tpl.name, block.id))
        XCTAssertEqual(fm.live.taskId, tpl.id, "the session still runs on the template")
        XCTAssertEqual(fm.live.occurrenceBlockId, block.id)
        assertStartsAtZero(fm.live)
    }

    /// A series with no open day (a reminder's Start before today's block
    /// synced) reaches Focus as the template itself.
    func testTheFocusScreenOnASeriesWithNoOpenDayStartsAtZero() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        let fm = FocusModel(task: series(), store: store)
        assertStartsAtZero(fm.live)
    }

    /// "End for now", then back: a one-off task's total IS its progress.
    func testAPlainTaskStillContinuesFromItsFocusedTotal() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        let plain = TaskItem(id: "w10-plain", name: "Write report", estimateMin: 50, totalFocused: 600,
                             createdAt: stamp, updatedAt: stamp)
        XCTAssertEqual(FocusModel(task: plain, store: store).live.priorAccumulatedSec, 600)
    }

    /// The assistant's start_focus on a series names the template + today's
    /// block; on a series with no open day, the template alone.
    func testTheAssistantsStartFocusOnARepeatingTaskStartsAtZero() async throws {
        let model = AppModel()
        model.startUITestMode()
        let db = try XCTUnwrap(model.db)
        let store = try XCTUnwrap(model.liveStore)
        let tpl = series()
        let block = day(of: tpl)
        try db.save(tpl)
        try db.save(block)

        await model.startFocusJoinOrMint(taskId: tpl.id, estimateMin: 25, occurrenceBlockId: block.id)
        let live = try XCTUnwrap(store.get())
        XCTAssertEqual(live.taskId, tpl.id)
        XCTAssertEqual(live.occurrenceBlockId, block.id)
        assertStartsAtZero(live)

        try store.set(nil)
        let bare = series(id: "w10-bare")
        try db.save(bare)
        await model.startFocusJoinOrMint(taskId: bare.id, estimateMin: 25, occurrenceBlockId: nil)
        assertStartsAtZero(try XCTUnwrap(store.get()))

        try store.set(nil)
        let plain = TaskItem(id: "w10-plain2", name: "Write report", estimateMin: 50, totalFocused: 600,
                             createdAt: stamp, updatedAt: stamp)
        try db.save(plain)
        await model.startFocusJoinOrMint(taskId: plain.id, estimateMin: nil, occurrenceBlockId: nil)
        XCTAssertEqual(try store.get()?.priorAccumulatedSec, 600, "a plain task keeps its own total")
    }

    /// The task sheet's Status on a day of a repeating task: the editor reads
    /// the TEMPLATE, whose total is the series' lifetime focus, so an untouched
    /// day read "In progress".
    func testTheTaskSheetShowsAnUntouchedDayOfARepeatingTaskAsNotStarted() {
        let tpl = series()
        XCTAssertEqual(TaskEditor.statusLabel(done: false, isOccurrence: true, focusedSec: tpl.totalFocused),
                       "Not started", "the series' lifetime focus is not this day's")
        XCTAssertEqual(TaskEditor.statusLabel(done: true, isOccurrence: true, focusedSec: tpl.totalFocused), "Completed")
        // A plain task, or the series itself, still reads its own total.
        XCTAssertEqual(TaskEditor.statusLabel(done: false, isOccurrence: false, focusedSec: 600), "In progress")
        XCTAssertEqual(TaskEditor.statusLabel(done: false, isOccurrence: false, focusedSec: 0), "Not started")
        XCTAssertEqual(TaskEditor.statusLabel(done: true, isOccurrence: false, focusedSec: 600), "Completed")
    }
}

final class SharedFocusLedgerParkingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "SharedFocusLedgerParkingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func rec(_ sid: String, sec: Int = 600) -> AppModel.PendingSharedFocusLog {
        AppModel.PendingSharedFocusLog(sessionId: sid, taskId: "t1", sec: sec, estimateMin: 25)
    }

    func testParkedRecordsComeBackForTheSameUserOnly() {
        AppModel.parkSharedFocusLedger([rec("s1"), rec("s2")], userId: "alice", in: defaults)
        // Bob signs in on the same device: nothing of Alice's rejoins his queue.
        XCTAssertEqual(AppModel.restoreParkedSharedFocusLedger(userId: "bob", current: [], in: defaults), [])
        // Alice's next sign-in: hers come back (before anything already pending) and the slot is cleared.
        let restored = AppModel.restoreParkedSharedFocusLedger(userId: "alice", current: [rec("s9")], in: defaults)
        XCTAssertEqual(restored.map(\.sessionId), ["s1", "s2", "s9"])
        XCTAssertNil(defaults.data(forKey: AppModel.parkedSharedFocusKey(userId: "alice")))
    }

    func testParkingMergesAndDedupesBySessionId() {
        AppModel.parkSharedFocusLedger([rec("s1", sec: 100)], userId: "alice", in: defaults)
        AppModel.parkSharedFocusLedger([rec("s1", sec: 999), rec("s2")], userId: "alice", in: defaults)
        let restored = AppModel.restoreParkedSharedFocusLedger(userId: "alice", current: [rec("s2")], in: defaults)
        XCTAssertEqual(restored.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(restored.first?.sec, 100, "the first record for a session id wins (server-side the RPC is idempotent per id anyway)")
    }

    func testRestoreWithNothingParkedLeavesTheQueueAlone() {
        XCTAssertEqual(AppModel.restoreParkedSharedFocusLedger(userId: "alice", current: [rec("s1")], in: defaults).map(\.sessionId), ["s1"])
    }
}

final class CollectionOwnerStateTests: XCTestCase {
    func testMergedMembersUnionsAndNeverListsTheOwner() {
        XCTAssertEqual(AppModel.mergedMembers(existing: nil, joined: ["b"], ownerId: "a"), ["b"])
        XCTAssertEqual(AppModel.mergedMembers(existing: ["b"], joined: ["b", "c", "a", ""], ownerId: "a"), ["b", "c"])
        XCTAssertEqual(AppModel.mergedMembers(existing: ["b"], joined: [], ownerId: "a"), ["b"],
                       "listing is additive; the hydrate is the authority for removals")
    }

    func testRefusedRPCMessageNamesTheListAndSaysItWasUndone() {
        let msg = AppModel.collectionRPCRejectionMessage(fn: "collection_add_item", listName: "Groceries")
        XCTAssertTrue(msg.contains("add that item to"))
        XCTAssertTrue(msg.contains("Groceries"))
        XCTAssertTrue(msg.contains("undone"))
        XCTAssertTrue(AppModel.collectionRPCRejectionMessage(fn: "something_new", listName: nil).contains("the shared list"))
    }
}

/// Focus accuracy (audit 2026-09-22, C37 C38 C39 C43 C44): the Focus screen
/// acts on the STORED session (a lock-screen Resume / End or the assistant
/// changed it behind the screen), a paused check-in only touches the session
/// it was armed for, a pause reason never re-pauses, a session nobody watched
/// is capped at its estimate + grace, and captures of a session that writes no
/// Session row leave the phone.
@MainActor
final class FocusAccuracyTests: XCTestCase {
    private let stamp = "2026-09-01T08:00:00.000Z"
    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    override func tearDown() {
        PausedCheckinBudget.disarm()
        super.tearDown()
    }

    private func task(_ id: String, estimate: Int = 25) -> TaskItem {
        TaskItem(id: id, name: "Write report", estimateMin: estimate, createdAt: stamp, updatedAt: stamp)
    }
    private func boot() throws -> (AppModel, AppDatabase, LiveSessionStore) {
        let model = AppModel()
        model.startUITestMode()
        let db = try XCTUnwrap(model.db)
        let store = try XCTUnwrap(model.liveStore)
        try store.set(nil)
        return (model, db, store)
    }
    private func running(_ taskId: String, id: String = newUUID(), sinceMin: Double, estimate: Int = 25) -> LiveSession {
        FocusTimer.start(.empty, taskId: taskId, estimateMin: estimate, now: nowMs - sinceMin * 60_000, newId: { id })
    }
    private func eventually(_ cond: () throws -> Bool) async rethrows -> Bool {
        for _ in 0..<100 {
            if try cond() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return try cond()
    }
    private func captureOp(_ db: AppDatabase, _ id: String) throws -> OutboxOp? {
        try OutboxStore(db).pending().last { $0.tableName == "captures" && $0.rowId == id }
    }

    // MARK: C37 — a control made off the Focus screen

    func testAResumeOnTheLockScreenIsNotUndoneByTheStaleFocusScreen() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        // 25 min focused, paused 20 min ago — the Focus screen is up on it.
        let paused = FocusTimer.pause(running("c37", sinceMin: 45, estimate: 50), now: nowMs - 20 * 60_000)
        try store.set(paused)
        let fm = FocusModel(task: task("c37", estimate: 50), store: store)
        XCTAssertTrue(fm.live.paused)
        // "Resume" on the lock screen 6 min ago writes the store only.
        try store.set(FocusTimer.resume(paused, now: nowMs - 6 * 60_000))
        // The screen still says PAUSED; its Resume shifted the start by the
        // whole 20-min pause, erasing the 6 min focused since.
        fm.resume()
        let focused = FocusTimer.elapsedSec(try XCTUnwrap(store.get()), now: nowMs)
        XCTAssertEqual(Double(focused), 31 * 60, accuracy: 5, "25 min before the pause + 6 since the lock-screen Resume")
    }

    func testDoneAfterALockScreenEndDoesNotLogTheSessionAgain() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        try store.set(running("c37", sinceMin: 10))
        let fm = FocusModel(task: task("c37"), store: store)
        try store.set(nil)   // End on the lock screen finalized + cleared it
        XCTAssertNil(fm.finish(), "already logged where it ended — no second Session, recap or totalFocused bump")
        XCTAssertNil(try store.get())
    }

    func testTheFocusScreenNeitherOverwritesNorResurrectsWhatChangedElsewhere() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        try store.set(running("c37", sinceMin: 10))
        let fm = FocusModel(task: task("c37"), store: store)
        // The assistant's extend_focus writes the store.
        try store.set(FocusTimer.extend(try XCTUnwrap(store.get()), minutes: 10))
        fm.pause()
        XCTAssertEqual(try store.get()?.sessionEstimateMin, 35, "the screen's next save kept the old estimate")
        XCTAssertEqual(try store.get()?.paused, true)
        // Another session replaced it (ended here, a new one started elsewhere).
        let other = running("c37-other", sinceMin: 1)
        try store.set(other)
        fm.resume()
        fm.extendFocus(10)
        XCTAssertFalse(fm.cancel())
        XCTAssertEqual(try store.get(), other, "a stale screen never writes over another session")
    }

    func testOffScreenControlsTellAnOpenFocusScreenAndTheShadesEndClosesIt() async throws {
        let (model, db, store) = try boot()
        let t = task(newUUID())
        try db.save(t)
        try store.set(running(t.id, sinceMin: 5))
        model.refreshLiveSession()
        var tick = model.liveSessionOffScreenTick
        model.pauseFocus()
        XCTAssertGreaterThan(model.liveSessionOffScreenTick, tick, "Today's / the assistant's pause")
        tick = model.liveSessionOffScreenTick
        model.resumeFocus()
        XCTAssertGreaterThan(model.liveSessionOffScreenTick, tick, "Today's / the assistant's resume")
        model.pauseFocus()
        tick = model.liveSessionOffScreenTick
        let id = try XCTUnwrap(store.get()?.id)
        await model.handlePushAction(.resumeSession(sessionId: id))
        XCTAssertGreaterThan(model.liveSessionOffScreenTick, tick, "the paused check-in's Resume")
        model.pauseFocus()
        model.router.focusTask = t
        await model.handlePushAction(.endSession(sessionId: id))
        XCTAssertNil(try store.get())
        XCTAssertNil(model.router.focusTask, "left up, its Done logged the session a second time")
    }

    // MARK: C38 — a paused check-in acts on its own session only

    func testACheckinActsOnlyOnThePausedSessionItWasArmedFor() {
        let live = running("b", id: "B", sinceMin: 5)
        let paused = FocusTimer.pause(live, now: nowMs)
        XCTAssertFalse(AppModel.pausedCheckinActsOn(live, sessionId: "B"), "never a running session")
        XCTAssertFalse(AppModel.pausedCheckinActsOn(paused, sessionId: "A"), "another session's nag")
        XCTAssertTrue(AppModel.pausedCheckinActsOn(paused, sessionId: "B"))
        XCTAssertTrue(AppModel.pausedCheckinActsOn(paused, sessionId: nil), "a nag an earlier build armed, on a paused session")
        XCTAssertFalse(AppModel.pausedCheckinActsOn(nil, sessionId: nil))
    }

    func testAnOldSessionsCheckinCannotEndTheNewOne() async throws {
        let (model, db, store) = try boot()
        let b = task(newUUID())
        try db.save(b)
        let live = running(b.id, sinceMin: 9)
        try store.set(live)
        await model.handlePushAction(.endSession(sessionId: newUUID()))   // "Did you step away? A"
        await model.handlePushAction(.endSession(sessionId: nil))         // the same nag from an earlier build
        await model.handlePushAction(.resumeSession(sessionId: newUUID()))
        XCTAssertEqual(try store.get(), live, "B keeps running, unlogged")
    }

    /// "Start focus on X" to the assistant while X sits paused ("Save for
    /// later") resumes the same session — its nag goes, and an open Focus
    /// screen is told (the screen's own start already did both).
    func testTheAssistantsStartOnAPausedSessionCancelsItsCheckin() async throws {
        let (model, db, store) = try boot()
        let x = task(newUUID())
        try db.save(x)
        let paused = FocusTimer.pause(running(x.id, sinceMin: 10), now: nowMs - 3 * 60_000)
        try store.set(paused)
        model.refreshLiveSession()
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 600, forKey: PausedCheckinBudget.fireAtKey)
        let tick = model.liveSessionOffScreenTick
        await model.startFocusJoinOrMint(taskId: x.id, estimateMin: nil, occurrenceBlockId: nil)
        let live = try XCTUnwrap(store.get())
        XCTAssertEqual(live.id, paused.id)
        XCTAssertFalse(live.paused, "resumed")
        XCTAssertNil(UserDefaults.standard.object(forKey: PausedCheckinBudget.fireAtKey),
                     "left armed, 'Did you step away?' fired while it ran")
        XCTAssertGreaterThan(model.liveSessionOffScreenTick, tick, "an open Focus screen stayed on PAUSED")
    }

    func testDisplacingAPausedSessionCancelsItsCheckin() throws {
        let (model, db, store) = try boot()
        let a = task(newUUID())
        try db.save(a)
        try store.set(FocusTimer.pause(running(a.id, sinceMin: 10), now: nowMs - 60_000))
        // A's ~14-min nag is armed, 10 min to go.
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 600, forKey: PausedCheckinBudget.fireAtKey)
        model.finalizeDisplacedFocus(forNewTaskId: newUUID())
        XCTAssertNil(UserDefaults.standard.object(forKey: PausedCheckinBudget.fireAtKey),
                     "left armed, it fired during the new session and its End ended that one")
    }

    // MARK: C39 — picking a pause reason

    func testPausingAPausedSessionKeepsWhenItWasPaused() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        try store.set(running("c39", sinceMin: 10))
        let fm = FocusModel(task: task("c39"), store: store)
        fm.pause()
        let pausedAt = try XCTUnwrap(fm.live.pausedAt)
        Thread.sleep(forTimeInterval: 0.02)
        fm.pause()   // the reason sheet's choice after Pause
        XCTAssertEqual(fm.live.pausedAt, pausedAt, "the time spent choosing a reason is not focus")
        XCTAssertEqual(try store.get()?.pausedAt, pausedAt)
    }

    // MARK: C43 — a session nobody watched

    func testADisplacedForgottenSessionIsCappedAtItsEstimatePlusGrace() async throws {
        let (model, db, store) = try boot()
        let a = task(newUUID())
        try db.save(a)
        try store.set(running(a.id, sinceMin: 16 * 60))   // "← Out", forgotten overnight
        model.finalizeDisplacedFocus(forNewTaskId: newUUID())
        let landed = try await eventually { (try db.fetchById(TaskItem.self, id: a.id)?.totalFocused ?? 0) > 0 }
        XCTAssertTrue(landed)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: a.id)?.totalFocused,
                       25 * 60 + AppModel.sharedFocusCapGraceSec, "not 16 hours")
    }

    func testTheShadesEndOnAForgottenSessionIsCapped() async throws {
        let (model, db, store) = try boot()
        let a = task(newUUID())
        try db.save(a)
        let paused = FocusTimer.pause(running(a.id, sinceMin: 16 * 60), now: nowMs - 60_000)
        try store.set(paused)
        await model.handlePushAction(.endSession(sessionId: paused.id))
        let landed = try await eventually { (try db.fetchById(TaskItem.self, id: a.id)?.totalFocused ?? 0) > 0 }
        XCTAssertTrue(landed)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: a.id)?.totalFocused, 25 * 60 + AppModel.sharedFocusCapGraceSec)
    }

    func testTheFocusScreenAsksOnlyPastTheEstimatePlusGrace() {
        let now = nowMs
        let forgotten = running("c43", sinceMin: 16 * 60)
        let over = FocusModel.overlongElapsedSec(forgotten, now: now, sharedLedger: false)
        XCTAssertEqual(Double(over?.raw ?? 0), 16 * 3600, accuracy: 2)
        XCTAssertEqual(over?.capped, 25 * 60 + AppModel.sharedFocusCapGraceSec)
        XCTAssertEqual(over?.mayDiscard, true)
        XCTAssertNil(FocusModel.overlongElapsedSec(running("c43", sinceMin: 40), now: now, sharedLedger: false),
                     "a long but real session logs as it is")
        XCTAssertNil(FocusModel.overlongElapsedSec(running("c43", sinceMin: 16 * 60, estimate: 24 * 60), now: now,
                                                   sharedLedger: false),
                     "extended to fit")
    }

    /// On a partner-shared task, ending here broadcasts `ended` and the
    /// partner's device logs the whole run under the same session id — so
    /// the prompt never offers "Discard", which would log nothing only here.
    func testTheFocusScreenOffersNoDiscardOnASessionSharedWithAPartner() throws {
        let (model, _, _) = try boot()
        var cofocus = running("c43-partner", sinceMin: 16 * 60)
        cofocus.sharedSessionRev = 3   // broadcast on the co-focus channel
        let ledger = model.accruesViaSharedLedger(cofocus, taskId: "c43-partner")
        XCTAssertTrue(ledger)
        let over = try XCTUnwrap(FocusModel.overlongElapsedSec(cofocus, now: nowMs, sharedLedger: ledger))
        XCTAssertFalse(over.mayDiscard)
        XCTAssertEqual(over.capped, 25 * 60 + AppModel.sharedFocusCapGraceSec, "logging it capped is still offered")
    }

    /// Adopting a partner's session over my own forgotten clock on the same
    /// task keeps that clock's Session row — capped like its ledger write,
    /// not the whole night (C43).
    func testAdoptingOverAForgottenOwnClockCapsItsSessionRow() {
        let t = task("c43-adopt")
        let row = AppModel.displacedClockSession(id: "old", task: t, rawSec: 16 * 3600, estimateMin: 25)
        XCTAssertEqual(row.id, "old")
        XCTAssertEqual(row.taskId, t.id)
        XCTAssertEqual(row.actualSec, 25 * 60 + AppModel.sharedFocusCapGraceSec, "not 16 hours into Insights")
        XCTAssertEqual(AppModel.displacedClockSession(id: "old", task: t, rawSec: 20 * 60, estimateMin: 25).actualSec,
                       20 * 60, "a real one logs as it is")
        // The row carries the SESSION's plan (an extended 45), not the task's
        // default 25 — Insights' D1 cap and calibration read it (P1-13).
        XCTAssertEqual(AppModel.displacedClockSession(id: "old", task: t, rawSec: 50 * 60, estimateMin: 45).estimateMin, 45)
    }

    // MARK: analytics — the displaced session's pause length and plan

    /// Starting Focus on B while A is PAUSED ends A's pause: A's reason log is
    /// re-saved with how long the pause lasted ("What pauses you", "How fast
    /// you come back" — cross-check P0-3), and A's Session row carries A's
    /// own plan (estimate + extends), not the task default (P1-13).
    func testDisplacingAPausedSessionLogsThePauseLengthAndTheSessionsOwnPlan() async throws {
        let (model, db, store) = try boot()
        let a = task(newUUID(), estimate: 25)
        try db.save(a)
        // Extended to 40 min, 28 min in, paused two minutes ago with a reason.
        var paused = FocusTimer.pause(running(a.id, sinceMin: 30, estimate: 40), now: nowMs - 120_000)
        let log = ReasonLog(id: newUUID(), taskId: a.id, reason: "Phone", action: .pause, at: stamp)
        paused.pendingPauseLog = log
        try store.set(paused)
        let sid = try XCTUnwrap(paused.id)
        model.finalizeDisplacedFocus(forNewTaskId: newUUID())
        let timed = try await eventually { (try db.fetchById(ReasonLog.self, id: log.id)?.durationSec ?? 0) > 0 }
        XCTAssertTrue(timed, "the pause's reason log never got its length")
        XCTAssertEqual(Double(try XCTUnwrap(db.fetchById(ReasonLog.self, id: log.id)?.durationSec)), 120, accuracy: 3)
        let row = try await eventually { try db.fetchById(UnstuckCore.Session.self, id: sid) != nil }
        XCTAssertTrue(row)
        XCTAssertEqual(try db.fetchById(UnstuckCore.Session.self, id: sid)?.estimateMin, 40, "the session's plan, not the task's 25")
    }

    /// The assistant's finish_focus caps a session left running — and says
    /// by how much, so the result line can (rules §1; C43).
    func testTheAssistantsFinishReportsTheRunItCapped() async throws {
        let (model, db, store) = try boot()
        let t = task(newUUID())
        try db.save(t)
        try store.set(running(t.id, sinceMin: 16 * 60))
        model.refreshLiveSession()
        let state = AppModelAssistantState(model: model, assistant: model.assistant)
        let finished = await state.finishFocus(markDone: false)
        let out = try XCTUnwrap(finished)
        XCTAssertEqual(out.elapsedSec, 25 * 60 + AppModel.sharedFocusCapGraceSec)
        XCTAssertEqual(Double(try XCTUnwrap(out.ranSec)), 16 * 3600, accuracy: 5)
        try store.set(running(t.id, sinceMin: 10))
        let ordinary = await state.finishFocus(markDone: false)
        XCTAssertNil(try XCTUnwrap(ordinary).ranSec, "logged in full — nothing to report")
    }

    // MARK: C44 — captures of a session with no Session row

    func testCancellingFocusReleasesTheCapturesHeldOnItsSession() async throws {
        let (model, db, store) = try boot()
        let t = task(newUUID())
        try db.save(t)
        let live = running(t.id, sinceMin: 5)
        try store.set(live)
        let sid = try XCTUnwrap(live.id)
        let cid = newUUID()
        await model.saveCaptureAwaiting(Capture(id: cid, taskId: t.id, sessionId: sid, tag: .followUp, body: "call the bank", at: stamp))
        XCTAssertEqual(try captureOp(db, cid)?.dependsOn, sid, "waits for the session's row")
        AppModelAssistantState(model: model, assistant: model.assistant).cancelFocus()   // "cancel it, don't log it"
        let released = try await eventually { try self.captureOp(db, cid)?.dependsOn == nil }
        XCTAssertTrue(released, "no Session row will ever come")
        XCTAssertNil(try db.fetchById(Capture.self, id: cid)?.sessionId)
    }

    func testADisplacedSessionOfADeletedTaskSendsItsCapturesWithoutEither() async throws {
        let (model, db, store) = try boot()
        let gone = newUUID()
        let live = running(gone, sinceMin: 5)
        try store.set(live)
        let cid = newUUID()
        await model.saveCaptureAwaiting(Capture(id: cid, taskId: gone, sessionId: live.id, tag: .idea, body: "x", at: stamp))
        model.finalizeDisplacedFocus(forNewTaskId: newUUID())
        let released = try await eventually { try self.captureOp(db, cid)?.dependsOn == nil }
        XCTAssertTrue(released)
        let row = try XCTUnwrap(db.fetchById(Capture.self, id: cid))
        XCTAssertNil(row.sessionId)
        XCTAssertNil(row.taskId, "captures.task_id references tasks(id): the dead id would be refused")
        let payload = try XCTUnwrap(captureOp(db, cid)?.payload?.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertTrue(obj["task_id"] is NSNull)
        XCTAssertTrue(obj["session_id"] is NSNull)
    }

    func testACaptureDuringASessionSharedWithMeIsTiedToNoSession() throws {
        let store = LiveSessionStore(try AppDatabase.makeInMemory())
        let shared = FocusModel(task: task("owners-task"), store: store, sharedLevel: .partner)
        XCTAssertNil(shared.captureSessionId, "that session writes no own Session row to wait for")
        try store.set(nil)
        let own = FocusModel(task: task("mine"), store: store)
        XCTAssertEqual(own.captureSessionId, own.live.id)
    }
}
