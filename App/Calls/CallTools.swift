// The four call tools the assistant can run on this device —
// request_call / cancel_call / update_call / get_calls — plus the call-level
// snooze_call, over CallsClient. Result strings are the WEB contract
// byte-for-byte (lib/assistant/tools.ts request_call/cancel_call/update_call/
// get_calls + docs/assistant-tool-contract.md) — the server prompt reads them:
//   ok: call booked <YYYY-MM-DD> <HH:MM> "<label>" (<n> note[s]) id=<id>
//   ok: cancelled the call about "<label>" (<date> <HH:MM>)
//   ok: updated call "<label>" — <date> <HH:MM>, <n> note[s] id=<id>
//   ok: <n> upcoming call[s]:\n- <date> <HH:MM> "<label>" (<n> notes)[ for "<task>"][ · snoozed| · ringing now] [id=<id>]
//   error: calls can only be booked between 06:00 and 23:00 — suggest a time inside that window
//   error: a call is already booked for "<label>" at <date> <HH:MM> id=<id> — update_call or cancel_call it
//   error: <date> is in the PAST (today is <today>). If the user meant the coming <weekday>, use <date> — see context.upcoming. …
//   error: <HH:MM> today is already past (it's <now> now). Ask for a later time or another day — free today: <windows>.
// The past-date / past-time refusals are the SHARED UnstuckCore strings
// (rejectPastDate / rejectPastTime — the same repair hints every other tool
// gives); the only iOS-local strings are the network failure, the
// "changed underneath me" compare-and-set miss, and this phone's own switch
// and hours (CallToolLogic.deviceGuard — it would decline the call on receipt):
//   error: calls are off on this iPhone, so it would decline this call — tell them to switch Calls on in Settings › Notifications & calls first
//   error: <HH:MM> is outside this iPhone's call hours (<start>–<end>), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls
//     (refusing the end minute itself, the hours read "<start>–<end>; the latest it rings is <end − 1 min>")
// On iOS a request_call / update_call `ok:` line may also end with
// CallToolLogic.micRefusedNote (dispatch only — `run` never adds it).
//
// ENTRY POINTS. The executor (runAssistantTool) calls
//   runCallTool(name:args:api:scratch:)
// so a task created THIS turn (create_task → request_call) resolves through
// the executor's TurnScratch + AssistantAppState exactly like every other
// tool (findTask / nextLiveBlock). The older
//   runCallTool(name:argsJSON:)  /  runCallTool(name:args:)
// forms still work — they build the live AppModelAssistantState with a fresh
// (empty) scratch. The network + userId come from the attached AppModel's
// coordinator either way. nil ⇒ not a call tool (the normal dispatcher runs).
//
// Pure pieces (when-parsing, guards, formatting) live in CallToolLogic and
// are unit-tested; the store is behind `CallStore` — in production
// `MirrorFirstCallStore` (the GRDB mirror of call_requests for every READ,
// so get_calls works offline and sees status changes live; CallsClient for
// every WRITE, whose returned row is upserted into the mirror at once), a
// fake in CallScriptTests.

import Foundation
import UnstuckCore
import UnstuckSync

/// Dispatch a call tool through the executor's state + scratch (the call
/// site in runAssistantTool). nil ⇒ not a call tool.
@MainActor
func runCallTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String? {
    guard CallTools.names.contains(name) else { return nil }
    let parsed = (try? JSONSerialization.jsonObject(with: Data(args.json.utf8))) as? [String: Any]
    return await CallTools.dispatch(name: name, args: parsed ?? [:], api: api, scratch: scratch)
}

/// Legacy entry: dictionary args, no executor scratch (the live AppModel
/// state with an empty scratch is used). nil ⇒ not a call tool.
@MainActor
func runCallTool(name: String, args: [String: Any]) async -> String? {
    guard CallTools.names.contains(name) else { return nil }
    guard let model = CallCoordinator.shared.attachedModel else {
        return name == "snooze_call"
            ? CallCoordinator.shared.snoozeActiveCall(minutes: CallToolLogic.int(args["minutes"]) ?? 10)
            : "error: calls aren't available right now — sign in on the phone first"
    }
    let api = AppModelAssistantState(model: model, assistant: model.assistant)
    return await CallTools.dispatch(name: name, args: args, api: api, scratch: TurnScratch())
}

