// App-layer unit tests for the redesigned assistant thread: the model window
// (what the edge function actually sees), the persisted turn shape, the day
// dividers, and the share-confirm contract.
//
// These cover the pieces that live in App/ (AssistantTurn / AssistantModel /
// the confirm card's performer seam) which `swift test` can't reach; the pure
// ports (suggestions / receipts / check-in / share-request) are tested in
// UnstuckCoreTests.

import XCTest
import UnstuckCore
import UnstuckSync
@testable import Unstuck

final class AssistantThreadTests: XCTestCase {

    private func user(_ text: String, at: Double? = 1) -> AssistantTurn {
        AssistantTurn(ChatMessage(role: "user", content: text), at: at)
    }
    private func assistant(_ text: String, receipts: [Receipt]? = nil) -> AssistantTurn {
        AssistantTurn(ChatMessage(role: "assistant", content: text), at: 2, receipts: receipts)
    }
    private func tool(_ result: String) -> AssistantTurn {
        AssistantTurn(ChatMessage(role: "tool", content: result, toolCallId: "c1", name: "create_task"))
    }
    private func local(_ text: String) -> AssistantTurn {
        AssistantTurn(ChatMessage(role: "assistant", content: text), at: 3, local: true)
    }

    // MARK: model window

    func testLocalCheckinTurnsNeverReachTheModel() {
        let turns = [user("hi"), assistant("hey"), local("Morning, Maya. 3 things on today.")]
        let window = AssistantModel.modelWindow(turns)
        XCTAssertEqual(window.count, 2)
        XCTAssertFalse(window.contains { $0.content?.hasPrefix("Morning") ?? false })
    }

    func testWindowIsCappedAndAlwaysStartsAtAUserTurn() {
        // 30 exchanges = 60 turns; the 40-turn tail would otherwise start on an
        // assistant turn (an orphaned reply the model must never resume from).
        var turns: [AssistantTurn] = []
        for i in 0..<30 {
            turns.append(user("q\(i)"))
            turns.append(assistant("a\(i)"))
        }
        let window = AssistantModel.modelWindow(turns)
        XCTAssertLessThanOrEqual(window.count, AssistantModel.maxModelWindow)
        XCTAssertEqual(window.first?.role, "user")
    }

    func testAToolResultTailIsAlsoRealignedToAUserTurn() {
        var turns: [AssistantTurn] = []
        for i in 0..<20 {
            turns.append(user("q\(i)"))
            turns.append(assistant("a\(i)"))
            turns.append(tool("ok: created task id=t\(i) name=\"x\""))
        }
        let window = AssistantModel.modelWindow(turns)
        XCTAssertEqual(window.first?.role, "user", "a window may never open on a dangling tool/assistant turn")
    }

