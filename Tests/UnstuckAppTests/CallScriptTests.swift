// CallScript vectors (the verbatim opening + the call instructions + the
// live tool list), IncomingCallPayload decoding, CallSession derivations,
// CallSettings window logic, the pure CallToolLogic guards/formatting behind
// request_call / update_call, and the CallTools executor over a fake store +
// the executor's in-memory AssistantAppState (scratch resolution, JSON-null
// notes, the web duplicate rule, compare-and-set misses).

import XCTest
import UnstuckCore
import UnstuckSync
@testable import Unstuck

final class CallScriptTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.date(from: c)!
    }

    private func session(name: String? = "Ahmad", label: String = "speak to James",
                         notes: [String] = ["Ask about the invoice", "Confirm Friday", "Send the deck"],
                         taskId: String? = "t1", startTime: String? = nil, firstAction: String? = nil,
                         captures: [String] = [], receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CallSession {
        CallSession(payload: IncomingCallPayload(
            callId: "0f1e2d3c-4b5a-4697-8877-665544332211", label: label, notes: notes,
            taskId: taskId, blockId: taskId.map { _ in "b1" }, taskName: "Speak to James",
            startTime: startTime, firstAction: firstAction, captures: captures, name: name), receivedAt: receivedAt)
    }

    // MARK: opening

    func testOpeningFullVector() {
        let s = session(firstAction: "open the thread")
        XCTAssertEqual(
            CallScript.opening(s),
            "Hi Ahmad — you asked me to ring so you'd speak to James. You wanted to remember: Ask about the invoice; Confirm Friday; Send the deck. Your first step was: open the thread. Start the timer, or ring you back in ten?")
    }

    func testOpeningWithoutNameOrNotesOrTaskOffersOnlyWhatApplies() {
        // No notes to tick off, no task to time: the old four-way menu named
        // both. Now: one plain question, and no "you didn't leave any notes"
        // filler.
        let s = session(name: nil, notes: [], taskId: nil)
        XCTAssertEqual(
            CallScript.opening(s),
            "Hi — you asked me to ring so you'd speak to James. Anything you want me to note?")
    }

    func testOpeningRendersTheLabelByShape() {
        // A verb-phrase label (what the prompt asks for) is framed "so you'd …";
        // a noun (a name, "the dentist", a task title) is framed "about …" —
        // never "ring about speak to James".
        XCTAssertTrue(CallScript.opening(session(label: "James")).hasPrefix("Hi Ahmad — you asked me to ring about James."))
        XCTAssertTrue(CallScript.opening(session(label: "the dentist")).hasPrefix("Hi Ahmad — you asked me to ring about the dentist."))
        XCTAssertTrue(CallScript.opening(session(label: "Dentist appointment")).hasPrefix("Hi Ahmad — you asked me to ring about Dentist appointment."))
        XCTAssertTrue(CallScript.opening(session(label: "speak to James")).hasPrefix("Hi Ahmad — you asked me to ring so you'd speak to James."))
        XCTAssertTrue(CallScript.opening(session(label: "to ring the bank")).hasPrefix("Hi Ahmad — you asked me to ring so you'd ring the bank."))
        XCTAssertFalse(CallScript.opening(session(label: "speak to James")).contains("ring about speak"))
    }

    func testLabelShapeAndReasonPhrase() {
        XCTAssertEqual(CallScript.labelShape("speak to James"), .verbPhrase)
        XCTAssertEqual(CallScript.labelShape("Chase the invoice"), .verbPhrase)
        XCTAssertEqual(CallScript.labelShape("to call mum"), .verbPhrase)
        XCTAssertEqual(CallScript.labelShape("James"), .nounPhrase)
        XCTAssertEqual(CallScript.labelShape("the dentist"), .nounPhrase)
        XCTAssertEqual(CallScript.labelShape("Q3 planning"), .nounPhrase)
        XCTAssertEqual(CallScript.labelShape(""), .nounPhrase)
        XCTAssertEqual(CallScript.reasonPhrase("  speak to James "), "so you'd speak to James")
        XCTAssertEqual(CallScript.reasonPhrase("To ring the bank"), "so you'd ring the bank")
        XCTAssertEqual(CallScript.reasonPhrase("James"), "about James")
    }

    func testOfferSentenceIsOneQuestionChosenByWhatApplies() {
        // One short question, never a menu: the timer/ring-back only when a
        // task is attached; "anything to add" only when there are notes.
        XCTAssertEqual(CallScript.offerSentence(hasTask: true, hasNotes: true), "Start the timer, or ring you back in ten?")
        XCTAssertEqual(CallScript.offerSentence(hasTask: true, hasNotes: false), "Start the timer, or ring you back in ten?")
        XCTAssertEqual(CallScript.offerSentence(hasTask: false, hasNotes: true), "Anything to add?")
        XCTAssertEqual(CallScript.offerSentence(hasTask: false, hasNotes: false), "Anything you want me to note?")
        // Notes-only (no task) never offers a timer; task-only never mentions notes.
        let notesOnly = CallScript.opening(session(notes: ["A"], taskId: nil))
        XCTAssertFalse(notesOnly.contains("timer"))
        XCTAssertTrue(notesOnly.contains("You wanted to remember: A."))
        XCTAssertTrue(notesOnly.hasSuffix("Anything to add?"))
        let taskOnly = CallScript.opening(session(notes: [], taskId: "t1"))
        XCTAssertFalse(taskOnly.contains("tick any off"))
        XCTAssertFalse(taskOnly.contains("notes"))
        XCTAssertTrue(taskOnly.contains("Start the timer"))
        // Every closing is exactly one question — one question mark, no menu.
        for (t, n) in [(true, true), (true, false), (false, true), (false, false)] {
            XCTAssertEqual(CallScript.offerSentence(hasTask: t, hasNotes: n).filter { $0 == "?" }.count, 1)
        }
    }

    func testOpeningUsesFirstNameOnly() {
        XCTAssertTrue(CallScript.opening(session(name: "Ahmad Tambaya")).hasPrefix("Hi Ahmad — "))
        XCTAssertTrue(CallScript.opening(session(name: "   ")).hasPrefix("Hi — "))
    }

    func testOpeningStartsInMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(12 * 60))
        let s = session(startTime: iso, receivedAt: now)
        XCTAssertTrue(CallScript.opening(s, now: now).contains("It starts in 12 minutes."), CallScript.opening(s, now: now))
        XCTAssertEqual(CallScript.startLine(session(startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(60)), receivedAt: now), now: now), "It starts in a minute.")
        XCTAssertEqual(CallScript.startLine(session(startTime: ISO8601DateFormatter().string(from: now), receivedAt: now), now: now), "It starts now.")
        XCTAssertEqual(CallScript.startLine(session(startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 60)), receivedAt: now), now: now), "It started 5 minutes ago.")
        XCTAssertNil(CallScript.startLine(session(), now: now))
    }

    func testNotesSentenceTrimsAndDropsBlanksAndIsNilWhenEmpty() {
        XCTAssertEqual(CallScript.notesSentence([" A ", "", "B"]), "You wanted to remember: A; B.")
        XCTAssertNil(CallScript.notesSentence([]))
        XCTAssertNil(CallScript.notesSentence(["  ", ""]))
    }

    // MARK: instructions + tools

    func testInstructionsCarryOpeningVerbatimToolsAndGuards() {
        let s = session(captures: ["ping Sam"])
        let i = CallScript.instructions(s)
        XCTAssertTrue(i.contains("\"" + CallScript.opening(s) + "\""), "opening quoted verbatim")
        XCTAssertTrue(i.contains("verbatim"))
        XCTAssertTrue(i.contains("Never claim an action happened without its tool result"))
        XCTAssertTrue(i.contains("English"))
        XCTAssertTrue(i.contains("times the way people say them"))
        XCTAssertTrue(i.contains("say bye"))
        for t in ["complete_task", "add_capture", "schedule_task", "start_focus", "update_call", "snooze_call"] {
            XCTAssertTrue(i.contains(t), t)
        }
        XCTAssertTrue(i.contains("- task: Speak to James [id=t1]"))
        XCTAssertTrue(i.contains("- notes (verbatim): \"Ask about the invoice\", \"Confirm Friday\", \"Send the deck\""))
        XCTAssertTrue(i.contains("- recent captures on it: \"ping Sam\""))
        XCTAssertTrue(i.contains("call id 0f1e2d3c-4b5a-4697-8877-665544332211"))
    }

    func testCallToolsList() {
        XCTAssertEqual(CallScript.callTools,
                       ["complete_task", "add_capture", "schedule_task", "start_focus", "update_call", "snooze_call"])
    }

    // MARK: payload decoding

    func testPayloadDecodesContractShape() throws {
        let json = """
        {"kind":"call","callId":"abc","label":"speak to James","notes":["A"," B ",""],"taskId":"t1","blockId":"b1",
         "taskName":"Speak to James","startTime":"2026-09-02T14:45:00Z","firstAction":"open the thread",
         "captures":["x"],"name":"Ahmad"}
        """
        let p = try JSONDecoder().decode(IncomingCallPayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.callId, "abc")
        XCTAssertEqual(p.notes, ["A", "B"])
        XCTAssertEqual(p.captures, ["x"])
        XCTAssertEqual(p.name, "Ahmad")
        XCTAssertEqual(p.blockId, "b1")
    }

    func testPayloadDefaultsMissingArraysAndBlanks() throws {
        let p = try JSONDecoder().decode(IncomingCallPayload.self, from: Data("{\"callId\":\"x\",\"label\":\"y\",\"name\":\"  \"}".utf8))
        XCTAssertEqual(p.notes, [])
        XCTAssertEqual(p.captures, [])
        XCTAssertNil(p.name)
        XCTAssertNil(p.taskId)
    }

    func testPayloadRequiresCallIdAndLabel() {
        XCTAssertNil(IncomingCallPayload(dictionary: ["label": "x"]))
        XCTAssertNil(IncomingCallPayload(dictionary: ["callId": "x", "label": "   "]))
        XCTAssertNil(IncomingCallPayload(dictionary: ["aps": ["alert": "hi"]]))
        XCTAssertNotNil(IncomingCallPayload(dictionary: ["callId": "x", "label": "y"]))
        XCTAssertEqual(IncomingCallPayload(dictionary: ["aps": ["alert": "x"], "data": ["callId": "n", "label": "nested"]])?.label, "nested")
    }

    func testSessionUUIDFromCallIdOrRandom() {
        let s = session()
        XCTAssertEqual(s.uuid, UUID(uuidString: "0f1e2d3c-4b5a-4697-8877-665544332211"))
        let other = CallSession(payload: IncomingCallPayload(callId: "not-a-uuid", label: "x"))
        XCTAssertEqual(other.callId, "not-a-uuid")
        XCTAssertNotEqual(other.uuid, s.uuid)
    }

    func testParseStartAcceptsISOClockAndLocalForms() {
        let anchor = date(2026, 9, 2, 10, 0)
        XCTAssertEqual(CallSession.parseStart("2026-09-02T13:45:00Z", relativeTo: anchor, calendar: cal),
                       ISO8601DateFormatter().date(from: "2026-09-02T13:45:00Z"))
        XCTAssertEqual(CallSession.parseStart("14:45", relativeTo: anchor, calendar: cal), date(2026, 9, 2, 14, 45))
        XCTAssertEqual(CallSession.parseStart("2026-09-03 09:05", relativeTo: anchor, calendar: cal), date(2026, 9, 3, 9, 5))
        XCTAssertEqual(CallSession.parseStart("2026-09-03T09:05", relativeTo: anchor, calendar: cal), date(2026, 9, 3, 9, 5))
        XCTAssertNil(CallSession.parseStart("25:00", relativeTo: anchor, calendar: cal))
        XCTAssertNil(CallSession.parseStart("soon", relativeTo: anchor, calendar: cal))
        XCTAssertNil(CallSession.parseStart(nil, relativeTo: anchor, calendar: cal))
    }

    // MARK: settings window

    func testWindowInsideOutsideOvernightAndEqual() {
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 8, 0), start: "08:00", end: "21:00", calendar: cal))
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 20, 59), start: "08:00", end: "21:00", calendar: cal))
        XCTAssertFalse(CallSettings.isWithinWindow(date(2026, 9, 2, 21, 0), start: "08:00", end: "21:00", calendar: cal))
        XCTAssertFalse(CallSettings.isWithinWindow(date(2026, 9, 2, 7, 59), start: "08:00", end: "21:00", calendar: cal))
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 23, 30), start: "22:00", end: "02:00", calendar: cal))
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 1, 0), start: "22:00", end: "02:00", calendar: cal))
        XCTAssertFalse(CallSettings.isWithinWindow(date(2026, 9, 2, 12, 0), start: "22:00", end: "02:00", calendar: cal))
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 3, 0), start: "09:00", end: "09:00", calendar: cal))
        XCTAssertTrue(CallSettings.isWithinWindow(date(2026, 9, 2, 3, 0), start: "junk", end: "09:00", calendar: cal))
    }

    func testServerWindowInclusive() {
        XCTAssertTrue(CallSettings.isWithinServerWindow(date(2026, 9, 2, 6, 0), calendar: cal))
        XCTAssertTrue(CallSettings.isWithinServerWindow(date(2026, 9, 2, 23, 0), calendar: cal))
        XCTAssertFalse(CallSettings.isWithinServerWindow(date(2026, 9, 2, 5, 59), calendar: cal))
        XCTAssertFalse(CallSettings.isWithinServerWindow(date(2026, 9, 2, 23, 1), calendar: cal))
    }

    // MARK: tool logic

    /// The past refusals are the SHARED UnstuckCore strings (with the free
    /// windows / the "use <date> — see context.upcoming" repair hint); only
    /// the 06:00–23:00 window string is local.
    func testTimeGuardUsesTheSharedPastRefusalsThenTheServerWindow() {
        let now = date(2026, 9, 2, 15, 0)
        let blocks = [CalBlock(id: "b", taskId: "t", taskName: "T", startTime: "16:00", durationMinutes: 30, date: "2026-09-02")]
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 2, 10, 0), now: now, blocks: blocks, calendar: cal),
                       rejectPastTime(blocks: blocks, today: "2026-09-02", date: "2026-09-02", startTime: "10:00", nowHM: "15:00"))
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 2, 10, 0), now: now, blocks: blocks, calendar: cal),
                       "error: 10:00 today is already past (it's 15:00 now). Ask for a later time or another day — free today: 15:15–16:00, 16:30–21:00.")
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 1, 10, 0), now: now, calendar: cal),
                       rejectPastDate(today: "2026-09-02", date: "2026-09-01"))
        XCTAssertTrue(CallToolLogic.timeGuard(date(2026, 9, 1, 10, 0), now: now, calendar: cal)!.contains("see context.upcoming"))
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 3, 5, 30), now: now, calendar: cal),
                       "error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window")
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 2, 23, 30), now: now, calendar: cal),
                       "error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window")
        XCTAssertNotNil(CallToolLogic.timeGuard(date(2026, 9, 2, 15, 0), now: now, calendar: cal), "the current minute is past, like the web")
        XCTAssertNil(CallToolLogic.timeGuard(date(2026, 9, 2, 15, 1), now: now, calendar: cal))
        XCTAssertNil(CallToolLogic.timeGuard(date(2026, 9, 2, 16, 45), now: now, calendar: cal))
        XCTAssertNil(CallToolLogic.timeGuard(date(2026, 9, 3, 6, 0), now: now, calendar: cal), "tomorrow at the window edge")
    }

    /// 20 notes × 300 chars (web MAX_CALL_NOTES); a string splits on NEWLINES
    /// only — a note may contain ";".
    func testNotesArgAcceptsArrayOrLinesAndCapsLikeTheWeb() {
        XCTAssertEqual(CallToolLogic.notes(["A", " B ", ""]), ["A", "B"])
        XCTAssertEqual(CallToolLogic.notes("A\nB; C\r\n\nD"), ["A", "B; C", "D"])
        XCTAssertEqual(CallToolLogic.notes(nil), [])
        XCTAssertEqual(CallToolLogic.notes(NSNull()), [])
        XCTAssertEqual(CallToolLogic.notes(Array(repeating: "x", count: 25)).count, 20)
        XCTAssertEqual(CallToolLogic.notes([String(repeating: "y", count: 400)])[0].count, 300)
        XCTAssertFalse(CallToolLogic.isPresent(nil))
        XCTAssertFalse(CallToolLogic.isPresent(NSNull()))
        XCTAssertTrue(CallToolLogic.isPresent([] as [String]))
        XCTAssertEqual(CallToolLogic.notesCount([]), "0 notes")
        XCTAssertEqual(CallToolLogic.notesCount(["a"]), "1 note")
    }

    func testJoinDateTimeAndInt() {
        XCTAssertEqual(CallToolLogic.joinDateTime(["date": "2026-09-03", "startTime": "09:00"]), "2026-09-03 09:00")
        XCTAssertEqual(CallToolLogic.joinDateTime(["startTime": "09:00"]), "09:00")
        XCTAssertNil(CallToolLogic.joinDateTime(["date": "2026-09-03"]))
        XCTAssertEqual(CallToolLogic.int("15"), 15)
        XCTAssertEqual(CallToolLogic.int(15.0), 15)
        XCTAssertNil(CallToolLogic.int("x"))
    }

    func testNextLiveBlockAndStart() {
        let now = date(2026, 9, 2, 15, 0)
        let blocks = [
            CalBlock(id: "old", taskId: "t", taskName: "T", startTime: "09:00", durationMinutes: 30, date: "2026-09-01"),
            CalBlock(id: "done", taskId: "t", taskName: "T", startTime: "16:00", durationMinutes: 30, date: "2026-09-02", done: true),
            CalBlock(id: "next", taskId: "t", taskName: "T", startTime: "17:00", durationMinutes: 30, date: "2026-09-02"),
            CalBlock(id: "later", taskId: "t", taskName: "T", startTime: "09:00", durationMinutes: 30, date: "2026-09-03"),
        ]
        let b = CallToolLogic.nextLiveBlock(blocks, now: now, calendar: cal)
        XCTAssertEqual(b?.id, "next")
        XCTAssertEqual(CallToolLogic.blockStart(b!, calendar: cal), date(2026, 9, 2, 17, 0))
        XCTAssertNil(CallToolLogic.nextLiveBlock([], now: now, calendar: cal))
    }

    /// The web rule exactly: with a task → any live call for that task (the
    /// block doesn't matter); without → a case-insensitive label match. No
    /// same-minute rule.
    func testDuplicateAnchorDetectionIsTheWebRule() {
        let at = date(2026, 9, 2, 16, 45)
        let rows = [
            CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(at), label: "x"),
            CallRequest(id: "r2", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "standalone"),
            CallRequest(id: "r3", taskId: "t3", callAt: CallsClient.iso(date(2026, 9, 2, 19, 0)), label: "gone", status: "cancelled"),
        ]
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: "t1", label: "whatever")?.id, "r1")
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: "t1", label: nil)?.id, "r1", "a different block of the same task is STILL the same anchor")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: "t9", label: "standalone"), "task given → only the task counts")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: "t3", label: nil), "a cancelled call is not live")
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: nil, label: " Standalone ")?.id, "r2")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: nil, label: "other"))
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: nil, label: nil))
        // Same minute, different label → fine (the old iOS-only rule is gone).
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: nil, label: "x at 18:00 too"))
    }

    func testGetCallsFormatMatchesTheWebContract() {
        let rows = [
            CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(date(2026, 9, 2, 16, 45)), label: "speak to James", notes: ["A", "B"]),
            CallRequest(id: "r2", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "standalone", status: "snoozed",
                        snoozeUntil: CallsClient.iso(date(2026, 9, 2, 18, 10))),
            CallRequest(id: "r3", callAt: CallsClient.iso(date(2026, 9, 2, 19, 0)), label: "ringing", notes: ["x"], status: "calling"),
        ]
        let out = CallToolLogic.formatCalls(rows, taskName: { $0 == "t1" ? "Speak to James" : nil }, calendar: cal)
        XCTAssertEqual(out, """
        ok: 3 upcoming calls:
        - 2026-09-02 16:45 "speak to James" (2 notes) for "Speak to James" [id=r1]
        - 2026-09-02 18:10 "standalone" (0 notes) · snoozed [id=r2]
        - 2026-09-02 19:00 "ringing" (1 note) · ringing now [id=r3]
        """)
        XCTAssertEqual(CallToolLogic.formatCalls([], taskName: { _ in nil }, calendar: cal), "ok: no calls booked")
        XCTAssertTrue(CallToolLogic.formatCalls([rows[0]], taskName: { _ in nil }, calendar: cal).hasPrefix("ok: 1 upcoming call:\n"))
    }

    func testCallRequestDecodesPostgRESTRow() throws {
        let json = """
        {"id":"r1","user_id":"u","task_id":null,"block_id":null,"call_at":"2026-09-02T14:45:00+00:00",
         "lead_min":null,"label":"speak to James","notes":["A","B"],"status":"snoozed",
         "snooze_until":"2026-09-02T15:00:00+00:00","outcome_notes":null,"call_id":"c1","attempts":1,
         "created_at":"2026-09-02T10:00:00.123456+00:00","updated_at":"2026-09-02T10:00:00+00:00"}
        """
        let r = try JSONDecoder().decode(CallRequest.self, from: Data(json.utf8))
        XCTAssertEqual(r.notes, ["A", "B"])
        XCTAssertEqual(r.outcomeNotes, [])
        XCTAssertTrue(r.isLive)
        XCTAssertEqual(r.callAtDate, ISO8601DateFormatter().date(from: "2026-09-02T14:45:00Z"))
        XCTAssertEqual(r.effectiveAtDate, ISO8601DateFormatter().date(from: "2026-09-02T15:00:00Z"), "snoozed → snooze_until")
    }
}

