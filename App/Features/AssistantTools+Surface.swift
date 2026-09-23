// The full app surface (2026-09-02: "the model should be able to do everything
// a user can do"): reopen/list tasks, calendar edits, focus controls, captures,
// list edits, areas + tags, unshare, settings, insights, navigation — and the
// 2026-09-20 registry additions (set_task_reminder, finish_focus,
// recolor_list, leave_list, pin_list_item, restore_capture, get_settings,
// set_theme, set_focus_defaults, set_ambient_sound). Every `ok:` describes a
// change the store confirmed; partial results name what was NOT done
// (docs/assistant-tooling-rules.md §1).

import Foundation
import UnstuckCore

/// Refusal for an owner-only list action attempted on a list shared WITH the
/// user, or nil when it's allowed. Rename / archive / delete are owner-only
/// both in the UI and server-side (RLS + the metadata lock accept an EDITOR's
/// write and silently discard it), so gating them on `canEditCollection` made
/// the assistant report a change that snapped back a second later. A list
/// created in THIS turn is ours by construction (the local row has no ownerId
/// until the server echo lands), so it bypasses the check — same as web.
@MainActor
private func ownerOnlyRefusal(_ c: ItemCollection, verb: String,
                              api: AssistantAppState, scratch: TurnScratch) -> String? {
    if scratch.newLists[c.id] != nil { return nil }
    if api.ownsCollection(c.id) { return nil }
    return "error: \"\(c.name)\" is shared with you by its owner — only they can \(verb) it. You can still add, edit and tick items."
}

// MARK: - dispatcher for the 2026-09-02 tools (+ the 2026-09-20 additions)

