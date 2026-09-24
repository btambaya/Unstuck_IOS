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
/// (started/done/paused/eligible/mode/mediaMode/speed/index/chipDismissed).
/// voiceURI is web-only (speechSynthesis fallback); iOS always narrates the
/// bundled clips.
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
    /// The user ✕-dismissed the floating "Resume tour" chip — it never comes
    /// back for this run (Settings → Replay the tour remains). Cleared when a
    /// fresh run begins.
    var chipDismissed: Bool?
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

    /// Forget the run entirely (sign-out): the tour is per account — the
    /// next person on this device must get their own one-time welcome, never
    /// the previous account's resume card / step index (Android clears
    /// TourStateStore at sign-out; the web key is in SYNCED_LOCAL_KEYS).
    func clear() { defaults.removeObject(forKey: Self.key) }

    static func clear(defaults: UserDefaults = .standard) { TourStore(defaults: defaults).clear() }
}

// MARK: - step data

/// The surfaces a step can open. iOS maps these onto the real tabs/sheets
/// (today→Today tab, captures→Inbox sheet, settings→Settings sheet, …).
/// NOTE `focus` (round 2): the tour renders its OWN full-screen DEMO focus
/// surface (TourDemoFocus, inside the tour window) — the app stays on Today
/// underneath and a real session is NEVER minted. The spotlight targets for
/// these steps live inside the demo.
enum TourStepView: String, Sendable {
    case today, tasks, calendar, captures, collections, insights, settings, focus
}

/// Spotlightable anchors — the iOS analogue of the web `data-tour` selectors.
/// Real views register live frames for these via `.tourTarget(_:)`.
enum TourTargetID: String, CaseIterable, Sendable {
    /// The Today list section (filters + rows) — the today/finish anchor.
    /// (`start-next`, the gradient hero card, was removed from Today on
    /// 2026-09-18; the list is the subject of those steps now.)
    case todayList = "today-list"
    case firstAction = "first-action"
    case newTask = "new-task"
    case assistantLaunch = "assistant-launch"
    case notifBody = "notif-body"
    /// The DEMO focus surface's progress ring (rendered by the tour itself —
    /// the analogue of web's `focus-ring`).
    case focusRing = "focus-ring"
    /// The DEMO focus surface's Capture pill — the capture step's anchor.
    case captureHint = "capture-hint"
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
    /// (e.g. an empty account has no task to open → the New-task FAB).
    var targetFallbacks: [TourTargetID] = []
    let title: String
    let body: String
    let narration: String
    var more: String? = nil
    let primary: String
    /// The primary CTA opens the assistant bubble (web `onShow: openAssistant`).
    var opensAssistant: Bool = false
    /// Round 3 (cross-platform cutout policy): the spotlight cutout passes
    /// touches through to the app ONLY on this step — every other step's ring
    /// is DISPLAY-ONLY and claims() swallows the cutout region too. TRUE only
    /// for the assistant/reentry steps, whose whole point is tapping the
    /// ringed launcher (and using the sheet it opens). Everywhere else a
    /// pass-through cutout was a live gun: tapping the (since removed) ringed
    /// Start-Next hero minted a REAL focus session mid-tour — and a ringed
    /// Today row opens a real task just the same.
    var cutoutInteractive: Bool = false

    /// Round 2: the focus/capture steps present the tour's own DEMO focus
    /// surface (TourDemoFocus) instead of navigating anywhere.
    var isDemoFocus: Bool { view == .focus }

    /// Round 3 (video-verified leak): a step-opened sheet stays interactive
    /// ONLY when using it IS the step — the assistant/reentry sheets (you type
    /// into them) and the settings sections (choosing Calm/Balanced/Coach is
    /// the demo). Every other presented surface (task detail on first-action,
    /// Inbox, Insights) is display-only: the tester could scroll the task
    /// sheet and edit a REAL estimate mid-tour through the old blanket
    /// exemption. Web (inert <main>) and Android (settings-scoped) already
    /// lock these.
    var surfaceInteractive: Bool { cutoutInteractive || opensAssistant || view == .settings }

