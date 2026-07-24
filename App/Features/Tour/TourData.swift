// Guided product tour — step data, canned Q&A, persistence, and the pure
// phase/placement logic. Port of the web components/tour/tour-data.ts
// (copy VERBATIM: ids, stages, titles, body, narration, more, TOUR_QA).
//
// An ADDITIVE layer over the existing app: it teaches the behavioral loop
// while driving the REAL UI (navigating, spotlighting) — never a slideshow.
//
// Deliberately app-import-free (pure data + UserDefaults) so the step list
// and the resume/placement rules stay unit-testable from UnstuckAppTests.

import Foundation
import CoreGraphics

// MARK: - modes + persistence (key parity with web `unstuck.tour.v1`)

enum TourMode: String, Codable, Sendable { case essential, full }
enum TourMediaMode: String, Codable, Sendable { case read, listen }

/// Persisted tour state — the same shape/semantics as the web TourState
/// (started/done/paused/eligible/mode/mediaMode/speed/index). voiceURI is
/// web-only (speechSynthesis fallback); iOS always narrates the bundled clips.
struct TourState: Codable, Equatable, Sendable {
    /// Set once the user has begun (or explicitly declined) the tour.
    var started: Bool?
    var done: Bool?
    var paused: Bool?
    /// Armed when the 5-step onboarding finishes — gates the one-time
    /// auto-welcome so EXISTING accounts are never ambushed by the tour.
    var eligible: Bool?
    var mode: TourMode?
    var mediaMode: TourMediaMode?
    var speed: Double?
    var index: Int?
}

/// UserDefaults-backed store for `TourState` under the web-parity key.
/// JSON-encoded so the stored shape mirrors the web localStorage blob.
/// (UserDefaults is documented thread-safe; it just predates Sendable.)
struct TourStore: @unchecked Sendable {
    static let key = "unstuck.tour.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> TourState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(TourState.self, from: data) else { return TourState() }
        return state
    }

    @discardableResult
    func save(_ patch: (inout TourState) -> Void) -> TourState {
        var next = load()
        patch(&next)
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
        return next
    }
}

// MARK: - step data

/// The surfaces a step can open. iOS maps these onto the real tabs/sheets
/// (today→Today tab, captures→Inbox sheet, settings→Settings sheet, …).
/// NOTE `focus`: the iOS FocusView always mints a live session on init (there
/// is no idle focus state), so the orchestrator maps focus-view steps onto the
/// Today tab and spotlights the hero's Focus begin affordance instead — the
/// tour must NEVER start a real session (spec deviation, noted).
enum TourStepView: String, Sendable {
    case today, tasks, calendar, captures, collections, insights, settings, focus
}

/// Spotlightable anchors — the iOS analogue of the web `data-tour` selectors.
/// Real views register live frames for these via `.tourTarget(_:)`.
enum TourTargetID: String, CaseIterable, Sendable {
    case startNext = "start-next"
    case backlogPointer = "backlog-pointer"
    case todayList = "today-list"
    case firstAction = "first-action"
    case newTask = "new-task"
    case assistantLaunch = "assistant-launch"
    case notifBody = "notif-body"
    /// The Today hero's "Focus" begin button — stands in for the web's
    /// `focus-ring` (no idle focus state exists on iOS; see TourStepView.focus).
    case focusBegin = "focus-begin"
}

struct TourStep: Identifiable, Sendable {
    let id: String
    let stage: String
    let view: TourStepView
    /// Settings steps deep-link a specific section.
    var section: String? = nil
    /// Anchor to spotlight; nil = whisper-light scrim only.
    var target: TourTargetID? = nil
    /// Ordered fallbacks when the primary target isn't on screen
    /// (e.g. an empty account has no hero → the Today list / New-task FAB).
    var targetFallbacks: [TourTargetID] = []
    let title: String
    let body: String
    let narration: String
    var more: String? = nil
    let primary: String
    /// The primary CTA opens the assistant bubble (web `onShow: openAssistant`).
    var opensAssistant: Bool = false
}

