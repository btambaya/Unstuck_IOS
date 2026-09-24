// The Assistant panel — the iOS port of the web redesign
// (components/assistant/assistant-bubble.tsx): a header with the ask-Unstuck
// eyebrow, a live tappable context strip (NEXT / USABLE / PAUSED), ONE endless
// thread with day dividers + action receipts, and the dynamic data-driven
// suggestion card that fills the view on open (history sits above the fold).
//
// There is no "new chat": the sheet opens scrolled to the top of the chips
// block, so the suggestions fill the viewport and scrolling UP reveals the
// conversation's history. Feedback now lives in Settings → Account → "Send
// feedback" (the panel is the assistant, nothing else).
//
// Everything the agent changes comes back as a deterministic ✓ receipt with
// Undo; a `share_task` request renders a confirm card and only leaves the
// device on the user's tap.

import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

/// The sheet presented by the floating assistant launcher.
struct AssistantSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var showVoice = false         // realtime "Talk" mode
    @State private var speakReplies = false      // TTS read-aloud toggle
    @State private var note: String?             // local notice (mic permission / STT unavailable)
    @State private var userStoppedMic = false    // distinguishes a tap-to-stop from an auto-end (denial)
    @State private var voice = VoiceController()
    /// The suggestion card shows at the thread tail until the user engages this
    /// visit; the ✦ button re-summons it.
    @State private var showChips = true
    @State private var ctx = AssistantContext.empty
    /// The get-to-know-you interview, hosted in this thread while the account
    /// hasn't finished or skipped it (InterviewThread). nil once done.
    @State private var interview: InterviewThreadDriver?
    @SwiftUI.FocusState private var fieldFocused: Bool

    private static let chipsAnchor = "assistant.chips"
    private static let bottomAnchor = "assistant.bottom"

    private var assistant: AssistantModel { model.assistant }

    var body: some View {
        VStack(spacing: 0) {
            header
            AssistantContextStrip(ctx: ctx, onJump: jump)

            if !assistant.hasHistory && !assistant.sending {
                // Brand-new conversation — the full "first page".
                ScrollView {
                    AssistantHomeBlock(ctx: ctx, onAsk: ask, onResumeTour: resumeTour,
                                       undoAll: undoAll)
                        .padding(.horizontal, 16).padding(.vertical, 20)
                }
            } else {
                GeometryReader { geo in thread(viewport: geo.size.height) }
            }

            // "Not now" on the AI-consent sheet: what didn't happen, and why.
            if model.aiConsentNote?.host == .assistant {
                AIConsentNoteLine(host: .assistant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 4)
            }

            // Local notice (mic permission / STT unavailable) or the last turn's
            // error off the model (which survives close/reopen). A live region so
            // VoiceOver announces failures.
            if let message = note ?? assistant.error.map(assistantFriendlyError) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(message)
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                        .accessibilityAddTraits(.updatesFrequently)
                    // Two upstream rejections in a row: the thread itself is
                    // the likely cause (a poisoned replayed tool_call,
                    // 2026-09-06) — offer the way out right where it hurts.
                    if note == nil && assistant.offersFreshThread {
                        Button("Start a fresh thread") {
                            assistant.clear()
                            input = ""
                            showChips = true
                        }
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink)
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 4)
            }

            inputBar
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showVoice) { VoiceModeScreen() }
        // The AI-consent ask for a first message or Talk from this panel.
        .aiConsentSheet(.assistant)
        .task {
            CrashBreadcrumbs.drop("assistant sheet open")
            let built = buildAssistantContext(model)
            ctx = built
            // Once per day, greet with a grounded line built from real counts
            // (local — it never enters the model window).
            assistant.maybeInjectCheckin(line: built.checkinLine)
            // The interview rides in this thread until the account is done
            // with it — it arms on the first send (the reply comes first).
            if interview == nil, !InterviewMachine.isDone() { interview = makeInterview() }
            // Today's input pill asked for the keyboard (and maybe a draft):
            // honour it once the sheet has settled, or the focus is dropped.
            if let req = assistant.takeComposerRequest() {
                if let d = req.draft, !d.isEmpty { input = d }
                if req.focus {
                    try? await Task.sleep(for: .milliseconds(450))
                    fieldFocused = true
                }
            }
            // The circle roster the share_task tool resolves names against.
            await assistant.refreshShareCandidates()
        }
        // Tool calls change the underlying data — rebuild the strip + chips
        // when a turn lands so the panel never shows a stale day. The
        // interview asks its question only now — after the reply.
        .onChange(of: assistant.sending) { _, busy in
            if !busy {
                refreshContext()
                interview?.turnFinished()
            }
        }
        // Read each new assistant reply aloud while the toggle is on — not
        // while Talk is open over the sheet: a reply landing while it still
        // connects got past VoiceController's check (Talk holds the audio
        // only once its socket is open) and played over the realtime voice
        // (audit 2026-09-22, C41).
        .onChange(of: assistant.lastReplyTick) { _, _ in
            if speakReplies, !showVoice, let r = assistant.lastReply { voice.speak(r) }
        }
        // Talk opens over this sheet: a reply still being read aloud would
        // talk over the realtime voice (VoiceController itself stays silent
        // once Talk holds the audio — audit 2026-09-22, C41).
        .onChange(of: showVoice) { _, talking in
            if talking { voice.stopSpeaking() }
        }
        // On-device dictation streams into the input field via the model bridge.
        .onChange(of: assistant.voiceDraft) { _, v in if assistant.dictating || !v.isEmpty { input = v } }
        .onDisappear {
            // Crash trail marker: "it crashed after I tried exiting the AI"
            // (TestFlight, 2026-09-06) — so a fault after this point is placed.
            CrashBreadcrumbs.drop("assistant sheet close sending:\(assistant.sending)")
            voice.stopListening()
            voice.stopSpeaking()
            assistant.dictating = false
            assistant.panelClosed()
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Mark(size: 20)
                .frame(width: 36, height: 36)
                .background(theme.palette.bg2, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant")
                    .font(UFont.sans(15.5, .semibold)).foregroundStyle(theme.palette.ink)
                Text("ASK UNSTUCK TO HANDLE IT")
                    .font(UFont.mono(9.5, .semibold)).tracking(1.5)
                    .foregroundStyle(theme.palette.ink3)
            }
            Spacer(minLength: 0)

            if model.voiceConfigured {
                // Talk sends their voice to OpenAI — the first time, it asks.
                Button { model.withAIConsent(.talk, from: .assistant) { showVoice = true } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill").font(.system(size: 11))
                        Text("Talk").font(UFont.sans(12.5, .semibold))
                    }
                    .foregroundStyle(theme.palette.ink)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(theme.palette.bg2, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk")
            }

            Menu {
                Toggle("Read replies aloud", isOn: $speakReplies)
                if assistant.hasHistory {
                    Button("Clear conversation", role: .destructive) {
                        assistant.clear()
                        input = ""
                        showChips = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16)).foregroundStyle(theme.palette.ink3)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Conversation options")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .padding(.top, 14).padding(.bottom, 10)
    }

    // MARK: - the one endless thread

    private func thread(viewport: CGFloat) -> some View {
        let shown = assistant.transcript
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, turn in
                        if let label = dayDivider(shown, at: i) {
                            Text(label)
                                .font(UFont.mono(10, .semibold)).tracking(0.8)
                                .foregroundStyle(theme.palette.ink3)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 6)
                        }
                        MessageBubble(text: turn.text, fromUser: turn.role == "user",
                                      local: turn.isLocal && turn.role != "user")
                            // A queued send (typed while a turn was in flight)
                            // shows faded until the model picks it up — web parity.
                            .opacity(turn.isPending ? 0.5 : 1)
                        // The interview's chips, under the question it is asking.
                        if let interview, interview.promptTurnId == turn.id {
                            InterviewPromptRow(driver: interview,
                                               ritualIsOn: { model.paPrefs.rituals[$0] },
                                               setRitual: { model.paPrefs.setRitual($0, on: $1) })
                                .padding(.leading, 4)
                        }
                        ForEach(Array((turn.receipts ?? []).enumerated()), id: \.offset) { ri, receipt in
                            // A network undo (cancel_call) shows "cancelling…" until
                            // the server answers; a failure keeps Undo + says why.
                            let inFlight = assistant.isUndoInFlight(turnId: turn.id, index: ri)
                            AssistantReceiptRow(receipt: inFlight ? receipt.cancelling : receipt) {
                                Task { @MainActor in
                                    await assistant.undoReceipt(turnId: turn.id, index: ri)
                                    refreshContext()
                                }
                            }
                            .frame(maxWidth: 320, alignment: .leading)
                            if let note = assistant.undoFailureNote(turnId: turn.id, index: ri) {
                                Text(note)
                                    .font(UFont.sans(11.5)).foregroundStyle(theme.palette.red)
                                    .padding(.leading, 11)
                                    .accessibilityAddTraits(.updatesFrequently)
                            }
                        }
                    }

                    ForEach(assistant.pendingShares) { pending in
                        AssistantShareConfirmCard(
                            pending: pending,
                            performer: ShareModelPerformer(shares: model.shareState,
                                                           taskShare: model.coordinator?.taskShare,
                                                           listShare: { [weak model] listId, email, userId, role in
                                                               await model?.shareCollection(listId, email: email, userId: userId, role: role) ?? .error
                                                           }),
                            onResolved: { assistant.resolveShare(id: pending.id, outcome: $0) })
                    }

                    // The model's per-round narration ("I'll get your lists…")
                    // shows HERE, transiently — never as a bubble.
                    if assistant.sending { ThinkingRow(text: assistant.status ?? "Thinking…") }

                    if showChips && !assistant.sending {
                        // min-height = the viewport, so aligning its TOP with the
                        // top of the scroll view hides everything before it; the
                        // history is one scroll-up away (web parity).
                        AssistantHomeBlock(ctx: ctx, compact: true, onAsk: ask,
                                           onResumeTour: resumeTour, undoAll: undoAll)
                            .padding(.top, 8)
                            .frame(minHeight: max(0, viewport - 24), alignment: .top)
                            .id(Self.chipsAnchor)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onAppear { syncScroll(proxy, animated: false) }
            .onChange(of: shown.count) { _, _ in syncScroll(proxy, animated: true) }
            .onChange(of: assistant.sending) { _, _ in syncScroll(proxy, animated: true) }
            .onChange(of: showChips) { _, _ in syncScroll(proxy, animated: true) }
            .onChange(of: assistant.pendingShares.count) { _, _ in syncScroll(proxy, animated: true) }
        }
    }

    /// The divider label for row `i`, or nil when it repeats the row above.
    private func dayDivider(_ turns: [AssistantTurn], at i: Int) -> String? {
        guard let label = assistantDayLabel(at: turns[i].at) else { return nil }
        let previous = i > 0 ? assistantDayLabel(at: turns[i - 1].at) : nil
        return label == previous ? nil : label
    }

    /// Opening on the chips puts the suggestion card in the viewport with the
    /// history above the fold; a live conversation (or a staged share awaiting
    /// a tap) pins to the bottom instead.
    private func syncScroll(_ proxy: ScrollViewProxy, animated: Bool) {
        let awaitingShare = assistant.pendingShares.contains { $0.outcome == nil }
        let target = (showChips && !assistant.sending && !awaitingShare)
            ? Self.chipsAnchor : Self.bottomAnchor
        let anchor: UnitPoint = target == Self.chipsAnchor ? .top : .bottom
        // A scroll during the same layout pass that appended the row lands
        // short — hop to the next runloop turn.
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(target, anchor: anchor) }
            } else {
                proxy.scrollTo(target, anchor: anchor)
            }
        }
    }

    // MARK: - input

    private var inputBar: some View {
        HStack(spacing: 8) {
            // ✦ re-summons the suggestion card once the user has engaged.
            if assistant.hasHistory && !showChips {
                Button { showChips = true } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.palette.ink2)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(theme.palette.line2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show suggestions")
            }

            TextField(assistant.dictating ? "Listening…" : "Ask Unstuck to handle something…",
                      text: $input, axis: .vertical)
                .font(UFont.sans(15))
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(theme.palette.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                // Stable handle for UI tests: Today's gateway composer is a
                // TextField too and sits behind this sheet, so a bare
                // `textFields.firstMatch` resolves to the wrong one.
                .accessibilityIdentifier("assistant-input")

            // On-device dictation (STT) into the input field.
            Button(action: toggleMic) {
                Image(systemName: assistant.dictating ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(assistant.dictating ? Color.white : theme.palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(assistant.dictating ? theme.palette.coral : theme.palette.bg2)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(assistant.sending)
            .accessibilityLabel(assistant.dictating ? "Stop dictation" : "Dictate")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : theme.palette.ink4)
                    .frame(width: 40, height: 40)
                    .background(canSend ? theme.palette.coral : theme.palette.bg2)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(theme.palette.line).frame(height: 0.5) }
    }

    // MARK: - actions

    private func refreshContext() { ctx = buildAssistantContext(model) }

    private var undoAll: (count: Int, run: () -> Void)? {
        guard let target = assistant.undoAllTarget else { return nil }
        return (target.count, {
            Task { @MainActor in
                await assistant.undoAll(turnId: target.turnId)
                refreshContext()
            }
        })
    }

    /// A chip tap sends its message through the NORMAL guardrailed agent path —
    /// no special-cased local execution, no new server surface.
    private func ask(_ message: String) {
        guard !assistant.sending else { return }
        model.withAIConsent(.chat, from: .assistant) {
            showChips = false
            note = nil
            assistant.send(message)
            interview?.userSent()
        }
    }

    /// No `sending` gate: a message typed while a turn is in flight is QUEUED
    /// by the model (`AssistantModel.send` → `queued`) and shown as a faded
    /// pending bubble, then sent when the turn finishes — web parity.
    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Drop the keyboard on send. It used to stay up for the whole
        // exchange, so the reply you just asked for landed behind it (found
        // while capturing marketing shots: focus survived until the sheet was
        // re-presented). Tap the field again to keep typing.
        fieldFocused = false
        // The first message asks for the AI-consent OK; "Not now" leaves the
        // text in the field, unsent.
        model.withAIConsent(.chat, from: .assistant) {
            if input.trimmingCharacters(in: .whitespacesAndNewlines) == t { input = "" }
            note = nil
            showChips = false
            assistant.send(t)
            interview?.userSent()
        }
    }

    /// The interview machine, wired exactly as the old Today card wired it:
    /// facts save as `.interview` into the profile-facts store, "done" is
    /// mirrored to the account (`pushInterviewDone`), local turns land in
    /// this thread.
    private func makeInterview() -> InterviewThreadDriver {
        let model = self.model
        let assistant = self.assistant
        let machine = InterviewMachine(
            save: { category, fact in
                // nil = the local write failed: the machine keeps the step
                // and the row says so — no echoed answer over a dropped save.
                model.profileFacts?.save(category: category, fact: fact, source: .interview, whenIso: nil) != nil
            },
            onDone: { model.pushInterviewDone() })
        return InterviewThreadDriver(
            machine: machine,
            firstName: GreetingName.firstName(model.currentUserName),
            ready: { model.profileFactsHydrated },
            factCount: { (model.profileFacts?.all() ?? []).filter { $0.active }.count },
            post: { text, meta in assistant.appendLocal(text, interview: meta) },
            echo: { text in assistant.appendLocalUser(text) })
    }

    private func jump(_ destination: AssistantJump) {
        dismiss()
        switch destination {
        case .tasks: model.router.tab = .tasks
        case .calendar: model.router.tab = .calendar
        // The PAUSED chip holds the live session's task — the TEMPLATE for a
        // recurring one — so it reopens the way the Today live card does,
        // on the session's own day (audit 2026-09-22, C3).
        case .focus(let task): model.reopenLiveFocus(task)
        }
    }

    private func resumeTour() {
        dismiss()
        model.tour.openExplicit()
    }

    private static let micDeniedNote = "Mic permission is needed to talk to the assistant."

    /// Toggle on-device dictation: stream the transcript into the input field
    /// (via the AssistantModel bridge), stop on the next tap or when it ends.
    /// On end, auto-send the dictated draft if it's non-blank — hands-free
    /// voice-to-action, 1:1 with Android's `if (input.isNotBlank()) send(input)`.
    private func toggleMic() {
        let assistant = self.assistant
        // User-initiated stop: end dictation quietly (don't surface a permission
        // notice for an empty draft the user chose to abandon).
        if assistant.dictating { userStoppedMic = true; voice.stopListening(); assistant.dictating = false; return }
        guard voice.sttAvailable else { note = Self.micDeniedNote; return }
        note = nil
        userStoppedMic = false
        assistant.setVoiceDraft("")   // clear any prior draft so the empty check below is meaningful
        assistant.dictating = true
        voice.startListening(
            onPartial: { p in Task { @MainActor in assistant.setVoiceDraft(p) } },
            onFinal: { f in Task { @MainActor in assistant.setVoiceDraft(f) } },
            onDone: {
                Task { @MainActor in
                    assistant.dictating = false
                    // Read the model's draft (the source the @Sendable callbacks
                    // write) — `input` mirrors it via .onChange, which can lag.
                    let draft = assistant.voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !draft.isEmpty {
                        // Auto-send the dictated draft (hands-free voice-to-action).
                        // Clear the model draft so the .onChange mirror doesn't
                        // re-populate `input` after send() empties it.
                        assistant.setVoiceDraft("")
                        input = draft
                        send()
                    } else if !userStoppedMic {
                        // Ended with nothing captured AND the user didn't tap to
                        // stop — on iOS the mic/speech permission is requested
                        // lazily inside startListening, so an empty auto-ended
                        // result is almost always a denial. Surface it.
                        note = Self.micDeniedNote
                    }
                }
            })
    }
}

// MARK: - rows

private extension Receipt {
    /// The in-flight look while a network undo runs: state in the label, no
    /// Undo button (a second tap mid-flight would double-send the cancel).
    var cancelling: Receipt { Receipt(icon: icon, label: "\(label) — cancelling…", undo: nil) }
}

private struct MessageBubble: View {
    @Environment(\.uTheme) private var theme
    let text: String
    let fromUser: Bool
    /// A locally-injected turn (the daily check-in) — marked with the ✦ tell.
    var local = false

    var body: some View {
        HStack {
            if fromUser { Spacer(minLength: 40) }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if local {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.ink3)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(UFont.sans(15))
                    .foregroundStyle(fromUser ? Color.white : theme.palette.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(fromUser ? theme.palette.coral : theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                fromUser ? nil :
                    RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.palette.line))
            .frame(maxWidth: 300, alignment: fromUser ? .trailing : .leading)
            if !fromUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
    }
}

private struct ThinkingRow: View {
    @Environment(\.uTheme) private var theme
    var text: String = "Thinking…"
    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1).truncationMode(.tail)
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.palette.line))
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - AI data-sharing consent (AIConsent)

