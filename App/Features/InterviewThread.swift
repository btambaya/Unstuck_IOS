// The get-to-know-you interview, re-hosted INSIDE the assistant thread.
// The Today card that carried it (its "Personalise your assistant" pill and
// inline panel) is gone (Ahmad, 2026-09-17). A user who has not finished or
// skipped the interview meets it in the assistant itself:
//
//  • TEXT — after the FIRST message of a visit is handled the normal way
//    (the reply comes first), the client appends the questions as LOCAL
//    assistant turns, one at a time, with the script's chip answers + Skip
//    (and the free-text field where the script allows one). If the user
//    changes the subject mid-way, the assistant answers that first and the
//    current question is asked again underneath. ZERO tokens: the local
//    turns never enter the model window.
//  • VOICE — the opening primer asks the same questions aloud
//    (AssistantContext.buildVoiceOpening) and `finish_interview` closes it.
//
// Same `InterviewMachine`, same profile-facts store, same done flag / resume
// step as before — only the host changed. The driver below is pure enough to
// unit test: the thread is reached through two closures (`post` appends an
// assistant turn and returns its id, `echo` appends the user's tap).

import SwiftUI
import UnstuckCore
import UnstuckDesign

/// Marks a LOCAL assistant turn as one interview prompt: the question key,
/// or `pickerKey` for the rituals step. The sheet draws the chip row under
/// the prompt the driver is currently asking (`promptTurnId`); older prompts
/// (a relaunch, a re-ask after the user changed the subject) render as plain
/// text. Persisted with the turn; never sent upstream.
struct InterviewPromptMeta: Codable, Equatable, Sendable {
    var key: String
    static let pickerKey = "picker"
}

@MainActor
@Observable
final class InterviewThreadDriver {
    enum Phase: Equatable {
        /// Nothing sent this visit yet.
        case idle
        /// The user's first message is in flight — the reply comes first.
        case waitingForReply
        /// A question (or the rituals picker) is on screen with its chips.
        case asking
        /// Finished or stood down — nothing more to ask, ever.
        case done
    }

    let machine: InterviewMachine
    private(set) var phase: Phase = .idle
    /// The id of the thread turn carrying the live chip row (nil = none).
    private(set) var promptTurnId: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let firstName: String?
    /// Whether the account's memory has been read (the profile-facts hydrate
    /// + the server done-flag): a decision before that greeted a fresh
    /// install of an onboarded account as a stranger.
    @ObservationIgnored private let ready: () -> Bool
    /// Live count of ACTIVE profile facts — the stand-down rule's input.
    @ObservationIgnored private let factCount: () -> Int
    /// Append a local assistant turn → its id.
    @ObservationIgnored private let post: (String, InterviewPromptMeta?) -> String
    /// Append the user's tap as a local user bubble.
    @ObservationIgnored private let echo: (String) -> Void
    @ObservationIgnored private var greeted = false

    init(machine: InterviewMachine,
         firstName: String?,
         defaults: UserDefaults = .standard,
         ready: @escaping () -> Bool = { true },
         factCount: @escaping () -> Int,
         post: @escaping (String, InterviewPromptMeta?) -> String,
         echo: @escaping (String) -> Void) {
        self.machine = machine
        self.firstName = firstName
        self.defaults = defaults
        self.ready = ready
        self.factCount = factCount
        self.post = post
        self.echo = echo
    }

    /// The chip row is on screen.
    var isAsking: Bool { phase == .asking }

    // MARK: - thread events

    /// The user sent a message. The FIRST one of a visit arms the interview —
    /// the reply to it comes first, the question after. Someone who already
    /// has facts from elsewhere (web, another device) with nothing parked
    /// mid-way is stood down here instead: the existing ≥1-fact rule, so a
    /// person the assistant already knows is never greeted as a stranger.
    func userSent() {
        guard phase == .idle, ready() else { return }
        if InterviewMachine.isDone(defaults) { phase = .done; return }
        if InterviewMachine.shouldAutoComplete(factCount: factCount(), isOpen: false, done: false,
                                               parkedStep: InterviewMachine.parkedStep(defaults)) {
            machine.finish()
            phase = .done
            return
        }
        phase = .waitingForReply
    }

    /// A turn finished (reply or error) — the assistant has handled what the
    /// user asked; now ask the current question. While a question is already
    /// up this is the user having changed the subject: the reply came first,
    /// the same question goes underneath it again.
    func turnFinished() {
        switch phase {
        case .waitingForReply:
            phase = .asking
            machine.markInProgress()
            ask()
        case .asking:
            ask()
        case .idle, .done:
            break
        }
    }

    // MARK: - answers

    /// Tap a chip: save its fact (if any) and move on. A failed save keeps
    /// the question up and says so (`machine.saveError`) — nothing is echoed
    /// that didn't land.
    func answer(chip: InterviewChip) {
        guard phase == .asking, machine.current != nil else { return }
        let before = machine.step
        machine.answer(chip: chip)
        guard machine.step > before else { return }
        echo(chip.label)
        ask()
    }

    /// Free-text answer (the questions that allow one). Empty → no-op.
    func answerFree(_ text: String) {
        guard phase == .asking, machine.current != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let before = machine.step
        machine.answerFree(t)
        guard machine.step > before else { return }
        echo(t)
        ask()
    }

    /// Skip just this question (nothing saved).
    func skip() {
        guard phase == .asking, machine.current != nil else { return }
        machine.skipQuestion()
        echo("Skip")
        ask()
    }

