// Analytics derivation helpers — pure functions over the live
// collections. Port of lib/analytics.ts. Swift Charts views (the iOS
// Report + DeepDive) consume these; each chart decides whether it has
// enough data to show real numbers vs. an empty state.

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
private func hourOf(_ d: Date) -> Int { Calendar.current.component(.hour, from: d) }

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

public func weekdayAreaHours(_ sessions: [Session], _ tasks: [TaskItem], areas: [String] = DEFAULT_AREAS) -> [StackedBar] {
    // Unassigned tasks (lifeArea == nil) drop out entirely — never
    // coerced to 'Work'.
    var taskArea: [String: String] = [:]
    for t in tasks where t.lifeArea != nil { taskArea[t.id] = t.lifeArea }
    var out = DAY_LABELS.map { StackedBar(d: $0, data: areas.map { _ in 0 }) }
    for s in sessions {
        guard let taskId = s.taskId, let area = taskArea[taskId],
              let ai = areas.firstIndex(of: area), let d = parseDate(s.completedAt) else { continue }
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

// MARK: H4 — time-of-day heatmap (5 weekdays × 6 two-hour buckets from 7am)

public typealias Heatmap = [[Double]]

public func timeOfDayHeatmap(_ sessions: [Session]) -> Heatmap {
    var grid: Heatmap = Array(repeating: Array(repeating: 0, count: 6), count: 5)
    for s in sessions {
        guard let d = parseDate(s.completedAt) else { continue }
        let dow = dayOfWeekIdx(d)
        if dow > 4 { continue }
        let bucket = Int((Double(hourOf(d) - 7) / 2).rounded(.down))
        if bucket < 0 || bucket > 5 { continue }
        grid[dow][bucket] += Double(s.actualSec) / HOUR
    }
    return grid
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

// MARK: H6 — re-entry distribution

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

public func slipping(_ tasks: [TaskItem], now: EpochMillis = Date().timeIntervalSince1970 * 1000) -> [SlipRow] {
    var out: [SlipRow] = []
    for t in tasks {
        if t.done { continue }
        let ageDays: Double = Time.parseMillis(t.createdAt).map { (now - $0) / (24 * 60 * 60 * 1000) } ?? 0
        let moves = t.moveCount ?? 0
        if ageDays >= 21 || moves >= 3 {
            out.append(SlipRow(name: t.name, weeks: max(0, Int((ageDays / 7).rounded(.down))), moveCount: moves))
        }
    }
    return out
        .sorted { ($0.moveCount, $0.weeks) > ($1.moveCount, $1.weeks) }
        .prefix(6)
        .map { $0 }
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
}

private let WEEKDAY_NAMES = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]

public func topInsights(sessions: [Session], tasks: [TaskItem], captures: [Capture], reasonLogs: [ReasonLog]) -> [Insight] {
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
    let slips = slipping(tasks)
    if let top = slips.first {
        let reason = top.moveCount >= 3 ? "rescheduled \(top.moveCount) times" : "\(top.weeks)+ weeks on the list"
        out.append(Insight(title: "\"\(top.name)\" keeps slipping.", sub: "\(reason). Remove it, or break it down differently?"))
    }

    return Array(out.prefix(3))
}