// MARK: - CallTools over a fake store + the executor's in-memory app state

/// call_requests as the tools see them — every write is recorded; `vanished`
/// ids make patch/cancel return nil (zero rows: the row changed underneath).
@MainActor
final class FakeCallStore: CallStore {
    var rows: [CallRequest] = []
    var booked: [CallRequest] = []
    struct Patch: Equatable { let id: String; let callAt: Date?; let blockId: String??; let leadMin: Int??; let label: String?; let notes: [String]? }
    var patches: [Patch] = []
    var cancelled: [String] = []
    var vanished: Set<String> = []

    func liveCalls() async throws -> [CallRequest] { rows.filter(\.isLive) }
    func call(id: String) async throws -> CallRequest? { rows.first { $0.id == id } }
    func book(userId: String, taskId: String?, blockId: String?, callAt: Date, leadMin: Int?,
              label: String, notes: [String]) async throws -> CallRequest {
        let r = CallRequest(id: "new-\(booked.count + 1)", userId: userId, taskId: taskId, blockId: blockId,
                            callAt: CallsClient.iso(callAt), leadMin: leadMin, label: label, notes: notes)
        booked.append(r); rows.append(r)
        return r
    }
    func patch(id: String, callAt: Date?, blockId: String??, leadMin: Int??,
               label: String?, notes: [String]?) async throws -> CallRequest? {
        patches.append(Patch(id: id, callAt: callAt, blockId: blockId, leadMin: leadMin, label: label, notes: notes))
        guard !vanished.contains(id), let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        if let callAt { rows[i].callAt = CallsClient.iso(callAt); rows[i].status = "scheduled"; rows[i].snoozeUntil = nil }
        if let blockId { rows[i].blockId = blockId }
        if let leadMin { rows[i].leadMin = leadMin }
        if let label { rows[i].label = label }
        if let notes { rows[i].notes = notes }
        return rows[i]
    }
    func cancelCall(id: String) async throws -> CallRequest? {
        cancelled.append(id)
        guard !vanished.contains(id), let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        rows[i].status = "cancelled"
        return rows[i]
    }
}

