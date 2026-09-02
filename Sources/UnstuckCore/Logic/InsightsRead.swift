// The Insights screen, rendered as text for the assistant (`get_insights`).
//
// `renderInsights` is a pure function the assistant calls to answer "how was
// my week?", "am I underestimating?", "what keeps stopping me?", "what's
// slipping?" from REAL data. It takes the same live collections the Insights
// screen reads, scopes them with the SAME window rule (Monday 00:00 / the 1st
// / everything — AnalyticsModel.cutoff) and runs the SAME derivations
// (Analytics.swift), so every number the model quotes equals what the user
// sees on the Insights tab. Port of lib/assistant/insights-read.ts.
//
// Output: compact plain text (no markdown), ≤ MAX_CHARS, prefixed `ok:` like
// the other assistant tool results. Each section is omitted (or says so in
// one short line) when there is nothing behind it — never a fabricated
// "sample" number.
//
// Date-only values (calendar-block dates, header dates) use LOCAL getters —
// never a UTC ISO round-trip, which shifts the day near midnight for anyone
// east or west of UTC.

import Foundation

public enum InsightsWindow: String, Sendable, CaseIterable {
    case week, month, all
}

/// Hard ceiling on the report. Past it, insight sub-lines drop first, then we truncate.
public let INSIGHTS_MAX_CHARS = 1200

/// Same slack `calibrationHitRate` uses — "within 5 min" on the Estimates card.
private let SLACK_MIN = 5
private let MAX_SLIPS = 5
private let MAX_PAUSES = 3
private let MAX_INSIGHTS = 3
private let MAX_NAME = 40

private let DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
/// Heatmap columns (timeOfDayHeatmap): six 2-hour buckets from 7am, Mon–Fri only.
private let HEAT_BUCKETS = ["7–9am", "9–11am", "11am–1pm", "1–3pm", "3–5pm", "5–7pm"]
/// Same display order as the DeepDive "Captures by kind" band.
private let TAG_ORDER: [CaptureTag] = [.followUp, .idea, .edit, .question, .distraction]

// MARK: - window scoping (mirrors lib/analytics-window.ts + AnalyticsModel.cutoff)

/// Window start: Monday 00:00 local for 'week', the 1st for 'month', nil for 'all'.
func insightsWindowStart(_ window: InsightsWindow, now: Date) -> Date? {
    let cal = Calendar.current
    let day = cal.startOfDay(for: now)
    switch window {
    case .all: return nil
    case .week: return Time.addDays(day, -((Time.dayOfWeekJS(day) + 6) % 7))
    case .month: return cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day
    }
}

private func inWindow(_ iso: String, lo: EpochMillis?) -> Bool {
    guard let lo else { return true }
    guard let t = Time.parseMillis(iso) else { return false }
    return t >= lo
}

public func windowLabel(_ window: InsightsWindow) -> String {
    switch window {
    case .week: return "WEEK SO FAR"
    case .month: return "MONTH SO FAR"
    case .all: return "ALL TIME"
    }
}

// MARK: - small formatters

/// Identical to the DeepDive "Focus this week" stat: `2h 45m`.
private func fmtHM(_ sec: Int) -> String { "\(sec / 3600)h \((sec % 3600) / 60)m" }