/// The step script — copy ported VERBATIM from web tour-data.ts.
enum TourScript {
    static let essential: [TourStep] = [
        TourStep(
            id: "welcome", stage: "Welcome", view: .today, target: nil,
            title: "This is Unstuck",
            body: "Unstuck helps when you know what needs doing but starting, switching, or coming back feels hard. It’s not another task manager — it’s an external executive-function layer.",
            narration: "Welcome to Unstuck. This helps when you already know what needs doing, but starting, switching, or coming back feels hard. It isn’t another task manager — think of it as an external executive-function layer. We’ll keep this short.",
            more: "A normal planner assumes the hard part is deciding what to do. Unstuck assumes you often already know — and the friction is beginning, sustaining, and returning. Everything here is built for that moment.",
            primary: "Continue"),
        TourStep(
            id: "today", stage: "Today", view: .today,
            // Empty-account fallback: a brand-new account with no tasks renders
            // NO hero card at all — spotlight the backlog pointer / Today list.
            target: .startNext, targetFallbacks: [.backlogPointer, .todayList],
            title: "Today narrows it down",
            body: "Start Next offers one realistic suggestion — with a short reason, like the time it fits. It’s a recommendation, never a command. Today shows only planned work; everything else waits in Backlog.",
            narration: "This is Today. Instead of a long list, Start Next offers one realistic suggestion, with a short reason — like the gap it fits before your next meeting. It’s a suggestion, never a command. Today shows only planned work; everything else waits quietly in your Backlog.",
            more: "Usable Time (top of the page and right rail) already accounts for meetings and fragmentation, so the suggestion is grounded in the time you actually have.",
            primary: "Continue"),
        TourStep(
            id: "first-action", stage: "Tasks", view: .tasks,
            target: .firstAction, targetFallbacks: [.newTask],
            title: "The first physical action",
            body: "The task is the outcome. The first physical action is how you begin — something concrete like “Open the document,” not “Write the report.” This is the core anti-overwhelm move.",
            narration: "Open any task and you’ll see its first physical action. The task is the outcome; the first physical action is how you actually begin. Concrete — “open the document” — not abstract like “write the report”. This one habit removes most of the friction of starting.",
            more: "You can click any field in the task detail to edit it in place, and Start, Schedule, Share, or mark Done right from here.",
            primary: "Continue"),
        TourStep(
            id: "assistant", stage: "Assistant", view: .today, target: .assistantLaunch,
            title: "Ask Unstuck to handle it",
            body: "The Assistant lives here, bottom-right. Brain-dump in plain language — “break this down”, “what should I do first?”, “schedule this” — and it performs the real action after you confirm. It operates the app; it isn’t a separate chatbot.",
            narration: "Down here is the Assistant. You can brain-dump in plain language — break this down, what should I do first, schedule this — and it carries out the real action after you confirm. It’s wired into the whole app. Action over conversation.",
            more: "The Assistant only makes high-impact changes (sharing, bulk rescheduling, deleting) after you confirm. Low-risk things like saving a capture happen directly, with Undo.",
            primary: "Open the Assistant", opensAssistant: true),
        TourStep(
            // The web tour navigates to /focus in its idle "Begin focus" state.
            // iOS has NO idle focus state (FocusView mints a session on init),
            // so this step stays on Today and rings the hero's Focus button —
            // it must never mint a real session.
            id: "focus", stage: "Focus", view: .focus,
            target: .focusBegin, targetFallbacks: [.startNext, .backlogPointer, .todayList],
            title: "Focus, and the Ring",
            body: "A session counts upward against your estimate; the screen color follows the state. Calm while you work, warm coral if you run over. No alarms — returning is always supported.",
            narration: "When you start a session you enter Focus. The ring counts upward against your estimate, and the whole screen’s colour follows the state — calm while you work, a warm coral if you run past the estimate. Never an alarm. This is where execution actually happens.",
            more: "Three looks — Ambient, Cockpit, and Monk — let you match the focus screen to how your brain settles.",
            primary: "Enter Focus"),
        TourStep(
            id: "capture", stage: "Focus", view: .focus,
            target: .focusBegin, targetFallbacks: [.startNext, .backlogPointer, .todayList],
            title: "Capture without leaving",
            body: "A stray thought mid-session? Press C or tap the mic and it’s saved — “add washing liquid to Groceries” — linked to this session, without breaking your focus.",
            narration: "While focusing, thoughts will surface. Don’t chase them. Press C, or tap the microphone, and Unstuck saves it — say, add washing liquid to groceries — linked to this session. You stay in focus; the thought is safe.",
            more: "Every capture lands in your Captures inbox, still linked to the task or session it came from, so nothing gets lost.",
            primary: "Enter Focus"),
        TourStep(
            id: "reentry", stage: "Recovery", view: .today, target: .assistantLaunch,
            title: "Interruption, then re-entry",
            body: "Life interrupts. When you come back, Unstuck rebuilds the context — the task, time spent, your captures, and the next action — so you don’t start from scratch. Returning is a feature, not a failure.",
            narration: "You’ll get interrupted — that’s expected. When you return, ask the Assistant “what was I doing?” and Unstuck rebuilds the picture: the task, the time you spent, the thoughts you captured, and your next physical action. You don’t reconstruct anything. Returning is part of the design.",
            more: "Pausing asks for an optional reason, and you can Save for later instead of ending — so the thread is never dropped.",
            primary: "Continue"),
        TourStep(
            id: "notifications", stage: "Trust", view: .settings, section: "Notifications",
            target: .notifBody,
            title: "You set how present it is",
            body: "Choose Calm, Balanced, or Coach — how much support Unstuck offers. Everything is quiet by default and nothing shouts. You can change this anytime.",
            narration: "One of the most important settings: how present Unstuck is. Calm gives you only the essentials. Balanced adds useful prompts without noise. Coach offers more active support. It’s your call, and you can change it whenever you like.",
            more: "Notifications are in-app and quiet by default — no red badges unless you ask for them.",
            primary: "Continue"),
        TourStep(
            id: "finish", stage: "Begin", view: .today,
            target: .startNext, targetFallbacks: [.backlogPointer, .todayList],
            title: "You’re ready to begin",
            body: "That’s the loop: Today narrows things down, the first physical action gets you moving, Focus sustains it, and the Assistant helps when you’re stuck. Pick one real next step.",
            narration: "That’s the core loop. Today narrows things down. The first physical action gets you moving. Focus sustains it. And the Assistant is there when you get stuck. You don’t need to learn everything today — just choose one real next step, and begin.",
            more: "You can reopen this tour anytime from Settings → Account. Nothing you skip is lost.",
            primary: "Begin"),
    ]

