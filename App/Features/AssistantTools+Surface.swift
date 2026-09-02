// The full app surface (2026-09-02: "the model should be able to do everything
// a user can do"): reopen/list tasks, calendar edits, focus controls, captures,
// list edits, areas + tags, unshare, settings, insights, navigation. 1:1 with
// the matching cases in lib/assistant/tools.ts — result strings are the
// contract's, byte for byte.

import Foundation
import UnstuckCore

// MARK: - dispatcher for the 2026-09-02 tools

@MainActor
func runSurfaceTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String? {
    let now = AppModel.isoNow

    switch name {
    // ── TASKS ──
    case "uncomplete_task":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        t.done = false
        t.completedAt = nil
        t.updatedAt = now()
        api.upsertTask(t)
        scratch.newTasks[t.id] = t
        return "ok: reopened \"\(t.name)\" id=\(t.id)"

    case "get_tasks":
        let viewMap: [String: TaskListView] = [
            "today": .today, "upcoming": .upcoming, "backlog": .backlog, "later": .later,
            "recurring": .recurring, "completed": .completed, "all": .all, "slipping": .all,
        ]
        let v = (args.str("view") ?? "all").lowercased()
        guard let view = viewMap[v] else {
            return "error: unknown view \"\(v)\" — use today, upcoming, backlog, later, recurring, completed, slipping, or all"
        }
        let area = args.str("area")
        if let area {
            var known: [String] = []
            for a in api.getAreas() + api.getTasks().map({ $0.lifeArea ?? "" }) where !a.isEmpty {
                let l = a.lowercased()
                if !known.contains(l) { known.append(l) }
            }
            if !known.contains(area.lowercased()) {
                return "error: no area named \"\(area)\" — areas: \(known.isEmpty ? "(none yet)" : known.joined(separator: ", "))"
            }
        }
        let tag = args.str("tag")?.lowercased()
        let tasks = api.getTasks()
        let blocks = api.getBlocks()
        var rows = visibleTasks(view: view, tasks: tasks, blocks: blocks, now: Date().timeIntervalSince1970 * 1000,
                                activeArea: area, activeTag: nil, slipMode: v == "slipping")
        if let tag { rows = rows.filter { ($0.tags ?? []).contains { $0.lowercased() == tag } } }
        let lines = rows.prefix(30).map { t -> String in
            // Recurring rows are OCCURRENCES: their id is the block id, the
            // real task id is templateId — the model must get the task id.
            let occ = occurrenceBlockFor(t.id, tasks: tasks, blocks: blocks)
            let taskId = occ?.taskId ?? t.id
            let b = occ ?? nextLiveBlock(api, taskId: taskId)
            var line = "- \(t.name) [id=\(taskId)] \(t.estimateMin)m"
            if let area = t.lifeArea, !area.isEmpty { line += " · \(area)" }
            if let b { line += " · \(b.date) \(b.startTime)" }
            if occ != nil { line += " · repeats" }
            if t.later == true { line += " · Later" }
            if (t.moveCount ?? 0) >= 3 { line += " · slipped \(t.moveCount ?? 0)×" }
            if t.done { line += " · done" }
            return line
        }
        return "ok: \(view.rawValue) (\(rows.count))\(rows.count > 30 ? ", first 30" : ""):\n\(lines.isEmpty ? "(none)" : lines.joined(separator: "\n"))"

    // ── CALENDAR ──
    case "unschedule_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let today = api.todayIso()
        let live = api.getBlocks().filter { $0.taskId == t.id && !$0.done && !$0.skipped && $0.date >= today }
        if live.isEmpty { return "error: \"\(t.name)\" has no upcoming slot to remove" }
        for b in live { api.deleteBlock(b.id) }
        return "ok: unscheduled \"\(t.name)\" (task kept, \(live.count) slot\(live.count == 1 ? "" : "s") removed)"

    case "skip_occurrence":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let date = args.str("date") ?? api.todayIso()
        guard var b = api.getBlocks().first(where: { $0.taskId == t.id && $0.date == date && !$0.done }) else {
            return "error: \"\(t.name)\" has nothing on \(date) to skip"
        }
        b.skipped = true
        api.upsertBlock(b)
        return "ok: skipped \"\(t.name)\" on \(date) (the task and its other days stay)"

    case "complete_occurrence":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let date = args.str("date") ?? api.todayIso()
        guard var b = api.getBlocks().first(where: { $0.taskId == t.id && $0.date == date && !$0.skipped }) else {
            return "error: \"\(t.name)\" has nothing on \(date)"
        }
        b.done = true
        api.upsertBlock(b)
        if t.recurrence == nil {
            t.done = true
            t.updatedAt = now()
            api.upsertTask(t)
            scratch.newTasks[t.id] = t
        }
        return "ok: marked \"\(t.name)\" done for \(date)\(t.recurrence != nil ? " (series continues)" : "")"

    case "block_time":
        let nm = args.str("name")
        let date = args.str("date")
        let startTime = args.str("startTime")
        let dur = args.int("durationMin") ?? 60
        guard let nm, let date, let startTime else { return "error: name, date and startTime are all required for block_time" }
        if let past = rejectPastDate(today: api.todayIso(), date: date)
            ?? rejectPastTime(blocks: api.getBlocks(), today: api.todayIso(), date: date, startTime: startTime, nowHM: api.nowHM()) {
            return past
        }
        let t = TaskItem(id: newUUID(), name: nm, estimateMin: dur, totalFocused: 0, done: false, priority: .medium,
                         tags: [], objectives: [], comments: [], later: false, createdAt: now(), updatedAt: now())
        api.upsertTask(t)
        scratch.newTasks[t.id] = t
        api.upsertBlock(CalBlock(id: newUUID(), taskId: t.id, taskName: nm, startTime: startTime, durationMinutes: dur, date: date, kind: .task))
        return "ok: blocked \"\(nm)\" \(date) \(startTime) for \(dur)m id=\(t.id)"

    case "carry_to_tomorrow":
        let today = api.todayIso()
        let tomorrow = LocalDate.addDays(today, 1)
        let wanted = args.strList("taskIds")
        let todays = api.getBlocks().filter { b in
            b.date == today && !b.done && !b.skipped && isTaskBlock(b)
                && (wanted == nil || wanted!.contains(b.taskId ?? ""))
        }
        if todays.isEmpty { return "error: nothing left on today to carry" }
        var names: [String] = []
        for b in todays {
            let t = api.getTasks().first { $0.id == b.taskId }
            let tomorrowTaken = api.getBlocks().contains { $0.taskId == b.taskId && $0.date == tomorrow && !$0.skipped }
            var next = b
            if tomorrowTaken { next.skipped = true } else { next.date = tomorrow }
            api.upsertBlock(next)
            if let t { api.upsertTask(bumpMoveCount(t, nowISO: now())) }
            names.append(t?.name ?? b.taskName)
        }
        return "ok: carried \(names.count) to \(tomorrow) — \(names.map { "\"\($0)\"" }.joined(separator: ", "))"

    // ── FOCUS ──
    case "start_focus":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        if let live = api.getLiveFocus(), live.sessionStart != nil {
            let cur = api.getTasks().first { $0.id == live.taskId }
            return "error: a focus session is already running on \"\(cur?.name ?? "a task")\" — pause or cancel it first, or ask the user"
        }
        let occ = t.recurrence != nil ? nextLiveBlock(api, taskId: t.id) : nil
        let est = args.int("estimateMin") ?? t.estimateMin
        api.startFocus(taskId: t.id, estimateMin: est, occurrenceBlockId: occ?.id)
        api.navigate(screen: "focus", id: nil)
        return "ok: focus started on \"\(t.name)\" (\(est)m) — the user is now on the focus screen"

    case "pause_focus":
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        if live.paused { return "error: it is already paused" }
        api.pauseFocus()
        return "ok: paused the focus session"

    case "resume_focus":
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        if !live.paused { return "error: it is not paused" }
        api.resumeFocus()
        return "ok: resumed the focus session"

    case "extend_focus":
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        let mins = args.int("minutes") ?? 10
        if mins < 1 || mins > 180 { return "error: minutes must be between 1 and 180" }
        api.extendFocus(mins)
        return "ok: extended the session by \(mins)m"

    case "cancel_focus":
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        api.cancelFocus()
        return "ok: cancelled the focus session (nothing logged). To finish and LOG a session, the user taps Done on the focus screen."

    // ── CAPTURES ──
    case "add_capture":
        guard let body = args.str("body") else { return "error: body required" }
        let tagRaw = (args.str("tag") ?? "idea").lowercased()
        let tag = CaptureTag(rawValue: tagRaw) ?? .idea
        let t = findTask(args.str("taskId"), api: api, scratch: scratch)
        let live = api.getLiveFocus()
        let c = Capture(id: newUUID(), taskId: t?.id, sessionId: (live?.sessionStart != nil) ? live?.id : nil,
                        tag: tag, body: String(body.prefix(500)), at: now())
        api.upsertCapture(c)
        return "ok: captured id=\(c.id) [\(tag.rawValue)] \"\(c.body)\"\(t.map { " on \"\($0.name)\"" } ?? "")"

    case "get_captures":
        let archived = Set(api.getArchivedCaptureIds())
        let tag = args.str("tag")?.lowercased()
        let open = api.getCaptures()
            .filter { !archived.contains($0.id) && (tag == nil || $0.tag.rawValue == tag) }
            .sorted { $0.at > $1.at }
        let lines = open.prefix(25).map { c -> String in
            let t = c.taskId.flatMap { id in api.getTasks().first { $0.id == id } }
            return "- [\(c.tag.rawValue)] \(c.body) (id=\(c.id)\(t.map { ", on \"\($0.name)\"" } ?? ""))"
        }
        return "ok: \(open.count) open capture\(open.count == 1 ? "" : "s"):\n\(lines.isEmpty ? "(inbox empty)" : lines.joined(separator: "\n"))"

    case "promote_capture":
        let id = args.str("captureId")
        guard var c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        // lib/capture-actions promoteCapture: task from the body, link the capture.
        let newId = newUUID()
        let name = c.body.count > 160 ? String(c.body.prefix(160)) : c.body
        let made = TaskItem(id: newId, name: name.isEmpty ? "Untitled task" : name, estimateMin: 25, totalFocused: 0, done: false,
                            priority: .medium, tags: ["from-capture", c.tag.rawValue], objectives: [], comments: [],
                            lifeArea: "Work", createdAt: now(), updatedAt: now())
        api.upsertTask(made)
        c.taskId = c.taskId ?? newId
        api.upsertCapture(c)
        api.archiveCapture(c.id, archived: true)
        scratch.newTasks[made.id] = made
        return "ok: promoted capture to task id=\(newId) name=\"\(c.body)\""

    case "resolve_capture":
        let id = args.str("captureId")
        guard let c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        api.archiveCapture(c.id, archived: true)
        return "ok: resolved capture \"\(c.body)\""

    case "delete_capture":
        let id = args.str("captureId")
        guard let c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        api.removeCapture(c.id)
        return "ok: deleted capture \"\(c.body)\""

    // ── LISTS ──
    case "rename_list":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let nm = args.str("name")
        guard let c else { return "error: list not found" }
        guard let nm else { return "error: name required" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        api.renameCollection(c.id, name: nm)
        return "ok: renamed list \"\(c.name)\" → \"\(nm)\""

    case "archive_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        let archived = args.bool("archived") ?? true
        api.updateCollection(c.id, archived: archived, color: nil)
        return "ok: \(archived ? "archived" : "unarchived") list \"\(c.name)\""

    case "delete_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        api.removeCollection(c.id)
        scratch.newLists.removeValue(forKey: c.id)
        return "ok: deleted list \"\(c.name)\""

    case "edit_list_item":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        let body = args.str("body")
        guard let c, let item else { return "error: list item not found" }
        guard let body else { return "error: body required" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        api.updateCollectionItem(collectionId: c.id, itemId: item.id, body: body, done: nil)
        return "ok: edited item in \"\(c.name)\" → \"\(body)\""

    case "remove_list_item":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        guard let c, let item else { return "error: list item not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        api.removeCollectionItem(collectionId: c.id, itemId: item.id)
        return "ok: removed \"\(item.body)\" from \"\(c.name)\""

    case "set_list_item_done":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        guard let c, let item else { return "error: list item not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        let done = args.bool("done") ?? true
        api.updateCollectionItem(collectionId: c.id, itemId: item.id, body: nil, done: done)
        return "ok: \(done ? "ticked" : "unticked") \"\(item.body)\" in \"\(c.name)\""

    // ── AREAS & TAGS ──
    case "create_area":
        guard let nm = args.str("name") else { return "error: name required" }
        if api.getAreaRows().contains(where: { $0.name.lowercased() == nm.lowercased() }) { return "error: area \"\(nm)\" already exists" }
        api.addArea(name: nm, color: args.str("color"))
        return "ok: created area \"\(nm)\""

    case "rename_area":
        let from = args.str("name")
        let to = args.str("newName")
        guard let row = api.getAreaRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no area named \"\(from ?? "")\" — areas: \(api.getAreas().joined(separator: ", "))"
        }
        guard let to else { return "error: newName required" }
        api.updateArea(row.id, name: to, color: nil)
        return "ok: renamed area \"\(from ?? "")\" → \"\(to)\" (tasks updated)"

    case "delete_area":
        let from = args.str("name")
        guard let row = api.getAreaRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no area named \"\(from ?? "")\""
        }
        api.removeArea(row.id)
        return "ok: deleted area \"\(from ?? "")\" (its tasks keep everything else)"

    case "create_tag":
        guard let nm = args.str("name") else { return "error: name required" }
        api.addTag(name: nm)
        return "ok: tag \"\(nm)\" ready"

    case "rename_tag":
        let from = args.str("name")
        let to = args.str("newName")
        guard let row = api.getTagRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no tag named \"\(from ?? "")\""
        }
        guard let to else { return "error: newName required" }
        api.updateTag(row.id, name: to)
        return "ok: renamed tag \"\(from ?? "")\" → \"\(to)\""

    case "delete_tag":
        let from = args.str("name")
        guard let row = api.getTagRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no tag named \"\(from ?? "")\""
        }
        api.removeTag(row.id)
        return "ok: deleted tag \"\(from ?? "")\" (removed from tasks)"

    // ── PEOPLE ──
    case "unshare_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let who = (args.str("person") ?? "").lowercased()
        let shares = await api.listTaskShares(taskId: t.id)
        if shares.isEmpty { return "error: \"\(t.name)\" isn't shared with anyone" }
        let hits = who.isEmpty ? shares : shares.filter { $0.recipientName.lowercased().contains(who) }
        if hits.count != 1 {
            let why = who.isEmpty ? "say who" : (hits.isEmpty ? "nobody matches \"\(who)\"" : "more than one person matches \"\(who)\"")
            return "error: \(why) — shared with: \(shares.map { "\($0.recipientName) (\($0.level))" }.joined(separator: ", "))"
        }
        do { try await api.unshareTask(shareId: hits[0].shareId) } catch { return "error: \(error.localizedDescription)" }
        return "ok: stopped sharing \"\(t.name)\" with \(hits[0].recipientName)"

    // ── SETTINGS ──
    case "set_usable_minutes":
        let wd = args.int("weekdayMin")
        let we = args.int("weekendMin")
        if wd == nil && we == nil { return "error: give weekdayMin and/or weekendMin" }
        if let wd, wd < 15 || wd > 1440 { return "error: minutes must be between 15 and 1440" }
        if let we, we < 15 || we > 1440 { return "error: minutes must be between 15 and 1440" }
        await api.setUsableMinutes(weekday: wd, weekend: we)
        return "ok: usable time set\(wd.map { " — weekdays \($0)m" } ?? "")\(we.map { " — weekends \($0)m" } ?? "")"

    case "set_notification_level":
        let lvl = (args.str("level") ?? "").lowercased()
        if !["calm", "balanced", "coach"].contains(lvl) { return "error: level must be calm, balanced, or coach" }
        let ok = await api.setNotificationLevel(lvl)
        return ok ? "ok: notifications set to \(lvl)" : "error: could not save the notification level (offline?)"

    case "set_reminder_lead":
        guard let m = args.int("minutes"), [0, 5, 10, 15].contains(m) else { return "error: minutes must be 0 (off), 5, 10, or 15" }
        let ok = await api.setReminderLead(m)
        return ok ? "ok: task reminders \(m == 0 ? "off" : "\(m) minutes before")" : "error: could not save (offline?)"

    case "set_ritual":
        let r = (args.str("ritual") ?? "").lowercased()
        if !["morning", "evening", "friday", "sunday"].contains(r) { return "error: ritual must be morning, evening, friday, or sunday" }
        let on = args.bool("on") ?? true
        api.setRitual(r, on: on)
        return "ok: \(r) moment \(on ? "on" : "off")"

    case "forget_fact":
        let id = args.str("factId")
        let text = (args.str("match") ?? "").lowercased()
        let facts = api.getProfileFacts()
        let target: ProfileFact?
        if let id {
            target = facts.first { $0.id == id }
        } else {
            let hits = text.isEmpty ? [] : facts.filter { $0.fact.lowercased().contains(text) }
            if hits.count > 1 {
                return "error: \(hits.count) facts match \"\(text)\" — be more specific: \(hits.map { "\"\($0.fact)\"" }.joined(separator: "; "))"
            }
            target = hits.first
        }
        guard let target else { return "error: no matching fact" }
        _ = api.removeProfileFact(target.id)
        return "ok: forgot \"\(target.fact)\""

    // ── INSIGHTS ──
    case "get_insights":
        let w = (args.str("window") ?? "week").lowercased()
        guard let window = InsightsWindow(rawValue: w) else { return "error: window must be week, month, or all" }
        return renderInsights(tasks: api.getTasks(), sessions: api.getSessions(), captures: api.getCaptures(),
                              reasons: api.getReasonLogs(), blocks: api.getBlocks(), now: Date(), window: window)

    // ── NAVIGATE ──
    case "open_screen":
        let s = (args.str("screen") ?? "").lowercased()
        let id = args.str("id")
        guard AssistantScreens.known.contains(s) else {
            return "error: unknown screen \"\(s)\" — try today, tasks, calendar, week, month, focus, insights, lists, captures, settings, people, notifications"
        }
        let withId = id != nil && (s == "tasks" || s == "lists" || s == "collections")
        api.navigate(screen: s, id: withId ? id : nil)
        return "ok: opened \(s)"

    default:
        return nil
    }
}

/// The contract's screen vocabulary (+ the web's aliases). The AppModel side
/// (`AppModel+Routing.swift`) maps each to the existing tab/route machinery.
enum AssistantScreens {
    static let known: Set<String> = [
        "today", "dashboard", "home", "tasks", "calendar", "day", "week", "month", "focus", "insights", "analytics",
        "lists", "collections", "captures", "inbox", "settings", "people", "notifications", "areas",
    ]
}
