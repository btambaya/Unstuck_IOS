// Fabrication guard — the claim detector + the self-correction stripper the
// harness runs on every no-tool reply. Port of `looksLikeActionClaim`,
// `refersToEarlierTurn` and `stripSelfCorrection` from lib/assistant/receipts.ts,
// regex for regex, so the web battery's verdicts hold on iOS. Pure.
//
// 2026-09-20 tooling rewrite (docs/assistant-tooling-rules.md §3): the
// detector is SENTENCE-AWARE — a sentence that refers to an earlier turn is
// not a claim about this one (bouncing a truthful recap invited the model to
// redo the action), the verb list is the full one (booked / skipped / ticked /
// renamed / carried / … / restored / pinned / recoloured), and the stripper
// only removes an apology lead (plus the bridging sentence that follows it)
// and a trailing apology — never a truthful "Actually, I…" that opens a reply,
// and never the whole reply.
//
// NSRegularExpression (ICU) is used rather than Swift `Regex` so the
// lookarounds + `\b` semantics match JS exactly.

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

    /// JS `String.split(regex)` (no capture groups): the pieces between matches.
    func split(_ s: String) -> [String] {
        let full = NSRange(s.startIndex..<s.endIndex, in: s)
        var out: [String] = []
        var cursor = s.startIndex
        for m in matches(in: s, range: full) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        out.append(String(s[cursor...]))
        return out
    }
}

// MARK: - stripSelfCorrection

// Apology forms that reference the hidden check ("sorry", "my mistake", "I
// said/claimed…", "I didn't actually…", "correction"). "Sorry to hear…" is
// sympathy, not a self-correction — leave it.
private let APOLOGY_FORMS =
    "sorry(?! to hear| that you| you| about your)|apolog\\w*|my (?:mistake|bad|apologies)"
    + "|i (?:said|claimed|mentioned|stated|didn'?t actually|hadn'?t actually|mistakenly)"
    + "|correction|that was (?:wrong|a mistake|an error)"

private let APOLOGY_LEAD = re(
    "^(?:(?:oh|ah|oops|hmm|right|wait|okay|ok)[,!.]?\\s*)?"
    + "(?:" + APOLOGY_FORMS + "|to correct)"
    + "[^.!?\\n]*[.!?\\n]+\\s*")

// The same apology forms as a whole TRAILING sentence ("Sorry for the
// confusion earlier.") — the user never saw a claim to be confused by.
private let APOLOGY_TAIL = re(
    "(?:^|(?<=[.!?\\n]\\s))(?:(?:oh|ah|oops|hmm|right|okay|ok)[,!.]?\\s*)?"
    + "(?:" + APOLOGY_FORMS + ")"
    + "[^.!?\\n]*[.!?]*\\s*$")

// Bridging sentences that only make sense right AFTER an apology ("Let me
// add it now.", "Actually, I hadn't added it yet!", "Adding it now."). They
// are stripped only in that position — standing alone at the head of a
// reply they're the model's real answer.
private let CONTINUATION = re(
    "^(?:actually,?\\s+i"
    + "|let me (?:fix|correct|add|do|create|schedule|save|move|redo) (?:that|it|this)\\b[^.!?\\n]*now"
    + "|(?:adding|doing|creating|scheduling|saving|moving) (?:it|that|this) now)"
    + "[^.!?\\n]*[.!?\\n]+\\s*")

/// After a fabrication-guard bounce the model tends to ANSWER THE CHECK
/// ("Sorry — I said I added it but I didn't; adding it now") even though the
/// user never saw the hidden claim. When the tool really ran on the retry,
/// strip that self-correction so the user just gets the answer. Pure.
///
/// Scoped to APOLOGY forms: a bare "Actually, I scheduled it for Friday…" or
/// "Let me add that now" is a truthful leading sentence after the tool ran —
/// stripping it used to leave the user with only "Want a reminder?" (harness
/// audit, 2026-09-05). Never returns an empty string — an apology-only turn
/// is still the reply.
public func stripSelfCorrection(_ text: String) -> String {
    let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var out = original
    var apologised = false
    for _ in 0..<4 {
        if APOLOGY_LEAD.test(out) {
            out = APOLOGY_LEAD.stripFirst(out).trimmingCharacters(in: .whitespacesAndNewlines)
            apologised = true
            continue
        }
        if apologised && CONTINUATION.test(out) {
            out = CONTINUATION.stripFirst(out).trimmingCharacters(in: .whitespacesAndNewlines)
            continue
        }
        break
    }
    // Never blank a reply — an apology-only turn is still the reply.
    if out.isEmpty { return original }
    for _ in 0..<2 where APOLOGY_TAIL.test(out) {
        let next = APOLOGY_TAIL.stripFirst(out).trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty { break }  // never strip the whole reply — a bare apology is still the reply
        out = next
    }
    return out
}

// MARK: - looksLikeActionClaim