    /// Round 4: the settings exemption is SCOPED to the section the step
    /// pushed (Notifications / Appearance) — never the whole Settings sheet.
    /// With the blanket sheet exemption a tester could tap Back to the root
    /// and hit Sign out / Delete account / Export mid-tour (sign-out left the
    /// running lockdown live over AuthView). Only points inside the pushed
    /// section's content pass through; the nav bar, the root list and the
    /// pop-gesture edge stay claimed (tourClaims: `surfaceRect` / `surfaceScoped`).
    var surfaceScoped: Bool { view == .settings }
}

/// The step script — copy ported VERBATIM from web tour-data.ts, except the
/// `today` step: the web dashboard still has a Start-Next card, the iOS home
/// does not (2026-09-18), so its body / narration / more describe the Today
/// list instead.
enum TourScript {
    /// Steps whose bundled Cherry narration + more clips are NOT in the app —
    /// Listen is hidden there (`TourAudioPlayer.hasAudio` → false) until the
    /// clips are regenerated from the CURRENT `narration` / `more` text
    /// (DashScope qwen3-tts-flash, voice "Cherry", AAC 24 kHz mono — recipe in
    /// handover.md). EMPTY since 2026-09-18: the `today` clips were re-recorded
    /// for the hero-less home. Park a step here only while its copy and its
    /// clips disagree; `TourAudioManifestTests` pins the set AND the exact
    /// strings the `today` clips speak.
    static let stepsAwaitingNarration: Set<String> = []

    /// Clips that are still in the bundle (the Xcode project lists every
    /// file, and it is not regenerated here) but whose recorded words no
    /// longer match the step copy, so they are NEVER played —
    /// `TourAudioPlayer.url(forStep:)` answers nil for them. Slim settings
    /// (2026-09-24): `personalization.m4a` narrates "theme, accent, density,
    /// text size" and "your focus defaults" (gone from Settings), and
    /// `finish-more.m4a` says "reopen this tour from Settings → Account" (now
    /// "Settings → Replay the tour"). Listen is hidden on the personalization
    /// step and Tell-me-more on finish expands silently — the web drops the
    /// same two entries (components/tour/tour-audio.ts). Re-record both from
    /// the CURRENT text (Cherry recipe above), then empty this set.
    static let staleClips: Set<String> = ["personalization", "finish-more"]

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
            // The Today list section (filters + rows) — always on screen, so
            // no fallback is needed (an empty account rings the list's empty
            // note).
            target: .todayList,
            // Copy describes the hero-less home (2026-09-18): greeting → week
            // pill → assistant input pill → the Today list. SAME strings on
            // Android; today.m4a / today-more.m4a were synthesised from EXACTLY
            // these (TourAudioManifestTests pins them — edit here = re-record).
            title: "Today narrows it down",
            body: "Your home: a greeting, how much you’ve focused this week, and the assistant pill — ask, plan, or brain-dump; say it or type it, and it does it. Below that, Today lists only what’s planned for today, filtered by area. Everything else waits in Backlog. Focus starts from any task row, or from inside the task.",
            narration: "This is Today. Up top: a greeting, how much you’ve focused this week, and the assistant pill — ask, plan, or brain-dump. Say it or type it, and it does it. Under that, the list shows only what’s planned for today, filtered by area; everything else waits quietly in Backlog. Focus starts from any task row, or from inside the task.",
            more: "Filter Today by area with the pills above the list, or switch to Backlog to see what’s waiting. Any row can start Focus — so can the task itself. Nothing unplanned is lost; it just isn’t in the way.",
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
            primary: "Open the Assistant", opensAssistant: true, cutoutInteractive: true),
        TourStep(
            // Round 2 (all platforms): the focus/capture steps present a DEMO
            // focus surface rendered by the tour itself — ring mid-progress,
            // state colors, capture hint — visually faithful, ZERO sessions,
            // zero navigation. The spotlight targets live inside the demo.
            id: "focus", stage: "Focus", view: .focus,
            target: .focusRing,
            title: "Focus, and the Ring",
            body: "A session counts upward against your estimate; the screen color follows the state. Calm while you work, warm coral if you run over. No alarms — returning is always supported.",
            narration: "When you start a session you enter Focus. The ring counts upward against your estimate, and the whole screen’s colour follows the state — calm while you work, a warm coral if you run past the estimate. Never an alarm. This is where execution actually happens.",
            more: "Three looks — Ambient, Cockpit, and Monk — let you match the focus screen to how your brain settles.",
            primary: "Enter Focus"),
        TourStep(
            id: "capture", stage: "Focus", view: .focus,
            target: .captureHint,
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
            primary: "Continue", cutoutInteractive: true),
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
            target: .todayList,
            title: "You’re ready to begin",
            body: "That’s the loop: Today narrows things down, the first physical action gets you moving, Focus sustains it, and the Assistant helps when you’re stuck. Pick one real next step.",
            narration: "That’s the core loop. Today narrows things down. The first physical action gets you moving. Focus sustains it. And the Assistant is there when you get stuck. You don’t need to learn everything today — just choose one real next step, and begin.",
            more: "You can replay this tour anytime from Settings → Replay the tour. Nothing you skip is lost.",
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
            id: "personalization", stage: "Personalize", view: .settings, section: "Appearance", target: nil,
            title: "Make it yours",
            body: "Pick light or dark and your text size here. Areas and tags live on Tasks; focus options live on the Focus screen.",
            narration: "Here you pick light or dark, and your text size. Your areas and tags live on the Tasks screen, and focus options live on the Focus screen, right where you use them. Change what helps you; leave the rest.",
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
                answer: "Yes. Calm keeps only the reminders you set, and you can change it anytime in Settings → Notifications & calls."),
    TourQAEntry(pattern: "offline|lose signal",
                answer: "Unstuck works offline. Your changes sync automatically when you reconnect."),
    TourQAEntry(pattern: "restart|tour again|find the tour",
                answer: "Replay it anytime from Settings → Replay the tour."),
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

