// CallScript — the deterministic part of a call from Unstuck. Pure (no
// CallKit, no network) and unit-tested: given a CallSession it yields
//   • `opening`      — the first utterance the model MUST speak verbatim
//                      (per KIND: the notes read back + the offer for a
//                      requested call; the test-call line; "want to walk
//                      through today?"; "quick wrap-up?"; "<task> was on till
//                      <time> — how did it go?"), and
//   • `instructions` — the extra system lines for a call turn (open verbatim,
//                      then act ONLY through tools, keep it short, English,
//                      never claim an action without its tool result), and
//   • `callTools`    — the tool names live during a call: EVERY voice tool
//                      (the registry's voice surface — a call is the full
//                      assistant on the phone, calls build-out 2026-09-20)
//                      plus the call-only extras (`ToolRegistry.call`).
// The launcher (built on VoiceRealtimeClient by the integrator) appends
// `instructions` to the standard voice instructions and filters the voice tool
// schemas to `callTools`, adding the call-level `snooze_call`.
//
// THE LABEL'S SHAPE. The assistant prompt asks for the call label as a VERB
// phrase ("speak to James" — prompt.ts request_call), but a model — or the
// task-anchored default (the task's name) — may hand over a noun ("James",
// "the dentist", "Dentist appointment"). Splicing either into one frame reads
// wrong for the other ("you asked me to ring about speak to James"), so the
// opening renders by shape: a verb phrase → "you asked me to ring so you'd
// speak to James", anything else → "you asked me to ring about James".

import Foundation
import UnstuckCore

enum CallScript {
    /// Tools live during a call: every voice tool the registry publishes, in
    /// registry order, then the call-only extras (`snooze_call`). `snooze_call`
    /// is CALL-LEVEL: the launcher handles it locally
    /// (CallCoordinator.snoozeActiveCall → call-outcome `snoozed` +
    /// snoozeMinutes, then hangs up) — it never reaches the app's executor.
    static var callTools: [String] { callToolNames(voice: ToolRegistry.voice, call: ToolRegistry.call) }

    /// Pure: the names of `voice` then `call`, de-duplicated, order kept.
    static func callToolNames(voice: [[String: Any]], call: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in voice + call {
            guard let n = t["name"] as? String, !n.isEmpty, seen.insert(n).inserted else { continue }
            out.append(n)
        }
        return out
    }

    /// The verbatim first utterance, by kind:
    ///   requested   "Hi <name> — you asked me to ring about <noun label> |
    ///               so you'd <verb label>. [You wanted to remember: <A>; <B>;
    ///               <C>.] [It starts in N minutes.] [Your first step was: …]
    ///               <closing question>" — ONE short question chosen by what
    ///               applies (`offerSentence`): a task → the timer or a
    ///               ring-back; notes only → anything to add; neither →
    ///               anything to note. Never a menu.
    ///   test        "Hi <name> — this is your test call from Unstuck.
    ///               Everything works. Want to try something — ask me what's
    ///               on today?"
    ///   morning     "Morning, <name>. Want to walk through today?"
    ///   evening     "Evening, <name>. Quick wrap-up?"
    ///   after_block "Hi <name> — <task> was on till <time>. How did it go?"
    static func opening(_ s: CallSession, now: Date = Date()) -> String {
        switch s.kind {
        case .requested:
            var parts: [String] = []
            parts.append(hiGreeting(s) + "you asked me to ring \(reasonPhrase(s.label)).")
            if let notes = notesSentence(s.notes) { parts.append(notes) }
            if let line = startLine(s, now: now) { parts.append(line) }
            if let fa = s.firstAction { parts.append("Your first step was: \(fa).") }
            parts.append(offerSentence(hasTask: s.taskId != nil, hasNotes: notesSentence(s.notes) != nil))
            return parts.joined(separator: " ")
        case .test:
            return hiGreeting(s) + "this is your test call from Unstuck. Everything works. Want to try something — ask me what's on today?"
        case .morning:
            return (s.preferredName.map { "Morning, \($0)." } ?? "Morning.") + " Want to walk through today?"
        case .evening:
            return (s.preferredName.map { "Evening, \($0)." } ?? "Evening.") + " Quick wrap-up?"
        case .afterBlock:
            let what = s.taskName ?? s.label
            let till = s.spokenEnd.map { "was on till \($0)" } ?? "just finished"
            return hiGreeting(s) + "\(what) \(till). How did it go?"
        }
    }

