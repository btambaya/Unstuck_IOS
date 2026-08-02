// Dynamic assistant suggestions — every chip derives from the user's ACTUAL
// data (real task names, real list names) and only appears when applicable.
// Port of lib/assistant/suggestions.ts, 1:1 including the copy: the panel's
// chips must read the same on web and iOS.
//
// Chip taps send `message` through the normal guardrailed agent path — no
// special-cased local execution, no new server surface. Anything the agent
// changes comes back as an undoable receipt.

import Foundation

public struct AssistantSuggestion: Equatable, Sendable, Identifiable {
    /// Chip label (short, may truncate the entity name).
    public let label: String
    /// The message actually sent to the agent on tap.
    public let message: String

    public var id: String { label }

    public init(label: String, message: String) {
        self.label = label
        self.message = message
    }
}

public struct SuggestionGroups: Equatable, Sendable {
    public var gettingStarted: [AssistantSuggestion]
    /// Plan/schedule work without typing — the "do it for me" group.
    public var planAndSchedule: [AssistantSuggestion]
    /// Sharpen what's already there (first steps, breakdowns, tidying).
    public var refine: [AssistantSuggestion]

    public init(gettingStarted: [AssistantSuggestion] = [],
                planAndSchedule: [AssistantSuggestion] = [],
                refine: [AssistantSuggestion] = []) {
        self.gettingStarted = gettingStarted
        self.planAndSchedule = planAndSchedule
        self.refine = refine
    }

    /// True when there is nothing to offer at all (a brand-new account).
    public var isEmpty: Bool {
        gettingStarted.isEmpty && planAndSchedule.isEmpty && refine.isEmpty
    }
}

/// `s.length <= max ? s : s.slice(0, max - 1).trimEnd() + '…'` — the web helper,
/// counting Characters (grapheme clusters) so an emoji/accent can't split.
func shortenSuggestion(_ s: String, max: Int = 24) -> String {
    guard s.count > max else { return s }
    let head = String(s.prefix(max - 1))
    // trimEnd(): JS trims trailing whitespace only (never the leading side).
    var trimmed = head
    while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
    return trimmed + "…"
}

/// Saturday/Sunday dates (YYYY-MM-DD) for the coming weekend, from today.
/// A Saturday resolves to TODAY + tomorrow; every other day walks forward to
/// the next Saturday (JS `(6 - day + 7) % 7`, which is 0 only on Saturday).
func nextWeekend(_ todayIso: String) -> (sat: String, sun: String) {
    let parts = todayIso.split(separator: "-").map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else {
        return (todayIso, todayIso)
    }
    let base = Time.civil(y, m, d)
    // JS getDay(): 0 = Sunday … 6 = Saturday — `(6 - day + 7) % 7` is 0 only on
    // a Saturday, so today's weekend is offered rather than next week's.
    let delta = (6 - Time.dayOfWeekJS(base) + 7) % 7
    let sat = Time.addDays(base, delta)
    let sun = Time.addDays(sat, 1)
    return (Clock.dateISO(sat), Clock.dateISO(sun))
}

/// Open, non-deferred, non-template tasks — the assistant's working set.
private func openTasks(_ tasks: [TaskItem]) -> [TaskItem] {
    tasks.filter { !$0.done && $0.recurrence == nil }
}