/// Explicit open (Settings → Replay the tour): resume at the saved step if an
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

// MARK: - live captions (round 2 — web tour-voice splitSentences + spans)

/// Split narration into sentences — the Swift port of web tour-voice's
/// splitSentences: keep the terminal punctuation (. ! ? …) plus trailing
/// closing quotes/brackets, fold stray fragments (< 4 chars — a lone closing
/// quote, an initialism tail) into the previous sentence, and never return
/// empty for non-empty input. Pure — unit-tested.
func splitTourSentences(_ text: String) -> [String] {
    let pattern = "[^.!?…]+[.!?…]+[\"'”’)\\]]*\\s*"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [t]
    }
    let ns = text as NSString
    var out: [String] = []
    var last = 0
    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let s = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        last = m.range.location + m.range.length
    }
    let rest = ns.substring(from: last).trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty { out.append(rest) }
    var merged: [String] = []
    for s in out {
        if !merged.isEmpty && s.count < 4 { merged[merged.count - 1] += " \(s)" }
        else { merged.append(s) }
    }
    if merged.isEmpty {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [t]
    }
    return merged
}

/// Which sentence is being spoken at `progress` (0…1) through a clip —
/// each sentence owns a span of the audio proportional to its CHARACTER
/// count (the same char-weighted estimate the web tour voice uses). The
/// Listen bar shows sentences[index] as the live caption. Pure.
func tourCaptionIndex(progress: Double, sentences: [String]) -> Int {
    guard !sentences.isEmpty else { return 0 }
    let total = sentences.reduce(0) { $0 + max(1, $1.count) }
    let p = min(max(progress, 0), 1)
    var acc = 0.0
    for (i, s) in sentences.enumerated() {
        acc += Double(max(1, s.count)) / Double(total)
        if p < acc { return i }
    }
    return sentences.count - 1
}

// MARK: - Tell-me-more handback progress (round 3)

/// Progress to show once a Tell-me-more clip hands playback back to the
/// narration. Normally the narration's paused position — but a narration that
/// already finished NATURALLY must stay at 1: AVAudioPlayer rewinds
/// currentTime to 0 after a clip plays to its end, so recomputing from the
/// player would snap the Listen bar 1 → 0 on the handback. Pure — unit-tested.
func tourHandbackProgress(preMoreProgress: Double, currentTime: TimeInterval, duration: TimeInterval) -> Double {
    if preMoreProgress >= 1 { return 1 }
    guard duration > 0 else { return 0 }
    return min(1, currentTime / duration)
}

// MARK: - paused "Resume tour" chip (round 2)

