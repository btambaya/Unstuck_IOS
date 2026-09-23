// PA moments — the deterministic engine behind the AI gateway's "one calm
// thing at a time" surface. Zero-LLM: every moment is composed from real data
// so it renders instantly and never hallucinates. Register mirrors Brief.swift —
// a good PA's one-two sentences, never guilt-tripping. Port of
// lib/assistant/moments.ts (+ RitualPrefs/RITUAL_LABELS from pa-prefs.ts).
//
// Exactly ONE moment surfaces at a time. Ids are stable per firing (e.g.
// 'evening-sweep:2026-08-29') so a dismissal recorded by the caller sticks
// for that firing window. Every moment's LAST action is a dismiss.
//
// Determinism: no randomness, no wall-clock reads — the clock is state.now and
// the calendar date is state.todayIso, both supplied by the caller. Date math
// is local-timezone safe (LocalDate: parse field-by-field, never a UTC round-trip).

import Foundation

// MARK: - Ritual prefs (pa-prefs.ts)

public enum RitualKey: String, Codable, Sendable, CaseIterable {
    case morning, evening, friday, sunday
}

/// Which recurring PA moments run — itself a personalisation choice. Asked in
/// the interview, changeable in Settings, read by the moments engine.
/// Device-local; morning + evening default ON, the weekly ones opt-in.
/// JSON shape matches the web's `unstuck-pa-rituals` (missing keys → defaults).
public struct RitualPrefs: Codable, Equatable, Sendable {
    public var morning: Bool
    public var evening: Bool
    public var friday: Bool
    public var sunday: Bool

    public static let defaults = RitualPrefs(morning: true, evening: true, friday: false, sunday: false)

    public init(morning: Bool = true, evening: Bool = true, friday: Bool = false, sunday: Bool = false) {
        self.morning = morning
        self.evening = evening
        self.friday = friday
        self.sunday = sunday
    }

    private enum CodingKeys: String, CodingKey { case morning, evening, friday, sunday }

    /// `{ ...DEFAULTS, ...JSON.parse(raw) }` — a partial blob keeps the defaults for what it omits.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RitualPrefs.defaults
        morning = try c.decodeIfPresent(Bool.self, forKey: .morning) ?? d.morning
        evening = try c.decodeIfPresent(Bool.self, forKey: .evening) ?? d.evening
        friday = try c.decodeIfPresent(Bool.self, forKey: .friday) ?? d.friday
        sunday = try c.decodeIfPresent(Bool.self, forKey: .sunday) ?? d.sunday
    }

    public subscript(key: RitualKey) -> Bool {
        get {
            switch key {
            case .morning: return morning
            case .evening: return evening
            case .friday: return friday
            case .sunday: return sunday
            }
        }
        set {
            switch key {
            case .morning: morning = newValue
            case .evening: evening = newValue
            case .friday: friday = newValue
            case .sunday: sunday = newValue
            }
        }
    }
}

public struct RitualLabel: Equatable, Sendable {
    public let key: RitualKey
    public let label: String
    public let sub: String
}

/// Settings / interview copy — verbatim from the web's RITUAL_LABELS.
public let RITUAL_LABELS: [RitualLabel] = [
    RitualLabel(key: .morning, label: "Morning briefing", sub: "Your day, one decision, at your first open"),
    RitualLabel(key: .evening, label: "Evening sweep", sub: "Carry what didn’t happen — no guilt attached"),
    RitualLabel(key: .friday, label: "Friday review", sub: "Your week in three minutes, one question"),
    RitualLabel(key: .sunday, label: "Sunday runway", sub: "A look at next week before it lands on you"),
]

// MARK: - State + output types

