// `get_period_review` — "how has my week been?" as compact text for the
// assistant. Port of period-review.ref.mjs (spec: week-review-spec.md); the
// shared vectors (Tests/UnstuckCoreTests/PeriodReviewVectors.generated.swift)
// pin every string byte for byte across web, iOS and Android.
//
// It is a text rendering of `periodFacts` (PeriodFacts.swift) — the same
// aggregation the Insights screen draws — so what the assistant says about a
// week agrees with the page for that week.
//
// Time zone: every zone comes from `Time.calendar` (never `TimeZone.current`,
// which ignores `NSTimeZone.default`, spec §6).

import Foundation

public let PERIOD_REVIEW_PERIODS = ["today", "yesterday", "this_week", "last_week", "this_month", "last_month", "week_of", "month_of", "dates"]
private let PERIOD_LIST = "today, yesterday, this_week, last_week, this_month, last_month, week_of (with date), month_of (with date), or dates (with from and to)"
public let PERIOD_REVIEW_MAX_DAYS = 93
public let PERIOD_REVIEW_MAX_CHARS = 1600
private let MAX_TASK_NAMES = 5
private let MAX_SERIES = 3
private let MAX_SLIPPED = 3
private let MAX_DEADLINES = 2
private let MAX_PAUSES = 3
private let MAX_AREAS = 3
private let DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
private let MONTH_FULL = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

/// The tool's raw string arguments (untrimmed; `resolvePeriod` trims them
/// with the spec's whitespace set). A non-string argument is passed as nil.
public struct PeriodReviewArgs: Sendable, Equatable {
    public var period: String?
    public var date: String?
    public var from: String?
    public var to: String?

    public init(period: String? = nil, date: String? = nil, from: String? = nil, to: String? = nil) {
        self.period = period
        self.date = date
        self.from = from
        self.to = to
    }
}

/// A resolved review span (spec §3.2).
public struct ResolvedPeriod: Equatable, Sendable {
    public let period: String
    public let from: String
    /// Last reviewed day (the nominal end, clipped to today).
    public let end: String
    public let clipped: Bool
    public let days: Int
    public let prevFrom: String
    public let prevTo: String
}

private func trimReviewSpace(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while let f = scalars.first, isReviewSpace(f) { scalars.removeFirst() }
    while let l = scalars.last, isReviewSpace(l) { scalars.removeLast() }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: scalars)
    return String(v)
}

