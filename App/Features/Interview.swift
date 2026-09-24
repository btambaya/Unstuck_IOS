// The get-to-know-you interview — the assistant's FIRST contact (iOS port of
// components/assistant/interview.tsx). Scripted and ZERO-token: chip answers
// and free text write profile facts directly (source .interview); the LLM is
// never involved. One question at a time, every question skippable, "I'm done"
// always visible — the documented ADHD dropout point is a long setup wizard,
// so this must never feel like one. The SEVEN questions are the web's, in the
// web's order with the web's copy, so a fact reads the same whichever device
// wrote it — and "done" is per PERSON, not per device: it's mirrored to
// user_preferences.assistant_interview_done_at (migration 052) and re-applied
// on every sign-in hydrate (AppModel.applyServerInterviewFlag). Everything
// saved is visible (and deletable) in Settings → "What Unstuck knows".
//
// Presented INSIDE the assistant thread (InterviewThread.swift) — one
// question per local assistant turn, chips + Skip underneath — and asked
// aloud by the voice opening primer. The state machine (`InterviewMachine`)
// is pure and UserDefaults-injectable so the step/auto-done/resume/skip
// rules are unit tested without SwiftUI.

import SwiftUI
import UnstuckCore
import UnstuckDesign

// MARK: - questions

/// One tap-answer for a question. `fact == nil` saves nothing ("It varies").
struct InterviewChip: Equatable, Sendable {
    let label: String
    let fact: String?
}

struct InterviewQuestion: Sendable {
    let key: String
    let category: UnstuckCore.ProfileFactCategory
    let question: String
    let chips: [InterviewChip]
    /// Prefix stitched onto a free-text answer ("Never schedule: …").
    let freePrefix: String?
    let allowFree: Bool
    /// Free text is a comma-separated list of NAMES — each becomes its own
    /// person fact ("Maleek", "Sam" → two facts), so relationship moments can
    /// match one name per fact (moments.ts `leadName`). A descriptor
    /// ("Maleek — son, 9") is ONE fact — see `InterviewMachine.splitPeople`.
    let splitNames: Bool

    init(key: String, category: UnstuckCore.ProfileFactCategory, question: String, chips: [InterviewChip],
         freePrefix: String? = nil, allowFree: Bool = false, splitNames: Bool = false) {
        self.key = key; self.category = category; self.question = question; self.chips = chips
        self.freePrefix = freePrefix; self.allowFree = allowFree; self.splitNames = splitNames
    }
}

/// The script — the web's SEVEN questions (components/assistant/interview.tsx)
/// in the web's order: rhythm → work → people → fixed points → commitments →
/// never-schedule → nudge style, then the rituals picker as the final step.
/// Keys, copy, chips, categories and free-text prefixes are the web's
/// verbatim, so a fact reads the same whichever device wrote it (a five-
/// question iOS variant once made the two interviews visibly different —
/// prod tester, 2026-09-05). The one iOS extra is `splitNames` on people.
/// The two clock chips ("Before 9am" / "After 9pm" on the web) read in the
/// phone's own 12/24-hour clock — "Before 9 AM" / "Before 09:00" (2026-09-24);
/// the FACTS they save stay the web's verbatim text, so a fact still reads the
/// same whichever device wrote it.
var INTERVIEW_QUESTIONS: [InterviewQuestion] { interviewQuestions(clock: .device) }

