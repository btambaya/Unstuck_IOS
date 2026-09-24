// Where a shared task shows up — the same rules the user's OWN tasks follow
// (VisibleTasks / TaskBucket), placed by the OWNER's next live block (migration
// 052 `next_*` projection, migration 053 `next_start_at` / `later`):
//   • Today     — open, and scheduled today OR not scheduled at all.
//   • Upcoming  — open, scheduled on a future day.
//   • Backlog   — open, only ever scheduled in the past (overdue).
//   • All       — everything open, plus today's completions lingering (struck,
//                 last) until tomorrow — mirroring isCompletedToday().
//   • Completed — done, however old.
// Two own-task rules ride along (the CROSS-PLATFORM contract — web, Android
// and iOS bucket identically):
//   • a share whose latest block is a FINISHED past one (next_done) is
//     "done-ish": nothing is scheduled, but it isn't current work either —
//     it shows under All only, never Today / Backlog;
//   • a `later` (parked) task leaves Today + Backlog exactly like the owner's
//     own Later bucket does; a future block still puts it in Upcoming.
// The active life-area filter narrows every mode the way the web's
// `shareMatchesArea` does: an AREA-LESS share always shows (the owner's
// vocabulary isn't ours — hiding it would make the share vanish for no
// visible reason); the "Unassigned" sentinel narrows to exactly those.
// Open rows are ordered chronologically by the owner's slot (unscheduled
// last — `compareShareSlot`), completed rows after them.
//
// RECIPIENT-LOCAL DATES: since 053 the projection also carries
// `next_start_at`, the owner's local date+time as an INSTANT. Bucketing and
// the slot label use that instant converted to the RECIPIENT's zone when it is
// present, and fall back to the owner's `next_date` / `next_start_time` text
// against an older server.
//
// Port of lib/shared-task-visibility.ts + lib/shared-blocks.ts (and their
// tests). Pure; every schedule field is optional so the client behaves
// correctly against an RPC that hasn't been migrated yet (049 / 052 / 053).

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
    /// 'YYYY-MM-DD' of the owner's next block (the OWNER's local date), when
    /// the projection provides one.
    var nextDate: String? { get }
    /// 'HH:MM' of that block (the OWNER's local time).
    var nextStartTime: String? { get }
    /// The same slot as an ISO instant (migration 053) — converted to the
    /// recipient's zone for placement + the slot label. nil pre-053.
    var nextStartAt: String? { get }
    /// Whether that next block is itself done (only ever true for a past block).
    var nextDone: Bool? { get }
    /// The owner parked the task in Later (migration 053). nil pre-053.
    var later: Bool? { get }
    /// The owner's life area, for the active-area filter.
    var lifeArea: String? { get }
}

public extension ShareVisibilityItem {
    var nextDate: String? { nil }
    var nextStartTime: String? { nil }
    var nextStartAt: String? { nil }
    var nextDone: Bool? { nil }
    var later: Bool? { nil }
    var lifeArea: String? { nil }
}

extension SharedWithMe: ShareVisibilityItem {}

// MARK: - Recipient-local slot

/// Epoch ms of a timestamptz as PostgREST projects it — "2026-09-06T04:30:00+00:00",
/// with or without fractional seconds (Postgres emits up to six digits; the
/// ISO parser wants three, so a longer fraction is trimmed, never dropped as
/// unparseable). nil for anything that isn't an instant.
public func sharedInstantMillis(_ iso: String) -> EpochMillis? {
    if let ms = Time.parseMillis(iso) { return ms }
    // "…:00.123456+00:00" → "…:00.123+00:00"
    guard let dot = iso.firstIndex(of: "."),
          let end = iso[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
    let frac = iso[iso.index(after: dot)..<end]
    guard frac.allSatisfy(\.isNumber) else { return nil }
    let trimmed = String(iso[..<dot]) + "." + String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(iso[end...])
    return Time.parseMillis(trimmed)
}

/// The owner's slot in the RECIPIENT's zone: ('YYYY-MM-DD', 'HH:MM') from
/// `nextStartAt` when the projection carries it (migration 053), else the
/// owner's own date/time text (pre-053 — the two only differ across zones).
/// nil when nothing is scheduled or the instant is unparseable.
public func sharedLocalSlot(nextDate: String?, nextStartTime: String?, nextStartAt: String?,
                            timeZone: TimeZone = .current) -> (date: String, time: String?)? {
    if let at = nextStartAt, let ms = sharedInstantMillis(at) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return (date, time)
    }
    guard let nextDate, !nextDate.isEmpty else { return nil }
    let time = nextStartTime.flatMap { $0.isEmpty ? nil : $0 }
    return (nextDate, time)
}

