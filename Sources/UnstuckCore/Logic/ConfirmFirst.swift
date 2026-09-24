// Confirm-first, enforced in CODE (James, build 51, 2026-09-13): replies to
// "Show park run on calendar" and "Add travel to Skipton…" came back with
// ✓ Deleted "Pack ski gear checklist" and ✓ Deleted "Gym" — the model really
// called delete_task on tasks nobody had asked about. The registry marks the
// destructive tools `confirm: true` (delete_task, delete_list, leave_list,
// delete_area, delete_tag, cancel_focus), but that rule lived only in the
// prompt.
//
// Before one of those tools runs, the text harness asks `allows`: the user's
// latest message must ask to delete / cancel / leave THAT thing — by name, or
// with "it"/"that" right after the assistant named it, or sweepingly ("delete
// all my done tasks") — or it must be a yes to the assistant's previous
// message when that message asked to delete it (the two-turn confirm: "Delete
// “Gym”?" → "yes"). Otherwise the tool is not run; the model gets `refusal`
// and asks instead. Same rule on web, iOS and Android.

import Foundation

public enum ConfirmFirst {
    // MARK: - words

    /// Asking for something to be removed (tasks, lists, areas, tags).
    static let deleteWords: Set<String> = [
        "delete", "deletes", "deleted", "deleting",
        "remove", "removes", "removed", "removing",
        "rid",                                            // "get rid of"
        "bin", "binned", "binning",
        "trash", "trashed", "trashing",
        "erase", "erased", "erasing",
        "scrap", "scrapped", "scrapping",
        "ditch", "ditched", "ditching",
        "drop", "dropped", "dropping",
        "clear", "cleared", "clearing",
        "wipe", "wiped", "wiping",
        "nuke", "nuked",
        "cancel", "cancels", "cancelled", "canceled", "cancelling", "canceling",
        "kill", "killed", "replace", "replaced", "replacing",   // "replace Gym with Swimming"
        "junk", "toss", "tossed", "chuck", "chucked", "dump", "dumped",
    ]
    /// Asking to leave a list someone shared with them.
    static let leaveWords: Set<String> = [
        "leave", "leaving", "quit", "quitting", "exit", "exiting",
        "unsubscribe", "unfollow", "unshare",
    ]
    /// Asking to throw the running focus session away.
    static let cancelFocusWords: Set<String> = [
        "cancel", "cancelled", "canceled", "cancelling", "canceling",
        "stop", "stopping", "end", "ending", "quit", "abandon", "abandoned",
        "scrap", "discard", "discarded", "kill", "abort", "ditch", "drop",
        "bin", "forget", "trash", "delete", "remove", "reset",
    ]
    /// What the running focus session is called.
    static let focusNouns: Set<String> = ["focus", "session", "timer", "block", "sprint", "pomodoro", "clock"]
    /// "it" / "that" — a thing just named.
    static let pointers: Set<String> = ["it", "this", "that", "one", "them", "these", "those", "both"]
    /// A sweeping ask ("delete all my done tasks").
    static let sweeping: Set<String> = ["all", "every", "everything", "each"]
    /// A yes.
    static let affirmations: Set<String> = [
        "yes", "yeah", "yea", "yep", "yup", "ya", "yah", "yess", "aye", "sure", "ok", "okay", "k", "kk",
        "please", "confirm", "confirmed", "correct", "absolutely", "definitely", "affirmative", "alright",
        "fine", "👍", "✅",
        // The commonest yes in the languages the assistant answers in.
        "si", "oui", "ja", "sim", "tak", "evet", "igen",
    ]
    /// A yes in more than one word.
    static let affirmingPhrases: [[String]] = [["go", "ahead"], ["do", "it"], ["go", "for", "it"], ["sounds", "good"], ["that's", "right"]]
    /// A no — never a confirmation, whatever else the message says.
    static let negations: Set<String> = ["no", "nope", "nah", "not", "don't", "dont", "never", "wait", "hold", "keep"]
    /// Too common to identify a task by.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "for", "with", "from", "in", "on", "at", "by", "my", "me",
        "i", "it", "is", "be", "up", "out", "off", "our", "your", "their", "this", "that", "list", "lists",
        "task", "tasks", "item", "items", "thing", "things", "new", "do", "get", "go", "some", "all",
    ]

    // MARK: - text

    /// Lower-cased words: letters, digits and apostrophes (curly ones
    /// straightened); diacritics folded; everything else splits.
    static func words(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'").lowercased()
        var out: [String] = []
        var cur = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "👍" || ch == "✅" {
                cur.append(ch)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    /// True when `text` names `name`: the whole name, or its telling words
    /// (one of a one- or two-word name's, two of a longer one's), a plural
    /// "s"/"es" allowed.
    public static func mentions(_ name: String?, in text: String?) -> Bool {
        guard let name, let text else { return false }
        let nameWords = words(name)
        let textWords = words(text)
        guard !nameWords.isEmpty, !textWords.isEmpty else { return false }
        // The whole name, as consecutive words.
        if textWords.count >= nameWords.count {
            for i in 0...(textWords.count - nameWords.count) where Array(textWords[i..<(i + nameWords.count)]) == nameWords {
                return true
            }
        }
        let telling = Array(Set(nameWords.filter { $0.count >= 3 && !stopWords.contains($0) }))
        guard !telling.isEmpty else { return false }
        let textSet = Set(textWords)
        let hits = telling.filter { w in textSet.contains(w) || textSet.contains(w + "s") || textSet.contains(w + "es") }.count
        return hits >= (telling.count >= 3 ? 2 : 1)
    }

    /// What the assistant's previous reply actually ASKED: its last question
    /// ("Want me to delete “Gym”? It has no slots left." → the first
    /// sentence), else its last sentence — so "I won't delete anything unless
    /// you say so. Want me to schedule Gym?" answered "yes" never deletes.
    static func lastAsk(_ text: String?) -> String? {
        guard let text else { return nil }
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?\n".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && t != "." && t != "!" && t != "?" { sentences.append(t) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.last { $0.hasSuffix("?") } ?? sentences.last
    }

    static func hasAny(_ text: String?, _ set: Set<String>) -> Bool {
        guard let text else { return false }
        return words(text).contains { set.contains($0) }
    }

    /// A yes: one of the first three words (or a phrase like "go ahead") says
    /// so, and nothing says no.
    static func isAffirmation(_ text: String) -> Bool {
        let w = words(text)
        guard !w.isEmpty, !w.contains(where: { negations.contains($0) }) else { return false }
        if w.prefix(3).contains(where: { affirmations.contains($0) }) { return true }
        return affirmingPhrases.contains { p in
            w.count >= p.count && (0...(w.count - p.count)).contains { Array(w[$0..<($0 + p.count)]) == p }
        }
    }

    static func actionWords(_ tool: String) -> Set<String> {
        switch tool {
        case "cancel_focus": return cancelFocusWords
        case "leave_list": return leaveWords.union(deleteWords)
        default: return deleteWords
        }
    }

    // MARK: - the rule

    /// May `tool` run on `target` (the task / list / area / tag name, or the
    /// focused task's name for cancel_focus) this turn? `userText` = the
    /// user's latest message; `previousAssistant` = the assistant's last
    /// visible reply before it (nil when there is none).
    public static func allows(tool: String, target: String?, userText: String, previousAssistant: String?) -> Bool {
        let verbs = actionWords(tool)
        let asks = hasAny(userText, verbs) && !hasAny(userText, ["don't", "dont", "not", "never"])
        if tool == "cancel_focus" {
            // One running session: any clear "cancel/stop it" about it.
            if asks && (hasAny(userText, focusNouns) || hasAny(userText, pointers) || mentions(target, in: userText)
                        || words(userText).count <= 3) { return true }
            let ask = lastAsk(previousAssistant)
            return isAffirmation(userText) && hasAny(ask, verbs)
                && (hasAny(ask, focusNouns) || hasAny(ask, pointers) || mentions(target, in: previousAssistant))
        }
        if asks {
            if mentions(target, in: userText) { return true }
            if hasAny(userText, sweeping) { return true }
            if hasAny(userText, pointers) && mentions(target, in: previousAssistant) { return true }
        }
        // The two-turn confirm: the assistant's question asked to delete it
        // (named there or just before it), the user said yes.
        let ask = lastAsk(previousAssistant)
        if isAffirmation(userText), hasAny(ask, verbs) {
            if mentions(target, in: previousAssistant) || mentions(target, in: userText) { return true }
            if hasAny(ask, sweeping) { return true }
        }
        return false
    }

    /// The tool result when `allows` says no — nothing ran; the model asks.
    public static func refusal(tool: String, target: String?) -> String {
        let q = target.map { "“\($0)”" } ?? "it"
        let plain = target.map { "\"\($0)\"" } ?? "that"
        switch tool {
        case "cancel_focus":
            return "error: not cancelled — the user hasn't asked to cancel this focus session. Nothing was changed. If they're done, finish_focus logs the time; to throw the session away, ask them first and call cancel_focus only once they say yes."
        case "leave_list":
            return "error: not left — the user hasn't asked to leave the list \(plain) in this conversation. Nothing was changed. Ask them first (\"Leave \(q)?\") and call leave_list only once they say yes."
        case "delete_list":
            return "error: not deleted — the user hasn't asked to delete the list \(plain) in this conversation. Nothing was changed. Ask them first (\"Delete the list \(q)?\") and call delete_list only once they say yes."
        case "delete_area":
            return "error: not deleted — the user hasn't asked to delete the area \(plain) in this conversation. Nothing was changed. Ask them first (\"Delete the area \(q)?\") and call delete_area only once they say yes."
        case "delete_tag":
            return "error: not deleted — the user hasn't asked to delete the tag \(plain) in this conversation. Nothing was changed. Ask them first (\"Delete the tag \(q)?\") and call delete_tag only once they say yes."
        default:
            return "error: not deleted — the user hasn't asked to delete \(plain) in this conversation. Nothing was changed. Ask them first (\"Delete \(q)?\") and call \(tool) only once they say yes."
        }
    }
}
