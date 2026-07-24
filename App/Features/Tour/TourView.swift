// Tour orchestrator — the iOS port of web onboarding-tour.tsx.
//
// Phase machine: boot → welcome | running | paused | dismissed | done.
// Progress + Read/Listen state persist (TourStore, `unstuck.tour.v1` parity)
// so the tour resumes where it stopped.
//
// MOUNTING: the tour renders in its OWN always-on-top passthrough UIWindow
// (created by TourWindowMounter from MainTabScaffold). A root .overlay would
// be hidden by every sheet (Settings, TaskEditor, Inbox, the bubble) and by
// the focus fullScreenCover — the separate window is the one context that
// verifiably renders above all of them (checked on simulator), the iOS
// equivalent of the web's root-mount pattern. Empty space passes touches
// through (hitTest), so the app stays fully usable under the spotlight.
//
// Launch triggers:
//  • One-time auto-welcome on Today for accounts that finish onboarding AFTER
//    this shipped (TourState.eligible — armed in AppModel.completeOnboarding).
//    Existing accounts are never ambushed.
//  • Settings → Account → "Product tour" (openExplicit): resume at the saved
//    step, or the welcome if fresh.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckDesign

// MARK: - orchestrator model

@MainActor
@Observable
final class TourModel {
    enum Phase: Equatable { case boot, welcome, running, paused, dismissed, done }

    private(set) var phase: Phase = .boot
    private(set) var mode: TourMode = .essential
    private(set) var mediaMode: TourMediaMode = .read
    private(set) var speed: Double = 1
    private(set) var index = 0
    /// Explicit open (Settings row) bypasses the Today-only gate on the cards.
    private(set) var explicitOpen = false
    /// The current step's resolved spotlight rect (screen coords; nil = scrim).
    private(set) var targetRect: CGRect?
    /// Last measured EXPANDED panel height — feeds the collapse decision.
    /// (Never updated from a collapsed measurement, or the rule oscillates.)
    var panelExpandedHeight: CGFloat = 340
    /// The panel's current on-screen frame — the ONLY interactive tour region
    /// while running; everything else passes through to the app (the window's
    /// hitTest asks `claims(point:)`).
    var panelFrame: CGRect = .zero
    /// The Ask input owns keyboard focus (set by TourPanel). While true the
    /// placement forces dock = .top and suppresses the collapse rule — the
    /// keyboard owns the bottom half, and a collapse would UNMOUNT the focused
    /// field, dropping the keyboard in a loop.
    var askFieldFocused = false
    /// The step the primary CTA already opened the assistant for (two-tap
    /// deviation from web — see primaryAction).
    private(set) var assistantOpenedForStep: String?

    let audio = TourAudioPlayer()
    let ask = TourAskModel()

    private let store: TourStore
    private unowned let app: AppModel
    private var pollTask: Task<Void, Never>?
    private var navTask: Task<Void, Never>?

    init(app: AppModel, store: TourStore = TourStore()) {
        self.app = app
        self.store = store
    }

    var steps: [TourStep] { TourScript.steps(for: mode) }
    var currentStep: TourStep { steps[min(index, steps.count - 1)] }

    /// The welcome/resume card is actually on screen: explicit opens show
    /// anywhere; the auto-offered card waits for Today with nothing presented
    /// (never ambush mid-task). Shared by the overlay root AND the window's
    /// hit-test claim so visibility and tappability can't drift apart.
    var cardVisible: Bool {
        guard phase == .welcome || phase == .paused else { return false }
        if explicitOpen { return true }
        // Auto-offer gate: the router's modals AND any UIKit-presented VC —
        // several screens present sheets from LOCAL @State the router can't
        // see, and the card must never ambush over (or under) one of those.
        return app.router.tab == .today
            && !app.router.hasActivePresentation
            && TourWindowHandle.shared.appWindow?.rootViewController?.presentedViewController == nil
    }

    /// Which screen points the tour overlay window owns. SwiftUI renders the
    /// whole tree inside ONE hosting view, so UIKit hitTest can't distinguish
    /// a button from empty scrim — the model decides by region instead: the
    /// modal cards claim everything; running claims only the panel; hidden
    /// claims nothing (full passthrough).
    func claims(point: CGPoint) -> Bool {
        if cardVisible { return true }
        if phase == .running {
            // Prefer the panel's LIVE UIKit frame (layout is complete by
            // hitTest time); fall back to the last SwiftUI measurement.
            if let v = TourWindowHandle.shared.panelAnchorView, v.window != nil {
                return v.convert(v.bounds, to: nil).insetBy(dx: -8, dy: -8).contains(point)
            }
            return panelFrame.insetBy(dx: -8, dy: -8).contains(point)
        }
        return false
    }

