// TourPanel — the running tour's compact card. Port of web tour-panel.tsx:
// header (mark + stage + soft progress dots + exit ✕), serif-italic title,
// body copy, Tell-me-more, the Listen bar, the per-step Ask thread (real
// assistant, Thinking pulse, FIXED light-lavender/dark-ink answer bubbles —
// deliberately theme-independent so they read correctly in BOTH themes), and
// the footer controls (Pause / Skip / Back / Continue).
//
// The panel NEVER covers the spotlight: the orchestrator docks it opposite
// the target (top/bottom) and passes `collapsed` when a target spans both
// halves — collapsed = title + controls only, so the ring stays visible.

import SwiftUI
import UnstuckDesign

struct TourPanel: View {
    @Environment(\.uTheme) private var theme
    @Bindable var tour: TourModel
    let collapsed: Bool

    @State private var question = ""
    @State private var showMore = false
    @FocusState private var askFocused: Bool

    /// FIXED answer-bubble colors (web: oklch(0.93 0.04 280) / oklch(0.25 0.02 280)).
    private static let answerBg = OKLCH(0.93, 0.04, 280).color
    private static let answerInk = OKLCH(0.25, 0.02, 280).color
    private static let thinkingInk = OKLCH(0.42, 0.02, 280).color

    var body: some View {
        let step = tour.currentStep
        VStack(spacing: 0) {
            header(step)
            VStack(alignment: .leading, spacing: 0) {
                Text(step.title)
                    .font(UFont.serifItalic(20))
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !collapsed {
                    Text(step.body)
                        .font(UFont.sans(13.5))
                        .lineSpacing(3)
                        .foregroundStyle(theme.palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    if showMore, let more = step.more {
                        Text(more)
                            .font(UFont.sans(12.5))
                            .lineSpacing(3)
                            .foregroundStyle(theme.palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                            .overlay(alignment: .top) { Rectangle().fill(theme.palette.line).frame(height: 1).offset(y: -5) }
                    }
                    if tour.mediaMode == .listen && tour.audio.available {
                        listenBar
                    }
                }
                // The Ask thread lives OUTSIDE the collapse conditional: a
                // collapse while the field owns focus would UNMOUNT it, drop
                // the keyboard, and re-expand — the focus loop. (It renders
                // nothing unless the user opened it, so the normal collapsed
                // panel is unchanged.)
                askThread(step)
                if !collapsed {
                    miniLinks(step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            footer(step)
        }
        .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Product tour")
        // Swipe-down = the pause flow (the iOS Escape-equivalent) — shows the
        // inline confirm first; progress is only saved-and-dismissed on confirm.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.height > 60 && abs(value.translation.width) < 80 { tour.requestPause() }
                }
        )
        .onChange(of: tour.currentStep.id) { _, _ in
            showMore = false
            question = ""
            askFocused = false
        }
        .onChange(of: askFocused) { _, focused in
            // Placement rule input: while the field owns focus the panel is
            // pinned to the top dock and never collapses (see TourModel).
            tour.askFieldFocused = focused
            // The tour lives in its own overlay window; text entry needs it key.
            if focused { TourWindowHandle.shared.makeTourKey() } else { TourWindowHandle.shared.restoreAppKey() }
        }
    }

    // MARK: header

    private func header(_ step: TourStep) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(theme.palette.primarySoft).frame(width: 26, height: 26)
                Mark(size: 16)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("\(step.stage) · \(tour.index + 1) of \(tour.steps.count) \(tour.mode == .essential ? "essentials" : "steps")".uppercased())
                    .font(UFont.mono(10, .medium))
                    .tracking(1)
                    .foregroundStyle(theme.palette.ink3)
                    .lineLimit(1)
                // Soft dots.
                HStack(spacing: 4) {
                    ForEach(Array(tour.steps.enumerated()), id: \.element.id) { i, _ in
                        Capsule()
                            .fill(i == tour.index ? theme.palette.primary
                                  : i < tour.index ? theme.palette.primarySoft : theme.palette.line2)
                            .frame(width: i == tour.index ? 16 : 6, height: 6)
                            .animation(.easeOut(duration: 0.16), value: tour.index)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { tour.exit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.ink3)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit tour")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.palette.line).frame(height: 1) }
    }

    // MARK: listen bar (bundled audio — "Voice · Cherry" + live captions)

    private var listenBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button { tour.audio.playPause() } label: {
                    Image(systemName: tour.audio.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .frame(width: 30, height: 30)
                        .background(theme.palette.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tour.audio.playing ? "Pause narration" : "Play narration")
                Button { tour.audio.replay() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.ink3)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay step")
                Capsule().fill(theme.palette.line2)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(theme.palette.primary)
                                .frame(width: max(0, geo.size.width * tour.audio.progress))
                        }
                    }
                    .clipShape(Capsule())
                Button { tour.setSpeed(nextTourSpeed(tour.speed)) } label: {
                    Text("\(speedLabel)×")
                        .font(UFont.sans(11, .bold))
                        .foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 6).frame(height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Narration speed \(speedLabel)x")
            }
            // Live caption (round 2): the sentence CURRENTLY being spoken —
            // narration or the Tell-me-more clip — one subtitle-style line
            // synced to audio progress (char-weighted spans). The panel never
            // grows: one line, gently scaled when a sentence runs long.
            if let caption = captionSentence {
                Text(caption)
                    .font(UFont.sans(11.5))
                    .foregroundStyle(theme.palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("TourCaption")
            }
            HStack(spacing: 5) {
                Text("CAPTIONS").font(UFont.mono(9, .medium)).tracking(0.8).foregroundStyle(theme.palette.ink3)
                Text("· live").font(UFont.sans(11)).foregroundStyle(theme.palette.ink4)
                Spacer(minLength: 0)
                Text("Voice · \(TourAudioPlayer.voiceLabel)")
                    .font(UFont.sans(10.5, .semibold)).foregroundStyle(theme.palette.ink3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 12)
    }

    /// The sentence being spoken right now, from the ACTIVE clip's text
    /// (narration, or the step's `more` while its clip plays) and progress.
    private var captionSentence: String? {
        let step = tour.currentStep
        let text = tour.audio.clip == .more ? (step.more ?? step.narration) : step.narration
        let sentences = splitTourSentences(text)
        guard !sentences.isEmpty else { return nil }
        return sentences[tourCaptionIndex(progress: tour.audio.progress, sentences: sentences)]
    }

    private var speedLabel: String {
        tour.speed == tour.speed.rounded() ? String(Int(tour.speed)) : String(tour.speed)
    }

    // MARK: ask thread

    @ViewBuilder
    private func askThread(_ step: TourStep) -> some View {
        let ask = tour.ask
        if ask.asking && (!ask.bubbles.isEmpty || ask.busy) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ask.bubbles) { b in
                            Text(b.text)
                                .font(UFont.sans(12.5))
                                .lineSpacing(2.5)
                                .foregroundStyle(b.role == .user ? theme.palette.ink : Self.answerInk)
                                .padding(.horizontal, b.role == .user ? 11 : 12)
                                .padding(.vertical, b.role == .user ? 6 : 10)
                                .background(b.role == .user ? AnyShapeStyle(theme.palette.bg2) : AnyShapeStyle(Self.answerBg),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: b.role == .user ? .trailing : .leading)
                                .id(b.id)
                        }
                        if ask.busy {
                            ThinkingBubble(bg: Self.answerBg, ink: Self.thinkingInk)
                                .id(-1)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .onChange(of: ask.bubbles.count) { _, _ in
                    withAnimation { proxy.scrollTo(ask.bubbles.last?.id ?? -1, anchor: .bottom) }
                }
            }
            .padding(.top, 10)
        }
        if ask.asking {
            HStack(spacing: 7) {
                TextField(ask.bubbles.isEmpty ? "Ask anything — the Assistant answers…" : "Follow up…",
                          text: $question)
                    .font(UFont.sans(13))
                    .foregroundStyle(theme.palette.ink)
                    .focused($askFocused)
                    .submitLabel(.send)
                    .onSubmit { send(step) }
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(theme.palette.surface, in: Capsule())
                    .overlay(Capsule().stroke(theme.palette.line2, lineWidth: 1))
                Button { send(step) } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .frame(width: 34, height: 34)
                        .background(theme.palette.ink, in: Circle())
                        .opacity(sendDisabled ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
                .accessibilityLabel("Send question")
            }
            .padding(.top, 10)
        }
    }

    private var sendDisabled: Bool {
        tour.ask.busy || question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send(_ step: TourStep) {
        let q = question
        question = ""
        tour.submitQuestion(q, step: step)
    }

    // MARK: mini links

    private func miniLinks(_ step: TourStep) -> some View {
        HStack(spacing: 6) {
            miniLink(tour.ask.asking ? "Close question" : "Ask a question") {
                tour.ask.asking.toggle()
                if !tour.ask.asking { askFocused = false }
            }
            if step.more != nil {
                // Round 2: in Listen mode the expand also plays the step's
                // <id>-more.m4a (narration pauses, resumes after); collapse
                // stops it. Read mode just toggles the text.
                miniLink(showMore ? "Less" : "Tell me more") {
                    showMore.toggle()
                    tour.moreToggled(expanded: showMore)
                }
            }
            if TourAudioPlayer.hasAudio(forStep: step.id) {
                miniLink(tour.mediaMode == .listen ? "Read instead" : "Listen") {
                    tour.setMediaMode(tour.mediaMode == .listen ? .read : .listen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    private func miniLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(UFont.sans(12, .medium))
                .foregroundStyle(theme.palette.ink2)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(theme.palette.surface, in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: footer (controls, or the inline pause confirm — round 2)

    @ViewBuilder
    private func footer(_ step: TourStep) -> some View {
        Group {
            if tour.confirmingPause {
                pauseConfirm
            } else {
                controls
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.palette.line).frame(height: 1) }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ghostButton("Pause") { tour.requestPause() }
            ghostButton("Skip") { tour.advance() }
            Spacer(minLength: 0)
            if tour.index > 0 {
                ghostButton("Back") { tour.back() }
            }
            Button { tour.primaryAction() } label: {
                HStack(spacing: 7) {
                    Text(tour.primaryLabel)
                        .font(UFont.sans(13, .semibold))
                    if tour.index < tour.steps.count - 1 {
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(theme.palette.bg)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(theme.palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Inline pause confirm: nothing is dismissed until [Pause]; the Settings
    /// path is always named so the run is never "lost".
    private var pauseConfirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause the tour? Your progress is saved.")
                .font(UFont.sans(13, .semibold))
                .foregroundStyle(theme.palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick it back up anytime from Settings → Account → Product tour.")
                .font(UFont.sans(11.5))
                .lineSpacing(2.5)
                .foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { tour.confirmPause() } label: {
                    Text("Pause")
                        .font(UFont.sans(13, .semibold))
                        .foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(theme.palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Confirm pause")
                Button { tour.cancelPause() } label: {
                    Text("Keep going")
                        .font(UFont.sans(13, .semibold))
                        .foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(theme.palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ghostButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(UFont.sans(12.5, .semibold))
                .foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The "Thinking…" pulse bubble (web um-blink).
private struct ThinkingBubble: View {
    let bg: Color
    let ink: Color
    @State private var dim = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Thinking").font(UFont.sans(12.5)).foregroundStyle(ink)
            Text("…").font(UFont.sans(12.5)).foregroundStyle(ink)
                .opacity(dim ? 0.15 : 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Thinking")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}
