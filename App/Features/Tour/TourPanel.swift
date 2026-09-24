// TourPanel — the running tour's compact card. Port of web tour-panel.tsx:
// header (mark + stage + soft progress dots + exit ✕), serif-italic title,
// body copy, Tell-me-more, the Listen bar, the per-step Ask thread (real
// assistant, Thinking pulse, FIXED light-lavender/dark-ink answer bubbles —
// deliberately theme-independent so they read correctly in BOTH themes), and
// the footer controls (Pause / Skip / Back / Continue).
//
// The panel NEVER covers the spotlight: the orchestrator docks it opposite the
// target (top/bottom) and hands it a `TourPanelPlacement` — a hard height cap
// when the free space is tight (header + footer stay pinned, the middle
// scrolls), and `collapsed` only when even a readable panel cannot fit, where
// title + controls is all that's left.

import SwiftUI
import UnstuckDesign

/// The body scroll view's coordinate space, and the id `scrollTo` uses to put
/// it back at the top on a step change. File scope so the `@Sendable` geometry
/// closure that reads the space can reference it without hopping actors.
private let tourPanelBodySpace = "tour-panel-body"
private let tourPanelBodyTopID = "tour-panel-body-top"

struct TourPanel: View {
    @Environment(\.uTheme) private var theme
    @Bindable var tour: TourModel
    /// Dock + collapse + cap as ONE value: the collapse flag and the cap come
    /// from a single decision, so the panel can't be laid out to one and
    /// measured against the other.
    let placement: TourPanelPlacement

    @State private var question = ""
    @State private var showMore = false
    /// The NATURAL height of the scrolling middle — see `body`. Laid out
    /// inside a ScrollView, so it is the ideal height whether or not the
    /// placement capped the panel.
    @State private var bodyHeight: CGFloat = 0
    /// The MEASURED chrome: the pinned header and footer. Seeded with the
    /// metrics so the first frame is already the right shape, then corrected —
    /// the footer is NOT a constant (the inline pause confirm adds 67pt).
    @State private var headerHeight = TourPanelMetrics.header
    @State private var footerHeight = TourPanelMetrics.footer
    /// The body scroll view is at its top, and whether the in-flight swipe
    /// began there — see `bodyPauseSwipe`. Stored as the BOOLEAN rather than the
    /// offset on purpose: `onGeometryChange` only fires when its value changes,
    /// so this re-renders the panel twice per scroll instead of every frame.
    @State private var bodyAtTop = true
    @State private var swipeBeganAtBodyTop: Bool?
    /// The Ask thread's natural height, so its 180pt window can be a DEFINITE
    /// frame — see `askThread`.
    @State private var askHeight: CGFloat = 0
    @FocusState private var askFocused: Bool

    /// FIXED answer-bubble colors (web: oklch(0.93 0.04 280) / oklch(0.25 0.02 280)).
    private static let answerBg = OKLCH(0.93, 0.04, 280).color
    private static let answerInk = OKLCH(0.25, 0.02, 280).color
    private static let thinkingInk = OKLCH(0.42, 0.02, 280).color