    /// Web label rule: last step → step.primary; an onShow step → step.primary;
    /// otherwise "Continue". The two-tap assistant step flips to "Continue"
    /// once the bubble has been opened.
    var primaryLabel: String {
        let step = currentStep
        if index == steps.count - 1 { return step.primary }
        if step.opensAssistant && assistantOpenedForStep != step.id { return step.primary }
        return "Continue"
    }

    // MARK: entry points

    /// Read persisted state once (first render of the overlay root).
    func bootIfNeeded() {
        guard phase == .boot else { return }
        let s = store.load()
        if let m = s.mode { mode = m }
        if let mm = s.mediaMode { mediaMode = mm }
        if let sp = s.speed { speed = sp; audio.speed = sp }
        if let i = s.index { index = i }
        switch tourInitialPhase(s) {
        case .hidden: phase = .dismissed
        case .paused: phase = .paused
        case .welcome: phase = .welcome
        }
    }

    /// Settings → Account → "Product tour": resume an UNFINISHED run at its
    /// saved step; a FINISHED (done) or fresh tour shows the welcome card over
    /// Today — web restart semantics, never a "resume" at the last step.
    func openExplicit() {
        let s = store.load()
        explicitOpen = true
        switch tourResumeDecision(s) {
        case .running(let saved):
            if let m = s.mode { mode = m }
            index = min(saved, steps.count - 1)
            store.save { $0.paused = false; $0.done = false }
            phase = .running
            applyCurrentStep()
            startPolling()
        case .welcome:
            goHome()
            phase = .welcome
        }
    }

    // MARK: welcome card

    func begin(_ m: TourMode) {
        mode = m
        index = 0
        // Clear done/paused too: a RESTART of a finished tour must persist as
        // a live run, or a mid-run pause/kill could never offer the resume card.
        store.save { $0.mode = m; $0.started = true; $0.index = 0; $0.done = false; $0.paused = false }
        explicitOpen = false
        phase = .running
        applyCurrentStep()
        startPolling()
    }

    /// "Explore with the Assistant" — no fixed path; opens the bubble.
    func explore() {
        store.save { $0.done = true; $0.started = true }
        explicitOpen = false
        phase = .done
        app.router.bubbleStartTab = .assistant
        app.router.showBubble = true
    }

    /// Welcome "Not now" — never auto-offer again.
    func declineWelcome() {
        store.save { $0.done = true; $0.started = true }
        explicitOpen = false
        phase = .done
    }

    // MARK: paused card

    func resume() {
        store.save { $0.paused = false }
        explicitOpen = false
        phase = .running
        applyCurrentStep()
        startPolling()
    }

    func startOver() {
        index = 0
        store.save { $0.index = 0; $0.paused = false }
        explicitOpen = false
        phase = .running
        applyCurrentStep()
        startPolling()
    }

    func declinePaused() {
        store.save { $0.done = true; $0.paused = false }
        explicitOpen = false
        phase = .done
    }

    // MARK: running controls

    /// The primary CTA. Web fires onShow + advance in ONE tap; on iOS the
    /// assistant is a full sheet the NEXT step's navigation would instantly
    /// dismiss — so an opensAssistant step opens the bubble on the first tap
    /// (label = "Open the Assistant") and advances on the second ("Continue").
    func primaryAction() {
        let step = currentStep
        if step.opensAssistant && assistantOpenedForStep != step.id {
            assistantOpenedForStep = step.id
            app.router.bubbleStartTab = .assistant
            app.router.showBubble = true
            return
        }
        advance()
    }

    func advance() {
        guard phase == .running else { return }
        if index >= steps.count - 1 {
            store.save { $0.done = true; $0.paused = false }
            phase = .done
            teardownRunning()
            return
        }
        index += 1
        applyCurrentStep()
    }

    func back() {
        guard phase == .running, index > 0 else { return }
        index -= 1
        applyCurrentStep()
    }

