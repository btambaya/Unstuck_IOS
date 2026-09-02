// CallScript vectors (the verbatim opening + the call instructions + the
// live tool list), IncomingCallPayload decoding, CallSession derivations,
// CallSettings window logic, and the pure CallToolLogic guards/formatting
// behind request_call / update_call.

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
            "Hi Ahmad — you asked me to call about speak to James. Your notes: Ask about the invoice; Confirm Friday; Send the deck. Your first step was: open the thread. Want to tick any off, add something, start a timer, or should I call back in ten?")
    }

    func testOpeningWithoutNameOrNotes() {
        let s = session(name: nil, notes: [], taskId: nil)
        XCTAssertEqual(
            CallScript.opening(s),
            "Hi — you asked me to call about speak to James. You didn't leave any notes. Want to tick any off, add something, start a timer, or should I call back in ten?")
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

    func testNotesSentenceTrimsAndDropsBlanks() {
        XCTAssertEqual(CallScript.notesSentence([" A ", "", "B"]), "Your notes: A; B.")
        XCTAssertEqual(CallScript.notesSentence([]), "You didn't leave any notes.")
    }

    // MARK: instructions + tools

    func testInstructionsCarryOpeningVerbatimToolsAndGuards() {
        let s = session(captures: ["ping Sam"])
        let i = CallScript.instructions(s)
        XCTAssertTrue(i.contains("\"" + CallScript.opening(s) + "\""), "opening quoted verbatim")
        XCTAssertTrue(i.contains("verbatim"))
        XCTAssertTrue(i.contains("Never claim an action happened without its tool result"))
        XCTAssertTrue(i.contains("English"))
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

    func testTimeGuardStrings() {
        let now = date(2026, 9, 2, 15, 0)
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 2, 10, 0), now: now, calendar: cal),
                       "error: 10:00 today is already past (it's 15:00 now). Ask for a later time.")
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 1, 10, 0), now: now, calendar: cal),
                       "error: 2026-09-01 10:00 is in the PAST (it's 2026-09-02 15:00 now). Ask for a later time or another day.")
        XCTAssertEqual(CallToolLogic.timeGuard(date(2026, 9, 3, 5, 30), now: now, calendar: cal),
                       "error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window")
        XCTAssertNil(CallToolLogic.timeGuard(date(2026, 9, 2, 15, 0), now: now, calendar: cal), "now itself is fine (30 s slack)")
        XCTAssertNil(CallToolLogic.timeGuard(date(2026, 9, 2, 16, 45), now: now, calendar: cal))
    }

    func testNotesArgAcceptsArrayOrLines() {
        XCTAssertEqual(CallToolLogic.notes(["A", " B ", ""]), ["A", "B"])
        XCTAssertEqual(CallToolLogic.notes("A\nB; C"), ["A", "B", "C"])
        XCTAssertEqual(CallToolLogic.notes(nil), [])
        XCTAssertEqual(CallToolLogic.notes(Array(repeating: "x", count: 12)).count, 8)
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

    func testDuplicateAnchorDetection() {
        let at = date(2026, 9, 2, 16, 45)
        let rows = [
            CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(at), label: "x"),
            CallRequest(id: "r2", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)), label: "standalone"),
        ]
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: "t1", blockId: "b1", callAt: at)?.id, "r1")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: "t1", blockId: "b2", callAt: date(2026, 9, 2, 19, 0)), "a different block of the same task is a different anchor")
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: "t1", blockId: nil, callAt: date(2026, 9, 2, 19, 0))?.id, "r1", "no block given → the task is the anchor")
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: nil, blockId: nil, callAt: date(2026, 9, 2, 18, 0).addingTimeInterval(20))?.id, "r2")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: "t9", blockId: nil, callAt: date(2026, 9, 2, 19, 0)))
        // Web rule: a standalone call with the same label (case-insensitive) is the same anchor.
        XCTAssertEqual(CallToolLogic.duplicate(in: rows, taskId: nil, blockId: nil, callAt: date(2026, 9, 2, 20, 0), label: " Standalone ")?.id, "r2")
        XCTAssertNil(CallToolLogic.duplicate(in: rows, taskId: nil, blockId: nil, callAt: date(2026, 9, 2, 20, 0), label: "other"))
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
