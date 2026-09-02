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

import Foundation

enum CallScript {
    /// Tools live during a call. `snooze_call` is CALL-LEVEL: the launcher
    /// handles it locally (CallCoordinator.snoozeActiveCall → call-outcome
    /// `snoozed` + snoozeMinutes, then hangs up) — it never reaches the
    /// app's tool executor.
    static let callTools = ["complete_task", "add_capture", "schedule_task", "start_focus", "update_call", "snooze_call"]

    /// The verbatim first utterance:
    /// "Hi <name> — you asked me to call about <label>. Your notes: <A>; <B>; <C>.
    ///  [It starts in N minutes.] [Your first step was: …] Want to tick any off,
    ///  add something, start a timer, or should I call back in ten?"
    static func opening(_ s: CallSession, now: Date = Date()) -> String {
        var parts: [String] = []
        let greeting = s.preferredName.map { "Hi \($0) — " } ?? "Hi — "
        parts.append(greeting + "you asked me to call about \(s.label).")
        parts.append(notesSentence(s.notes))
        if let line = startLine(s, now: now) { parts.append(line) }
        if let fa = s.firstAction { parts.append("Your first step was: \(fa).") }
        parts.append("Want to tick any off, add something, start a timer, or should I call back in ten?")
        return parts.joined(separator: " ")
    }

    /// "Your notes: A; B; C." — verbatim, trailing punctuation left alone; or
    /// "You didn't leave any notes." when the request carried none.
    static func notesSentence(_ notes: [String]) -> String {
        let clean = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "You didn't leave any notes." }
        return "Your notes: " + clean.joined(separator: "; ") + "."
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