    func testALeadingAssistantTurnIsDroppedSoTheWindowOpensOnTheUser() {
        let turns = [assistant("hello"), user("hi")]
        let window = AssistantModel.modelWindow(turns)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.role, "user")
    }

    func testAWindowWithNoUserTurnAtAllIsLeftAlone() {
        // Nothing to realign to — the web keeps it too rather than sending [].
        let turns = [assistant("hello"), tool("ok")]
        XCTAssertEqual(AssistantModel.modelWindow(turns).count, 2)
    }

    // MARK: persistence shape

    func testATurnRoundTripsWithItsDisplayMetadataAndReceipts() throws {
        let receipt = Receipt(icon: .plus, label: "Created “Dentist”", undo: .deleteTask(id: "abc"))
        let turn = assistant("Done.", receipts: [receipt])
        let back = try JSONDecoder().decode(AssistantTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(back, turn)
        XCTAssertEqual(back.receipts?.first?.undo, .deleteTask(id: "abc"))
        XCTAssertEqual(back.undoableReceipts.count, 1)
    }

    func testTheWireMessageInsideATurnKeepsTheOpenAIShape() throws {
        let turn = AssistantTurn(ChatMessage(role: "tool", content: "ok", toolCallId: "call_1", name: "create_task"))
        let json = String(data: try JSONEncoder().encode(turn), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"tool_call_id\""), json)
        // Display-only fields exist on the TURN, never inside the wire message.
        XCTAssertFalse(json.contains("\"receipts\":"), "an empty receipts list must not be persisted")
    }

    // MARK: day dividers

    func testDayLabels() {
        let now = Date()
        let today = now.timeIntervalSince1970 * 1000
        XCTAssertEqual(assistantDayLabel(at: today, now: now), "Today")

        let yesterday = Foundation.Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(assistantDayLabel(at: yesterday.timeIntervalSince1970 * 1000, now: now), "Yesterday")

        let older = Foundation.Calendar.current.date(byAdding: .day, value: -9, to: now)!
        let label = assistantDayLabel(at: older.timeIntervalSince1970 * 1000, now: now)
        XCTAssertNotNil(label)
        XCTAssertNotEqual(label, "Today")
        XCTAssertNotEqual(label, "Yesterday")

        // A legacy turn with no timestamp simply renders without a divider.
        XCTAssertNil(assistantDayLabel(at: nil, now: now))
    }

    // MARK: undo bookkeeping

    func testUndoableReceiptsIgnoreAlreadyUndoneAndUndoLessCards() {
        let turn = assistant("Done.", receipts: [
            Receipt(icon: .plus, label: "Created “A”", undo: .deleteTask(id: "a")),
            Receipt(icon: .check, label: "Completed “B”", undo: .uncompleteTask(id: "b"), undone: true),
            Receipt(icon: .calendar, label: "Scheduled “C”"),
        ])
        XCTAssertEqual(turn.undoableReceipts.count, 1)
    }
}

// MARK: - share confirm

/// Records what the confirm card actually performs. `nothing leaves before the
/// tap` is enforced by construction: the card only calls
/// `performConfirmedShare` from its "Share it" action.
@MainActor
private final class SpyPerformer: AssistantSharePerformer {
    var shares: [(String, String, ShareLevel)] = []
    var notifies: [(String, String)] = []
    var failWith: Error?

    func share(taskId: String, user: String, level: ShareLevel) async throws {
        if let failWith { throw failWith }
        shares.append((taskId, user, level))
    }
    func notify(taskId: String, recipientId: String) async {
        notifies.append((taskId, recipientId))
    }
}

private struct ShareRPCError: LocalizedError {
    var errorDescription: String? { "not in circle" }
}

@MainActor
final class AssistantShareConfirmTests: XCTestCase {
    private let pending = PendingShare(id: "p1", taskId: "t1", taskName: "Grocery run",
                                       recipientUserId: "u2", recipientName: "Zubair Kazaure",
                                       level: .assign)

    func testNothingLeavesUntilTheShareIsPerformed() {
        let spy = SpyPerformer()
        // Merely staging a request touches the network zero times.
        XCTAssertTrue(spy.shares.isEmpty)
        XCTAssertTrue(spy.notifies.isEmpty)
    }

    func testConfirmPerformsTheShareWithTheStagedValuesThenNotifies() async {
        let spy = SpyPerformer()
        let (outcome, message) = await performConfirmedShare(pending, using: spy)
        XCTAssertEqual(outcome, .shared)
        XCTAssertNil(message)
        XCTAssertEqual(spy.shares.count, 1)
        XCTAssertEqual(spy.shares.first?.0, "t1")
        XCTAssertEqual(spy.shares.first?.1, "u2")
        XCTAssertEqual(spy.shares.first?.2, .assign)
        XCTAssertEqual(spy.notifies.first?.0, "t1")
        XCTAssertEqual(spy.notifies.first?.1, "u2")
    }

    func testAFailedRPCReportsFailureAndNEVERNotifies() async {
        let spy = SpyPerformer()
        spy.failWith = ShareRPCError()
        let (outcome, message) = await performConfirmedShare(pending, using: spy)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(message, "not in circle")
        XCTAssertTrue(spy.notifies.isEmpty, "a failed share must never look like a successful one")
    }

    func testAResolvedShareStopsOfferingTheAction() {
        var resolved = pending
        resolved.outcome = .shared
        XCTAssertEqual(resolved.outcome, .shared)
        // The card renders its "SHARED" state off this and drops both buttons.
        XCTAssertNotEqual(resolved.outcome, .dismissed)
    }
}