/// The floating "Resume tour" chip is offered while a resumable paused run
/// exists and the user hasn't ✕-dismissed the chip. done/declined runs and
/// paused states without a mode (can't resume) never show it. Pure.
func tourChipEligible(_ s: TourState) -> Bool {
    s.paused == true && s.done != true && s.started == true
        && s.mode != nil && s.chipDismissed != true
}

// MARK: - hit-test claims (round 2 — spotlight-only lockdown)

/// Spotlight pad (8) + ring stroke/halo allowance (6) — the pass-through
/// cutout around a target matches what the ring visually encloses.
let tourClaimRingPad: CGFloat = 14

/// Everything TourModel.claims(point:) needs, flattened so the decision is
/// pure and unit-testable.
struct TourClaimContext: Equatable, Sendable {
    /// The welcome/resume card is up — modal, claims the whole screen.
    var cardVisible = false
    /// The paused "Resume tour" chip is up — ONLY the chip is claimable;
    /// the app underneath stays fully usable.
    var chipVisible = false
    var chipFrame = CGRect.zero
    var running = false
    var panelFrame = CGRect.zero
    /// The current step's resolved spotlight rect (nil = no-target step).
    var targetRect: CGRect? = nil
    /// The step renders the tour's own demo focus surface (focus/capture).
    var demoStep = false
    /// The step's cutout PASSES touches through (assistant/reentry only —
    /// TourStep.cutoutInteractive). Every other ring is display-only.
    var cutoutInteractive = false
    /// A sheet/cover is presented in the APP window (assistant bubble,
    /// settings/inbox/insights sheet, task detail).
    var presentationActive = false
    /// The current step's surface is MEANT to be used (assistant/reentry/
    /// settings — TourStep.surfaceInteractive). Only then does an active
    /// presentation revert the claim to panel-only; on every other step the
    /// presented sheet is display-only and the tour swallows it (round 3 —
    /// the task-detail sheet was fully editable mid-tour).
    var surfaceExempt = false
    /// Round 4: the exemption is SCOPED (settings steps — TourStep.surfaceScoped):
    /// only points inside `surfaceRect` pass through; everything else on the
    /// presented sheet (nav bar Back, the root list with Sign out / Delete
    /// account / Export, the pop-gesture edge) is claimed. A scoped step with
    /// NO resolved rect (section not pushed yet / popped back to the root /
    /// the UIKit stack couldn't be read) fails CLOSED: panel-only.
    var surfaceScoped = false
    /// The permitted region of the presented surface, screen coordinates
    /// (the pushed settings section's content, below the navigation bar).
    var surfaceRect: CGRect? = nil
}

/// Which screen points the tour overlay window OWNS (handles or swallows) vs.
/// passes through to the app. Round-2 lockdown: while the tour runs, ONLY the
/// spotlighted element and the panel are interactive — everything else (dim
/// panels, nav/tabs, FAB) is claimed and swallowed; swallowed touches do
/// nothing. Round-3 refinements (cross-platform cutout policy):
///  • the cutout passes through ONLY on cutoutInteractive steps (assistant /
///    reentry — the launcher + its sheet ARE the step). Every other ring is
///    display-only: the cutout region is claimed and swallowed too, so a
///    spotlighted Today row can never open a real task (or, before the hero
///    went, mint a real session) mid-tour;
///  • demo focus steps claim everything, EVEN while a presentation is active
///    (the demoStep check sits above presentationActive): a live REAL focus
///    cover under the opaque demo must never receive blind pass-through
///    touches. (The render side skips the demo over a live cover — see
///    TourRootView.runningLayer — but the claim swallows regardless.);
///  • a step-opened surface reverts the claim to panel-only while presented
///    ONLY on surfaceInteractive steps (assistant/reentry/settings — using
///    the sheet IS the step). On every other step (task detail, inbox,
///    insights) the presented sheet is display-only: claimed and swallowed
///    (round 3 — the task-detail sheet was live and real edits got through);
///  • no-target steps claim everything except the panel;
///  • (round 4) a SCOPED exemption (settings steps) passes through ONLY the
///    pushed section's content (`surfaceRect`) — the sheet's nav bar / root
///    list (Sign out, Delete account, Export) stay claimed — and fails closed
///    (panel-only) while that region is unknown.
func tourClaims(point: CGPoint, ctx: TourClaimContext) -> Bool {
    if ctx.cardVisible { return true }
    if ctx.chipVisible { return ctx.chipFrame.insetBy(dx: -8, dy: -8).contains(point) }
    guard ctx.running else { return false }
    if ctx.panelFrame.insetBy(dx: -8, dy: -8).contains(point) { return true }
    if ctx.demoStep { return true }
    if ctx.presentationActive {
        guard ctx.surfaceExempt else { return true }
        guard ctx.surfaceScoped else { return false }
        guard let r = ctx.surfaceRect, r.width > 0, r.height > 0 else { return true }
        return !r.contains(point)
    }
    if ctx.cutoutInteractive,
       let t = ctx.targetRect, t.width > 0, t.height > 0,
       t.insetBy(dx: -tourClaimRingPad, dy: -tourClaimRingPad).contains(point) {
        return false
    }
    return true
}