public struct MomentState: Sendable {
    public var tasks: [TaskItem]
    public var blocks: [CalBlock]
    public var sessions: [Session]
    public var reasons: [ReasonLog]
    public var facts: [ProfileFact]
    /// Self-reported friction points from onboarding, e.g. ['Starting','Switching'].
    public var struggles: [String]
    /// 'YYYY-MM-DD' (local).
    public var todayIso: String
    /// Wall clock — only its local hours/minutes drive the time gates.
    public var now: Date
    /// Caller persists dismissals keyed by Moment.id.
    public var isDismissed: @Sendable (String) -> Bool

    public init(tasks: [TaskItem] = [], blocks: [CalBlock] = [], sessions: [Session] = [], reasons: [ReasonLog] = [],
                facts: [ProfileFact] = [], struggles: [String] = [], todayIso: String, now: Date,
                isDismissed: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.tasks = tasks
        self.blocks = blocks
        self.sessions = sessions
        self.reasons = reasons
        self.facts = facts
        self.struggles = struggles
        self.todayIso = todayIso
        self.now = now
        self.isDismissed = isDismissed
    }
}

public enum MomentKind: String, Codable, Equatable, Sendable {
    case ritual, notice, relationship
}

/// What tapping an action does — the surface runs it (carry / schedule /
/// create / hand a message to the chat / dismiss).
public enum MomentRun: Codable, Equatable, Sendable {
    case carryTasks(taskIds: [String])
    case schedule(taskId: String, date: String, time: String?)
    case createTask(name: String, estimateMin: Int?)
    case chat(message: String)
    case dismiss
}

public struct MomentAction: Codable, Equatable, Sendable {
    public let label: String
    public let run: MomentRun
    public init(label: String, run: MomentRun) {
        self.label = label
        self.run = run
    }
}

public struct Moment: Equatable, Sendable {
    public let id: String
    public let kind: MomentKind
    public let priority: Int
    /// Same-priority tiebreak weight (the web keeps it on the candidate; exposed here for the surface/tests).
    public let salience: Int
    public let text: String
    public let actions: [MomentAction]

    public init(id: String, kind: MomentKind, priority: Int, salience: Int, text: String, actions: [MomentAction]) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.salience = salience
        self.text = text
        self.actions = actions
    }
}

// MARK: - Local-date + phrase plumbing

private let DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/// "Sat 12 Sept" — how a PA says a near date out loud.
private func fmtDate(_ isoDate: String) -> String {
    let d = LocalDate.parse(isoDate)
    let month = Time.calendar.component(.month, from: d) - 1
    return "\(DAY_SHORT[Time.dayOfWeekJS(d)]) \(Time.dayOfMonth(d)) \(MONTH_SHORT_GB[month])"
}

private func hourOf(_ now: Date) -> Int { Time.calendar.component(.hour, from: now) }
private func minutesOfDay(_ now: Date) -> Int {
    let c = Time.calendar.dateComponents([.hour, .minute], from: now)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

/// Leading name of a fact, profile.ts convention: "Maleek — son, 9" → "Maleek".
private func leadName(_ fact: String) -> String {
    let seps: Set<Character> = ["—", "–", "-"]
    let head = fact.prefix { !$0.isWhitespace && !seps.contains($0) }
    return String(head).trimmingCharacters(in: .whitespaces)
}

/// Whole-word, case-insensitive name match ("Maleek" ≠ "Maleeka").
private func containsName(_ text: String, _ name: String) -> Bool {
    guard let re = NameRegexCache.shared.regex(for: name) else { return false }
    return matches(re, text)
}

private func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
    re.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
}

/// The fixed patterns, compiled ONCE. `pickMoment` runs on every gateway
/// body evaluation; compiling NSRegularExpressions per call was the hot spot.
private enum Re {
    nonisolated(unsafe) static let isoDatePrefix = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}", options: [.caseInsensitive])
    nonisolated(unsafe) static let birthday = try! NSRegularExpression(pattern: "birthday|turning\\s+\\d", options: [.caseInsensitive])
    nonisolated(unsafe) static let gift = try! NSRegularExpression(pattern: "gift|birthday|present", options: [.caseInsensitive])
}

