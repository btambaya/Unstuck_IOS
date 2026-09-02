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
// The only iOS-local strings are the past-time guards (the web's carry the
// day's free windows, which the pure guard doesn't have) and the network
// failure. `runCallTool` is wired into the text + voice dispatchers by
// runAssistantTool; it returns nil for any other tool name.
//
// Pure pieces (when-parsing, guards, formatting) live in CallToolLogic and
// are unit-tested; the network + store reads are in `CallTools.run`.

import Foundation
import UnstuckCore
import UnstuckSync

/// Dispatch a call tool. nil ⇒ not a call tool (let the normal dispatcher run).
@MainActor
func runCallTool(name: String, args: [String: Any]) async -> String? {
    guard CallTools.names.contains(name) else { return nil }
    if name == "snooze_call" {
        let m = CallToolLogic.int(args["minutes"]) ?? 10
        return CallCoordinator.shared.snoozeActiveCall(minutes: m)
    }
    guard let model = CallCoordinator.shared.attachedModel,
          let client = model.coordinator?.calls,
          let userId = model.coordinator?.auth.currentUserId else {
        return "error: calls aren't available right now — sign in on the phone first"
    }
    return await CallTools.run(name: name, args: args, model: model, client: client, userId: userId)
}

/// Same, from the raw JSON-string arguments both dispatchers already hold
/// (VoiceRealtimeClient's `runTool(name, argsJSON)` / the harness's
/// `call.function.arguments`). Unparseable JSON → `[:]`.
@MainActor
func runCallTool(name: String, argsJSON: String) async -> String? {
    guard CallTools.names.contains(name) else { return nil }
    let parsed = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]
    return await runCallTool(name: name, args: parsed ?? [:])
}

@MainActor
enum CallTools {
    static let names: Set<String> = ["request_call", "cancel_call", "update_call", "get_calls", "snooze_call"]

    static func run(name: String, args: [String: Any], model: AppModel, client: CallsClient,
                    userId: String, now: Date = Date()) async -> String {
        do {
            switch name {
            case "request_call": return try await requestCall(args, model: model, client: client, userId: userId, now: now)
            case "cancel_call": return try await cancelCall(args, client: client)
            case "update_call": return try await updateCall(args, model: model, client: client, now: now)
            case "get_calls": return try await getCalls(model: model, client: client)
            default: return "error: unknown tool \(name)"
            }
        } catch {
            return "error: couldn't reach the server — try again"
        }
    }

    // MARK: request_call(when | taskId+leadMin, label, notes[])

    private static func requestCall(_ args: [String: Any], model: AppModel, client: CallsClient,
                                    userId: String, now: Date) async throws -> String {
        let taskId = CallToolLogic.str(args["taskId"])
        let whenRaw = CallToolLogic.str(args["when"]) ?? CallToolLogic.joinDateTime(args)
        let notes = CallToolLogic.notes(args["notes"])
        var label = CallToolLogic.str(args["label"]).map { String($0.prefix(120)) }

        var task: TaskItem?
        if let taskId {
            guard let t = (try? model.taskRepo?.fetch(id: taskId)) ?? nil else { return "error: task not found" }
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
            guard let d = CallToolLogic.parseWhen(whenRaw, now: now) else {
                return "error: when must be 'YYYY-MM-DD HH:MM' in the user's local time (got \"\(whenRaw)\")"
            }
            callAt = d
        } else if let task {
            let lead = min(1440, max(0, CallToolLogic.int(args["leadMin"]) ?? CallSettings.defaultLeadMin))
            let blocks = (try? model.db?.blocks(forTask: task.id)) ?? []
            guard let block = CallToolLogic.nextLiveBlock(blocks, now: now),
                  let start = CallToolLogic.blockStart(block) else {
                return "error: \"\(task.name)\" has no upcoming slot — schedule_task it first, or give a time with when"
            }
            callAt = start.addingTimeInterval(TimeInterval(-lead * 60))
            if callAt.timeIntervalSince(now) < -30 {
                return "error: \(lead) min before \"\(task.name)\" (\(CallToolLogic.fmt(callAt))) is already past — give a time with when instead"
            }
            blockId = block.id
            leadMin = lead
        } else {
            return "error: needs a time — ask ONE short question suggesting one (e.g. \"3pm today, or a time you prefer?\"), then book when they answer"
        }

        if let e = CallToolLogic.timeGuard(callAt, now: now) { return e }

        // One live call per anchor: the task when given, else the label (web),
        // plus the same-minute standalone rule.
        let live = try await client.list(upcoming: true)
        if let dup = CallToolLogic.duplicate(in: live, taskId: task?.id, blockId: blockId, callAt: callAt, label: label) {
            return "error: a call is already booked for \"\(dup.label)\" at \(CallToolLogic.fmt(dup.effectiveAtDate ?? callAt)) id=\(dup.id) — update_call or cancel_call it"
        }

        let row = try await client.create(userId: userId, taskId: task?.id, blockId: blockId,
                                          callAt: callAt, leadMin: leadMin, label: label, notes: notes)
        return "ok: call booked \(CallToolLogic.fmt(callAt)) \"\(label)\" (\(CallToolLogic.notesCount(notes))) id=\(row.id)"
    }

    // MARK: cancel_call(callId)

    private static func cancelCall(_ args: [String: Any], client: CallsClient) async throws -> String {
        guard let id = CallToolLogic.str(args["callId"]) ?? CallToolLogic.str(args["id"]) else {
            return "error: callId required — use get_calls to find it"
        }
        guard let row = try await client.get(id: id) else { return "error: call not found — use get_calls" }
        guard row.isLive else { return "error: that call is already \(row.status)" }
        try await client.cancel(id: id)
        return "ok: cancelled the call about \"\(row.label)\" (\(CallToolLogic.fmt(row.callAtDate)))"
    }