    /// "Hi <name> — " / "Hi — ".
    static func hiGreeting(_ s: CallSession) -> String {
        s.preferredName.map { "Hi \($0) — " } ?? "Hi — "
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

    /// "about James" / "so you'd speak to James" — the phrase after "you
    /// asked me to ring". A leading "to " is folded into the frame.
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

    /// The closing question — one short question, never a menu: a task
    /// attached → the timer or a ring-back; notes only → anything to add;
    /// neither → anything to note.
    static func offerSentence(hasTask: Bool, hasNotes: Bool) -> String {
        switch (hasTask, hasNotes) {
        case (true, _): return "Start the timer, or ring you back in ten?"
        case (false, true): return "Anything to add?"
        case (false, false): return "Anything you want me to note?"
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
    /// instructions (which carry the scope guardrail + live app state + every
    /// tool's rules). Line 1 (the verbatim opening) and the "never claim an
    /// action without its tool result" rule hold for every kind; line 2 is
    /// the kind's own shape of conversation.
    /// `dayContext`: lines read from the local store as the call connects
    /// (CallDayContext.lines) — what got done today, what is still open,
    /// today's plan, tomorrow's first thing. Zubair's evening call
    /// (2026-09-20 19:01): the model asked HIM what got done, answered "what
    /// did we have today" from nothing, then read an undated all-time
    /// completed list as "today". With the facts in the instructions the
    /// answer needs no tool call the model might skip.
    static func instructions(_ s: CallSession, now: Date = Date(), dayContext: [String] = []) -> String {
        var ctx: [String] = ["- kind: \(s.kind.rawValue)", "- label: \(s.label)"]
        if let t = s.taskId {
            ctx.append("- task: \(s.taskName ?? "(unnamed)") [id=\(t)]")
        }
        if let b = s.blockId { ctx.append("- block: \(b)") }
        if let st = s.startDate {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            ctx.append("- starts at: \(f.string(from: st))")
        }
        if let en = s.endDate {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            ctx.append("- block ended at: \(f.string(from: en))")
        }
        if let fa = s.firstAction { ctx.append("- first step: \(fa)") }
        ctx.append("- notes (verbatim): " + (s.notes.isEmpty ? "(none)" : s.notes.map { "\"\($0)\"" }.joined(separator: ", ")))
        if !s.captures.isEmpty {
            ctx.append("- recent captures on it: " + s.captures.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        for line in dayContext { ctx.append("- " + line) }
        let openingRule: String
        switch s.kind {
        case .requested:
            openingRule = "read the notes word for word, do not summarise or reorder them"
        default:
            openingRule = "then wait for their answer"
        }
        return """
        \(headline(s)) Speak English, calm and brief, like a friend on the phone.
        1. Open by saying EXACTLY this, verbatim, before anything else — \(openingRule):
        "\(opening(s, now: now))"
        2. \(conversationRule(s.kind)) You have every tool you have in Talk — reschedule, add tasks, tick things off, capture, share, plus update_call (changes this call's notes for later) and snooze_call ("call me back in ten" — say the minutes). Never claim an action happened without its tool result; if a tool errors, say so plainly.
        3. One or two sentences a turn, one question at a time, times the way people say them. When they're done, say bye — they hang up from the screen.
        Call context (read from the app as the call connected — answer \"what got done\" / \"what's on today\" from it; call get_schedule / get_tasks only for what it doesn't cover):
        \(ctx.joined(separator: "\n"))
        """
    }

    /// The first line of the call instructions — what kind of call this is.
    static func headline(_ s: CallSession) -> String {
        switch s.kind {
        case .requested: return "THIS IS A PHONE CALL the user asked you to make (call id \(s.callId))."
        case .test: return "THIS IS A TEST CALL the user booked from Settings to hear what a call from Unstuck sounds like (call id \(s.callId))."
        case .morning: return "THIS IS THE MORNING PLANNING CALL the user opted into (call id \(s.callId))."
        case .evening: return "THIS IS THE EVENING WRAP-UP CALL the user opted into (call id \(s.callId))."
        case .afterBlock: return "THIS IS THE CHECK-IN AFTER A BLOCK the user opted into: the block ended and its task isn't marked done (call id \(s.callId))."
        }
    }

    /// Line 2 — how the conversation goes for this kind.
    static func conversationRule(_ kind: CallKind) -> String {
        switch kind {
        case .requested:
            return "Then act ONLY through tools: complete_task ticks a task off, add_capture notes something they say, schedule_task moves it, start_focus starts the timer."
        case .test:
            return "If they try something, do it for real through the tools (get_schedule / get_tasks answer \"what's on today\"); keep it light — this call proves the ring works."
        case .morning:
            return "If they say yes, read today's plan from the call context below, briefly (times the way people say them) — call get_schedule only if the context has no plan — then plan with them: move things with schedule_task / block_time, add what's missing with create_task, drop what won't happen with set_task_later or carry_to_tomorrow. Act ONLY through tools."
        case .evening:
            return "If they say yes, say from the call context below what got done today and what is still open, in one sentence — NEVER ask them what got done, and call get_tasks(view: completed) only if the context has no such line — then ask what moves to tomorrow: carry_to_tomorrow ONLY when they ask for it, complete_task only for something they clearly say they finished, add_capture for a loose thought. Act ONLY through tools."
        case .afterBlock:
            return "Listen. Tick it off (complete_task, or complete_occurrence for a recurring one) ONLY when they clearly say they finished it — \"done\", \"finished it\", \"all done\". If they only say how it went (\"it went well\", \"sort of\") or you didn't catch it, ask one short question first — \"Want me to mark it done?\" — and act only on a yes. Not now → skip_occurrence / set_task_later, and needs another go → schedule_task or block_time, only when they say so. Never change anything they didn't ask for. Act ONLY through tools."
        }
    }
}


// MARK: - CallDayContext

/// The day's facts for a call, read from the local store as the call
/// connects (pure; the launcher feeds it AppModel's tasks + blocks). Lines
/// go into the call instructions' context, so "what got done today" and
/// "what's on today" are answered from here, not from a tool call the model
/// may skip — and never from an undated list.
enum CallDayContext {
    static let maxNames = 12

    static func lines(kind: CallKind, tasks: [TaskItem], blocks: [CalBlock], today: String, nowHM: String,
                      tz: TimeZone = .current) -> [String] {
        var out: [String] = ["today: \(today) (\(weekdayName(today: today))), now \(nowHM)"]
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let todays = blocks.filter { $0.date == today }.sorted { $0.startTime < $1.startTime }
        // The task's current name first (a block's copy can be stale after a rename).
        func name(_ b: CalBlock) -> String { b.taskId.flatMap { byId[$0]?.name } ?? (b.taskName.isEmpty ? "?" : b.taskName) }
        // Done today: tasks ticked today (by completedAt) + today's occurrence blocks ticked.
        var done: [String] = []
        for t in tasks where t.done && localDate(ofISO: t.completedAt, tz: tz) == today { done.append(t.name) }
        for b in todays where b.done { done.append(name(b)) }
        done = dedupe(done)
        // Still open today: today's live blocks whose task isn't done.
        let open = todays.filter { b in
            guard !b.done, !b.skipped else { return false }
            if let tid = b.taskId, let t = byId[tid], t.done { return false }
            return true
        }
        let plan = todays.map { b -> String in
            let taskDone = b.taskId.flatMap { byId[$0]?.done } ?? false
            return "\(b.startTime) \(name(b))" + ((b.done || taskDone) ? " · done" : (b.skipped ? " · skipped" : ""))
        }
        let tomorrow = LocalDate.addDays(today, 1)
        let firstTomorrow = blocks.filter { $0.date == tomorrow && !$0.done && !$0.skipped }.sorted { $0.startTime < $1.startTime }.first
        func names(_ xs: [String]) -> String {
            xs.count <= maxNames ? xs.joined(separator: ", ") : xs.prefix(maxNames).joined(separator: ", ") + " and \(xs.count - maxNames) more"
        }
        let doneLine = done.isEmpty ? "done today: nothing ticked off yet" : "done today (\(done.count)): \(names(done))"
        let openLine = open.isEmpty ? "still open today: nothing" : "still open today (\(open.count)): " + names(open.map { "\(name($0)) (\($0.startTime))" })
        let planLine = plan.isEmpty ? "today's plan: nothing scheduled" : "today's plan (\(plan.count)): " + plan.prefix(maxNames).joined(separator: "; ") + (plan.count > maxNames ? "; and \(plan.count - maxNames) more" : "")
        let tomorrowLine = firstTomorrow.map { "tomorrow starts with: \(name($0)) at \($0.startTime)" } ?? "tomorrow: nothing scheduled yet"
        switch kind {
        case .evening: out += [doneLine, openLine, tomorrowLine]
        case .morning: out += [planLine, doneLine]
        case .afterBlock: out += [openLine, doneLine]
        case .requested, .test: out += [planLine]
        }
        return out
    }

    /// 'YYYY-MM-DD' in `tz` for an ISO-8601 instant ("2026-09-20T08:10:00.000Z"); nil when unparseable.
    static func localDate(ofISO iso: String?, tz: TimeZone) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        guard let d = f1.date(from: iso) ?? f2.date(from: iso) else { return nil }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = tz; df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }

    private static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x.lowercased()).inserted { out.append(x) }
        return out
    }
}
