// Reply polish — a DETERMINISTIC layer over the model's FINAL chat text.
// Port of lib/assistant/polish.ts, rule for rule, so the web vectors hold
// on iOS.
//
// Testers said the assistant "sounds unnatural": a "Done —" reflex, "Let me
// know if…" closers, cheering "!" and raw 2026-09-05 / 14:00 tokens echoed
// from tool results. Every attempt to fix that in the system prompt made
// qwen-turbo stop calling tools or lie (naturalness rounds 1–2, 2026-09-05),
// so the register is fixed HERE, on the client, on text only — it cannot
// touch tool calling, and the fabrication guard always sees the raw text.
//
// Rules (all case-insensitive, idempotent, never touching text inside
// quotes / backticks / URLs / id=… tokens, never returning an empty string):
//  1. openers   — strip a leading status tic ("Done —", "Got it.", "Sure,").
//  2. closers   — drop a trailing generic offer ("Let me know if…") when the
//                 reply has ≥2 sentences; keep specific one-question offers.
//  3. "!"       — "!" → "." at sentence end in a confirmation; greetings keep it.
//  4. dates     — 2026-09-05 → "Sat 5 Sep" (year only when not this year),
//                 14:30 → "2:30pm"; standalone tokens only.
//  5. markdown  — **bold** → plain; a single-item bullet list → a sentence.
//  6. whitespace — doubled spaces collapsed, trimmed.
//
// NSRegularExpression (ICU) + UTF-16 offsets throughout, like AssistantGuard,
// so lookaheads and `\b` match the web's JS semantics.

import Foundation

public struct PolishOptions: Sendable {
    /// "Now" for the this-year date rule (tests pin it).
    public var now: Date
    /// Calendar that decides which year "now" is in.
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }
}

/// Polish the model's FINAL chat text. Pure; idempotent; never empty.
public func polishReply(_ text: String, _ opts: PolishOptions = PolishOptions()) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return text }
    var out = ReplyPolish.collapseMarkdown(trimmed)
    out = ReplyPolish.stripOpener(out)
    out = ReplyPolish.stripCloser(out)
    out = ReplyPolish.restrainExclamations(out)
    out = ReplyPolish.speakDatesAndTimes(out, thisYear: opts.calendar.component(.year, from: opts.now))
    out = ReplyPolish.tidyWhitespace(out)
    return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmed : out
}

/// "Sat 5 Sep" — the year only when it is not `thisYear`; nil for an invalid
/// civil date. Locale-agnostic (English abbreviations, `EEE d MMM`).
public func spokenDate(year: Int, month: Int, day: Int, thisYear: Int) -> String? {
    guard (1...12).contains(month), day >= 1, day <= ReplyPolish.daysInMonth(year, month) else { return nil }
    let core = "\(ReplyPolish.days[ReplyPolish.dayOfWeek(year, month, day)]) \(day) \(ReplyPolish.months[month - 1])"
    return year == thisYear ? core : "\(core) \(year)"
}

/// 14:00 → "2pm", 14:30 → "2:30pm", 00:05 → "12:05am".
public func spokenTime(hour: Int, minute: Int) -> String {
    let h12 = hour % 12 == 0 ? 12 : hour % 12
    let suffix = hour < 12 ? "am" : "pm"
    return minute == 0 ? "\(h12)\(suffix)" : "\(h12):\(String(format: "%02d", minute))\(suffix)"
}

// MARK: - implementation

enum ReplyPolish {

    struct Span { let start: Int; let end: Int }   // UTF-16 offsets, end exclusive

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // Static literals ported from the web; a typo is a programmer error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func full(_ s: NSString) -> NSRange { NSRange(location: 0, length: s.length) }

    // ---- protected spans

    // URLs and id=… tokens are never rewritten (a date inside an id is data).
    private static let protectedToken = re("\\bhttps?://\\S+|\\bwww\\.\\S+|\\bids?=\\S+")
    // Balanced quote pairs; a straight apostrophe is NOT a quote (contractions).
    private static let quotePairs: [(String, String)] = [("\"", "\""), ("“", "”"), ("‘", "’"), ("`", "`")]
    private static let quoteChars = re("[\"“”‘’`]", [])