    /// Look up a shared essential step by id — a broken full tour should fail
    /// loudly (in tests / debug), not render holes. Mirrors web `essential()`.
    static func essentialStep(_ id: String) -> TourStep {
        guard let step = essential.first(where: { $0.id == id }) else {
            fatalError("tour: missing essential step '\(id)'")
        }
        return step
    }

    static let full: [TourStep] = Array(essential.prefix(3)) + [
        TourStep(
            id: "calendar", stage: "Calendar", view: .calendar, target: nil,
            title: "A realistic day",
            body: "Today, Week, and Month views — with a current-time line and a light focus heatmap. Drag tasks from the unscheduled tray onto real free gaps, or let Auto-sequence place them for you.",
            narration: "The Calendar gives you Today, Week, and Month. Drag tasks from the unscheduled tray onto genuine free gaps, or let Auto-sequence fit them into your open time. It reads your Google Calendar so the plan reflects a real day.",
            primary: "Continue"),
        TourStep(
            id: "captures", stage: "Capture", view: .captures, target: nil,
            title: "Nothing gets lost",
            body: "Every captured thought lands here, still linked to where it came from. Promote it to a task, open it, or archive it — on your schedule, without pressure.",
            narration: "The Captures inbox holds every thought you dumped, still linked to its task or session. Triage when you have bandwidth — promote to a task, open, or archive.",
            primary: "Continue"),
        TourStep(
            id: "collections", stage: "Collections", view: .collections, target: nil,
            title: "Things to keep, not do",
            body: "Collections are calm shelves — groceries, books, quotes — that never nag. Distinct from Tasks, which represent intended action. Share a list and updates appear live.",
            narration: "Collections are for things to keep and remember without pressure — groceries, books, quotes. They’re deliberately separate from Tasks, which represent action. Share a list and edits appear instantly for everyone on it.",
            primary: "Continue"),
        essentialStep("assistant"),
        essentialStep("focus"),
        essentialStep("reentry"),
        TourStep(
            id: "sharing", stage: "Together", view: .tasks, target: nil,
            title: "Trusted, by invite",
            body: "Your Trusted Circle is small and private — nothing is shared by default. Share a task as View (follow along), Partner (either can complete, focus together), or Assign (it becomes theirs).",
            narration: "Sharing is invite-only and private by default. When you share a task you choose the level: View to follow along, Partner so either of you can complete it and focus together, or Assign to hand it over entirely. A shared session runs one timer both people can join.",
            primary: "Continue"),
        TourStep(
            id: "insights", stage: "Insights", view: .insights, target: nil,
            title: "Observations, not scores",
            body: "Insights show useful patterns — estimate accuracy, what keeps slipping, when you focus best. No productivity grade, ever.",
            narration: "Insights offer observations, never a score. Estimate accuracy, work that keeps slipping, the times of day you focus best. Useful from your very first session — and never a grade.",
            primary: "Continue"),
        essentialStep("notifications"),
        TourStep(
            id: "personalization", stage: "Personalize", view: .settings, section: "Interface", target: nil,
            title: "Make it yours",
            body: "Theme, accent, density, and text size; focus defaults; your areas and tags. Adjust what helps, ignore the rest.",
            narration: "Personalization covers appearance — theme, accent, density, text size — plus your focus defaults and how you manage areas and tags. Change what helps you; leave the rest.",
            primary: "Continue"),
        essentialStep("finish"),
    ]

