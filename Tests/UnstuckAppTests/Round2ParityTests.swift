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
