// The get-to-know-you interview — the assistant's FIRST contact (iOS port of
// components/assistant/interview.tsx). Scripted and ZERO-token: chip answers
// and free text write profile facts directly (source .interview); the LLM is
// never involved. One question at a time, every question skippable, "Skip for
// now" always visible — the documented ADHD dropout point is a long setup
// wizard, so this must never feel like one. Everything saved is visible (and
// deletable) in Settings → "What Unstuck knows".
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

/// The script. Order: chronotype → people → work hours → never-before → nudge
/// style, then the rituals picker as the final step. Copy mirrors the web
/// interview so a fact reads the same whichever device wrote it.
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
        key: "people", category: .person,
        question: "Anyone whose schedule shapes yours — kids, a partner, someone you care for? Names help.",
        chips: [InterviewChip(label: "No one right now", fact: nil)],
        allowFree: true, splitNames: true),
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let save: (UnstuckCore.ProfileFactCategory, String) -> Void

    init(questions: [InterviewQuestion] = INTERVIEW_QUESTIONS,
         defaults: UserDefaults = .standard,
         save: @escaping (UnstuckCore.ProfileFactCategory, String) -> Void) {
        self.questions = questions
        self.defaults = defaults
        self.save = save
        // Resume where the user left off (a collapse persists the step); a
        // stale/out-of-range value restarts at the greeting.
        let saved = defaults.integer(forKey: Self.stepKey)
        self.step = (0...questions.count).contains(saved) ? saved : 0
    }

    var isPicker: Bool { step >= questions.count }
    var current: InterviewQuestion? { isPicker ? nil : questions[step] }
    /// "2/5" for the eyebrow.
    var progress: String { "\(min(step + 1, questions.count))/\(questions.count)" }
    var isFirstStep: Bool { step == 0 }

    /// Tap a chip: save its fact (if any) and advance.
    func answer(chip: InterviewChip) {
        guard let q = current else { return }
        if let fact = chip.fact { store(q.category, fact) }
        advance()
    }

    /// Free-text answer. Empty → no-op (stays on the question). Name questions
    /// split into one person fact per name (`splitPeople`).
    func answerFree(_ text: String) {
        guard let q = current else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if q.splitNames {
            let names = Self.splitPeople(t)
            guard !names.isEmpty else { return }
            for n in names { store(q.category, n) }
        } else {
            store(q.category, q.freePrefix.map { "\($0): \(t)" } ?? t)
        }
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
    func skipQuestion() { advance() }

    /// "That's me set up" / "I'm done": mark done — never re-asks. Facts
    /// already saved stay.
    func finish() {
        Self.markDone(defaults)
        finished = true
    }

    /// "Skip for now": NOT final (web parity — its finisher is "I'm done").
    /// The panel collapses and the step is persisted so the pill resumes
    /// here; nothing is marked done. Same as `collapse`.
    func skip() { collapse() }

    /// Collapse the panel mid-way WITHOUT finishing: the step is persisted so
    /// re-opening resumes here (also across relaunch).
    func collapse() {
        defaults.set(step, forKey: Self.stepKey)
    }

    private func store(_ category: UnstuckCore.ProfileFactCategory, _ fact: String) {
        save(category, fact)
        noted.append(fact)
    }

    private func advance() {
        step = min(step + 1, questions.count)
        defaults.set(step, forKey: Self.stepKey)
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

    /// Onboarding by CONVERSATION counts: once ≥3 real facts exist (saved by
    /// voice/chat/settings) the interview stands down — asking again reads as
    /// "the AI isn't saving anything". NEVER while the panel is open: its own
    /// answers grow the count and auto-closing at answer 3 of 5 looks like a
    /// crash (web flow review, 2026-08-30). And NEVER while a resume step is
    /// saved: those ≥3 facts are its OWN answers from a hidden-mid-way run,
    /// and auto-completing there skipped the rituals picker on relaunch.
    nonisolated static func shouldAutoComplete(factCount: Int, isOpen: Bool, done: Bool,
                                               hasResumeStep: Bool = false) -> Bool {
        !done && !isOpen && !hasResumeStep && factCount >= 3
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
                // Two ways out, both always visible: "Skip for now" parks it
                // (the pill resumes here); "I'm done" is the finisher that
                // never re-asks (web parity).
                Button { machine.skip(); onCollapse() } label: {
                    Text("Skip for now").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Skip for now")
                    .accessibilityHint("Hides the questions; resume any time from the card")
                Button { machine.finish(); onFinished() } label: {
                    Text("I’m done").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("I’m done")
                    .accessibilityHint("Finishes the interview; it won’t ask again")
            }

            if let q = machine.current {
                question(q)
            } else {
                ritualsPicker
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

    // The agent's FIRST words to a new user: it introduces itself before it
    // asks anything, and discloses what happens to the answers.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("Hey\(firstName.map { " \($0)" } ?? "") — I’m your assistant here. Before we get started, can I get to know you a little? It makes everything I do actually ")
                + Text("yours").italic()
                + Text(". Skip anything you like."))
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