    /// Pause = dismiss preserving progress; resume via the paused card on next
    /// launch or Settings → Product tour.
    func pause() {
        guard phase == .running else { return }
        store.save { [index, mode] in $0.paused = true; $0.index = index; $0.mode = mode }
        phase = .dismissed
        teardownRunning()
    }

    /// Exit ✕ — done for good (until an explicit restart).
    func exit() {
        guard phase == .running else { return }
        store.save { $0.done = true; $0.paused = false }
        phase = .done
        teardownRunning()
    }

    /// scenePhase → .background while running: checkpoint a paused state
    /// { paused, index, mode } so a jetsam kill relaunches into the resume
    /// card instead of losing the run. The LIVE phase stays .running — a
    /// normal foreground return just continues, and every finish/exit path
    /// overwrites this checkpoint on its own.
    func appDidEnterBackground() {
        guard phase == .running else { return }
        store.save { [index, mode] in $0.paused = true; $0.index = index; $0.mode = mode }
    }

    // MARK: panel plumbing

    func setMediaMode(_ m: TourMediaMode) {
        guard m != mediaMode else { return }
        mediaMode = m
        store.save { $0.mediaMode = m }
        guard phase == .running else { return }
        if m == .listen {
            audio.prepare(step: currentStep.id, autoplay: true)
            if audio.available && !audio.playing { audio.play() }
        } else {
            audio.stop()
        }
    }

    func setSpeed(_ s: Double) {
        speed = s
        audio.speed = s
        store.save { $0.speed = s }
    }

    func submitQuestion(_ q: String, step: TourStep) {
        ask.submit(q, step: step, assistant: app.assistant)
    }

    // MARK: internals

    private func applyCurrentStep() {
        let step = currentStep
        ask.reset(step: step.id)
        askFieldFocused = false
        assistantOpenedForStep = nil
        targetRect = nil
        navigate(step)
        audio.prepare(step: step.id, autoplay: mediaMode == .listen)
        store.save { [index, mode, mediaMode] in
            $0.started = true; $0.mode = mode; $0.mediaMode = mediaMode; $0.index = index
        }
    }

    /// Drive the real app for a step: close whatever modal is up, switch tab,
    /// and (after the dismiss settles — SwiftUI silently drops a second
    /// presentation while one is tearing down) present the step's surface.
    private func navigate(_ step: TourStep) {
        NotificationCenter.default.post(name: .unstuckTourWillNavigate, object: nil)
        let router = app.router
        // Tour-scoped dismiss: closes what the TOUR may have opened (sheet,
        // detail, bubble) but leaves a live Focus session alone — the tour
        // never opens focusTask, so any focus cover is USER-started and must
        // never be yanked by step navigation.
        router.dismissTourPresentations()
        navTask?.cancel()
        navTask = nil
        switch step.view {
        case .today, .focus:
            // FOCUS DEVIATION: FocusView mints a live session on init (no idle
            // state exists), so focus/capture steps stay on Today and ring the
            // hero's Focus begin affordance — a session is NEVER started.
            router.select(.today)
        case .calendar:
            router.select(.calendar)
        case .collections:
            router.select(.lists)
        case .tasks:
            router.select(.tasks)
            if step.id == "first-action" {
                // Open a real task's detail so the first-physical-action block
                // exists (empty account → the New-task FAB fallback rings).
                navTask = presentSoon { [weak self] in
                    guard let self, let first = self.firstOpenTask() else { return }
                    self.app.router.detailTask = first
                }
            }
        case .captures:
            router.select(.today)
            navTask = presentSoon { [weak self] in self?.app.router.present(.inbox) }
        case .insights:
            navTask = presentSoon { [weak self] in self?.app.router.present(.insights) }
        case .settings:
            let section = step.section
            navTask = presentSoon { [weak self] in self?.app.router.present(.settings(section: section)) }
        }
    }