/// Legacy entry from the raw JSON-string arguments (VoiceRealtimeClient's
/// `runTool(name, argsJSON)` / the harness's `call.function.arguments`).
/// Unparseable JSON → `[:]`. nil ⇒ not a call tool.
@MainActor
func runCallTool(name: String, argsJSON: String) async -> String? {
    guard CallTools.names.contains(name) else { return nil }
    let parsed = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]
    return await runCallTool(name: name, args: parsed ?? [:])
}

/// The call_requests reads/writes the tools need — CallsClient in production,
/// a fake in tests. Writes that can lose a race return nil for "zero rows".
protocol CallStore: Sendable {
    func liveCalls() async throws -> [CallRequest]
    func call(id: String) async throws -> CallRequest?
    func book(userId: String, taskId: String?, blockId: String?, callAt: Date, leadMin: Int?,
              label: String, notes: [String]) async throws -> CallRequest
    func patch(id: String, callAt: Date?, blockId: String??, leadMin: Int??,
               label: String?, notes: [String]?) async throws -> CallRequest?
    func cancelCall(id: String) async throws -> CallRequest?
}

extension CallsClient: CallStore {
    func liveCalls() async throws -> [CallRequest] { try await list(upcoming: true) }
    func call(id: String) async throws -> CallRequest? { try await get(id: id) }
    func book(userId: String, taskId: String?, blockId: String?, callAt: Date, leadMin: Int?,
              label: String, notes: [String]) async throws -> CallRequest {
        try await create(userId: userId, taskId: taskId, blockId: blockId, callAt: callAt,
                         leadMin: leadMin, label: label, notes: notes)
    }
    func patch(id: String, callAt: Date?, blockId: String??, leadMin: Int??,
               label: String?, notes: [String]?) async throws -> CallRequest? {
        try await update(id: id, callAt: callAt, blockId: blockId, leadMin: leadMin, label: label, notes: notes)
    }
    func cancelCall(id: String) async throws -> CallRequest? { try await cancel(id: id) }
}

/// The production store: READS come from the local `call_requests` mirror
/// (CallRequestsMirror — hydrated, mirrored via realtime, caught up by
/// cursor), falling back to the live read ONLY when the mirror is empty (a
/// fresh sign-in before the hydrate landed). Offline with an empty mirror ⇒
/// "no calls" rather than an error. WRITES go to the server (the status
/// guard lives there) and the returned row lands in the mirror at once, so
/// the next get_calls / the task editor sees it before the realtime echo.
struct MirrorFirstCallStore: CallStore {
    let client: CallsClient
    let mirror: CallRequestsMirror

    func liveCalls() async throws -> [CallRequest] {
        let local = try mirror.live()
        let mirrorEmpty = try mirror.isEmpty()
        if !local.isEmpty || !mirrorEmpty { return local }
        guard let remote = try? await client.list(upcoming: true) else { return [] }
        for r in remote { try? mirror.upsert(r) }
        return remote
    }

    func call(id: String) async throws -> CallRequest? {
        if let local = try mirror.get(id: id) { return local }
        guard try mirror.isEmpty() else { return nil }
        let remote = try await client.get(id: id)
        if let remote { try? mirror.upsert(remote) }
        return remote
    }

    func book(userId: String, taskId: String?, blockId: String?, callAt: Date, leadMin: Int?,
              label: String, notes: [String]) async throws -> CallRequest {
        let row = try await client.create(userId: userId, taskId: taskId, blockId: blockId, callAt: callAt,
                                          leadMin: leadMin, label: label, notes: notes)
        try? mirror.upsert(row)
        return row
    }

