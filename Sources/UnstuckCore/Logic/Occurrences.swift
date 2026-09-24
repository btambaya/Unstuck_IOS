// Recurring-task occurrences. Port of lib/occurrences.ts / Occurrences.kt.
//
// A repeating task is a hidden TEMPLATE (task.recurrence != nil). Its occurrence
// cal_blocks each carry their own done/skipped/completedAt (migration 033). At
// read time we PROJECT those blocks into synthetic one-day TaskItem rows
// (id = block id) so each occurrence appears in Today/All/Upcoming as an
// independent, completable task, while the template is hidden everywhere except
// the "Recurring" tab. Completing / skipping / focusing an occurrence writes the
// cal_block, never the template.
//
// Detection: an occurrence row's id IS a cal_block id, so any consumer can
// recover it via `occurrenceBlockFor` (a normal task's id is never a block id).

import Foundation

/// A recurring TEMPLATE — hidden from every view except "Recurring".
public func isTemplate(_ t: TaskItem) -> Bool { t.recurrence != nil }

/// Project one synthetic one-day occurrence row per non-skipped occurrence
/// cal_block of a recurring template, on or after `fromISO`. id = block id;
/// name/tags/area/priority inherited from the template; estimate/done/completedAt
/// from the block; recurrence cleared (a plain one-day task).
public func projectOccurrences(_ tasks: [TaskItem], _ blocks: [CalBlock], fromISO: String) -> [TaskItem] {
    var templates: [String: TaskItem] = [:]
    for t in tasks where t.recurrence != nil { templates[t.id] = t }
    if templates.isEmpty { return [] }

    var out: [TaskItem] = []
    for b in blocks {
        guard isTaskBlock(b), let tid = b.taskId, !b.skipped, b.date >= fromISO,
              let tpl = templates[tid] else { continue }
        var occ = tpl
        occ.id = b.id                    // id = cal_block id
        occ.done = b.done
        occ.completedAt = b.completedAt
        occ.estimateMin = b.durationMinutes   // occurrence carries its own duration
        occ.recurrence = nil
        occ.later = false
        out.append(occ)
    }
    return out
}

/// One synthetic "overdue" occurrence row per recurring template whose most-
/// recent PAST occurrence was missed — i.e. that latest past occurrence is still
/// incomplete (NOT done AND NOT skipped) AND today is not itself a recurrence day
/// for it (a today occurrence supersedes the stale miss — it shows in Today). This
/// is what surfaces a missed "Call mom every Friday" in Backlog the day after,
/// instead of it vanishing until next Friday. Port of lib/occurrences.ts
/// `projectOverdueOccurrences`.
///
/// Keyed to the most-recent past occurrence on purpose, so the behaviour is:
///   • At most ONE overdue row per template — missing several weeks never stacks.
///   • Completing it marks that occurrence done → the most-recent past is now
///     complete → the row clears. Older incomplete misses are intentionally
///     ignored ("you don't owe 3 calls").
///   • The next live occurrence (today) takes over: no overdue while today is a
///     recurrence day.
/// Pure read — never mutates blocks. Each row's id IS the cal_block id, so the
/// usual `occurrenceBlockFor` routing resolves it for complete/skip/focus.
public func projectOverdueOccurrences(_ tasks: [TaskItem], _ blocks: [CalBlock], todayISO: String) -> [TaskItem] {
    var templates: [String: TaskItem] = [:]
    for t in tasks where t.recurrence != nil { templates[t.id] = t }
    if templates.isEmpty { return [] }

    var latestPast: [String: CalBlock] = [:]   // template id -> most-recent PAST occurrence block
    var hasToday = Set<String>()                // template ids with an occurrence dated today
    for b in blocks {
        guard isTaskBlock(b), let tid = b.taskId, templates[tid] != nil else { continue }
        if b.date == todayISO { hasToday.insert(tid); continue }
        if b.date > todayISO { continue }
        if let cur = latestPast[tid], cur.date >= b.date { continue }
        latestPast[tid] = b
    }

    var out: [TaskItem] = []
    for (tid, b) in latestPast {
        if hasToday.contains(tid) { continue }   // today's occurrence takes over
        if b.done || b.skipped { continue }      // most-recent past already handled
        guard let tpl = templates[tid] else { continue }
        var occ = tpl
        occ.id = b.id                            // id = cal_block id
        occ.done = false
        occ.completedAt = nil
        occ.estimateMin = b.durationMinutes
        occ.recurrence = nil
        occ.later = false
        out.append(occ)
    }
    return out
}

