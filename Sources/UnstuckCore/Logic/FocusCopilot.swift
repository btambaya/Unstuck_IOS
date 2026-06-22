// FocusCopilot — the pure decision core of the "Hands-Free Focus Copilot"
// (Phase 1: proactive SPOKEN progress alerts + hands-free voice replies,
// 100% on-device, ZERO LLM/network). Everything here is a pure function:
// no clocks, no audio, no speech, no network — so the cadence rules and
// the keyword command parser are deterministic and unit-tested exactly
// like FocusTimer, and identical across iOS / Android / web.
//
// The App layer (FocusCopilotController) owns the ticking clock, the TTS
// speaker, the short on-device STT window, and the AmbientAudio duck — it
// asks this module *what* to say/do, never *how*.
//
// Milestones key off ACCUMULATED focus seconds (paused time excluded), not
// wall clock, and each fires at most once (tracked by the caller in a set of
// already-fired milestones). OVERRUN re-checks every +5 min while over (cap
// 2 re-checks) and is suppressed once the user chose "keep going".

import Foundation

// MARK: - Milestones

/// A point in a focus block where the copilot has something to say. The
/// raw values double as the `alreadyFired` keys (OVERRUN re-checks append the
/// re-check index so each of the (max 2) re-checks fires once).
public enum FocusMilestone: Equatable, Sendable {
    /// Coach only, E >= 20: "Halfway there…".
    case halfway
    /// Balanced+ , E > 10: "Five minutes left…".
    case tMinus5
    /// Every level: "That's your block…".
    case atTime
    /// Coach only: every +5 min past the estimate, capped at 2 re-checks.
    /// `index` is 1 or 2 (the 1st / 2nd re-check).
    case overrun(index: Int)

    /// Stable string used as the `alreadyFired` membership key.
    public var key: String {
        switch self {
        case .halfway: return "halfway"
        case .tMinus5: return "tMinus5"
        case .atTime: return "atTime"
        case .overrun(let i): return "overrun.\(i)"
        }
    }

    /// True for milestones that open a listening window for a voice reply
    /// (they ask a question). HALFWAY is speak-only.
    public var asksQuestion: Bool {
        switch self {
        case .halfway: return false
        case .tMinus5, .atTime, .overrun: return true
        }
    }
}

/// The most-proactive milestones, in firing order, for a level. Used by the
/// scheduler + the tests; OVERRUN re-checks are computed separately.
public extension NotificationLevel {
    /// The non-overrun milestones this level enables for an estimate of
    /// `estimateMin` minutes (the gates: HALFWAY needs E>=20 + Coach; T-5
    /// needs E>10 + Balanced/Coach; AT_TIME always; E<=5 → AT_TIME only).
    func copilotMilestones(estimateMin: Int) -> [FocusMilestone] {
        // E <= 5 collapses to AT_TIME only at every level.
        if estimateMin <= 5 { return [.atTime] }
        var out: [FocusMilestone] = []
        if self == .coach && estimateMin >= 20 { out.append(.halfway) }
        if self != .calm && estimateMin > 10 { out.append(.tMinus5) }
        out.append(.atTime)
        return out
    }

    /// Whether this level re-checks during overrun (Coach only).
    var copilotOverrunRechecks: Bool { self == .coach }
}

/// The maximum number of OVERRUN re-checks (Coach), after AT_TIME.
public let FOCUS_COPILOT_OVERRUN_CAP = 2
/// Seconds between OVERRUN re-checks.
public let FOCUS_COPILOT_OVERRUN_STEP_SEC = 5 * 60

public enum FocusCopilot {

    /// The single milestone due RIGHT NOW given the accumulated focus seconds,
    /// or nil. `focusedSec` is the ACCUMULATED focus time (paused excluded).
    /// `alreadyFired` is the set of milestone keys already spoken this session.
    /// `keepGoing` suppresses all OVERRUN re-checks (the user opted to keep
    /// going at a prior prompt).
    ///
    /// Pure: the same inputs always return the same milestone. Returns the
    /// EARLIEST not-yet-fired milestone whose threshold the focus time has
    /// reached, so a tick that jumps past several thresholds still surfaces
    /// them one at a time (the caller marks each fired, then re-asks).
    public static func dueMilestone(
        estimateMin E: Int,
        level: NotificationLevel,
        focusedSec: Int,
        alreadyFired: Set<String>,
        keepGoing: Bool = false
    ) -> FocusMilestone? {
        let estimateSec = max(0, E) * 60

        // Fixed (non-overrun) milestones, in firing order.
        for m in level.copilotMilestones(estimateMin: E) where !alreadyFired.contains(m.key) {
            if let threshold = thresholdSec(m, estimateSec: estimateSec), focusedSec >= threshold {
                return m
            }
        }

        // OVERRUN re-checks: Coach only, E > 5 (E<=5 → AT_TIME only at any
        // level), AT_TIME must have fired, not keepGoing.
        guard level.copilotOverrunRechecks, E > 5, !keepGoing,
              alreadyFired.contains(FocusMilestone.atTime.key) else { return nil }
        for i in 1...FOCUS_COPILOT_OVERRUN_CAP {
            let m = FocusMilestone.overrun(index: i)
            if alreadyFired.contains(m.key) { continue }
            let threshold = estimateSec + i * FOCUS_COPILOT_OVERRUN_STEP_SEC
            if focusedSec >= threshold { return m }
            // Re-checks are ordered: don't skip ahead to #2 before #1 is due.
            break
        }
        return nil
    }