    private func presentSoon(_ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            body()
        }
    }

    /// The first visible open task (Tasks · All ordering) for the
    /// first-action step — mirrors web's 'unstuck-tour-open-first-task'.
    private func firstOpenTask() -> TaskItem? {
        let tasks = (try? app.taskRepo?.all()) ?? []
        let blocks = (try? app.db?.fetchAllCalBlocks()) ?? []
        let rows = visibleTasks(view: .all, tasks: tasks, blocks: blocks,
                                now: Date().timeIntervalSince1970 * 1000,
                                activeArea: nil, slipMode: false)
        return rows.first { !$0.done }
    }

    private func teardownRunning() {
        pollTask?.cancel()
        pollTask = nil
        navTask?.cancel()
        navTask = nil
        audio.stop()
        targetRect = nil
        explicitOpen = false
        askFieldFocused = false
        // Close anything the tour itself opened (settings/inbox/insights sheet,
        // the task detail, the bubble) so the user isn't stranded in a modal.
        // A live Focus session is deliberately spared — the tour never opens
        // one, so it can only be the user's.
        NotificationCenter.default.post(name: .unstuckTourWillNavigate, object: nil)
        app.router.dismissTourPresentations()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase == .running {
                    let step = self.currentStep
                    let rect = TourTargetRegistry.shared.resolve(target: step.target,
                                                                 fallbacks: step.targetFallbacks)
                    if rect != self.targetRect { self.targetRect = rect }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func goHome() {
        NotificationCenter.default.post(name: .unstuckTourWillNavigate, object: nil)
        app.router.dismissTourPresentations()
        app.router.select(.today)
    }
}

// MARK: - overlay root

/// The root of the tour overlay window. Renders nothing while hidden; the
/// auto-shown welcome/resume cards wait for Today with nothing presented —
/// never ambush mid-task. Explicit opens show wherever asked.
struct TourRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tour = model.tour
        ZStack {
            switch tour.phase {
            case .welcome:
                if tour.cardVisible { TourWelcomeCard(tour: tour) }
            case .paused:
                if tour.cardVisible { TourResumeCard(tour: tour) }
            case .running:
                runningLayer(tour)
            case .boot, .dismissed, .done:
                EmptyView()
            }
        }
        .task { tour.bootIfNeeded() }
    }

    private func runningLayer(_ tour: TourModel) -> some View {
        GeometryReader { geo in
            let screen = geo.frame(in: .global)
            // Non-negotiable #1: dock the panel OPPOSITE the spotlight target;
            // a target spanning both halves collapses the panel instead of
            // covering the ring. Re-evaluated on every rect/height change.
            // While the Ask field owns focus, `keyboard:` forces dock = .top
            // and suppresses collapse (a collapse would unmount the focused
            // field → keyboard drop → re-expand loop).
            let placement = tourPanelPlacement(target: tour.targetRect, screen: screen,
                                               panelHeight: tour.panelExpandedHeight,
                                               keyboard: tour.askFieldFocused)
            ZStack {
                TourSpotlight(rect: tour.targetRect, reduceMotion: model.settings.reduceMotion)
                    .allowsHitTesting(false)
                // ONE panel with a flipping alignment — a single structural
                // identity, so the dock flip is a frame change (not a remount)
                // and the geometry callback below reliably re-fires.
                panel(tour, collapsed: placement.collapsed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: placement.dock == .top ? .top : .bottom)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        // The measuring frame must IGNORE the keyboard: SwiftUI keyboard
        // avoidance would shrink the GeometryReader when the Ask field
        // focuses, collapsing the panel and unmounting that very field (the
        // HIGH-severity focus loop). The keyboard-time layout is handled by
        // the forced top dock above instead.
        .ignoresSafeArea(.keyboard)
    }

    private func panel(_ tour: TourModel, collapsed: Bool) -> some View {
        TourPanel(tour: tour, collapsed: collapsed)
            // UIKit frame reader — the hit-test claim reads this view's LIVE
            // window frame at hitTest time (immune to any SwiftUI callback
            // staleness; a stale claim once sent a tap through to the tab bar).
            .background(TourPanelFrameReader().allowsHitTesting(false))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // The SwiftUI frame is the claim FALLBACK; only EXPANDED
                // measurements feed the collapse rule (a collapsed height
                // would flip it right back — oscillation).
                tour.panelFrame = frame
                if !collapsed { tour.panelExpandedHeight = frame.height }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.22), value: collapsed)
    }
}

// MARK: - welcome + resume cards (web TourCard / ModeRow / MediaToggle)

private let tourBackdrop = Color(red: 20 / 255, green: 18 / 255, blue: 40 / 255)

struct TourWelcomeCard: View {
    @Environment(\.uTheme) private var theme
    @Bindable var tour: TourModel