/// The date a shared task is PLACED on, from the owner's next block: the
/// (recipient-local) block date, unless that block is a finished PAST one —
/// the server only falls back to a past block when no live block exists, and
/// a finished past block means nothing is scheduled (it is not "overdue"; see
/// `shareBucket` for where it lands). nil ⇒ unscheduled.
public func sharedPlacementDate(nextDate: String?, nextStartAt: String? = nil, nextDone: Bool?,
                                timeZone: TimeZone = .current) -> String? {
    guard let slot = sharedLocalSlot(nextDate: nextDate, nextStartTime: nil, nextStartAt: nextStartAt,
                                     timeZone: timeZone) else { return nil }
    if nextDone == true { return nil }
    return slot.date
}

// MARK: - Bucketing (the cross-platform rule)

/// Where a share lands, given the recipient-local `todayISO`.
public enum ShareBucket: String, Sendable, Equatable {
    /// The task is done (completed rows follow the isCompletedToday rule).
    case done
    case today
    case upcoming
    /// A LIVE block in the past and the task still open → Backlog.
    case overdue
    /// No block at all → lives in Today, like a task that arrived without a plan.
    case unscheduled
    /// The latest block is a FINISHED past one: nothing scheduled, but not
    /// current work either → All only (never Today / Backlog).
    case finishedPast
    /// The owner parked it in Later (and nothing future is booked) → All only,
    /// exactly like the owner's own Later tasks leave Today + Backlog.
    case parked
}

public func shareBucket(done: Bool, nextDate: String?, nextStartAt: String? = nil, nextDone: Bool?,
                        later: Bool? = nil, todayISO: String, timeZone: TimeZone = .current) -> ShareBucket {
    if done { return .done }
    guard let slot = sharedLocalSlot(nextDate: nextDate, nextStartTime: nil, nextStartAt: nextStartAt,
                                     timeZone: timeZone) else {
        return later == true ? .parked : .unscheduled
    }
    if nextDone == true { return .finishedPast }
    if slot.date > todayISO { return .upcoming }
    if later == true { return .parked }
    return slot.date == todayISO ? .today : .overdue
}

public func shareBucket<T: ShareVisibilityItem>(_ item: T, todayISO: String, timeZone: TimeZone = .current) -> ShareBucket {
    shareBucket(done: item.done, nextDate: item.nextDate, nextStartAt: item.nextStartAt, nextDone: item.nextDone,
                later: item.later, todayISO: todayISO, timeZone: timeZone)
}

