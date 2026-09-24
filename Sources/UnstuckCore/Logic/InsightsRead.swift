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
/// Rows of `focusHourGrid`: Monday-anchored.
private let GRID_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
/// Minimum linked captures before the interruptions line (and the screen's
/// chart) says anything — below it the pattern is noise (cross-check P0-11).
public let INTERRUPTIONS_MIN_LINKED = 3

/// "10–11am", "11am–12pm", "11pm–12am" for the hour starting at `h`.
public func hourSpanLabel(_ h: Int) -> String {
    func parts(_ x: Int) -> (Int, String) { let v = ((x % 24) + 24) % 24; return (v % 12 == 0 ? 12 : v % 12, v < 12 ? "am" : "pm") }
    let (a, sa) = parts(h), (b, sb) = parts(h + 1)
    return sa == sb ? "\(a)–\(b)\(sb)" : "\(a)\(sa)–\(b)\(sb)"
}
/// Same display order as the DeepDive "Captures by kind" band.
private let TAG_ORDER: [CaptureTag] = [.followUp, .idea, .edit, .question, .distraction]

// MARK: - window scoping (mirrors lib/analytics-window.ts + AnalyticsModel.cutoff)

/// Window start: Monday 00:00 local for 'week', the 1st for 'month', nil for 'all'.
func insightsWindowStart(_ window: InsightsWindow, now: Date) -> Date? {
    let cal = Time.calendar
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

/// Seconds as the Insights page shows them: rounded minutes,
/// floor((sec + 30) / 60), written `45m` / `2h` / `1h 5m` — the page's
/// Focused card and get_period_review use the same rule, so the model never
/// quotes a number a minute off the screen ("1h 39m" for the page's 1h 40m;
/// same rule on web and Android).
func fmtFocusSec(_ sec: Int) -> String { fmtFocusDur(roundedMinutes(sec)) }

/// `Wed 2 Sep` — local getters only.
private func fmtDay(_ d: Date) -> String {
    let c = Time.calendar.dateComponents([.month, .day], from: d)
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

/// `areas` = the user's own life areas in their order (the Insights screen's
/// stacked bars); nil falls back to the defaults. Sessions go through the D1
/// filter (`countableSessions`) exactly as on screen.
public func renderInsights(
    tasks: [TaskItem],
    sessions allSessions: [Session],
    captures allCaptures: [Capture],
    reasons: [ReasonLog],
    blocks: [CalBlock],
    now: Date,
    window: InsightsWindow,
    areas userAreas: [String]? = nil
) -> String {
    let start = insightsWindowStart(window, now: now)
    let lo: EpochMillis? = start.map { $0.timeIntervalSince1970 * 1000 }
    // Raw rows in the window (the interruptions line places a runaway at its
    // real start), and the D1-counted ones every focus number uses.
    let rawSessions = allSessions.filter { inWindow($0.completedAt, lo: lo) }
    let sessions = countableSessions(rawSessions)
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
        lines.append("Focus: \(fmtFocusSec(totalSec)) across \(plural(sessions.count, "session")), median \(fmtFocusSec(medianSec(sessions))).")

        // By area: the screen's "When focus happens" series, series for
        // series — the user's areas, any other area a task carries under its
        // own name, then "No area".
        let areaNames = (userAreas?.isEmpty == false) ? userAreas! : DEFAULT_AREAS
        let bars = weekdayAreaBars(sessions, tasks, areas: areaNames)
        var areaLines: [String] = []
        for (i, series) in bars.series.enumerated() {
            let hours = bars.days.reduce(0.0) { $0 + $1.data[i] }
            if hours > 0 { areaLines.append("\(series.name) \(toFixed1(hours))h") }
        }
        if !areaLines.isEmpty {
            lines.append("By area: \(areaLines.joined(separator: ", ")).")
        }

        // The screen's hour × day grid: the busiest hour a session ran through.
        if let peak = peakFocusHour(focusHourGrid(sessions)), peak.minutes > 0 {
            lines.append("Peak slot: \(GRID_DAYS[peak.day]) \(hourSpanLabel(peak.hour)) (\(jsRound(peak.minutes)) min).")
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

    // Interruptions: Report histogram — captures written mid-session, by
    // minutes in. Shown (here and on screen) from 3 linked captures.
    let bins = interruptionBins(captures, rawSessions)
    let linked = bins.reduce(0, +)
    if linked >= INTERRUPTIONS_MIN_LINKED {
        let peakIdx = bins.firstIndex(of: bins.max() ?? 0) ?? 0
        lines.append("Interruptions: \(plural(linked, "capture")) mid-session, most around \(peakIdx * 3)–\((peakIdx + 1) * 3) min in.")
    }

    // Coming back: DeepDive "How fast you come back" — pause → resume, from
    // the pause lengths logged on resume; only when some were timed.
    let lengths = pauseLengthBins(reasonLogs)
    let timed = lengths.reduce(0, +)
    if timed > 0 {
        lines.append("Coming back: \(lengths[0]) of \(plural(timed, "timed pause")) ended within 5 min.")
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
        lines.append("Planned: \(plural(planned.count, "calendar block")) (\(fmtFocusDur(mins))) dated in this window.")
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