    static func steps(for mode: TourMode) -> [TourStep] {
        mode == .full ? full : essential
    }
}

// MARK: - canned Q&A (the INSTANT fallback for "Ask a question")

struct TourQAEntry: Sendable {
    /// Case-insensitive regex over the question (web `m`).
    let pattern: String
    let answer: String
}

/// Ported verbatim from web TOUR_QA.
let TOUR_QA: [TourQAEntry] = [
    TourQAEntry(pattern: "different|task manager|why unstuck",
                answer: "A planner assumes deciding is the hard part. Unstuck assumes you already know — and helps with the part that actually breaks: starting, sustaining, and returning."),
    TourQAEntry(pattern: "usable time",
                answer: "The focus time you realistically have left today, after meetings and fragmentation are subtracted. Suggestions are grounded in it."),
    TourQAEntry(pattern: "collections.*separate|separate.*collections|why.*collections",
                answer: "Tasks are intended actions — they can nag. Collections are things to keep and remember, and never appear in Today."),
    TourQAEntry(pattern: "assistant.*do|can the assistant|do this for me",
                answer: "Yes — it creates, schedules, and updates real tasks and lists. It confirms before any high-impact change."),
    TourQAEntry(pattern: "miss.*session|what happens if i miss",
                answer: "Nothing bad. There’s no penalty or streak. When you come back, re-entry rebuilds the context for you."),
    TourQAEntry(pattern: "shared focus|focus.*work.*together",
                answer: "One timer per shared task. Either person can start; the other joins mid-session. Either can pause, extend, or finish, with clear labels like “Paused by Sam”."),
    TourQAEntry(pattern: "who can see|my data|privacy",
                answer: "Nothing is shared by default. You share per-task, per-person, and can revoke it. Your Trusted Circle is invite-only."),
    TourQAEntry(pattern: "partner.*assign|difference.*partner",
                answer: "Partner: either of you can complete it and focus together. Assign: it becomes their task entirely."),
    TourQAEntry(pattern: "notifications off|turn.*off|can i turn",
                answer: "Yes. Calm mode keeps only essentials, and you can adjust it anytime in Notifications."),
    TourQAEntry(pattern: "offline|lose signal",
                answer: "Unstuck works offline. Your changes sync automatically when you reconnect."),
    TourQAEntry(pattern: "restart|tour again|find the tour",
                answer: "Reopen it anytime from Settings → Account → Product tour."),
]

let TOUR_FALLBACK_ANSWER =
    "Good question — the short version: Unstuck reduces the friction of starting and returning. Ask the Assistant anytime for specifics."

/// Canned answer lookup (web `answerFor`). First matching TOUR_QA entry, else
/// the generic fallback.
func tourAnswer(for question: String) -> String {
    for entry in TOUR_QA {
        guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) else { continue }
        let range = NSRange(question.startIndex..., in: question)
        if regex.firstMatch(in: question, options: [], range: range) != nil { return entry.answer }
    }
    return TOUR_FALLBACK_ANSWER
}

// MARK: - pure phase logic (web initialPhase / resumeDecision)

enum TourEntryPhase: Equatable, Sendable { case hidden, paused, welcome }