    /// "That's me set up" on the rituals picker — the finisher. Marks done
    /// (never re-asks, on any device) and closes with one line.
    func finish() {
        guard phase == .asking else { return }
        machine.finish()
        promptTurnId = nil
        phase = .done
        _ = post(Self.closingLine, nil)
    }

    // MARK: - prompts

    private func ask() {
        if machine.isFirstStep, !greeted {
            greeted = true
            _ = post(Self.greeting(firstName: firstName), nil)
        }
        if let q = machine.current {
            promptTurnId = post(q.question, InterviewPromptMeta(key: q.key))
        } else {
            promptTurnId = post(Self.pickerQuestion, InterviewPromptMeta(key: InterviewPromptMeta.pickerKey))
        }
    }

    /// The agent's first words to a new user: the web interview's greeting
    /// verbatim, then the small-print disclosure of what happens to the answers.
    static func greeting(firstName: String?) -> String {
        "Hey\(firstName.map { " \($0)" } ?? ""). A few quick questions so I can plan around your actual life — skip any you like.\n\n"
            + "I’ll remember what you tell me; it stays yours — see What Unstuck knows in Settings to view or delete any of it. "
            + "Facts are shared with our AI provider (which doesn’t train on them) so I can help."
    }

    static let pickerQuestion = "Last one — which moments should I run for you? All optional, all changeable in Settings."
    static let closingLine = "That’s everything — I’ll plan around it. Change any of it in Settings → What Unstuck knows."
}

// MARK: - the chip row

/// The answers for the prompt the driver is asking, drawn under that turn's
/// bubble: chips + Skip (+ the free-text field where the script allows one),
/// or the rituals picker + "That's me set up". The eyebrow keeps the web's
/// "GETTING TO KNOW YOU · n/7". Chip + button styling is the interview's own
/// (the old inline panel) — nothing new.
struct InterviewPromptRow: View {
    @Environment(\.uTheme) private var theme
    let driver: InterviewThreadDriver
    let ritualIsOn: (RitualKey) -> Bool
    let setRitual: (RitualKey, Bool) -> Void

    @State private var free = ""

    var body: some View {
        let machine = driver.machine
        VStack(alignment: .leading, spacing: 8) {
            Text(machine.isPicker ? "LAST ONE" : "GETTING TO KNOW YOU · \(machine.progress)")
                .font(UFont.mono(10, .semibold)).tracking(1.2)
                .foregroundStyle(theme.palette.ink3)
            if let q = machine.current {
                chips(q)
                if q.allowFree { freeField(q) }
            } else if machine.isPicker {
                picker
            }
            // A dropped local write keeps the step and says so — never an
            // echoed answer the store didn't take.
            if let err = machine.saveError {
                Text(err)
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                    .accessibilityLabel(err)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting to know you")
        .accessibilityIdentifier("interview-prompt")
    }

    private func chips(_ q: InterviewQuestion) -> some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(q.chips.enumerated()), id: \.offset) { _, chip in
                Button { driver.answer(chip: chip); free = "" } label: {
                    Text(chip.label)
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(theme.palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line2))
                }.buttonStyle(.plain)
            }
            Button { driver.skip(); free = "" } label: {
                Text("Skip").font(UFont.sans(12.5)).foregroundStyle(theme.palette.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 8)
                    .frame(minHeight: 44)
            }.buttonStyle(.plain)
                .accessibilityLabel("Skip this question")
        }
    }

    private func freeField(_ q: InterviewQuestion) -> some View {
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
                .accessibilityIdentifier("interview-free-text")
            let can = !free.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: saveFree) {
                Text("Save").font(UFont.sans(12.5, .semibold))
                    .foregroundStyle(can ? .white : theme.palette.ink3)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(can ? theme.palette.coral : theme.palette.bg2, in: Capsule())
            }.buttonStyle(.plain).disabled(!can)
        }
    }

    private func saveFree() {
        let t = free
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        driver.answerFree(t)
        free = ""
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            RitualChips(isOn: ritualIsOn, set: setRitual)
            Button { driver.finish() } label: {
                Text("That’s me set up").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(theme.palette.coral, in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel("That’s me set up")
        }
    }
}

// MARK: - voice

/// The same seven questions as one spoken list for the voice opening primer
/// (AssistantContext.buildVoiceOpening) — keyed by the script's keys so the
/// two hosts can never drift apart (a unit test checks every key has a line).
enum InterviewVoice {
    static let spoken: [String: String] = [
        "rhythm": "when their head's clearest — mornings, afternoons or evenings",
        "work": "what their work days look like — the hours and days",
        "people": "anyone whose schedule shapes theirs — kids, a partner, someone they care for (names help)",
        "fixed": "fixed points in the week to plan around — school runs, prayers, classes",
        "commitments": "regular commitments — gym, rehearsals, clubs, volunteering",
        "nogo": "times to never schedule anything",
        "nudge": "how they'd like to be nudged — gently, kept honest, or barely at all",
    ]

    /// "; "-joined spoken lines for the questions from `index` on (the first
    /// is spoken verbatim in the primer's greeting, so the list starts at 1).
    static func questionList(from index: Int = 1, questions: [InterviewQuestion] = INTERVIEW_QUESTIONS) -> String {
        questions.dropFirst(index).compactMap { spoken[$0.key] }.joined(separator: "; ")
    }
}