/// Per-name whole-word regexes (`\bMaleek\b`), compiled once per distinct
/// name. Locked: `MomentState` is Sendable, so the engine may run off-main.
/// Bounded — a profile has a handful of people, but a runaway caller must
/// not grow this without limit.
private final class NameRegexCache: @unchecked Sendable {
    static let shared = NameRegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(for name: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[name] = re
        return re
    }
}

// Filler words dropped when lifting the activity out of a block name:
// "Take Maleek to rehearsals" → "rehearsals".
private let FILLER: Set<String> = [
    "to", "the", "a", "an", "for", "at", "with", "in", "on", "of", "and",
    "from", "his", "her", "their", "my", "our", "up",
]

/// The words after `name` in a block title, minus filler; nil if nothing survives.
private func activityAfterName(_ taskName: String, _ name: String) -> String? {
    let words = taskName.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    // `[^\p{L}\p{N}’'-]` stripped from each word.
    func strip(_ w: String) -> String {
        String(w.filter { $0.isLetter || $0.isNumber || $0 == "’" || $0 == "'" || $0 == "-" })
    }
    guard let i = words.firstIndex(where: { strip($0).lowercased() == name.lowercased() }) else { return nil }
    let rest = words[(i + 1)...]
        .map(strip)
        .filter { !$0.isEmpty && !FILLER.contains($0.lowercased()) }
    return rest.isEmpty ? nil : rest.joined(separator: " ")
}

/// Tone dispatch — gentle = soft suggestion, honest = direct, minimal = shortest.
private func byTone(_ tone: Tone, gentle: String, honest: String, minimal: String) -> String {
    switch tone {
    case .gentle: return gentle
    case .honest: return honest
    case .minimal: return minimal
    }
}

private func dismiss(_ label: String = "Not now") -> MomentAction { MomentAction(label: label, run: .dismiss) }

/// JS number → string for a value already rounded to one decimal ("4.5", "5").
private func fmtNum(_ x: Double) -> String { String(format: "%g", x) }

// A candidate is a moment plus a same-priority tiebreak weight (Moment.salience).
private typealias Candidate = Moment

// ════════════════════════════════════════════════════════════════════════════
// RELATIONSHIP (priority 30)
// ════════════════════════════════════════════════════════════════════════════

/// dates-that-matter — a fact carrying a whenIso 3–14 days ahead (2 days out is
/// too late to be useful ahead-of-time nudging territory… it fires at 3, and 15
/// is too early). One id per fact+date, so a dismissal covers the whole window.
private func datesThatMatter(_ state: MomentState, _ tone: Tone) -> Candidate? {
    struct Hit { let fact: ProfileFact; let when: String; let du: Int }
    var hits: [Hit] = []
    for f in state.facts {
        guard let whenIso = f.whenIso, whenIso.count >= 10, matches(Re.isoDatePrefix, whenIso) else { continue }
        let w = String(whenIso.prefix(10))
        let du = LocalDate.daysUntil(state.todayIso, w)
        if du < 3 || du > 14 { continue }
        hits.append(Hit(fact: f, when: w, du: du))
    }
    if hits.isEmpty { return nil }
    // Soonest date first; fact id breaks ties for full determinism.
    hits.sort { a, z in a.du != z.du ? a.du < z.du : a.fact.id < z.fact.id }
    let hit = hits[0]
    let fact = hit.fact, when = hit.when, du = hit.du

    let name = leadName(fact.fact)
    let isBirthday = matches(Re.birthday, fact.fact)

    if isBirthday {
        // Already sorted? An open task naming both the person and the gift/birthday
        // means the PA has nothing to add — stay quiet.
        let covered = state.tasks.contains {
            !$0.done && containsName($0.name, name) && matches(Re.gift, $0.name)
        }
        if covered { return nil }
        return Moment(
            id: "dates-that-matter:\(fact.id):\(when)",
            kind: .relationship,
            priority: 30,
            salience: 100 + (14 - du),
            text: byTone(tone,
                gentle: "\(name)’s birthday is \(fmtDate(when)) — gift sorted?",
                honest: "Straight up: \(name)’s birthday is \(fmtDate(when)) and there’s no gift task yet. Want one?",
                minimal: "\(name)’s birthday — \(fmtDate(when))."),
            actions: [
                MomentAction(label: "Sort the gift", run: .createTask(name: "Get \(name)’s birthday gift", estimateMin: nil)),
                dismiss(),
            ])
    }

    return Moment(
        id: "dates-that-matter:\(fact.id):\(when)",
        kind: .relationship,
        priority: 30,
        salience: 100 + (14 - du),
        text: byTone(tone,
            gentle: "\(fmtDate(when)) — \(fact.fact). Want a task for it?",
            honest: "Straight up: \(fmtDate(when)) is getting close — \(fact.fact). Prepare something?",
            minimal: "\(fmtDate(when)) — \(fact.fact)."),
        actions: [
            MomentAction(label: "Make it a task", run: .createTask(name: String("Prepare: \(fact.fact)".prefix(80)), estimateMin: nil)),
            dismiss(),
        ])
}

