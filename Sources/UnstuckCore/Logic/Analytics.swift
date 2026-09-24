// Analytics derivation helpers — pure functions over the live
// collections. Port of lib/analytics.ts. Swift Charts views (the iOS
// Report + DeepDive) consume these; each chart decides whether it has
// enough data to show real numbers vs. an empty state.
//
// Callers pass sessions through `countableSessions` (PeriodFacts.swift, the
// D1 filter) first, so a forgotten timer or an accidental 5-second start
// never reaches a chart.

import Foundation

// Floor for the qualitative "Worth noticing" insights only — a single session
// shouldn't claim a "strongest day". The numeric cards + charts no longer gate
// on this (they show real data from the first session via enoughData/hasDots);
// kept low so the prose insights still surface early (Android parity).
public let REAL_DATA_THRESHOLD = 3
private let HOUR: Double = 3600

private func parseDate(_ iso: String) -> Date? {
    Time.parseMillis(iso).map { Date(timeIntervalSince1970: $0 / 1000) }
}

/// Monday-anchored weekday index: Mon=0 … Sun=6.
public func dayOfWeekIdx(_ d: Date) -> Int {
    (Time.dayOfWeekJS(d) + 6) % 7
}

// MARK: H1 — weekday × area stacked bars

public struct StackedBar: Equatable, Sendable {
    public let d: String
    public var data: [Double]
}
private let DAY_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
public let DEFAULT_AREAS = ["Work", "Personal", "Home", "Health", "Volunteering"]

/// Label of the trailing "unassigned" series in `weekdayAreaHours`.
public let NO_AREA_LABEL = "No area"

/// Focus hours per weekday (Mon…Sun) × area. `data` holds one slot per name
/// in `areas` (the user's OWN life areas, in their order) PLUS one trailing
/// "No area" slot for sessions with no task, a task with no area, or an area
/// that no longer exists — those were silently dropped before (≈42% of prod
/// focus time; analytics cross-check P0-5).
public func weekdayAreaHours(_ sessions: [Session], _ tasks: [TaskItem], areas: [String] = DEFAULT_AREAS) -> [StackedBar] {
    var taskArea: [String: String] = [:]
    for t in tasks where t.lifeArea != nil { taskArea[t.id] = t.lifeArea }
    var out = DAY_LABELS.map { StackedBar(d: $0, data: Array(repeating: 0, count: areas.count + 1)) }
    for s in sessions {
        guard let d = parseDate(s.completedAt) else { continue }
        let ai = s.taskId.flatMap { taskArea[$0] }.flatMap { areas.firstIndex(of: $0) } ?? areas.count
        out[dayOfWeekIdx(d)].data[ai] += Double(s.actualSec) / HOUR
    }
    return out
}

// MARK: H2 — estimate-vs-actual scatter

public struct CalibrationDot: Equatable, Sendable {
    public let e: Int       // estimateMin
    public let a: Int       // actualMin (rounded)
    public let t: String    // task name
}

public func calibrationDots(_ sessions: [Session], _ tasks: [TaskItem], cap: Int = 24) -> [CalibrationDot] {
    let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let sorted = sessions.sorted { $0.completedAt > $1.completedAt }   // desc
    var out: [CalibrationDot] = []
    for s in sorted.prefix(cap) {
        guard let taskId = s.taskId, let task = byId[taskId] else { continue }
        out.append(CalibrationDot(e: task.estimateMin, a: Int((Double(s.actualSec) / 60).rounded()), t: task.name))
    }
    return out
}

public func calibrationHitRate(_ dots: [CalibrationDot], slackMin: Int = 5) -> Double {
    if dots.isEmpty { return 0 }
    let hits = dots.filter { abs($0.a - $0.e) <= slackMin }.count
    return Double(hits) / Double(dots.count)
}

// MARK: H3 — interruption histogram (captures as the proxy)

public func interruptionBins(_ captures: [Capture], _ sessions: [Session], binMin: Int = 3, binCount: Int = 10) -> [Int] {
    // Degenerate-arg guards: a 0-wide bin divides-by-zero in the index math, and
    // a 0-count bin array would index bins[-1]. Coerce to safe minimums.
    let binMin = max(1, binMin)
    guard binCount >= 1 else { return [] }
    var bins = Array(repeating: 0, count: binCount)
    var sessionStart: [String: Double] = [:]
    for s in sessions {
        if let end = Time.parseMillis(s.completedAt) {
            sessionStart[s.id] = end - Double(s.actualSec) * 1000
        }
    }
    for c in captures {
        guard let sid = c.sessionId, let start = sessionStart[sid], let at = Time.parseMillis(c.at) else { continue }
        let intoMin = (at - start) / 60_000
        if intoMin < 0 { continue }
        let idx = min(binCount - 1, Int((intoMin / Double(binMin)).rounded(.down)))
        bins[idx] += 1
    }
    return bins
}

