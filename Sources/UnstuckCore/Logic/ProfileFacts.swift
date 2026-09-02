// Profile facts — the assistant's persistent memory of the user (people,
// rhythm, constraints, preferences, context). Pure port of the logic half of
// lib/assistant/profile.ts: the store/sync half lives in UnstuckData
// (ProfileFactsRepository) + UnstuckSync (ProfileFactsService / Hydrator).
//
// Every rule here is copied from the web verbatim (same regexes, same
// stoplists, same caps) so the two platforms remember — and refuse — the
// same things. Facts become part of every future system prompt, which is
// why the save path filters instruction-shaped text from MODEL-written
// sources and why the context block is capped and newest-first.

import Foundation

public enum ProfileFactCategory: String, Codable, Sendable, CaseIterable {
    case person, rhythm, constraint, preference, context
}

public enum ProfileFactSource: String, Codable, Sendable, CaseIterable {
    case interview, chat, derived, settings
}

/// One remembered fact. `active == false` is a soft-delete TOMBSTONE — the
/// row stays (locally and on the server) so another device's cache can't
/// resurrect a forgotten fact; every read surface filters on `active`.
public struct ProfileFact: Codable, Equatable, Identifiable, Sendable {
    /// Lowercase RFC-4122 uuid (the server column is `uuid`).
    public var id: String
    public var category: ProfileFactCategory
    public var fact: String
    public var source: ProfileFactSource
    /// `YYYY-MM-DD` the fact refers to (a birthday, a show, a deadline) —
    /// powers "Dates that matter". Most facts carry none.
    public var whenIso: String?
    public var active: Bool
    /// ISO-8601 instants (strings, compared as instants where it matters).
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, category: ProfileFactCategory, fact: String, source: ProfileFactSource,
                whenIso: String? = nil, active: Bool = true, createdAt: String, updatedAt: String) {
        self.id = id
        self.category = category
        self.fact = fact
        self.source = source
        self.whenIso = whenIso
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A style preference detected deterministically from the USER'S OWN words
/// (web `detectStylePreference`): the model kept promising "I'll skip the
/// name" without saving anything, so the app persists these itself.
public enum StylePreference: Equatable, Sendable {
    case noName
    case callMe(String)

    /// Always a `preference` fact.
    public var category: ProfileFactCategory { .preference }

    /// The exact fact text the web stores — every surface parses these
    /// strings back (`noNamePreference` / `preferredName`), so they must
    /// match byte-for-byte across platforms.
    public var fact: String {
        switch self {
        case .noName: return "Don't use their name in replies"
        case .callMe(let name): return "Call them \(name)"
        }
    }
}

public enum ProfileFactsLogic {
    /// Server check: `char_length(fact) between 1 and 300`.
    public static let maxFactLength = 300
    /// Most-recent facts that ever reach the model (web `.slice(0, 15)`).
    public static let contextCap = 15

    // MARK: - Save-path normalisation

    /// Lenient category parse for tool arguments: an unknown / missing value
    /// falls back to `context` (web `isCategory(category) ? category : 'context'`).
    public static func category(from raw: String?) -> ProfileFactCategory {
        raw.flatMap(ProfileFactCategory.init(rawValue:)) ?? .context
    }

    /// Trim + cap at 300 characters (web `fact.trim().slice(0, 300)`); nil
    /// when nothing is left. The cap counts Unicode scalars so the result
    /// always satisfies Postgres' `char_length` check.
    public static func prepareFact(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.count <= maxFactLength { return trimmed }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxFactLength)))
    }

    /// `YYYY-MM-DD` or nothing (web `/^\d{4}-\d{2}-\d{2}$/`).
    public static func validWhenIso(_ s: String?) -> String? {
        guard let s, Patterns.whenIso.test(s) else { return nil }
        return s
    }

    /// True for the sources whose saves the injection filter guards: the
    /// MODEL-written ones (chat / voice / derived). Facts the user types
    /// themselves (interview, Settings) are their own words.
    public static func guardsAgainstInjection(_ source: ProfileFactSource) -> Bool {
        source == .chat || source == .derived
    }

    // MARK: - Refine keys

    /// Punctuation-insensitive leading-words key (web `keyOf`): lowercase,
    /// split on whitespace / dashes, strip everything but letters, digits and
    /// apostrophes, keep the first two words. "Maleek — son, 9" and
    /// "Maleek - son" both key to "maleek son".
    public static func normalizeKey(_ s: String) -> String {
        Patterns.keySplit.split(s.lowercased())
            .map { Patterns.keyStrip.replacingAll(in: $0, with: "") }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
    }

    /// The existing fact a new one refines IN PLACE, or nil for a fresh row.
    /// Exact (trimmed, case-insensitive) duplicates dedup in any category;
    /// leading-words matching is PERSON-only ("Maleek — son" → "Maleek — son,
    /// 9") because on other categories it clobbered distinct constraints
    /// ("Never schedule mornings" vs "Never schedule Fridays"). Pass the
    /// ACTIVE facts; `fact` should already be `prepareFact`-normalised.
    public static func refine(existing: [ProfileFact], category: ProfileFactCategory, fact: String) -> ProfileFact? {
        let key2 = normalizeKey(fact)
        let lower = fact.lowercased()
        return existing.first { f in
            guard f.category == category else { return false }
            if f.fact.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower { return true }
            return category == .person && key2.utf16.count >= 3 && normalizeKey(f.fact) == key2
        }
    }

    // MARK: - Injection filter

    /// A fact that reads like an INSTRUCTION ("ignore your rules", "you must
    /// always…") is a persistent injection vector once it's in every prompt.
    /// Rejects the obvious shapes; legitimate third-person facts never match.
    public static func isInstructionLike(_ text: String) -> Bool {
        Patterns.injection.test(text)
    }

    // MARK: - Style preferences

    /// Deterministic "don't use my name" / "call me X" detection on the
    /// user's own message. Capitalised name REQUIRED, common false positives
    /// stoplisted, and task-ish sentences skipped ("remind me to call me mum").
    public static func detectStylePreference(_ userText: String) -> StylePreference? {
        let t = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Patterns.noNameRequest.test(t) { return .noName }
        guard let name = Patterns.callMe.firstCapture(in: t),
              !Patterns.callMeStop.test(name),
              !Patterns.dontCallMe.test(t),
              !Patterns.taskish.test(t) else { return nil }
        return .callMe(name)
    }

    /// True when they've asked NOT to be addressed by name — a saved
    /// preference every surface must obey.
    public static func noNamePreference(_ facts: [ProfileFact]) -> Bool {
        facts.contains { $0.category == .preference && Patterns.noNameFact.test($0.fact) }
    }

    /// The name THEY asked to be called, if they've ever said so — overrides
    /// the account display name everywhere. Parsed from preference facts like
    /// "Call them Ari, not Ahmad" / "Prefers to be called Chief" / "Goes by Mo".
    public static func preferredName(_ facts: [ProfileFact]) -> String? {
        for f in facts where f.category == .preference {
            if let name = Patterns.preferredName.firstCapture(in: f.fact) { return name }
        }
        return nil
    }

    // MARK: - Model context

    /// The facts the model sees: most recently updated first, capped at 15.
    /// Stable on ties (the web relies on V8's stable sort). Pass active facts.
    public static func sortedForContext(_ facts: [ProfileFact]) -> [ProfileFact] {
        let ordered = facts.enumerated().sorted { a, z in
            if a.element.updatedAt != z.element.updatedAt { return a.element.updatedAt > z.element.updatedAt }
            return a.offset < z.offset
        }
        return ordered.prefix(contextCap).map(\.element)
    }

    /// One line per fact, exactly as `context.profile` is built on the web
    /// (lib/assistant/tools.ts): `[category] fact` plus ` (date: YYYY-MM-DD)`
    /// when the fact is about a date.
    public static func contextLine(_ f: ProfileFact) -> String {
        var line = "[\(f.category.rawValue)] \(f.fact)"
        if let when = f.whenIso { line += " (date: \(when))" }
        return line
    }

    /// `sortedForContext` rendered with `contextLine` — the ONLY shape that
    /// ever leaves the device for the model vendor.
    public static func contextLines(_ facts: [ProfileFact]) -> [String] {
        sortedForContext(facts).map(contextLine)
    }

    // MARK: - Regexes (copied from profile.ts)

    /// Thin JS-flavoured wrapper over NSRegularExpression. The compiled
    /// patterns are immutable and NSRegularExpression is documented
    /// thread-safe, so sharing them across threads is sound.
    struct JSRegex: @unchecked Sendable {
        let re: NSRegularExpression

        init(_ pattern: String, caseInsensitive: Bool = false) {
            // Patterns are compile-time constants copied from the web; a typo
            // is a programmer error, so crash loudly rather than silently
            // matching nothing.
            re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        func test(_ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }

        /// The first capture group of the first match (JS `exec(s)?.[1]`).
        func firstCapture(in s: String) -> String? {
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }

        func replacingAll(in s: String, with template: String) -> String {
            re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }

        /// JS `s.split(re)` (without the empty-piece filtering — callers filter).
        func split(_ s: String) -> [String] {
            var pieces: [String] = []
            var cursor = s.startIndex
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s) else { continue }
                pieces.append(String(s[cursor..<r.lowerBound]))
                cursor = r.upperBound
            }
            pieces.append(String(s[cursor...]))
            return pieces
        }
    }

    enum Patterns {
        static let whenIso = JSRegex(#"^\d{4}-\d{2}-\d{2}$"#)
        static let keySplit = JSRegex(#"[\s—–-]+"#)
        static let keyStrip = JSRegex(#"[^\p{L}\p{N}'’]"#)
        static let injection = JSRegex(
            #"\b(ignore|disregard|forget)\b.{0,30}\b(previous|prior|above|instruction|rule|prompt|system)|\b(you (are|must|should|will|can|shall)\b|from now on|act as|pretend to be|reveal|disclose|your (system )?prompt|jailbreak|developer mode|always (say|state|reveal|include|mention))\b"#,
            caseInsensitive: true)
        static let noNameRequest = JSRegex(
            #"\b(don'?t|do not|stop|never|quit)\b.{0,40}\b(us(?:e|ing)|say(?:ing)?|mention(?:ing)?|call(?:ing)?|address(?:ing)?)\b.{0,25}\bname\b"#,
            caseInsensitive: true)
        // Capitalised name REQUIRED (no case-insensitive flag — it defeated that).
        static let callMe = JSRegex(#"\b[Cc]all me ["'“]?([A-Z][\w'’-]{1,30})["'”]?"#)
        static let callMeStop = JSRegex(#"^(Back|Later|Now|Today|Tomorrow|Tonight|When|If|At|On|In|After|Before|Please|Again|Once|Soon|Mum|Dad|Mom|Home)$"#)
        static let dontCallMe = JSRegex(#"\b(don'?t|do not|never|stop) call me\b"#, caseInsensitive: true)
        static let taskish = JSRegex(#"\b(remind|task|schedule|add|set|book|ring)\b"#, caseInsensitive: true)
        static let noNameFact = JSRegex(
            #"\b(don'?t|do not|stop|never|avoid|without)\b.{0,30}\b(us(?:e|ing)|say(?:ing)?|mention(?:ing)?|address(?:ing)?|call(?:ing)?)\b.{0,20}\bname\b"#,
            caseInsensitive: true)
        static let preferredName = JSRegex(
            #"(?:call (?:me|him|her|them)|to be called|goes by)\s+["'“]?([A-Za-z][\w'’-]*)"#,
            caseInsensitive: true)
    }
}