    var body: some View {
        let step = tour.currentStep
        // The cap covers the WHOLE panel, and the header and footer are PINNED,
        // so what is left of it is the body's. The chrome is MEASURED, not
        // assumed: the inline pause confirm makes the footer 134pt where the
        // controls row is 67.
        let chrome = headerHeight + footerHeight
        // Never squeeze the body below its title block. If the real chrome is
        // fatter than the placement rule's floor assumed (confirm open on a
        // ring-filled screen), a few points of overlap beat hiding the step's
        // name — and since the panel HUGS, the frame it reports is that taller
        // height, so the hit-test claim still covers every point it draws on.
        let bodyLimit = placement.maxHeight.map { max(TourPanelMetrics.titleBlock, $0 - chrome) }
        VStack(spacing: 0) {
            header(step)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollViewReader { proxy in
                ScrollView {
                    middle(step)
                        // Measured here, INSIDE the scroll view, where the
                        // content is always proposed its ideal height — the one
                        // reading of the panel that a cap can't distort.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                        // Scroll position: the content's top sits at the scroll
                        // view's own top (or below it, mid-rubber-band) exactly
                        // while there is nothing left to scroll UP into view.
                        // Read by the swipe-down-to-pause gesture below.
                        .onGeometryChange(for: Bool.self) {
                            $0.frame(in: .named(tourPanelBodySpace)).minY > -0.5
                        } action: { bodyAtTop = $0 }
                        .id(tourPanelBodyTopID)
                }
                .coordinateSpace(.named(tourPanelBodySpace))
                // A ScrollView is greedy — left alone it swallows the whole
                // offered height and strands the footer at the bottom of an
                // over-tall panel. Capped, it takes the smaller of the measured
                // content and what the cap leaves (so a short step never shows
                // dead space) as a DEFINITE height; uncapped, nil leaves it to
                // hug its content under the `fixedSize` below, exactly as the
                // plain VStack used to.
                .frame(height: bodyLimit.map { bodyHeight > 0 ? min(bodyHeight, $0) : $0 })
                // Uncapped there is nothing to scroll (and the panel-wide
                // gesture then owns the drag over the copy too).
                .scrollDisabled(bodyLimit == nil)
                .scrollBounceBehavior(.basedOnSize)
                // Capped, the scroll view's pan recognizer outranks the
                // panel-wide DragGesture, which would silently retire the
                // swipe-down-to-pause gesture over the copy on exactly the
                // tight steps this cap exists for. Simultaneous + "only from
                // the top" gives both: a drag that starts mid-scroll scrolls,
                // one that starts at the top pauses.
                .simultaneousGesture(bodyPauseSwipe)
                .onChange(of: tour.currentStep.id) { _, _ in
                    // The panel is ONE structural identity across steps
                    // (TourRootView keeps a single flipping panel), so nothing
                    // resets this offset on its own — without it a capped step
                    // opens already scrolled past its own first line.
                    bodyAtTop = true
                    proxy.scrollTo(tourPanelBodyTopID, anchor: .top)
                }
            }
            footer(step)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        // The panel ALWAYS hugs: the cap is spent on the body above, never on
        // this stack, so the header and footer can never be compressed and the
        // panel can never draw outside the frame it reports.
        .fixedSize(horizontal: false, vertical: true)
        // The ONE place the placement rule's input is written, re-fired whenever
        // EITHER measurement moves. It has to watch both: the body's own
        // geometry callback never fires when the FOOTER swaps its controls row
        // for the pause confirm — the copy above it is untouched — and that is
        // exactly the 67pt the rule would otherwise never hear about.
        // (`reportPanelHeight` refuses a collapsed reading; see it for why both
        // operands are safe to feed back and a rendered frame is not.)
        .onChange(of: [bodyHeight, chrome], initial: true) { _, m in
            tour.reportPanelHeight(body: m[0], chrome: m[1], collapsed: placement.collapsed)
        }
        .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Product tour")
        // Swipe-down = the pause flow (the iOS Escape-equivalent) — shows the
        // inline confirm first; progress is only saved-and-dismissed on confirm.
        // Nothing competes for the drag over the pinned header and footer, so
        // this one needs no scroll guard; the body carries its own copy above.
        .gesture(DragGesture(minimumDistance: 30).onEnded { pauseIfSwipeDown($0) })
        .onChange(of: tour.currentStep.id) { _, _ in
            showMore = false
            question = ""
            askFocused = false
            // Per-step state that outlives the step otherwise — the panel is one
            // structural identity across steps. A stale askHeight is a DEFINITE
            // frame on the next step's thread (180pt of white around one line).
            askHeight = 0
            swipeBeganAtBodyTop = nil
        }
        .onChange(of: askFocused) { _, focused in
            // Placement rule input: while the field owns focus the panel is
            // pinned to the top dock and never collapses (see TourModel).
            tour.askFieldFocused = focused
            // The tour lives in its own overlay window; text entry needs it key.
            if focused { TourWindowHandle.shared.makeTourKey() } else { TourWindowHandle.shared.restoreAppKey() }
        }
    }

    // MARK: swipe-down-to-pause

    /// Shared tail of both pause swipes: a decisive DOWNWARD drag.
    private func pauseIfSwipeDown(_ value: DragGesture.Value) {
        if value.translation.height > 60 && abs(value.translation.width) < 80 { tour.requestPause() }
    }

    /// The same flow over the SCROLLING body, attached simultaneously so the
    /// scroll view's pan doesn't swallow it — but only when the swipe BEGAN at
    /// the top of the body, where a downward drag has nothing left to scroll.
    /// (Sampled at `onChanged`, not at the end: a genuine scroll-back-to-the-top
    /// flick also ENDS at the top, and must not pause the tour.)
    private var bodyPauseSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { _ in
                if swipeBeganAtBodyTop == nil { swipeBeganAtBodyTop = bodyAtTop }
            }
            .onEnded { value in
                let fromTop = swipeBeganAtBodyTop ?? bodyAtTop
                swipeBeganAtBodyTop = nil
                guard fromTop else { return }
                pauseIfSwipeDown(value)
            }
    }

    // MARK: middle (the scrolling part — everything but header and footer)

    private func middle(_ step: TourStep) -> some View {
        let collapsed = placement.collapsed
        return VStack(alignment: .leading, spacing: 0) {
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { askHeight = $0 }
                }
                // The thread still tops out at 180pt, but as a DEFINITE frame
                // now that it can sit inside the panel's own scroll view: a
                // nested ScrollView with only a maxHeight is handed an
                // unbounded proposal by the outer one, returns its full
                // content height, and draws straight over what follows it.
                //
                // UNTIL it has been measured the frame stays nil — unspecified,
                // so the thread hugs its content for that first frame. A
                // definite `min(askHeight, 180)` off the seed would draw the
                // thread 0-tall on the frame it mounts (and `askHeight` is
                // reset per step, so a long thread on one step can no longer
                // leave the next step's one-liner in a 180pt box).
                .frame(height: askHeight > 0 ? min(askHeight, 180) : nil)
                // Below the ceiling there is nothing to scroll, and the outer
                // body should own the drag.
                .scrollDisabled(askHeight <= 180)
                .scrollBounceBehavior(.basedOnSize)
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
            Text("Replay it anytime from Settings → Replay the tour.")
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