    var body: some View {
        ZStack {
            tourBackdrop.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}   // modal backdrop — consume taps
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Circle().fill(theme.palette.primarySoft).frame(width: 44, height: 44)
                        Mark(size: 26)
                    }
                    Text("Welcome to Unstuck")
                        .font(UFont.serifItalic(30))
                        .foregroundStyle(theme.palette.ink)
                        .padding(.top, 16)
                    Text("A two-minute look at how Unstuck helps you begin, stay with it, and come back — nothing to configure. How would you like to explore?")
                        .font(UFont.sans(14.5))
                        .lineSpacing(3.5)
                        .foregroundStyle(theme.palette.ink2)
                        .padding(.top, 8)
                    VStack(spacing: 10) {
                        TourModeRow(title: "Essential tour",
                                    sub: "The core loop: Today, first step, Focus, and the Assistant.",
                                    meta: "3–5 min", recommended: true) { tour.begin(.essential) }
                        TourModeRow(title: "Full guided tour",
                                    sub: "Every major area, start to finish.",
                                    meta: "10–15 min") { tour.begin(.full) }
                        TourModeRow(title: "Explore with the Assistant",
                                    sub: "No fixed path — ask about any screen you open.") { tour.explore() }
                    }
                    .padding(.top, 22)
                    HStack(spacing: 12) {
                        Button { tour.declineWelcome() } label: {
                            Text("Not now")
                                .font(UFont.sans(12.5, .semibold))
                                .foregroundStyle(theme.palette.ink3)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        if TourAudioPlayer.hasAudio(forStep: "welcome") {
                            TourMediaToggle(mediaMode: tour.mediaMode) { tour.setMediaMode($0) }
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(EdgeInsets(top: 30, leading: 30, bottom: 26, trailing: 30))
                .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                .frame(maxWidth: 460)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct TourResumeCard: View {
    @Environment(\.uTheme) private var theme
    @Bindable var tour: TourModel

    var body: some View {
        let step = tour.currentStep
        ZStack {
            tourBackdrop.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(theme.palette.primarySoft).frame(width: 40, height: 40)
                    Mark(size: 22)
                }
                Text("Continue your tour?")
                    .font(UFont.serifItalic(26))
                    .foregroundStyle(theme.palette.ink)
                    .padding(.top, 14)
                (Text("You stopped at ")
                    + Text(step.stage).font(UFont.sans(13.5, .bold)).foregroundColor(theme.palette.ink)
                    + Text(" — \(step.title.lowercased()). Pick up where you left off, or start fresh."))
                    .font(UFont.sans(13.5))
                    .lineSpacing(3)
                    .foregroundStyle(theme.palette.ink2)
                    .padding(.top, 6)
                HStack(spacing: 8) {
                    Button { tour.resume() } label: {
                        HStack(spacing: 7) {
                            Text("Continue").font(UFont.sans(13, .semibold))
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(theme.palette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { tour.startOver() } label: {
                        Text("Start over")
                            .font(UFont.sans(13, .semibold))
                            .foregroundStyle(theme.palette.ink)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(theme.palette.surface, in: Capsule())
                            .overlay(Capsule().stroke(theme.palette.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { tour.declinePaused() } label: {
                        Text("Not now")
                            .font(UFont.sans(12.5, .semibold))
                            .foregroundStyle(theme.palette.ink3)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 20)
            }
            .padding(EdgeInsets(top: 30, leading: 30, bottom: 26, trailing: 30))
            .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .frame(maxWidth: 400)
            .padding(20)
        }
    }
}

private struct TourModeRow: View {
    @Environment(\.uTheme) private var theme
    let title: String
    let sub: String
    var meta: String? = nil
    var recommended = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(UFont.sans(14.5, .bold))
                            .foregroundStyle(theme.palette.ink)
                        if recommended {
                            Text("SUGGESTED")
                                .font(UFont.mono(9.5, .medium))
                                .tracking(0.6)
                                .foregroundStyle(theme.palette.primaryDeep)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(theme.palette.primarySoft, in: Capsule())
                        }
                    }
                    Text(sub)
                        .font(UFont.sans(12.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(theme.palette.ink3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if let meta {
                    Text(meta).font(UFont.mono(11.5)).foregroundStyle(theme.palette.ink3)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.ink2)
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(recommended ? theme.palette.primary : theme.palette.line,
                        lineWidth: recommended ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TourMediaToggle: View {
    @Environment(\.uTheme) private var theme
    let mediaMode: TourMediaMode
    let setMediaMode: (TourMediaMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Read", .read)
            segment("Listen", .listen)
        }
        .padding(2)
        .background(theme.palette.bg2, in: Capsule())
    }

    private func segment(_ label: String, _ m: TourMediaMode) -> some View {
        let on = mediaMode == m
        return Button { setMediaMode(m) } label: {
            Text(label)
                .font(UFont.sans(12, .semibold))
                .foregroundStyle(on ? theme.palette.ink : theme.palette.ink3)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(on ? AnyShapeStyle(theme.palette.surface) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - overlay window plumbing

/// Weak handles to the tour + app windows, so the Ask field can make the tour
/// window key for text entry and hand key status back afterwards — plus the
/// hit-test claim the passthrough window consults.
@MainActor
final class TourWindowHandle {
    static let shared = TourWindowHandle()
    weak var tourWindow: UIWindow?
    weak var appWindow: UIWindow?
    /// The running panel's UIKit background view — its live window frame is
    /// the authoritative interactive region for the hit-test claim.
    weak var panelAnchorView: UIView?
    /// Does the tour UI own this screen point right now? (Wired to
    /// TourModel.claims(point:) at mount; nil/false → full passthrough.)
    var claimsPoint: ((CGPoint) -> Bool)?
    func makeTourKey() { tourWindow?.makeKey() }
    func restoreAppKey() { appWindow?.makeKey() }
}

/// Invisible UIKit reader behind the running panel — registers itself as the
/// live panel-frame source while mounted.
private struct TourPanelFrameReader: UIViewRepresentable {
    final class ReaderView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                TourWindowHandle.shared.panelAnchorView = self
            } else if TourWindowHandle.shared.panelAnchorView === self {
                TourWindowHandle.shared.panelAnchorView = nil
            }
        }
    }
    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ view: ReaderView, context: Context) {}
}

/// Above-everything window that passes touches through to the app window
/// everywhere the tour UI isn't. SwiftUI hosts its whole tree in ONE hosting
/// view (hitTest returns it for buttons AND empty scrim alike), so the pass-
/// through decision is REGION-based via TourModel.claims(point:) — the modal
/// cards claim the whole screen, running claims just the panel.
private final class TourPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard TourWindowHandle.shared.claimsPoint?(point) == true else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct TourHostRoot: View {
    let model: AppModel
    var body: some View {
        TourRootView()
            .environment(model)
            .unstuckTheme(accent: model.settings.accent)
    }
}

/// Creates the tour overlay window once the hosting view lands in a window
/// scene. Mounted from MainTabScaffold (signed-in + onboarded only).
struct TourWindowMounter: UIViewRepresentable {
    let model: AppModel
    /// Follows Settings · Interface theme (nil = system).
    let colorSchemeOverride: ColorScheme?

    @MainActor
    final class Coordinator {
        var window: UIWindow?
    }

    final class MounterView: UIView {
        var onWindowAvailable: (@MainActor (UIWindowScene, UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, let scene = window.windowScene {
                onWindowAvailable?(scene, window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MounterView {
        let v = MounterView()
        v.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        let model = model
        v.onWindowAvailable = { scene, appWindow in
            guard coordinator.window == nil else { return }
            let win = TourPassthroughWindow(windowScene: scene)
            win.windowLevel = .alert + 1
            win.backgroundColor = .clear
            let host = UIHostingController(rootView: TourHostRoot(model: model))
            host.view.backgroundColor = .clear
            win.rootViewController = host
            win.isHidden = false
            coordinator.window = win
            TourWindowHandle.shared.tourWindow = win
            TourWindowHandle.shared.appWindow = appWindow
            TourWindowHandle.shared.claimsPoint = { [weak model] point in
                // Reads the built model only — never constructs the tour just
                // to answer a hit-test.
                model?._tour?.claims(point: point) ?? false
            }
        }
        return v
    }

    func updateUIView(_ view: MounterView, context: Context) {
        let style: UIUserInterfaceStyle = switch colorSchemeOverride {
        case .light: .light
        case .dark: .dark
        default: .unspecified
        }
        context.coordinator.window?.overrideUserInterfaceStyle = style
    }
}
