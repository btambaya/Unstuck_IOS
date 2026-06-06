// Recurrence — materialise + regenerate cal_blocks for repeating tasks.
// Pure functions, no I/O. Port of lib/recurrence.ts. Callers pipe the
// returned diff through the sync layer.
//
// Model: a task has at most one `recurrence`. When set, the client
// materialises cal_blocks for RECURRENCE_HORIZON_DAYS into the future at
// the same start time. Past occurrences are preserved; future ones are
// regenerated on edit.

import Foundation

/// How far ahead we materialise occurrences on create/edit (8 weeks).
public let RECURRENCE_HORIZON_DAYS = 56

public struct MaterializedOccurrence: Equatable, Sendable {
    public let date: String        // YYYY-MM-DD
    public let startTime: String   // HH:MM
    public init(date: String, startTime: String) {
        self.date = date
        self.startTime = startTime
    }
}

public extension Recurrence {
    /// The inclusive `until` bound (YYYY-MM-DD), regardless of kind.
    var untilDate: String? {
        switch self {
        case .daily(let u), .monthly(let u): return u
        case .weekly(_, let u): return u
        }
    }
}

private func matchesRecurrence(_ r: Recurrence, startDate: Date, candidate: Date) -> Bool {
    if Time.startOfDay(candidate) < Time.startOfDay(startDate) { return false }
    switch r {
    case .daily:
        return true
    case .weekly(let days, _):
        return days.contains(Time.dayOfWeekJS(candidate))
    case .monthly:
        // Clamp a day-31 start to each month's last day (Feb 28/29, Apr 30, …),
        // recovering to 31 in long months — matches current Android (the v0.4.23 fix).
        return Time.dayOfMonth(candidate) == min(Time.dayOfMonth(startDate), Time.daysInMonth(candidate))
    }
}

/// Date/time pairs for a recurrence starting at `startDate`/`startTime`,
/// going `horizonDays` ahead (inclusive of startDate). Stops at
/// `recurrence.until` (inclusive) when set.
public func materializeOccurrences(
    _ recurrence: Recurrence,
    startDate: Date,
    startTime: String,
    horizonDays: Int = RECURRENCE_HORIZON_DAYS
) -> [MaterializedOccurrence] {
    var out: [MaterializedOccurrence] = []
    let untilIso = recurrence.untilDate
    for i in 0..<horizonDays {
        let day = Time.addDays(startDate, i)
        let iso = Clock.dateISO(day)
        if let untilIso, iso > untilIso { break }
        if matchesRecurrence(recurrence, startDate: startDate, candidate: day) {
            out.append(MaterializedOccurrence(date: iso, startTime: startTime))
        }
    }
    return out
}

/// The diff needed to align a task's existing cal_blocks with
/// `recurrence`: keep past occurrences, delete mismatched future ones,
/// add missing ones. `todayIso` is injected so the boundary is testable.
public struct RegenPlan: Equatable, Sendable {
    public var toUpsert: [CalBlock]
    public var toDelete: [String]   // cal_block ids
    public init(toUpsert: [CalBlock], toDelete: [String]) {
        self.toUpsert = toUpsert
        self.toDelete = toDelete
    }
}

public func regenerateForTask(
    task: TaskItem,
    recurrence: Recurrence?,
    existingBlocks: [CalBlock],
    todayIso: String,
    startTime: String,
    startDate: Date,
    horizonDays: Int = RECURRENCE_HORIZON_DAYS
) -> RegenPlan {
    let existing = existingBlocks.filter { $0.taskId == task.id && isTaskBlock($0) }
    let futureExisting = existing.filter { $0.date > todayIso }

    guard let recurrence else {
        // Clearing recurrence — delete every future occurrence, keep history.
        return RegenPlan(toUpsert: [], toDelete: futureExisting.map(\.id))
    }

    let desired = materializeOccurrences(recurrence, startDate: startDate, startTime: startTime, horizonDays: horizonDays)
        .filter { $0.date > todayIso }
    let desiredKeys = Set(desired.map { "\($0.date)|\($0.startTime)" })
    let existingFutureKeys = Set(futureExisting.map { "\($0.date)|\($0.startTime)" })

    var toDelete: [String] = []
    for b in futureExisting where !desiredKeys.contains("\(b.date)|\(b.startTime)") {
        toDelete.append(b.id)
    }

    var toUpsert: [CalBlock] = []
    for o in desired where !existingFutureKeys.contains("\(o.date)|\(o.startTime)") {
        toUpsert.append(CalBlock(
            id: newUUID(), taskId: task.id, taskName: task.name,
            startTime: o.startTime, durationMinutes: task.estimateMin,
            date: o.date, kind: .task))
    }

    return RegenPlan(toUpsert: toUpsert, toDelete: toDelete)
}

private let DOW_LABELS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private func formatDays(_ days: [Int]) -> String {
    let sorted = Array(Set(days)).sorted()
    if sorted.count == 5 && [1, 2, 3, 4, 5].allSatisfy(sorted.contains) { return "weekdays" }
    if sorted.count == 2 && sorted.contains(0) && sorted.contains(6) { return "weekends" }
    return sorted.compactMap { (0..<DOW_LABELS.count).contains($0) ? DOW_LABELS[$0] : nil }.joined(separator: "/")
}

/// Short human label for the detail pane / row chips.
public func recurrenceLabel(_ r: Recurrence?) -> String {
    guard let r else { return "" }
    let base: String
    switch r {
    case .daily:
        base = "Repeats daily"
    case .weekly(let days, _):
        base = days.count == 7 ? "Repeats daily" : "Repeats \(formatDays(days))"
    case .monthly:
        base = "Repeats monthly"
    }
    if let until = r.untilDate {
        let parts = until.split(separator: "-").map { Int($0) }
        if parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] {
            let date = Time.civil(y, m, d)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US")
            df.dateFormat = "MMM d, yyyy"
            return "\(base) until \(df.string(from: date))"
        }
    }
    return base
}
