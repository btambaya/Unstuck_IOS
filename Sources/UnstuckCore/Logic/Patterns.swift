// Schedule-pattern detection for the AI gateway — pure logic, zero-LLM.
// A "pattern" is a habit the calendar reveals: the same task scheduled on the
// same weekday in at least three distinct weeks of recent history. A "gap" is
// a pattern whose next occurrence has nothing on the calendar yet — the thing
// a good PA would gently ask about ("still on for Wednesday?").
//
// Port of lib/assistant/patterns.ts. All date math is LOCAL-timezone safe:
// 'YYYY-MM-DD' strings go through `LocalDate` (parse field-by-field, format
// field-by-field, DST-safe day arithmetic) — never an ISO-8601 UTC round-trip.

import Foundation

public struct Pattern: Equatable, Sendable {
    public var taskId: String
    public var taskName: String
    /// Weekday of the habit, 0=Sun … 6=Sat (JS `getDay` convention).
    public var dow: Int
    /// Most common startTime among the occurrences; nil if none carried one.
    public var time: String?
    /// Distinct history weeks the habit appeared in.
    public var weeksSeen: Int
    /// e.g. "Gym most Wednesdays at 07:00 (4 of the last 4 weeks)".
    public var label: String

    public init(taskId: String, taskName: String, dow: Int, time: String? = nil, weeksSeen: Int, label: String) {
        self.taskId = taskId
        self.taskName = taskName
        self.dow = dow
        self.time = time
        self.weeksSeen = weeksSeen
        self.label = label
    }
}

/// A `Pattern` plus the next uncovered occurrence date ('YYYY-MM-DD', today or later).
public struct Gap: Equatable, Sendable {
    public var taskId: String
    public var taskName: String
    public var dow: Int
    public var time: String?
    public var weeksSeen: Int
    public var label: String
    public var dueDate: String

    public init(taskId: String, taskName: String, dow: Int, time: String? = nil, weeksSeen: Int, label: String, dueDate: String) {
        self.taskId = taskId
        self.taskName = taskName
        self.dow = dow
        self.time = time
        self.weeksSeen = weeksSeen
        self.label = label
        self.dueDate = dueDate
    }

    public init(_ p: Pattern, dueDate: String) {
        self.init(taskId: p.taskId, taskName: p.taskName, dow: p.dow, time: p.time,
                  weeksSeen: p.weeksSeen, label: p.label, dueDate: dueDate)
    }
}

let DAY_NAMES_FULL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

/// Monday of the week containing `base` (local midnight).
func weekStartDate(_ base: Date) -> Date {
    Time.addDays(base, -((Time.dayOfWeekJS(base) + 6) % 7))
}

/// Same task, same weekday, in ≥3 distinct weeks of recent HISTORY — blocks
/// dated before the Monday of the current week and no older than 35 days
/// before today. The current week never counts: a habit is something the past
/// shows, not something this week's plan asserts. Done occurrences DO count
/// (they're evidence the habit happened); blocks without a resolvable task
/// are ignored.
public func derivePatterns(_ tasks: [TaskItem], _ blocks: [CalBlock], todayIso: String) -> [Pattern] {
    let today = LocalDate.parse(todayIso)
    let historyEnd = weekStartDate(today)          // exclusive — current week is not history
    let historyStart = Time.addDays(today, -35)    // inclusive — ~5 weeks back

    let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    struct Bucket {
        var taskId: String
        var taskName: String
        var dow: Int
        var weeks: Set<String>
        /// startTime → occurrence count, insertion-ordered (first seen wins ties).
        var timeOrder: [String]
        var timeCounts: [String: Int]
    }
    var buckets: [String: Bucket] = [:]
    var order: [String] = []   // JS Map iteration order = insertion order

    for b in blocks {
        guard let tid = b.taskId, !tid.isEmpty, let task = taskById[tid] else { continue }
        // An every-N-weeks series is not a weekly habit by definition: a
        // fortnightly Sunday showed 3 distinct weeks in the 5-week window, so
        // its off-week Sunday raised "still on for Sunday?" (every-n-weeks
        // spec §8.2).
        if case .everyNWeeks? = task.recurrence { continue }
        let d = LocalDate.parse(b.date)
        if d >= historyEnd || d < historyStart { continue }   // history only
        let dow = Time.dayOfWeekJS(d)
        let key = "\(tid)|\(dow)"
        if buckets[key] == nil {
            buckets[key] = Bucket(taskId: tid, taskName: task.name, dow: dow, weeks: [], timeOrder: [], timeCounts: [:])
            order.append(key)
        }
        buckets[key]!.weeks.insert(LocalDate.format(weekStartDate(d)))
        let time = b.startTime.trimmingCharacters(in: .whitespaces)
        if !time.isEmpty {
            if buckets[key]!.timeCounts[time] == nil { buckets[key]!.timeOrder.append(time) }
            buckets[key]!.timeCounts[time, default: 0] += 1
        }
    }

    var patterns: [Pattern] = []
    for key in order {
        let e = buckets[key]!
        if e.weeks.count < 3 { continue }
        var time: String?
        var best = 0
        for t in e.timeOrder {
            let n = e.timeCounts[t] ?? 0
            if n > best { best = n; time = t }
        }
        let weeksSeen = e.weeks.count
        // The window reads "the last 4 weeks" like the reference, but never
        // understates: a 5-distinct-week habit says "5 of the last 5".
        let window = max(4, weeksSeen)
        let at = time.map { " at \($0)" } ?? ""
        patterns.append(Pattern(
            taskId: e.taskId, taskName: e.taskName, dow: e.dow, time: time, weeksSeen: weeksSeen,
            label: "\(e.taskName) most \(DAY_NAMES_FULL[e.dow])s\(at) (\(weeksSeen) of the last \(window) weeks)"))
    }
    return patterns
}

/// Patterns whose NEXT occurrence has nothing scheduled. The next occurrence
/// is the pattern's weekday this week if that's today or later, else the same
/// weekday next week — a PA asked on Saturday about a Wednesday habit
/// naturally means next Wednesday. A non-done block for the task on that
/// exact date counts as covered and suppresses the gap.
public func patternGaps(_ patterns: [Pattern], _ blocks: [CalBlock], todayIso: String) -> [Gap] {
    let today = LocalDate.parse(todayIso)
    let start = weekStartDate(today)
    var gaps: [Gap] = []
    for p in patterns {
        var due = Time.addDays(start, (p.dow + 6) % 7)   // Sunday-based dow → Monday-based offset
        if due < today { due = Time.addDays(due, 7) }     // already passed this week → roll forward
        let dueDate = LocalDate.format(due)
        let covered = blocks.contains { $0.taskId == p.taskId && $0.date == dueDate && !$0.done }
        if !covered { gaps.append(Gap(p, dueDate: dueDate)) }
    }
    return gaps
}
