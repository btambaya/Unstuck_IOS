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
// Presented INLINE inside the gateway card on Today (web parity: an inline
// panel, not a modal). The state machine (`InterviewMachine`) is pure and
// UserDefaults-injectable so the step/auto-done/resume/skip rules are unit
// tested without SwiftUI.

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
let INTERVIEW_QUESTIONS: [InterviewQuestion] = [
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
            InterviewChip(label: "Before 9am", fact: "Never schedule anything before 9am"),
            InterviewChip(label: "After 9pm", fact: "Never schedule anything after 9pm"),
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
]

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

    /// Park the panel WITHOUT finishing (the header chevron): the step is
    /// persisted so re-opening resumes here — also across relaunch — and,
    /// while parked, the card shows the pill instead of popping the panel
    /// open again (`shouldAutoOpen`). Nothing is marked done. Web parity: the
    /// web has no "Skip for now"; its two controls are the per-question Skip
    /// and the header "I'm done".
    func collapse() { markInProgress() }

    /// Persist the current step. The card calls this the moment it OPENS the
    /// panel: the auto-open gate is per-process, so without a persisted step
    /// a user with 0 facts got the panel at 1/N on EVERY cold launch — the
    /// nag it exists to avoid. From then on the pill is the way in.
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

    /// Whether to open the interview by itself: nothing learned anywhere, not
    /// done, and not parked ("Skip for now" persists a resume step — popping
    /// back open on the next launch would be the nag it exists to avoid; the
    /// pill is the way back in). Every question is skippable.
    nonisolated static func shouldAutoOpen(factCount: Int, done: Bool, hasResumeStep: Bool = false) -> Bool {
        !done && !hasResumeStep && factCount == 0
    }
}

/// When the card may open the interview BY ITSELF: exactly once, and only
/// after BOTH the local facts have been read AND the server hydrate has
/// completed (success or failure/offline). Deciding on the first local
/// emission flashed the interview open on a fresh install whose facts live on
/// the web, then slammed it shut when the hydrate landed. Pure and tested.
struct InterviewAutoOpenGate: Equatable {
    private(set) var decided = false

    /// Feed every change (facts emission, hydrate flag flip). Returns true
    /// exactly once — the moment the panel should open.
    mutating func evaluate(hydrated: Bool, factsLoaded: Bool, factCount: Int, done: Bool,
                           hasResumeStep: Bool = false) -> Bool {
        guard !decided, hydrated, factsLoaded else { return false }
        decided = true
        return InterviewMachine.shouldAutoOpen(factCount: factCount, done: done, hasResumeStep: hasResumeStep)
    }
}

// MARK: - inline panel

/// The interview panel rendered inside the gateway card. `firstName` greets;
/// `onFinished` fires after finish/skip; `onCollapse` hides the panel
/// (resumable). Ritual toggles are wired by the host (`ritualIsOn`/`setRitual`)
/// so this view doesn't depend on the prefs store's shape.
struct InterviewFlowView: View {
    @Environment(\.uTheme) private var theme
    @Bindable var machine: InterviewMachine
    let firstName: String?
    let ritualIsOn: (RitualKey) -> Bool
    let setRitual: (RitualKey, Bool) -> Void
    let onFinished: () -> Void
    let onCollapse: () -> Void