/// how-did-it-go — yesterday held a block whose name carries a person we know
/// ("Take Maleek to rehearsals" + fact "Maleek — son…"). One id per block, and
/// the window is only ever yesterday, so it naturally fires once.
private func howDidItGo(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let yesterday = LocalDate.addDays(state.todayIso, -1)
    let people = state.facts
        .filter { $0.category == .person }
        .map { leadName($0.fact) }
        .filter { $0.count >= 2 }
    if people.isEmpty { return nil }

    let hits = state.blocks
        .filter { b in b.date == yesterday && !b.skipped && people.contains { containsName(b.taskName, $0) } }
        .sorted { a, z in a.startTime != z.startTime ? a.startTime < z.startTime : a.id < z.id }
    guard let block = hits.first else { return nil }

    let name = people.first { containsName(block.taskName, $0) }!
    let activity = activityAfterName(block.taskName, name)

    return Moment(
        id: "how-did-it-go:\(block.id)",
        kind: .relationship,
        priority: 30,
        salience: 200, // one-day window — outranks a birthday still ≥3 days out
        text: activity.map { activity in
            byTone(tone,
                gentle: "How did \(name)’s \(activity) go yesterday?",
                honest: "Straight up: how did \(name)’s \(activity) go yesterday?",
                minimal: "\(name)’s \(activity) — how’d it go?")
        } ?? byTone(tone,
            gentle: "How did ‘\(block.taskName)’ go yesterday?",
            honest: "Straight up: how did ‘\(block.taskName)’ go yesterday?",
            minimal: "‘\(block.taskName)’ — how’d it go?"),
        actions: [
            MomentAction(label: "Talk about it", run: .chat(message: "Tell me how it went: \(block.taskName)")),
            dismiss(),
        ])
}

// ════════════════════════════════════════════════════════════════════════════
// RITUALS (priority 20 — pref-gated, one per day each)
// ════════════════════════════════════════════════════════════════════════════

