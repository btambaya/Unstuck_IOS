// CallScript — the deterministic part of a call from Unstuck. Pure (no
// CallKit, no network) and unit-tested: given a CallSession it yields
//   • `opening`      — the first utterance the model MUST speak verbatim
//                      (the notes read back, then the offer), and
//   • `instructions` — the extra system lines for a call turn (read the notes
//                      first, then act ONLY through tools, keep it short,
//                      English, never claim an action without its tool), and
//   • `callTools`    — the tool names live during a call.
// The launcher (built on VoiceRealtimeClient by the integrator) appends
// `instructions` to the standard voice instructions and filters the voice tool
// schemas to `callTools`, adding the call-level `snooze_call`.
//
// THE LABEL'S SHAPE. The assistant prompt asks for the call label as a VERB
// phrase ("speak to James" — prompt.ts CALLS), but a model — or the task-
// anchored default (the task's name) — may hand over a noun ("James", "the
// dentist", "Dentist appointment"). Splicing either into one frame reads
// wrong for the other ("you asked me to call about speak to James"), so the
// opening renders by shape: a verb phrase → "you asked me to call so you'd
// speak to James", anything else → "you asked me to call about James".

import Foundation

enum CallScript {
    /// Tools live during a call. `snooze_call` is CALL-LEVEL: the launcher
    /// handles it locally (CallCoordinator.snoozeActiveCall → call-outcome
    /// `snoozed` + snoozeMinutes, then hangs up) — it never reaches the
    /// app's tool executor.
    static let callTools = ["complete_task", "add_capture", "schedule_task", "start_focus", "update_call", "snooze_call"]

    /// The verbatim first utterance:
    /// "Hi <name> — you asked me to call so you'd <verb label> | about <noun label>.
    ///  [You wanted to remember: <A>; <B>; <C>.] [It starts in N minutes.]
    ///  [Your first step was: …] <offer>"
    /// where the offer names only what applies (`offerSentence`): notes to
    /// tick off / add to, a timer only when a task is attached, and the
    /// call-back always.
    static func opening(_ s: CallSession, now: Date = Date()) -> String {
        var parts: [String] = []
        let greeting = s.preferredName.map { "Hi \($0) — " } ?? "Hi — "
        parts.append(greeting + "you asked me to call \(reasonPhrase(s.label)).")
        if let notes = notesSentence(s.notes) { parts.append(notes) }
        if let line = startLine(s, now: now) { parts.append(line) }
        if let fa = s.firstAction { parts.append("Your first step was: \(fa).") }
        parts.append(offerSentence(hasTask: s.taskId != nil, hasNotes: notesSentence(s.notes) != nil))
        return parts.joined(separator: " ")
    }

    // MARK: label shape

    enum LabelShape: Equatable { case verbPhrase, nounPhrase }

    /// Imperative verbs a call label commonly opens with. A label whose first
    /// word is one of these (or that starts "to …") is a verb phrase; anything
    /// else — a name, "the dentist", "Dentist appointment" — is a noun phrase.
    /// Unknown first words default to NOUN: "about chase the invoice" is a
    /// mild miss, "so you'd dentist appointment" is not.
    static let leadingVerbs: Set<String> = [
        "speak", "talk", "call", "ring", "phone", "dial", "text", "message", "email", "mail", "dm", "whatsapp",
        "facetime", "zoom", "write", "reply", "respond", "answer", "ask", "tell", "remind", "check", "confirm",
        "chase", "follow", "nudge", "ping", "poke", "book", "cancel", "reschedule", "schedule", "plan", "prep",
        "prepare", "pack", "unpack", "buy", "order", "pay", "send", "submit", "sign", "renew", "register", "apply",
        "review", "read", "finish", "start", "begin", "do", "get", "go", "pick", "drop", "collect", "fetch",
        "bring", "take", "make", "cook", "clean", "tidy", "wash", "water", "feed", "walk", "run", "exercise",
        "stretch", "meditate", "sleep", "rest", "eat", "drink", "leave", "meet", "see", "visit", "join", "attend",
        "watch", "listen", "practice", "practise", "study", "revise", "learn", "fix", "repair", "update", "upload",
        "download", "install", "set", "sort", "file", "print", "scan", "post", "ship", "return", "drive", "catch",
        "wake", "hand", "deliver", "complete", "wrap", "close", "open", "look", "find", "search", "log", "track",
        "record", "note", "decide", "choose", "move", "transfer", "charge", "push", "pull", "merge", "deploy",
        "test", "debug", "release", "publish", "draft", "outline", "edit", "proofread", "share", "invite", "thank",
        "apologise", "apologize", "congratulate", "celebrate", "wish", "greet", "put", "hang", "turn", "switch",
        "lock", "unlock", "fill", "refill", "vacuum", "iron", "fold", "mend", "hire", "rent", "swap", "sell",
        "list", "dispute", "claim", "report", "escalate", "stand", "sit", "breathe", "focus", "work", "tackle",
        "kick", "launch", "stop", "quit", "resume", "continue", "try", "give", "help", "let", "keep", "wait",
        "leave", "arrange", "organise", "organize", "clear", "empty", "top", "back", "ring", "pop", "nip", "head",
    ]

