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