/// first-touch — before noon, with ≥1 open task. The anchor is picked exactly
/// like Brief.swift (first live timed block still ahead, else the day's first
/// block); with nothing on the calendar, the shortest unscheduled task is the
/// lightest way in.
private func firstTouch(_ state: MomentState, _ tone: Tone) -> Candidate? {
    // 05:00–11:59 only: a night owl opening the app at 1am is still on
    // YESTERDAY's evening, not tomorrow's morning (flow review, 2026-08-30).
    let hour = hourOf(state.now)
    if hour >= 12 || hour < 5 { return nil }
    let open = state.tasks.filter { !$0.done && $0.recurrence == nil }
    if open.isEmpty { return nil }

    let todayBlocks = liveBlocksToday(state.blocks, todayIso: state.todayIso)

    var text: String
    if !todayBlocks.isEmpty {
        let nowHm = localNowHM(state.now)
        let anchor = anchorBlock(todayBlocks, nowHm: nowHm)!
        // Prefer the task's current name (blocks denormalize it and can go stale).
        let name = state.tasks.first { $0.id == anchor.taskId }?.name ?? anchor.taskName
        let trimmed = anchor.startTime.trimmingCharacters(in: .whitespaces)
        let label = trimmed.isEmpty ? "‘\(name)’" : "‘\(name)’ at \(trimmed)"
        text = byTone(tone,
            gentle: "Morning. \(label) is the anchor — want the day built around it?",
            honest: "Straight up: \(label) is the day’s anchor. Build around it?",
            minimal: "\(label). Build around it?")
    } else {
        // Shortest unscheduled open task; any open task as a last resort.
        let scheduledIds = Set(state.blocks.compactMap { $0.taskId }.filter { !$0.isEmpty })
        let pool = open.filter { !($0.later ?? false) && !scheduledIds.contains($0.id) }
        let from = pool.isEmpty ? open : pool
        var lightest = from[0]
        for t in from where t.estimateMin < lightest.estimateMin { lightest = t }
        text = byTone(tone,
            gentle: "Morning. ‘\(lightest.name)’ (~\(lightest.estimateMin) min) is a light way in — build the day from there?",
            honest: "Straight up: nothing’s timed yet. ‘\(lightest.name)’ (~\(lightest.estimateMin) min) is the lightest way in.",
            minimal: "‘\(lightest.name)’ first? ~\(lightest.estimateMin) min.")
    }

    if state.struggles.contains("Starting") { text += " I’ll give you the first ten minutes." }

    return Moment(
        id: "first-touch:\(state.todayIso)",
        kind: .ritual,
        priority: 20,
        salience: 100,
        text: text,
        actions: [
            MomentAction(label: "Plan my day", run: .chat(message: "Plan my day around the anchor")),
            dismiss(),
        ])
}