    func patch(id: String, callAt: Date?, blockId: String??, leadMin: Int??,
               label: String?, notes: [String]?) async throws -> CallRequest? {
        let row = try await client.update(id: id, callAt: callAt, blockId: blockId, leadMin: leadMin,
                                          label: label, notes: notes)
        if let row { try? mirror.upsert(row) }
        return row
    }

    func cancelCall(id: String) async throws -> CallRequest? {
        let row = try await client.cancel(id: id)
        if let row { try? mirror.upsert(row) }
        return row
    }
}

extension SyncCoordinator {
    /// The app's call store: the mirror for reads, the client for writes.
    nonisolated var callStore: MirrorFirstCallStore { MirrorFirstCallStore(client: calls, mirror: callsMirror) }
}

@MainActor
enum CallTools {
    static let names: Set<String> = ["request_call", "cancel_call", "update_call", "get_calls", "snooze_call"]

    /// Compare-and-set miss: the row was cancelled / rang / finished between
    /// the read and the write. Never echo the stale row as `ok:`.
    static let changedUnderneath = "error: that call changed underneath me — get_calls and try again"
    /// A time change on a call that is ringing / in progress right now: its
    /// status is about to be settled by the phone's own outcome report, which
    /// would silently overwrite a re-arm to `scheduled`. Notes and label still
    /// land (mid-call "change the notes for later"); a new time needs a new
    /// call — or a snooze.
    static let inProgress = "error: that call is in progress right now — I can change its notes or label, but not its time; snooze_call or book another with request_call"

    /// The production dispatch: snooze → the CallKit coordinator; the rest →
    /// `run` over the attached coordinator's CallsClient + user id.
    static func dispatch(name: String, args: [String: Any], api: AssistantAppState, scratch: TurnScratch) async -> String {
        if name == "snooze_call" {
            return CallCoordinator.shared.snoozeActiveCall(minutes: CallToolLogic.int(args["minutes"]) ?? 10)
        }
        guard let model = CallCoordinator.shared.attachedModel,
              let coord = model.coordinator,
              let userId = coord.auth.currentUserId else {
            return "error: calls aren't available right now — sign in on the phone first"
        }
        let result = await run(name: name, args: args, api: api, scratch: scratch, store: coord.callStore, userId: userId)
        // A call booked or changed by typing never asked for the microphone,
        // and a lock-screen answer can't show the prompt — so the first call
        // couldn't hear them (audit 2026-09-22, C13). Ask now, while the
        // assistant is in front of them; a refusal goes into the ok: line so
        // the model tells them. Not with Calls off here: this phone declines
        // the call, so asking would be noise and "will ring" untrue.
        guard CallToolLogic.booksACall(result), CallSettings.enabled else { return result }
        let allowed = await CallSettingsView.microphoneAllowedAfterBooking()
        return CallToolLogic.withMicrophoneNote(result, micRefused: !allowed)
    }

    static func run(name: String, args: [String: Any], api: AssistantAppState, scratch: TurnScratch,
                    store: any CallStore, userId: String, now: Date = Date(),
                    calendar: Calendar = .current) async -> String {
        do {
            switch name {
            case "request_call":
                return try await requestCall(args, api: api, scratch: scratch, store: store, userId: userId, now: now, calendar: calendar)
            case "cancel_call": return try await cancelCall(args, store: store, calendar: calendar)
            case "update_call": return try await updateCall(args, api: api, store: store, now: now, calendar: calendar)
            case "get_calls": return try await getCalls(api: api, scratch: scratch, store: store, calendar: calendar)
            default: return "error: unknown tool \(name)"
            }
        } catch {
            return "error: couldn't reach the server — try again"
        }
    }

    // MARK: request_call(when | taskId+leadMin, label, notes[])

