// The AI gateway card on Today — iOS port of components/dashboard/gateway-card.tsx.
// ADDITIVE by design: it sits between the greeting and the recap/hero; the
// Start-Next hero, recap and list stay. Under the greeting: a deterministic
// zero-token brief (composeBrief), ONE "moment" from the PA engine
// (pickMoment — rituals the user opted into, notices from their behaviour,
// relationship reminders), the first-run interview, and a single composer
// whose send HANDS OFF to the Assistant sheet (which already owns the thread —
// decision 3, docs/ios-gateway-plan.md). Moments REPLACE the old quiet-nudge
// card (decision 2: they subsume slip radar / habit gaps).
//
// The action reducer (`GatewayActions`) and the dismiss/done bookkeeping
// (`GatewayMomentState`) are pure and unit tested; the view only wires them to
// AppModel's write methods.

import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

// MARK: - pure action reducer

/// What a moment action wants written — the view applies these through
/// AppModel.saveBlock / saveTask. Pure so the recurring-safe carry + moveCount
/// rules are testable without a store.
struct GatewayWrites: Equatable {
    var blocks: [CalBlock] = []
    var tasks: [TaskItem] = []
    var confirmation: String
}

enum GatewayActions {
    /// `carry_tasks`: move today's unfinished blocks for `taskIds` to tomorrow.
    /// Carries only what was actually on today. A recurring task usually
    /// ALREADY has tomorrow's occurrence — moving today's block would double
    /// it up, so today's is marked skipped instead (same outcome, no
    /// duplicate). Every real carry bumps the task's moveCount — an honest slip
    /// counter is what makes Slip Radar honest.
    static func carryTasks(taskIds: [String], tasks: [TaskItem], blocks: [CalBlock],
                           todayIso: String, tomorrowIso: String, nowISO: String) -> GatewayWrites {
        var out = GatewayWrites(confirmation: "")
        var n = 0
        for id in taskIds {
            guard let b = blocks.first(where: { $0.taskId == id && $0.date == todayIso && !$0.done && !$0.skipped })
            else { continue }
            let tomorrowTaken = blocks.contains { $0.taskId == id && $0.date == tomorrowIso && !$0.skipped }
            var next = b
            if tomorrowTaken { next.skipped = true } else { next.date = tomorrowIso }
            out.blocks.append(next)
            n += 1
            if let t = tasks.first(where: { $0.id == id }) {
                out.tasks.append(bumpMoveCount(t, nowISO: nowISO))
            }
        }
        out.confirmation = "Carried \(n) to tomorrow."
        return out
    }

    /// `schedule`: move only a LIVE, upcoming block for the task (grabbing a
    /// skipped or historical one said "Blocked ✓" while dragging history
    /// around); otherwise create a fresh block. No moveCount bump (web parity —
    /// booking a habit gap isn't a slip).
    static func schedule(taskId: String, date: String, time: String?, tasks: [TaskItem], blocks: [CalBlock],
                         todayIso: String, newId: String) -> GatewayWrites {
        let t = tasks.first { $0.id == taskId }
        let name = t?.name ?? "Task"
        var block: CalBlock
        if let anchor = blocks.first(where: { $0.taskId == taskId && !$0.done && !$0.skipped && $0.date >= todayIso }) {
            block = anchor
            block.date = date
            if let time { block.startTime = time }
        } else {
            block = CalBlock(id: newId, taskId: taskId, taskName: name, startTime: time ?? "09:00",
                             durationMinutes: t?.estimateMin ?? 30, date: date, kind: .task)
        }
        return GatewayWrites(blocks: [block], tasks: [],
                             confirmation: "Blocked — \(name), \(date)\(time.map { " " + $0 } ?? "").")
    }

    /// `create_task`: a plain new task (estimate defaults to 25 like the web).
    static func createTask(name: String, estimateMin: Int?, id: String, nowISO: String) -> GatewayWrites {
        let t = TaskItem(id: id, name: name, estimateMin: estimateMin ?? 25, createdAt: nowISO, updatedAt: nowISO)
        return GatewayWrites(blocks: [], tasks: [t], confirmation: "Added “\(name)”.")
    }
}

// MARK: - dismiss / done bookkeeping

