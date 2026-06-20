// The bubble's dual-purpose surface: an Assistant chat (agentic — brain-dump to
// manage your schedule) + the existing Feedback composer, switched by a top
// toggle. The chat drives AssistantModel (which calls the qwen edge fn +
// executes tool calls locally). 1:1 with the Android AssistantSheet, MINUS the
// voice entry (deferred): no "Talk" button, no mic, no speaker toggle.

import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

/// The sheet presented by the floating bubble. A top toggle switches between
/// the Assistant chat and the Feedback composer; both stay reachable.
struct BubbleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// The tab the user was on (for Feedback triage).
    let screen: String
    /// Which surface to open on (Assistant by default; bug-report deep-links Feedback).
    let startTab: AppRouter.BubbleTab

    @State private var tab: AppRouter.BubbleTab

    init(screen: String, startTab: AppRouter.BubbleTab) {
        self.screen = screen
        self.startTab = startTab
        _tab = State(initialValue: startTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top toggle: Assistant | Feedback.
            HStack(spacing: 8) {
                ToggleChip(label: "Assistant", selected: tab == .assistant) { tab = .assistant }
                ToggleChip(label: "Feedback", selected: tab == .feedback) { tab = .feedback }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch tab {
            case .assistant: AssistantChat()
            case .feedback: FeedbackForm(screen: screen, onDone: { dismiss() })
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct ToggleChip: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let selected: Bool
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(UFont.sans(13, .semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
                .background(selected ? theme.palette.ink : theme.palette.bg2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The agentic chat: transcript of user/assistant bubbles, a "Thinking…" row
/// while a turn is in flight, an inline error row, an input field + send button,
/// and a "New chat" clear action. History + the in-flight turn live on the
/// AssistantModel (the turn runs in a detached Task) so dismissing the sheet
/// mid-turn doesn't cancel it.
private struct AssistantChat: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var input = ""
    @State private var showVoice = false        // realtime "Talk" mode
    @State private var speakReplies = false      // TTS read-aloud toggle
    @State private var note: String?             // local notice (mic permission / STT unavailable)
    @State private var userStoppedMic = false    // distinguishes a tap-to-stop from an auto-end (denial)
    @State private var voice = VoiceController()
    @SwiftUI.FocusState private var fieldFocused: Bool

    private var assistant: AssistantModel { model.assistant }

    var body: some View {
        let shown = assistant.transcript
        VStack(spacing: 0) {
            // Header: a "Talk" entry into realtime voice (when configured) +
            // "New chat" clear (only when there's a conversation).
            HStack {
                if model.voiceConfigured {
                    Button { showVoice = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform").font(.system(size: 12))
                            Text("Talk").font(UFont.sans(12, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(theme.palette.coral, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if !shown.isEmpty {
                    Button("New chat") { assistant.clear(); input = "" }
                        .font(UFont.sans(12, .medium))
                        .foregroundStyle(theme.palette.ink3)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            // Transcript (or the empty hint).
            if shown.isEmpty && !assistant.sending {
                emptyHint
            } else {
                transcript(shown)
            }

            // Local notice (mic permission / STT unavailable) or the last turn's
            // error off the model (which survives close/reopen). A live region so
            // VoiceOver announces failures. 1:1 with Android `note ?: errorCode`.
            if let message = note ?? assistant.error.map(assistantFriendlyError) {
                Text(message)
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            inputBar
        }
        .fullScreenCover(isPresented: $showVoice) { VoiceModeScreen() }
        // Read each new assistant reply aloud while the speaker toggle is on.
        .onChange(of: assistant.lastReplyTick) { _, _ in
            if speakReplies, let r = assistant.lastReply { voice.speak(r) }
        }
        // On-device dictation streams into the input field via the model bridge.
        .onChange(of: assistant.voiceDraft) { _, v in if assistant.dictating || !v.isEmpty { input = v } }
        .onDisappear { voice.stopListening(); assistant.dictating = false }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brain-dump it.")
                .font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
            Text("Tell me what's on your plate and I'll sort it — \"add a dentist appt next Tue 3pm\", "
                + "\"move my report to tomorrow morning\", \"what should I start?\". Type or tap the mic.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    private func transcript(_ shown: [ChatMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { m in
                        MessageBubble(text: m.content ?? "", fromUser: m.role == "user")
                    }
                    if assistant.sending { ThinkingRow().id("thinking") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: shown.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: assistant.sending) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Read replies aloud (on-device TTS).
            Button { speakReplies.toggle(); if !speakReplies { voice.stopSpeaking() } } label: {
                Image(systemName: speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(speakReplies ? theme.palette.coral : theme.palette.ink3)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speakReplies ? "Stop reading replies aloud" : "Read replies aloud")

            TextField(assistant.dictating ? "Listening…" : "Message…", text: $input, axis: .vertical)
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

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.sending
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !assistant.sending else { return }
        input = ""
        note = nil   // 1:1 with Android send(): clear any local notice on send
        assistant.send(t)
    }
}

private struct MessageBubble: View {
    @Environment(\.uTheme) private var theme
    let text: String
    let fromUser: Bool
    var body: some View {
        HStack {
            if fromUser { Spacer(minLength: 40) }
            Text(text)
                .font(UFont.sans(15))
                .foregroundStyle(fromUser ? Color.white : theme.palette.ink)
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