    private static func requestCall(_ args: [String: Any], api: AssistantAppState, scratch: TurnScratch,
                                    store: any CallStore, userId: String, now: Date, calendar: Calendar) async throws -> String {
        let taskId = CallToolLogic.str(args["taskId"])
        let whenRaw = CallToolLogic.str(args["when"]) ?? CallToolLogic.joinDateTime(args)
        let notes = CallToolLogic.notes(args["notes"])
        var label = CallToolLogic.str(args["label"]).map { String($0.prefix(120)) }

        var task: TaskItem?
        if let taskId {
            // The executor's resolver: a task created THIS turn lives in the
            // scratch before the store has it.
            guard let t = findTask(taskId, api: api, scratch: scratch) else { return "error: task not found" }
            task = t
            if label == nil { label = String(t.name.prefix(120)) }
        }
        guard let label, !label.isEmpty else {
            return "error: label required — say what the call is about (e.g. \"speak to James\")"
        }

        var callAt: Date
        var blockId: String?
        var leadMin: Int?
        if let whenRaw {
            guard let d = CallToolLogic.parseWhen(whenRaw, now: now, calendar: calendar) else {
                return "error: when must be 'YYYY-MM-DD HH:MM' in the user's local time (got \"\(whenRaw)\")"
            }
            callAt = d
        } else if let task {
            let lead = min(1440, max(0, CallToolLogic.int(args["leadMin"]) ?? CallSettings.defaultLeadMin))
            // The same anchor schedule_task / block_time just moved — read
            // through the executor's state, not a stale repo snapshot.
            guard let block = nextLiveBlock(api, taskId: task.id),
                  let start = CallToolLogic.blockStart(block, calendar: calendar) else {
                return "error: \"\(task.name)\" has no upcoming slot — schedule_task it first, or give a time with when"
            }
            callAt = start.addingTimeInterval(TimeInterval(-lead * 60))
            if callAt.timeIntervalSince(now) < -30 {
                return "error: \(lead) min before \"\(task.name)\" (\(CallToolLogic.fmt(callAt, calendar: calendar))) is already past — give a time with when instead"
            }
            blockId = block.id
            leadMin = lead
        } else {
            return "error: needs a time — ask ONE short question suggesting one (e.g. \"3pm today, or a time you prefer?\"), then book when they answer"
        }

        if let e = CallToolLogic.timeGuard(callAt, now: now, blocks: api.getBlocks(), calendar: calendar) { return e }
        if let e = CallToolLogic.deviceGuard(callAt, calendar: calendar) { return e }

        // One live call per anchor: the task when given, else the label (web rule).
        let live = try await store.liveCalls()
        if let dup = CallToolLogic.duplicate(in: live, taskId: task?.id, label: label) {
            return "error: a call is already booked for \"\(dup.label)\" at \(CallToolLogic.fmt(dup.callAtDate ?? callAt, calendar: calendar)) id=\(dup.id) — update_call or cancel_call it"
        }

        let row = try await store.book(userId: userId, taskId: task?.id, blockId: blockId,
                                       callAt: callAt, leadMin: leadMin, label: label, notes: notes)
        return "ok: call booked \(CallToolLogic.fmt(callAt, calendar: calendar)) \"\(label)\" (\(CallToolLogic.notesCount(notes))) id=\(row.id)"
    }

    // MARK: cancel_call(callId)

    private static func cancelCall(_ args: [String: Any], store: any CallStore, calendar: Calendar) async throws -> String {
        guard let id = CallToolLogic.str(args["callId"]) ?? CallToolLogic.str(args["id"]) else {
            return "error: callId required — use get_calls to find it"
        }
        guard let row = try await store.call(id: id) else { return "error: call not found — use get_calls" }
        guard row.isLive else { return "error: that call is already \(row.status)" }
        guard let cancelled = try await store.cancelCall(id: id) else { return changedUnderneath }
        return "ok: cancelled the call about \"\(cancelled.label)\" (\(CallToolLogic.fmt(cancelled.callAtDate, calendar: calendar)))"
    }

    // MARK: update_call(callId, notes | when | leadMin | label)