// MARK: H4 — hour × day heatmap (7 days × 24 hours, by the hours a session spanned)

public typealias Heatmap = [[Double]]

/// Focus MINUTES per local weekday (rows Mon…Sun) × hour of day (0…23),
/// spread over the hours each session actually ran: it ended at
/// `completedAt` and started `actualSec` earlier, so 21:30–23:10 puts 30 min
/// in 21h, 60 in 22h and 10 in 23h. Every day and every hour counts —
/// weekends, evenings and night owls included (the old Mon–Fri 07–19 grid by
/// END hour showed 20% of prod focus; cross-check P0-2).
public func focusHourGrid(_ sessions: [Session]) -> Heatmap {
    var grid: Heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    let cal = Time.calendar
    for s in sessions where s.actualSec > 0 {
        guard let endMs = Time.parseMillis(s.completedAt) else { continue }
        let end = Date(timeIntervalSince1970: endMs / 1000)
        var t = end.addingTimeInterval(-Double(s.actualSec))
        var guardSteps = 0
        while t < end, guardSteps < 48 {
            guardSteps += 1
            let hourEnd = cal.dateInterval(of: .hour, for: t)?.end ?? end
            let segEnd = min(hourEnd, end)
            let c = cal.dateComponents([.weekday, .hour], from: t)
            let row = ((c.weekday ?? 1) + 5) % 7          // 1=Sun…7=Sat → Mon=0…Sun=6
            grid[row][min(max(c.hour ?? 0, 0), 23)] += segEnd.timeIntervalSince(t) / 60
            if segEnd <= t { break }
            t = segEnd
        }
    }
    return grid
}

/// The busiest (weekday, hour) cell of `focusHourGrid`, or nil when empty.
public func peakFocusHour(_ grid: Heatmap) -> (day: Int, hour: Int, minutes: Double)? {
    var best: (day: Int, hour: Int, minutes: Double)? = nil
    for (d, row) in grid.enumerated() {
        for (h, m) in row.enumerated() where m > (best?.minutes ?? 0) { best = (d, h, m) }
    }
    return best
}

// MARK: H5 — pause anatomy

public struct PauseBar: Equatable, Sendable {
    public let reason: String
    public let minutes: Double
    public let count: Int
}

public func pauseAnatomy(_ reasonLogs: [ReasonLog]) -> [PauseBar] {
    var minutesByReason: [String: Double] = [:]
    var countByReason: [String: Int] = [:]
    var order: [String] = []
    for r in reasonLogs {
        let key = r.reason.isEmpty ? "Other" : r.reason
        if countByReason[key] == nil { order.append(key) }
        countByReason[key, default: 0] += 1
        if let dur = r.durationSec, dur > 0 {
            minutesByReason[key, default: 0] += Double(dur) / 60
        }
    }
    return order
        .map { PauseBar(reason: $0, minutes: minutesByReason[$0] ?? 0, count: countByReason[$0] ?? 0) }
        .sorted { ($0.minutes, Double($0.count)) > ($1.minutes, Double($1.count)) }
        .prefix(6)
        .map { $0 }
}

// MARK: H6 — how fast you come back (pause → resume)

/// Pause lengths (reason logs with a `durationSec`, written on resume) in
/// `binMin`-minute bins; the last bin collects everything longer. Replaces
/// the old re-entry chart, which measured the DAYS between two sessions on
/// the same task (cross-check P0-6, decision D5).
public func pauseLengthBins(_ reasonLogs: [ReasonLog], binMin: Int = 5, binCount: Int = 7) -> [Int] {
    let binMin = max(1, binMin)
    guard binCount >= 1 else { return [] }
    var bins = Array(repeating: 0, count: binCount)
    for r in reasonLogs {
        guard let sec = r.durationSec, sec > 0 else { continue }
        bins[min(binCount - 1, sec / (binMin * 60))] += 1
    }
    return bins
}

// MARK: re-entry distribution (days-between-sessions; no longer shown)