@MainActor
final class CallToolsTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.date(from: c)!
    }
    private var api: FakeAssistantState!
    private var scratch: TurnScratch!
    private var store: FakeCallStore!
    /// 2026-09-02 15:00 London.
    private var now: Date { date(2026, 9, 2, 15, 0) }

    override func setUp() {
        super.setUp()
        api = FakeAssistantState(); api.today = "2026-09-02"; api.now = "15:00"
        scratch = TurnScratch()
        store = FakeCallStore()
    }

    private func run(_ name: String, _ args: [String: Any]) async -> String {
        await CallTools.run(name: name, args: args, api: api, scratch: scratch, store: store,
                            userId: "u1", now: now, calendar: cal)
    }
    private func expect(_ name: String, _ args: [String: Any], _ want: String?,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let got = await run(name, args)
        XCTAssertEqual(got, want, file: file, line: line)
    }
    private func task(_ id: String, _ name: String) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: 25, tags: [], createdAt: "x", updatedAt: "x")
    }

    // MARK: request_call resolves through the executor's scratch + state

    func testRequestCallFindsATaskCreatedThisTurnAndItsFreshBlock() async {
        // create_task + block_time earlier in the SAME turn: the task is only
        // in the scratch, the block only in the executor's state.
        scratch.newTasks["t-new"] = task("t-new", "Speak to James")
        api.blocks = [CalBlock(id: "b-new", taskId: "t-new", taskName: "Speak to James", startTime: "17:00", durationMinutes: 30, date: "2026-09-03")]
        let r = await run("request_call", ["taskId": "t-new", "leadMin": 10, "notes": ["Ask about the invoice"]])
        XCTAssertEqual(r, "ok: call booked 2026-09-03 16:50 \"Speak to James\" (1 note) id=new-1")
        XCTAssertEqual(store.booked.count, 1)
        XCTAssertEqual(store.booked[0].taskId, "t-new")
        XCTAssertEqual(store.booked[0].blockId, "b-new")
        XCTAssertEqual(store.booked[0].leadMin, 10)
        XCTAssertEqual(store.booked[0].userId, "u1")
    }

    func testRequestCallUnknownTaskAndNoSlot() async {
        await expect("request_call", ["taskId": "nope"], "error: task not found")
        api.tasks = [task("t1", "Write the deck")]
        await expect("request_call", ["taskId": "t1"], "error: \"Write the deck\" has no upcoming slot — schedule_task it first, or give a time with when")
        XCTAssertTrue(store.booked.isEmpty)
    }

    func testRequestCallPastRefusalsAreTheSharedStrings() async {
        let past = await run("request_call", ["label": "speak to James", "when": "2026-09-02 10:00"])
        XCTAssertEqual(past, rejectPastTime(blocks: [], today: "2026-09-02", date: "2026-09-02", startTime: "10:00", nowHM: "15:00"))
        let yesterday = await run("request_call", ["label": "speak to James", "when": "2026-09-01 10:00"])
        XCTAssertEqual(yesterday, rejectPastDate(today: "2026-09-02", date: "2026-09-01"))
        let window = await run("request_call", ["label": "speak to James", "when": "2026-09-03 05:00"])
        XCTAssertEqual(window, "error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window")
        XCTAssertTrue(store.booked.isEmpty)
    }

    func testRequestCallDuplicateIsTheWebRule() async {
        api.tasks = [task("t1", "Speak to James")]
        api.blocks = [CalBlock(id: "b2", taskId: "t1", taskName: "Speak to James", startTime: "18:00", durationMinutes: 30, date: "2026-09-03")]
        store.rows = [
            CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(date(2026, 9, 2, 16, 45)), label: "Speak to James"),
            CallRequest(id: "r2", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "dentist"),
        ]
        // Same task, different block → still a duplicate.
        await expect("request_call", ["taskId": "t1", "leadMin": 5], "error: a call is already booked for \"Speak to James\" at 2026-09-02 16:45 id=r1 — update_call or cancel_call it")
        // Standalone: label match, case-insensitive.
        await expect("request_call", ["label": "DENTIST", "when": "2026-09-02 20:00"], "error: a call is already booked for \"dentist\" at 2026-09-02 18:00 id=r2 — update_call or cancel_call it")
        // Standalone at the SAME minute as r2 with another label → fine (no same-minute rule).
        await expect("request_call", ["label": "call mum", "when": "2026-09-02 18:00"], "ok: call booked 2026-09-02 18:00 \"call mum\" (0 notes) id=new-1")
    }

    // MARK: update_call / cancel_call

    func testUpdateCallJSONNullNotesLeavesNotesUntouched() async {
        store.rows = [CallRequest(id: "r1", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "dentist", notes: ["bring the form"])]
        // `notes: null` from the model → NSNull → not a change.
        await expect("update_call", ["callId": "r1", "notes": NSNull()], "error: nothing to change — give notes and/or when")
        XCTAssertTrue(store.patches.isEmpty)
        let r = await run("update_call", ["callId": "r1", "notes": NSNull(), "label": "dentist appt"])
        XCTAssertEqual(r, "ok: updated call \"dentist appt\" — 2026-09-02 18:00, 1 note id=r1")
        XCTAssertEqual(store.patches.count, 1)
        XCTAssertNil(store.patches[0].notes, "untouched")
        XCTAssertEqual(store.patches[0].label, "dentist appt")
        // A real (empty) array DOES replace them.
        _ = await run("update_call", ["callId": "r1", "notes": [] as [String]])
        XCTAssertEqual(store.patches.last?.notes, [])
    }

    func testUpdateCallMovesTimeAndDropsTheAnchor() async {
        store.rows = [CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(date(2026, 9, 2, 16, 45)), leadMin: 15, label: "x")]
        let r = await run("update_call", ["callId": "r1", "when": "2026-09-03 09:30", "notes": "A\nB; C"])
        XCTAssertEqual(r, "ok: updated call \"x\" — 2026-09-03 09:30, 2 notes id=r1")
        let p = store.patches[0]
        XCTAssertEqual(p.callAt, date(2026, 9, 3, 9, 30))
        XCTAssertEqual(p.blockId, .some(nil))
        XCTAssertEqual(p.leadMin, .some(nil))
        XCTAssertEqual(p.notes, ["A", "B; C"])
        await expect("update_call", ["callId": "r1", "when": "2026-09-02 09:30"], rejectPastTime(blocks: [], today: "2026-09-02", date: "2026-09-02", startTime: "09:30", nowHM: "15:00"))
    }

    func testUpdateAndCancelReportAChangeUnderneathInsteadOfEchoingTheOldRow() async {
        store.rows = [CallRequest(id: "r1", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "dentist")]
        store.vanished = ["r1"]
        await expect("update_call", ["callId": "r1", "label": "new"], CallTools.changedUnderneath)
        await expect("cancel_call", ["callId": "r1"], CallTools.changedUnderneath)
        XCTAssertEqual(CallTools.changedUnderneath, "error: that call changed underneath me — get_calls and try again")
        store.vanished = []
        await expect("cancel_call", ["callId": "r1"], "ok: cancelled the call about \"dentist\" (2026-09-02 18:00)")
        await expect("cancel_call", ["callId": "r1"], "error: that call is already cancelled")
        await expect("cancel_call", ["callId": "zzz"], "error: call not found — use get_calls")
        await expect("cancel_call", [:], "error: callId required — use get_calls to find it")
    }

    // MARK: update_call mid-call (answered / calling rows)

    func testUpdateCallEditsNotesAndLabelOnAnAnsweredCall() async {
        // The phone reports `answered` the moment the call is picked up, so
        // by the time the model runs update_call the row is 'answered' — the
        // in-call "add 'bring the contract' to the notes" must still land.
        store.rows = [CallRequest(id: "r1", callAt: CallsClient.iso(date(2026, 9, 2, 14, 55)), label: "dentist",
                                  notes: ["bring the form"], status: "answered")]
        let r = await run("update_call", ["callId": "r1", "notes": ["bring the form", "bring the contract"]])
        XCTAssertEqual(r, "ok: updated call \"dentist\" — 2026-09-02 14:55, 2 notes id=r1")
        XCTAssertEqual(store.patches.count, 1)
        XCTAssertEqual(store.patches[0].notes, ["bring the form", "bring the contract"])
        XCTAssertNil(store.patches[0].callAt)
        XCTAssertEqual(store.rows[0].status, "answered", "a notes edit never touches the status")
        // Label too — and on a ringing ('calling') row.
        store.rows[0].status = "calling"
        let l = await run("update_call", ["callId": "r1", "label": "dentist appt"])
        XCTAssertEqual(l, "ok: updated call \"dentist appt\" — 2026-09-02 14:55, 2 notes id=r1")
        XCTAssertEqual(store.rows[0].status, "calling")
    }

    func testUpdateCallRefusesATimeChangeWhileRingingOrAnswered() async {
        // Re-arming a ringing/answered row to 'scheduled' would be overwritten
        // by the phone's own outcome report (missed / done) a moment later —
        // the reschedule the tool just confirmed would silently vanish.
        for status in ["calling", "answered"] {
            store.rows = [CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(date(2026, 9, 2, 14, 55)),
                                      leadMin: 5, label: "x", status: status)]
            store.patches = []
            await expect("update_call", ["callId": "r1", "when": "2026-09-02 17:00"], CallTools.inProgress)
            await expect("update_call", ["callId": "r1", "leadMin": 10], CallTools.inProgress)
            XCTAssertTrue(store.patches.isEmpty, status)
            XCTAssertEqual(store.rows[0].status, status)
        }
        XCTAssertEqual(CallTools.inProgress, "error: that call is in progress right now — I can change its notes or label, but not its time; snooze_call or book another with request_call")
        // Finished rows are not editable at all.
        store.rows = [CallRequest(id: "r1", callAt: CallsClient.iso(date(2026, 9, 2, 14, 55)), label: "x", status: "done")]
        await expect("update_call", ["callId": "r1", "notes": ["A"]], "error: that call is already done — book a new one with request_call")
    }

    func testCallRequestStatusContract() {
        func row(_ status: String) -> CallRequest {
            CallRequest(id: "r", callAt: CallsClient.iso(date(2026, 9, 2, 14, 55)), label: "x", status: status)
        }
        XCTAssertEqual(CallRequest.liveStatuses, ["scheduled", "snoozed", "calling"])
        XCTAssertEqual(CallRequest.editableStatuses, ["scheduled", "snoozed", "calling", "answered"])
        XCTAssertEqual(CallRequest.reschedulableStatuses, ["scheduled", "snoozed"])
        XCTAssertTrue(row("answered").isEditable && row("answered").isInProgress && !row("answered").isLive)
        XCTAssertTrue(row("calling").isEditable && row("calling").isInProgress && row("calling").isLive)
        XCTAssertTrue(row("scheduled").isEditable && !row("scheduled").isInProgress)
        XCTAssertFalse(row("done").isEditable || row("cancelled").isEditable || row("missed").isEditable)
        // The compare-and-set list CallsClient.update sends: a time change
        // never matches a 'calling' row (so it can't flip it back to
        // 'scheduled'); a notes/label edit matches answered too.
        XCTAssertEqual(CallsClient.statusesAccepting(timeChange: true), ["scheduled", "snoozed"])
        XCTAssertEqual(CallsClient.statusesAccepting(timeChange: false), ["scheduled", "snoozed", "calling", "answered"])
    }

    func testCallOutcomeRejectedClassifiesPermanentStatuses() {
        for code in [400, 403, 404, 410, 422] { XCTAssertTrue(CallOutcomeRejected.isPermanent(status: code), "\(code)") }
        for code in [401, 408, 429, 500, 502, 503, 200] { XCTAssertFalse(CallOutcomeRejected.isPermanent(status: code), "\(code)") }
        let e = CallOutcomeRejected(status: 404, message: "not_found")
        XCTAssertTrue(CallsOutcomeReporter.isPermanent(e))
        XCTAssertFalse(CallsOutcomeReporter.isPermanent(NSError(domain: "net", code: -1009)))
    }

    // MARK: get_calls

    func testGetCallsNamesTasksFromTheScratchToo() async {
        scratch.newTasks["t-new"] = task("t-new", "Speak to James")
        store.rows = [
            CallRequest(id: "r1", taskId: "t-new", callAt: CallsClient.iso(date(2026, 9, 2, 16, 45)), label: "speak to James", notes: ["A"]),
            CallRequest(id: "r0", callAt: CallsClient.iso(date(2026, 9, 2, 16, 0)), label: "first", status: "done"),
        ]
        await expect("get_calls", [:], """
        ok: 1 upcoming call:
        - 2026-09-02 16:45 "speak to James" (1 note) for "Speak to James" [id=r1]
        """)
        store.rows = []
        await expect("get_calls", [:], "ok: no calls booked")
    }
}