func interviewQuestions(clock: ClockFormat) -> [InterviewQuestion] { [
    InterviewQuestion(
        key: "rhythm", category: .rhythm,
        question: "When’s your head clearest?",
        chips: [
            InterviewChip(label: "Morning", fact: "Mornings are the good hours — schedule the hard things early"),
            InterviewChip(label: "Afternoon", fact: "Afternoons are the good hours"),
            InterviewChip(label: "Evening", fact: "Evenings are the good hours — slow starter"),
            InterviewChip(label: "It varies", fact: nil),
        ]),
    InterviewQuestion(
        key: "work", category: .context,   // web parity — .constraint here duplicated the fact across devices
        question: "What do your work days look like?",
        chips: [
            InterviewChip(label: "9–5 weekdays", fact: "Works roughly 9–5 on weekdays"),
            InterviewChip(label: "Shifts", fact: "Works shifts — hours change week to week"),
            InterviewChip(label: "Flexible / freelance", fact: "Flexible schedule — sets their own hours"),
            InterviewChip(label: "Studying", fact: "Studying — timetable over office hours"),
        ],
        freePrefix: "Work", allowFree: true),
    InterviewQuestion(
        key: "people", category: .person,
        question: "Anyone whose schedule shapes yours — kids, a partner, someone you care for? Names help.",
        chips: [InterviewChip(label: "No one right now", fact: nil)],
        allowFree: true, splitNames: true),
    InterviewQuestion(
        key: "fixed", category: .constraint,   // the web files fixed points as a constraint
        question: "Fixed points in the week I should plan around? School runs, prayers, classes…",
        chips: [InterviewChip(label: "None", fact: nil)],
        allowFree: true),
    InterviewQuestion(
        key: "commitments", category: .context,
        question: "Regular commitments — gym, rehearsals, clubs, volunteering?",
        chips: [InterviewChip(label: "Not really", fact: nil)],
        allowFree: true),
    InterviewQuestion(
        key: "nogo", category: .constraint,
        question: "When should I never schedule anything?",
        chips: [
            InterviewChip(label: "Before \(clock.shortTime(minutes: 9 * 60))", fact: "Never schedule anything before 9am"),
            InterviewChip(label: "After \(clock.shortTime(minutes: 21 * 60))", fact: "Never schedule anything after 9pm"),
            InterviewChip(label: "Weekends", fact: "Keep weekends free — never schedule work there"),
            InterviewChip(label: "No hard limits", fact: nil),
        ],
        freePrefix: "Never schedule", allowFree: true),
    InterviewQuestion(
        key: "nudge", category: .preference,
        question: "Last one — how should I nudge you?",
        chips: [
            InterviewChip(label: "Gently", fact: "Prefers gentle nudges — suggest, never push"),
            InterviewChip(label: "Keep me honest", fact: "Wants to be kept honest — direct nudges are welcome"),
            InterviewChip(label: "Barely at all", fact: "Minimal nudging — only speak up when it really matters"),
        ]),
] }

// MARK: - state machine

/// Pure interview state. `save` is the ONLY side effect (a profile-fact write);
/// `defaults` carries the done flag + the resumable step. Internal (not
/// private) for UnstuckAppTests.
@MainActor
@Observable
final class InterviewMachine {
    /// Same key as the web (STORAGE_KEYS.GATEWAY_INTERVIEW_DONE) — "1" once done.
    /// Sign-out must clear it (`resetDone`) so the next account on a shared
    /// device is greeted, not silently skipped.
    nonisolated static let doneKey = "unstuck-gateway-interview-done"
    /// The step to resume at when the panel was collapsed mid-way.
    nonisolated static let stepKey = "unstuck-gateway-interview-step"

    let questions: [InterviewQuestion]
    /// 0..<questions.count = a question; == questions.count = the rituals picker.
    private(set) var step: Int
    /// Facts saved this session, newest last — drives the "✓ Noted: …" line.
    private(set) var noted: [String] = []
    /// True once `finish()` ran — the host stops rendering the panel.
    private(set) var finished = false
    /// Set when the LAST answer's save failed (the local GRDB write threw):
    /// the step is kept so the user can retry, and the panel says so inline.
    /// The UI used to note + advance regardless — "✓ Noted" over a dropped
    /// write was a lie. Cleared by the next successful answer or skip.
    private(set) var saveError: String?

    static let saveFailedMessage = "Couldn’t save that — try again"

    @ObservationIgnored private let defaults: UserDefaults
    /// Persist one fact; false = the write failed (nothing to note).
    @ObservationIgnored private let save: (UnstuckCore.ProfileFactCategory, String) -> Bool
    /// Fired the moment the interview becomes DONE (finish, or reaching the
    /// picker) — the host mirrors the flag to the account
    /// (`AppModel.pushInterviewDone`). At most once per run.
    @ObservationIgnored private let onDone: () -> Void
    @ObservationIgnored private var doneNotified = false