    /// Notes / label edits land on any EDITABLE row — live, or ANSWERED and in
    /// progress: the in-call "add 'bring the contract' to the notes and call
    /// me back in 20" must edit the row while the conversation is up (the
    /// phone reports `answered` the moment the call is picked up, so the row
    /// is never `calling` by the time the model runs the tool). A TIME change
    /// on a ringing / answered row is refused (`inProgress`): re-arming it to
    /// `scheduled` would be overwritten by the outcome report a moment later.
    private static func updateCall(_ args: [String: Any], api: AssistantAppState, store: any CallStore,
                                   now: Date, calendar: Calendar) async throws -> String {
        guard let id = CallToolLogic.str(args["callId"]) ?? CallToolLogic.str(args["id"]) else {
            return "error: callId required — use get_calls to find it"
        }
        guard let row = try await store.call(id: id) else { return "error: call not found — use get_calls" }
        guard row.isEditable else { return "error: that call is already \(row.status) — book a new one with request_call" }
        // A JSON `null` (NSNull) or an absent key leaves the notes untouched;
        // only a real array/string replaces them.
        let notes: [String]? = CallToolLogic.isPresent(args["notes"]) ? CallToolLogic.notes(args["notes"]) : nil
        let label = CallToolLogic.str(args["label"]).map { String($0.prefix(120)) }
        let whenRaw = CallToolLogic.str(args["when"]) ?? CallToolLogic.joinDateTime(args)
        let lead = CallToolLogic.int(args["leadMin"])
        guard notes != nil || label != nil || whenRaw != nil || lead != nil else {
            return "error: nothing to change — give notes and/or when"
        }
        if row.isInProgress, whenRaw != nil || lead != nil { return inProgress }

        var callAt: Date?
        var leadPatch: Int?? = nil
        var blockPatch: String?? = nil
        if let whenRaw {
            guard let d = CallToolLogic.parseWhen(whenRaw, now: now, calendar: calendar) else {
                return "error: when must be 'YYYY-MM-DD HH:MM' in the user's local time (got \"\(whenRaw)\")"
            }
            callAt = d
            leadPatch = .some(nil)    // a standalone time drops the block anchor
            blockPatch = .some(nil)
        } else if let lead {
            guard let taskId = row.taskId else { return "error: this call isn't anchored to a task — give a time instead" }
            guard let block = nextLiveBlock(api, taskId: taskId),
                  let start = CallToolLogic.blockStart(block, calendar: calendar) else {
                return "error: the task has no scheduled time any more — schedule_task it first"
            }
            callAt = start.addingTimeInterval(TimeInterval(-lead * 60))
            leadPatch = .some(lead)
            blockPatch = .some(block.id)
        }
        if let callAt, let e = CallToolLogic.timeGuard(callAt, now: now, blocks: api.getBlocks(), calendar: calendar) { return e }
        // Only a NEW time meets this phone's switch and hours; a notes- or
        // label-only edit is never refused here.
        if let callAt, let e = CallToolLogic.deviceGuard(callAt, calendar: calendar) { return e }

        guard let r = try await store.patch(id: id, callAt: callAt, blockId: blockPatch, leadMin: leadPatch,
                                            label: label, notes: notes) else { return changedUnderneath }
        return "ok: updated call \"\(r.label)\" — \(CallToolLogic.fmt(r.callAtDate, calendar: calendar)), \(CallToolLogic.notesCount(r.notes)) id=\(r.id)"
    }

    // MARK: get_calls()

    private static func getCalls(api: AssistantAppState, scratch: TurnScratch, store: any CallStore,
                                 calendar: Calendar) async throws -> String {
        let rows = try await store.liveCalls()
            .sorted { ($0.callAtDate ?? .distantFuture) < ($1.callAtDate ?? .distantFuture) }
        guard !rows.isEmpty else { return "ok: no calls booked" }
        return CallToolLogic.formatCalls(rows, taskName: { findTask($0, api: api, scratch: scratch)?.name },
                                         calendar: calendar)
    }
}