/// True when a shared row with this state belongs in the given view.
/// `todayISO` is the local 'YYYY-MM-DD' (the block dates compare
/// lexicographically, like the web / VisibleTasks).
public func shareVisibleIn(done: Bool, completedAt: String?, nextDate: String? = nil, nextStartAt: String? = nil,
                           nextDone: Bool? = nil, later: Bool? = nil,
                           mode: ShareViewMode, now: EpochMillis, todayISO: String = Clock.todayISO(),
                           timeZone: TimeZone = .current) -> Bool {
    if mode == .completed { return done }
    if !done {
        if mode == .all { return true }
        let bucket = shareBucket(done: false, nextDate: nextDate, nextStartAt: nextStartAt, nextDone: nextDone,
                                 later: later, todayISO: todayISO, timeZone: timeZone)
        switch mode {
        case .today: return bucket == .today || bucket == .unscheduled
        case .upcoming: return bucket == .upcoming
        case .backlog: return bucket == .overdue
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

/// Life-area filter for shared rows — the web `shareMatchesArea` rule (and
/// Android's): a share with NO area still shows under any filter; the
/// "Unassigned" sentinel narrows to exactly those area-less shares; a nil /
/// empty filter admits everything.
public func shareMatchesArea(_ lifeArea: String?, _ activeArea: String?) -> Bool {
    guard let activeArea, !activeArea.isEmpty else { return true }
    let area = lifeArea.flatMap { $0.isEmpty ? nil : $0 }
    if activeArea == UNASSIGNED_AREA { return area == nil }
    return area == nil || area == activeArea
}

/// True when this shared row belongs in the given view (+ passes the active
/// life-area filter, when one is set — `shareMatchesArea` semantics).
public func shareVisibleIn<T: ShareVisibilityItem>(_ item: T, _ mode: ShareViewMode, now: EpochMillis,
                                                   todayISO: String = Clock.todayISO(),
                                                   activeArea: String? = nil,
                                                   timeZone: TimeZone = .current) -> Bool {
    guard shareMatchesArea(item.lifeArea, activeArea) else { return false }
    return shareVisibleIn(done: item.done, completedAt: item.completedAt,
                          nextDate: item.nextDate, nextStartAt: item.nextStartAt,
                          nextDone: item.nextDone, later: item.later,
                          mode: mode, now: now, todayISO: todayISO, timeZone: timeZone)
}

/// Chronological order by the owner's slot (recipient-local): earliest first,
/// unscheduled rows sink to the end. Port of the web `compareShareSlot`.
/// Returns <0 / 0 / >0.
public func compareShareSlot<T: ShareVisibilityItem>(_ a: T, _ b: T, timeZone: TimeZone = .current) -> Int {
    let sa = sharedLocalSlot(nextDate: a.nextDate, nextStartTime: a.nextStartTime, nextStartAt: a.nextStartAt, timeZone: timeZone)
    let sb = sharedLocalSlot(nextDate: b.nextDate, nextStartTime: b.nextStartTime, nextStartAt: b.nextStartAt, timeZone: timeZone)
    switch (sa, sb) {
    case (nil, nil): return 0
    case (nil, _): return 1
    case (_, nil): return -1
    case let (x?, y?):
        if x.date != y.date { return x.date < y.date ? -1 : 1 }
        let xt = x.time ?? "", yt = y.time ?? ""
        return xt < yt ? -1 : (xt > yt ? 1 : 0)
    }
}

/// Filter + order a shared list for a view: open first — earliest slot first,
/// unscheduled last (`compareShareSlot`) — completed after (never park
/// struck-through rows above the next thing to do). The web relies on a
/// STABLE sort; Swift's sort is not guaranteed stable, so ties fall back to
/// the input order explicitly.
public func visibleShares<T: ShareVisibilityItem>(
    _ items: [T],
    mode: ShareViewMode,
    now: EpochMillis = Date().timeIntervalSince1970 * 1000,
    todayISO: String = Clock.todayISO(),
    activeArea: String? = nil,
    timeZone: TimeZone = .current
) -> [T] {
    let kept = items.enumerated().filter {
        shareVisibleIn($0.element, mode, now: now, todayISO: todayISO, activeArea: activeArea, timeZone: timeZone)
    }
    let open = kept.filter { !$0.element.done }.sorted { l, r in
        let c = compareShareSlot(l.element, r.element, timeZone: timeZone)
        return c != 0 ? c < 0 : l.offset < r.offset
    }
    let done = kept.filter { $0.element.done }
    return (open + done).map(\.element)
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

/// The slot line on a "shared with you" row — "Sat 04:30 · 45m" (24-hour
/// phone) / "Sat 4:30 AM · 45m" (12-hour) — from the owner's next block, in
/// the RECIPIENT's zone when `nextStartAt` is given, in the recipient's clock.
/// nil when nothing is placed (no block, or only a finished past one), so the
/// row falls back to just "from <owner>".
public func sharedSlotLabel(nextDate: String?, nextStartTime: String?, nextDurationMinutes: Int?,
                            nextDone: Bool? = nil, nextStartAt: String? = nil,
                            todayISO: String = Clock.todayISO(), timeZone: TimeZone = .current,
                            clock: ClockFormat = .device) -> String? {
    guard nextDone != true,
          let slot = sharedLocalSlot(nextDate: nextDate, nextStartTime: nextStartTime, nextStartAt: nextStartAt,
                                     timeZone: timeZone) else { return nil }
    var out = sharedDayLabel(slot.date, todayISO: todayISO)
    if let t = slot.time, !t.isEmpty { out += " \(clock.time(t))" }
    if let m = nextDurationMinutes, m > 0 { out += " · \(m)m" }
    return out
}

/// The "Planned …" line in the shared-task detail — "Planned Sat, Sep 12 ·
/// 04:30 · 45m" — from the `next_*` projection (or a tapped calendar block),
/// in the recipient's zone when an instant is given, in the recipient's
/// 12/24-hour clock. Unlike the row slot, a finished past block still reads
/// (it says when the task WAS): "Done Fri, Sep 4 · 09:00 · 45m". nil when the
/// task has never been scheduled.
public func sharedPlannedLabel(nextDate: String?, nextStartTime: String?, nextDurationMinutes: Int?,
                               nextDone: Bool?, nextStartAt: String? = nil,
                               timeZone: TimeZone = .current, clock: ClockFormat = .device) -> String? {
    guard let slot = sharedLocalSlot(nextDate: nextDate, nextStartTime: nextStartTime, nextStartAt: nextStartAt,
                                     timeZone: timeZone) else { return nil }
    let parts = slot.date.split(separator: "-").map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEE, MMM d"
    var out = "\(nextDone == true ? "Done" : "Planned") \(f.string(from: Time.civil(y, m, d)))"
    if let t = slot.time, !t.isEmpty { out += " · \(clock.time(t))" }
    if let mins = nextDurationMinutes, mins > 0 { out += " · \(mins)m" }
    return out
}