/// The card's moment bookkeeping: which ids are dismissed (persisted through
/// `persist`, cross-launch) and the ✓ confirmation shown after an action. The
/// confirmation is a moment, not a mute button — the host clears it after ~8 s
/// (`clearDone`) so the NEXT undismissed moment can surface.
@MainActor
@Observable
final class GatewayMomentState {
    private(set) var dismissed: Set<String>
    private(set) var momentDone: String?
    @ObservationIgnored private let persist: (Set<String>) -> Void

    init(dismissed: Set<String>, persist: @escaping (Set<String>) -> Void) {
        self.dismissed = dismissed
        self.persist = persist
    }

    func isDismissed(_ id: String) -> Bool { dismissed.contains(id) }

    /// Record the dismissal (merged with what's already on disk via
    /// `alreadyOnDisk` — another surface may have dismissed since we mounted)
    /// and show the confirmation, if any.
    func settle(_ id: String, confirmation: String?, alreadyOnDisk: Set<String> = []) {
        dismissed = dismissed.union(alreadyOnDisk).union([id])
        persist(dismissed)
        momentDone = confirmation
    }

    /// Clear the confirmation — only if it's still the one we set (a newer
    /// action's ✓ must not be wiped by an older timer).
    func clearDone(if confirmation: String) {
        if momentDone == confirmation { momentDone = nil }
    }
}

// MARK: - the card