/// Pure helpers (tested in CallScriptTests).
enum CallToolLogic {
    /// Web `MAX_CALL_NOTES` / per-note cap.
    static let maxNotes = 20
    static let maxNoteLength = 300

    static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    /// A key that is there AND not JSON `null` (JSONSerialization → NSNull).
    static func isPresent(_ v: Any?) -> Bool {
        guard let v else { return false }
        return !(v is NSNull)
    }
    /// notes: an array of strings, or one string split on NEWLINES only (a
    /// note may contain ";"). Trimmed, blanks dropped, 300 chars × 20 (web).
    static func notes(_ v: Any?) -> [String] {
        let raw: [String]
        if let a = v as? [Any] { raw = a.compactMap { $0 as? String } }
        else if let s = v as? String { raw = s.components(separatedBy: CharacterSet.newlines) }
        else { raw = [] }
        return Array(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(maxNoteLength)) }.prefix(maxNotes))
    }
    static func notesCount(_ n: [String]) -> String { "\(n.count) note\(n.count == 1 ? "" : "s")" }

    /// schedule_task-style split args → "YYYY-MM-DD HH:MM".
    static func joinDateTime(_ args: [String: Any]) -> String? {
        let time = str(args["startTime"]) ?? str(args["time"])
        let date = str(args["date"])
        switch (date, time) {
        case let (d?, t?): return "\(d) \(t)"
        case let (nil, t?): return t
        default: return nil
        }
    }

    /// ISO-8601, "YYYY-MM-DD HH:MM", "YYYY-MM-DDTHH:MM", or "HH:MM" (today).
    static func parseWhen(_ raw: String, now: Date, calendar: Calendar = .current) -> Date? {
        CallSession.parseStart(raw, relativeTo: now, calendar: calendar)
    }

    /// get_calls (web format): `ok: <n> upcoming call[s]:` then one line per
    /// call — soonest first, at most 20 lines — showing the EFFECTIVE time
    /// (snooze_until when snoozed), the task it rings for, and its state.
    static func formatCalls(_ rows: [CallRequest], taskName: (String) -> String?, calendar: Calendar = .current) -> String {
        guard !rows.isEmpty else { return "ok: no calls booked" }
        let lines = rows.prefix(20).map { r -> String in
            var s = "- \(fmt(r.effectiveAtDate, calendar: calendar)) \"\(r.label)\" (\(notesCount(r.notes)))"
            if let tid = r.taskId, let name = taskName(tid) { s += " for \"\(name)\"" }
            if r.status == "snoozed" { s += " · snoozed" } else if r.status == "calling" { s += " · ringing now" }
            return s + " [id=\(r.id)]"
        }
        return "ok: \(rows.count) upcoming call\(rows.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
    }

    /// Past-date / past-time (the SHARED UnstuckCore refusals, with the day's
    /// free windows / the "use <date> — see context.upcoming" repair hint)
    /// then the server window → the error string, or nil when fine. `blocks`
    /// = the executor's live blocks (for the free windows).
    static func timeGuard(_ callAt: Date, now: Date, blocks: [CalBlock] = [], calendar: Calendar = .current) -> String? {
        let today = ymd(now, calendar: calendar)
        let date = ymd(callAt, calendar: calendar)
        if let e = rejectPastDate(today: today, date: date) { return e }
        if let e = rejectPastTime(blocks: blocks, today: today, date: date,
                                  startTime: CallSettings.hhmm(callAt, calendar: calendar),
                                  nowHM: CallSettings.hhmm(now, calendar: calendar)) { return e }
        if !CallSettings.isWithinServerWindow(callAt, calendar: calendar) {
            return "error: calls can only be booked between \(CallSettings.serverWindowStart) and \(CallSettings.serverWindowEnd) — suggest a time inside that window"
        }
        return nil
    }

    /// THIS phone's Calls switch and allowed hours → the error string, or nil
    /// when it would ring. Runs after timeGuard wherever this phone picks a
    /// ring time (request_call, update_call with a new time, the task
    /// editor). The switch and hours used to be applied only on receipt
    /// (CallCoordinator.reportIncoming), which turned an "ok: call booked"
    /// into a quiet decline at ring time (audit 2026-09-22, C12). Kept apart
    /// from timeGuard so the web-contract window string stays as it is. The
    /// wording makes the model ASK for another time, never pick one.
    static func deviceGuard(_ callAt: Date, enabled: Bool = CallSettings.enabled,
                            start: String = CallSettings.windowStart, end: String = CallSettings.windowEnd,
                            calendar: Calendar = .current) -> String? {
        if !enabled {
            return "error: calls are off on this iPhone, so it would decline this call — tell them to switch Calls on in Settings › Notifications & calls first"
        }
        if !CallSettings.isWithinWindow(callAt, start: start, end: end, calendar: calendar) {
            let hours = CallSettings.hoursLabel(start: start, end: end, refusing: CallSettings.minuteOfDay(callAt, calendar: calendar))
            return "error: \(CallSettings.hhmm(callAt, calendar: calendar)) is outside this iPhone's call hours (\(hours)), so it would decline this call — ask them for a time inside those hours, or tell them they can widen them in Settings › Notifications & calls"
        }
        return nil
    }

    /// Appended to a booked / updated call's `ok:` line when the microphone
    /// is refused (audit 2026-09-22, C13). No quotes and no em-dash, so the
    /// receipt patterns (AssistantReceipts CALL_BOOKED_RE / CALL_UPDATED_RE,
    /// anchored at the start) still read the line and its id.
    static let micRefusedNote = " NOTE: microphone access is off for Unstuck on this iPhone, so the call will ring but can't hear them. Tell them to turn it on in iOS Settings › Unstuck › Microphone."

    /// The results that leave a call booked to ring.
    static func booksACall(_ r: String) -> Bool {
        r.hasPrefix("ok: call booked") || r.hasPrefix("ok: updated call")
    }

    static func withMicrophoneNote(_ r: String, micRefused: Bool) -> String {
        micRefused && booksACall(r) ? r + micRefusedNote : r
    }

    /// One live call per anchor — the web rule exactly: with a task, any live
    /// call for that task; without, a case-insensitive label match. Nothing else.
    static func duplicate(in live: [CallRequest], taskId: String?, label: String?) -> CallRequest? {
        let rows = live.filter(\.isLive)
        if let taskId { return rows.first { $0.taskId == taskId } }
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !label.isEmpty else { return nil }
        return rows.first { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == label }
    }

    /// The task's next live task-block (today or later, not done/skipped) —
    /// the task-editor's anchor (CallMeSection has the task's own blocks).
    static func nextLiveBlock(_ blocks: [CalBlock], now: Date, calendar: Calendar = .current) -> CalBlock? {
        let today = ymd(now, calendar: calendar)
        return blocks
            .filter { isTaskBlock($0) && !$0.done && !$0.skipped && $0.date >= today }
            .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
            .first
    }

    static func blockStart(_ b: CalBlock, calendar: Calendar = .current) -> Date? {
        let ymd = b.date.split(separator: "-").compactMap { Int($0) }
        let hm = b.startTime.split(separator: ":").compactMap { Int($0) }
        guard ymd.count == 3, hm.count >= 2 else { return nil }
        var c = DateComponents()
        c.year = ymd[0]; c.month = ymd[1]; c.day = ymd[2]; c.hour = hm[0]; c.minute = hm[1]
        return calendar.date(from: c)
    }

    /// "YYYY-MM-DD" local.
    static func ymd(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "YYYY-MM-DD HH:MM" local.
    static func fmt(_ d: Date?, calendar: Calendar = .current) -> String {
        guard let d else { return "?" }
        return "\(ymd(d, calendar: calendar)) \(CallSettings.hhmm(d, calendar: calendar))"
    }
}
