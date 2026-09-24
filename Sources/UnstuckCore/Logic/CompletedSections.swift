// Tasks › Completed, folded by WHEN each task was finished (owner request
// 2026-09-24: "one long list" → collapsible "last 24 hours, 48 hours, last
// week…" sections). Same rule on iOS, Android and web:
//
//   Today · Yesterday · Earlier this week · Last week · Earlier
//
// by the task's `completedAt`, on LOCAL day boundaries, weeks starting MONDAY
// (the app's convention). The first matching section wins, top to bottom, so
// on a Monday "Earlier this week" is empty and Sunday is "Yesterday"; on a
// Tuesday it is empty too and Sunday falls in "Last week". A missing or
// unparseable `completedAt` (and anything older than last week) is "Earlier".
// A timestamp in the future (clock skew) counts as Today. Newest first inside
// each section; empty sections are omitted.

import Foundation

public enum CompletedSection: String, CaseIterable, Sendable, Equatable {
    case today, yesterday, earlierThisWeek, lastWeek, earlier

    public var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case .earlier: return "Earlier"
        }
    }

    /// Open by default: Today and Yesterday; the rest start folded.
    public var expandedByDefault: Bool { self == .today || self == .yesterday }
}

public struct CompletedGroup<T> {
    public let section: CompletedSection
    public let items: [T]
}

/// The four local midnights the sections split on, computed once per pass.
struct CompletedBoundaries {
    let today: EpochMillis, yesterday: EpochMillis, weekStart: EpochMillis, lastWeekStart: EpochMillis

    init(now: EpochMillis, calendar cal: Calendar) {
        let todayStart = cal.startOfDay(for: Date(timeIntervalSince1970: now / 1000))
        // Day arithmetic through the calendar, so a 23/25-hour DST day still
        // lands on the right local midnight. Monday is computed from the
        // weekday number, never from the device locale's first weekday.
        let sinceMonday = (cal.component(.weekday, from: todayStart) + 5) % 7   // Mon 0 … Sun 6
        func back(_ days: Int, _ from: Date) -> Date {
            cal.date(byAdding: .day, value: -days, to: from) ?? from.addingTimeInterval(Double(-days) * 86_400)
        }
        let weekStart = back(sinceMonday, todayStart)
        today = todayStart.timeIntervalSince1970 * 1000
        yesterday = back(1, todayStart).timeIntervalSince1970 * 1000
        self.weekStart = weekStart.timeIntervalSince1970 * 1000
        lastWeekStart = back(7, weekStart).timeIntervalSince1970 * 1000
    }

    func section(_ ms: EpochMillis?) -> CompletedSection {
        guard let ms else { return .earlier }
        if ms >= today { return .today }
        if ms >= yesterday { return .yesterday }
        if ms >= weekStart { return .earlierThisWeek }
        if ms >= lastWeekStart { return .lastWeek }
        return .earlier
    }
}

/// Which section a completion instant falls in, relative to `now`.
public func completedSection(completedAt: String?, now: EpochMillis,
                             calendar: Calendar = Time.calendar) -> CompletedSection {
    CompletedBoundaries(now: now, calendar: calendar).section(completedAt.flatMap(Time.parseMillis))
}

/// Group completed rows into the non-empty sections, in section order, each
/// newest first (rows without a parseable `completedAt` last, input order kept
/// — Swift's sort is not stable, so ties fall back to the input index).
public func groupCompleted<T>(_ items: [T], completedAt: (T) -> String?, now: EpochMillis,
                              calendar: Calendar = Time.calendar) -> [CompletedGroup<T>] {
    let bounds = CompletedBoundaries(now: now, calendar: calendar)
    var buckets: [CompletedSection: [(offset: Int, ms: EpochMillis?, item: T)]] = [:]
    for (i, item) in items.enumerated() {
        let ms = completedAt(item).flatMap(Time.parseMillis)
        buckets[bounds.section(ms), default: []].append((i, ms, item))
    }
    return CompletedSection.allCases.compactMap { section in
        guard let rows = buckets[section], !rows.isEmpty else { return nil }
        let sorted = rows.sorted { l, r in
            switch (l.ms, r.ms) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return l.offset < r.offset
            }
        }
        return CompletedGroup(section: section, items: sorted.map(\.item))
    }
}