    @State private var free = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if machine.isFirstStep {
                greeting
            }
            HStack(alignment: .firstTextBaseline) {
                Text(machine.isPicker ? "LAST ONE" : "GETTING TO KNOW YOU · \(machine.progress)")
                    .font(UFont.mono(10, .semibold)).tracking(1.2)
                    .foregroundStyle(theme.palette.ink3)
                Spacer(minLength: 8)
                // The web's two controls: the per-question Skip (below) and
                // "I'm done" — the finisher that never re-asks. The chevron
                // only PARKS the panel (the pill resumes it); it replaced a
                // "Skip for now" label that read as a third kind of skip.
                Button { machine.finish(); onFinished() } label: {
                    Text("I’m done").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("I’m done")
                    .accessibilityHint("Finishes the interview; it won’t ask again")
                Button { machine.collapse(); onCollapse() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.ink3)
                        .frame(width: 32, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Hide for now")
                    .accessibilityHint("Hides the questions; resume any time from the card")
            }

            if let q = machine.current {
                question(q)
            } else {
                ritualsPicker
            }

            // A dropped local write keeps the step and says so — never a
            // "✓ Noted" the store didn't take.
            if let err = machine.saveError {
                Text(err)
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.theme.palette.red)
                    .accessibilityLabel(err)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let last = machine.noted.last {
                Text("✓ Noted: \(last)")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .lineLimit(2)
                    .accessibilityLabel("Noted: \(last)")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting to know you")
    }

    // The agent's FIRST words to a new user: one plain line (no permission
    // request, no tagline — mirrors the web interview.tsx greeting verbatim),
    // then the small-print disclosure of what happens to the answers.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hey\(firstName.map { " \($0)" } ?? ""). A few quick questions so I can plan around your actual life — skip any you like.")
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
                .lineSpacing(3)
            Text("I’ll remember what you tell me; it stays yours — see What Unstuck knows in Settings to view or delete any of it. Facts are shared with our AI provider (which doesn’t train on them) so I can help.")
                .font(UFont.sans(11.5)).foregroundStyle(theme.palette.ink3)
                .lineSpacing(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.palette.bg2, in: UnevenRoundedRectangle(
            topLeadingRadius: 14, bottomLeadingRadius: 6, bottomTrailingRadius: 14, topTrailingRadius: 14,
            style: .continuous))
        .overlay(UnevenRoundedRectangle(
            topLeadingRadius: 14, bottomLeadingRadius: 6, bottomTrailingRadius: 14, topTrailingRadius: 14,
            style: .continuous).stroke(theme.palette.line))
    }

    @ViewBuilder
    private func question(_ q: InterviewQuestion) -> some View {
        Text(q.question)
            .font(UFont.serif(19)).foregroundStyle(theme.palette.ink)
            .lineSpacing(2)
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(q.chips.enumerated()), id: \.offset) { _, chip in
                Button { machine.answer(chip: chip); free = "" } label: {
                    Text(chip.label)
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(theme.palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line2))
                }.buttonStyle(.plain)
            }
            Button { machine.skipQuestion(); free = "" } label: {
                Text("Skip").font(UFont.sans(12.5)).foregroundStyle(theme.palette.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 8)
            }.buttonStyle(.plain)
                .accessibilityLabel("Skip this question")
        }
        if q.allowFree {
            HStack(spacing: 6) {
                TextField(q.splitNames ? "…or type names, comma-separated" : "…or type it", text: $free)
                    .font(UFont.sans(13.5)).foregroundStyle(theme.palette.ink)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit(saveFree)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(theme.palette.bg2, in: Capsule())
                    .overlay(Capsule().stroke(theme.palette.line))
                    .accessibilityLabel("Type an answer")
                let can = !free.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: saveFree) {
                    Text("Save").font(UFont.sans(12.5, .semibold))
                        .foregroundStyle(can ? .white : theme.palette.ink3)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(can ? theme.palette.coral : theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain).disabled(!can)
            }
        }
    }

    private func saveFree() {
        let t = free
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        machine.answerFree(t)
        free = ""
    }

    /// Final step — which recurring moments the assistant should run. The
    /// rituals themselves are a personalisation choice; all changeable in
    /// Settings → What Unstuck knows.
    private var ritualsPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which moments should I run for you? All optional, all changeable in Settings.")
                .font(UFont.serif(19)).foregroundStyle(theme.palette.ink)
                .lineSpacing(2)
            RitualChips(isOn: ritualIsOn, set: setRitual)
            Button { machine.finish(); onFinished() } label: {
                Text("That’s me set up").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(theme.palette.coral, in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel("That’s me set up")
        }
    }
}

/// The four ritual toggles as selectable chips (interview picker). Copy from
/// RITUAL_LABELS so the interview, Settings and the web read identically.
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
                        .font(UFont.sans(13)).foregroundStyle(on ? .white : theme.palette.ink)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(on ? theme.palette.coral : theme.palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(on ? theme.palette.coral : theme.palette.line2))
                }.buttonStyle(.plain)
                    .accessibilityLabel(r.label)
                    .accessibilityHint(r.sub)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