    // MARK: update_call(callId, notes | when | leadMin | label)

    private static func updateCall(_ args: [String: Any], model: AppModel, client: CallsClient, now: Date) async throws -> String {
        guard let id = CallToolLogic.str(args["callId"]) ?? CallToolLogic.str(args["id"]) else {
            return "error: callId required — use get_calls to find it"
        }
        guard let row = try await client.get(id: id) else { return "error: call not found — use get_calls" }
        guard row.isLive else { return "error: that call is already \(row.status) — book a new one with request_call" }
        let notes = args["notes"] != nil ? CallToolLogic.notes(args["notes"]) : nil
        let label = CallToolLogic.str(args["label"]).map { String($0.prefix(120)) }
        let whenRaw = CallToolLogic.str(args["when"]) ?? CallToolLogic.joinDateTime(args)
        let lead = CallToolLogic.int(args["leadMin"])
        guard notes != nil || label != nil || whenRaw != nil || lead != nil else {
            return "error: nothing to change — give notes and/or when"
        }

        var callAt: Date?
        var leadPatch: Int?? = nil
        var blockPatch: String?? = nil
        if let whenRaw {
            guard let d = CallToolLogic.parseWhen(whenRaw, now: now) else {
                return "error: when must be 'YYYY-MM-DD HH:MM' in the user's local time (got \"\(whenRaw)\")"
            }
            callAt = d
            leadPatch = .some(nil)    // a standalone time drops the block anchor
            blockPatch = .some(nil)
        } else if let lead {
            guard let taskId = row.taskId else { return "error: this call isn't anchored to a task — give a time instead" }
            let blocks = (try? model.db?.blocks(forTask: taskId)) ?? []
            guard let block = CallToolLogic.nextLiveBlock(blocks, now: now), let start = CallToolLogic.blockStart(block) else {
                return "error: the task has no scheduled time any more — schedule_task it first"
            }
            callAt = start.addingTimeInterval(TimeInterval(-lead * 60))
            leadPatch = .some(lead)
            blockPatch = .some(block.id)
        }
        if let callAt, let e = CallToolLogic.timeGuard(callAt, now: now) { return e }

        let updated = try await client.update(id: id, callAt: callAt, blockId: blockPatch, leadMin: leadPatch,
                                              label: label, notes: notes)
        let r = updated ?? row
        return "ok: updated call \"\(r.label)\" — \(CallToolLogic.fmt(r.callAtDate)), \(CallToolLogic.notesCount(r.notes)) id=\(r.id)"
    }

    // MARK: get_calls()

    private static func getCalls(model: AppModel, client: CallsClient) async throws -> String {
        let rows = try await client.list(upcoming: true)
            .sorted { ($0.callAtDate ?? .distantFuture) < ($1.callAtDate ?? .distantFuture) }
        guard !rows.isEmpty else { return "ok: no calls booked" }
        let tasks = (try? model.taskRepo?.all()) ?? []
        return CallToolLogic.formatCalls(rows, taskName: { id in tasks.first { $0.id == id }?.name })
    }
}

/// Pure helpers (tested in CallScriptTests).
enum CallToolLogic {
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
    /// notes: an array of strings, or one string split on newlines / " ; ".
    static func notes(_ v: Any?) -> [String] {
        let raw: [String]
        if let a = v as? [Any] { raw = a.compactMap { $0 as? String } }
        else if let s = v as? String { raw = s.components(separatedBy: CharacterSet.newlines).flatMap { $0.components(separatedBy: ";") } }
        else { raw = [] }
        return Array(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(200)) }.prefix(8))
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

    /// Past-time + server-window guards → the error string, or nil when fine.
    static func timeGuard(_ callAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        if callAt.timeIntervalSince(now) < -30 {
            if calendar.isDate(callAt, inSameDayAs: now) {
                return "error: \(CallSettings.hhmm(callAt, calendar: calendar)) today is already past (it's \(CallSettings.hhmm(now, calendar: calendar)) now). Ask for a later time."
            }
            return "error: \(fmt(callAt, calendar: calendar)) is in the PAST (it's \(fmt(now, calendar: calendar)) now). Ask for a later time or another day."
        }
        if !CallSettings.isWithinServerWindow(callAt, calendar: calendar) {
            return "error: calls can only be booked between \(CallSettings.serverWindowStart) and \(CallSettings.serverWindowEnd) — suggest a time inside that window"
        }
        return nil
    }

    /// One live call per anchor: same task (task-anchored), else — standalone —
    /// the same label (case-insensitive, the web rule) or the same minute.
    static func duplicate(in live: [CallRequest], taskId: String?, blockId: String?, callAt: Date,
                          label: String? = nil) -> CallRequest? {
        if let taskId, let hit = live.first(where: { $0.taskId == taskId && ($0.blockId == nil || blockId == nil || $0.blockId == blockId) }) {
            return hit
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !label.isEmpty,
           let hit = live.first(where: { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == label }) {
            return hit
        }
        let minute = floor(callAt.timeIntervalSince1970 / 60)
        return live.first { r in
            guard let d = r.effectiveAtDate else { return false }
            return floor(d.timeIntervalSince1970 / 60) == minute
        }
    }

    /// The task's next live task-block (today or later, not done/skipped).
    static func nextLiveBlock(_ blocks: [CalBlock], now: Date, calendar: Calendar = .current) -> CalBlock? {
        let today = Clock.dateISO(now)
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

    /// "YYYY-MM-DD HH:MM" local.
    static func fmt(_ d: Date?, calendar: Calendar = .current) -> String {
        guard let d else { return "?" }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        let ymd = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(ymd) \(CallSettings.hhmm(d, calendar: calendar))"
    }
}
