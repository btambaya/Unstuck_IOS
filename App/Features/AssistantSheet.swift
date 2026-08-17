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

            // Local notice (mic permission / STT unavailable) or the last turn's
            // error off the model (which survives close/reopen). A live region so
            // VoiceOver announces failures.
            if let message = note ?? assistant.error.map(assistantFriendlyError) {
                Text(message)
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            inputBar
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showVoice) { VoiceModeScreen() }
        .task {
            let built = buildAssistantContext(model)
            ctx = built
            // Once per day, greet with a grounded line built from real counts
            // (local — it never enters the model window).
            assistant.maybeInjectCheckin(line: built.checkinLine)
            // The circle roster the share_task tool resolves names against.
            await assistant.refreshShareCandidates()
        }
        // Tool calls change the underlying data — rebuild the strip + chips
        // when a turn lands so the panel never shows a stale day.
        .onChange(of: assistant.sending) { _, busy in if !busy { refreshContext() } }
        // Read each new assistant reply aloud while the toggle is on.
        .onChange(of: assistant.lastReplyTick) { _, _ in
            if speakReplies, let r = assistant.lastReply { voice.speak(r) }
        }
        // On-device dictation streams into the input field via the model bridge.
        .onChange(of: assistant.voiceDraft) { _, v in if assistant.dictating || !v.isEmpty { input = v } }
        .onDisappear {
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
                Button { showVoice = true } label: {
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
                                      local: turn.isLocal)
                        ForEach(Array((turn.receipts ?? []).enumerated()), id: \.offset) { ri, receipt in
                            AssistantReceiptRow(receipt: receipt) {
                                assistant.undoReceipt(turnId: turn.id, index: ri)
                                refreshContext()
                            }
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    }

                    ForEach(assistant.pendingShares) { pending in
                        AssistantShareConfirmCard(
                            pending: pending,
                            performer: ShareModelPerformer(shares: model.shareState),
                            onResolved: { assistant.resolveShare(id: pending.id, outcome: $0) })
                    }

                    if assistant.sending { ThinkingRow() }

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
            assistant.undoAll(turnId: target.turnId)
            refreshContext()
        })
    }

    /// A chip tap sends its message through the NORMAL guardrailed agent path —
    /// no special-cased local execution, no new server surface.
    private func ask(_ message: String) {
        guard !assistant.sending else { return }
        showChips = false
        note = nil
        assistant.send(message)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.sending
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !assistant.sending else { return }
        input = ""
        note = nil
        showChips = false
        // Drop the keyboard on send. It used to stay up for the whole
        // exchange, so the reply you just asked for landed behind it (found
        // while capturing marketing shots: focus survived until the sheet was
        // re-presented). Tap the field again to keep typing.
        fieldFocused = false
        assistant.send(t)
    }

    private func jump(_ destination: AssistantJump) {
        dismiss()
        switch destination {
        case .tasks: model.router.tab = .tasks
        case .calendar: model.router.tab = .calendar
        case .focus(let task): model.router.beginFocus(task)
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
    var body: some View {
        HStack {
            Text("Thinking…")
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
