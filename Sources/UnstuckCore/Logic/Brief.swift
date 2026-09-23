// The deterministic brief for the AI gateway card — zero-LLM, so it renders
// instantly and never hallucinates. Register: a calm PA's one-two sentences.
// NO greeting prefix — the Today header already greets, and "Morning, Ahmad.
// Morning!" is the opposite of calm. Port of lib/assistant/brief.ts.
//
//   "Three things scheduled today — 'Write the project update' at 11:00 is
//    the anchor. About 90 usable minutes before it."
//   "Nothing on the calendar today — 7 open tasks if you want to pull one in."
//   "A clear day. Add what's on your mind below."
//
// The ANCHOR is the day's centre of gravity: the first live block still ahead
// of now, or — once everything timed is behind us — the day's first block.

import Foundation

// British short months — September abbreviates to "Sept", not "Sep".
let MONTH_SHORT_GB = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]

// Small counts read as words ("Three things"), larger ones as digits.
private let COUNT_WORDS = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
func countWord(_ n: Int) -> String { n >= 0 && n < COUNT_WORDS.count ? COUNT_WORDS[n] : String(n) }

/// JS `Math.round`: halves round toward +∞ (−2.5 → −2), unlike Swift's schoolbook rounding.
func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

extension Array {
    /// A guaranteed-stable sort (the web relies on V8's stable `Array.sort`;
    /// Swift's `sort` is not documented as stable — see handover conventions).
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map { $0.element }
    }
}

/// Today's live blocks (not done, not skipped) in start-time order — untimed
/// blocks sort first, like the calendar's any-time lane. Shared by the brief
/// and the first-touch moment.
func liveBlocksToday(_ blocks: [CalBlock], todayIso: String) -> [CalBlock] {
    blocks.filter { $0.date == todayIso && !$0.done && !$0.skipped }
        .stableSorted { $0.startTime < $1.startTime }
}

/// The brief's anchor: first live timed block at-or-after `nowHm`, else the day's first block.
func anchorBlock(_ todayBlocks: [CalBlock], nowHm: String) -> CalBlock? {
    todayBlocks.first { !$0.startTime.trimmingCharacters(in: .whitespaces).isEmpty && $0.startTime >= nowHm }
        ?? todayBlocks.first
}

public func composeBrief(tasks: [TaskItem], blocks: [CalBlock], todayIso: String, now: Date, usableMinutes: Int? = nil) -> String {
    // Live = not done, not skipped (a cancelled occurrence isn't "scheduled
    // today" any more — same convention as suggestions.ts). Untimed blocks
    // sort first, like the calendar's any-time lane.
    let todayBlocks = liveBlocksToday(blocks, todayIso: todayIso)

    if todayBlocks.isEmpty {
        // Open working set = not done, not a recurring template (occurrences
        // live on the calendar as blocks) — mirrors suggestions.ts.
        let open = tasks.filter { !$0.done && $0.recurrence == nil }.count
        return open > 0
            ? "Nothing on the calendar today — \(open) open \(open == 1 ? "task" : "tasks") if you want to pull one in."
            : "A clear day. Add what’s on your mind below."
    }

    let nowHm = localNowHM(now)
    let anchor = anchorBlock(todayBlocks, nowHm: nowHm)!
    // Prefer the task's current name (blocks denormalize it and can go stale).
    let anchorName = tasks.first { $0.id == anchor.taskId }?.name ?? anchor.taskName
    let trimmed = anchor.startTime.trimmingCharacters(in: .whitespaces)
    let anchorTime: String? = trimmed.isEmpty ? nil : trimmed

    let n = todayBlocks.count
    let head = "\(countWord(n)) \(n == 1 ? "thing" : "things") scheduled today — ‘\(anchorName)’\(anchorTime.map { " at \($0)" } ?? "") is the anchor."

    // The runway sentence only earns its place when it's real: a meaningful
    // stretch (≥15 min) before an anchor that is genuinely still ahead.
    if let usable = usableMinutes, usable >= 15, let anchorTime, anchorTime > nowHm {
        let rounded = jsRound(Double(usable) / 5) * 5
        return "\(head) About \(rounded) usable minutes before it."
    }
    return head
}

/// The gentle probe for a pattern gap:
/// "You usually do 'Gym' on Wednesdays — still on for Wednesday 2 Sept?"
/// Date parsed locally (never a UTC-midnight ISO parse, which reads back as
/// the previous day west of Greenwich).
public func probeQuestion(_ gap: Gap) -> String {
    let due = LocalDate.parse(gap.dueDate)
    let dueDow = Time.dayOfWeekJS(due)
    let month = Time.calendar.component(.month, from: due) - 1
    return "You usually do ‘\(gap.taskName)’ on \(DAY_NAMES_FULL[gap.dow])s — still on for \(DAY_NAMES_FULL[dueDow]) \(Time.dayOfMonth(due)) \(MONTH_SHORT_GB[month])?"
}