/// Should the app window be hidden from ACCESSIBILITY while the tour owns the
/// screen (round-4 lockdown)? The invariant: **never hide from VoiceOver
/// something the touch layer still accepts touches on.** Hiding the whole app
/// window is right while `tourClaims` swallows every app point, and wrong the
/// moment it deliberately passes one through — on those steps the pass-through
/// control (the ringed assistant launcher; the section a settings step opens)
/// IS the step, and hiding it leaves the step followable by sighted users only.
///
/// Mirrors `tourClaims`' structure deliberately, minus the point: the same
/// branches, answering "is there ANY pass-through region right now?". Reads
/// only fields that come from OBSERVABLE model state — never the live UIKit
/// frames (`panelFrame` / `surfaceRect`), which change without notifying
/// SwiftUI and would leave the flag stuck at its last value. The scoped
/// settings exemption therefore lifts hiding as soon as the sheet is up, a
/// beat before the touch layer resolves the section rect; a11y visibility is
/// not the boundary that keeps Sign out / Delete account unreachable —
/// `tourClaims` is, and it still fails closed.
func tourHidesAppFromAccessibility(ctx: TourClaimContext) -> Bool {
    if ctx.cardVisible { return true }
    guard ctx.running else { return false }
    if ctx.demoStep { return true }
    if ctx.presentationActive { return !ctx.surfaceExempt }
    if ctx.cutoutInteractive, let t = ctx.targetRect, t.width > 0, t.height > 0 { return false }
    return true
}

// MARK: - panel placement (non-negotiable #1: NEVER cover the spotlight)

enum TourPanelDock: Equatable, Sendable { case top, bottom }

/// TourPanel's layout metrics. The placement rule has to know how much PANEL a
/// slice of free space can actually hold — an all-or-nothing rule that only
/// knows the whole expanded height collapses a panel that had room for its
/// title and most of its copy (the 2026-09-18 today/finish bug on 6.3" phones:
/// 242pt free above the ringed Today list, a 358pt panel — title-only
/// rendered).
///
/// Every number below is MEASURED off the real panel on the simulator (hosted
/// and laid out at 354pt wide — a 402pt screen less the running layer's 2×24
/// padding), not read off the padding constants:
/// SwiftUI's rendered line box for Geist 13.5 is 18.22pt, not the face's own
/// 17.55pt line height, and the device pixel grid moves each line origin by up
/// to ⅓pt. `TourPanelMeasureTests` re-measures all of them, so a padding or
/// font change fails there rather than silently mis-sizing the panel.
///
/// The `header`/`footer`/`chrome` figures describe the panel with its ordinary
/// CONTROLS footer. They are a SEED, not a source of truth: the inline pause
/// confirm makes the footer 134pt (measured), so the panel measures its own
/// chrome at runtime and reports `chrome + body` from there — see
/// `TourModel.reportPanelHeight`.
enum TourPanelMetrics {
    /// Header row: 12pt top padding + the 32pt ✕-button row + 10pt bottom.
    static let header: CGFloat = 54
    /// Footer with the CONTROLS row. The inline pause confirm swaps in a taller
    /// block (+67pt measured) — hence "seed, not truth" above.
    static let footer: CGFloat = 67
    /// Header + footer: the chrome that stays PINNED while the body scrolls.
    static let chrome = header + footer                       // 121
    /// The body block's own padding (14pt top + 4pt bottom).
    static let bodyInsets: CGFloat = 18
    /// One line of the serif-italic step title, and the gap under it.
    static let title: CGFloat = 26
    static let titleToBody: CGFloat = 8
    /// One RENDERED line of body copy — SwiftUI's line box for Geist 13.5,
    /// measured, not the face's 17.55pt ascent+descent — plus the 3pt
    /// `lineSpacing` the panel sets BETWEEN lines. Measured pitch: 21.22pt.
    static let bodyLine: CGFloat = 18.22
    static let bodyLineSpacing: CGFloat = 3

