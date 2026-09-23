// Grounded assistant insights — pure, zero-LLM derivations from the user's
// REAL history (focus sessions, reason logs, interview facts). Each helper
// returns plain strings/numbers the prompt builder can drop in verbatim, so
// the model opens with something true about THIS user instead of generic
// coaching. Port of lib/assistant/insights.ts.
//
// Date math follows the Patterns.swift conventions: local-calendar getters
// for anything user-facing (hours, short dates), never a UTC round-trip for
// display.

import Foundation

public enum Tone: String, Codable, Sendable, CaseIterable {
    case gentle, honest, minimal
}

public struct GoldenHours: Equatable, Sendable {
    /// Local START hours of the band, contiguous, 2–3 entries, e.g. [9, 10].
    public var hours: [Int]
    /// Human phrasing, e.g. 'mornings around 9–11'.
    public var label: String
    /// Fraction (0–1) of focused seconds whose session started inside the band.
    public var share: Double
    /// e.g. 'Deep focus lands best around 9–11am (from 34 real sessions)'.
    public var factText: String

    public init(hours: [Int], label: String, share: Double, factText: String) {
        self.hours = hours
        self.label = label
        self.share = share
        self.factText = factText
    }
}

public struct StruggleProfile: Equatable, Sendable {
    /// First declared struggle, normalized to canonical casing when it matches.
    public var primary: String?
    /// Recent reason logs corroborate the declared struggle (≥5 in 30 days).
    public var confirmed: Bool
    /// One warm context line for the model; nil when nothing was declared.
    public var line: String?
    /// Starting is among the declared struggles → lead with a tiny first step.
    public var offerFirstStep: Bool

    public init(primary: String?, confirmed: Bool, line: String?, offerFirstStep: Bool) {
        self.primary = primary
        self.confirmed = confirmed
        self.line = line
        self.offerFirstStep = offerFirstStep
    }
}

private let MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

private func matches(_ pattern: String, _ text: String) -> Bool {
    // Static literal patterns ported from the web — a typo is a programmer error.
    let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    return re.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
}

// MARK: - goldenHours

/// Time-of-day word for a band, keyed by its FIRST hour.
private func daypart(_ startHour: Int) -> String {
    if startHour >= 5 && startHour <= 7 { return "early mornings" }
    if startHour >= 8 && startHour <= 11 { return "mornings" }
    if startHour >= 12 && startHour <= 14 { return "early afternoons" }
    if startHour >= 15 && startHour <= 16 { return "late afternoons" }
    if startHour >= 17 && startHour <= 20 { return "evenings" }
    return "late nights"
}

/// 9 → 9, 13 → 1, 0/12/24 → 12.
private func hourNum(_ h: Int) -> Int { h % 12 == 0 ? 12 : h % 12 }
/// 24 is midnight — 'am'.
private func meridiem(_ h: Int) -> String { (h < 12 || h == 24) ? "am" : "pm" }

/// '9–11am', '1–4pm', '11am–1pm'. `end` is exclusive, may be 24.
private func fmtRange(_ start: Int, _ end: Int) -> String {
    meridiem(start) == meridiem(end)
        ? "\(hourNum(start))–\(hourNum(end))\(meridiem(end))"
        : "\(hourNum(start))\(meridiem(start))–\(hourNum(end))\(meridiem(end))"
}

/// The user's proven focus window, from the last 60 days of sessions. Each
/// session's START hour (completedAt minus actualSec, local time) is weighted
/// by actualSec — one long deep-work block outvotes a scatter of two-minute
/// dabs. Requires ≥10 qualifying sessions, else nil (don't invent a pattern
/// from noise).
///
/// Band selection: the best contiguous 2-hour window (never wrapping
/// midnight; ties prefer the window whose first hour is heavier, then the
/// earlier start), extended to 3 hours when an adjacent hour genuinely
/// carries weight (≥ a quarter of the 2-hour band).
public func goldenHours(_ sessions: [Session], now: Date) -> GoldenHours? {
    let nowMs = now.timeIntervalSince1970 * 1000
    let windowStart = nowMs - 60 * DAY_MS

    var bins = Array(repeating: 0, count: 24)
    var total = 0
    var count = 0
    for s in sessions {
        guard s.actualSec > 0 else { continue }
        guard let endMs = LocalTime.parseMillis(s.completedAt), endMs >= windowStart, endMs <= nowMs else { continue }
        let start = Date(timeIntervalSince1970: (endMs - Double(s.actualSec) * 1000) / 1000)
        let startHour = Time.calendar.component(.hour, from: start)
        bins[startHour] += s.actualSec
        total += s.actualSec
        count += 1
    }
    if count < 10 || total <= 0 { return nil }

    var start = 0
    var sum = -1
    for h in 0...22 {
        let w = bins[h] + bins[h + 1]
        if w > sum || (w == sum && bins[h] > bins[start]) { start = h; sum = w }
    }

    var hours = [start, start + 1]
    let left = start - 1 >= 0 ? bins[start - 1] : 0
    let right = start + 2 <= 23 ? bins[start + 2] : 0
    let heavier = max(left, right)
    if heavier > 0 && Double(heavier) >= Double(sum) / 4 {
        hours = left >= right ? [start - 1, start, start + 1] : [start, start + 1, start + 2]
    }

    let bandSum = hours.reduce(0) { $0 + bins[$1] }
    let first = hours[0]
    let end = hours[hours.count - 1] + 1   // exclusive — [9,10] reads 9–11
    return GoldenHours(
        hours: hours,
        label: "\(daypart(first)) around \(first)–\(end)",
        share: Double(bandSum) / Double(total),
        factText: "Deep focus lands best around \(fmtRange(first, end)) (from \(count) real sessions)")
}

