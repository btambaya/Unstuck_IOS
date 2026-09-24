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
// all my done tasks"); a message that opens with a no ("No, leave it") asks
// only for what it names — or it must be a yes to the assistant's previous
// QUESTION when that question asked to delete it (the two-turn confirm:
// "Delete “Gym”?" → "yes"). Otherwise the tool is not run; the model gets
// `refusal` and asks instead. The same rule runs on web
// (lib/assistant/confirm-first.ts) and Android (AssistantConfirmFirst.kt),
// each with its own word lists. Typed chat only: a spoken (Talk / call) tool
// call is not checked here yet.

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
    /// What points at a list to LEAVE — never "it"/"that": "leave it" means
    /// keep it ("No, leave it" answering "Leave “Book club”?").
    static let listPointers: Set<String> = ["list", "lists", "group", "them", "these", "those", "both"]
    /// A word before a yes phrase that keeps it a yes ("just do it", "please go ahead").
    static let fillers: Set<String> = ["just", "please", "oh", "um", "well", "so", "then", "right"]
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
    /// A no — never a confirmation, whatever else the message says; a
    /// message that OPENS with one asks for nothing it doesn't name.
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
    /// A quoted name never splits ("Delete “Dr. Patel follow-up”?").
    static func lastAsk(_ text: String?) -> String? {
        guard let text else { return nil }
        var sentences: [String] = []
        var cur = ""
        var quoted = false
        for ch in text {
            cur.append(ch)
            if ch == "“" { quoted = true } else if ch == "”" { quoted = false } else if ch == "\"" { quoted.toggle() }
            if !quoted && ".!?\n".contains(ch) {
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

    /// A yes: an ANSWER that starts with one ("yes", "sure, go ahead", "yes,
    /// and the dentist too"), a short one with it a word or two in ("oh yes
    /// please"), or a yes phrase at its start ("go ahead", "just do it") —
    /// and nothing says no. Never a yes word inside another request: "I'll do
    /// it on Friday", "please add milk".
    static func isAffirmation(_ text: String) -> Bool {
        let w = words(text)
        guard let first = w.first, !w.contains(where: { negations.contains($0) }) else { return false }
        // "please" is a yes alone or as "please do" / "please, yes".
        func yes(_ word: String) -> Bool { word != "please" && affirmations.contains(word) }
        if yes(first) { return true }
        if first == "please" && (w.count == 1 || w[1] == "do" || yes(w[1])) { return true }
        if w.count <= 4 && w.prefix(3).contains(where: yes) { return true }
        let from = fillers.contains(first) ? [0, 1] : [0]
        return affirmingPhrases.contains { p in
            from.contains { i in i + p.count <= w.count && Array(w[i..<(i + p.count)]) == p }
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
        let userWords = words(userText)
        let asks = hasAny(userText, verbs) && !hasAny(userText, ["don't", "dont", "not", "never"])
        // "No, leave it" / "no, clear it off today" / "no, stop asking": a
        // message that opens with a no asks only for what it NAMES.
        let opensWithNo = userWords.first.map { negations.contains($0) } ?? false
        if tool == "cancel_focus" {
            // One running session: any clear "cancel/stop it" about it.
            if asks && (hasAny(userText, focusNouns) || mentions(target, in: userText)) { return true }
            if asks && !opensWithNo && (hasAny(userText, pointers) || userWords.count <= 3) { return true }
            let ask = lastAsk(previousAssistant)
            return isAffirmation(userText) && hasAny(ask, verbs)
                && (hasAny(ask, focusNouns) || hasAny(ask, pointers) || mentions(target, in: previousAssistant))
        }
        if asks {
            if mentions(target, in: userText) { return true }
            if !opensWithNo {
                if hasAny(userText, sweeping) { return true }
                let pointing = tool == "leave_list" ? listPointers : pointers
                if hasAny(userText, pointing) && mentions(target, in: previousAssistant) { return true }
            }
        }
        // The two-turn confirm: the assistant's QUESTION asked to delete this
        // thing — named in it, or pointed back at ("…Delete it?") with the
        // thing named before — and the user said yes. A name elsewhere in the
        // reply ("Gym is done. Want me to delete “Old plan”?") is not it.
        let ask = lastAsk(previousAssistant)
        if isAffirmation(userText), hasAny(ask, verbs) {
            if mentions(target, in: ask) || mentions(target, in: userText) { return true }
            if hasAny(ask, sweeping) { return true }
            if hasAny(ask, pointers.union(listPointers)) && mentions(target, in: previousAssistant) { return true }
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