    init(questions: [InterviewQuestion] = INTERVIEW_QUESTIONS,
         defaults: UserDefaults = .standard,
         save: @escaping (UnstuckCore.ProfileFactCategory, String) -> Bool,
         onDone: @escaping () -> Void = {}) {
        self.questions = questions
        self.defaults = defaults
        self.save = save
        self.onDone = onDone
        // Resume where the user left off (a collapse persists the step); a
        // stale/out-of-range value restarts at the greeting.
        let saved = defaults.integer(forKey: Self.stepKey)
        self.step = (0...questions.count).contains(saved) ? saved : 0
    }

    var isPicker: Bool { step >= questions.count }
    var current: InterviewQuestion? { isPicker ? nil : questions[step] }
    /// "2/7" for the eyebrow.
    var progress: String { "\(min(step + 1, questions.count))/\(questions.count)" }
    var isFirstStep: Bool { step == 0 }

    /// Tap a chip: save its fact (if any) and advance. A failed save keeps
    /// the step (and says so) — nothing is noted that didn't land.
    func answer(chip: InterviewChip) {
        guard let q = current else { return }
        if let fact = chip.fact {
            guard store(q.category, fact) else { return }
        }
        saveError = nil
        advance()
    }

    /// Free-text answer. Empty → no-op (stays on the question). Name questions
    /// split into one person fact per name (`splitPeople`). Advances only when
    /// EVERY piece saved; the ones that did are noted, and a retry re-saves
    /// the rest (saves are refine-in-place, so nothing duplicates).
    func answerFree(_ text: String) {
        guard let q = current else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let facts: [String]
        if q.splitNames {
            facts = Self.splitPeople(t)
            guard !facts.isEmpty else { return }
        } else {
            facts = [q.freePrefix.map { "\($0): \(t)" } ?? t]
        }
        var allSaved = true
        for f in facts where !store(q.category, f) { allSaved = false }
        guard allSaved else { return }
        saveError = nil
        advance()
    }

    /// The people answer → person facts. Commas separate NAMES ("Maleek, Sam")
    /// — unless the text carries a descriptor dash ("Maleek — son, 9"), where
    /// the comma is part of the description and the whole line is one fact
    /// (profile.ts convention: leading name, dash, detail). Pieces without a
    /// letter ("9") are dropped, and a name only ever yields one fact.
    nonisolated static func splitPeople(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces: [String] = hasDescriptorDash(t) ? [t] : t.split(separator: ",").map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for raw in pieces {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.contains(where: { $0.isLetter }) else { continue }
            let key = leadName(p).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(p)
        }
        return out
    }

    /// An em/en dash anywhere, or a hyphen next to whitespace ("Maleek - son");
    /// a hyphen INSIDE a word ("Mary-Jane") is part of the name.
    private nonisolated static func hasDescriptorDash(_ s: String) -> Bool {
        if s.contains("—") || s.contains("–") { return true }
        let chars = Array(s)
        for (i, c) in chars.enumerated() where c == "-" {
            let before = i > 0 ? chars[i - 1] : " "
            let after = i + 1 < chars.count ? chars[i + 1] : " "
            if before.isWhitespace || after.isWhitespace { return true }
        }
        return false
    }

    /// "Maleek — son, 9" → "maleek"-comparable head (moments.ts `leadName`).
    private nonisolated static func leadName(_ fact: String) -> String {
        let seps: Set<Character> = ["—", "–", "-", ","]
        return String(fact.prefix { !$0.isWhitespace && !seps.contains($0) })
    }

    /// Skip just this question (nothing saved).
    func skipQuestion() {
        saveError = nil
        advance()
    }

    /// "That's me set up" / "I'm done": mark done — never re-asks, on ANY
    /// device (the host pushes the account flag via `onDone`). Facts already
    /// saved stay.
    func finish() {
        Self.markDone(defaults)
        finished = true
        notifyDone()
    }

    /// Park the interview WITHOUT finishing: the step is persisted so the
    /// next visit resumes here — also across relaunch. Nothing is marked
    /// done. Web parity: the web has no "Skip for now"; its two controls are
    /// the per-question Skip and "I'm done".
    func collapse() { markInProgress() }