struct GatewayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let vm: TodayModel
    /// Talk-mode entry (the mic inside the composer) — the host presents
    /// VoiceModeScreen, exactly as the Assistant sheet does.
    let onTalk: () -> Void

    @State private var draft = ""
    @State private var moments: GatewayMomentState?
    @State private var interview: InterviewMachine?
    @State private var interviewOpen = false
    @State private var interviewDone = true   // corrected once the facts land
    @State private var facts: [ProfileFact] = []
    @State private var factsLoaded = false
    /// Re-ticks each minute: the brief ("…is the anchor") and the time-gated
    /// moments (evening sweep at 17:30) must appear/refresh while Today just
    /// sits open — without this they froze until some data changed.
    @State private var clock = 0
    @SwiftUI.FocusState private var fieldFocused: Bool

    private static let chips: [(label: String, msg: String)] = [
        ("✦ Plan my day", "Plan my day — what should I start with and what order makes sense?"),
        ("Brain-dump", "I want to brain-dump everything on my mind — ready?"),
        ("What’s this week?", "What have I got coming up this week?"),
    ]

    var body: some View {
        if model.assistantEnabled {
            card
                .task { bootstrap() }
                .task { await observeFacts() }
                .task {
                    // Minute tick (cancelled with the view).
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        clock += 1
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    clock += 1
                }
                .onChange(of: facts.count) { _, n in factsChanged(count: n) }
        }
    }

    private var card: some View {
        let now = Date()
        _ = clock   // body depends on the tick
        let brief = composeBriefLine(now: now)
        let moment = interviewOpen ? nil : currentMoment(now: now)
        return VStack(alignment: .leading, spacing: 12) {
            identityRow(brief)

            // One PA moment at a time — ritual, notice, or relationship.
            if let done = moments?.momentDone {
                Text("✓ \(done)")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    .accessibilityAddTraits(.updatesFrequently)
                    .task(id: done) {
                        try? await Task.sleep(for: .seconds(8))
                        moments?.clearDone(if: done)
                    }
            } else if let moment {
                momentView(moment)
            }

            // First-run interview — the profile bootstrap. The pill stays until
            // the interview is DONE (not merely started): leaving after 1–2
            // answers used to dead-end onboarding with no way back in.
            if !interviewDone && !interviewOpen {
                Button { openInterview() } label: {
                    Text("✦ Personalise your assistant — two minutes, skip anything")
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(Capsule().stroke(theme.palette.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }.buttonStyle(.plain)
            }
            if interviewOpen, let interview {
                InterviewFlowView(
                    machine: interview,
                    firstName: GreetingName.firstName(model.currentUserName),
                    ritualIsOn: { model.paPrefs.rituals[$0] },
                    setRitual: { model.paPrefs.setRitual($0, on: $1) },
                    onFinished: { interviewOpen = false; interviewDone = true },
                    onCollapse: { interviewOpen = false })
            }

            // Instant CTAs — one tap into a real conversation.
            WrapLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Self.chips, id: \.label) { c in
                    Button { engage(c.msg) } label: {
                        Text(c.label)
                            .font(UFont.sans(12.5, .semibold)).foregroundStyle(theme.palette.coralDeep)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(theme.palette.surface, in: Capsule())
                            .overlay(Capsule().stroke(theme.palette.coral.opacity(0.5)))
                    }.buttonStyle(.plain)
                }
            }

            composer
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [theme.palette.coral.opacity(scheme == .dark ? 0.14 : 0.09), theme.palette.surface],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.coral, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant")
    }

    // Identity row — THIS is the assistant, and it's alive.
    private func identityRow(_ brief: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(theme.palette.coral, in: Circle())
                .shadow(color: theme.palette.coral.opacity(0.45), radius: 4, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR ASSISTANT")
                    .font(UFont.mono(9.5, .semibold)).tracking(1.6)
                    .foregroundStyle(theme.palette.coralDeep)
                // The brief — deterministic, instant, offline-safe.
                Text(brief)
                    .font(UFont.serif(19)).foregroundStyle(theme.palette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func momentView(_ m: Moment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.text)
                .font(UFont.sans(13.5)).italic().foregroundStyle(theme.palette.ink2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(m.actions.enumerated()), id: \.offset) { _, a in
                    let isDismiss = a.run == .dismiss
                    Button { run(m, a) } label: {
                        Text(a.label)
                            .font(UFont.sans(12.5, isDismiss ? .regular : .semibold))
                            .foregroundStyle(isDismiss ? theme.palette.ink2 : .white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(isDismiss ? Color.clear : theme.palette.coral, in: Capsule())
                            .overlay(Capsule().stroke(isDismiss ? theme.palette.line2 : .clear))
                    }.buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Moment")
    }

    // The gateway: one composer. Search-box construction — the sparkles icon
    // lives INSIDE the field, and voice lives INSIDE the bar next to send.
    private var composer: some View {
        let can = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.palette.coral)
                .padding(.leading, 13)
                .accessibilityHidden(true)
            TextField("Ask me anything — or hand me your whole day…", text: $draft)
                .font(UFont.sans(14.5)).foregroundStyle(theme.palette.ink)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { engage(draft) }
                .padding(.vertical, 12)
                .accessibilityLabel("Ask the assistant")
            if model.voiceConfigured {
                Button(action: onTalk) {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.palette.coralDeep)
                        .frame(width: 34, height: 34).contentShape(Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Talk to your assistant")
            }
            Button { engage(draft) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(can ? theme.palette.coral : theme.palette.coral.opacity(0.3), in: Circle())
            }.buttonStyle(.plain)
                .disabled(!can)
                .padding(.trailing, 4)
                .accessibilityLabel("Send")
        }
        .frame(minHeight: 44)
        .background(theme.palette.surface, in: Capsule())
        .overlay(Capsule().stroke(theme.palette.coral.opacity(0.55), lineWidth: 1.5))
    }

    // MARK: - engine wiring

    private func bootstrap() {
        if moments == nil {
            // One shared PAPrefs (AppModel.paPrefs): `dismiss` is idempotent and
            // keeps the newest 200, so persisting the merged set is a no-op for
            // ids already on disk and appends the new one in order.
            let prefs = model.paPrefs
            moments = GatewayMomentState(dismissed: Set(prefs.dismissed),
                                         persist: { ids in for id in ids { prefs.dismiss(id) } })
        }
        interviewDone = InterviewMachine.isDone()
    }

    /// Live facts off the store (the assistant's saves, a hydrate from another
    /// device, a Settings forget all land here). The FIRST value is the point
    /// to decide about the interview — deciding before the facts are read
    /// re-asked existing users on a second device.
    private func observeFacts() async {
        guard let service = model.profileFacts else { return }
        do {
            for try await list in service.observeAll() {
                facts = list.filter { $0.active }
                if !factsLoaded {
                    factsLoaded = true
                    if InterviewMachine.shouldAutoOpen(factCount: facts.count, done: interviewDone) {
                        openInterview()
                    }
                }
            }
        } catch {}
    }

    private func factsChanged(count: Int) {
        // Facts that arrive from ELSEWHERE while the panel is open but untouched
        // (a second device's hydrate landing a beat after first open): close
        // it — the user has clearly been here before.
        if interviewOpen, let interview, interview.isFirstStep, interview.noted.isEmpty, count >= 3 {
            interviewOpen = false
        }
        guard InterviewMachine.shouldAutoComplete(factCount: count, isOpen: interviewOpen, done: interviewDone)
        else { return }
        InterviewMachine.markDone()
        interviewDone = true
    }

    private func openInterview() {
        if interview == nil {
            interview = InterviewMachine(save: { [model] category, fact in
                model.profileFacts?.save(category: category, fact: fact, source: .interview, whenIso: nil)
            })
        }
        interviewOpen = true
    }

    private func todayIso() -> String { Clock.todayISO() }

    /// "About N usable minutes before it" must be the gap to the anchor, capped
    /// by usable time — not the day's total.
    private func composeBriefLine(now: Date) -> String {
        let today = todayIso()
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let next = vm.blocks
            .filter { $0.date == today && !$0.done && !$0.skipped && !$0.startTime.isEmpty }
            .compactMap { b -> Int? in
                let p = b.startTime.split(separator: ":").compactMap { Int($0) }
                return p.count == 2 ? p[0] * 60 + p[1] : nil
            }
            .filter { $0 >= nowMin }
            .min()
        let usable = usableToday(blocks: vm.blocks, todayIso: today).usableMins
        let before: Int? = next.map { max(0, min(usable, $0 - nowMin)) }
        return composeBrief(tasks: vm.all, blocks: vm.blocks, todayIso: today, now: now, usableMinutes: before)
    }

    private func currentMoment(now: Date) -> Moment? {
        guard let moments else { return nil }
        let struggles = UserDefaults.standard.stringArray(forKey: "unstuck.adhdStruggles") ?? []
        let dismissed = moments.dismissed   // value snapshot — the engine's probe is @Sendable
        let state = MomentState(
            tasks: vm.all, blocks: vm.blocks, sessions: vm.sessions, reasons: [],
            facts: facts, struggles: struggles, todayIso: todayIso(), now: now,
            isDismissed: { dismissed.contains($0) })
        return pickMoment(state, prefs: model.paPrefs.rituals, tone: toneFromFacts(facts))
    }

    private func engage(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        fieldFocused = false
        // Hand-off: the sheet owns the thread — same path as the Siri deep link
        // (AppModel+Notifications routeDeepLink "unstuck://assistant").
        model.openAssistant()
        model.assistant.send(t)
    }

    private func settle(_ id: String, _ confirmation: String?) {
        moments?.settle(id, confirmation: confirmation, alreadyOnDisk: Set(PAPrefsStore.getDismissed()))
    }

    private func run(_ m: Moment, _ a: MomentAction) {
        let today = todayIso()
        let nowISO = AppModel.isoNow()
        switch a.run {
        case .dismiss:
            settle(m.id, nil)
        case .chat(let message):
            settle(m.id, nil)
            engage(message)
        case .schedule(let taskId, let date, let time):
            let w = GatewayActions.schedule(taskId: taskId, date: date, time: time, tasks: vm.all, blocks: vm.blocks,
                                            todayIso: today, newId: newUUID())
            apply(w)
            settle(m.id, w.confirmation)
        case .createTask(let name, let estimateMin):
            let w = GatewayActions.createTask(name: name, estimateMin: estimateMin, id: newUUID(), nowISO: nowISO)
            apply(w)
            settle(m.id, w.confirmation)
        case .carryTasks(let taskIds):
            let tomorrow = Clock.dateISO(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            let w = GatewayActions.carryTasks(taskIds: taskIds, tasks: vm.all, blocks: vm.blocks,
                                              todayIso: today, tomorrowIso: tomorrow, nowISO: nowISO)
            apply(w)
            settle(m.id, w.confirmation)
        }
    }

    private func apply(_ w: GatewayWrites) {
        for b in w.blocks { model.saveBlock(b) }
        for t in w.tasks { model.saveTask(t) }
    }
}