@MainActor
func runSurfaceTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String? {
    let now = AppModel.isoNow

    switch name {
    // ── TASKS ──
    case "uncomplete_task":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        // An open repeating series: "untick that" means TODAY's occurrence —
        // the day complete_task now ticks (audit 2026-09-22, C3). No id= in
        // the result, so the receipt offers no Undo: its `.completeTask` would
        // set the series' own done and end it.
        if t.recurrence != nil && !t.done {
            let today = api.todayIso()
            guard var b = api.getBlocks().filter({ $0.taskId == t.id && $0.date == today && !$0.skipped && $0.done })
                .max(by: { $0.startTime < $1.startTime }) else {
                return "error: \"\(t.name)\" repeats and isn't done on \(today) — nothing changed"
            }
            b.done = false
            b.completedAt = nil
            await api.upsertBlock(b)
            return "ok: reopened \"\(t.name)\" for \(today) (series continues)"
        }
        // Already open → error, never "ok: reopened": that receipt's Undo would
        // COMPLETE a task the user never finished (web parity).
        if !t.done { return "error: \"\(t.name)\" is already open — nothing changed" }
        t.done = false
        t.completedAt = nil
        t.updatedAt = now()
        await api.upsertTask(t)
        // A loop-promoted shared-list task: un-tick the collection row for the
        // other members too (the UI's un-complete sends `reopen`; a bare
        // upsert would leave the shared row ticked with an open task behind it).
        api.notifyTaskReopenedIfShared(t)
        scratch.newTasks[t.id] = t
        // A series the old path ended is running again — no id= either, for
        // the same reason: its Undo would end it once more (C3).
        if t.recurrence != nil { return "ok: reopened \"\(t.name)\" — its repeating series runs again" }
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
        // The completed view is DATED and newest first: an undated all-time
        // list was read back as "today" (Zubair's evening call, 2026-09-20 —
        // "you completed quite a bit today: … Hike, Abba Barde", weeks old).
        let today = api.todayIso()
        if view == .completed { rows.sort { ($0.completedAt ?? "") > ($1.completedAt ?? "") } }
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
            // When it was created — "the ones I created last week" (Ahmad,
            // 2026-09-20 23:47: the model rightly said the list didn't show it).
            if let c = doneWhenLabel(t.createdAt, today: today) { line += " · created \(c)" }
            if t.done {
                let stamp = t.completedAt ?? occ?.completedAt
                line += " · done" + (doneWhenLabel(stamp, today: today).map { " \($0)" } ?? "")
            }
            return line
        }
        let order = view == .completed && rows.count > 1 ? ", newest first" : ""
        return "ok: \(view.rawValue) (\(rows.count))\(order)\(rows.count > 30 ? ", first 30" : ""):\n\(lines.isEmpty ? "(none)" : lines.joined(separator: "\n"))"

    case "set_task_reminder":
        // Per-task lead override (NotificationPrefs.setReminderOverride + a
        // scheduler resync) — omit minutes = back to the default, 0 = off.
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let minutes = args.int("minutes")
        if let m = minutes, ![0, 5, 10, 15].contains(m) { return "error: minutes must be 0 (off), 5, 10 or 15 — or omit it for the default" }
        guard api.setTaskReminder(taskId: t.id, minutes: minutes) else { return "error: couldn't save the reminder — try again" }
        let unscheduled = nextLiveBlock(api, taskId: t.id) == nil ? " (it isn't on the calendar yet — the reminder applies once it is scheduled)" : ""
        switch minutes {
        case nil:
            let lead = api.getSettings().reminderLeadMin
            return "ok: \"\(t.name)\" reminds at the default lead — \(lead == 0 ? "reminders are off by default" : "\(lead) minutes before")\(unscheduled)"
        case 0?:
            return "ok: no reminder for \"\(t.name)\"\(unscheduled)"
        case let m?:
            return "ok: \"\(t.name)\" reminds \(m) minutes before it starts\(unscheduled)"
        }

    // ── CALENDAR ──
    case "unschedule_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        // A repeating task is refused, even with no upcoming slot left: with
        // the repeat still on, the horizon top-up rebuilt every removed slot at
        // the next launch or midnight although the result said they were gone
        // (audit 2026-09-22, C1). Which one the user means is theirs to say.
        if t.recurrence != nil {
            return "error: \"\(t.name)\" repeats — nothing changed. Ask the user which they mean: stop the whole series (set_task_recurrence kind none) or skip just one day (skip_occurrence with the date)."
        }
        let today = api.todayIso()
        let live = api.getBlocks().filter { $0.taskId == t.id && !$0.done && !$0.skipped && $0.date >= today }
        if live.isEmpty { return "error: \"\(t.name)\" has no upcoming slot to remove" }
        for b in live { await api.deleteBlock(b.id) }
        return "ok: unscheduled \"\(t.name)\" (task kept, \(live.count) slot\(live.count == 1 ? "" : "s") removed)"

    case "skip_occurrence":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let date = args.str("date") ?? api.todayIso()
        guard var b = api.getBlocks().first(where: { $0.taskId == t.id && $0.date == date && !$0.done }) else {
            return "error: \"\(t.name)\" has nothing on \(date) to skip"
        }
        // Re-skipping is a no-op — say so instead of a second "Skipped" receipt.
        if b.skipped { return "error: \"\(t.name)\" is already skipped on \(date) — nothing changed" }
        b.skipped = true
        await api.upsertBlock(b)
        return "ok: skipped \"\(t.name)\" on \(date) (the task and its other days stay)"

    case "complete_occurrence":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let date = args.str("date") ?? api.todayIso()
        guard let b = api.getBlocks().first(where: { $0.taskId == t.id && $0.date == date && !$0.skipped }) else {
            return "error: \"\(t.name)\" has nothing on \(date)"
        }
        // Already done that day → error, not a second "Done for today" receipt.
        if b.done { return "error: \"\(t.name)\" is already done on \(date) — nothing changed" }
        // …and for a ONE-OFF task, done can live on the task rather than the
        // block. complete_task refuses that case precisely because the
        // receipt's Undo would reopen something finished earlier; this path
        // was missing the same guard (audit 2026-09-21).
        if t.recurrence == nil, t.done {
            return "error: \"\(t.name)\" is already done — nothing changed"
        }
        // Stamped like the UI's tick (audit 2026-09-22, C6): the block gets
        // its completedAt (a repeating day then counts as done today), and a
        // one-off task its completedAt + shared-list notice. The template of a
        // series is never touched.
        await markOccurrenceDone(b, api: api)
        if t.recurrence == nil { _ = await markTaskDone(t, api: api, scratch: scratch) }
        return "ok: marked \"\(t.name)\" done for \(date)\(t.recurrence != nil ? " (series continues)" : "")"

    case "block_time":
        let nm = args.str("name")
        let date = args.str("date")
        let rawStart = args.str("startTime")
        // Clamped to the server's CHECK (5…1440): an out-of-range block is
        // accepted locally, refused on flush and quarantined in silence.
        let dur = clampDurationMin(args.int("durationMin"), fallback: 60)
        guard let nm, let date, let rawStart else { return "error: name, date and startTime are all required for block_time" }
        // '9:00' or '7:30pm' failed the server's HH:MM check and was
        // quarantined while this said "blocked" (audit 2026-09-22, C28).
        guard let startTime = normalizeClockTime(rawStart) else {
            return (rejectBadStartTime(rawStart) ?? "error: startTime must be 24-hour HH:MM.") + " Nothing was blocked."
        }
        if let past = rejectPastDate(today: api.todayIso(), date: date)
            ?? rejectPastTime(blocks: api.getBlocks(), today: api.todayIso(), date: date, startTime: startTime, nowHM: api.nowHM()) {
            return past
        }
        let t = TaskItem(id: newUUID(), name: nm, estimateMin: dur, totalFocused: 0, done: false, priority: .medium,
                         tags: [], objectives: [], comments: [], later: false, createdAt: now(), updatedAt: now())
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        await api.upsertBlock(CalBlock(id: newUUID(), taskId: t.id, taskName: nm, startTime: startTime, durationMinutes: dur, date: date, kind: .task))
        return "ok: blocked \"\(nm)\" \(date) \(startTime) for \(dur)m id=\(t.id)"

    case "carry_to_tomorrow":
        let today = api.todayIso()
        let tomorrow = LocalDate.addDays(today, 1)
        let wanted = args.strList("taskIds")
        // Task blocks only (web: `b.taskId && …`) — a block with no task has
        // nothing to carry and nothing to bump.
        // "Unfinished" = neither the block nor its TASK is done: a one-off task
        // ticked off (done on the task, not the block) was carried to tomorrow
        // with the open ones (Zubair's evening call, 2026-09-21: "moved 4 —
        // Project Check-in, …" — the check-in was done at noon).
        let doneTaskIds = Set(api.getTasks().filter { $0.done }.map { $0.id })
        let todays = api.getBlocks().filter { b in
            b.taskId != nil && b.date == today && !b.done && !b.skipped && isTaskBlock(b)
                && !doneTaskIds.contains(b.taskId ?? "")
                && (wanted == nil || wanted!.contains(b.taskId ?? ""))
        }
        if todays.isEmpty { return "error: nothing left on today to carry" }
        // A task tomorrow ALREADY has is skipped today instead of moved — it
        // is reported as "not moved", never counted as carried (rules §1).
        var moved: [String] = []
        var skipped: [String] = []
        for b in todays {
            let t = api.getTasks().first { $0.id == b.taskId }
            let tomorrowTaken = api.getBlocks().contains { $0.taskId == b.taskId && $0.date == tomorrow && !$0.skipped }
            var next = b
            if tomorrowTaken { next.skipped = true } else { next.date = tomorrow }
            await api.upsertBlock(next)
            if let t { await api.upsertTask(bumpMoveCount(t, nowISO: now())) }
            let nm = "\"\(t?.name ?? b.taskName)\""
            if tomorrowTaken { skipped.append(nm) } else { moved.append(nm) }
        }
        let notMoved = skipped.isEmpty ? "" : ". Not moved: \(skipped.joined(separator: ", ")) (tomorrow already has \(skipped.count == 1 ? "it" : "them"); skipped today instead)"
        if moved.isEmpty { return "ok: moved 0 to \(tomorrow)\(notMoved)" }
        return "ok: moved \(moved.count) to \(tomorrow) — \(moved.joined(separator: ", "))\(notMoved)"

    // ── FOCUS ──
    case "start_focus":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        if let live = api.getLiveFocus(), live.sessionStart != nil {
            let cur = api.getTasks().first { $0.id == live.taskId }
            return "error: a focus session is already running on \"\(cur?.name ?? "a task")\" — pause or cancel it first, or ask the user"
        }
        let occ = t.recurrence != nil ? nextLiveBlock(api, taskId: t.id) : nil
        let est = args.int("estimateMin") ?? t.estimateMin
        // Awaited join-or-mint (was fire-and-forget): "focus started" is said
        // only once the session is live in the store.
        guard await api.startFocus(taskId: t.id, estimateMin: est, occurrenceBlockId: occ?.id) else {
            return "error: couldn't start a session on \"\(t.name)\" — nothing is running; try again"
        }
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
        guard api.extendFocus(mins) else { return "error: couldn't extend the session — its length is unchanged" }
        return "ok: extended the session by \(mins)m"

    case "finish_focus":
        // End + LOG (the focus screen's Done/End path): Session row,
        // totalFocused, optional completion. cancel_focus is the no-log one.
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        let markDone = args.bool("markDone") ?? false
        guard let out = await api.finishFocus(markDone: markDone) else {
            return "error: couldn't finish the session — nothing was logged and the task is unchanged; try again or use Done on the focus screen"
        }
        let mins = max(1, Int((Double(out.elapsedSec) / 60.0).rounded()))
        let state = out.markedDone ? "task marked done" : (markDone ? "task still open (a repeating task's series is never closed this way)" : "task still open")
        return "ok: finished the session on \"\(out.taskName)\" — \(mins)m logged, \(state)"

    case "cancel_focus":
        guard let live = api.getLiveFocus(), live.sessionStart != nil else { return "error: no focus session is running" }
        api.cancelFocus()
        return "ok: cancelled the focus session (nothing logged). To finish and LOG a session, use finish_focus."

    // ── CAPTURES ──
    case "add_capture":
        guard let body = args.str("body") else { return "error: body required" }
        let tagRaw = (args.str("tag") ?? "idea").lowercased()
        let tag = CaptureTag(rawValue: tagRaw) ?? .idea
        let t = findTask(args.str("taskId"), api: api, scratch: scratch)
        let live = api.getLiveFocus()
        // A body over the 500-character cap is truncated — and SAID (no silent
        // fallbacks, rules §1).
        let cut = body.count > 500
        let c = Capture(id: newUUID(), taskId: t?.id, sessionId: (live?.sessionStart != nil) ? live?.id : nil,
                        tag: tag, body: String(body.prefix(500)), at: now())
        await api.upsertCapture(c)
        return "ok: captured id=\(c.id) [\(tag.rawValue)] \"\(c.body)\"\(t.map { " on \"\($0.name)\"" } ?? "")\(cut ? " (cut to 500 characters — say so)" : "")"

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

    case "get_lists":
        // READ — the full set (context.lists carries only the first 12
        // unarchived), one list in full, or the archived ones. There was no
        // list-reading tool at all: the model guessed names for three rounds
        // (tester round, 2026-09-06). Result text 1:1 with tools.ts.
        let wantId = args.str("listId")
        let one = wantId.flatMap { findList($0, api: api, scratch: scratch) }
        if wantId != nil && one == nil { return "error: list not found" }
        let includeArchived = args.bool("includeArchived") ?? false
        let lists = one.map { [$0] } ?? api.getCollections().filter { includeArchived || $0.archived != true }
        if lists.isEmpty { return "ok: no lists yet" }
        let itemCap = one != nil ? 100 : 10
        var lines: [String] = []
        for c in lists.prefix(20) {
            let done = c.items.filter { $0.done == true }.count
            lines.append("- \"\(c.name)\" [id=\(c.id)] — \(c.items.count - done) open\(done > 0 ? ", \(done) done" : "")\(c.archived == true ? " · archived" : "")")
            if c.items.isEmpty { lines.append("  (empty)"); continue }
            for i in c.items.prefix(itemCap) { lines.append("  - \(i.body)\(i.done == true ? " (done)" : "")\(i.pinned == true ? " (pinned)" : "") [id=\(i.id)]") }
            if c.items.count > itemCap { lines.append("  … and \(c.items.count - itemCap) more — get_lists listId=\(c.id) for all") }
        }
        if lists.count > 20 { lines.append("… and \(lists.count - 20) more lists") }
        return "ok: \(lists.count) list\(lists.count == 1 ? "" : "s"):\n\(lines.joined(separator: "\n"))"

    case "promote_capture":
        let id = args.str("captureId")
        guard var c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        // lib/capture-actions promoteCapture: task from the body, link the capture.
        let newId = newUUID()
        let name = c.body.count > 160 ? String(c.body.prefix(160)) : c.body
        // The area comes from the task the capture is attached to, if any —
        // the old hard-coded "Work" put every promoted thought in Work.
        let linked = c.taskId.flatMap { tid in findTask(tid, api: api, scratch: scratch) }
        let made = TaskItem(id: newId, name: name.isEmpty ? "Untitled task" : name, estimateMin: 25, totalFocused: 0, done: false,
                            priority: .medium, tags: ["from-capture", c.tag.rawValue], objectives: [], comments: [],
                            lifeArea: linked?.lifeArea, createdAt: now(), updatedAt: now())
        await api.upsertTask(made)
        c.taskId = c.taskId ?? newId
        await api.upsertCapture(c)
        api.archiveCapture(c.id, archived: true)
        scratch.newTasks[made.id] = made
        let trimmed = name.count < c.body.count ? " (title cut to 160 characters)" : ""
        return "ok: promoted capture to task id=\(newId) name=\"\(c.body)\"\(trimmed)"

    case "resolve_capture":
        let id = args.str("captureId")
        guard let c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        if api.getArchivedCaptureIds().contains(c.id) { return "error: \"\(c.body)\" is already resolved — nothing changed" }
        api.archiveCapture(c.id, archived: true)
        return "ok: resolved capture \"\(c.body)\""

    case "restore_capture":
        let id = args.str("captureId")
        guard let c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        if !api.getArchivedCaptureIds().contains(c.id) { return "error: \"\(c.body)\" is not archived — it is already in the inbox; nothing changed" }
        api.archiveCapture(c.id, archived: false)
        return "ok: restored capture \"\(c.body)\" to the inbox"

    case "delete_capture":
        let id = args.str("captureId")
        guard let c = api.getCaptures().first(where: { $0.id == id }) else { return "error: capture not found" }
        await api.removeCapture(c.id)
        return "ok: deleted capture \"\(c.body)\""

    // ── LISTS ──
    case "rename_list":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let nm = args.str("name")
        guard let c else { return "error: list not found" }
        guard let nm else { return "error: name required" }
        if let refusal = ownerOnlyRefusal(c, verb: "rename", api: api, scratch: scratch) { return refusal }
        if nm.trimmingCharacters(in: .whitespacesAndNewlines) == c.name { return "error: the list is already called \"\(c.name)\" — nothing changed" }
        guard await api.renameCollection(c.id, name: nm) else { return "error: couldn't rename \"\(c.name)\" — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: renamed list \"\(c.name)\" → \"\(nm)\""

    case "recolor_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        let color = (args.str("color") ?? "").lowercased()
        if !LIST_COLORS.contains(color) { return "error: unknown colour \"\(color)\" — use \(LIST_COLORS.joined(separator: ", "))" }
        if let refusal = ownerOnlyRefusal(c, verb: "recolour", api: api, scratch: scratch) { return refusal }
        if c.color == color { return "error: \"\(c.name)\" is already \(color) — nothing changed" }
        guard await api.updateCollection(c.id, archived: nil, color: color) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: recoloured list \"\(c.name)\" to \(color)"

    case "archive_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        let archived = args.bool("archived") ?? true
        if let refusal = ownerOnlyRefusal(c, verb: archived ? "archive" : "unarchive", api: api, scratch: scratch) { return refusal }
        if (c.archived ?? false) == archived { return "error: \"\(c.name)\" is \(archived ? "already archived" : "not archived") — nothing changed" }
        guard await api.updateCollection(c.id, archived: archived, color: nil) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: \(archived ? "archived" : "unarchived") list \"\(c.name)\""

    case "delete_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if let refusal = ownerOnlyRefusal(c, verb: "delete", api: api, scratch: scratch) { return refusal }
        guard await api.removeCollection(c.id) else { return "error: couldn't delete \"\(c.name)\" — try again" }
        scratch.newLists.removeValue(forKey: c.id)
        return "ok: deleted list \"\(c.name)\""

    case "leave_list":
        // Confirm-first in the prompt; here only the facts: an own list can't
        // be left, and "left" is said only once the server confirmed it.
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if scratch.newLists[c.id] != nil || api.ownsCollection(c.id) {
            return "error: \"\(c.name)\" is the user's own list — only a list shared WITH them can be left; delete_list or archive_list it instead"
        }
        guard await api.leaveCollection(c.id) else {
            return "error: couldn't leave \"\(c.name)\" — the server didn't confirm it (offline?); it is still shared with them; try again"
        }
        return "ok: left \"\(c.name)\" — the user no longer sees it; the owner keeps it"

    case "edit_list_item":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        let body = args.str("body")
        guard let c, let item else { return "error: list item not found" }
        guard let body else { return "error: body required" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        guard await api.updateCollectionItem(collectionId: c.id, itemId: item.id, body: body, done: nil, pinned: nil) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: edited item in \"\(c.name)\" → \"\(body)\""

    case "remove_list_item":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        guard let c, let item else { return "error: list item not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        guard await api.removeCollectionItem(collectionId: c.id, itemId: item.id) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: removed \"\(item.body)\" from \"\(c.name)\""

    case "set_list_item_done":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        guard let c, let item else { return "error: list item not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        let done = args.bool("done") ?? true
        if (item.done ?? false) == done { return "error: \"\(item.body)\" is already \(done ? "ticked" : "unticked") — nothing changed" }
        guard await api.updateCollectionItem(collectionId: c.id, itemId: item.id, body: nil, done: done, pinned: nil) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: \(done ? "ticked" : "unticked") \"\(item.body)\" in \"\(c.name)\""

    case "pin_list_item":
        let c = findList(args.str("listId"), api: api, scratch: scratch)
        let item = c?.items.first { $0.id == args.str("itemId") }
        guard let c, let item else { return "error: list item not found" }
        if !api.canEditCollection(c.id) { return "error: you can't edit \"\(c.name)\"" }
        let pinned = args.bool("pinned") ?? true
        if (item.pinned ?? false) == pinned { return "error: \"\(item.body)\" is \(pinned ? "already pinned" : "not pinned") — nothing changed" }
        guard await api.updateCollectionItem(collectionId: c.id, itemId: item.id, body: nil, done: nil, pinned: pinned) else { return "error: couldn't save — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: \(pinned ? "pinned" : "unpinned") \"\(item.body)\" in \"\(c.name)\""

    // ── AREAS & TAGS ──
    case "create_area":
        // `str` hands back the untrimmed text: " Home " slipped past the
        // duplicate check below (audit 2026-09-22, C19).
        guard let nm = args.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "error: name required" }
        if api.getAreaRows().contains(where: { $0.name.lowercased() == nm.lowercased() }) { return "error: area \"\(nm)\" already exists" }
        await api.addArea(name: nm, color: args.str("color"))
        return "ok: created area \"\(nm)\""

    case "rename_area":
        let from = args.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = args.str("newName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let row = api.getAreaRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no area named \"\(from ?? "")\" — areas: \(api.getAreas().joined(separator: ", "))"
        }
        guard let to else { return "error: newName required" }
        // Tasks key areas by name and the server has unique(user_id, name): a
        // rename onto another area's name was quarantined by the outbox while
        // the task relabels synced, and the tool still said ok. Refuse rather
        // than merge (Android parity; audit 2026-09-22, C19). A case-only
        // rename of the same area is fine.
        if to == row.name { return "error: area \"\(row.name)\" already has that name — nothing changed" }
        if let taken = api.getAreaRows().first(where: { $0.id != row.id && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
            return "error: area \"\(taken.name)\" already exists — nothing changed"
        }
        await api.updateArea(row.id, name: to, color: nil)
        return "ok: renamed area \"\(from ?? "")\" → \"\(to)\" (tasks updated)"

    case "delete_area":
        let from = args.str("name")
        guard let row = api.getAreaRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no area named \"\(from ?? "")\""
        }
        await api.removeArea(row.id)
        return "ok: deleted area \"\(from ?? "")\" (its tasks keep everything else)"

    case "create_tag":
        guard let nm = args.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "error: name required" }
        // "The result says if it already exists" (registry) — a second
        // "ready" over an existing tag read as a fresh creation.
        if let existing = api.getTagRows().first(where: { $0.name.lowercased() == nm.lowercased() }) {
            return "error: tag \"\(existing.name)\" already exists — nothing changed"
        }
        await api.addTag(name: nm)
        return "ok: created tag \"\(nm)\""

    case "rename_tag":
        let from = args.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = args.str("newName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let row = api.getTagRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no tag named \"\(from ?? "")\""
        }
        guard let to else { return "error: newName required" }
        // Same unique(user_id, name) quarantine as rename_area (audit
        // 2026-09-22, C19).
        if to == row.name { return "error: tag \"\(row.name)\" already has that name — nothing changed" }
        if let taken = api.getTagRows().first(where: { $0.id != row.id && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
            return "error: tag \"\(taken.name)\" already exists — nothing changed"
        }
        await api.updateTag(row.id, name: to)
        return "ok: renamed tag \"\(from ?? "")\" → \"\(to)\""

    case "delete_tag":
        let from = args.str("name")
        guard let row = api.getTagRows().first(where: { $0.name.lowercased() == (from ?? "").lowercased() }) else {
            return "error: no tag named \"\(from ?? "")\""
        }
        await api.removeTag(row.id)
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
        // The revoke is a server RPC: "stopped sharing" over a failed call
        // would leave the person with access while the user believes otherwise.
        do { try await api.unshareTask(shareId: hits[0].shareId) } catch { return "error: couldn't revoke the share — try again" }
        return "ok: stopped sharing \"\(t.name)\" with \(hits[0].recipientName)"

    // ── SETTINGS ──
    case "get_settings":
        let s = api.getSettings()
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        let budget: String = {
            if s.usableWeekdayMin == nil && s.usableWeekendMin == nil { return "not set" }
            return [s.usableWeekdayMin.map { "weekdays \($0)m" }, s.usableWeekendMin.map { "weekends \($0)m" }].compactMap { $0 }.joined(separator: ", ")
        }()
        let rituals = ["morning", "evening", "friday", "sunday"].map { "\($0) \(onOff(s.rituals[$0] ?? false))" }.joined(separator: ", ")
        return "ok: settings:\n"
            + "- notifications: \(s.notificationLevel)\n"
            + "- reminder lead: \(s.reminderLeadMin == 0 ? "off" : "\(s.reminderLeadMin) minutes before a task")\n"
            + "- usable minutes: \(budget)\n"
            + "- focus defaults: \(s.focusDefaultMin)m sessions, \(s.focusOverrunMin == 0 ? "no overrun grace" : "\(s.focusOverrunMin)m overrun grace"), soft exit \(onOff(s.focusSoftExit)), pause reasons \(onOff(s.focusPauseReasons))\n"
            + "- theme: \(s.theme)\n"
            + "- ambient sound: \(s.ambient)\n"
            + "- rituals: \(rituals)"

    case "set_usable_minutes":
        let wd = args.int("weekdayMin")
        let we = args.int("weekendMin")
        if wd == nil && we == nil { return "error: give weekdayMin and/or weekendMin" }
        if let wd, wd < 15 || wd > 1440 { return "error: minutes must be between 15 and 1440" }
        if let we, we < 15 || we > 1440 { return "error: minutes must be between 15 and 1440" }
        let ok = await api.setUsableMinutes(weekday: wd, weekend: we)
        return ok
            ? "ok: usable time set\(wd.map { " — weekdays \($0)m" } ?? "")\(we.map { " — weekends \($0)m" } ?? "")"
            : "error: could not save usable minutes (offline?)"

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
        let cur = api.getSettings().rituals[r] ?? false
        if cur == on { return "error: the \(r) moment is already \(on ? "on" : "off") — nothing changed" }
        guard api.setRitual(r, on: on) else { return "error: couldn't save the \(r) moment — it is still \(cur ? "on" : "off")" }
        return "ok: \(r) moment \(on ? "on" : "off")"

    case "set_theme":
        let theme = (args.str("theme") ?? "").lowercased()
        if !["system", "light", "dark"].contains(theme) { return "error: theme must be system, light, or dark" }
        if api.getSettings().theme == theme { return "error: the theme is already \(theme) — nothing changed" }
        guard api.setTheme(theme) else { return "error: couldn't switch the theme — it is still \(api.getSettings().theme)" }
        return "ok: theme set to \(theme)"

    case "set_focus_defaults":
        let dm = args.int("defaultMinutes")
        let om = args.int("overrunMinutes")
        let se = args.bool("softExit")
        let pr = args.bool("pauseReasons")
        if dm == nil && om == nil && se == nil && pr == nil { return "error: give at least one of defaultMinutes, overrunMinutes, softExit, pauseReasons" }
        if let dm, ![15, 25, 45].contains(dm) { return "error: defaultMinutes must be 15, 25 or 45" }
        if let om, ![0, 5, 10].contains(om) { return "error: overrunMinutes must be 0, 5 or 10" }
        guard api.setFocusDefaults(defaultMinutes: dm, overrunMinutes: om, softExit: se, pauseReasons: pr) else { return "error: couldn't save — try again" }
        var parts: [String] = []
        if let dm { parts.append("\(dm)m sessions") }
        if let om { parts.append(om == 0 ? "no overrun grace" : "\(om)m overrun grace") }
        if let se { parts.append("soft exit \(se ? "on" : "off")") }
        if let pr { parts.append("pause reasons \(pr ? "on" : "off")") }
        return "ok: focus defaults — \(parts.joined(separator: ", "))"

    case "set_ambient_sound":
        let sound = (args.str("sound") ?? "").lowercased()
        if !["off", "brown", "pink"].contains(sound) { return "error: sound must be off, brown, or pink" }
        if api.getSettings().ambient == sound { return "error: ambient sound is already \(sound) — nothing changed" }
        guard api.setAmbientSound(sound) else { return "error: couldn't save — try again" }
        return "ok: ambient sound \(sound == "off" ? "off" : "set to \(sound) noise")"

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
        // The store's verdict used to be ignored — "forgot" over a fact still
        // in every future prompt.
        guard api.removeProfileFact(target.id) else { return "error: couldn't forget that just now — try again" }
        return "ok: forgot \"\(target.fact)\""

    // ── INSIGHTS ──
    case "get_insights":
        let w = (args.str("window") ?? "week").lowercased()
        guard let window = InsightsWindow(rawValue: w) else { return "error: window must be week, month, or all" }
        var out = renderInsights(tasks: api.getTasks(), sessions: api.getSessions(), captures: api.getCaptures(),
                                 reasons: api.getReasonLogs(), blocks: api.getBlocks(), now: Date(), window: window)
        // The week window starts on Monday: early in the week it is a day or
        // two of data. "How was my last week?" on a Monday was answered from
        // it as if it were the week before (Ahmad, 2026-09-20 23:46).
        if window == .week {
            let dow = LocalDate.dayOfWeek(api.todayIso())   // 0 = Sunday … 1 = Monday
            let daysIn = dow == 0 ? 7 : dow
            if daysIn <= 2 {
                out += "\nnote: this is the CURRENT week, \(daysIn == 1 ? "today only" : "two days") so far — it says nothing about last week. If they asked about last week, say the app has no last-week window yet and offer the month (window: month)."
            }
        }
        return out

    // ── NAVIGATE ──
    case "open_screen":
        let s = (args.str("screen") ?? "").lowercased()
        let id = args.str("id")
        guard AssistantScreens.known.contains(s) else {
            return "error: unknown screen \"\(s)\" — use one of: \(AssistantScreens.registry.joined(separator: ", "))"
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
    /// The registry's `open_screen.screen` enum, in its order.
    static let registry: [String] = [
        "today", "tasks", "calendar", "day", "week", "month", "focus", "insights", "lists", "captures", "settings",
        "people", "notifications", "areas",
    ]
    /// Registry names + the web's aliases (dashboard/home, analytics, collections, inbox).
    static let known: Set<String> = Set(registry).union(["dashboard", "home", "analytics", "collections", "inbox"])
}


/// "today" / "yesterday" / "Fri 19 Sep" for a completion instant, in the
/// device's zone against the app's local `today`; nil when there is no stamp.
func doneWhenLabel(_ completedAt: String?, today: String, tz: TimeZone = .current) -> String? {
    guard let day = CallDayContext.localDate(ofISO: completedAt, tz: tz) else { return nil }
    if day == today { return "today" }
    if day == LocalDate.addDays(today, -1) { return "yesterday" }
    let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.timeZone = tz; inF.dateFormat = "yyyy-MM-dd"
    guard let d = inF.date(from: day) else { return day }
    let outF = DateFormatter(); outF.locale = Locale(identifier: "en_US_POSIX"); outF.timeZone = tz; outF.dateFormat = "EEE d MMM"
    return outF.string(from: d)
}