    /// Persist the current step. The thread driver calls this the moment it
    /// starts asking, so a mid-way parked step (> 0) is visible to the
    /// ≥1-fact stand-down rule (`shouldAutoComplete`) and the questions
    /// resume where they left off.
    func markInProgress() {
        defaults.set(step, forKey: Self.stepKey)
    }

    /// True = landed (noted); false = the write failed (step kept, error shown).
    private func store(_ category: UnstuckCore.ProfileFactCategory, _ fact: String) -> Bool {
        guard save(category, fact) else {
            saveError = Self.saveFailedMessage
            return false
        }
        noted.append(fact)
        return true
    }

    private func advance() {
        step = min(step + 1, questions.count)
        defaults.set(step, forKey: Self.stepKey)
        // Reaching the picker IS being onboarded — even when every answer was
        // a null-fact chip ("It varies", "No one right now"): the ≥1-fact
        // auto-done can't see those, and leaving before "That's me set up"
        // used to keep them un-done and re-asked (web parity, 2026-09-05).
        // The picker still renders; `finish` is what dismisses it.
        if isPicker {
            Self.markDone(defaults)
            notifyDone()
        }
    }

    private func notifyDone() {
        guard !doneNotified else { return }
        doneNotified = true
        onDone()
    }

    // MARK: done flag

    nonisolated static func isDone(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: doneKey) == "1"
    }
    nonisolated static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set("1", forKey: doneKey)
        defaults.removeObject(forKey: stepKey)
    }
    /// Sign-out wipe hook (AppModel.scrubDeviceLocalUserContent should call
    /// this): forget both the done flag and the resume step.
    nonisolated static func resetDone(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: doneKey)
        defaults.removeObject(forKey: stepKey)
    }

    /// True while a mid-way step is persisted (a collapse / "Skip for now",
    /// or any advance that hasn't reached `finish`): the user is still IN the
    /// interview, just not looking at it.
    nonisolated static func hasResumeStep(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: stepKey) != nil
    }

    /// The parked step, if any (nil = nothing persisted).
    nonisolated static func parkedStep(_ defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: stepKey) as? Int
    }

    /// Onboarding by CONVERSATION counts: once ≥1 real fact exists (saved by
    /// voice/chat/settings/another device) the interview stands down — asking
    /// again reads as "the AI isn't saving anything". ONE fact (web parity,
    /// 2026-09-05; was three): a single saved fact means they engaged, and
    /// the higher bar re-asked people on a second device with 1–2 synced
    /// facts. NEVER while the panel is open: its own answers grow the count
    /// and auto-closing mid-interview looks like a crash (web flow review,
    /// 2026-08-30). And NEVER while a step PAST the first is parked: that
    /// fact may be its OWN answer from a hidden-mid-way run, and
    /// auto-completing there skipped the rest + the rituals picker on
    /// relaunch. A parked step 0 (auto-opened, never answered) can't hold its
    /// own answers, so facts from elsewhere still stand it down.
    nonisolated static func shouldAutoComplete(factCount: Int, isOpen: Bool, done: Bool,
                                               parkedStep: Int? = nil) -> Bool {
        !done && !isOpen && (parkedStep ?? 0) == 0 && factCount >= 1
    }
}

// MARK: - rituals picker chips

/// The four ritual toggles as selectable chips (the interview's last step,
/// now inside the assistant thread). Copy from RITUAL_LABELS so the
/// interview, Settings and the web read identically.
struct RitualChips: View {
    @Environment(\.uTheme) private var theme
    let isOn: (RitualKey) -> Bool
    let set: (RitualKey, Bool) -> Void

    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(RITUAL_LABELS, id: \.key) { r in
                let on = isOn(r.key)
                Button { set(r.key, !on) } label: {
                    Text((on ? "✓ " : "") + r.label)   // glyph is visual only — label below reads the name
                        .font(UFont.sans(13)).foregroundStyle(on ? theme.palette.bg : theme.palette.ink2)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .frame(minHeight: 44)
                        // Selection is the app's black-and-white pair (ink fill,
                        // bg text) — the same idiom as every other chip.
                        .background(on ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                        .overlay(Capsule().stroke(on ? Color.clear : theme.palette.line2))
                }.buttonStyle(.plain)
                    .accessibilityLabel(r.label)
                    .accessibilityHint(r.sub)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
