// Where a shared task shows up — the same rules the user's OWN tasks follow
// (VisibleTasks / TaskBucket), placed by the OWNER's next live block (migration
// 052 `next_*` projection):
//   • Today     — open, and scheduled today OR not scheduled at all.
//   • Upcoming  — open, scheduled on a future day.
//   • Backlog   — open, only ever scheduled in the past (overdue).
//   • All       — everything open, plus today's completions lingering (struck,
//                 last) until tomorrow — mirroring isCompletedToday().
//   • Completed — done, however old.
// The active life-area filter narrows every mode like it does for Delegated.
// Applies whoever ticked it — owner or an assign/partner recipient (Ahmad,
// 2026-08-02: completed shared tasks should move to Completed "for all, like
// all other tasks").
//
// Port of lib/shared-task-visibility.ts (+ its .test.ts), extended with the
// schedule-aware modes. Pure; `completedAt` + every `next*` field is optional
// so the client behaves correctly against an RPC that hasn't been migrated
// yet (049 / 052) — without a timestamp a completed share simply leaves the
// active lists, and without a schedule an open share sits in Today.

import Foundation

/// Which list a shared row is being rendered inside.
public enum ShareViewMode: String, Sendable, Equatable, CaseIterable {
    case today
    case upcoming
    case backlog
    case all
    case completed

    /// The task-list view a shared group is mounted in → its share mode.
    /// Today / Upcoming / Backlog / All / Completed mount the group (the
    /// date-aware placement makes every bucket meaningful); Later / Recurring
    /// don't, and degrade to `.all` (never to a mode that hides open shares).
    public init(_ view: TaskListView) {
        switch view {
        case .completed: self = .completed
        case .today: self = .today
        case .upcoming: self = .upcoming
        case .backlog: self = .backlog
        default: self = .all
        }
    }
}

/// The fields the visibility rule reads. `SharedWithMe` conforms; tests (and
/// any future projection) can supply their own row. The schedule fields have
/// nil defaults so a minimal row (done + completedAt) still conforms.
public protocol ShareVisibilityItem {
    var done: Bool { get }
    /// ISO completion time, when the projection provides one.
    var completedAt: String? { get }
    /// 'YYYY-MM-DD' of the owner's next block, when the projection provides one.
    var nextDate: String? { get }
    /// Whether that next block is itself done (only ever true for a past block).
    var nextDone: Bool? { get }
    /// The owner's life area, for the active-area filter.
    var lifeArea: String? { get }
}

public extension ShareVisibilityItem {
    var nextDate: String? { nil }
    var nextDone: Bool? { nil }
    var lifeArea: String? { nil }
}

extension SharedWithMe: ShareVisibilityItem {}

/// The date a shared task is PLACED on, from the owner's next block: the block
/// date, unless that block is a finished PAST one — the server only falls back
/// to a past block when no live block exists, and a finished past block means
/// nothing is scheduled (it is not "overdue"). nil ⇒ unscheduled.
public func sharedPlacementDate(nextDate: String?, nextDone: Bool?) -> String? {
    guard let nextDate, !nextDate.isEmpty else { return nil }
    if nextDone == true { return nil }
    return nextDate
}

/// True when a shared row with this state belongs in the given view.
/// `todayISO` is the local 'YYYY-MM-DD' (the block dates compare
/// lexicographically, like the web / VisibleTasks).
public func shareVisibleIn(done: Bool, completedAt: String?, nextDate: String? = nil, nextDone: Bool? = nil,
                           mode: ShareViewMode, now: EpochMillis, todayISO: String = Clock.todayISO()) -> Bool {
    if mode == .completed { return done }
    if !done {
        let placed = sharedPlacementDate(nextDate: nextDate, nextDone: nextDone)
        switch mode {
        case .today: return placed == nil || placed == todayISO
        case .upcoming: return placed.map { $0 > todayISO } ?? false
        case .backlog: return placed.map { $0 < todayISO } ?? false
        case .all, .completed: return true
        }
    }
    // Completed rows: only "finished today" lingers, and only in All —
    // mirroring isCompletedToday() for the user's own tasks. A missing or
    // unparseable timestamp means it simply leaves the active lists.
    guard mode == .all else { return false }
    guard let completedAt, let t = Time.parseMillis(completedAt) else { return false }
    let start = Time.startOfDayMillis(now)
    return t >= start && t < start + DAY_MS
}