public func reEntryDistribution(_ sessions: [Session], binMin: Int = 5, binCount: Int = 12) -> [Int] {
    // Degenerate-arg guards (see interruptionBins): avoid divide-by-zero on a
    // 0-wide bin and a bins[-1] index when no bins were requested.
    let binMin = max(1, binMin)
    guard binCount >= 1 else { return [] }
    var bins = Array(repeating: 0, count: binCount)
    var byTask: [String: [Session]] = [:]
    for s in sessions {
        guard let taskId = s.taskId else { continue }
        byTask[taskId, default: []].append(s)
    }
    for var list in byTask.values {
        list.sort { $0.completedAt < $1.completedAt }
        for i in 1..<max(1, list.count) where i < list.count {
            guard let prevEnd = Time.parseMillis(list[i - 1].completedAt),
                  let thisEnd = Time.parseMillis(list[i].completedAt) else { continue }
            let gapMin = (thisEnd - prevEnd) / 60_000 - Double(list[i].actualSec) / 60
            if gapMin <= 0 { continue }
            let idx = min(binCount - 1, Int((gapMin / Double(binMin)).rounded(.down)))
            bins[idx] += 1
        }
    }
    return bins
}

// MARK: H7 — slip detector

public struct SlipRow: Equatable, Sendable {
    public let name: String
    public let weeks: Int
    public let moveCount: Int
}

/// Open one-off tasks that have waited 21+ days or been moved 3+ times.
/// Repeating templates (their age is the series', and moving one day bumps
/// the template's count) and Later tasks (parked on purpose) are not slips.
/// Returns the FULL list — the card shows the true count, lists cap at display.
public func slipping(_ tasks: [TaskItem], now: EpochMillis = Date().timeIntervalSince1970 * 1000) -> [SlipRow] {
    var out: [SlipRow] = []
    for t in tasks {
        if t.done || t.recurrence != nil || t.later == true { continue }
        let ageDays: Double = Time.parseMillis(t.createdAt).map { (now - $0) / (24 * 60 * 60 * 1000) } ?? 0
        let moves = t.moveCount ?? 0
        if ageDays >= 21 || moves >= 3 {
            out.append(SlipRow(name: t.name, weeks: max(0, Int((ageDays / 7).rounded(.down))), moveCount: moves))
        }
    }
    return out.sorted {
        ($0.moveCount, $0.weeks) != ($1.moveCount, $1.weeks)
            ? ($0.moveCount, $0.weeks) > ($1.moveCount, $1.weeks)
            : utf16Less($0.name, $1.name)
    }
}

// MARK: capture flow breakdown

public func captureBreakdown(_ captures: [Capture]) -> [CaptureTag: Int] {
    var out: [CaptureTag: Int] = [.followUp: 0, .idea: 0, .edit: 0, .question: 0, .distraction: 0]
    for c in captures { out[c.tag, default: 0] += 1 }
    return out
}

// MARK: Insight engine — the Report "WORTH NOTICING" cards

public struct Insight: Equatable, Sendable {
    public let title: String
    public let sub: String
    public init(title: String, sub: String) {
        self.title = title
        self.sub = sub
    }
}

private let WEEKDAY_NAMES = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

/// `now` defaults to the wall clock (the Insights screen); the assistant's
/// `renderInsights` passes its own clock so the slip card is deterministic.
public func topInsights(sessions: [Session], tasks: [TaskItem], captures: [Capture], reasonLogs: [ReasonLog],
                        now: EpochMillis = Date().timeIntervalSince1970 * 1000) -> [Insight] {
    var out: [Insight] = []

    if sessions.count >= REAL_DATA_THRESHOLD {
        // 1. Best weekday by focus minutes.
        var byDay = Array(repeating: 0.0, count: 7)
        for s in sessions {
            if let d = parseDate(s.completedAt) { byDay[dayOfWeekIdx(d)] += Double(s.actualSec) / 60 }
        }
        if let maxVal = byDay.max(), maxVal > 0, let idx = byDay.firstIndex(of: maxVal) {
            out.append(Insight(
                title: "\(WEEKDAY_NAMES[idx]) are your strongest day.",
                sub: "\(Int(maxVal.rounded())) focused minutes — more than any other day this window. Stack harder work here."))
        }

        // 2. Calibration tightening.
        let dots = calibrationDots(sessions, tasks)
        if dots.count >= 3 {
            let hit = calibrationHitRate(dots)
            let phrase = hit >= 0.75 ? "you're nailing your estimates"
                : hit >= 0.5 ? "your estimates are improving" : "estimates are still settling"
            out.append(Insight(
                title: "Estimates within 5 min \(Int((hit * 100).rounded()))% of the time.",
                sub: "\(dots.count) recent sessions tracked — \(phrase). The calibration card shows where outliers landed."))
        }
    }

    // 3. Slipping task (works even at low session counts).
    let slips = slipping(tasks, now: now)
    if let top = slips.first {
        let reason = top.moveCount >= 3 ? "rescheduled \(top.moveCount) times" : "\(top.weeks)+ weeks on the list"
        out.append(Insight(title: "\"\(top.name)\" keeps slipping.", sub: "\(reason). Remove it, or break it down differently?"))
    }

    return Array(out.prefix(3))
}