/// evening-sweep — from 17:30, offer to carry today's misses forward. Only
/// timed blocks that have already ENDED count as "didn't happen" (a 20:00
/// block at 18:00 is still tonight's plan, and an untimed block can still
/// happen any time). If a leftover has slipped ≥3 times, the sweep names it
/// and adds the shrink path.
private func eveningSweep(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let nowMin = minutesOfDay(state.now)
    if nowMin < 17 * 60 + 30 { return nil }

    let taskById = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var leftovers: [TaskItem] = []
    var seen = Set<String>()
    let missed = state.blocks
        .filter { b in
            b.date == state.todayIso && !b.done && !b.skipped
                && !(b.taskId ?? "").isEmpty && !b.startTime.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .stableSorted { $0.startTime < $1.startTime }
    for b in missed {
        if hmToMin(b.startTime) + b.durationMinutes > nowMin { continue } // still ahead tonight
        guard let task = taskById[b.taskId!], !task.done, !seen.contains(task.id) else { continue }
        seen.insert(task.id)
        leftovers.append(task)
    }
    if leftovers.isEmpty { return nil }

    let n = leftovers.count
    let taskIds = leftovers.map { $0.id }
    let carry = MomentAction(label: "Carry \(n) to tomorrow", run: .carryTasks(taskIds: taskIds))
    let leave = dismiss(n == 1 ? "Leave it" : "Leave them")

    // The honest variant fires on a chronic slipper regardless of tone level —
    // pretending 'Tax form' just "didn't happen today" would be the real unkindness.
    var slipper: TaskItem?
    for t in leftovers {
        let m = t.moveCount ?? 0
        if m >= 3 && m > (slipper?.moveCount ?? 0) { slipper = t }
    }
    if let slipper {
        let m = slipper.moveCount ?? 0
        return Moment(
            id: "evening-sweep:\(state.todayIso)",
            kind: .ritual,
            priority: 20,
            salience: 400,
            text: byTone(tone,
                gentle: "‘\(slipper.name)’ has slipped \(m) times — want to carry it, shrink it, or let it go?",
                honest: "Straight up: ‘\(slipper.name)’ has slipped \(m) times — carry, shrink, or let it go?",
                minimal: "‘\(slipper.name)’: slipped \(m)×. Carry, shrink, or drop?"),
            actions: [
                carry,
                MomentAction(label: "Shrink it", run: .chat(message: "Help me shrink ‘\(slipper.name)’ into a first step")),
                leave,
            ])
    }

    return Moment(
        id: "evening-sweep:\(state.todayIso)",
        kind: .ritual,
        priority: 20,
        salience: 400,
        text: byTone(tone,
            gentle: n == 1
                ? "One thing didn’t happen today — carry it to tomorrow?"
                : "\(countWord(n)) things didn’t happen today — carry them to tomorrow?",
            honest: "Straight up: \(n) \(n == 1 ? "thing" : "things") didn’t happen today. Carry \(n == 1 ? "it" : "them") to tomorrow?",
            minimal: "\(n) left over — carry to tomorrow?"),
        actions: [carry, leave])
}

/// friday-review — Friday from 15:00, once ≥5 focus sessions landed this week.
private func fridayReview(_ state: MomentState, _ tone: Tone) -> Candidate? {
    if LocalDate.dayOfWeek(state.todayIso) != 5 || hourOf(state.now) < 15 { return nil }

    let weekStartIso = LocalDate.mondayOf(state.todayIso)
    let thisWeek = state.sessions.filter { s in
        guard let d = LocalDate.dateOfStamp(s.completedAt) else { return false }
        return d >= weekStartIso && d <= state.todayIso
    }
    if thisWeek.count < 5 { return nil }

    var best = thisWeek[0]
    for s in thisWeek where s.actualSec > best.actualSec { best = s }
    guard let bestAt = LocalTime.parseTimestamp(best.completedAt) else { return nil }
    let day = DAY_NAMES_FULL[Time.dayOfWeekJS(bestAt)]
    let h = hourOf(bestAt)
    let part = h < 12 ? "morning" : h < 18 ? "afternoon" : "evening"
    let n = thisWeek.count

    return Moment(
        id: "friday-review:\(state.todayIso)",
        kind: .ritual,
        priority: 20,
        salience: 300,
        text: byTone(tone,
            gentle: "Week in three minutes? \(n) focus blocks, best run \(day) \(part).",
            honest: "Straight up: \(n) focus blocks this week, best run \(day) \(part). Worth three minutes?",
            minimal: "\(n) focus blocks. Review the week?"),
        actions: [
            MomentAction(label: "Review the week", run: .chat(message: "Let’s do the week review")),
            dismiss(),
        ])
}

/// sunday-runway — Sunday from 16:00, look at next week. An overloaded weekday
/// (>4h scheduled Mon–Fri) wins; otherwise ≥3 unscheduled tasks earn a gentle
/// "rough it out" offer.
private func sundayRunway(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let todayDow = LocalDate.dayOfWeek(state.todayIso)
    if todayDow != 0 || hourOf(state.now) < 16 { return nil }

    let id = "sunday-runway:\(state.todayIso)"

    // Next week's weekdays: Mon (+1) … Fri (+5).
    var heaviest: (dow: Int, load: Int)?
    for offset in 1...5 {
        let date = LocalDate.addDays(state.todayIso, offset)
        let load = state.blocks
            .filter { $0.date == date && !$0.done && !$0.skipped }
            .reduce(0) { $0 + $1.durationMinutes }
        if load > 240 && load > (heaviest?.load ?? 0) { heaviest = ((offset % 7 + todayDow) % 7, load) }
    }
    if let heaviest {
        let day = DAY_NAMES_FULL[heaviest.dow]
        let hrs = Double(jsRound(Double(heaviest.load) / 60 * 10)) / 10
        return Moment(
            id: id, kind: .ritual, priority: 20, salience: 200,
            text: byTone(tone,
                gentle: "\(day) looks wall-to-wall — want to thin it out?",
                honest: "Straight up: \(day) has \(fmtNum(hrs))h scheduled. Thin it out?",
                minimal: "\(day): \(fmtNum(hrs))h. Thin it?"),
            actions: [
                MomentAction(label: "Thin out \(day)", run: .chat(message: "Help me thin out \(day)")),
                dismiss(),
            ])
    }

    let scheduledIds = Set(state.blocks.compactMap { $0.taskId }.filter { !$0.isEmpty })
    let unscheduled = state.tasks.filter {
        !$0.done && !($0.later ?? false) && $0.recurrence == nil && !scheduledIds.contains($0.id)
    }
    if unscheduled.count < 3 { return nil }
    let n = unscheduled.count
    return Moment(
        id: id, kind: .ritual, priority: 20, salience: 200,
        text: byTone(tone,
            gentle: "Rough out next week? \(n) tasks are still unscheduled.",
            honest: "Straight up: \(n) tasks have no slot next week. Rough it out?",
            minimal: "\(n) unscheduled. Rough out next week?"),
        actions: [
            MomentAction(label: "Rough out next week", run: .chat(message: "Let’s rough out next week")),
            dismiss(),
        ])
}

// ════════════════════════════════════════════════════════════════════════════
// NOTICES (priority 10 — at most one surfaces; the strongest wins)
// ════════════════════════════════════════════════════════════════════════════

/// slip-radar — an open task rescheduled ≥3 times. The highest non-dismissed
/// count wins (dismissal is filtered INSIDE the rule so the next-worst slipper
/// can take the slot). The id carries the count, so a dismissal sticks until
/// the task slips again.
private func slipRadar(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let slippers = state.tasks
        .filter { !$0.done && !($0.later ?? false) && ($0.moveCount ?? 0) >= 3 }
        .filter { !state.isDismissed("slip-radar:\($0.id):\($0.moveCount ?? 0)") }
        .sorted { a, z in
            let am = a.moveCount ?? 0, zm = z.moveCount ?? 0
            return am != zm ? am > zm : a.id < z.id
        }
    guard let t = slippers.first else { return nil }

    let n = t.moveCount ?? 0
    let starting = state.struggles.contains("Starting")

    return Moment(
        id: "slip-radar:\(t.id):\(n)",
        kind: .notice,
        priority: 10,
        salience: 300 + n,
        text: starting
            ? byTone(tone,
                gentle: "‘\(t.name)’ has moved \(n) times — starting is the hard part, not the task. Want a 10-minute first step?",
                honest: "Straight up: ‘\(t.name)’ has moved \(n) times. Starting is the hard part, not the task — take a 10-minute first step?",
                minimal: "‘\(t.name)’: moved \(n)×. Starting’s the hard part — take 10 minutes?")
            : byTone(tone,
                gentle: "‘\(t.name)’ has moved \(n) times. Shrink it to a 10-minute step, park it, or let it go?",
                honest: "Straight up: ‘\(t.name)’ has moved \(n) times. Shrink it to a 10-minute step, park it, or let it go?",
                minimal: "‘\(t.name)’: moved \(n)×. Shrink, park, or drop?"),
        actions: [
            MomentAction(label: "Shrink it", run: .chat(message: "Help me shrink ‘\(t.name)’ into a first step")),
            dismiss(),
        ])
}

/// quiet-win — a chronic slipper completed yesterday deserves one calm nod.
private func quietWin(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let yesterday = LocalDate.addDays(state.todayIso, -1)
    let wins = state.tasks
        .filter { $0.done && ($0.moveCount ?? 0) >= 3 && LocalDate.dateOfStamp($0.completedAt) == yesterday }
        .sorted { a, z in
            let am = a.moveCount ?? 0, zm = z.moveCount ?? 0
            return am != zm ? am > zm : a.id < z.id
        }
    guard let t = wins.first else { return nil }

    let n = t.moveCount ?? 0
    return Moment(
        id: "quiet-win:\(t.id):\(yesterday)",
        kind: .notice,
        priority: 10,
        salience: 200 + n,
        text: byTone(tone,
            gentle: "‘\(t.name)’ finally happened after \(n) dodges. That’s the hard kind of done.",
            honest: "Straight up: ‘\(t.name)’ took \(n) dodges and still got done. That’s the hard kind of done.",
            minimal: "‘\(t.name)’ — done after \(n) dodges."),
        actions: [dismiss("Noted")])
}

/// habit-gap — the calendar shows a habit (Patterns.swift) whose next slot is empty.
private func habitGap(_ state: MomentState, _ tone: Tone) -> Candidate? {
    let gaps = patternGaps(
        derivePatterns(state.tasks, state.blocks, todayIso: state.todayIso),
        state.blocks,
        todayIso: state.todayIso)
    if gaps.isEmpty { return nil }
    let soonest = gaps.sorted { a, z in
        if a.dueDate != z.dueDate { return a.dueDate < z.dueDate }
        if a.weeksSeen != z.weeksSeen { return a.weeksSeen > z.weeksSeen }
        return a.taskId < z.taskId
    }
    let gap = soonest[0]
    let day = DAY_NAMES_FULL[gap.dow]

    return Moment(
        id: "habit-gap:\(gap.taskId):\(gap.dueDate)",
        kind: .notice,
        priority: 10,
        salience: 100 + gap.weeksSeen,
        text: byTone(tone,
            gentle: probeQuestion(gap),
            honest: "Straight up: no ‘\(gap.taskName)’ on the calendar for \(day). Book it?",
            minimal: "‘\(gap.taskName)’ \(day) — book it?"),
        actions: [
            MomentAction(label: gap.time.map { "Book \(day) \($0)" } ?? "Book \(day)",
                         run: .schedule(taskId: gap.taskId, date: gap.dueDate, time: gap.time)),
            dismiss(),
        ])
}

// ════════════════════════════════════════════════════════════════════════════
// Selection
// ════════════════════════════════════════════════════════════════════════════

/// The one moment to surface right now, or nil for a quiet gateway.
/// Relationship beats ritual beats notice; within a tier the salience weights
/// above break the tie, then the id — fully deterministic for a given state.
public func pickMoment(_ state: MomentState, prefs: RitualPrefs, tone: Tone) -> Moment? {
    var candidates: [Candidate] = []
    func consider(_ c: Candidate?) {
        if let c, !state.isDismissed(c.id) { candidates.append(c) }
    }

    // Relationship
    consider(howDidItGo(state, tone))
    consider(datesThatMatter(state, tone))

    // Rituals (pref-gated)
    if prefs.morning { consider(firstTouch(state, tone)) }
    if prefs.evening { consider(eveningSweep(state, tone)) }
    if prefs.friday { consider(fridayReview(state, tone)) }
    if prefs.sunday { consider(sundayRunway(state, tone)) }

    // Notices — only the strongest one is ever in the running.
    let notices = [slipRadar(state, tone), quietWin(state, tone), habitGap(state, tone)]
        .compactMap { $0 }
        .filter { !state.isDismissed($0.id) }
        .sorted { a, z in a.salience != z.salience ? a.salience > z.salience : a.id < z.id }
    if let top = notices.first { candidates.append(top) }

    candidates.sort { a, z in
        if a.priority != z.priority { return a.priority > z.priority }
        if a.salience != z.salience { return a.salience > z.salience }
        return a.id < z.id
    }
    return candidates.first
}
