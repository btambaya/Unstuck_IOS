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
// equivalent of the web's root-mount pattern.
//
// ROUND-2 LOCKDOWN: while the tour runs the window claims (and swallows)
// every touch EXCEPT the panel and — on cutoutInteractive steps only
// (assistant/reentry) — the spotlight cutout; every other ring is display-
// only (round-3 cutout policy: the ringed Today list must never open a real
// task — nor, when it still existed, the Start-Next hero mint a real
// session). A step-opened surface (assistant sheet, settings section,
// task detail) reverts the claim to panel-only so that surface stays usable
// while it's the step's subject. While PAUSED, a floating "Resume tour" chip
// is the only claimed region and the app is fully usable underneath. See
// tourClaims() in TourData.swift.
//
// Launch triggers:
//  • One-time auto-welcome on Today for accounts that finish onboarding AFTER
//    this shipped (TourState.eligible — armed in AppModel.completeOnboarding).
//    Existing accounts are never ambushed.
//  • Settings → "Replay the tour" (openExplicit): resume at the saved
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
    /// The panel's NATURAL (unconstrained) height — the placement rule's input.
    /// Written only by `reportPanelHeight`; see it for why that is the one
    /// door in.
    private(set) var panelExpandedHeight: CGFloat = 340
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
    /// Pause is a two-step: the footer shows an inline confirm ("Pause the
    /// tour?") before anything is dismissed (round 2).
    private(set) var confirmingPause = false
    /// A resumable paused run exists and the chip wasn't ✕-dismissed —
    /// mirrors tourChipEligible(store) so hit-testing never hits UserDefaults.
    private(set) var chipEligible = false
    /// The floating "Resume tour" chip's on-screen frame (claim fallback).
    var chipFrame: CGRect = .zero
    /// OBSERVED mirror of "a UIKit-presented VC is up in the app window"
    /// (circle-invite alerts, share sheets — presentations the router can't
    /// see). The raw `presentedViewController` read is UNOBSERVABLE: when
    /// render and the hit-test claim each read it live they can drift — the
    /// full-screen card CLAIM stays live while the card is NOT rendered
    /// (e.g. an invite alert lands after render), soft-locking every touch
    /// into an invisible card. Polled into @Observable state so render and
    /// claims() consume the SAME value and a change re-renders the overlay.
    private(set) var uikitPresentationActive = false

    let audio = TourAudioPlayer()
    let ask = TourAskModel()

    private let store: TourStore
    private unowned let app: AppModel
    private var pollTask: Task<Void, Never>?
    private var navTask: Task<Void, Never>?
    private var presentationWatchTask: Task<Void, Never>?

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
        // `uikitPresentationActive` (never the raw unobservable read) so this
        // re-renders when an alert appears/dismisses and claims() can't drift
        // from what's on screen.
        return app.router.tab == .today
            && !app.router.hasActivePresentation
            && !uikitPresentationActive
    }

    /// The paused "Resume tour" chip is on screen: after an in-session pause
    /// (phase .dismissed) it shows everywhere; on a relaunch into the paused
    /// phase it shows wherever the auto resume card can't (non-Today / a
    /// modal up) so the run stays one tap away on every screen.
    var chipVisible: Bool {
        guard chipEligible else { return false }
        switch phase {
        case .dismissed: return true
        case .paused: return !cardVisible
        default: return false
        }
    }

    /// Which screen points the tour overlay window owns. SwiftUI renders the
    /// whole tree inside ONE hosting view, so UIKit hitTest can't distinguish
    /// a button from empty scrim — the model decides by region and delegates
    /// to the pure tourClaims() rule (round-2 lockdown: running claims
    /// EVERYTHING except the spotlight cutout, with the panel-only reversion
    /// while a step-opened surface is presented; the paused chip claims only
    /// itself; hidden claims nothing).
    func claims(point: CGPoint) -> Bool {
        var ctx = TourClaimContext()
        // "Card claims everything" holds ONLY while the card is actually
        // RENDERED — the live UIKit anchor (mounted by the card views) is the
        // proof of render. Without the gate, an unobserved presentation change
        // could leave the full-screen claim standing with no card on screen:
        // every touch swallowed, the app soft-locked (round-3 HIGH).
        ctx.cardVisible = cardVisible
            && Self.liveFrame(TourWindowHandle.shared.cardAnchorView) != nil
        ctx.chipVisible = chipVisible
        ctx.chipFrame = Self.liveFrame(TourWindowHandle.shared.chipAnchorView) ?? chipFrame
        ctx.running = phase == .running
        // Prefer the panel's LIVE UIKit frame (layout is complete by hitTest
        // time); fall back to the last SwiftUI measurement.
        ctx.panelFrame = Self.liveFrame(TourWindowHandle.shared.panelAnchorView) ?? panelFrame
        ctx.targetRect = targetRect
        ctx.demoStep = currentStep.isDemoFocus
        ctx.cutoutInteractive = currentStep.cutoutInteractive
        // Any presentation in the APP window — router modals AND UIKit-presented
        // VCs. Whether it UNLOCKS anything is the step's call: only
        // surfaceInteractive steps (assistant/reentry/settings) revert to
        // panel-only; elsewhere the sheet is display-only and stays swallowed.
        // The UIKit half reads the same OBSERVED mirror render uses (see
        // uikitPresentationActive) — never the raw unobservable property.
        ctx.presentationActive = app.router.hasActivePresentation || uikitPresentationActive
        ctx.surfaceExempt = currentStep.surfaceInteractive
        // Round 4: the settings exemption is scoped to the PUSHED section —
        // resolved live from the app window's navigation stack at hit-test
        // time (the section pops back to the root the moment the user taps
        // Back, and the rect must follow instantly, not on a poll tick). Nil
        // while nothing is pushed → the rule fails closed to panel-only, so
        // the root list (Sign out / Delete account / Export) is never reachable.
        ctx.surfaceScoped = currentStep.surfaceScoped
        if ctx.surfaceScoped && ctx.presentationActive {
            ctx.surfaceRect = Self.pushedSettingsSectionRect(in: TourWindowHandle.shared.appWindow)
        }
        return tourClaims(point: point, ctx: ctx)
    }

    private static func liveFrame(_ view: UIView?) -> CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
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
        chipEligible = tourChipEligible(s)
        switch tourInitialPhase(s) {
        case .hidden: setPhase(.dismissed)
        case .paused: setPhase(.paused)
        case .welcome: setPhase(.welcome)
        }
    }

    /// Settings → "Replay the tour": resume an UNFINISHED run at its
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
            chipEligible = false
            setPhase(.running)
            applyCurrentStep()
            startPolling()
        case .welcome:
            goHome()
            setPhase(.welcome)
        }
    }

    // MARK: welcome card

    func begin(_ m: TourMode) {
        mode = m
        index = 0
        // Clear done/paused too: a RESTART of a finished tour must persist as
        // a live run, or a mid-run pause/kill could never offer the resume card.
        // chipDismissed is per-run — a fresh run re-arms the resume chip.
        store.save {
            $0.mode = m; $0.started = true; $0.index = 0
            $0.done = false; $0.paused = false; $0.chipDismissed = nil
        }
        chipEligible = false
        explicitOpen = false
        setPhase(.running)
        applyCurrentStep()
        startPolling()
    }

    /// "Explore with the Assistant" — no fixed path; opens the bubble.
    func explore() {
        store.save { $0.done = true; $0.started = true }
        chipEligible = false
        explicitOpen = false
        setPhase(.done)
        app.openAssistant()
    }

    /// Welcome "Not now" — never auto-offer again.
    func declineWelcome() {
        store.save { $0.done = true; $0.started = true }
        chipEligible = false
        explicitOpen = false
        setPhase(.done)
    }

    // MARK: paused card + resume chip

    func resume() {
        store.save { $0.paused = false }
        chipEligible = false
        explicitOpen = false
        setPhase(.running)
        applyCurrentStep()
        startPolling()
    }

    func startOver() {
        index = 0
        store.save { $0.index = 0; $0.paused = false }
        chipEligible = false
        explicitOpen = false
        setPhase(.running)
        applyCurrentStep()
        startPolling()
    }

    func declinePaused() {
        store.save { $0.done = true; $0.paused = false }
        chipEligible = false
        explicitOpen = false
        setPhase(.done)
    }

    /// The floating chip resumes the run exactly where it paused.
    func resumeFromChip() { resume() }

    /// Chip ✕ — the chip never returns for THIS run (persisted); the
    /// Settings → Replay the tour path remains.
    func dismissChip() {
        let saved = store.save { $0.chipDismissed = true }
        chipEligible = tourChipEligible(saved)
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
            app.openAssistant()
            return
        }
        advance()
    }

    func advance() {
        guard phase == .running else { return }
        if index >= steps.count - 1 {
            store.save { $0.done = true; $0.paused = false }
            chipEligible = false
            setPhase(.done)
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

    // MARK: pause (round 2 — confirm, then dismiss + resume chip)

    /// Pause button / swipe-down: show the inline footer confirm first —
    /// nothing is dismissed until the user confirms.
    func requestPause() {
        guard phase == .running else { return }
        confirmingPause = true
    }

    /// "Keep going" — drop the confirm, stay on the step.
    func cancelPause() {
        confirmingPause = false
    }

    /// Confirmed pause = dismiss preserving progress; the floating "Resume
    /// tour" chip (and the paused card on next launch / Settings → Product
    /// tour) brings the run back.
    func confirmPause() {
        guard phase == .running else { return }
        confirmingPause = false
        let saved = store.save { [index, mode] in $0.paused = true; $0.index = index; $0.mode = mode }
        chipEligible = tourChipEligible(saved)
        setPhase(.dismissed)
        teardownRunning()
    }

    /// Exit ✕ — done for good (until an explicit restart).
    func exit() {
        guard phase == .running else { return }
        store.save { $0.done = true; $0.paused = false }
        chipEligible = false
        setPhase(.done)
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

    /// Tell-me-more expanded/collapsed (round 2): in Listen mode the expand
    /// plays the step's `<id>-more.m4a` (pausing the narration, which resumes
    /// after); collapsing stops it. Read mode unchanged.
    func moreToggled(expanded: Bool) {
        guard phase == .running, mediaMode == .listen else { return }
        if expanded { audio.playMore() } else { audio.stopMore() }
    }

    /// The panel reporting what it really needs — its measured scrolling middle
    /// plus its measured chrome. The ONLY way `panelExpandedHeight` is written,
    /// so the rule can't be fed its own output.
    ///
    /// Two properties have to hold AT ONCE, and they coexist because both
    /// operands are functions of the panel's CONTENT alone, never of the
    /// placement this rule produces:
    ///
    ///  • NOT STALE. `chrome` is the live header + footer, not a constant: the
    ///    inline pause confirm swaps a 67pt controls row for a 134pt block, and
    ///    a compile-time 121 would under-report the panel by 67pt — enough for
    ///    the uncapped branch to decide it fits and let it grow into the ring.
    ///  • NO OSCILLATION. Neither operand can echo the cap back. The middle is
    ///    measured INSIDE the panel's ScrollView, where it is always proposed
    ///    its ideal height, so a capped render reports the same number an
    ///    uncapped one does. The header and footer are never capped at all —
    ///    the panel spends the cap on its body and hugs — so they always
    ///    measure their natural height too. The one poisoned reading left is a
    ///    COLLAPSED render, where the copy is absent from the tree rather than
    ///    scrolled out of sight; believing that would shrink the requirement,
    ///    re-expand the panel and flip back. It is refused here.
    func reportPanelHeight(body: CGFloat, chrome: CGFloat, collapsed: Bool) {
        guard !collapsed, body > 0, chrome > 0 else { return }
        panelExpandedHeight = body + chrome
    }

    // MARK: internals

    private func applyCurrentStep() {
        let step = currentStep
        ask.reset(step: step.id)
        askFieldFocused = false
        assistantOpenedForStep = nil
        confirmingPause = false
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
            // Focus/capture steps (round 2): the tour renders its OWN demo
            // focus surface in the tour window — the app just settles on
            // Today underneath; a real session is NEVER started.
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
        // Key-window handback (round-3 HIGH): exiting/pausing/finishing with
        // the Ask keyboard focused unmounts the panel BEFORE its askFocused
        // onChange can fire — the TOUR window would stay key forever and the
        // app's text inputs go dead. Every teardown path (confirmPause, exit,
        // advance-to-done) funnels through here; restoreAppKey is idempotent.
        if askFieldFocused { TourWindowHandle.shared.restoreAppKey() }
        askFieldFocused = false
        // Close anything the tour itself opened (settings/inbox/insights sheet,
        // the task detail, the bubble) so the user isn't stranded in a modal.
        // A live Focus session is deliberately spared — the tour never opens
        // one, so it can only be the user's.
        NotificationCenter.default.post(name: .unstuckTourWillNavigate, object: nil)
        app.router.dismissTourPresentations()
    }

    /// Sign-out (AppModel.scrubDeviceLocalUserContent / signOut): stop
    /// everything this run owns — the target + presentation polls, audio, a
    /// pending step presentation, the key-window grab, the VoiceOver lock —
    /// and leave the app fully passable. The persisted state is wiped by the
    /// caller (TourStore.clear) and the model itself is dropped (`_tour = nil`),
    /// so the next account boots a fresh tour. Idempotent; never touches the
    /// store (a paused run of the signed-out account is gone by design —
    /// Android clears TourStateStore the same way).
    func teardownForSignOut() {
        pollTask?.cancel(); pollTask = nil
        navTask?.cancel(); navTask = nil
        presentationWatchTask?.cancel(); presentationWatchTask = nil
        audio.stop()
        targetRect = nil
        explicitOpen = false
        chipEligible = false
        confirmingPause = false
        if askFieldFocused { TourWindowHandle.shared.restoreAppKey() }
        askFieldFocused = false
        phase = .done
        TourWindowHandle.shared.setAccessibilityLock(false)
    }

    /// The ONE phase setter: every transition also (re)decides whether the
    /// UIKit-presentation watch must run and whether VoiceOver is locked to
    /// the tour window. Keeping both here means no entry/exit path can leave
    /// a poll or the lock behind.
    private func setPhase(_ next: Phase) {
        phase = next
        syncPresentationWatch()
    }

    /// The presentation watch is only meaningful while the tour is on screen
    /// or about to be (welcome / paused card gating, the running claim). It
    /// used to start on the first overlay render and run for the life of the
    /// process — for EVERY user, including those whose tour finished long
    /// ago — waking the main actor 4×/s and polling a stale window after
    /// sign-out. Now it runs exactly while it matters and is cancelled
    /// everywhere else (done / dismissed / boot).
    private func syncPresentationWatch() {
        switch phase {
        case .welcome, .paused, .running:
            if presentationWatchTask == nil { startPresentationWatch() }
        case .boot, .dismissed, .done:
            presentationWatchTask?.cancel()
            presentationWatchTask = nil
        }
    }

    /// The tour owns the screen (round-4 a11y): its window is marked MODAL, so
    /// VoiceOver ignores the sibling app window. Held while running or while a
    /// card is actually on screen; released the moment neither is true (the
    /// paused chip leaves the app fully usable).
    var accessibilityLockHeld: Bool { phase == .running || cardVisible }

    /// The second, narrower half of that lock: the app window's elements are
    /// hidden OUTRIGHT (belt and braces — a UIKit-presented sheet in the app
    /// window stays traversable through mere modality).
    ///
    /// Modality is unconditional; hiding must MIRROR THE TOUCH CLAIM, or the
    /// two drift and a VoiceOver user loses exactly the surfaces a step tells
    /// them to operate. `tourClaims` deliberately passes touches through on
    /// cutoutInteractive steps (the ringed assistant launcher IS the step) and
    /// to a step-opened surface on surfaceInteractive steps (the Settings →
    /// Notifications section IS the step). Blanket-hiding the app window there
    /// left those steps followable by sighted users only — the launcher and the
    /// notification controls were simply not in the accessibility tree. So the
    /// app window stays hidden ONLY while every app point is genuinely
    /// swallowed; the modal flag keeps the rest of the app out of VoiceOver's
    /// way whenever something IS passed through.
    var accessibilityHidingHeld: Bool {
        guard accessibilityLockHeld else { return false }
        var ctx = TourClaimContext()
        ctx.cardVisible = cardVisible
        ctx.running = phase == .running
        ctx.demoStep = currentStep.isDemoFocus
        ctx.presentationActive = app.router.hasActivePresentation || uikitPresentationActive
        ctx.surfaceExempt = currentStep.surfaceInteractive
        ctx.cutoutInteractive = currentStep.cutoutInteractive
        ctx.targetRect = targetRect
        return tourHidesAppFromAccessibility(ctx: ctx)
    }

    /// Poll the app window's UIKit presentation state into observable model
    /// state while the tour is live (250ms, matching the target poll). The
    /// property itself is unobservable, and BOTH the card render and the
    /// hit-test claim depend on it — polling one shared value is what keeps
    /// "claims ⊆ rendered" true when an alert appears or dismisses without
    /// any SwiftUI-visible state change. Lifecycle: syncPresentationWatch.
    private func startPresentationWatch() {
        presentationWatchTask?.cancel()
        presentationWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let live = TourWindowHandle.shared.appWindow?
                    .rootViewController?.presentedViewController != nil
                if live != self.uikitPresentationActive { self.uikitPresentationActive = live }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// The pushed settings section's content rect (screen coordinates) for the
    /// scoped settings exemption — nil when the Settings sheet isn't up, when
    /// its navigation stack is still at the ROOT (the list with Sign out /
    /// Delete account / Export), or when the UIKit stack can't be read (the
    /// claim then fails closed to panel-only). The navigation bar is cut off
    /// the top (Back stays claimed) and the leading edge is claimed so the
    /// interactive-pop gesture can't reach the root either.
    private static func pushedSettingsSectionRect(in window: UIWindow?) -> CGRect? {
        guard let presented = window?.rootViewController?.presentedViewController,
              let nav = firstNavigationController(in: presented),
              nav.viewControllers.count > 1,
              let content = nav.topViewController?.view, let contentWindow = content.window
        else { return nil }
        var rect = contentWindow.convert(content.convert(content.bounds, to: nil),
                                         to: contentWindow.screen.coordinateSpace)
        let bar = nav.navigationBar
        if let barWindow = bar.window, !bar.isHidden {
            let barRect = barWindow.convert(bar.convert(bar.bounds, to: nil), to: barWindow.screen.coordinateSpace)
            if barRect.maxY > rect.minY {
                let cut = barRect.maxY - rect.minY
                rect.origin.y += cut
                rect.size.height -= cut
            }
        }
        let popEdge: CGFloat = 24
        rect.origin.x += popEdge
        rect.size.width -= popEdge
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private static func firstNavigationController(in vc: UIViewController) -> UINavigationController? {
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children {
            if let nav = firstNavigationController(in: child) { return nav }
        }
        return nil
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
    /// The phone's own Reduce Motion (the in-app switch is gone — slim
    /// settings, 2026-09-24): the demo ring and the spotlight pulse follow it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tour = model.tour
        ZStack {
            switch tour.phase {
            case .welcome:
                if tour.cardVisible { TourWelcomeCard(tour: tour) }
            case .paused:
                if tour.cardVisible { TourResumeCard(tour: tour) }
                else if tour.chipVisible { TourResumeChip(tour: tour) }
            case .running:
                runningLayer(tour)
            case .dismissed:
                // Paused mid-session: the floating "Resume tour" chip docks
                // bottom-corner across every screen (round 2).
                if tour.chipVisible { TourResumeChip(tour: tour) }
            case .boot, .done:
                EmptyView()
            }
        }
        // One traversal group for VoiceOver: the tour's controls are read as
        // a unit, and while the lock is held nothing under the scrim (the app
        // window) is reachable — TourWindowHandle.setAccessibilityLock.
        .accessibilityElement(children: .contain)
        .task { tour.bootIfNeeded() }
        .onChange(of: tour.accessibilityLockHeld, initial: true) { _, held in
            TourWindowHandle.shared.setAccessibilityLock(held, hiding: tour.accessibilityHidingHeld)
        }
        // The hiding half moves WITHIN a run (step change, a step-opened
        // surface coming up or going away), so it needs its own observation —
        // the lock flag itself stays true across all of those.
        .onChange(of: tour.accessibilityHidingHeld, initial: true) { _, hiding in
            TourWindowHandle.shared.setAccessibilityLock(tour.accessibilityLockHeld, hiding: hiding)
        }
    }

    private func runningLayer(_ tour: TourModel) -> some View {
        GeometryReader { geo in
            let screen = geo.frame(in: .global)
            // Non-negotiable #1: dock the panel OPPOSITE the spotlight target
            // and hard-cap it to the free space on that side, so it can never
            // grow into the ring; only a target that leaves no room for a
            // READABLE panel on either side collapses it to title + controls.
            // Re-evaluated on every rect/height change. While the Ask field
            // owns focus, `keyboard:` forces dock = .top, uncapped, and
            // suppresses collapse (either would unmount or hide the focused
            // field → keyboard drop → re-expand loop).
            let placement = tourPanelPlacement(target: tour.targetRect, screen: screen,
                                               panelHeight: tour.panelExpandedHeight,
                                               keyboard: tour.askFieldFocused)
            // Round 3: a LIVE real focus cover (always USER-started — the tour
            // never mints one) must never sit under the opaque look-alike demo
            // — skip the demo render and run the step panel-only. The claim
            // still swallows every point on demo steps (tourClaims puts
            // demoStep above presentationActive), so no blind touch can reach
            // the session underneath either way. `focusTask` is observable —
            // render and claims stay in step.
            let showDemo = tour.currentStep.isDemoFocus && model.router.focusTask == nil
            ZStack {
                // Round-2 lockdown swallow layer: the window claims almost
                // every point while running (tourClaims), and THIS is the view
                // that actually absorbs those touches — the spotlight above is
                // hit-test-disabled, and UIKit needs a hit-testable SwiftUI
                // region or the claimed tap would find nothing. Pass-through
                // regions (spotlight cutout, an opened sheet) never reach it:
                // claims() answers false and the window returns nil first.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .ignoresSafeArea()
                // Focus/capture steps: the tour's own DEMO focus surface —
                // under the spotlight + panel, above the swallow layer.
                if showDemo {
                    TourDemoFocus(reduceMotion: reduceMotion,
                                  stepID: tour.currentStep.id)
                        .transition(.opacity)
                }
                TourSpotlight(rect: tour.targetRect, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                // ONE panel with a flipping alignment — a single structural
                // identity, so the dock flip is a frame change (not a remount)
                // and the geometry callback below reliably re-fires.
                // `topOffset` (keyboard-time only): nudges the forced-top
                // panel below a top-half ring when both fit — see
                // tourPanelPlacement's documented keyboard × ring decision.
                panel(tour, placement: placement)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: placement.dock == .top ? .top : .bottom)
                    .padding(.top, placement.dock == .top ? placement.topOffset : 0)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
            .animation(.easeOut(duration: 0.22), value: showDemo)
        }
        // The measuring frame must IGNORE the keyboard: SwiftUI keyboard
        // avoidance would shrink the GeometryReader when the Ask field
        // focuses, collapsing the panel and unmounting that very field (the
        // HIGH-severity focus loop). The keyboard-time layout is handled by
        // the forced top dock above instead.
        .ignoresSafeArea(.keyboard)
    }

    private func panel(_ tour: TourModel, placement: TourPanelPlacement) -> some View {
        TourPanel(tour: tour, placement: placement)
            // UIKit frame reader — the hit-test claim reads this view's LIVE
            // window frame at hitTest time (immune to any SwiftUI callback
            // staleness; a stale claim once sent a tap through to the tab bar).
            .background(TourPanelFrameReader().allowsHitTesting(false))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Claim FALLBACK only. This frame is the RESULT of the
                // placement — collapsed or capped to the space the rule just
                // chose — so feeding it back as the panel's height would be
                // feeding the rule its own output. The height input comes from
                // the panel's unconstrained body + chrome measurements instead
                // (TourModel.reportPanelHeight).
                tour.panelFrame = frame
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.22), value: placement.collapsed)
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
                    Text("A quick look at how Unstuck helps you begin, stay with it, and come back — about three minutes for the essentials.")
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
                    // Quiet footer (round 2): the tour is never a commitment.
                    Text("Pause anytime — replay it from Settings → Replay the tour.")
                        .font(UFont.sans(11.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(theme.palette.ink4)
                        .padding(.top, 12)
                }
                .padding(EdgeInsets(top: 30, leading: 30, bottom: 26, trailing: 30))
                .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                // Proof-of-render anchor: the full-screen claim is honored
                // only while this card is actually mounted (see claims()).
                .background(TourCardFrameReader().allowsHitTesting(false))
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
            // Proof-of-render anchor — same claim gate as the welcome card.
            .background(TourCardFrameReader().allowsHitTesting(false))
            .frame(maxWidth: 400)
            .padding(20)
        }
    }
}

/// The floating "Resume tour" chip (round 2): a small pill docked at the
/// bottom-leading corner (the assistant bubble owns bottom-trailing), present
/// across all screens while a paused-with-progress run exists. Tap = resume at
/// the saved step; ✕ = gone for good (the Settings path remains). The chip is
/// the ONLY claimed region while paused — everything else passes through.
struct TourResumeChip: View {
    @Environment(\.uTheme) private var theme
    @Bindable var tour: TourModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                chip
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            // Clear the floating bottom nav (~84pt incl. safe area).
            .padding(.bottom, 92)
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Button { tour.resumeFromChip() } label: {
                HStack(spacing: 7) {
                    Mark(size: 15)
                    Text("Resume tour")
                        .font(UFont.sans(12.5, .semibold))
                        .foregroundStyle(theme.palette.ink)
                }
                .padding(.leading, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume tour")
            Button { tour.dismissChip() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.ink3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss resume tour chip")
            .padding(.trailing, 6)
        }
        .background(theme.palette.bg, in: Capsule())
        .overlay(Capsule().stroke(theme.palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        // Live UIKit frame for the hit-test claim (same pattern as the panel).
        .background(TourChipFrameReader().allowsHitTesting(false))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            tour.chipFrame = frame
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
    /// The paused "Resume tour" chip's UIKit background view — the ONLY
    /// claimed region while the chip is up.
    weak var chipAnchorView: UIView?
    /// The welcome/resume card's UIKit background view — the claim's PROOF OF
    /// RENDER: "card claims everything" is honored only while this anchor is
    /// live in a window (TourModel.claims), so the full-screen claim can never
    /// outlive the card itself.
    weak var cardAnchorView: UIView?
    /// Does the tour UI own this screen point right now? (Wired to
    /// TourModel.claims(point:) at mount; nil/false → full passthrough.)
    var claimsPoint: ((CGPoint) -> Bool)?
    func makeTourKey() { tourWindow?.makeKey() }
    func restoreAppKey() { appWindow?.makeKey() }

    /// Round-4 a11y: while the tour owns the screen, VoiceOver must not reach
    /// the app content under the scrim. The tour window becomes MODAL for
    /// accessibility (its sibling windows are ignored) and the app window's
    /// elements are hidden outright (a UIKit-presented sheet in the app
    /// window would otherwise stay traversable). Idempotent; a screen-change
    /// notification moves the cursor onto the tour when the lock engages.
    ///
    /// The two halves are set SEPARATELY, because they don't have the same
    /// scope: modality lasts the whole run, while hiding has to be lifted on
    /// the steps whose touch policy passes through to a real app control
    /// (TourModel.accessibilityHidingHeld) — otherwise those steps are
    /// impossible to follow with VoiceOver.
    private(set) var accessibilityLockHeld = false
    private(set) var accessibilityHidingHeld = false
    func setAccessibilityLock(_ held: Bool, hiding: Bool? = nil) {
        let hide = (hiding ?? held) && held
        guard held != accessibilityLockHeld || hide != accessibilityHidingHeld else { return }
        accessibilityLockHeld = held
        accessibilityHidingHeld = hide
        tourWindow?.accessibilityViewIsModal = held
        appWindow?.accessibilityElementsHidden = hide
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The overlay window is going away (the signed-in scaffold unmounted):
    /// drop every handle that pointed into it and release the app window's
    /// accessibility lock so nothing stays hidden for the next screen.
    func detach(window: UIWindow) {
        guard tourWindow === window else { return }
        setAccessibilityLock(false)
        claimsPoint = nil
        tourWindow = nil
        appWindow = nil
        panelAnchorView = nil
        chipAnchorView = nil
        cardAnchorView = nil
    }
}

/// Invisible UIKit reader that registers itself into a TourWindowHandle slot
/// while mounted in a window — the live-frame/proof-of-render source for the
/// hit-test claims (panel region, chip region, card render-gate). One generic
/// reader so the three anchors can't drift apart in behavior.
private struct TourHandleAnchorReader: UIViewRepresentable {
    let slot: ReferenceWritableKeyPath<TourWindowHandle, UIView?>

    final class ReaderView: UIView {
        var slot: ReferenceWritableKeyPath<TourWindowHandle, UIView?>?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let slot else { return }
            if window != nil {
                TourWindowHandle.shared[keyPath: slot] = self
            } else if TourWindowHandle.shared[keyPath: slot] === self {
                TourWindowHandle.shared[keyPath: slot] = nil
            }
        }
    }
    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.slot = slot
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ view: ReaderView, context: Context) {}
}

/// The running panel's live-frame reader (authoritative claim region).
private struct TourPanelFrameReader: View {
    var body: some View { TourHandleAnchorReader(slot: \.panelAnchorView) }
}

/// The "Resume tour" chip's live-frame reader (paused-phase claim region).
private struct TourChipFrameReader: View {
    var body: some View { TourHandleAnchorReader(slot: \.chipAnchorView) }
}

/// The welcome/resume card's liveness reader — claims() only lets the card
/// claim the screen while this is mounted (no claim without a render).
private struct TourCardFrameReader: View {
    var body: some View { TourHandleAnchorReader(slot: \.cardAnchorView) }
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
            .unstuckTheme()
    }
}

/// Creates the tour overlay window once the hosting view lands in a window
/// scene. Mounted from MainTabScaffold (signed-in + onboarded only).
struct TourWindowMounter: UIViewRepresentable {
    let model: AppModel
    /// Follows Settings · Appearance theme (nil = system).
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

    /// The signed-in scaffold unmounted (sign-out): hide + release the
    /// overlay window. A visible UIWindow is retained by its scene, so
    /// without this every sign-out/sign-in cycle stacked another always-on-
    /// top tour window (each still rendering a TourRootView against the
    /// model) and the previous account's lock could linger over AuthView.
    static func dismantleUIView(_ uiView: MounterView, coordinator: Coordinator) {
        guard let win = coordinator.window else { return }
        TourWindowHandle.shared.detach(window: win)
        win.isHidden = true
        win.rootViewController = nil
        coordinator.window = nil
    }
}