/// True when this shared row belongs in the given view (+ passes the active
/// life-area filter, when one is set — `matchesArea` semantics, so the
/// "Unassigned" sentinel works and a nil filter admits everything).
public func shareVisibleIn<T: ShareVisibilityItem>(_ item: T, _ mode: ShareViewMode, now: EpochMillis,
                                                   todayISO: String = Clock.todayISO(),
                                                   activeArea: String? = nil) -> Bool {
    guard matchesArea(item.lifeArea, activeArea) else { return false }
    return shareVisibleIn(done: item.done, completedAt: item.completedAt,
                          nextDate: item.nextDate, nextDone: item.nextDone,
                          mode: mode, now: now, todayISO: todayISO)
}

/// Filter + order a shared list for a view: open first, completed last (never
/// park struck-through rows above the next thing to do). The web relies on a
/// STABLE sort here; Swift's sort is not guaranteed stable, so partition by
/// hand to match exactly (same shape as `visibleTasks`).
public func visibleShares<T: ShareVisibilityItem>(
    _ items: [T],
    mode: ShareViewMode,
    now: EpochMillis = Date().timeIntervalSince1970 * 1000,
    todayISO: String = Clock.todayISO(),
    activeArea: String? = nil
) -> [T] {
    let kept = items.filter { shareVisibleIn($0, mode, now: now, todayISO: todayISO, activeArea: activeArea) }
    return kept.filter { !$0.done } + kept.filter { $0.done }
}

// MARK: - Slot labels (the schedule, in words)

/// Short day label for a block date relative to today: "Today", "Tomorrow",
/// the weekday ("Sat") inside the coming week, else "Sat 12 Sep". A PAST date
/// reads "Overdue · Fri" — the same wording the Backlog uses for a missed
/// recurring occurrence. "" for an unparseable date.
public func sharedDayLabel(_ iso: String, todayISO: String) -> String {
    let parts = iso.split(separator: "-").map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return "" }
    if iso == todayISO { return "Today" }
    let day = Time.civil(y, m, d)
    if iso < todayISO { return "Overdue · \(Time.weekdayShort(iso))" }
    let tp = todayISO.split(separator: "-").map { Int($0) }
    if tp.count == 3, let ty = tp[0], let tm = tp[1], let td = tp[2] {
        let diff = Time.wholeDaysBetween(day, Time.civil(ty, tm, td))
        if diff == 1 { return "Tomorrow" }
        if diff >= 0 && diff <= 6 { return Time.weekdayShort(iso) }
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEE d MMM"
    return f.string(from: day)
}

/// The slot line on a "shared with you" row — "Sat 04:30 · 45m" — from the
/// owner's next block. nil when nothing is placed (no block, or only a
/// finished past one), so the row falls back to just "from <owner>".
public func sharedSlotLabel(nextDate: String?, nextStartTime: String?, nextDurationMinutes: Int?,
                            nextDone: Bool? = nil, todayISO: String = Clock.todayISO()) -> String? {
    guard let date = sharedPlacementDate(nextDate: nextDate, nextDone: nextDone) else { return nil }
    var out = sharedDayLabel(date, todayISO: todayISO)
    if let t = nextStartTime, !t.isEmpty { out += " \(t)" }
    if let m = nextDurationMinutes, m > 0 { out += " · \(m)m" }
    return out
}

/// The "Planned …" line in the shared-task detail — "Planned Sat, Sep 12 ·
/// 04:30 · 45m" — from the `next_*` projection. Unlike the row slot, a
/// finished past block still reads (it says when the task WAS): "Done Fri,
/// Sep 4 · 09:00 · 45m". nil when the task has never been scheduled.
public func sharedPlannedLabel(nextDate: String?, nextStartTime: String?, nextDurationMinutes: Int?,
                               nextDone: Bool?) -> String? {
    guard let nextDate, !nextDate.isEmpty else { return nil }
    let parts = nextDate.split(separator: "-").map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEE, MMM d"
    var out = "\(nextDone == true ? "Done" : "Planned") \(f.string(from: Time.civil(y, m, d)))"
    if let t = nextStartTime, !t.isEmpty { out += " · \(t)" }
    if let mins = nextDurationMinutes, mins > 0 { out += " · \(mins)m" }
    return out
}