// Verbs a completed-action claim is built from. Kept wide on purpose: once
// openers vary ("Booked.", "Skipped gym today.") the guard must still see
// them — an unmatched verb is an unbounced lie (harness audit, 2026-09-05).
// Identical to the web's CLAIM_VERBS (+ restored / pinned / unpinned /
// recoloured / recolored / finished / left / switched for the 2026-09-20 tools).
private let CLAIM_VERB_LIST: [String] = [
    "added", "created", "scheduled", "rescheduled", "moved", "shifted", "pushed", "postponed", "completed",
    "deleted", "removed", "saved", "updated", "blocked", "booked", "skipped", "reopened", "ticked", "unticked",
    "renamed", "unscheduled", "carried", "paused", "resumed", "extended", "cancelled", "canceled", "forgot",
    "forgotten", "remembered", "promoted", "started", "set", "turned", "noted", "archived", "unarchived",
    "resolved", "captured", "shared", "unshared", "restored", "pinned", "unpinned", "recoloured", "recolored",
    "finished", "left", "switched",
]
private let CLAIM_VERBS = CLAIM_VERB_LIST.joined(separator: "|")
// Sentence leads with the verb — minus the leads that open honest sentences
// ("Set aside 20 minutes for it?", "Shared tasks show up under…", "Turned
// out…", "Started already?", "Left to do: …", "Finished with that one?").
private let LEAD_VERBS = CLAIM_VERB_LIST.filter { !["set", "turned", "shared", "started", "left", "finished"].contains($0) }.joined(separator: "|")

private let CLAIM_PATTERNS: [NSRegularExpression] = [
    re("^(done|all set|sorted|booked|blocked)\\b"),
    // "Set to 240 minutes per day — done." / "Reminders on, done." (settings lies, 2026-09-02)
    re("(?:—|–|-|,|;)\\s*(?:all )?done[.!]?\\s*$"),
    re("^(?:set|turned|switched|changed)\\b.*(?:\\bdone\\b|✓)"),
    re("\\bI(?:['’]| ha)ve (?:\(CLAIM_VERBS))\\b"),
    re("\\b(?:\(CLAIM_VERBS)) [\"“'‘]"),
    // Passive perfect: "the task has been created/moved…"
    re("\\b(?:has|have) been (?:\(CLAIM_VERBS))\\b"),
    // Sentence leads with the verb: "Created the task for you." / "Skipped gym today."
    re("^(?:\(LEAD_VERBS))\\b"),
    // "I (just) created/moved the/your/that task…"
    re("\\bI (?:just )?(?:\(CLAIM_VERBS)) (?:the|your|that|a|an|it|them|this|those|these)\\b"),
    // Memory promises with nothing behind them: "I'll make a note of it",
    // "noted", "I'll remember that" — remembering IS save_profile_fact.
    re("\\bI(?:['’]ll| will)? ?(?:take|make) a? ?note\\b"),
    re("\\bI(?:['’]ll| will) (?:remember|keep that in mind|note that)\\b"),
    // Compliance promises that require persistence: "I'll skip/stop using
    // the name" — unsaved, that's forgotten by the next session.
    re("\\bI(?:['’]ll| will) (?:skip|stop|avoid|drop|leave out|not (?:use|say|mention))\\b"),
    re("^noted\\b"),
]

// NOT "before" / "this morning": "moved it before your meeting" and
// "scheduled it for this morning" are this-turn claims.
private let EARLIER_TURN = re(
    "\\b(?:earlier|previously|already|last time|a (?:moment|minute|while) ago|yesterday"
    + "|(?:as|like) I (?:said|mentioned|noted|told you)|when you asked"
    + "|in (?:my|the) (?:last|previous) (?:message|reply|turn))\\b")

/// A claim that talks about an EARLIER turn ("I moved it earlier", "as I
/// said", "already added yesterday") is not a claim about THIS turn — the
/// harness can only vouch for this turn's tool calls, and bouncing a
/// truthful recap invited the model to redo the action (a duplicate task,
/// harness audit 2026-09-05). Pure, per sentence.
public func refersToEarlierTurn(_ sentence: String) -> Bool {
    EARLIER_TURN.test(sentence)
}

/// Split on sentence ends, keeping sentences non-empty (the web's
/// `text.split(/(?<=[.!?])\s+|\n+/)`).
private let SENTENCE_END = re("(?<=[.!?])\\s+|\\n+")
private func sentences(_ text: String) -> [String] {
    SENTENCE_END.split(text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func sentenceClaimsAction(_ c: String) -> Bool {
    CLAIM_PATTERNS.contains { $0.test(c) }
}

/// Does a no-tool-call reply read like a claimed COMPLETED action or a
/// memory promise? ("Done — added 'X'", "the task has been created",
/// "I'll make a note of that"). Used by BOTH the text loop and the voice
/// session guard. Deliberately careful: honest answers ABOUT existing state
/// ("your dentist slot is on Friday") must not trip it, and neither must a
/// truthful reference to a PREVIOUS turn's action ("I moved it earlier").
public func looksLikeActionClaim(_ content: String?) -> Bool {
    let whole = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if whole.isEmpty { return false }
    // Only a sentence about THIS turn counts; an earlier-turn recap in the
    // same sentence disqualifies that sentence, not the others.
    return sentences(whole).contains { !refersToEarlierTurn($0) && sentenceClaimsAction($0) }
}