/// Map of overdue-occurrence row id → its missed occurrence date (YYYY-MM-DD).
/// The Backlog UI uses this to label a missed recurring row ("Overdue · Fri")
/// without re-deriving the rule per row. Same selection as
/// `projectOverdueOccurrences`, so the keys match exactly the overdue rows it
/// surfaces. Pure / read-only.
public func overdueOccurrenceDates(_ tasks: [TaskItem], _ blocks: [CalBlock], todayISO: String) -> [String: String] {
    var out: [String: String] = [:]
    for occ in projectOverdueOccurrences(tasks, blocks, todayISO: todayISO) {
        if let b = blocks.first(where: { $0.id == occ.id }) { out[occ.id] = b.date }
    }
    return out
}

/// The occurrence cal_block behind a projected row id, or nil if the row is a
/// normal task. Routing (complete/skip/focus) uses this to target the block.
public func occurrenceBlockFor(_ rowId: String, tasks: [TaskItem], blocks: [CalBlock]) -> CalBlock? {
    guard let b = blocks.first(where: { $0.id == rowId && isTaskBlock($0) }) else { return nil }
    return tasks.contains { $0.id == b.taskId && $0.recurrence != nil } ? b : nil
}

/// The row a FOCUS deep link (`unstuck://focus/<id>`) must open, given the id
/// it carries. Every in-app "Start" hands FocusView the ROW the user tapped —
/// an occurrence row for a repeating series — and FocusView resolves it
/// (`occurrenceFocusTarget`), so the live session runs on the template and
/// carries the day's block. A deep link is the one focus entry point that
/// arrives as a bare id, and BOTH of its senders got that id wrong:
///
///  • the starts-now notification's "Start" action carries the block's
///    `taskId`, which for a recurring series is the hidden TEMPLATE. Opening
///    the template ran the session with NO occurrence attached, so "Done"
///    marked the TEMPLATE done — ending the whole series — while today's
///    occurrence stayed open;
///  • the assistant's `open_screen: focus` re-opens the live session on its
///    occurrence ROW id (a cal_block id), which `taskRepo.fetch` could never
///    resolve, so it silently landed on Today instead of the running session.
///
/// The rule (web `resolveFocusTarget`, Android parity): a recurring series is
/// always focused through an OCCURRENCE row, everything else through its own
/// task row.
///  • a task-block id → that block's row (the occurrence for a recurring
///    template, the plain task otherwise);
///  • a plain task id → the task;
///  • a recurring TEMPLATE id → its live occurrence: today's if still open,
///    else the earliest open future one, else today's (already ticked), else
///    the template itself when it has no occurrence blocks at all;
///  • an unknown id → nil (the caller falls back to Today).
public func focusRowForId(_ id: String, tasks: [TaskItem], blocks: [CalBlock], todayISO: String) -> TaskItem? {
    guard !id.isEmpty else { return nil }
    // A block id: the occurrence row for a recurring template, else its task.
    if let block = blocks.first(where: { $0.id == id && isTaskBlock($0) }) {
        return taskForBlock(block, tasks: tasks)
    }
    guard let task = tasks.first(where: { $0.id == id }) else { return nil }
    guard task.recurrence != nil else { return task }
    // A template: pick the day's occurrence so the session carries the block.
    let mine = blocks
        .filter { isTaskBlock($0) && $0.taskId == task.id && !$0.skipped }
        .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
    let live = mine.first { $0.date == todayISO && !$0.done }
        ?? mine.first { $0.date > todayISO && !$0.done }
        ?? mine.first { $0.date == todayISO }
    guard let live else { return task }
    return taskForBlock(live, tasks: tasks) ?? task
}