// MARK: - struggleProfile

private let CANONICAL_STRUGGLES = ["Starting", "Sustaining", "Switching", "Stopping", "Recovering"]

private let STRUGGLE_LINES: [String: String] = [
    "Starting": "Their hard part is Starting — offer a tiny first step before anything else.",
    "Sustaining": "Their hard part is Sustaining — keep the session small and check in before the energy fades.",
    "Switching": "Their hard part is Switching — help them come back to one thing instead of adding another.",
    "Stopping": "Their hard part is Stopping — give clear permission to wrap up and call it done.",
    "Recovering": "Their hard part is Recovering — make restarting feel tiny, with zero guilt about the gap.",
]

/// Does one reason log corroborate the given struggle? Deliberately simple
/// keyword/action heuristics — evidence, not diagnosis: many switch/distraction
/// logs look like Switching; long pause durations look like Sustaining.
private func corroborates(_ struggle: String, _ log: ReasonLog) -> Bool {
    switch struggle {
    case "Starting":
        return matches("start|begin|procrastinat|put(ting)?\\s+(it\\s+)?off|avoid|dread|blank", log.reason)
    case "Sustaining":
        return (log.action == .pause && (log.durationSec ?? 0) >= 300)
            || matches("tired|drain|energy|steam|fatigue|fad(ed|ing)|lost focus|can'?t focus", log.reason)
    case "Switching":
        return log.action == .switch
            || matches("distract|switch|rabbit\\s*hole|jump|shiny|another (task|thing|idea)", log.reason)
    case "Stopping":
        return matches("stop|kept going|one more|overr[au]n|ran (way )?over|too long|hyperfocus", log.reason)
    case "Recovering":
        return matches("resum|recover|restart|re-?engag|get(ting)? back|com(e|ing) back|warm(ing)? up", log.reason)
    default:
        return false
    }
}

/// The user's declared friction point, cross-checked against what their last
/// 30 days of reason logs actually show. `confirmed` needs ≥5 corroborating
/// logs — a single bad Tuesday isn't a pattern. `now` defaults to the wall
/// clock (the web reads `Date.now()`).
public func struggleProfile(_ struggles: [String], _ reasons: [ReasonLog], now: Date = Date()) -> StruggleProfile {
    let declared = struggles.first?.trimmingCharacters(in: .whitespaces) ?? ""
    let offerFirstStep = struggles.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "starting" }
    if declared.isEmpty { return StruggleProfile(primary: nil, confirmed: false, line: nil, offerFirstStep: offerFirstStep) }

    let primary = CANONICAL_STRUGGLES.first { $0.lowercased() == declared.lowercased() } ?? declared
    let cutoff = now.timeIntervalSince1970 * 1000 - 30 * DAY_MS
    let corroborating = reasons.filter { r in
        guard let at = LocalTime.parseMillis(r.at) else { return false }
        return at >= cutoff && corroborates(primary, r)
    }
    return StruggleProfile(
        primary: primary,
        confirmed: corroborating.count >= 5,
        line: STRUGGLE_LINES[primary] ?? "Their hard part is \(primary) — meet them there before anything else.",
        offerFirstStep: offerFirstStep)
}

// MARK: - toneFromFacts

/// Nudge tone from the interview's style-preference fact ('Prefers gentle
/// nudges — suggest, never push' / 'Wants to be kept honest — direct nudges
/// are welcome' / 'Minimal nudging — only speak up when it really matters').
/// Only nudge-flavored facts are considered so an unrelated fact mentioning
/// 'direct' can't hijack the tone. Default: gentle — never harsher than asked.
public func toneFromFacts(_ facts: [(category: String, fact: String)]) -> Tone {
    for f in facts {
        if !matches("nudg", f.fact) && !matches("style|tone|nudge|prefer", f.category) { continue }
        let text = f.fact.lowercased()
        if text.contains("gentle") { return .gentle }
        if text.contains("honest") || text.contains("direct") { return .honest }
        if text.contains("minimal") || text.contains("barely") { return .minimal }
    }
    return .gentle
}

public func toneFromFacts(_ facts: [ProfileFact]) -> Tone {
    toneFromFacts(facts.map { (category: $0.category.rawValue, fact: $0.fact) })
}

// MARK: - quietWinLine

/// One line celebrating a much-rescheduled task finally getting done —
/// acknowledging the dodges without shame. nil under 3 moves: an ordinary
/// completion doesn't need a backstory.
public func quietWinLine(taskName: String, moveCount: Int, tone: Tone) -> String? {
    if moveCount < 3 { return nil }
    switch tone {
    case .honest:
        return "That’s “\(taskName)” done after \(moveCount) dodges. The hard kind of done."
    case .minimal:
        return "“\(taskName)” — done, after \(moveCount) tries."
    case .gentle:
        return "“\(taskName)” finally happened — it dodged you \(moveCount) times, and you got it anyway."
    }
}

// MARK: - factCitation

/// '“Mornings are the good hours” (you told me 12 Aug)'. Date-only strings
/// parse as LOCAL midnight (never UTC, which shifts a day west of Greenwich);
/// full timestamps render via local getters.
public func factCitation(fact: String, createdAt: String) -> String {
    guard let d = LocalTime.parseTimestamp(createdAt) else { return "“\(fact)”" }
    let month = Time.calendar.component(.month, from: d) - 1
    return "“\(fact)” (you told me \(Time.dayOfMonth(d)) \(MONTHS[month]))"
}

public func factCitation(_ f: ProfileFact) -> String {
    factCitation(fact: f.fact, createdAt: f.createdAt)
}