    static func labelShape(_ label: String) -> LabelShape {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: { $0 == " " }).first else { return .nounPhrase }
        let word = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if word == "to" { return .verbPhrase }
        return leadingVerbs.contains(word) ? .verbPhrase : .nounPhrase
    }

    /// "so you'd speak to James" / "about James" — the phrase after "you
    /// asked me to call". A leading "to " is folded into the frame.
    static func reasonPhrase(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch labelShape(trimmed) {
        case .verbPhrase:
            var body = trimmed
            if body.lowercased().hasPrefix("to ") { body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            return "so you'd \(body)"
        case .nounPhrase:
            return "about \(trimmed)"
        }
    }

    // MARK: sentences

    /// "You wanted to remember: A; B; C." — verbatim, trailing punctuation
    /// left alone; nil when the request carried no notes (nothing to say).
    static func notesSentence(_ notes: [String]) -> String? {
        let clean = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return nil }
        return "You wanted to remember: " + clean.joined(separator: "; ") + "."
    }

    /// The closing offer, naming only what applies: notes can be ticked off /
    /// added to only when there are notes, the timer only when a task is
    /// attached, the call-back always.
    static func offerSentence(hasTask: Bool, hasNotes: Bool) -> String {
        switch (hasTask, hasNotes) {
        case (true, true): return "Want to tick any off, add something, start the timer, or should I call back in ten?"
        case (true, false): return "Want to start the timer, or should I call back in ten?"
        case (false, true): return "Want to tick any off, add something, or should I call back in ten?"
        case (false, false): return "Anything you want me to note down, or should I call back in ten?"
        }
    }

    /// "It starts in N minutes." / "It starts now." / "It started N minutes ago."
    static func startLine(_ s: CallSession, now: Date) -> String? {
        guard let m = s.minutesUntilStart(now: now) else { return nil }
        switch m {
        case 2...: return "It starts in \(m) minutes."
        case 1: return "It starts in a minute."
        case 0: return "It starts now."
        case -1: return "It started a minute ago."
        default: return "It started \(-m) minutes ago."
        }
    }

    /// Extra system lines for the call turn. Appended AFTER the standard voice
    /// instructions (which carry the scope guardrail + live app state).
    static func instructions(_ s: CallSession, now: Date = Date()) -> String {
        var ctx: [String] = ["- label: \(s.label)"]
        if let t = s.taskId {
            ctx.append("- task: \(s.taskName ?? "(unnamed)") [id=\(t)]")
        }
        if let b = s.blockId { ctx.append("- block: \(b)") }
        if let st = s.startDate {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            ctx.append("- starts at: \(f.string(from: st))")
        }
        if let fa = s.firstAction { ctx.append("- first step: \(fa)") }
        ctx.append("- notes (verbatim): " + (s.notes.isEmpty ? "(none)" : s.notes.map { "\"\($0)\"" }.joined(separator: ", ")))
        if !s.captures.isEmpty {
            ctx.append("- recent captures on it: " + s.captures.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        return """
        THIS IS A PHONE CALL the user asked you to make (call id \(s.callId)). Speak English, calm and brief, like a friend on the phone.
        1. Open by saying EXACTLY this, verbatim, before anything else — read the notes word for word, do not summarise or reorder them:
        "\(opening(s, now: now))"
        2. Then act ONLY through tools: complete_task ticks a task off, add_capture notes something they say, schedule_task moves it, start_focus starts the timer, update_call changes these notes for later, snooze_call ("call me back in ten") calls back later — say the minutes. Never claim an action happened without its tool result; if a tool errors, say so plainly.
        3. One or two sentences per turn, one question at a time. When they're done, say goodbye — they hang up from the call screen.
        Call context:
        \(ctx.joined(separator: "\n"))
        """
    }
}