/// `Wed 2 Sep` — local getters only.
private func fmtDay(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    return "\(DAY_SHORT[Time.dayOfWeekJS(d)]) \(c.day ?? 0) \(MONTHS[(c.month ?? 1) - 1])"
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
private func pct(_ frac: Double) -> Int { jsRound(frac * 100) }
private func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

/// JS `toFixed(1)`: ties round up (1.25 → "1.3"), unlike printf's half-even.
private func toFixed1(_ x: Double) -> String {
    let n = (x * 10).rounded(.toNearestOrAwayFromZero)
    return String(format: "%.1f", n / 10)
}

private func quote(_ name: String) -> String {
    let clean = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let shown = clean.count > MAX_NAME ? "\(clean.prefix(MAX_NAME - 1))…" : clean
    return "\"\(shown)\""
}

/// DeepDive's median: sorted, then the element at floor(n/2).
private func medianSec(_ sessions: [Session]) -> Int {
    let arr = sessions.map { $0.actualSec }.sorted()
    return arr[arr.count / 2]
}

private enum Verdict { case underestimating, overestimating, aboutRight }

/// One-line verdict from the calibration dots. A miss is anything outside the
/// ±5 min slack. "Underestimating" when the over-runs outnumber the
/// under-runs AND make up at least ~30% of the tracked sessions (so a single
/// outlier among many hits can't flip the verdict); symmetric for over.
private func calibrationVerdict(over: Int, under: Int, n: Int) -> Verdict {
    let floor = Double(n) * 0.3
    if over > under && Double(over) >= floor { return .underestimating }
    if under > over && Double(under) >= floor { return .overestimating }
    return .aboutRight
}

private func verdictText(_ v: Verdict) -> String {
    switch v {
    case .underestimating: return "underestimating (things take longer than you plan)"
    case .overestimating: return "overestimating (things finish sooner than you plan)"
    case .aboutRight: return "about right"
    }
}

// MARK: - the report

public func renderInsights(
    tasks: [TaskItem],
    sessions allSessions: [Session],
    captures allCaptures: [Capture],
    reasons: [ReasonLog],
    blocks: [CalBlock],
    now: Date,
    window: InsightsWindow
) -> String {
    let start = insightsWindowStart(window, now: now)
    let lo: EpochMillis? = start.map { $0.timeIntervalSince1970 * 1000 }
    let sessions = allSessions.filter { inWindow($0.completedAt, lo: lo) }
    let captures = allCaptures.filter { inWindow($0.at, lo: lo) }
    let reasonLogs = reasons.filter { inWindow($0.at, lo: lo) }
    let nowMs: EpochMillis = now.timeIntervalSince1970 * 1000

    var lines: [String] = []

    // Header — which window, which local dates.
    let range = start.map { "\(fmtDay($0)) – \(fmtDay(now))" } ?? "to \(fmtDay(now))"
    lines.append("ok: Insights, \(windowLabel(window).lowercased()) (\(range)).")

    // Focus: total + count + median (DeepDive stat strip), by area (Report
    // stacked bars), peak weekday slot (DeepDive heatmap).
    if sessions.isEmpty {
        lines.append("Focus: no focus sessions in this window.")
    } else {
        let totalSec = sessions.reduce(0) { $0 + $1.actualSec }
        lines.append("Focus: \(fmtHM(totalSec)) across \(plural(sessions.count, "session")), median \(jsRound(Double(medianSec(sessions)) / 60))m.")

        // By area over the Report's default area order (web AREA_ORDER).
        let bars = weekdayAreaHours(sessions, tasks)
        var areaLines: [String] = []
        for (i, area) in DEFAULT_AREAS.enumerated() {
            let hours = bars.reduce(0.0) { $0 + $1.data[i] }
            if hours > 0 { areaLines.append("\(area) \(toFixed1(hours))h") }
        }
        if !areaLines.isEmpty {
            lines.append("By area: \(areaLines.joined(separator: ", ")).")
        }

        let grid = timeOfDayHeatmap(sessions)
        var peak = (dow: -1, bucket: -1, hours: 0.0)
        for (dow, row) in grid.enumerated() {
            for (bucket, hours) in row.enumerated() where hours > peak.hours {
                peak = (dow, bucket, hours)
            }
        }
        if peak.hours > 0 {
            // Heatmap rows are Mon..Fri (Monday-anchored index 0..4).
            lines.append("Peak slot: \(DAY_SHORT[peak.dow + 1]) \(HEAT_BUCKETS[peak.bucket]) (\(jsRound(peak.hours * 60)) min).")
        }
    }

    // Estimates: the calibration card + a verdict the model can hand back
    // when asked "am I underestimating?".
    let dots = calibrationDots(sessions, tasks)
    if !dots.isEmpty {
        let hit = calibrationHitRate(dots, slackMin: SLACK_MIN)
        let over = dots.filter { $0.a - $0.e > SLACK_MIN }.count
        let under = dots.filter { $0.e - $0.a > SLACK_MIN }.count
        let meanDelta = jsRound(Double(dots.reduce(0) { $0 + ($1.a - $1.e) }) / Double(dots.count))
        lines.append(
            "Estimates: \(pct(hit))% of \(plural(dots.count, "estimated session")) landed within \(SLACK_MIN) min; "
            + "\(over) ran over, \(under) ran under; actual vs estimate averages \(signed(meanDelta)) min. "
            + "Verdict: \(verdictText(calibrationVerdict(over: over, under: under, n: dots.count))).")
    } else if !sessions.isEmpty {
        lines.append("Estimates: no sessions linked to an estimated task yet.")
    }

    // Pauses: DeepDive "What pauses you" — reason × count (+ real minutes when logged).
    let pauses = pauseAnatomy(reasonLogs)
    if pauses.isEmpty {
        lines.append("Pauses: none logged in this window.")
    } else {
        let top = pauses.prefix(MAX_PAUSES)
            .map { "\($0.reason) \($0.count)x\($0.minutes > 0 ? " (\(jsRound($0.minutes))m)" : "")" }
            .joined(separator: ", ")
        lines.append("Pauses: \(plural(reasonLogs.count, "reason")) logged; top: \(top).")
    }

    // Interruptions: Report histogram — captures written mid-session, by minutes in.
    let bins = interruptionBins(captures, sessions)
    let linked = bins.reduce(0, +)
    if linked > 0 {
        let peakIdx = bins.firstIndex(of: bins.max() ?? 0) ?? 0
        lines.append("Interruptions: \(plural(linked, "capture")) mid-session, most around \(peakIdx * 3)–\((peakIdx + 1) * 3) min in.")
    }

    // Re-entry: DeepDive "Re-entry within 5m" — only when a gap was measurable.
    let reentry = reEntryDistribution(sessions)
    let gaps = reentry.reduce(0, +)
    if gaps > 0 {
        lines.append("Re-entry: \(pct(Double(reentry[0]) / Double(gaps)))% of \(plural(gaps, "return")) to a task came within 5 min.")
    }

    // Slipping: Report "Gentle friction" count + DeepDive slip detector names.
    let slips = slipping(tasks, now: nowMs)
    if slips.isEmpty {
        lines.append("Slipping: none.")
    } else {
        let shown = slips.prefix(MAX_SLIPS)
            .map { "\(quote($0.name)) (moved \($0.moveCount)x, \($0.weeks)wk on list)" }
            .joined(separator: "; ")
        let more = slips.count > MAX_SLIPS ? " +\(slips.count - MAX_SLIPS) more" : ""
        lines.append("Slipping: \(plural(slips.count, "task")) — \(shown)\(more).")
    }

    // Captures by kind (window-scoped, same order as the DeepDive band).
    if captures.isEmpty {
        lines.append("Captures: none.")
    } else {
        let counts = captureBreakdown(captures)
        let kinds = TAG_ORDER.filter { (counts[$0] ?? 0) > 0 }.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: ", ")
        lines.append("Captures: \(captures.count) — \(kinds).")
    }

    // Planned: own calendar blocks dated inside the window up to today (local
    // date strings, so a block for "today" is today's in every timezone).
    let todayStr = Clock.dateISO(now)
    let startStr = start.map { Clock.dateISO($0) }
    let planned = blocks.filter { b in
        !b.skipped
            && b.kind != .external && (b.externalEventId ?? "").isEmpty
            && b.date <= todayStr
            && (startStr == nil || b.date >= startStr!)
    }
    if !planned.isEmpty {
        let mins = planned.reduce(0) { $0 + $1.durationMinutes }
        lines.append("Planned: \(plural(planned.count, "calendar block")) (\(fmtHM(mins * 60))) dated in this window.")
    }

    // Worth noticing: the Report's own narrative cards.
    let insights = Array(topInsights(sessions: sessions, tasks: tasks, captures: captures, reasonLogs: reasonLogs, now: nowMs).prefix(MAX_INSIGHTS))

    func compose(withSubs: Bool) -> String {
        if insights.isEmpty { return lines.joined(separator: "\n") }
        let noticing = insights.map { "- \($0.title)\(withSubs ? " \($0.sub)" : "")" }
        return (lines + ["Worth noticing:"] + noticing).joined(separator: "\n")
    }

    let full = compose(withSubs: true)
    if full.utf16.count <= INSIGHTS_MAX_CHARS { return full }
    let titlesOnly = compose(withSubs: false)
    if titlesOnly.utf16.count <= INSIGHTS_MAX_CHARS { return titlesOnly }
    return "\(titlesOnly.prefix(INSIGHTS_MAX_CHARS - 1))…"
}