/// Resolve `period` against local `today` — a period, or the exact error line.
public func resolvePeriod(_ args: PeriodReviewArgs, today: String) -> Result<ResolvedPeriod, PeriodReviewError> {
    func s(_ k: String) -> String? {
        let raw: String?
        switch k {
        case "period": raw = args.period
        case "date": raw = args.date
        case "from": raw = args.from
        default: raw = args.to
        }
        guard let raw else { return nil }
        let t = trimReviewSpace(raw)
        return t.isEmpty ? nil : t
    }
    let p = (s("period") ?? "").lowercased()
    if p.isEmpty { return .failure(.init("error: period required — \(PERIOD_LIST)")) }
    if !PERIOD_REVIEW_PERIODS.contains(p) { return .failure(.init("error: unknown period \"\(p)\" — use \(PERIOD_LIST)")) }
    func need(_ k: String, alias: String? = nil) -> Result<String, PeriodReviewError> {
        let key = s(k) == nil && alias != nil && s(alias!) != nil ? alias! : k
        guard let v = s(key) else { return .failure(.init("error: period=\(p) needs \(k) (YYYY-MM-DD)")) }
        guard CivilDay.parse(v) != nil else { return .failure(.init("error: \(key) must be a real date as YYYY-MM-DD (got \"\(v)\")")) }
        return .success(v)
    }
    enum Group { case day, week, month }
    var from = today, to = today
    var group = Group.day
    switch p {
    case "today": break
    case "yesterday": from = CivilDay.add(today, -1); to = from
    case "this_week": from = CivilDay.monday(today); to = CivilDay.add(from, 6); group = .week
    case "last_week": from = CivilDay.add(CivilDay.monday(today), -7); to = CivilDay.add(from, 6); group = .week
    case "week_of":
        switch need("date") {
        case .failure(let e): return .failure(e)
        case .success(let v): from = CivilDay.monday(v); to = CivilDay.add(from, 6); group = .week
        }
    case "this_month": from = CivilDay.firstOfMonth(today); to = CivilDay.lastOfMonth(today); group = .month
    case "last_month":
        from = CivilDay.firstOfMonth(CivilDay.add(CivilDay.firstOfMonth(today), -1)); to = CivilDay.lastOfMonth(from); group = .month
    case "month_of":
        switch need("date") {
        case .failure(let e): return .failure(e)
        case .success(let v): from = CivilDay.firstOfMonth(v); to = CivilDay.lastOfMonth(v); group = .month
        }
    default:   // dates
        switch need("from", alias: "date") {
        case .failure(let e): return .failure(e)
        case .success(let v): from = v
        }
        if s("to") == nil {
            to = from
        } else {
            switch need("to") {
            case .failure(let e): return .failure(e)
            case .success(let v): to = v
            }
        }
        if utf16Less(to, from) { return .failure(.init("error: to (\(to)) is before from (\(from))")) }
    }
    if utf16Less(today, from) {
        return .failure(.init("error: \(from) is after today (\(today)) — a review only covers what already happened; for what's coming up use get_schedule"))
    }
    let clipped = !utf16Less(to, today)
    let end = utf16Less(to, today) ? to : today
    let days = CivilDay.between(from, end) + 1
    if days > PERIOD_REVIEW_MAX_DAYS {
        return .failure(.init("error: that's \(days) days — a review covers at most \(PERIOD_REVIEW_MAX_DAYS) days; ask which week or month they mean, or review it in parts"))
    }
    let prevFrom: String, prevTo: String
    switch group {
    case .week:
        prevFrom = CivilDay.add(from, -7); prevTo = CivilDay.add(end, -7)
    case .month:
        prevFrom = CivilDay.firstOfMonth(CivilDay.add(from, -1))
        prevTo = clipped
            ? String(prevFrom.prefix(8)) + CivilDay.pad(min(CivilDay.dayOfMonth(end), CivilDay.daysInMonth(of: prevFrom)), 2)
            : CivilDay.lastOfMonth(prevFrom)
    case .day:
        prevFrom = CivilDay.add(from, -days); prevTo = CivilDay.add(from, -1)
    }
    return .success(ResolvedPeriod(period: p, from: from, end: end, clipped: clipped, days: days, prevFrom: prevFrom, prevTo: prevTo))
}

public struct PeriodReviewError: Error, Equatable, Sendable {
    public let line: String
    init(_ line: String) { self.line = line }
}

// MARK: - formatting primitives (spec §4.1)

private func plural(_ n: Int, _ one: String) -> String { "\(n) \(n == 1 ? one : one + "s")" }
private func signedInt(_ d: Int) -> String { d == 0 ? "same" : d > 0 ? "+\(d)" : "-\(-d)" }
private func signedDur(_ d: Int) -> String { d == 0 ? "same" : d > 0 ? "+\(fmtFocusDur(d))" : "-\(fmtFocusDur(-d))" }
private func q(_ s: String?) -> String { "\"\(reviewCleanName(s))\"" }

private func fmtDay(_ s: String, _ todayYear: Int) -> String {
    let (y, m, d) = CivilDay.ymd(CivilDay.num(s))
    return "\(DAY[CivilDay.weekday(s)]) \(d) \(MON[m - 1])\(y != todayYear ? " \(y)" : "")"
}

private func fmtRange(_ a: String, _ b: String, _ y: Int) -> String {
    a == b ? fmtDay(a, y) : "\(fmtDay(a, y)) – \(fmtDay(b, y))"
}

private func label(_ r: ResolvedPeriod, _ y: Int) -> String {
    let range = fmtRange(r.from, r.end, y)
    switch r.period {
    case "today": return "today (\(range), so far)"
    case "yesterday": return "yesterday (\(range))"
    case "this_week": return "this week (\(range), so far)"
    case "last_week": return "last week (\(range))"
    case "week_of": return "the week \(range)\(r.clipped ? " (so far)" : "")"
    case "this_month": return "this month (\(range), so far)"
    case "last_month": return "last month (\(range))"
    case "month_of":
        let (yy, m, _) = CivilDay.ymd(CivilDay.num(r.from))
        return "\(MONTH_FULL[m - 1]) \(yy) (\(range)\(r.clipped ? ", so far" : ""))"
    default: return "\(range)\(r.clipped ? " (so far)" : "")"
    }
}