/// The row a TASK deep link (`unstuck://task/<id>`) must open (audit
/// 2026-09-22, C3). Reminders (local and server-pushed), the "Rescheduled"
/// confirmation, Inbox "Open" on a capture filed on a series and the bell's
/// logged reminder rows all carry the block's `taskId` — the hidden TEMPLATE
/// for a series. Opening the template offered "Mark done" on the series
/// itself, so "I took my meds" from a reminder tap ended the whole series and
/// every reminder after it. A series opens through an OCCURRENCE row, as in
/// `focusRowForId`, but chosen for a reminder tapped late:
///  • today's occurrence, open or already ticked — a stale reminder tapped
///    after the day was ticked shows today ticked, never tomorrow's row (whose
///    Mark done would tick the wrong day);
///  • else the most recent past occurrence while it is still open — the row
///    Backlog shows as overdue (`projectOverdueOccurrences`), so last
///    Friday's reminder tapped on Saturday opens Friday;
///  • else the earliest open future occurrence;
///  • else the template itself (it has no occurrence to open).
/// A block id opens that exact day's row, a plain task id its task, and an
/// unknown id nil (the caller treats it as shared with me).
public func taskLinkRowForId(_ id: String, tasks: [TaskItem], blocks: [CalBlock], todayISO: String) -> TaskItem? {
    guard let task = tasks.first(where: { $0.id == id }), task.recurrence != nil else {
        return focusRowForId(id, tasks: tasks, blocks: blocks, todayISO: todayISO)
    }
    let mine = blocks
        .filter { isTaskBlock($0) && $0.taskId == task.id }
        .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
    let latestPast = mine.last { $0.date < todayISO }
    let pick = mine.first { $0.date == todayISO && !$0.skipped && !$0.done }
        ?? mine.first { $0.date == todayISO && !$0.skipped }
        ?? latestPast.flatMap { $0.done || $0.skipped ? nil : $0 }
        ?? mine.first { $0.date > todayISO && !$0.skipped && !$0.done }
    guard let pick else { return task }
    return taskForBlock(pick, tasks: tasks) ?? task
}

/// Is this calendar slot done? Port of web `blockIsDone` (lib/occurrences.ts).
/// A repeating task's day is done on its OWN block — the template's flag never
/// counts (ticking Tuesday must not strike Wednesday, and a series the old
/// path ended must not strike every day it still has); a one-off's slot is
/// done when the TASK is — a stale `done` left on its block (a ticked day
/// whose series was turned off, then reopened) never strikes it. No task →
/// not done. The Day / Week grids, the Month peek and the Edit-block sheet
/// all read this, so the block the sheet just ticked or reopened shows it.
public func blockIsDone(_ block: CalBlock, task: TaskItem?) -> Bool {
    guard let task else { return false }
    return task.recurrence != nil ? block.done : task.done
}

/// The row to open when a calendar block is tapped: the per-day OCCURRENCE
/// (id = block id) when the block belongs to a recurring template, else the
/// normal task. Lets the detail screen treat it as an occurrence.
public func taskForBlock(_ block: CalBlock, tasks: [TaskItem]) -> TaskItem? {
    guard let t = tasks.first(where: { $0.id == block.taskId }) else { return nil }
    guard t.recurrence != nil else { return t }
    var occ = t
    occ.id = block.id
    occ.recurrence = nil
    occ.done = block.done
    occ.completedAt = block.completedAt
    occ.estimateMin = block.durationMinutes
    return occ
}