    /// Focus-seconds threshold at which a fixed milestone becomes due, or nil
    /// if the milestone is gated out for this estimate.
    private static func thresholdSec(_ m: FocusMilestone, estimateSec: Int) -> Int? {
        switch m {
        case .halfway: return estimateSec / 2
        case .tMinus5: return max(0, estimateSec - 5 * 60)
        case .atTime: return estimateSec
        case .overrun: return nil   // handled separately
        }
    }

    // MARK: - Spoken lines

    /// The spoken line for a milestone. `{n}` is whole minutes:
    ///  • HALFWAY uses minutes LEFT (estimate − focused, floored, ≥ 0).
    ///  • OVERRUN uses minutes OVER (focused − estimate, floored, ≥ 0).
    /// T-5 / AT_TIME are fixed strings.
    public static func line(for m: FocusMilestone, estimateMin E: Int, focusedSec: Int) -> String {
        switch m {
        case .halfway:
            let leftMin = max(0, (max(0, E) * 60 - focusedSec) / 60)
            return "Halfway there — about \(leftMin) minutes left."
        case .tMinus5:
            return "Five minutes left. Want to wrap up, or add time?"
        case .atTime:
            return "That's your block. Add five, stop, or keep going?"
        case .overrun:
            let overMin = max(0, (focusedSec - max(0, E) * 60) / 60)
            return "You're \(overMin) minutes over. Stop here, or keep going?"
        }
    }

    // MARK: - Push-to-talk capture (Phase 1.5)

    /// Normalize a dictated transcript into a verbatim capture body, or nil if
    /// there's nothing to save. PURE: trims surrounding whitespace/newlines and
    /// returns nil for a blank/empty transcript; otherwise returns the trimmed
    /// text UNCHANGED — it is NEVER parsed as a command (so "I should stop
    /// procrastinating" is saved verbatim, never read as a stop). This is the
    /// whole contract of push-to-talk capture: dictation, not commands.
    public static func captureFromTranscript(_ transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Voice command parsing (keyword match, NO LLM)

/// A hands-free command parsed from an utterance. Pure keyword matching —
/// never an LLM, never a network call.
public enum FocusCommand: Equatable, Sendable {
    /// Stop / finish the session.
    case stop
    /// Add `minutes` to the block (clamped 1...120).
    case extend(minutes: Int)
    /// "keep going" / "in the zone" / "not yet" — stay focused, suppress nags.
    case keepGoing
    /// Capture `text` verbatim as a parked thought.
    case capture(text: String)
    /// Nothing recognised (or empty).
    case none
}

public enum FocusCommandParser {

    /// Parse an utterance into a `FocusCommand`. Case-insensitive keyword
    /// match with a fixed priority:
    ///   1. stop      ← stop | done | finish | end | stop here | that's it
    ///   2. extend(n) ← (add|extend|give me) + a number word/digit;
    ///                  "add time"/"more time" → 5; keep-going phrases → keepGoing
    ///   3. capture   ← prefix capture|note|remember|remind me|add a task → remainder
    ///   4. none      ← otherwise / empty
    /// `extend` n is clamped to 1...120.
    public static func parse(_ utterance: String) -> FocusCommand {
        let raw = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .none }
        let lower = raw.lowercased()

        // ── (1) stop. Check the multi-word "stop here" / "that's it" first, then
        //    the single-word synonyms as whole words.
        if containsPhrase(lower, "stop here") || containsPhrase(lower, "that's it") || containsPhrase(lower, "thats it") {
            return .stop
        }
        for w in ["stop", "done", "finish", "end"] where containsWord(lower, w) {
            return .stop
        }

        // ── (2) keep-going (a flavour of "extend": stay in the block, suppress
        //    nags). Checked before the numeric extend so "keep going" never
        //    falls through to capture.
        if containsPhrase(lower, "keep going") || containsPhrase(lower, "in the zone") || containsPhrase(lower, "not yet") {
            return .keepGoing
        }

        // ── (2) numeric extend. "add time" / "more time" → 5; otherwise look for
        //    a verb (add | extend | give me) and a number.
        let hasExtendVerb = containsWord(lower, "add") || containsWord(lower, "extend")
            || containsPhrase(lower, "give me") || containsWord(lower, "more")
        if containsPhrase(lower, "add time") || containsPhrase(lower, "more time") {
            return .extend(minutes: 5)
        }
        if hasExtendVerb, let n = firstNumber(in: lower) {
            return .extend(minutes: clampMinutes(n))
        }

        // ── (3) capture. A recognised prefix; the remainder (verbatim from the
        //    ORIGINAL casing) is the capture body.
        for prefix in ["capture", "note", "remember", "remind me", "add a task"] {
            if let body = stripPrefix(raw, prefix) {
                return .capture(text: body)
            }
        }

        // ── (4) nothing recognised.
        return .none
    }

    /// Clamp an extend amount to the supported 1...120 minute range.
    public static func clampMinutes(_ n: Int) -> Int { min(120, max(1, n)) }

    // MARK: matching helpers

    /// True if `haystack` contains `word` as a whole word (word-boundary match,
    /// so "stop" matches "stop now" but not "nonstop").
    private static func containsWord(_ haystack: String, _ word: String) -> Bool {
        tokens(haystack).contains(word)
    }

    /// True if `haystack` contains the multi-word `phrase` as a contiguous
    /// run of whole tokens.
    private static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        let h = tokens(haystack)
        let p = phrase.split(separator: " ").map(String.init)
        guard !p.isEmpty, h.count >= p.count else { return false }
        for start in 0...(h.count - p.count) where Array(h[start..<start + p.count]) == p {
            return true
        }
        return false
    }