    static func protectedSpans(_ s: NSString) -> [Span] {
        var spans: [Span] = []
        for m in protectedToken.matches(in: s as String, range: full(s)) {
            spans.append(Span(start: m.range.location, end: m.range.location + m.range.length))
        }
        for (open, close) in quotePairs {
            var i = 0
            while i < s.length {
                let a = s.range(of: open, options: [.literal], range: NSRange(location: i, length: s.length - i))
                if a.location == NSNotFound { break }
                let from = a.location + a.length
                let b = s.range(of: close, options: [.literal], range: NSRange(location: from, length: s.length - from))
                if b.location == NSNotFound { break }   // an unmatched opener protects nothing
                spans.append(Span(start: a.location, end: b.location + b.length))
                i = b.location + b.length
            }
        }
        return spans
    }

    private static func inSpan(_ i: Int, _ spans: [Span]) -> Bool {
        spans.contains { i >= $0.start && i < $0.end }
    }

    // ---- sentences

    private static func isSpace(_ c: unichar) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(u)
    }

    /// Trimmed sentence spans. Boundaries: ".", "!", "?" (a run of them, plus a
    /// closing bracket) OUTSIDE protected spans and followed by whitespace/end —
    /// not a decimal point — and every line break.
    static func sentenceSpans(_ s: NSString, _ spans: [Span]) -> [Span] {
        var out: [Span] = []
        var start = 0
        let n = s.length
        func space(_ i: Int) -> Bool { i >= 0 && i < n && isSpace(s.character(at: i)) }
        func digit(_ i: Int) -> Bool { i >= 0 && i < n && (48...57).contains(s.character(at: i)) }
        func push(_ end: Int) {
            var a = start, b = end
            while a < b && space(a) { a += 1 }
            while b > a && space(b - 1) { b -= 1 }
            if b > a { out.append(Span(start: a, end: b)) }
            start = end
        }
        var i = 0
        while i < n {
            let c = s.character(at: i)
            if c == 10 { push(i); start = i + 1; i += 1; continue }              // "\n"
            if (c == 46 || c == 33 || c == 63) && !inSpan(i, spans) {          // . ! ?
                if c == 46 && digit(i - 1) && digit(i + 1) { i += 1; continue }
                var j = i
                while j + 1 < n, [46, 33, 63].contains(s.character(at: j + 1)), !inSpan(j + 1, spans) { j += 1 }
                while j + 1 < n, [41, 93].contains(s.character(at: j + 1)) { j += 1 }   // ) ]
                if j + 1 >= n || space(j + 1) { push(j + 1); i = j }
            }
            i += 1
        }
        push(n)
        return out
    }

    // ---- 5. markdown residue

    private static let bold = re("\\*\\*([^*\\n]+?)\\*\\*", [])
    private static let boldUnderscore = re("__([^_\\n]+?)__", [])
    private static let bullet = re("^\\s*(?:[-*•]|\\d+[.)])\\s+", [])
    private static let terminated = re("[.!?…]$", [])

    private static func unwrap(_ s: String, _ rx: NSRegularExpression) -> String {
        let ns = s as NSString
        let spans = protectedSpans(ns)
        let out = NSMutableString(string: s)
        for m in rx.matches(in: s, range: full(ns)).reversed() where !inSpan(m.range.location, spans) {
            out.replaceCharacters(in: m.range, with: ns.substring(with: m.range(at: 1)))
        }
        return out as String
    }

    static func collapseMarkdown(_ s: String) -> String {
        var out = unwrap(unwrap(s, bold), boldUnderscore)
        // A one-item list is a sentence that lost its way; multi-item lists stay.
        var lines = out.components(separatedBy: "\n")
        let bullets = lines.indices.filter { bullet.firstMatch(in: lines[$0], range: full(lines[$0] as NSString)) != nil }
        if bullets.count == 1 {
            let i = bullets[0]
            var item = bullet.stringByReplacingMatches(in: lines[i], range: full(lines[i] as NSString), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty, terminated.firstMatch(in: item, range: full(item as NSString)) == nil { item += "." }
            var p = i - 1
            while p >= 0 && lines[p].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p -= 1 }
            if p >= 0 {
                lines[p] = trimEnd(lines[p]) + " " + item
                lines.removeSubrange((p + 1)...i)
            } else {
                lines[i] = item
            }
            out = lines.joined(separator: "\n")
        }
        return out
    }

    private static func trimEnd(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return String(out)
    }

    // ---- 1. openers

    private static let opener = re("^(?:all\\s+)?(?:done|got\\s+it|sure(?:\\s+thing)?|alright|all\\s+right|okay|ok|great|perfect|absolutely|certainly|of\\s+course|no\\s+problem)\\s*[—–\\-:,.!]+\\s*")

    private static func capitaliseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        let up = String(first).uppercased()
        return up == String(first) ? s : up + s.dropFirst()
    }

    static func stripOpener(_ s: String) -> String {
        var out = s
        for _ in 0..<3 {
            let ns = out as NSString
            guard let m = opener.firstMatch(in: out, range: full(ns)) else { break }
            let rest = ns.substring(from: m.range.length)
            if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }   // "Done." alone stays a reply
            out = rest
        }
        return out == s ? s : capitaliseFirst(out)
    }

    // ---- 2. closers

    private static let closer = re("^(?:and\\s+|so\\s+|but\\s+)?(?:let me know|just let me know|just say|just ask|just tell me|feel free|if you'?d like|if you would like|if you want|if you need|if there'?s anything|anything else|is there anything else|need anything else|happy to help|hope that helps|hope this helps|want me to|would you like me to|do you want me to|shall i)\\b")

    // A closer that names a day / time is a real offer, not a tic.
    private static let specific = re("\\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|today|tomorrow|tonight|noon|midnight|morning|afternoon|evening)\\b|\\b\\d{1,2}(?::\\d{2})?\\s*(?:am|pm)\\b|\\b\\d{1,2}:\\d{2}\\b|\\b\\d{4}-\\d{2}-\\d{2}\\b|\\b\\d{1,2}\\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\b")

    // Words a generic "anything else?" is built from. A "?" offer made ONLY of
    // these is dropped; one with a real object ("the report", "the calendar") stays.
    private static let filler: Set<String> = Set(("a an the and or to with for of on in at it that this these those them me you your i "
        + "can could would should will want wants need needs needed like help helping assist assistance anything something "
        + "else more further other another any some all just also too if whether when what how about adjust adjusting "
        + "adjustments change changes changing tweak tweaks tweaking edit edits update updates do done know let say feel free "
        + "ask questions question happy hope helps glad here there is are be have has please sure okay ok go ahead now next "
        + "again thing things stuff otherwise ready wish shall details detail "
        + "there's that's it's i'd i'll i'm you'd you'll you're").split(separator: " ").map(String.init))
    private static let nonWord = re("[^a-z'\\s]", [])

    private static func isGenericOffer(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        let cleaned = nonWord.stringByReplacingMatches(in: lowered, range: full(lowered as NSString), withTemplate: " ")
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return words.allSatisfy { filler.contains($0) }
    }

    private static func shouldDropCloser(_ sentence: String) -> Bool {
        let ns = sentence as NSString
        if closer.firstMatch(in: sentence, range: full(ns)) == nil { return false }
        if quoteChars.firstMatch(in: sentence, range: full(ns)) != nil { return false }   // names a task/list/date
        if specific.firstMatch(in: sentence, range: full(ns)) != nil { return false }
        if sentence.hasSuffix("?") && !isGenericOffer(sentence) { return false }
        return true
    }

    static func stripCloser(_ s: String) -> String {
        var out = s
        for _ in 0..<3 {
            let ns = out as NSString
            let sentences = sentenceSpans(ns, protectedSpans(ns))
            if sentences.count < 2 { break }
            let last = sentences[sentences.count - 1]
            if !shouldDropCloser(ns.substring(with: NSRange(location: last.start, length: last.end - last.start))) { break }
            out = trimEnd(ns.substring(to: last.start))
        }
        return out
    }

    // ---- 3. exclamation restraint

    private static let confirmVerb = re("\\b(?:added|scheduled|rescheduled|moved|booked|skipped|saved|noted|removed|created|updated|reopened|cancelled|canceled|blocked|captured|deleted|completed|renamed|started|set|ticked|unticked|unscheduled|shared|paused|resumed|extended|cleared|marked|archived|logged|done)\\b")
    private static let greeting = re("^(?:hi|hey|hello|welcome|good\\s+(?:morning|afternoon|evening)|morning|afternoon|evening|happy)\\b")
    private static let trailingBang = re("!+$", [])

    static func restrainExclamations(_ s: String) -> String {
        let ns = s as NSString
        if confirmVerb.firstMatch(in: s, range: full(ns)) == nil { return s }
        let sentences = sentenceSpans(ns, protectedSpans(ns))
        let out = NSMutableString(string: s)
        for sent in sentences.reversed() {   // edit from the end: earlier offsets stay valid
            let t = ns.substring(with: NSRange(location: sent.start, length: sent.end - sent.start))
            guard let bang = trailingBang.firstMatch(in: t, range: full(t as NSString)),
                  greeting.firstMatch(in: t, range: full(t as NSString)) == nil else { continue }
            out.replaceCharacters(in: NSRange(location: sent.start + bang.range.location, length: bang.range.length), with: ".")
        }
        return out as String
    }

    // ---- 4. dates and times spoken

    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// 0 = Sunday. Pure civil-date arithmetic (Sakamoto), no time zone.
    static func dayOfWeek(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let yy = m < 3 ? y - 1 : y
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        if m == 2 { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28 }
        return [4, 6, 9, 11].contains(m) ? 30 : 31
    }

    // Standalone only: not glued to letters/digits/ids.
    private static let date = re("(^|[^A-Za-z0-9_/=-])(\\d{4})-(\\d{2})-(\\d{2})(?![A-Za-z0-9_/-])", [])
    private static let time = re("(^|[^A-Za-z0-9_:/=.-]|[-–—])([01]\\d|2[0-3]):([0-5]\\d)(?![0-9A-Za-z_:]|\\s*[ap]\\.?m\\b)")

    static func speakDatesAndTimes(_ s: String, thisYear: Int) -> String {
        var ns = s as NSString
        var spans = protectedSpans(ns)
        var out = NSMutableString(string: s)
        for m in date.matches(in: s, range: full(ns)).reversed() {
            let pre = m.range(at: 1)
            if inSpan(m.range.location + pre.length, spans) { continue }
            guard let y = Int(ns.substring(with: m.range(at: 2))), let mo = Int(ns.substring(with: m.range(at: 3))),
                  let d = Int(ns.substring(with: m.range(at: 4))),
                  let spoken = spokenDate(year: y, month: mo, day: d, thisYear: thisYear) else { continue }
            out.replaceCharacters(in: m.range, with: ns.substring(with: pre) + spoken)
        }
        let afterDates = out as String
        ns = afterDates as NSString
        spans = protectedSpans(ns)
        out = NSMutableString(string: afterDates)
        for m in time.matches(in: afterDates, range: full(ns)).reversed() {
            let pre = m.range(at: 1)
            if inSpan(m.range.location + pre.length, spans) { continue }
            guard let h = Int(ns.substring(with: m.range(at: 2))), let min = Int(ns.substring(with: m.range(at: 3))) else { continue }
            out.replaceCharacters(in: m.range, with: ns.substring(with: pre) + spokenTime(hour: h, minute: min))
        }
        return out as String
    }

    // ---- 6. whitespace

    private static let doubledSpaces = re("[ \\t]{2,}", [])
    private static let trailingLineSpaces = re("[ \\t]+\\n", [])
    private static let blankRuns = re("\\n{3,}", [])

    static func tidyWhitespace(_ s: String) -> String {
        let ns = s as NSString
        let spans = protectedSpans(ns)
        let out = NSMutableString(string: s)
        for m in doubledSpaces.matches(in: s, range: full(ns)).reversed() where !inSpan(m.range.location, spans) {
            out.replaceCharacters(in: m.range, with: " ")
        }
        var text = out as String
        text = trailingLineSpaces.stringByReplacingMatches(in: text, range: full(text as NSString), withTemplate: "\n")
        text = blankRuns.stringByReplacingMatches(in: text, range: full(text as NSString), withTemplate: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