extension View {
    /// Hosts the AI-consent sheet for `host`: it shows while the gate
    /// (AppModel.withAIConsent) is asking from this surface. Swiping it away
    /// counts as "Not now"; what the answer goes on to do runs once it's gone.
    func aiConsentSheet(_ host: AIConsentHost) -> some View {
        modifier(AIConsentSheetHost(host: host))
    }
}

private struct AIConsentSheetHost: ViewModifier {
    @Environment(AppModel.self) private var model
    let host: AIConsentHost

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.aiConsentAsk?.host == host },
            set: { shown in if !shown, model.aiConsentAsk?.host == host { model.declineAIConsent() } }),
                      onDismiss: { model.aiConsentSheetDismissed(from: host) }) {
            AIConsentSheet()
        }
    }
}

/// "Your assistant uses OpenAI" — the disclosure + ask before anything the
/// user types or says goes to the AI provider (guideline 5.1.2(i)). The same
/// words as the web, everywhere it appears (AIConsent).
struct AIConsentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    /// The ask this sheet came up for (AppModel.aiConsentSheetShown / Gone).
    @State private var askId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Mark(size: 20)
                    .frame(width: 40, height: 40)
                    .background(theme.palette.bg2, in: Circle())
                    .accessibilityHidden(true)
                Text(AIConsent.title)
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(AIConsent.body)
                    .font(UFont.sans(14.5)).foregroundStyle(theme.palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AIConsent.privacyURL) {
                    HStack(spacing: 4) {
                        Text(AIConsent.privacyLinkLabel).underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(UFont.sans(13.5, .semibold)).foregroundStyle(theme.palette.ink)
                }
                .accessibilityIdentifier("ai-consent-privacy")

                Button { model.agreeAIConsent() } label: {
                    Text(AIConsent.agreeLabel)
                        .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.bg)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(theme.palette.ink, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityIdentifier("ai-consent-agree")
                Button { model.declineAIConsent() } label: {
                    Text(AIConsent.declineLabel)
                        .font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink2)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ai-consent-decline")
            }
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            askId = model.aiConsentAsk?.id
            model.aiConsentSheetShown(askId)
        }
        .onDisappear { model.aiConsentSheetGone(askId) }
    }
}

/// A "Not now" line (AIConsent.decline) under the surface that asked — calm
/// secondary ink, not an error.
struct AIConsentNoteLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let host: AIConsentHost

    var body: some View {
        if let note = model.aiConsentNote, note.host == host {
            Text(note.text)
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