// MARK: - the review

/// The full tool result. `sessions` are the raw rows (the D1 filter is
/// applied inside, like every other focus number). `historyFloor` is always
/// nil on iOS (spec §3.6); `blocksPartial` is the last cal_blocks pull's
/// `mayBeTruncated`.
public func renderPeriodReview(args: PeriodReviewArgs, tasks: [TaskItem], blocks: [CalBlock], sessions: [Session],
                               captures: [Capture], reasons: [ReasonLog], now: Date,
                               historyFloor: String?, blocksPartial: Bool) -> String {
    let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    let nowStamp = PeriodTime.at(nowMs)
    let today = nowStamp.day
    let y = CivilDay.ymd(CivilDay.num(today)).0
    let r: ResolvedPeriod
    switch resolvePeriod(args, today: today) {
    case .failure(let e): return e.line
    case .success(let v): r = v
    }
    let data = PeriodData(tasks: tasks, blocks: blocks, sessions: sessions, captures: captures, reasons: reasons)
    let cut = r.clipped ? nowStamp.minute : nil
    let cur = periodFacts(data, PeriodWindow(from: r.from, to: r.end, cut: cut))
    let prev = periodFacts(data, PeriodWindow(from: r.prevFrom, to: r.prevTo, cut: cut))
    let header = "ok: review of \(label(r, y))."
    var lines = [header]

    // 1. Done
    let doneTotal = cur.doneCount
    let plain = cur.plainDone.sorted {
        let ea = $0.task.estimateMin, eb = $1.task.estimateMin
        if ea != eb { return ea > eb }
        if $0.at.ms != $1.at.ms { return $0.at.ms < $1.at.ms }
        return utf16Less($0.task.id, $1.task.id)
    }
    var series: [String: SeriesCount] = [:]
    for o in cur.occDone {
        let id = o.block.taskId ?? ""
        var g = series[id] ?? SeriesCount(id: id, name: reviewCleanName(o.template.name), n: 0)
        g.n += 1
        series[id] = g
    }
    let seriesSorted = series.values.sorted {
        if $0.n != $1.n { return $0.n > $1.n }
        if $0.name != $1.name { return utf16Less($0.name, $1.name) }
        return utf16Less($0.id, $1.id)
    }
    var doneParts: [String] = []
    if !plain.isEmpty {
        let more = plain.count > MAX_TASK_NAMES ? " +\(plain.count - MAX_TASK_NAMES) more" : ""
        doneParts.append("\(plural(plain.count, "task")) — \(plain.prefix(MAX_TASK_NAMES).map { q($0.task.name) }.joined(separator: ", "))\(more)")
    }
    if !seriesSorted.isEmpty {
        let more = seriesSorted.count > MAX_SERIES ? " +\(seriesSorted.count - MAX_SERIES) more" : ""
        doneParts.append("\(plural(cur.occDone.count, "repeating check-off")) — \(seriesSorted.prefix(MAX_SERIES).map { "\"\($0.name)\" ×\($0.n)" }.joined(separator: ", "))\(more)")
    }
    lines.append(doneParts.isEmpty ? "Done: nothing marked done." : "Done: \(doneParts.joined(separator: "; plus ")).")

    // 2. Focus
    let n = cur.sessions.count
    if n == 0 {
        lines.append("Focus: no focus sessions logged.")
    } else {
        let longest = cur.sessions.sorted {
            if $0.sec != $1.sec { return $0.sec > $1.sec }
            if $0.end.ms != $1.end.ms { return $0.end.ms < $1.end.ms }
            return utf16Less($0.session.id, $1.session.id)
        }[0]
        if n == 1 {
            lines.append("Focus: 1 session, \(fmtFocusDur(roundedMinutes(cur.focusSec))) on \(q(longest.session.taskName)).")
        } else {
            var line = "Focus: \(n) sessions, \(fmtFocusDur(roundedMinutes(cur.focusSec))) in all, average \(fmtFocusDur(roundedMinutes(cur.focusSec / n))), longest \(fmtFocusDur(roundedMinutes(longest.sec))) on \(q(longest.session.taskName))"
            if n >= 3 {
                // Group by task id (else cleaned name); the name shown is the NEWEST session's.
                let newestFirst = cur.sessions.sorted {
                    $0.end.ms != $1.end.ms ? $0.end.ms > $1.end.ms : utf16Less($0.session.id, $1.session.id)
                }
                var groups: [String: (key: String, name: String, sec: Int)] = [:]
                for s in newestFirst {
                    let key = s.session.taskId.map { "id:\($0)" } ?? "name:\(reviewCleanName(s.session.taskName))"
                    var g = groups[key] ?? (key: key, name: reviewCleanName(s.session.taskName), sec: 0)
                    g.sec += s.sec
                    groups[key] = g
                }
                let top = groups.values.sorted {
                    if $0.sec != $1.sec { return $0.sec > $1.sec }
                    if $0.name != $1.name { return utf16Less($0.name, $1.name) }
                    return utf16Less($0.key, $1.key)
                }[0]
                line += "; most time on \"\(top.name)\" (\(fmtFocusDur(roundedMinutes(top.sec))))"
            }
            lines.append(line + ".")
        }
    }

    // 3. Plan — judged days are from..end, minus today (today isn't over).
    var planRecorded = false
    if let plan = planFacts(data, from: r.from, end: r.end, clipped: r.clipped, nowMs: nowMs) {
        var bits: [String] = []
        if !plan.slipped.isEmpty {
            let items = plan.slipped.prefix(MAX_SLIPPED).map { s in
                s.task.done
                    ? "\(q(s.task.name)) (\(fmtDay(s.planDate, y)), done later)"
                    : "\(q(s.task.name)) (\(fmtDay(s.planDate, y)), still open) [id=\(s.task.id)]"
            }.joined(separator: ", ")
            let more = plan.slipped.count > MAX_SLIPPED ? " +\(plan.slipped.count - MAX_SLIPPED) more" : ""
            bits.append("\(plural(plan.slipped.count, "task")) slipped — \(items)\(more)")
        }
        if !plan.missed.isEmpty {
            let more = plan.missed.count > MAX_SERIES ? " +\(plan.missed.count - MAX_SERIES) more" : ""
            bits.append("\(plural(plan.missedTotal, "repeating day")) missed — \(plan.missed.prefix(MAX_SERIES).map { "\"\($0.name)\" ×\($0.n)" }.joined(separator: ", "))\(more)")
        }
        if plan.skipped > 0 { bits.append("\(plural(plan.skipped, "repeating day")) skipped on purpose") }
        if !plan.deadlines.isEmpty {
            let items = plan.deadlines.prefix(MAX_DEADLINES).map { t in
                "\(q(t.name)) (\(fmtDay(PeriodTime.dayOf(t.dueAt) ?? r.from, y)))"
            }.joined(separator: ", ")
            let more = plan.deadlines.count > MAX_DEADLINES ? " +\(plan.deadlines.count - MAX_DEADLINES) more" : ""
            bits.append("\(plural(plan.deadlines.count, "deadline")) missed — \(items)\(more)")
        }
        planRecorded = plan.planned > 0 || !bits.isEmpty
        if plan.planned > 0 {
            lines.append("Plan: \(plan.doneToPlan) of \(plan.planned) planned done\(bits.isEmpty ? "" : "; " + bits.joined(separator: "; ")).")
        } else if !bits.isEmpty {
            lines.append("Plan: \(bits.joined(separator: "; ")).")
        } else {
            lines.append("Plan: nothing was scheduled in this period.")
        }
    }

    // 4. Still open today (only when the period includes today)
    var stillOpen = 0
    if r.clipped {
        stillOpen = stillOpenOn(data, day: r.end)
        if stillOpen > 0 { lines.append("Still open today: \(plural(stillOpen, "planned item")).") }
    }

    // 5. Also
    var also: [String] = []
    if !cur.created.isEmpty { also.append("added \(plural(cur.created.count, "task"))") }
    if !cur.captures.isEmpty { also.append(plural(cur.captures.count, "capture")) }
    if !cur.pauses.isEmpty {
        var g: [String: Int] = [:]
        for x in cur.pauses {
            let k = hasReviewText(x.reason) ? reviewCleanName(x.reason) : "Other"
            g[k, default: 0] += 1
        }
        let top = g.sorted { $0.value != $1.value ? $0.value > $1.value : utf16Less($0.key, $1.key) }
            .prefix(MAX_PAUSES).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        also.append("pauses: \(top)")
    }
    if r.days >= 2 {
        if let best = busiestDay(cur), best.done >= 2 {
            let fm = roundedMinutes(best.focusSec)
            also.append("busiest day \(fmtDay(best.date, y)) (\(best.done) done\(fm > 0 ? ", \(fmtFocusDur(fm)) focus" : ""))")
        }
        also.append("active \(showedUpDays(cur)) of \(r.days) days")
    }
    // No calendar-event count: Google meetings are per-device local mirrors
    // (never synced), so two devices would disagree (spec §3.8).

    // 6. By area (named areas only; the screen adds a "No area" bar).
    let areas = doneByArea(cur).filter { $0.area != nil }
    let areaLine: String? = areas.isEmpty ? nil
        : "By area: \(areas.prefix(MAX_AREAS).map { "\($0.area!) \($0.count)" }.joined(separator: ", "))."

    // 7. Before that
    let prevRange = fmtRange(r.prevFrom, r.prevTo, y) + (r.clipped ? ", up to the same time" : "")
    let prevDone = prev.doneCount
    let prevEmpty = prevDone == 0 && prev.sessions.isEmpty
    let curMin = roundedMinutes(cur.focusSec), prevMin = roundedMinutes(prev.focusSec)
    let compare = prevEmpty
        ? "Before that (\(prevRange)): nothing done and no focus logged."
        : "Before that (\(prevRange)): done \(doneTotal) vs \(prevDone) (\(signedInt(doneTotal - prevDone))), focus \(fmtFocusDur(curMin)) vs \(fmtFocusDur(prevMin)) (\(signedDur(curMin - prevMin))), sessions \(n) vs \(prev.sessions.count) (\(signedInt(n - prev.sessions.count)))."

    // 8. Notes
    var notes: [String] = []
    if r.period == "this_week" && r.days <= 2 {
        notes.append("note: only \(plural(r.days, "day")) into this week so far — if they meant the week that just ended, call again with period=last_week.")
    }
    if r.period == "this_month" && r.days <= 3 {
        notes.append("note: only \(plural(r.days, "day")) into this month so far — if they meant the month that just ended, call again with period=last_month.")
    }
    if let floor = historyFloor, !floor.isEmpty, utf16Less(r.prevFrom, floor) {
        notes.append("note: this device only holds focus, pause and capture history from \(fmtDay(floor, y)) — anything before then isn't counted.")
    }
    if blocksPartial {
        notes.append("note: this device may be missing some calendar slots (over the 1,000-slot sync limit) — repeating check-offs and plan numbers may be low.")
    }

    // Nothing at all in the period → one explicit line (never "empty week").
    let nothing = doneTotal == 0 && n == 0 && cur.captures.isEmpty && cur.pauses.isEmpty
        && cur.created.isEmpty && stillOpen == 0 && !planRecorded
    var head = nothing
        ? ["\(header.dropLast()): nothing recorded — nothing marked done, no focus sessions, nothing planned or missed, no captures."]
        : lines + (also.isEmpty ? [] : ["Also: \(also.joined(separator: "; "))."]) + (areaLine.map { [$0] } ?? [])
    let tail = (nothing && prevEmpty ? [] : [compare]) + notes
    return capReview(head: &head, tail: tail, areaLine: areaLine)
}

/// Length cap (UTF-16 units): drop By area, then Also, then cut the HEAD
/// (never the tail — the comparison and the notes) and mark the cut with "…".
func capReview(head: inout [String], tail: [String], areaLine: String?, maxChars: Int = PERIOD_REVIEW_MAX_CHARS) -> String {
    func joined() -> String { (head + tail).joined(separator: "\n") }
    var text = joined()
    if text.utf16.count > maxChars, let areaLine { head.removeAll { $0 == areaLine }; text = joined() }
    if text.utf16.count > maxChars { head.removeAll { $0.hasPrefix("Also: ") }; text = joined() }
    if text.utf16.count > maxChars {
        let tailText = tail.joined(separator: "\n")
        let room = max(0, maxChars - 1 - (tailText.isEmpty ? 0 : tailText.utf16.count + 1))
        var units = Array(head.joined(separator: "\n").utf16.prefix(room))
        if let last = units.last, last >= 0xD800, last <= 0xDBFF { units.removeLast() }
        text = String(decoding: units, as: UTF16.self) + "…" + (tailText.isEmpty ? "" : "\n" + tailText)
    }
    return text
}