    /// Split into lowercase word tokens, treating any non-alphanumeric (except
    /// an in-word apostrophe) as a separator. Keeps "that's" intact.
    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                cur.append(ch)
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The first number in the utterance, as a digit ("10") or a number word
    /// ("ten"). Returns nil if none.
    private static func firstNumber(in lower: String) -> Int? {
        for tok in tokens(lower) {
            if let n = Int(tok) { return n }
            if let n = numberWords[tok] { return n }
        }
        return nil
    }

    /// Number words 1...20 + common round tens (matches the spec's
    /// five/ten/fifteen/twenty… vocabulary, with a little headroom).
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// If `raw` starts with `prefix` (case-insensitive, on a word boundary),
    /// return the remainder VERBATIM (original casing, trimmed). The remainder
    /// must be non-empty — a bare "note" with nothing after it isn't a capture.
    private static func stripPrefix(_ raw: String, _ prefix: String) -> String? {
        let lowerRaw = raw.lowercased()
        let lowerPrefix = prefix.lowercased()
        guard lowerRaw.hasPrefix(lowerPrefix) else { return nil }
        let after = raw.index(raw.startIndex, offsetBy: prefix.count)
        // The char right after the prefix must be a boundary (space/punct/end),
        // so "remembering" doesn't match the "remember" prefix.
        if after < raw.endIndex {
            let next = raw[after]
            guard !(next.isLetter || next.isNumber) else { return nil }
        }
        // Drop a leading filler/punct ("to", "that", ":", ",") so
        // "remind me to call Sam" captures "call Sam".
        var rest = String(raw[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":,-—"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for filler in ["to ", "that ", "about "] where rest.lowercased().hasPrefix(filler) {
            rest = String(rest.dropFirst(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return rest.isEmpty ? nil : rest
    }
}

// MARK: - Effects (the intent of acting on a command / milestone)

/// The intent of acting on a command — what the App layer should do to the
/// session, plus the spoken acknowledgement. NO effect deletes data.
/// `FocusCommand.none` and `.keepGoing`/`.stop`/etc. all map here; the
/// controller runs the side effect (extend/keepGoing/finish/save) then speaks
/// `ack`.
public enum FocusEffect: Equatable, Sendable {
    /// Extend the block by `minutes`, recompute overrun, ack.
    case extend(minutes: Int)
    /// Set the no-re-nag flag (suppress OVERRUN), ack.
    case keepGoing
    /// Finish the session, ack.
    case stop
    /// Save a verbatim capture (with the session id), ack.
    case capture(text: String)
    /// Nothing to do (unrecognised) — no ack.
    case none

    /// The spoken acknowledgement, or nil for `.none`.
    public var ack: String? {
        switch self {
        case .extend(let n): return "Added \(n) minutes."
        case .keepGoing: return "Okay, keep going."
        case .stop: return "Nice work."
        case .capture: return "Got it."
        case .none: return nil
        }
    }
}

public extension FocusCommand {
    /// Map a parsed command to its effect (1:1; kept separate so the App layer
    /// has a single value to switch on and so the ack copy is testable).
    var effect: FocusEffect {
        switch self {
        case .stop: return .stop
        case .extend(let n): return .extend(minutes: FocusCommandParser.clampMinutes(n))
        case .keepGoing: return .keepGoing
        case .capture(let t): return .capture(text: t)
        case .none: return .none
        }
    }
}