/// Where the tour surfaces on app load. A finished (or previously started /
/// declined) tour stays hidden; a paused run offers the resume card; a fresh
/// account that just completed onboarding (eligible) gets the one-time
/// welcome. Everyone else — existing accounts — sees nothing unless they
/// open the tour explicitly.
func tourInitialPhase(_ state: TourState) -> TourEntryPhase {
    if state.done == true { return .hidden }
    if state.paused == true && state.mode != nil { return .paused }
    if state.started == true { return .hidden }
    return state.eligible == true ? .welcome : .hidden
}

enum TourResumeDecision: Equatable, Sendable {
    case running(index: Int)
    case welcome
}

/// Explicit open (Settings → Product tour): resume at the saved step if an
/// UNFINISHED run exists, otherwise show the welcome. A FINISHED tour
/// (done == true) restarts from the welcome card — web restart semantics —
/// never "resumes" at its last step.
func tourResumeDecision(_ state: TourState) -> TourResumeDecision {
    if state.done != true, state.started == true, let index = state.index {
        return .running(index: index)
    }
    return .welcome
}

// MARK: - listen speed cycle (web cycleSpeed)

/// 0.75 → 1 → 1.25 → 1.5 → 1.75 → 2 → back to 0.75.
func nextTourSpeed(_ speed: Double) -> Double {
    speed >= 2 ? 0.75 : ((speed + 0.25) * 100).rounded() / 100
}

// MARK: - panel placement (non-negotiable #1: NEVER cover the spotlight)

enum TourPanelDock: Equatable, Sendable { case top, bottom }

struct TourPanelPlacement: Equatable, Sendable {
    var dock: TourPanelDock
    /// Target so tall it spans both halves and the free space can't fit the
    /// full panel → collapse the panel to title + controls rather than cover
    /// the ring.
    var collapsed: Bool
}

/// Compute where the panel docks for a target rect (screen coordinates):
/// target center in the TOP half → panel at the BOTTOM; bottom half → TOP;
/// no target → bottom. If the chosen side's free space (outside the ring +
/// its padding) can't fit the expanded panel, collapse it. Pure — unit-tested.
///
/// - Parameters:
///   - target: the spotlight target rect (nil = whisper scrim, panel bottom).
///   - screen: the full screen bounds. Callers must measure this IGNORING the
///     software keyboard (`.ignoresSafeArea(.keyboard)` / window bounds) — a
///     keyboard-shrunk frame would collapse the panel and unmount the very
///     field that summoned the keyboard (drop → re-expand → loop).
///   - panelHeight: the EXPANDED panel height (measured; callers must not feed
///     the collapsed height back in, or the decision oscillates).
///   - keyboard: the Ask input owns focus / the keyboard is up. The keyboard
///     owns the bottom of the screen, so the panel is FORCED to the top dock
///     and the collapse rule is suppressed — collapsing would unmount the
///     focused field and drop the keyboard (the HIGH-severity focus loop).
///   - margin: outer margin between panel and screen/ring edges.
///   - ringPad: spotlight padding + ring width around the target (8 + 6).
func tourPanelPlacement(target: CGRect?, screen: CGRect, panelHeight: CGFloat,
                        keyboard: Bool = false,
                        margin: CGFloat = 16, ringPad: CGFloat = 14) -> TourPanelPlacement {
    if keyboard { return TourPanelPlacement(dock: .top, collapsed: false) }
    guard let target, target.width > 0, target.height > 0 else {
        return TourPanelPlacement(dock: .bottom, collapsed: false)
    }
    let ring = target.insetBy(dx: -ringPad, dy: -ringPad)
    let dock: TourPanelDock = target.midY < screen.midY ? .bottom : .top
    let available: CGFloat = dock == .bottom
        ? screen.maxY - ring.maxY - margin * 2
        : ring.minY - screen.minY - margin * 2
    return TourPanelPlacement(dock: dock, collapsed: available < panelHeight)
}

// MARK: - cross-feature signals

extension Notification.Name {
    /// Posted just before the tour drives navigation for a step (or exits), so
    /// screens with LOCAL sheet state (Today/Tasks/Calendar/Collections present
    /// Settings & co. from @State, outside the router) can close them — the
    /// router's dismissAllPresentations can't reach those.
    static let unstuckTourWillNavigate = Notification.Name("unstuck-tour-will-navigate")
}