    /// The body block a collapsed panel still shows: its own padding plus the
    /// one title line. TourPanel floors the body at this against its MEASURED
    /// chrome, so the step's name survives however tall the footer really is.
    static let titleBlock = bodyInsets + title                 // 44
    /// Title + controls only — what a collapsed panel needs with the ordinary
    /// footer, and the floor the cap is given when a ring leaves less than that
    /// (overlapping is unavoidable at that point).
    static let collapsedMin = chrome + titleBlock              // 165
    /// The smallest panel that still READS: the collapsed floor plus three
    /// lines of body copy. At or above this the panel stays EXPANDED and its
    /// body scrolls under the cap; below it there is nothing to show but the
    /// title, so it collapses. Measured: 233.66pt, against the 242pt the Today
    /// ring leaves on a 6.3" phone — 8.3pt of headroom, a third of a line.
    static let readableMin = collapsedMin + titleToBody
        + bodyLine * 3 + bodyLineSpacing * 2                   // ≈ 233.66
}

struct TourPanelPlacement: Equatable, Sendable {
    var dock: TourPanelDock
    /// Neither side can hold a READABLE panel (a ring spanning nearly the whole
    /// screen) → title + controls only, rather than cover the ring.
    var collapsed: Bool
    /// Hard height cap: the free space outside the ring on the docked side, so
    /// the panel can never grow into the spotlight. nil = unconstrained — the
    /// panel fits as it is (or there is no ring to avoid), and it hugs its
    /// content exactly as it always has.
    var maxHeight: CGFloat?
    /// Keyboard-time nudge (round 3): extra top inset pushing the forced-TOP
    /// panel just BELOW a top-half ring when both fit above the keyboard.
    /// 0 everywhere else.
    var topOffset: CGFloat = 0
}

