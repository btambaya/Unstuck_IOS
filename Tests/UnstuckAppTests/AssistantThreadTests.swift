// App-layer unit tests for the redesigned assistant thread: the model window
// (what the edge function actually sees), the persisted turn shape, the day
// dividers, and the share-confirm contract.
//
// These cover the pieces that live in App/ (AssistantTurn / AssistantModel /
// the confirm card's performer seam) which `swift test` can't reach; the pure
// ports (suggestions / receipts / check-in / share-request) are tested in
// UnstuckCoreTests.

import XCTest
import Supabase
import UnstuckCore
import UnstuckShared
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
    /// The hidden guard bounce — the display filter keys on `hidden`, not on
    /// the text (the real string is MainActor-bound on AssistantHarness).
    private static let corrective = "(integrity check from the app — not the user. …)"
    /// A model round that asked for a tool — its text is narration, not a reply.
    private func narration(_ text: String?, tool name: String = "get_lists") -> AssistantTurn {
        AssistantTurn(ChatMessage(role: "assistant", content: text,
                                  toolCalls: [ToolCall(id: "c1", type: "function", function: ToolFunction(name: name, arguments: "{}"))]), at: 2)
    }

    // MARK: interview prompts in the thread (InterviewThread)

    func testInterviewPromptMetaRoundTripsAndStaysOutOfTheModelWindow() throws {
        // A question the interview posted: a LOCAL assistant turn tagged with
        // its key (the sheet keys the chip row on it); the user's chip tap is
        // a LOCAL user bubble. Both display; neither reaches the model.
        let q = AssistantTurn(ChatMessage(role: "assistant", content: "When’s your head clearest?"),
                              at: 4, local: true, interview: InterviewPromptMeta(key: "rhythm"))
        let tap = AssistantTurn(ChatMessage(role: "user", content: "Morning"), at: 5, local: true)
        let turns = [user("hi"), assistant("Hello."), q, tap]
        XCTAssertEqual(AssistantModel.displayTurns(turns).map(\.text),
                       ["hi", "Hello.", "When’s your head clearest?", "Morning"])
        XCTAssertEqual(AssistantModel.modelWindow(turns).map(\.content), ["hi", "Hello."])
        let data = try JSONEncoder().encode(turns)
        let back = try JSONDecoder().decode([AssistantTurn].self, from: data)
        XCTAssertEqual(back[2].interview, InterviewPromptMeta(key: "rhythm"))
        XCTAssertNil(back[3].interview)
        XCTAssertTrue(back[3].isLocal)
        // A thread persisted before the field existed decodes with no prompt.
        let legacy = try JSONDecoder().decode([AssistantTurn].self, from: try JSONEncoder().encode([user("old")]))
        XCTAssertNil(legacy[0].interview)
    }

    // MARK: display filter (lib/assistant/display.ts parity)

    func testATurnWithTwoToolRoundsAndAFinalReplyRendersOneAssistantBubble() {
        // The tester's screenshot (2026-09-06): four assistant bubbles for one
        // question — each round's "I'll get… / Let me try…" narration.
        let turns = [
            user("I would like to review what I have in my collections"),
            narration("I'll get your current collections (lists) for you."),
            tool("error: unknown tool \"get_collections\" — available: …"),
            narration("Let me try the correct tool:"),
            tool("ok: 2 lists:\n- \"ToDo\" [id=l1] — 3 open"),
            assistant("Two lists: ToDo and Shopping."),
        ]
        XCTAssertEqual(AssistantModel.displayTurns(turns).map(\.text),
                       ["I would like to review what I have in my collections", "Two lists: ToDo and Shopping."])
        // The persisted thread is untouched — the model still sees its narration.
        XCTAssertEqual(AssistantModel.modelWindow(turns).count, 6)
    }

    func testDisplayKeepsLocalLinesAndDropsHiddenBouncesEmptyAndToolTurns() {
        let turns = [
            user("hi"),
            local("Morning, Maya. 3 things on today."),
            AssistantTurn(ChatMessage(role: "assistant", content: "Added it."), hidden: true),
            AssistantTurn(ChatMessage(role: "user", content: Self.corrective), hidden: true),
            narration(nil, tool: "create_task"),
            tool("ok: created task id=t1 name=\"x\""),
            assistant("   "),
            assistant("Created \"x\"."),
        ]
        XCTAssertEqual(AssistantModel.displayTurns(turns).map(\.text), ["hi", "Morning, Maya. 3 things on today.", "Created \"x\"."])
    }

    func testWorkingStatusIsTheLatestNarrationOfTheInFlightTurnOnly() {
        XCTAssertNil(AssistantModel.workingStatus([user("q")]), "nothing landed yet → Thinking…")
        let mid = [user("q"), narration("I'll get your lists.\nThen summarise."), tool("ok")]
        XCTAssertEqual(AssistantModel.workingStatus(mid), "I'll get your lists.")
        let later = mid + [narration("Let me try the correct tool:"), tool("error: …")]
        XCTAssertEqual(AssistantModel.workingStatus(later), "Let me try the correct tool:")
        // A previous turn's narration never leaks into a new turn.
        XCTAssertNil(AssistantModel.workingStatus(later + [assistant("done"), user("next")]))
        // A hidden bounce does not end the turn; an empty narration falls through.
        let bounced = mid + [AssistantTurn(ChatMessage(role: "assistant", content: "I added it"), hidden: true),
                             AssistantTurn(ChatMessage(role: "user", content: Self.corrective), hidden: true)]
        XCTAssertEqual(AssistantModel.workingStatus(bounced), "I'll get your lists.")
        XCTAssertEqual(AssistantModel.workingStatus(bounced + [narration(nil, tool: "create_task"), tool("ok")]), "I'll get your lists.")
        XCTAssertEqual(AssistantModel.oneLine(String(repeating: "x", count: 100)), String(repeating: "x", count: 79) + "…")
        XCTAssertNil(AssistantModel.oneLine("  \n "))
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

    // MARK: recovery — two upstream rejections in a row offer a fresh thread

    func testTwoUpstreamFailuresInARowOfferAFreshThreadAndAnyOtherOutcomeResets() {
        var streak = 0
        streak = AssistantModel.upstreamStreak(after: "upstream", previous: streak)
        XCTAssertEqual(streak, 1)
        XCTAssertFalse(AssistantModel.offersFreshThread(streak: streak))
        streak = AssistantModel.upstreamStreak(after: "upstream", previous: streak)
        XCTAssertEqual(streak, 2)
        XCTAssertTrue(AssistantModel.offersFreshThread(streak: streak))
        // A different failure between them is not the poisoned-thread signature.
        XCTAssertEqual(AssistantModel.upstreamStreak(after: "network", previous: 1), 0)
        XCTAssertEqual(AssistantModel.upstreamStreak(after: "rate_limited", previous: 5), 0)
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

// MARK: - the AI-consent gate (AIConsent, guideline 5.1.2(i))
//
// AppModel.withAIConsent is the ONE gate in front of everything that sends
// the user's words or voice to OpenAI. These drive it the way the sheet does
// (ask → agree / "Not now" → the sheet goes away) on throwaway defaults, plus
// the backstops that hold when a surface didn't ask.

@MainActor
final class AIConsentGateTests: XCTestCase {
    private var suite: UserDefaults!
    private var savedConsentDefaults: UserDefaults!
    private var savedCallDefaults: UserDefaults!
    private var app: AppModel!

    private let granted = AIConsent.Record(at: "2026-09-24T08:00:00.000Z", version: AIConsent.version)

    override func setUp() async throws {
        try await super.setUp()
        suite = UserDefaults(suiteName: "ai-consent-gate-tests")
        suite.removePersistentDomain(forName: "ai-consent-gate-tests")
        savedConsentDefaults = AIConsentStore.defaults
        savedCallDefaults = CallSettings.defaults
        AIConsentStore.defaults = suite
        CallSettings.defaults = suite
        app = AppModel()
    }

    override func tearDown() async throws {
        app = nil
        AIConsentStore.defaults = savedConsentDefaults
        CallSettings.defaults = savedCallDefaults
        suite.removePersistentDomain(forName: "ai-consent-gate-tests")
        try await super.tearDown()
    }

    func testWithTheOKTheActionRunsAtOnce() {
        app.aiConsentCache = AIConsent.Cache(userId: "u1", record: granted, pending: false)
        var ran = 0
        app.withAIConsent(.chat, from: .assistant) { ran += 1 }
        XCTAssertEqual(ran, 1, "synchronously — the send path is unchanged")
        XCTAssertNil(app.aiConsentAsk)
    }

    func testWithoutItTheSheetAsksAndAgreeRunsTheActionOnceTheSheetIsGone() async {
        XCTAssertFalse(app.aiConsentGranted)
        var ran = 0
        await app.askForAIConsent(.chat, from: .assistant) { ran += 1 }
        XCTAssertEqual(app.aiConsentAsk?.host, .assistant)
        XCTAssertEqual(app.aiConsentAsk?.action, .chat)
        XCTAssertEqual(ran, 0, "nothing sent while it asks")

        app.agreeAIConsent(now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(app.aiConsentAsk)
        XCTAssertEqual(ran, 0, "a Talk cover can only present once the sheet has gone")
        app.aiConsentSheetDismissed()
        XCTAssertEqual(ran, 1)
        app.aiConsentSheetDismissed()
        XCTAssertEqual(ran, 1, "once")

        XCTAssertTrue(app.aiConsentGranted)
        XCTAssertEqual(app.aiConsentCache?.record, AIConsent.Record(at: "2026-09-21T14:13:20.000Z", version: AIConsent.version))
        XCTAssertEqual(app.aiConsentCache?.pending, true, "no account to write to here — sent on the next open")
        XCTAssertEqual(AIConsentStore.load(), app.aiConsentCache, "kept for offline + a call ringing before the app is up")
        XCTAssertNil(app.aiConsentNote)
    }

    func testAnOKForAnOlderVersionAsksAgain() async {
        app.aiConsentCache = AIConsent.Cache(userId: "u1", record: .init(at: "2026-01-01T00:00:00.000Z", version: "2026-01-01"),
                                             pending: false)
        XCTAssertFalse(app.aiConsentGranted)
        await app.askForAIConsent(.talk, from: .today) {}
        XCTAssertEqual(app.aiConsentAsk?.host, .today)
    }

    func testNotNowSkipsTheActionAndSaysWhyWhereItWasAsked() async {
        CallSettings.enabled = true
        var ran = 0, declined = 0
        await app.askForAIConsent(.talk, from: .today, onDecline: { declined += 1 }) { ran += 1 }
        app.declineAIConsent()
        XCTAssertNil(app.aiConsentAsk)
        app.aiConsentSheetDismissed()
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(declined, 1)
        XCTAssertEqual(app.aiConsentNote, AIConsentNote(host: .today, text: AIConsent.decline(.talk).note))
        XCTAssertFalse(app.aiConsentGranted)
        XCTAssertNil(app.aiConsentCache, "nothing recorded")
        XCTAssertTrue(CallSettings.enabled, "nothing else changes")
        // The next try clears the line and asks again.
        app.withAIConsent(.talk, from: .today) {}
        XCTAssertNil(app.aiConsentNote)
    }

    func testSwipingTheSheetAwayCountsAsNotNow() async {
        var ran = 0
        await app.askForAIConsent(.chat, from: .assistant) { ran += 1 }
        app.aiConsentSheetDismissed()
        XCTAssertEqual(ran, 0)
        XCTAssertNil(app.aiConsentAsk)
        XCTAssertEqual(app.aiConsentNote?.host, .assistant)
    }

    func testOneSheetAtATime() async {
        await app.askForAIConsent(.chat, from: .assistant) {}
        let first = app.aiConsentAsk?.id
        await app.askForAIConsent(.talk, from: .today) {}
        XCTAssertEqual(app.aiConsentAsk?.id, first)
        XCTAssertEqual(app.aiConsentAsk?.host, .assistant)
    }

    func testCallsCountAsOnOnlyWhenSomethingCanRing() {
        CallSettings.enabled = true
        XCTAssertFalse(app.callsAreOnForAIConsent, "the switch is on by default — alone it rings nothing")
        var prefs = CallProactivePrefs.defaults
        prefs.eveningEnabled = true
        app.setCallProactivePrefs(prefs)
        XCTAssertTrue(app.callsAreOnForAIConsent)
        CallSettings.enabled = false
        XCTAssertFalse(app.callsAreOnForAIConsent)
    }

    func testNotNowOnAppOpenTurnsCallsOffAndSaysSo() {
        CallSettings.enabled = true
        var prefs = CallProactivePrefs.defaults
        prefs.morningEnabled = true
        prefs.afterBlockEnabled = true
        app.setCallProactivePrefs(prefs)
        app.aiConsentAsk = AIConsentAsk(action: .callsOnOpen, host: .root, onAgree: {}, onDecline: {})
        app.declineAIConsent()
        XCTAssertFalse(CallSettings.enabled)
        XCTAssertFalse(app.callProactivePrefs.morningEnabled)
        XCTAssertFalse(app.callProactivePrefs.eveningEnabled)
        XCTAssertFalse(app.callProactivePrefs.afterBlockEnabled)
        XCTAssertEqual(CallSettings.proactive, app.callProactivePrefs, "the account's proactive calls go off too")
        XCTAssertFalse(app.callsAreOnForAIConsent)
        app.aiConsentSheetDismissed()
        XCTAssertEqual(app.aiConsentNote, AIConsentNote(host: .root, text: AIConsent.callsTurnedOffNote))
    }

    func testAgreeOnAppOpenLeavesCallsOn() {
        CallSettings.enabled = true
        app.aiConsentAsk = AIConsentAsk(action: .callsOnOpen, host: .root, onAgree: {}, onDecline: {})
        app.agreeAIConsent()
        app.aiConsentSheetDismissed()
        XCTAssertTrue(CallSettings.enabled)
        XCTAssertTrue(app.aiConsentGranted)
    }

    func testTurningItOffInSettingsClearsTheOKAndTurnsCallsOff() {
        app.aiConsentCache = AIConsent.Cache(userId: "u1", record: granted, pending: false)
        CallSettings.enabled = true
        var prefs = CallProactivePrefs.defaults
        prefs.morningEnabled = true
        app.setCallProactivePrefs(prefs)
        app.revokeAIConsent()
        XCTAssertFalse(app.aiConsentGranted)
        XCTAssertNil(app.aiConsentCache?.record.at)
        XCTAssertEqual(app.aiConsentCache?.pending, true, "sent to the account (ai_consent_at: null) on the next open")
        XCTAssertFalse(CallSettings.enabled)
        XCTAssertFalse(app.callProactivePrefs.morningEnabled)
        XCTAssertEqual(app.aiConsentNote, AIConsentNote(host: .settings, text: AIConsent.revokedNote))
    }

    func testTheAccountsAnswerIsAdopted() {
        app.adoptAIConsent(granted, userId: "u1", source: .fresh)
        XCTAssertTrue(app.aiConsentGranted)
        // Turned off on the web: the next fresh read turns it off here.
        app.adoptAIConsent(AIConsent.revoked(granted), userId: "u1", source: .fresh)
        XCTAssertFalse(app.aiConsentGranted)
        // A saved launch session never overrides the copy.
        app.adoptAIConsent(granted, userId: "u1", source: .stored)
        XCTAssertFalse(app.aiConsentGranted)
    }

    // MARK: backstops (a path that didn't ask)

    func testTheAssistantSendsNothingWithoutTheOK() async {
        AssistantModel.scrubPersisted()
        let assistant = AssistantModel(model: app, client: AssistantClient(Self.offlineClient()))
        assistant.send("plan my day")
        XCTAssertEqual(assistant.error, "consent")
        XCTAssertFalse(assistant.sending)
        XCTAssertTrue(assistant.turns.isEmpty, "not even into the thread")
        XCTAssertEqual(assistantFriendlyError("consent"), AIConsent.decline(.chat).note)
        guard case .err("consent") = await assistant.tourAsk(messages: [], stepId: "s", stepTitle: "t") else {
            return XCTFail("the tour answers from its script instead")
        }
        assistant.clear()
    }

    func testTheSiriPromptWaitsInTheComposerWithoutTheOK() throws {
        try XCTSkipUnless(app.assistantEnabled, "the AI kill-switch drops the link before the gate")
        AppGroup.setPendingAssistantPrompt("probe")
        try XCTSkipUnless(AppGroup.consumePendingAssistantPrompt() == "probe", "no App Group container in this host")
        AppGroup.setPendingAssistantPrompt("book the dentist")
        app.routeDeepLink("unstuck://assistant")
        XCTAssertTrue(app.router.showAssistant)
        XCTAssertEqual(app.assistant.takeComposerRequest()?.draft, "book the dentist")
        XCTAssertTrue(app.assistant.turns.isEmpty, "nothing sent")
        app.router.showAssistant = false
    }

    private static func offlineClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "http://127.0.0.1:1")!, supabaseKey: "offline",
            options: SupabaseClientOptions(auth: .init(storage: ConsentMemoryAuthStorage(), autoRefreshToken: false,
                                                       emitLocalSessionAsInitialSession: true)))
    }
}

private final class ConsentMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}
