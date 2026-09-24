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
                         captures: [String] = [], receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                         kind: String? = nil, endTime: String? = nil, taskName: String? = "Speak to James") -> CallSession {
        CallSession(payload: IncomingCallPayload(
            callId: "0f1e2d3c-4b5a-4697-8877-665544332211", label: label, notes: notes,
            taskId: taskId, blockId: taskId.map { _ in "b1" }, taskName: taskName,
            startTime: startTime, firstAction: firstAction, captures: captures, name: name,
            callKind: kind, endTime: endTime), receivedAt: receivedAt)
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

    func testCallToolsIsEveryVoiceToolPlusTheCallExtras() {
        // A call is the full assistant on the phone (calls build-out): every
        // registry voice tool, in registry order, then the call-only extras.
        let voiceNames = ToolRegistry.voice.compactMap { $0["name"] as? String }
        let callNames = ToolRegistry.call.compactMap { $0["name"] as? String }
        XCTAssertFalse(voiceNames.isEmpty)
        XCTAssertEqual(Array(CallScript.callTools.prefix(voiceNames.count)), voiceNames)
        for n in callNames { XCTAssertTrue(CallScript.callTools.contains(n), n) }
        XCTAssertEqual(CallScript.callTools.count, Set(CallScript.callTools).count, "no duplicates")
        for t in ["get_schedule", "get_tasks", "carry_to_tomorrow", "complete_task", "schedule_task", "add_capture",
                  "share_task", "request_call", "update_call", "snooze_call", "skip_occurrence", "set_task_later"] {
            XCTAssertTrue(CallScript.callTools.contains(t), t)
        }
        // Pure: de-duplicated, order kept, blanks dropped.
        XCTAssertEqual(CallScript.callToolNames(voice: [["name": "a"], ["name": "b"], ["x": 1]],
                                                call: [["name": "b"], ["name": "c"], ["name": ""]]), ["a", "b", "c"])
    }

    // MARK: kinds (calls build-out §2)

    func testOpeningPerKind() {
        XCTAssertEqual(CallScript.opening(session(kind: "test")),
                       "Hi Ahmad — this is your test call from Unstuck. Everything works. Want to try something — ask me what's on today?")
        XCTAssertEqual(CallScript.opening(session(name: nil, kind: "test")),
                       "Hi — this is your test call from Unstuck. Everything works. Want to try something — ask me what's on today?")
        XCTAssertEqual(CallScript.opening(session(kind: "morning")), "Morning, Ahmad. Want to walk through today?")
        XCTAssertEqual(CallScript.opening(session(name: nil, kind: "morning")), "Morning. Want to walk through today?")
        XCTAssertEqual(CallScript.opening(session(kind: "evening")), "Evening, Ahmad. Quick wrap-up?")
        XCTAssertEqual(CallScript.opening(session(name: nil, kind: "evening")), "Evening. Quick wrap-up?")
        XCTAssertEqual(CallScript.opening(session(kind: "after_block", endTime: "11:30")),
                       "Hi Ahmad — Speak to James was on till 11:30am. How did it go?")
        XCTAssertEqual(CallScript.opening(session(kind: "after_block", endTime: "14:00", taskName: nil)),
                       "Hi Ahmad — speak to James was on till 2pm. How did it go?", "no task name → the label")
        XCTAssertEqual(CallScript.opening(session(name: nil, kind: "after_block", endTime: nil)),
                       "Hi — Speak to James just finished. How did it go?", "no end time → 'just finished'")
        // The requested opening is untouched — and the default when the push
        // carries no kind at all, or one this build doesn't know.
        let requested = "Hi Ahmad — you asked me to ring so you'd speak to James. You wanted to remember: Ask about the invoice; Confirm Friday; Send the deck. Start the timer, or ring you back in ten?"
        XCTAssertEqual(CallScript.opening(session()), requested)
        XCTAssertEqual(CallScript.opening(session(kind: "requested")), requested)
        XCTAssertEqual(CallScript.opening(session(kind: "something_new")), requested)
    }

    func testInstructionsPerKindKeepTheVerbatimOpeningAndTheHonestyRule() {
        for kind in ["requested", "test", "morning", "evening", "after_block"] {
            let s = session(kind: kind, endTime: "11:30")
            let i = CallScript.instructions(s)
            XCTAssertTrue(i.contains("\"" + CallScript.opening(s) + "\""), "\(kind): opening quoted verbatim")
            XCTAssertTrue(i.contains("1. Open by saying EXACTLY this, verbatim, before anything else"), kind)
            XCTAssertTrue(i.contains("Never claim an action happened without its tool result"), kind)
            XCTAssertTrue(i.contains("English"), kind)
            XCTAssertTrue(i.contains("say bye"), kind)
            XCTAssertTrue(i.contains("- kind: \(kind)"), kind)
            XCTAssertTrue(i.contains("update_call"), kind)
            XCTAssertTrue(i.contains("snooze_call"), kind)
        }
        XCTAssertTrue(CallScript.instructions(session()).contains("THIS IS A PHONE CALL the user asked you to make"))
        XCTAssertTrue(CallScript.instructions(session()).contains("read the notes word for word"))
        XCTAssertTrue(CallScript.instructions(session(kind: "test")).contains("TEST CALL"))
        XCTAssertTrue(CallScript.instructions(session(kind: "morning")).contains("get_schedule"))
        XCTAssertTrue(CallScript.instructions(session(kind: "morning")).contains("MORNING PLANNING CALL"))
        XCTAssertTrue(CallScript.instructions(session(kind: "evening")).contains("get_tasks(view: completed)"))
        XCTAssertTrue(CallScript.instructions(session(kind: "evening")).contains("carry_to_tomorrow ONLY when they ask"))
        let after = CallScript.instructions(session(kind: "after_block", endTime: "11:30"))
        XCTAssertTrue(after.contains("CHECK-IN AFTER A BLOCK"))
        XCTAssertTrue(after.contains("complete_task"))
        XCTAssertTrue(after.contains("skip_occurrence"))
        XCTAssertTrue(after.contains("schedule_task"))
        XCTAssertTrue(after.contains("- block ended at: "))
    }

    // MARK: day context (2026-09-20 — Zubair's evening call read nothing, then
    // an undated all-time list as "today")

    private let london = TimeZone(identifier: "Europe/London")!
    private func dayStore() -> ([TaskItem], [CalBlock]) {
        let tasks = [task("t-course", "Beginner course", done: true, completedAt: "2026-09-20T08:10:00.000Z"),
                     task("t-gym", "Gym"), task("t-mum", "Call mum"), task("t-dentist", "Dentist"),
                     task("t-sc200", "SC-200 revision", done: true, completedAt: "2026-09-19T10:00:00.000Z"),
                     task("t-late", "Late tick", done: true, completedAt: "2026-09-19T23:30:00.000Z")]   // 00:30 London on the 20th
        let blocks = [block("b6", "t-course", "2026-09-20", "09:00"), block("b7", "t-gym", "2026-09-20", "15:00"),
                      block("b8", "t-mum", "2026-09-20", "17:30"), block("b9", "t-dentist", "2026-09-21", "10:00"),
                      block("b5", "t-sc200", "2026-09-19", "09:00")]
        return (tasks, blocks)
    }

    func testDayContextEveningReadsDoneOpenAndTomorrowFromTheStore() {
        let (tasks, blocks) = dayStore()
        let lines = CallDayContext.lines(kind: .evening, tasks: tasks, blocks: blocks, today: "2026-09-20", nowHM: "19:01", tz: london)
        XCTAssertTrue(lines[0].hasPrefix("today: 2026-09-20 (") && lines[0].hasSuffix("), now 19:01"), lines[0])
        XCTAssertEqual(lines[1], "done today (2): Beginner course, Late tick", "by the LOCAL completion day — 23:30Z on the 19th is the 20th in London; SC-200 (the 19th) is not today")
        XCTAssertEqual(lines[2], "still open today (2): Gym (15:00), Call mum (17:30)")
        XCTAssertEqual(lines[3], "tomorrow starts with: Dentist at 10:00")
    }

    func testDayContextMorningAndAfterBlockAndEmptyDay() {
        let (tasks, blocks) = dayStore()
        let morning = CallDayContext.lines(kind: .morning, tasks: tasks, blocks: blocks, today: "2026-09-20", nowHM: "08:30", tz: london)
        XCTAssertEqual(morning[1], "today's plan (3): 09:00 Beginner course · done; 15:00 Gym; 17:30 Call mum")
        XCTAssertEqual(morning[2], "done today (2): Beginner course, Late tick")
        let after = CallDayContext.lines(kind: .afterBlock, tasks: tasks, blocks: blocks, today: "2026-09-20", nowHM: "15:50", tz: london)
        XCTAssertEqual(after[1], "still open today (2): Gym (15:00), Call mum (17:30)")
        let empty = CallDayContext.lines(kind: .evening, tasks: [], blocks: [], today: "2026-09-22", nowHM: "19:00", tz: london)
        XCTAssertEqual(Array(empty.dropFirst()), ["done today: nothing ticked off yet", "still open today: nothing", "tomorrow: nothing scheduled yet"])
        XCTAssertEqual(CallDayContext.localDate(ofISO: "2026-09-19T23:30:00Z", tz: london), "2026-09-20")
        XCTAssertNil(CallDayContext.localDate(ofISO: "nope", tz: london))
    }

    @MainActor func testInstructionsCarryTheDayContextAndTheEveningRuleNeverAsksWhatGotDone() {
        let i = CallScript.instructions(session(kind: "evening"), dayContext: ["done today (1): Beginner course", "still open today: nothing"])
        XCTAssertTrue(i.contains("- done today (1): Beginner course"), i)
        XCTAssertTrue(i.contains("- still open today: nothing"), i)
        XCTAssertTrue(i.contains("NEVER ask them what got done"), i)
        XCTAssertTrue(i.contains("read from the app as the call connected"), i)
        XCTAssertTrue(CallScript.instructions(session(kind: "morning")).contains("read today's plan from the call context"))
        let comp = RealtimeCallVoiceLauncher.compose(session: session(kind: "evening"), baseInstructions: "BASE", voiceTools: [], dayContext: ["done today (1): X"])
        XCTAssertTrue(comp.instructions.contains("- done today (1): X"), "the launcher threads the store's lines through")
    }

    func testPayloadParsesCallKindAndEndTimeTolerantly() throws {
        let json = """
        {"kind":"call","callKind":"after_block","endTime":"11:30","callId":"abc","label":"speak to James"}
        """
        let p = try JSONDecoder().decode(IncomingCallPayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.resolvedKind, .afterBlock)
        XCTAssertEqual(p.endTime, "11:30")
        XCTAssertEqual(CallSession(payload: p).kind, .afterBlock)
        XCTAssertEqual(CallSession(payload: p).spokenEnd, "11:30am")
        // A server that writes the row's kind into the push's own `kind`.
        let alt = try JSONDecoder().decode(IncomingCallPayload.self, from: Data("{\"kind\":\"morning\",\"callId\":\"x\",\"label\":\"Morning plan\"}".utf8))
        XCTAssertEqual(alt.resolvedKind, .morning)
        // Absent / blank / unknown → requested; the discriminator alone is not a kind.
        let plain = try JSONDecoder().decode(IncomingCallPayload.self, from: Data("{\"kind\":\"call\",\"callId\":\"x\",\"label\":\"y\",\"callKind\":\" \"}".utf8))
        XCTAssertEqual(plain.resolvedKind, .requested)
        XCTAssertNil(plain.callKind)
        XCTAssertEqual(IncomingCallPayload(dictionary: ["callId": "x", "label": "y", "callKind": "weird"])?.resolvedKind, .requested)
        XCTAssertEqual(CallKind(raw: " Evening "), .evening)
        XCTAssertEqual(CallKind(raw: nil), .requested)
        // The fallback-B tap recognises both spellings of a call push.
        XCTAssertTrue(IncomingCallPayload.isCallPush(kind: "call"))
        XCTAssertTrue(IncomingCallPayload.isCallPush(kind: "after_block"))
        XCTAssertFalse(IncomingCallPayload.isCallPush(kind: "task_reminder"))
        XCTAssertFalse(IncomingCallPayload.isCallPush(kind: nil))
    }

    func testSpokenTime() {
        XCTAssertEqual(CallSettings.spokenTime("09:00"), "9am")
        XCTAssertEqual(CallSettings.spokenTime("14:05"), "2:05pm")
        XCTAssertEqual(CallSettings.spokenTime("12:30"), "12:30pm")
        XCTAssertEqual(CallSettings.spokenTime("00:15"), "12:15am")
        XCTAssertEqual(CallSettings.spokenTime("23:00"), "11pm")
        XCTAssertEqual(CallSettings.spokenTime("soon"), "soon")
        // An ISO end time is spoken in local time too.
        let s = session(kind: "after_block", endTime: "2026-09-02 11:30")
        XCTAssertEqual(s.spokenEnd, "11:30am")
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

    // MARK: settings persistence (Settings › Notifications & calls)

    private func withFreshDefaults(_ body: () -> Void) {
        let name = "CallSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let previous = CallSettings.defaults
        CallSettings.defaults = d
        defer { CallSettings.defaults = previous; d.removePersistentDomain(forName: name) }
        body()
    }

    func testCallsSwitchDefaultsOnAndPersists() {
        withFreshDefaults {
            XCTAssertTrue(CallSettings.enabled, "a missing key is ON — bool(forKey:) would read false")
            CallSettings.enabled = false
            XCTAssertFalse(CallSettings.enabled)
            XCTAssertEqual(CallSettings.defaults.object(forKey: CallSettings.enabledKey) as? Bool, false)
            CallSettings.enabled = true
            XCTAssertTrue(CallSettings.enabled)
        }
    }

    func testHoursAndLeadPersistAndFallBackOnGarbage() {
        withFreshDefaults {
            // The server's window, like Android (audit 2026-09-22, C12).
            XCTAssertEqual(CallSettings.windowStart, "06:00")
            XCTAssertEqual(CallSettings.windowEnd, "23:00")
            XCTAssertEqual(CallSettings.windowStart, CallSettings.serverWindowStart)
            XCTAssertEqual(CallSettings.windowEnd, CallSettings.serverWindowEnd)
            XCTAssertEqual(CallSettings.defaultLeadMin, 15)
            CallSettings.windowStart = "07:30"; CallSettings.windowEnd = "22:15"; CallSettings.defaultLeadMin = 30
            XCTAssertEqual(CallSettings.windowStart, "07:30")
            XCTAssertEqual(CallSettings.windowEnd, "22:15")
            XCTAssertEqual(CallSettings.defaultLeadMin, 30)
            CallSettings.defaults.set("25:99", forKey: CallSettings.windowStartKey)
            XCTAssertEqual(CallSettings.windowStart, "06:00", "garbage → default")
        }
    }

    /// C13 (audit 2026-09-22): the foreground microphone prompt only when a
    /// call can actually ring on this phone.
    func testMicrophonePromptOnlyWhenACallCanRingHere() {
        withFreshDefaults {
            // Defaults: Calls on, every proactive call off.
            XCTAssertTrue(CallSettings.expectsCalls(hasCallRows: true))
            XCTAssertFalse(CallSettings.expectsCalls(hasCallRows: false))
            let off = CallProactivePrefs.defaults
            var p = off; p.morningEnabled = true
            CallSettings.proactive = p
            XCTAssertTrue(CallSettings.expectsCalls(hasCallRows: false), "morning call on")
            p = off; p.eveningEnabled = true
            CallSettings.proactive = p
            XCTAssertTrue(CallSettings.expectsCalls(hasCallRows: false), "evening call on")
            p = off; p.afterBlockEnabled = true
            CallSettings.proactive = p
            XCTAssertTrue(CallSettings.expectsCalls(hasCallRows: false), "after-block call on")
            // Calls off on this iPhone: it declines them, so never ask.
            CallSettings.enabled = false
            XCTAssertFalse(CallSettings.expectsCalls(hasCallRows: true))
            XCTAssertFalse(CallSettings.expectsCalls(hasCallRows: true, enabled: false, proactive: p))
        }
    }

    func testProactivePrefsCacheRoundTripsWithThePendingFlag() {
        withFreshDefaults {
            XCTAssertEqual(CallSettings.proactive, .defaults, "all off until the server row is read")
            XCTAssertFalse(CallSettings.pendingProactivePush)
            let p = CallProactivePrefs(morningEnabled: true, morningTime: "07:45", eveningEnabled: false,
                                       eveningTime: "18:00", afterBlockEnabled: true)
            CallSettings.proactive = p
            CallSettings.pendingProactivePush = true
            XCTAssertEqual(CallSettings.proactive, p)
            XCTAssertTrue(CallSettings.pendingProactivePush)
            CallSettings.pendingProactivePush = false
            XCTAssertFalse(CallSettings.pendingProactivePush)
            XCTAssertNil(CallSettings.defaults.object(forKey: CallSettings.pendingProactivePushKey), "cleared, not false")
            // Every call key is in the sign-out scrub list.
            for key in [CallSettings.enabledKey, CallSettings.windowStartKey, CallSettings.windowEndKey,
                        CallSettings.defaultLeadKey, CallSettings.proactiveKey, CallSettings.pendingProactivePushKey,
                        CallSettings.voipNudgeDismissedKey] {
                XCTAssertTrue(CallSettings.userContentKeys.contains(key), key)
            }
        }
    }

    func testProactivePrefsNormaliseServerTimes() {
        XCTAssertEqual(CallProactivePrefs.hhmm("08:30:00"), "08:30")
        XCTAssertEqual(CallProactivePrefs.hhmm("18:05:00.000"), "18:05")
        XCTAssertEqual(CallProactivePrefs.hhmm("7:5"), nil)
        XCTAssertEqual(CallProactivePrefs.hhmm("09:00"), "09:00")
        XCTAssertNil(CallProactivePrefs.hhmm(nil))
        XCTAssertNil(CallProactivePrefs.hhmm("25:00:00"))
        XCTAssertEqual(CallProactivePrefs.defaults.morningTime, "08:30")
        XCTAssertEqual(CallProactivePrefs.defaults.eveningTime, "18:00")
    }

    func testVoipNudgePolicy() {
        // No token 10 s after a signed-in launch, not yet acted on → show.
        XCTAssertTrue(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: true, secondsSinceStart: 10, dismissed: false))
        XCTAssertTrue(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: true, secondsSinceStart: 600, dismissed: false))
        XCTAssertFalse(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: true, secondsSinceStart: 9.9, dismissed: false), "still in the grace")
        XCTAssertFalse(VoipRegistrationNudge.shouldShow(tokenPresent: true, signedIn: true, secondsSinceStart: 60, dismissed: false), "a token arrived")
        XCTAssertFalse(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: false, secondsSinceStart: 60, dismissed: false), "signed out")
        XCTAssertFalse(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: true, secondsSinceStart: 60, dismissed: true), "one-time")
        XCTAssertFalse(VoipRegistrationNudge.shouldShow(tokenPresent: false, signedIn: true, secondsSinceStart: nil, dismissed: false), "registration never started")
        withFreshDefaults {
            XCTAssertFalse(CallSettings.voipNudgeDismissed)
            CallSettings.voipNudgeDismissed = true
            XCTAssertTrue(CallSettings.voipNudgeDismissed)
        }
    }

    func testPreviousTestCallsAreTheLiveOnesWithTheTestLabelOrKind() {
        let rows = [
            CallRequest(id: "a", callAt: "2026-09-02T14:00:00Z", label: "Test call", status: "scheduled"),
            CallRequest(id: "b", callAt: "2026-09-02T14:00:00Z", label: "test CALL ", status: "snoozed"),
            CallRequest(id: "c", callAt: "2026-09-02T14:00:00Z", label: "Test call", status: "done"),
            CallRequest(id: "d", callAt: "2026-09-02T14:00:00Z", label: "Ring", status: "scheduled", kind: "test"),
            CallRequest(id: "e", callAt: "2026-09-02T14:00:00Z", label: "speak to James", status: "scheduled"),
        ]
        XCTAssertEqual(CallSettingsView.previousTestCalls(in: rows).map(\.id), ["a", "b", "d"])
    }

    func testCallRequestKindDefaultsAndDecodes() throws {
        let row = try JSONDecoder().decode(CallRequest.self, from: Data("""
        {"id":"x","call_at":"2026-09-02T14:45:00+00:00","label":"Morning plan","status":"scheduled","kind":"morning","retries":1}
        """.utf8))
        XCTAssertEqual(row.kind, "morning")
        XCTAssertEqual(row.retries, 1)
        let old = try JSONDecoder().decode(CallRequest.self, from: Data("{\"id\":\"y\",\"call_at\":\"2026-09-02T14:45:00+00:00\",\"label\":\"z\"}".utf8))
        XCTAssertEqual(old.kind, "requested", "a pre-072 row")
        XCTAssertNil(old.retries)
        XCTAssertEqual(CallRequest(id: "n", callAt: "2026-09-02T14:45:00Z", label: "l").kind, "requested")
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
        // The minute form the pickers use is the same rule.
        XCTAssertTrue(CallSettings.isWithinWindow(minuteOfDay: 1259, start: "08:00", end: "21:00"))
        XCTAssertFalse(CallSettings.isWithinWindow(minuteOfDay: 1260, start: "08:00", end: "21:00"))
        XCTAssertTrue(CallSettings.isWithinWindow(minuteOfDay: 60, start: "22:00", end: "02:00"))
        XCTAssertTrue(CallSettings.isWithinWindow(minuteOfDay: 180, start: "09:00", end: "09:00"))
    }

    // MARK: will it ring here? (audit 2026-09-22, C12)

    func testDeviceGuardRefusesOutsideThePhonesHoursAndWhenCallsAreOff() {
        func guardAt(_ h: Int, _ m: Int, enabled: Bool = true, start: String = "08:00", end: String = "21:00") -> String? {
            CallToolLogic.deviceGuard(date(2026, 9, 2, h, m), enabled: enabled, start: start, end: end, calendar: cal)
        }
        XCTAssertNil(guardAt(20, 59))
        XCTAssertEqual(guardAt(21, 0), "error: 21:00 is outside this iPhone's call hours (08:00–21:00; the latest it rings is 20:59), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls",
                       "end exclusive, like the receipt rule — and said so, since 21:00 is the end it names")
        XCTAssertEqual(guardAt(7, 59), "error: 07:59 is outside this iPhone's call hours (08:00–21:00), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls")
        XCTAssertNil(guardAt(8, 0))
        XCTAssertNil(guardAt(23, 30, start: "22:00", end: "02:00"), "overnight window")
        XCTAssertNil(guardAt(3, 0, start: "09:00", end: "09:00"), "start == end → always")
        // The switch is checked before the hours.
        XCTAssertEqual(guardAt(12, 0, enabled: false), "error: calls are off on this iPhone, so it would decline this call — tell them to switch Calls on in Settings › Notifications & calls first")
        XCTAssertEqual(guardAt(22, 0, enabled: false), guardAt(12, 0, enabled: false))
        // The default hours: the server's window, end exclusive on the phone.
        XCTAssertNil(guardAt(6, 0, start: "06:00", end: "23:00"))
        XCTAssertNil(guardAt(22, 59, start: "06:00", end: "23:00"))
        XCTAssertEqual(guardAt(23, 0, start: "06:00", end: "23:00"), "error: 23:00 is outside this iPhone's call hours (06:00–23:00; the latest it rings is 22:59), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls",
                       "the server takes 23:00, the phone doesn't — never '23:00 is outside 06:00–23:00' alone")
    }

    /// The end is exclusive, so a refusal of the end minute itself names the
    /// last minute that rings; any other refused minute gets the plain hours.
    func testHoursLabelNamesTheLastMinuteOnlyWhenTheEndItselfIsRefused() {
        XCTAssertEqual(CallSettings.hoursLabel(start: "06:00", end: "23:00", refusing: 23 * 60),
                       "06:00–23:00; the latest it rings is 22:59")
        XCTAssertEqual(CallSettings.hoursLabel(start: "06:00", end: "23:00", refusing: 23 * 60 + 30), "06:00–23:00")
        XCTAssertEqual(CallSettings.hoursLabel(start: "06:00", end: "23:00", refusing: 5 * 60 + 59), "06:00–23:00")
        XCTAssertEqual(CallSettings.hoursLabel(start: "22:00", end: "02:00", refusing: 2 * 60),
                       "22:00–02:00; the latest it rings is 01:59", "overnight")
        XCTAssertEqual(CallSettings.hoursLabel(start: "08:00", end: "00:00", refusing: 0),
                       "08:00–00:00; the latest it rings is 23:59", "an end at midnight")
        XCTAssertEqual(CallSettings.hoursLabel(start: "08:00", end: "junk", refusing: 0), "08:00–junk")
        XCTAssertEqual(CallSettings.minuteOfDay(date(2026, 9, 2, 21, 15), calendar: cal), 21 * 60 + 15)
    }

    /// dispatch_proactive_calls (072) books at the first 5-minute tick in
    /// [time, time+10) inside 06:00–23:00 inclusive.
    func testProactiveRingMinuteIsTheDispatchersTick() {
        XCTAssertEqual(CallSettings.proactiveRingMinute(8 * 60 + 30), 8 * 60 + 30)
        XCTAssertEqual(CallSettings.proactiveRingMinute(7 * 60 + 32), 7 * 60 + 35)
        XCTAssertEqual(CallSettings.proactiveRingMinute(5 * 60 + 51), 6 * 60, "booked at the 06:00 tick")
        XCTAssertEqual(CallSettings.proactiveRingMinute(5 * 60 + 55), 6 * 60)
        XCTAssertNil(CallSettings.proactiveRingMinute(5 * 60 + 50), "05:50 and 05:55 ticks are both before 06:00")
        XCTAssertNil(CallSettings.proactiveRingMinute(5 * 60 + 45))
        XCTAssertEqual(CallSettings.proactiveRingMinute(22 * 60 + 56), 23 * 60)
        XCTAssertEqual(CallSettings.proactiveRingMinute(23 * 60), 23 * 60, "inclusive")
        XCTAssertNil(CallSettings.proactiveRingMinute(23 * 60 + 1))
        XCTAssertNil(CallSettings.proactiveRingMinute(23 * 60 + 59))
    }

    func testProactiveTimeWarningCoversTheServerWindowThePhonesHoursAndTheSwitch() {
        func warn(_ t: String, enabled: Bool = true, start: String = "08:00", end: String = "21:00") -> String? {
            CallSettings.proactiveTimeWarning(t, enabled: enabled, start: start, end: end)
        }
        // Never booked at all — even with Calls off, that's the first thing to say.
        XCTAssertEqual(warn("05:45"), "Unstuck only calls between 06:00 and 23:00, so a call at 05:45 never rings.")
        XCTAssertEqual(warn("05:45", enabled: false), warn("05:45"))
        XCTAssertEqual(warn("23:15"), "Unstuck only calls between 06:00 and 23:00, so a call at 23:15 never rings.")
        XCTAssertEqual(warn("23:01"), "Unstuck only calls between 06:00 and 23:00, so a call at 23:01 never rings.")
        // Booked by the server — judged at the minute it really rings.
        XCTAssertNil(warn("23:00", start: "00:00", end: "00:00"))
        XCTAssertNil(warn("22:58", start: "00:00", end: "00:00"))
        XCTAssertNil(warn("06:00", start: "00:00", end: "00:00"))
        XCTAssertEqual(warn("05:55"), "Unstuck rings this call at about 06:00, outside this iPhone's allowed hours (08:00–21:00), so it's declined here — widen the hours above or pick another time.",
                       "booked at 06:00, not 'never'")
        XCTAssertNil(warn("05:55", start: "06:00", end: "23:00"))
        XCTAssertEqual(warn("07:30"), "Unstuck rings this call at about 07:30, outside this iPhone's allowed hours (08:00–21:00), so it's declined here — widen the hours above or pick another time.",
                       "not the end minute: the plain hours")
        XCTAssertNil(warn("07:58"), "rings at the 08:00 tick")
        XCTAssertEqual(warn("20:58"), "Unstuck rings this call at about 21:00, outside this iPhone's allowed hours (08:00–21:00; the latest it rings is 20:59), so it's declined here — widen the hours above or pick another time.",
                       "booked at the 21:00 tick, declined every day")
        XCTAssertTrue(warn("21:30")?.contains("at about 21:30") == true)
        XCTAssertTrue(warn("20:55", end: "20:56")?.contains("at about 20:56, outside this iPhone's allowed hours (08:00–20:56; the latest it rings is 20:55)") == true,
                      "call-dispatch may ring a minute later")
        XCTAssertEqual(warn("23:00", start: "06:00", end: "23:00"), "Unstuck rings this call at about 23:00, outside this iPhone's allowed hours (06:00–23:00; the latest it rings is 22:59), so it's declined here — widen the hours above or pick another time.",
                       "the default end is exclusive")
        XCTAssertNil(warn("08:30"))
        XCTAssertNil(warn("18:00"))
        XCTAssertNil(warn("07:30", start: "07:00"))
        XCTAssertEqual(warn("08:30", enabled: false), "Calls are off on this iPhone, so this call is declined here — switch them on above.")
        XCTAssertNil(warn("junk"))
    }

    func testAfterBlockWarningWhenCallsAreOffOrTheHoursAreNarrower() {
        XCTAssertEqual(CallSettings.afterBlockWarning(enabled: false, start: "06:00", end: "23:00"),
                       "Calls are off on this iPhone, so these check-ins are declined here — switch them on above.")
        XCTAssertNil(CallSettings.afterBlockWarning(enabled: true, start: "06:00", end: "23:00"), "the defaults")
        XCTAssertNil(CallSettings.afterBlockWarning(enabled: true, start: "05:00", end: "23:30"))
        XCTAssertNil(CallSettings.afterBlockWarning(enabled: true, start: "00:00", end: "00:00"))
        XCTAssertEqual(CallSettings.afterBlockWarning(enabled: true, start: "08:00", end: "21:00"),
                       "This iPhone only takes calls 08:00–21:00, so a check-in after a block that ends outside those hours is declined here.")
        XCTAssertNotNil(CallSettings.afterBlockWarning(enabled: true, start: "22:00", end: "07:00"), "overnight misses the day")
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

    /// request_call / update_call read THIS phone's switch + hours
    /// (CallToolLogic.deviceGuard): a throwaway store keeps them at the
    /// defaults (on, 06:00–23:00) whatever the simulator's app has saved.
    private var savedDefaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        api = FakeAssistantState(); api.today = "2026-09-02"; api.now = "15:00"
        scratch = TurnScratch()
        store = FakeCallStore()
        suiteName = "CallToolsTests.\(UUID().uuidString)"
        savedDefaults = CallSettings.defaults
        CallSettings.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        CallSettings.defaults = savedDefaults
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
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

    // MARK: this phone's switch + hours (audit 2026-09-22, C12)

    /// "call me at 9pm" used to be answered "ok: call booked", then declined
    /// quietly on receipt by the phone's hours.
    func testRequestCallRefusesATimeThisIPhoneWouldDecline() async {
        CallSettings.windowStart = "08:00"; CallSettings.windowEnd = "21:00"
        await expect("request_call", ["label": "meds", "when": "2026-09-02 21:00"],
                     "error: 21:00 is outside this iPhone's call hours (08:00–21:00; the latest it rings is 20:59), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls")
        let early = await run("request_call", ["label": "meds", "when": "2026-09-03 07:30"])
        XCTAssertTrue(early.hasPrefix("error: 07:30 is outside this iPhone's call hours"), early)
        // Task-anchored: block start minus the lead is what's judged.
        api.tasks = [task("t1", "Evening review")]
        api.blocks = [CalBlock(id: "b1", taskId: "t1", taskName: "Evening review", startTime: "21:30", durationMinutes: 30, date: "2026-09-02")]
        let anchored = await run("request_call", ["taskId": "t1", "leadMin": 15])
        XCTAssertTrue(anchored.hasPrefix("error: 21:15 is outside this iPhone's call hours"), anchored)
        // The server window still answers first.
        await expect("request_call", ["label": "meds", "when": "2026-09-03 05:00"],
                     "error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window")
        XCTAssertTrue(store.booked.isEmpty, "nothing is booked on a refusal")
        await expect("request_call", ["label": "meds", "when": "2026-09-02 20:59"],
                     "ok: call booked 2026-09-02 20:59 \"meds\" (0 notes) id=new-1")
    }

    func testRequestCallRefusedWhileCallsAreOffOnThisIPhone() async {
        CallSettings.enabled = false
        await expect("request_call", ["label": "dentist", "when": "2026-09-02 18:00"],
                     "error: calls are off on this iPhone, so it would decline this call — tell them to switch Calls on in Settings › Notifications & calls first")
        XCTAssertTrue(store.booked.isEmpty)
        CallSettings.enabled = true
        await expect("request_call", ["label": "dentist", "when": "2026-09-02 18:00"],
                     "ok: call booked 2026-09-02 18:00 \"dentist\" (0 notes) id=new-1")
    }

    func testUpdateCallRefusesANewTimeOutsideThePhonesHoursButStillEditsNotes() async {
        CallSettings.windowStart = "08:00"; CallSettings.windowEnd = "21:00"
        store.rows = [CallRequest(id: "r1", taskId: "t1", blockId: "b1", callAt: CallsClient.iso(date(2026, 9, 2, 18, 0)),
                                  leadMin: 15, label: "x", notes: ["A"])]
        let late = await run("update_call", ["callId": "r1", "when": "2026-09-03 21:30"])
        XCTAssertTrue(late.hasPrefix("error: 21:30 is outside this iPhone's call hours (08:00–21:00)"), late)
        // Re-anchoring with a lead onto a block that starts too late.
        api.blocks = [CalBlock(id: "b2", taskId: "t1", taskName: "x", startTime: "21:20", durationMinutes: 30, date: "2026-09-02")]
        let lead = await run("update_call", ["callId": "r1", "leadMin": 5])
        XCTAssertTrue(lead.hasPrefix("error: 21:15 is outside this iPhone's call hours"), lead)
        XCTAssertTrue(store.patches.isEmpty, "nothing written on a refusal")
        // Notes only: never refused — not even with Calls off here.
        CallSettings.enabled = false
        let notes = await run("update_call", ["callId": "r1", "notes": ["A", "B"]])
        XCTAssertEqual(notes, "ok: updated call \"x\" — 2026-09-02 18:00, 2 notes id=r1")
        XCTAssertEqual(store.patches.count, 1)
        XCTAssertNil(store.patches[0].callAt)
    }

    // MARK: the microphone note (audit 2026-09-22, C13)

    func testBookedCallCarriesAMicrophoneNoteOnlyWhenRefused() {
        let booked = "ok: call booked 2026-09-03 16:50 \"Speak to James\" (1 note) id=new-1"
        XCTAssertEqual(CallToolLogic.withMicrophoneNote(booked, micRefused: false), booked)
        let annotated = CallToolLogic.withMicrophoneNote(booked, micRefused: true)
        XCTAssertTrue(annotated.hasPrefix(booked))
        XCTAssertTrue(annotated.hasSuffix(CallToolLogic.micRefusedNote))
        XCTAssertTrue(annotated.hasPrefix("ok:"))
        // The receipt (and its Undo id) reads the annotated line the same.
        let plain = deriveReceipt(name: "request_call", args: ReceiptArgs(), result: booked, tasks: [])
        XCTAssertNotNil(plain)
        XCTAssertEqual(deriveReceipt(name: "request_call", args: ReceiptArgs(), result: annotated, tasks: []), plain)
        XCTAssertEqual(plain?.undo, .cancelCall(id: "new-1"))
        // update_call too.
        let updated = "ok: updated call \"Speak to James\" — 2026-09-04 09:00, 2 notes id=r1"
        let updatedNoted = CallToolLogic.withMicrophoneNote(updated, micRefused: true)
        XCTAssertEqual(updatedNoted, updated + CallToolLogic.micRefusedNote)
        let updatedReceipt = deriveReceipt(name: "update_call", args: ReceiptArgs(), result: updated, tasks: [])
        XCTAssertNotNil(updatedReceipt)
        XCTAssertEqual(deriveReceipt(name: "update_call", args: ReceiptArgs(), result: updatedNoted, tasks: []), updatedReceipt)
        // Nothing booked → nothing added.
        for r in ["error: calls are off on this iPhone, so it would decline this call — tell them to switch Calls on in Settings › Notifications & calls first",
                  "ok: no calls booked", "ok: cancelled the call about \"x\" (2026-09-02 18:00)"] {
            XCTAssertEqual(CallToolLogic.withMicrophoneNote(r, micRefused: true), r)
            XCTAssertFalse(CallToolLogic.booksACall(r))
        }
        XCTAssertTrue(CallToolLogic.booksACall(booked))
        XCTAssertTrue(CallToolLogic.booksACall(updated))
        XCTAssertFalse(CallToolLogic.micRefusedNote.contains("\""), "a quote would stretch the receipt's label match")
        XCTAssertFalse(CallToolLogic.micRefusedNote.contains("—"))
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

/// Zubair's after-block calls, 2026-09-24 10:31 + 11:43: "It went well." and a
/// misheard "I always do that." were each ticked off at once — the rule said
/// "settle it in one move". A vague answer now gets one question first.
final class CallCompletionRuleTests: XCTestCase {
    func testAfterBlockTicksOffOnlyAClearDoneAndAsksOnAVagueAnswer() {
        let r = CallScript.conversationRule(.afterBlock)
        XCTAssertTrue(r.contains("ONLY when they clearly say they finished it"), r)
        XCTAssertTrue(r.contains("Want me to mark it done?"), r)
        XCTAssertTrue(r.contains("Never change anything they didn't ask for"), r)
        XCTAssertFalse(r.contains("settle it in one move"), r)
    }

    func testEveningTicksOffOnlyWhatTheyClearlySayTheyFinished() {
        XCTAssertTrue(CallScript.conversationRule(.evening).contains("complete_task only for something they clearly say they finished"))
    }
}