/// Compute where the panel docks for a target rect (screen coordinates) and
/// how much room it may use there. Ordered rule — pure, unit-tested:
///
///  1. Preferred dock = OPPOSITE the target (center in the top half → bottom;
///     bottom half → top; no target → bottom).
///  2. That side fits the whole expanded panel → expanded, uncapped.
///  3. It fits at least `TourPanelMetrics.readableMin` → expanded but CAPPED to
///     the free space, with the panel's body scrolling inside the cap. This is
///     the step the old all-or-nothing rule was missing: a 6.3" phone leaves
///     242pt above the ringed Today list — the title and three-and-a-bit lines
///     of copy — and the panel was rendering title-only there.
///  4. Same two tests on the other side. (A safety net rather than a reachable
///     branch: the "opposite the target" preference IS the roomier side —
///     midY < screen.midY ⟺ the space below the ring exceeds the space above —
///     so step 4 can only fire if that preference ever changes.)
///  5. Neither side can hold a readable panel → the roomier side, collapsed to
///     title + controls, floored at `collapsedMin` so the controls stay usable.
///     The single, physically unavoidable overlap. The floor is a floor on the
///     CAP, not a promise about the drawn height: the panel keeps its measured
///     chrome plus one title line whatever this says, and it hugs that, so the
///     frame it reports (the hit-test claim) is always the height it draws.
///
/// - Parameters:
///   - target: the spotlight target rect (nil = whisper scrim, panel bottom).
///   - screen: the full screen bounds. Callers must measure this IGNORING the
///     software keyboard (`.ignoresSafeArea(.keyboard)` / window bounds) — a
///     keyboard-shrunk frame would collapse the panel and unmount the very
///     field that summoned the keyboard (drop → re-expand → loop).
///   - panelHeight: the panel's NATURAL (unconstrained) height. TourPanel
///     measures it from its scroll CONTENT, which is laid out at its ideal
///     height, cap or no cap — the panel's RENDERED frame must never be fed
///     back here (it is this rule's own output) or the decision oscillates.
///     TourModel.reportPanelBodyHeight is the only writer.
///   - keyboard: the Ask input owns focus / the keyboard is up. The keyboard
///     owns the bottom of the screen, so the panel is FORCED to the top dock
///     and the collapse rule is suppressed — collapsing would unmount the
///     focused field and drop the keyboard (the HIGH-severity focus loop).
///   - margin: outer margin between panel and screen/ring edges.
///   - ringPad: spotlight padding + ring width around the target (8 + 6).
func tourPanelPlacement(target: CGRect?, screen: CGRect, panelHeight: CGFloat,
                        keyboard: Bool = false,
                        margin: CGFloat = 16, ringPad: CGFloat = 14) -> TourPanelPlacement {
    if keyboard {
        // KEYBOARD × TOP-HALF RING — the documented decision (round 3): the
        // keyboard owns the bottom, so the panel is forced to the TOP dock —
        // which can land on a ring whose target sits in the top half. The
        // PANEL WINS visually (typing is the user's current intent, and the
        // claim order already prefers the panel; on a cutoutInteractive step
        // the ring's cutout stays pass-through wherever the panel doesn't
        // cover it — tourClaims checks the panel frame first). But when the
        // ring AND the expanded panel both fit above a conservative keyboard
        // top (55% of screen height — below every iPhone keyboard layout),
        // nudge the panel to sit just below the ring so neither is covered.
        // Otherwise accept the overlap.
        var topOffset: CGFloat = 0
        if let target, target.width > 0, target.height > 0 {
            let ring = target.insetBy(dx: -ringPad, dy: -ringPad)
            let panelTop = screen.minY + margin
            let overlapsRing = ring.minY < panelTop + panelHeight && ring.maxY > panelTop
            let keyboardTop = screen.minY + screen.height * 0.55
            if overlapsRing, ring.maxY + margin + panelHeight + margin <= keyboardTop {
                topOffset = ring.maxY + margin - panelTop
            }
        }
        // Uncapped: the keyboard branch must never constrain the panel — the
        // Ask field lives in the body, and a cap that scrolled it out of view
        // (or a collapse that unmounted it) is the focus loop again.
        return TourPanelPlacement(dock: .top, collapsed: false, maxHeight: nil, topOffset: topOffset)
    }
    guard let target, target.width > 0, target.height > 0 else {
        return TourPanelPlacement(dock: .bottom, collapsed: false, maxHeight: nil)
    }
    let ring = target.insetBy(dx: -ringPad, dy: -ringPad)
    /// Free space outside the ring on one side, less the panel's own margins.
    /// Clamped at 0: a ring can run off either edge of the screen (the Today
    /// list is taller than the viewport), which makes the raw figure negative.
    func free(_ dock: TourPanelDock) -> CGFloat {
        let raw = dock == .bottom ? screen.maxY - ring.maxY : ring.minY - screen.minY
        return max(0, raw - margin * 2)
    }
    let preferred: TourPanelDock = target.midY < screen.midY ? .bottom : .top
    let other: TourPanelDock = preferred == .bottom ? .top : .bottom
    let preferredFree = free(preferred)
    let otherFree = free(other)
    for (dock, space) in [(preferred, preferredFree), (other, otherFree)] {
        // Fits whole → no cap at all (and so the panel keeps hugging its copy).
        if space >= panelHeight {
            return TourPanelPlacement(dock: dock, collapsed: false, maxHeight: nil)
        }
        // Fits a readable panel → expanded, capped, the body scrolls inside.
        if space >= TourPanelMetrics.readableMin {
            return TourPanelPlacement(dock: dock, collapsed: false, maxHeight: space)
        }
    }
    let dock = otherFree > preferredFree ? other : preferred
    return TourPanelPlacement(dock: dock, collapsed: true,
                              maxHeight: max(max(preferredFree, otherFree),
                                             TourPanelMetrics.collapsedMin))
}

// MARK: - cross-feature signals

extension Notification.Name {
    /// Posted just before the tour drives navigation for a step (or exits), so
    /// screens with LOCAL sheet state (Today/Tasks/Calendar/Collections present
    /// Settings & co. from @State, outside the router) can close them — the
    /// router's dismissAllPresentations can't reach those.
    static let unstuckTourWillNavigate = Notification.Name("unstuck-tour-will-navigate")
}