public func buildSuggestions(
    tasks: [TaskItem],
    blocks: [CalBlock],
    collections: [ItemCollection],
    todayIso: String
) -> SuggestionGroups {
    let open = openTasks(tasks)
    var gettingStarted: [AssistantSuggestion] = []
    var planAndSchedule: [AssistantSuggestion] = []
    var refine: [AssistantSuggestion] = []

    let liveBlocks = blocks.filter { !$0.done && !$0.skipped }
    let todayBlocks = liveBlocks.filter { $0.date == todayIso }
    let scheduledIds = Set(liveBlocks.filter { $0.date >= todayIso }.compactMap(\.taskId))
    let unscheduled = open.filter { !($0.later ?? false) && !scheduledIds.contains($0.id) }
    let laterPile = open.filter { $0.later ?? false }
    let noFirstStep = open.filter {
        !($0.later ?? false)
            && ($0.firstPhysicalAction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // ---- Getting started -------------------------------------------------
    if !open.isEmpty {
        gettingStarted.append(.init(label: "What should I work on next?",
                                    message: "What should I work on next?"))
    }
    if todayBlocks.count >= 3 || open.count >= 6 {
        gettingStarted.append(.init(label: "I’m overwhelmed", message: "I’m overwhelmed."))
    }
    if !todayBlocks.isEmpty {
        gettingStarted.append(.init(label: "What’s realistic today?",
                                    message: "What’s realistic for me today?"))
    }

    // ---- Plan & schedule (tap → the agent actually schedules) -------------
    if let first = unscheduled.first {
        planAndSchedule.append(.init(
            label: unscheduled.count == 1
                ? "Find time for “\(shortenSuggestion(first.name, max: 18))”"
                : "Schedule my \(unscheduled.count) unscheduled tasks",
            message: unscheduled.count == 1
                ? "Find a realistic slot for \"\(first.name)\" in the next few days and schedule it."
                : "I have \(unscheduled.count) unscheduled tasks. Spread them across realistic slots over the next few days and schedule them — keep my existing blocks and don't overload any one day."))
    }
    if !todayBlocks.isEmpty {
        planAndSchedule.append(.init(
            label: "Move today’s leftovers to tomorrow",
            message: "Anything still unfinished on today’s plan — reschedule it to sensible times tomorrow."))
    }
    // Weekend planning: only when the light/personal stuff exists to move.
    let weekendable = open.filter {
        !($0.later ?? false) && $0.estimateMin <= 45
            && ($0.lifeArea == "Home" || $0.lifeArea == "Personal" || $0.lifeArea == "Health")
    }
    if weekendable.count >= 2 {
        let (sat, sun) = nextWeekend(todayIso)
        planAndSchedule.append(.init(
            label: "Plan a quiet weekend",
            message: "Schedule my lighter personal and home tasks across \(sat) and \(sun), spaced out with breathing room — nothing before 10am, and leave the rest of the weekend free."))
    }
    if todayBlocks.isEmpty && !open.isEmpty {
        planAndSchedule.append(.init(
            label: "Block out my day",
            message: "Build me a realistic plan for today from my open tasks and schedule the blocks."))
    }

    // ---- Refine (sharpen what exists) ------------------------------------
    let chunky = noFirstStep
        .filter { $0.estimateMin >= 45 }
        .sorted { $0.estimateMin > $1.estimateMin }
        .first
    if let chunky {
        refine.append(.init(
            label: "Break down “\(shortenSuggestion(chunky.name))”",
            message: "Break down \"\(chunky.name)\" — give it a first physical action and split it into steps."))
    }
    if noFirstStep.count >= 2 {
        refine.append(.init(
            label: "Add first steps to \(noFirstStep.count) tasks",
            message: "\(noFirstStep.count) of my tasks have no first physical action. Give each one a concrete, physical first step — something I could literally start in the next minute."))
    }
    if laterPile.count >= 2 {
        refine.append(.init(
            label: "Tidy my Later pile (\(laterPile.count))",
            message: "I have \(laterPile.count) tasks parked in Later. Look through them and tell me which are actually worth bringing back this week — then bring those back."))
    }
    let openIds = Set(open.map(\.id))
    let slipped = open.contains { ($0.moveCount ?? 0) >= 2 }
        || blocks.contains { b in
            b.date < todayIso && !b.done && !b.skipped
                && (b.taskId.map { openIds.contains($0) } ?? false)
        }
    if slipped {
        refine.append(.init(label: "What keeps slipping?",
                            message: "What keeps slipping, and what should I do about it?"))
    }

    // Lists: keep the classic add-to-groceries affordance.
    let lists = collections.filter { !($0.archived ?? false) }
    let groceries = lists.first { $0.name.range(of: "grocer|shopping", options: [.regularExpression, .caseInsensitive]) != nil }
    if let groceries {
        refine.append(.init(
            label: "Add to \(shortenSuggestion(groceries.name, max: 16))",
            message: "Add an item to my \"\(groceries.name)\" list — ask me what to add."))
    } else if let first = lists.first {
        refine.append(.init(
            label: "Add to “\(shortenSuggestion(first.name, max: 16))”",
            message: "I want to add an item to my \"\(first.name)\" list."))
    }

    return SuggestionGroups(gettingStarted: gettingStarted,
                            planAndSchedule: planAndSchedule,
                            refine: refine)
}
