// Fabrication guard — the claim detector + the self-correction stripper the
// harness runs on every no-tool reply. Port of `looksLikeActionClaim` and
// `stripSelfCorrection` from lib/assistant/receipts.ts, regex for regex, so
// the web battery's verdicts hold on iOS. Pure.
//
// NSRegularExpression (ICU) is used rather than Swift `Regex` so the
// lookaheads + `\b` semantics match JS exactly.

import Foundation

private func re(_ pattern: String) -> NSRegularExpression {
    // Patterns are static literals ported from the web; a typo is a programmer
    // error, so crash loudly at first use rather than silently never matching.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private extension NSRegularExpression {
    func test(_ s: String) -> Bool {
        firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    /// JS `String.replace(regex, '')` — first match only (no `g` flag).
    func stripFirst(_ s: String) -> String {
        let full = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = firstMatch(in: s, range: full), let r = Range(m.range, in: s) else { return s }
        var out = s
        out.removeSubrange(r)
        return out
    }
}

// MARK: - stripSelfCorrection

// "Sorry to hear…" is sympathy, not a self-correction — leave it.
private let APOLOGY = re(
    "^(?:(?:oh|ah|oops|hmm|right|wait|okay|ok)[,!.]?\\s*)?"
    + "(?:sorry(?! to hear| that you| you| about your)|apolog\\w*|my (?:mistake|bad|apologies)"
    + "|i (?:said|claimed|mentioned|stated|didn'?t actually|hadn'?t actually|mistakenly|previously|earlier)"
    + "|correction|actually,?\\s+i"
    + "|let me (?:fix|correct|add|do|create|schedule|save|move|redo) (?:that|it|this)\\b[^.!?\\n]*now"
    + "|(?:adding|doing|creating|scheduling|saving|moving) (?:it|that|this) now"
    + "|that was (?:wrong|a mistake|an error)|to correct)"
    + "[^.!?\\n]*[.!?\\n]+\\s*")

/// After a fabrication-guard bounce the model tends to ANSWER THE CHECK
/// ("Sorry — I said I added it but I didn't; adding it now") even though the
/// user never saw the hidden claim. When the tool really ran on the retry,
/// strip that self-correction so the user just gets the answer. Pure.
public func stripSelfCorrection(_ text: String) -> String {
    var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var i = 0
    while i < 3 && APOLOGY.test(out) {
        out = APOLOGY.stripFirst(out).trimmingCharacters(in: .whitespacesAndNewlines)
        i += 1
    }
    return out
}

// MARK: - looksLikeActionClaim

private let CLAIM_PATTERNS: [NSRegularExpression] = [
    re("^(done|all set|sorted)\\b"),
    // "Set to 240 minutes per day — done." / "Reminders on, done." (settings lies, 2026-09-02)
    re("(?:—|–|-|,|;)\\s*(?:all )?done[.!]?\\s*$"),
    re("^(?:set|turned|switched|changed)\\b.*(?:\\bdone\\b|✓)"),
    re("\\bI(?:['’]| ha)ve (added|created|scheduled|rescheduled|moved|shifted|pushed|postponed|completed|deleted|removed|saved|updated|blocked|set|noted)\\b"),
    re("\\b(added|created|scheduled|updated|deleted|saved|completed|moved|shifted|pushed|blocked) [\"“'‘]"),
    // Passive perfect: "the task has been created/moved…"
    re("\\b(?:has|have) been (?:created|added|scheduled|rescheduled|moved|shifted|pushed|postponed|completed|deleted|removed|updated|saved)\\b"),
    // Sentence leads with the verb: "Created the task for you."
    re("^(?:created|added|scheduled|rescheduled|moved|shifted|pushed|postponed|completed|deleted|updated|saved)\\b"),
    // "I (just) created/moved the/your/that task…"
    re("\\bI (?:just )?(?:created|added|scheduled|rescheduled|moved|shifted|pushed|postponed|completed|deleted|updated|saved) (?:the|your|that|a|an|it)\\b"),
    // Memory promises with nothing behind them: "I'll make a note of it",
    // "noted", "I'll remember that" — remembering IS save_profile_fact.
    re("\\bI(?:['’]ll| will)? ?(?:take|make) a? ?note\\b"),
    re("\\bI(?:['’]ll| will) (?:remember|keep that in mind|note that)\\b"),
    // Compliance promises that require persistence: "I'll skip/stop using
    // the name" — unsaved, that's forgotten by the next session.
    re("\\bI(?:['’]ll| will) (?:skip|stop|avoid|drop|leave out|not (?:use|say|mention))\\b"),
    re("^noted\\b"),
]

/// Does a no-tool-call reply read like a claimed COMPLETED action or a
/// memory promise? ("Done — added 'X'", "the task has been created",
/// "I'll make a note of that"). Used by BOTH the text loop and the voice
/// session guard. Deliberately careful: honest answers ABOUT existing state
/// ("your dentist slot is on Friday") must not trip it.
public func looksLikeActionClaim(_ content: String?) -> Bool {
    let c = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if c.isEmpty { return false }
    return CLAIM_PATTERNS.contains { $0.test(c) }
}
