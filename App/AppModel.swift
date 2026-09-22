// App-level state + composition root. Builds the offline store + sync
// coordinator from the injected SyncConfig (SUPABASE_HOST + ANON_KEY in
// Info.plist, sourced from Config.xcconfig / Secrets.xcconfig), starts
// the auth→hydrate→subscribe loop, and exposes signed-in state to the UI.

import OSLog
import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckShared
import UnstuckSync
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let router = AppRouter()
    /// Device-local user preferences (theme / focus / sound / accessibility),
    /// UserDefaults-backed. Single shared instance the whole app observes.
    let settings = SettingsState.loaded()
    /// The gateway's device-local PA prefs (ritual toggles + dismissed moment
    /// ids) — ONE observable instance so the Today card, the interview picker,
    /// Settings → "What Unstuck knows" and the `set_ritual` tool all see the
    /// same state. Wiped on sign-out (scrubDeviceLocalUserContent).
    let paPrefs = PAPrefs()
    private(set) var coordinator: SyncCoordinator?
    private(set) var db: AppDatabase?
    private(set) var taskRepo: TaskRepository?
    private(set) var liveStore: LiveSessionStore?
    /// The assistant's cross-device memory (`profile_facts`): save / forget /
    /// list facts over the live store + outbox write-through. Stateless, so
    /// it's built on access; nil until the store exists (before start()).
    var profileFacts: ProfileFactsService? {
        db.map { ProfileFactsService(db: $0, write: write) }
    }
    var signedIn = false
    var configured = true
    /// True once the FIRST `profile_facts` hydrate of this sign-in has
    /// completed — success, failure or offline alike. Surfaces that treat an
    /// empty local memory as "never met" (the interview, the gateway card)
    /// wait on this so a fresh install of an existing account isn't greeted
    /// as a stranger while the pull is still in flight. Reset on sign-out so
    /// the next account waits for its own hydrate; set immediately in the
    /// UITest boot (nothing to pull).
    private(set) var profileFactsHydrated = false
    /// Set when a password-RECOVERY link lands (the user tapped "Forgot
    /// password" → the email link). The recovery session authenticates them but
    /// RootView shows the set-new-password screen instead of the app until they
    /// pick a new password (a recovery session can change the password without
    /// the old one). Mirrors Android's pendingPasswordRecovery.
    var pendingPasswordRecovery = false
    /// One-shot: armed when an `auth-callback` deep link lands so the NEXT
    /// authenticated transition classifies the session. The PKCE recovery flow
    /// returns `?code=…` with NO `type=recovery` and the SDK emits only
    /// `.signedIn` (never `.passwordRecovery`), so the only reliable signal is
    /// the exchanged session's JWT `amr` claim — see `isRecoverySession`.
    /// Consumed ONLY by a `.signedIn` whose token differs from the one in hand
    /// when the probe was armed (`recoveryProbeArmedToken`) — i.e. the code
    /// exchange. The stored-session `.initialSession` every new subscription
    /// receives (and any refresh) must not spend it: with a session stored and
    /// the app killed, the reset link was classified against the OLD token and
    /// the set-new-password screen never appeared.
    private var pendingRecoveryProbe = false
    @ObservationIgnored private var recoveryProbeArmedToken: String?
    /// An `auth-callback` URL that arrived BEFORE `start()` built the
    /// coordinator (a cold launch off the reset / magic link): stashed here and
    /// replayed at the end of `start()` instead of being dropped.
    @ObservationIgnored private var pendingAuthCallbackURL: URL?
    /// Local-only WriteThrough used by the XCUITest demo boot (no coordinator).
    var uiTestWrite: WriteThrough?
    // Per-collection serial RPC queue. The optimistic local write happens
    // synchronously on the main actor; the server RPC dispatch is chained so two
    // rapid edits to the same shared collection can't reach the server out of
    // order (replaces Android's collectionMutex).
    private var collectionRPCChains: [String: Task<Void, Never>] = [:]
    /// The last area/tag rename or delete; the next one waits for it (see
    /// afterPreviousLabelCascade).
    @ObservationIgnored private var labelCascadeTail: Task<Void, Never>?

    /// Enqueue a shared-collection RPC, ordered after any pending RPC for the
    /// same collection.
    func enqueueCollectionRPC(_ collectionId: String, _ op: @escaping @Sendable () async -> Void) {
        let prev = collectionRPCChains[collectionId]
        collectionRPCChains[collectionId] = Task { await prev?.value; await op() }
    }
    // Local first-run flag; struggles also sync to user_preferences. The gate
    // is ACCOUNT-wide: on sign-in it is reconciled from the server (a non-empty
    // `adhd_struggles` or a set interview flag ⇒ onboarded elsewhere ⇒ pinned
    // here without re-running the steps) — see reconcileAccountOnboardingIfNeeded.
    var onboarded = UserDefaults.standard.bool(forKey: "unstuck.onboarded")
    /// True once the account's onboarding state is KNOWN for this sign-in:
    /// the local flag was set, or the server answered (or couldn't within the
    /// deadline — then the local flag decides). RootView can gate on this to
    /// avoid a flash of OnboardingView for an existing account on a fresh
    /// install while the read is in flight.
    private(set) var onboardingResolved = UserDefaults.standard.bool(forKey: "unstuck.onboarded")
    /// Per-sign-in guard for the account-onboarding reconcile (set once the
    /// server ANSWERED; a transport failure leaves it unset so the next
    /// hydrate hook retries).
    @ObservationIgnored private var onboardingReconciledFor: String?
    /// Per-sign-in guard for the server-preferences pull (level / lead /
    /// rituals). Same retry semantics.
    @ObservationIgnored private var serverPrefsPulledFor: String?
    /// Guard for the timezone push — keyed on user + zone, so a re-sign-in
    /// no-ops but a device that has MOVED pushes the new zone once.
    @ObservationIgnored private var timezonePushedFor: String?
    /// Live as long as the model; the app has one AppModel for its lifetime.
    @ObservationIgnored private var timezoneObserver: NSObjectProtocol?
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?
    /// Generation counters so a push that succeeds can only clear the
    /// pending-push flag its own change set.
    @ObservationIgnored private var notifPrefsPushGen = 0
    @ObservationIgnored private var ritualsPushGen = 0
    /// The opt-in proactive calls (morning plan / evening wrap-up / check-in
    /// after a block) — `notification_preferences.call_*` (migration 072).
    /// Observed by Settings › Calls; the device cache is CallSettings.proactive,
    /// re-pushed on the next hydrate while `pendingProactivePush` is set.
    var callProactivePrefs: CallProactivePrefs = CallSettings.proactive
    @ObservationIgnored var callPrefsPushGen = 0
    /// In-memory backing for the archived-capture id set the Inbox triage tray
    /// reads (`archivedCaptureIds` in AppModel+Captures keeps a UserDefaults
    /// cache of it). Stored here because @Observable extensions can't add
    /// stored properties. The set is a CACHE of the local `capture_archive`
    /// table (server `captures.archived_at`, migration 053): the store →
    /// set direction runs through `startCaptureArchiveObservation`; the
    /// UI → store direction (archive / restore taps insert or remove an id)
    /// runs through this observer, which writes the diff through the
    /// repository + outbox so the archive reaches the server.
    var archivedCaptureIdsBacking: Set<String> = [] {
        didSet { propagateCaptureArchiveChange(from: oldValue, to: archivedCaptureIdsBacking) }
    }
    /// Set while the set is being updated FROM the store (observation, the
    /// sign-out scrub) so the observer above doesn't echo it back as writes.
    @ObservationIgnored private var captureArchiveWriteThroughSuppressed = false
    @ObservationIgnored private var captureArchiveObservation: Task<Void, Never>?

    /// Last finished focus session, backing the Today "Just now" recap card
    /// (Android RecapState parity). In-memory only — set by finishFocus,
    /// shown for 6 hours, ✕ on the card clears it.
    struct RecapState {
        let taskName: String
        let focusedSec: Int
        /// Epoch ms of the session end.
        let at: Double
        /// Set when a PARTNER ended the shared session remotely — the recap
        /// shows "<name> ended the session" (one true shared session).
        var endedBy: String? = nil
    }
    var lastRecap: RecapState?

    /// Google calendar health from the last pull (SyncCoordinator): which
    /// connections need a fresh consent, the last server-side reason, and any
    /// 429 back-off. `calendarNeedsReauth` (AppModel+CalendarControls) is the
    /// UI's "Reconnect Google" gate.
    var calendarSyncStatus: SyncCoordinator.CalendarSyncStatus?

    /// A shared-list edit the server REFUSED (RLS / a revoked share / a bad
    /// RPC): the optimistic row was rolled back to the server's copy and this
    /// says so — the Lists surface shows it once, then clears it.
    var collectionSyncError: String?

    // MARK: - one true shared session (partner co-focus v2)
    // Stored state for AppModel+SharedSession (extensions can't add storage).

    /// The session-lifetime co-focus channel for the LIVE partner-shared
    /// session. Owned HERE — not by the focus screen — so remote pause/resume/
    /// extend/end arrive while the user is on Today or the screen is closed.
    /// Lifecycle + broadcasts run through `syncSharedSessionChannel()` (the
    /// refreshLiveSession choke point). Observable: FocusView feeds its
    /// CoFocusBar from this model's peers.
    var liveCoFocus: CoFocusModel?
    /// The task id `liveCoFocus` is bound to (the channel topic key).
    @ObservationIgnored var liveCoFocusTaskId: String?
    /// The last shared-session state this device broadcast, ADOPTED, or applied
    /// from a remote control — the change/echo detector for the choke-point
    /// broadcast and the `atMs` base for LWW ties. In-memory only (the rev also
    /// persists on the live session, so a relaunch keeps the chain monotonic).
    @ObservationIgnored var lastSharedBroadcast: SharedSessionState?
    /// Bumped after every APPLIED remote control so an open FocusView re-syncs
    /// its FocusModel from the store (remote pause/resume/extend) or leaves
    /// (remote end).
    var sharedSessionRemoteTick = 0
    /// Calm attribution line for the focus screen ("Ann paused" / "Ann
    /// resumed") — never a modal. Sticky for a remote pause; transient (a few
    /// seconds) for resume/extend. Cleared on any local control.
    var sharedSessionAttribution: String?
    @ObservationIgnored var sharedAttributionClearTask: Task<Void, Never>?
    /// A just-probed ADOPTED session state, consumed by the choke point when
    /// the adopted live session lands in the store — it becomes the broadcast
    /// baseline (no rev bump: adopting is not a control).
    @ObservationIgnored var pendingAdoptionSeed: SharedSessionState?
    /// The HEAD of the app-wide co-focus op chain: every channel start / stop /
    /// endSession / adoption probe enqueues behind the current head and
    /// registers itself as the new head (chainCoFocusOp) — a strict FIFO, so a
    /// stop() can never race a start() on the same (topic-deduped) channel.
    /// Read + re-registered at ENQUEUE time on the main actor, never captured
    /// stale (supabase-swift dedupes channels by topic; removeChannel
    /// unconditionally unsubscribes whichever instance holds the topic).
    @ObservationIgnored var coFocusTeardown: Task<Void, Never>?
    /// The in-flight pending-shared-focus-ledger drain (nil when idle) — a
    /// foreground + relaunch retry loop for accruals that couldn't reach the
    /// server (idempotent per sessionId, so re-fires are safe).
    @ObservationIgnored var sharedLedgerDrainTask: Task<Void, Never>?

    /// Register a channel-ADOPTED shared session with the share-session signal
    /// reducer as already-started: only the MINTER fires the session_start
    /// ping; joining an in-flight session announces nothing (its end, if ended
    /// HERE, still fires — that's this device acting).
    func markSessionSignalAdopted(sid: String) { shareSig.adoptedSid = sid }

    /// Overwrite the in-memory live-session cache after a DIRECT store write
    /// from the shared-session choke point (which runs INSIDE refreshLiveSession
    /// and so must not recurse into it). Same-file setter for the private(set).
    func setCachedLiveSession(_ live: LiveSession?) { cachedLiveSession = live }

    /// Drop the started-task marker so the imminent transition to idle fires
    /// NO session_end ping — a remote `ended` was applied and the ender's
    /// device already announced it.
    func suppressNextSessionEndSignal() { shareSig.startedTask = nil }

    /// Cached signed-in identity (display name + email), backing the top-bar
    /// avatar initials, Settings, DataExport and Assistant context. Seeded once
    /// on `start()` and refreshed from the `authStateChanges` session — NEVER
    /// re-read from `auth.currentSession` during a view body, because that
    /// accessor does a synchronous keychain read on every call and stalling the
    /// main thread there during a notification-tap state-restoration snapshot
    /// aborts with a UIKit CATransaction NSAssertion (TestFlight crash, T4).
    /// Observed, so seeding/refresh re-renders the avatar reactively.
    private(set) var cachedUserName: String?
    private(set) var cachedEmail: String?
    /// Cached user id + has-password, same rationale as cachedUserName: isShared/
    /// isOwner (per collection card) and Settings' hasPassword read these instead
    /// of `auth.currentSession` (a synchronous keychain read), so a notification
    /// deep-linking to Collections/Settings can't reproduce the T4 render-snapshot
    /// crash. Seeded on start(), refreshed from the authStateChanges session.
    private(set) var cachedUserId: String?
    private(set) var cachedHasPassword: Bool = true
    /// The live session's access token, cached from the SAME authStateChanges
    /// session as the identity above (and refreshed on every `.tokenRefreshed`).
    /// `voiceAccessToken` reads THIS rather than `auth.currentSession`: that
    /// accessor is a synchronous keychain read which can fail for reasons that
    /// have nothing to do with being signed in (an unsigned/dev build has no
    /// `application-identifier` → errSecMissingEntitlement −34018; a locked
    /// device; a storage-migration error) — and when it does, realtime voice
    /// dead-ends on "Please sign in to use voice." while the app is plainly
    /// signed in (2026-09-11 repro). Not persisted: a cold launch gets it from
    /// the `.initialSession` event.
    private(set) var cachedAccessToken: String?

    /// Overwrite the cached display name (used right after a successful name
    /// change so Settings/avatar reflect it before the auth `.userUpdated` event
    /// lands). Same file as the `private(set)` declaration so extensions can set it.
    func setCachedUserName(_ name: String) { cachedUserName = name }

    /// In-memory cache of the persisted live focus session. The Today
    /// LiveSessionCard ticks once per second while a session is live + Today is
    /// on screen; reading the GRDB-backed liveStore (a blocking read + fresh
    /// JSONDecoder) on every tick was wasteful. Every mutator that writes the
    /// store (start/pause/resume/end/cancel) calls `refreshLiveSession()` to keep
    /// this current; the 1s tick recomputes elapsed/progress from this cached
    /// value with no per-tick disk read. Seeded once on launch (reapStaleLiveActivities).
    private(set) var cachedLiveSession: LiveSession?

    /// Re-read the persisted live session into the in-memory cache. Called by
    /// every mutator that touches `liveStore` so the cache never goes stale.
    /// This is also the single choke point every focus transition (start / pause
    /// / resume / finish / cancel) flows through, so it drives the share-session
    /// signal reducer — a start/finish on a shared task pings its recipients —
    /// AND the one-true-shared-session channel: partner co-focus sessions
    /// broadcast every local control (rev+1 full-state snapshot) from here,
    /// and finished ones broadcast `ended` before teardown.
    func refreshLiveSession() {
        cachedLiveSession = (try? liveStore?.get()) ?? nil
        pumpShareSessionSignals()
        syncSharedSessionChannel()
    }

    /// Backing for the lazily-built assistant. Observation-ignored: AppModel
    /// holds the reference but never needs to observe the swap (AssistantModel
    /// is itself @Observable and drives the chat UI). A lazy stored var conflicts
    /// with the @Observable macro's init accessor, so it's built on first access.
    @ObservationIgnored private(set) var _assistant: AssistantModel?

    /// The in-app agent (text chat + client-side tool execution). Built on first
    /// panel open so the persisted thread load + the client are only touched
    /// when the user actually uses it.
    var assistant: AssistantModel {
        if let a = _assistant { return a }
        let a = AssistantModel(model: self, client: coordinator?.assistant)
        _assistant = a
        return a
    }

    /// The AI kill-switch (Settings → Interface → "AI Assistant"). OFF removes
    /// the launcher, the panel and voice entirely — the promise the published
    /// privacy policy makes. Device-local, never synced.
    var assistantEnabled: Bool { settings.assistantEnabled }

    /// The ONE way to open the Assistant panel (launcher, Siri deep link, the
    /// guided tour, Today's input pill). No-ops while the kill-switch is off,
    /// so a stale deep link or tour step can never resurrect a disabled
    /// assistant. `focusComposer` puts the keyboard in the sheet's composer
    /// on open; `draft` pre-fills it (text typed elsewhere carries over).
    func openAssistant(draft: String? = nil, focusComposer: Bool = false) {
        guard assistantEnabled else { return }
        if focusComposer || !(draft ?? "").isEmpty {
            assistant.requestComposer(draft: draft, focus: focusComposer)
        }
        router.showAssistant = true
    }

    /// Backing for the lazily-built guided-tour orchestrator. Observation-
    /// ignored for the same reason as `_assistant`: TourModel is itself
    /// @Observable and drives the tour UI.
    @ObservationIgnored private(set) var _tour: TourModel?

    /// The guided product tour (welcome/running/paused phase machine + the
    /// spotlight/panel state). Built on first access from the tour overlay.
    var tour: TourModel {
        if let t = _tour { return t }
        let t = TourModel(app: self)
        _tour = t
        return t
    }

    /// Backing for the app-wide per-task sharing state (tasks shared WITH me +
    /// my outgoing badges / delegation map). Single shared instance so Today,
    /// Tasks, the share sheet, and the Start-Next picker all read one source of
    /// truth; it refetches on the live `unstuckCollabSharesChanged` signal.
    @ObservationIgnored private(set) var _shareState: ShareModel?

    /// Live per-task sharing state (the iOS analogue of the web `useSharedWithMe`
    /// + `useShareBadges` hooks). Built lazily on first access, bound to the
    /// shared CircleClient (nil client on the demo/UITest boot → empty + inert).
    var shareState: ShareModel {
        if let s = _shareState { return s }
        let s = ShareModel(client: coordinator?.circle)
        // Re-run the share-session signal reducer whenever the outgoing badges
        // refresh, so a session_start that was waiting on late-resolving badges
        // (RPC still in flight when the session began) fires once they land.
        // Same for the shared-session channel: a partner badge resolving after
        // the session began makes it a co-focus candidate now.
        s.onChange = { [weak self] in
            self?.pumpShareSessionSignals()
            self?.syncSharedSessionChannel()
        }
        _shareState = s
        return s
    }

    /// Prior state of the pure share-session signal reducer (UnstuckCore
    /// `sessionSignalStep`). Driven off the live focus session + outgoing badges.
    @ObservationIgnored private var shareSig = initSigState()

    /// Feed the current (session id, shared taskId) into the pure reducer and
    /// fire any session_start / session_end pings it returns. Called on every
    /// live-session transition (via refreshLiveSession) AND on every badge
    /// refresh (via ShareModel.onChange). Reads `_shareState` (never builds it)
    /// so an idle/signed-out app never announces anything. Mirrors the web
    /// useShareSessionSignals effect.
    func pumpShareSessionSignals() {
        let live = cachedLiveSession
        let active = live?.sessionStart != nil
        let sid: String? = active ? (live?.id ?? live?.taskId) : nil
        let taskId: String? = active ? live?.taskId : nil
        let badges = _shareState?.badges ?? [:]
        // shared == the taskId iff it has ≥1 outgoing share (any level) — the
        // whole point of the start/finish heads-up ("quiet company").
        let shared: String? = {
            guard let taskId, !(badges[taskId]?.isEmpty ?? true) else { return nil }
            return taskId
        }()
        let (state, fires) = sessionSignalStep(shareSig, sid: sid, shared: shared)
        shareSig = state
        guard !fires.isEmpty, let share = _shareState else { return }
        for f in fires {
            let kind = f.kind.rawValue
            let tid = f.taskId
            Task { await share.notifySession(kind: kind, taskId: tid) }
        }
    }

    /// Finish onboarding. Mirrors the Android completeOnboarding: seed the
    /// user's PICKED life areas (or canonical defaults) — but only when they
    /// have none yet, so an existing account whose areas already hydrated isn't
    /// double-seeded — sync the ADHD-struggle selections, optionally create the
    /// first task (+ its smallest first action), and adopt the chosen default
    /// focus treatment.
    func completeOnboarding(struggles: [String], areas: [String] = [],
                            firstTask: String = "", firstAction: String = "",
                            treatment: FocusTreatment? = nil) {
        // Store the CANONICAL keys (the struggle engine + moments key on them)
        // whatever labels the picker showed — see canonicalStruggles.
        let struggles = Self.canonicalStruggles(struggles)
        UserDefaults.standard.set(struggles, forKey: "unstuck.adhdStruggles")
        UserDefaults.standard.set(true, forKey: "unstuck.onboarded")
        onboarded = true
        onboardingResolved = true

        // Arm the ONE-TIME guided-tour auto-welcome for accounts that finish
        // onboarding after the tour shipped (it surfaces on the next Today
        // appearance). Existing accounts only ever reach the tour via
        // Settings → Account → Product tour.
        TourStore().save { $0.eligible = true }

        // Seed life areas (single source — only when empty).
        if let write = coordinator?.write, ((try? db?.fetchAllLifeAreas())?.isEmpty ?? true) {
            let palette = ["indigo", "coral", "green", "amber", "teal", "blue", "violet", "red"]
            let seed = areas.isEmpty ? ["Work", "Personal", "Home", "Health"] : areas
            let now = Self.isoNow()
            Task {
                for (i, name) in seed.enumerated() {
                    try? await write.upsertLifeArea(
                        LifeArea(id: newUUID(), name: name, color: palette[i % palette.count], sortOrder: i),
                        nowISO: now)
                }
            }
        }

        // Create the first task in ONE write (no mutate-then-resave race):
        // filed under the first picked area, estimate 15 ("Small is good"),
        // with its first physical action — 1:1 with Android.
        let taskName = firstTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !taskName.isEmpty {
            let action = firstAction.trimmingCharacters(in: .whitespacesAndNewlines)
            addTask(name: taskName, estimateMin: 15,
                    lifeArea: areas.first,
                    firstPhysicalAction: action.isEmpty ? nil : action)
        }

        // Adopt the chosen default focus treatment.
        if let treatment { settings.defaultTreatment = treatment }

        if let coord = coordinator, let uid = coord.auth.currentUserId, !struggles.isEmpty {
            Task { try? await coord.preferences.setAdhdStruggles(userId: uid, struggles: struggles) }
        }
    }

    /// The struggle vocabulary the ported engine keys on (`struggleProfile`,
    /// `pickMoment`): the web's onboarding keys. The iOS/Android pickers
    /// stored their own labels ("Getting started", "Switching tasks", …), so
    /// the engine never matched and every struggle line fell to the generic
    /// fallback. Maps legacy labels → canonical keys, passes canonical keys
    /// through (case-insensitively), drops unknowns, dedupes, keeps order.
    nonisolated static func canonicalStruggles(_ raw: [String]) -> [String] {
        let canonical = ["Starting", "Sustaining", "Switching", "Stopping", "Recovering"]
        let legacy: [String: String] = [
            "getting started": "Starting",
            "switching tasks": "Switching",
            "distraction": "Sustaining",     // web: "I drift after a few minutes"
            "time blindness": "Stopping",    // web: "hyperfocus runs me into the ground"
            "overwhelm": "Starting",         // web: "tasks feel impossible to begin"
        ]
        var out: [String] = []
        for s in raw {
            let key = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mapped = canonical.first(where: { $0.lowercased() == key }) ?? legacy[key] else { continue }
            if !out.contains(mapped) { out.append(mapped) }
        }
        return out
    }

    /// The canonical struggles for THIS device's account (what the engine +
    /// the assistant context read).
    var canonicalStruggles: [String] {
        Self.canonicalStruggles(UserDefaults.standard.stringArray(forKey: "unstuck.adhdStruggles") ?? [])
    }

    /// Once per sign-in, reconcile the device with the ACCOUNT:
    ///  • a fresh install of an existing account has no local struggles while
    ///    the server row does — pull `user_preferences.adhd_struggles`
    ///    (canonicalised on the way in);
    ///  • the 5-step onboarding gate is account-wide — a non-empty server
    ///    struggles list means the account onboarded on another device, so
    ///    the local flag is pinned instead of re-onboarding (which re-armed
    ///    the one-time tour and overwrote the server's picks). The interview
    ///    flag (`applyServerInterviewFlag`) pins it the same way.
    /// Runs from the auth transition (early, so RootView's gate resolves
    /// before the full hydrate) AND the profile-facts hydrate hook (retry). A
    /// transport failure / deadline leaves the guard unset for the retry and
    /// lets the LOCAL flag decide meanwhile — "unknown" never flips the gate.
    private func reconcileAccountOnboardingIfNeeded() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId, onboardingReconciledFor != uid else { return }
        if onboarded && !canonicalStruggles.isEmpty {
            onboardingReconciledFor = uid
            onboardingResolved = true
            return
        }
        let prefs = coord.preferences
        Task { [weak self] in
            let raw: [String]? = try? await withDeadline(seconds: 6) { try await prefs.adhdStruggles(userId: uid) }
            guard let self, coord.auth.currentUserId == uid else { return }
            guard let raw else {
                self.onboardingResolved = true   // unknown → the local flag decides; retried next hydrate
                return
            }
            self.onboardingReconciledFor = uid
            let mapped = Self.canonicalStruggles(raw)
            if !mapped.isEmpty {
                if self.canonicalStruggles.isEmpty { UserDefaults.standard.set(mapped, forKey: "unstuck.adhdStruggles") }
                self.markOnboardedFromServer()
            }
            self.onboardingResolved = true
        }
    }

    /// The account already onboarded elsewhere: pin the local gate WITHOUT
    /// re-arming the one-time tour (that's for accounts finishing the steps
    /// on this device) and without touching the server's struggles.
    func markOnboardedFromServer() {
        onboardingResolved = true
        guard !onboarded else { return }
        UserDefaults.standard.set(true, forKey: "unstuck.onboarded")
        onboarded = true
    }

    /// Once per sign-in (hydrate hook): the account-wide preferences the
    /// phone used to write-only or keep device-local — the notification level
    /// + reminder lead (`notification_preferences`) and the PA ritual toggles
    /// (`user_preferences.pa_rituals`, migration 053). The server is the
    /// source of truth: a non-null server value replaces the local cache. The
    /// one exception is a change made HERE whose push failed (flagged
    /// pending) — that is re-pushed instead, so an offline toggle isn't
    /// silently reverted. A transport failure leaves the guard unset so the
    /// next hydrate retries. Moment dismissals are device-local by design.
    /// Once per (account, zone): record the device's IANA timezone on the
    /// account (`set_timezone`, migration 053). The server's reminders, morning
    /// brief and the owner-local slot shared tasks are bucketed by all read
    /// `notification_preferences.timezone`; without this an account that only
    /// ever signs in on the phone stays on the UTC fallback. A transport
    /// failure leaves the guard unset so the next hydrate retries; a rejected
    /// zone is remembered (retrying can't help).
    private func pushTimezoneIfNeeded() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let tz = TimeZone.current.identifier
        let stamp = "\(uid)|\(tz)"
        guard timezonePushedFor != stamp else { return }
        let prefs = coord.preferences
        Task { [weak self] in
            guard (try? await prefs.setTimezone(tz)) != nil else { return }
            guard let self, coord.auth.currentUserId == uid else { return }
            self.timezonePushedFor = stamp
        }
    }

    /// Re-read every account-wide preference the device caches, ignoring the
    /// once-per-sign-in guards. Driven by the freshness owner (gap triggers,
    /// throttled) and by a `notification_preferences` / `user_preferences`
    /// realtime event. This is what makes a notification level, reminder lead,
    /// timezone, ritual toggle, struggles list or assistant-interview flag
    /// changed on another device show up here WITHOUT a relaunch.
    func refreshServerPreferences() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        serverPrefsPulledFor = nil
        interviewFlagPulledFor = nil
        // The onboarding reconcile is idempotent and only ever PINS the local
        // gate, so re-running it is safe; clearing its guard lets a struggles
        // list picked on another device land here too.
        if onboardingReconciledFor == uid { onboardingReconciledFor = nil }
        pullServerPreferencesIfNeeded()
        reconcileAccountOnboardingIfNeeded()
        pushTimezoneIfNeeded()
        Task { await self.applyServerInterviewFlag() }
    }

    private func pullServerPreferencesIfNeeded() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId, serverPrefsPulledFor != uid else { return }
        let prefs = coord.preferences
        let paPrefs = self.paPrefs
        Task { [weak self] in
            var complete = true
            // Notification level + lead.
            if NotificationPrefs.pendingServerPush {
                let level = NotificationPrefs.level, lead = NotificationPrefs.reminderLeadMin
                do {
                    try await prefs.setNotificationLevel(userId: uid, morningBrief: level.morningBrief,
                                                         pausedCheckin: level.pausedCheckin, level: level.rawValue)
                    try await prefs.setReminderLead(userId: uid, minutes: lead)
                    guard coord.auth.currentUserId == uid else { return }
                    NotificationPrefs.pendingServerPush = false
                } catch { complete = false }
            } else {
                do {
                    let row = try await prefs.notificationPrefs(userId: uid)
                    guard let self, coord.auth.currentUserId == uid else { return }
                    self.applyServerNotificationPrefs(row)
                } catch { complete = false }
            }
            // Proactive calls (server-backed toggles; the phone caches them).
            if CallSettings.pendingProactivePush {
                do {
                    try await prefs.setCallProactivePrefs(userId: uid, prefs: CallSettings.proactive)
                    guard coord.auth.currentUserId == uid else { return }
                    CallSettings.pendingProactivePush = false
                } catch { complete = false }
            } else {
                do {
                    let server = try await prefs.callProactivePrefs(userId: uid)
                    guard let self, coord.auth.currentUserId == uid else { return }
                    if let server { self.applyServerCallProactivePrefs(server) }
                } catch { complete = false }
            }
            // PA rituals.
            if paPrefs.isPendingPush {
                do {
                    try await prefs.setPaRituals(userId: uid, prefs: paPrefs.rituals)
                    guard coord.auth.currentUserId == uid else { return }
                    paPrefs.setPendingPush(false)
                } catch { complete = false }
            } else {
                do {
                    let server = try await prefs.paRituals(userId: uid)
                    guard coord.auth.currentUserId == uid else { return }
                    if let server { paPrefs.applyServerRituals(server) }
                } catch { complete = false }
            }
            guard let self, coord.auth.currentUserId == uid else { return }
            if complete { self.serverPrefsPulledFor = uid }
        }
    }

    /// A ritual toggle made here → `user_preferences.pa_rituals`. Flagged
    /// pending until the write lands, so an offline toggle survives the next
    /// hydrate (re-pushed rather than pulled over).
    private func pushRituals(_ rituals: RitualPrefs) {
        paPrefs.setPendingPush(true)
        ritualsPushGen += 1
        let gen = ritualsPushGen
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        Task { [weak self] in
            do {
                try await coord.preferences.setPaRituals(userId: uid, prefs: rituals)
                guard let self, coord.auth.currentUserId == uid, self.ritualsPushGen == gen else { return }
                self.paPrefs.setPendingPush(false)
            } catch {}
        }
    }

    // MARK: - interview flag (cross-device, migration 052)

    /// The user whose `assistant_interview_done_at` has been reconciled this
    /// sign-in. Nil until a read SUCCEEDS — offline / timed out / the column
    /// not deployed yet all leave it unset so the next hydrate retries. Reset
    /// on sign-out (scrubDeviceLocalUserContent).
    @ObservationIgnored private var interviewFlagPulledFor: String?

    /// Reconcile the device's interview flag with the ACCOUNT's
    /// (`user_preferences.assistant_interview_done_at`): server done ⇒ pin the
    /// local flag, so the gateway's gate never auto-opens for someone who
    /// finished on the web (prod tester, 2026-09-05); local done but server
    /// not ⇒ push it up (a finish made offline, or before migration 052
    /// existed). Once per sign-in, bounded so an unreachable server can't
    /// stall the "hydrated" flip — the gate then falls back to the fact
    /// count, as before. Best-effort: never throws, never touches the local
    /// flag on an unknown answer.
    private func applyServerInterviewFlag() async {
        guard let coord = coordinator, let uid = coord.auth.currentUserId, interviewFlagPulledFor != uid else { return }
        let prefs = coord.preferences
        do {
            let doneAt = try await withDeadline(seconds: 6) { try await prefs.interviewDoneAt(userId: uid) }
            guard coord.auth.currentUserId == uid else { return }   // account changed mid-flight
            interviewFlagPulledFor = uid
            if doneAt != nil {
                InterviewMachine.markDone()
                // An account that finished the interview onboarded somewhere.
                markOnboardedFromServer()
            } else if InterviewMachine.isDone() {
                Task { try? await prefs.setInterviewDone(userId: uid) }
            }
        } catch {
            // Offline, timed out, or the column isn't there yet (42703):
            // unknown ≠ "not done" — leave the local flag alone, retry next hydrate.
        }
    }

    /// The interview finished on THIS device (any finisher, reaching the
    /// picker, or the ≥1-fact auto-done): mirror it to the account so no other
    /// device re-asks. The local flag is the machine's job; this is the
    /// best-effort push (a failure is re-pushed by the next sign-in hydrate).
    func pushInterviewDone() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        Task { try? await coord.preferences.setInterviewDone(userId: uid) }
    }

    // MARK: - voice (realtime "Talk" mode config)

    /// The CF Worker proxy URL. Info.plist carries the HOST
    /// (VOICE_PROXY_HOST ← Config.xcconfig) because an xcconfig value is cut at
    /// "//"; the scheme is added here. A full wss:// URL from an older
    /// Secrets.xcconfig still works. Blank → voice unconfigured.
    var voiceProxyURL: String {
        let info = Bundle.main.infoDictionary
        // Secrets.xcconfig (untracked) still wins when it sets a full URL; the
        // committed host is the floor so voice can never ship unconfigured.
        let secret = (info?["VOICE_PROXY_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = (info?["VOICE_PROXY_HOST"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = secret.isEmpty ? host : secret
        if raw.isEmpty { return "" }
        return raw.contains("://") ? raw : "wss://\(raw)"
    }
    /// Gate the Talk button: a non-blank proxy URL (matches Android — no token
    /// check, so Talk stays visible during token-refresh / cold-start) AND the
    /// AI kill-switch — "off" means no voice either, which is what the privacy
    /// policy promises.
    var voiceConfigured: Bool { !voiceProxyURL.isEmpty && assistantEnabled }
    /// The realtime model id (DashScope Qwen-Omni).
    var voiceModel: String { "qwen3.5-omni-flash-realtime" }
    /// The Supabase access token the proxy validates.
    /// Prefer the token cached from the auth stream (see `cachedAccessToken`);
    /// fall back to the stored session only when the cache is cold (e.g. a
    /// caller that runs before the first authStateChanges event lands).
    var voiceAccessToken: String? {
        if let t = cachedAccessToken, !t.isEmpty { return t }
        return coordinator?.auth.accessToken
    }

    func sendSessionRecap(taskName: String, away: Bool = false) {
        guard let n = coordinator?.notifications else { return }
        Task { try? await n.sessionRecap(taskName: taskName, away: away) }
    }

    // The paused check-in's cap coordination lives in AppModel+FocusControls
    // (armPausedCheckin / cancelPausedCheckin / peek / consume): the budget is
    // claimed when the nag FIRES, not when the session is paused.

    // MARK: - wake-window calibration (server `wake_window_history`)

    /// Record the day's FIRST foreground as this account's wake signal — one
    /// row per local day (`calibrate_wake_windows` medians them into the
    /// morning-brief window). Idempotent per (user, day): the sample of the
    /// first foreground is stashed so a failed write retries with the SAME
    /// time later in the day, never a later one. Called on every foreground
    /// sync + launch.
    func recordWakeWindowIfNeeded(now: Date = Date()) {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let d = UserDefaults.standard
        let doneKey = "unstuck.wakeWindow.lastDate.\(uid)"
        let pendingKey = "unstuck.wakeWindow.pending.\(uid)"
        let pending = d.dictionary(forKey: pendingKey).flatMap { dict -> WakeWindowSample? in
            guard let date = dict["date"] as? String, let time = dict["time"] as? String,
                  let wd = dict["weekday"] as? Int else { return nil }
            return WakeWindowSample(localDate: date, firstInputLocal: time, weekday: wd)
        }
        guard let sample = Self.wakeWindowSampleToSend(
            lastRecordedDate: d.string(forKey: doneKey), pending: pending, now: WakeWindowSample(now: now))
        else { return }
        d.set(["date": sample.localDate, "time": sample.firstInputLocal, "weekday": sample.weekday], forKey: pendingKey)
        Task {
            do {
                try await coord.notifications.recordWakeWindow(userId: uid, sample: sample)
                d.set(sample.localDate, forKey: doneKey)
                d.removeObject(forKey: pendingKey)
            } catch {}   // offline: the stashed first-input sample is retried on the next foreground
        }
    }

    /// Pure: which sample (if any) to send. Nothing once today is recorded;
    /// else today's stashed first-input sample when one exists (a retry must
    /// not report a LATER time as the day's first input); else `now`.
    nonisolated static func wakeWindowSampleToSend(lastRecordedDate: String?, pending: WakeWindowSample?,
                                                   now: WakeWindowSample) -> WakeWindowSample? {
        if lastRecordedDate == now.localDate { return nil }
        if let pending, pending.localDate == now.localDate { return pending }
        return now
    }

    #if DEBUG
    /// Boot straight into the signed-in app with seeded local data and no
    /// network — for XCUITest. Triggered by the UITEST_SEED launch env var.
    func startUITestMode() {
        guard coordinator == nil, db == nil else { return }
        // TEMPORARY perf scaffolding (UITEST_SEED_HEAVY): a heavy account on a
        // PERSISTENT sqlite file, so relaunch #2+ is a true cold start against
        // a large store. DEBUG-only + env-gated; the normal demo boot below is
        // untouched (in-memory + the small DemoSeed).
        let heavy = HeavyDemoSeed.enabled
        guard let database = heavy
                ? (try? AppDatabase.make(path: HeavyDemoSeed.dbPath()))
                : (try? AppDatabase.makeInMemory()) else { return }
        db = database
        taskRepo = TaskRepository(database)
        liveStore = LiveSessionStore(database)
        refreshLiveSession()
        uiTestWrite = WriteThrough(db: database)
        if heavy { HeavyDemoSeed.seedIfNeeded(database) } else { DemoSeed.seed(database) }
        // The demo persona has a NAME. Without one the greeting falls back to
        // "Good evening Unstuck." — correct behaviour, but it reads as a bug in
        // a marketing screenshot. "Maya" is the persona the web seed already
        // uses (scripts/seed-demo-account.mjs sets full_name/display_name), so
        // the three platforms show the same person. Not "Sarah": the seed has a
        // "Reply to Sarah" task, and a user replying to herself reads wrong.
        setCachedUserName("Maya")
        startCaptureArchiveObservation(database)
        configured = true
        signedIn = true
        profileFactsHydrated = true   // nothing to pull — the seed IS the memory
        onboarded = true
        onboardingResolved = true
        UserDefaults.standard.set(true, forKey: "unstuck.onboarded")
        // Tour UITest hook: reset the tour to a fresh 'eligible' state so the
        // one-time welcome fires deterministically on this boot. Every OTHER
        // UITest boot clears it instead: the seed is an in-memory database but
        // the tour's state lives in UserDefaults and outlives it, so a tour
        // test that ended mid-run left a "Continue your tour?" card sitting
        // over the first screen of every later test on that simulator.
        if ProcessInfo.processInfo.environment["UITEST_TOUR"] == "1" {
            TourStore().save { $0 = TourState(eligible: true) }
        } else {
            TourStore.clear()
        }
        // Debug hook: jump straight into Focus on launch (crash isolation).
        if ProcessInfo.processInfo.environment["UITEST_FOCUS"] == "1",
           let t = (try? taskRepo?.fetch(id: "t-proposal")) ?? nil {
            router.beginFocus(t)
        }
        // Debug hook: replay the tester-reported BULK calendar turn through the
        // real assistant (scripted transport, no network) — crash isolation.
        // Debug hook: a canned one-line reply (no network, no LLM) so a UI walk
        // can send a message and reach the interview-in-thread prompts.
        if ProcessInfo.processInfo.environment["UITEST_ASSISTANT_CANNED"] == "1" {
            AssistantModel.scrubPersisted()
            assistant.transportOverride = CannedAssistantScript()
        }
        if ProcessInfo.processInfo.environment["UITEST_ASSISTANT_BULK"] == "1" {
            AssistantModel.scrubPersisted()
            assistant.transportOverride = BulkAssistantScript()
            // A bulk calendar turn also drives the reactive reminder re-sync
            // (50 new blocks → up to 150 UNNotificationRequests). start() is
            // what normally arms it; arm it for the repro boot too.
            startNotifications()
        }
    }
    #endif

    func start() async {
        guard coordinator == nil else { return }
        guard let config = Self.loadConfig() else {
            configured = false
            return
        }
        guard let database = try? AppDatabase.make(path: Self.databasePath()) else { return }
        db = database
        taskRepo = TaskRepository(database)
        liveStore = LiveSessionStore(database)
        loadArchivedCaptureIds()   // restore the Inbox archived view across relaunch
        let provider = SupabaseClientProvider(config)
        let coord = SyncCoordinator(provider: provider, db: database)
        coordinator = coord
        signedIn = coord.auth.currentUserId != nil
        // Seed the cached identity once at cold launch (one keychain read here,
        // off the render/snapshot path). Thereafter it's refreshed from the
        // authStateChanges session — see cachedUserName's note.
        cachedUserName = coord.auth.currentUserName
        cachedEmail = coord.auth.currentEmail
        cachedUserId = coord.auth.currentUserId
        cachedHasPassword = coord.auth.hasPassword
        // "Profile facts hydrated once" — BEFORE start(), so the sign-in
        // hydrate the auth observer kicks off is the first one observed.
        await coord.setOnProfileFactsHydrated { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The account's interview flag lands BEFORE "hydrated" flips:
                // the gateway's auto-open gate decides on that flip, and an
                // already-onboarded user (done on the web, few synced facts)
                // must never be greeted as a stranger.
                await self.applyServerInterviewFlag()
                self.profileFactsHydrated = true
                self.reconcileAccountOnboardingIfNeeded()
                self.pullServerPreferencesIfNeeded()
                self.pushTimezoneIfNeeded()
                // Repeating tasks whose 8-week horizon has run out since the
                // last edit (topUpRecurrenceHorizon). After the hydrate, so it
                // sees the account's real blocks rather than an empty store.
                self.topUpRecurrenceHorizon()
                // Hands-free ops whose target wasn't in the local store before
                // this hydrate (a widget "Done" on a task pulled just now) are
                // retried the moment the store is faithful, then flushed.
                if self.drainSiriWriteQueue() {
                    self.refreshWidgetSnapshot()
                    self.syncNow()
                }
            }
        }
        // Google calendar health → UI ("Reconnect Google" when a refresh token
        // died; quiet while backing off a 429).
        await coord.setOnCalendarStatus { [weak self] status in
            Task { @MainActor in self?.calendarSyncStatus = status }
        }
        // A shared-list RPC the server refused (dropped by the outbox): roll
        // the optimistic row back to the server's copy + say so once.
        await coord.setOnCollectionRPCRejected { [weak self] collectionId, fn, error in
            Task { @MainActor in self?.handleCollectionRPCRejected(collectionId: collectionId, fn: fn, error: error) }
        }
        // Ritual toggles are account-wide (migration 053) — push every change.
        paPrefs.onRitualsChanged = { [weak self] rituals in self?.pushRituals(rituals) }
        // The pre-053 device-local archive set becomes server state ONCE, then
        // the Inbox's set follows the local archive table (hydrate / realtime /
        // our own writes / the sign-out wipe).
        await migrateLegacyCaptureArchiveIfNeeded()
        startCaptureArchiveObservation(database)
        // Account-wide preference rows live outside the local store, so the
        // cursor catch-up can't carry them: the freshness owner calls this on
        // every gap trigger, and the realtime mirror calls it the moment a
        // `notification_preferences` / `user_preferences` row changes. Before
        // this, every one of them was pulled ONCE per process launch and a
        // change made on the web could not reach the phone without a relaunch.
        await coord.setOnPreferencesStale { [weak self] in
            await MainActor.run { self?.refreshServerPreferences() }
        }
        await coord.start()
        // Apply the visibility the scenePhase handler may already have
        // reported before the coordinator existed (the cold-launch race that
        // used to leave a session with no periodic pull).
        setFreshnessVisible(foregroundVisible)
        await observeAuth(coord)

        // Register the APNs token (now or when it arrives).
        PushRegistrar.shared.onToken = { [weak self] hex in self?.registerPush(hex) }
        if let existing = PushRegistrar.shared.apnsTokenHex { registerPush(existing) }
        // "Unstuck calls you" (C1): bind the CallKit coordinator to the live store + calls client.
        CallCoordinator.shared.attach(model: self, client: coord.calls)
        installCallVoiceLauncher()

        // Travel. The server anchors every scheduled call, brief and reminder
        // to `notification_preferences.timezone`, which the phone pushed at
        // sign-in and after a hydrate — so a user who flew somewhere kept
        // ringing on the old zone's wall clock until the next hydrate, which
        // is one of the ways a call could land at 3am (audit 2026-09-21).
        // A day rollover re-derives Today's buckets for the same reason.
        timezoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.timezonePushedFor = nil   // force the push: the zone changed
                    self.pushTimezoneIfNeeded()
                    self.topUpRecurrenceHorizon()
                }
            }
        // A new day: repeating tasks get their horizon extended (see
        // topUpRecurrenceHorizon) for an app that stays open for weeks.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.topUpRecurrenceHorizon() }
            }

        // Register Live Activity per-update push tokens as they're issued.
        LiveActivityController.shared.onPushToken = { [weak self] activityId, token in
            self?.registerLiveActivityToken(activityId: activityId, token: token)
        }

        // BG app refresh (spec 02-sync-engine §5): flush + hydrate, then
        // rebuild the Start-Next widget snapshot (the in-app updater only
        // runs while TodayModel is alive — mirrors Android's SyncWorker).
        BackgroundSync.perform = { [weak coord, weak self] in
            await self?.drainSiriWriteQueue()   // apply Siri-queued writes first
            await coord?.syncNow()              // flush the outbox (incl. those)
            await self?.shareState.refresh()    // current delegation before the pick
            await self?.refreshWidgetSnapshot()
        }

        // Reminder scheduler + notification log + buffered push gestures
        // (spec 10): must come after repos exist so a cold launch from a
        // notification tap can resolve its task.
        startNotifications()

        // Seed the live-session cache from the persisted store (a relaunch
        // mid-session must surface the LiveSessionCard without waiting for a
        // mutator), then reap any focus Live Activity orphaned by a prior
        // kill/crash: rebind to a still-live session, else end the ghost timer.
        refreshLiveSession()
        reapStaleLiveActivities()
        // Retry shared-focus accruals that couldn't reach the server before a
        // kill (the offline-finish pending ledger — idempotent per sessionId),
        // after un-parking any this user parked at an offline sign-out.
        if let uid = coord.auth.currentUserId { restoreParkedSharedFocusLedger(userId: uid) }
        drainPendingSharedFocusLedger()
        // A paused check-in that fired while the app was dead claims its
        // budget slot now; today's first foreground feeds wake calibration.
        settlePausedCheckinBudgetIfFired()
        recordWakeWindowIfNeeded()
        // An auth-callback link that landed before the coordinator existed
        // (cold launch off a reset / magic link) is exchanged now.
        if let url = pendingAuthCallbackURL {
            pendingAuthCallbackURL = nil
            handleDeepLink(url)
        }

        // Apply any hands-free writes a Siri intent queued while the app was
        // closed, refresh the App-Group snapshot (Siri reads "how many left /
        // what's next" from it), then consume any "open the app" route stashed
        // before launch (cold-launch path — the scenePhase=.active hook no-ops
        // until db exists). Flush the drained ops to the server when present.
        let drained = drainSiriWriteQueue()
        refreshWidgetSnapshot()
        consumePendingSiriRoute()
        if drained { syncNow() }
    }

    /// Foreground/manual sync trigger (scenePhase .active, BG refresh):
    /// flush the outbox + hydrate for the current user. No-op signed out.
    /// Also re-extends the 48h reminder horizon (spec 10 §5.3) and catches
    /// the Notification Log up on anything delivered while away.
    func syncNow() {
        ReminderScheduler.shared.resync()
        NotificationLog.shared.sweepDelivered()
        // Keep the App-Group snapshot current on every foreground so Siri's
        // "how many left / what's next" answers don't lag.
        refreshWidgetSnapshot()
        // Retry any shared-focus accrual stranded by an offline finish
        // (pending ledger — idempotent per sessionId).
        drainPendingSharedFocusLedger()
        // A paused check-in that fired while we were away claims its push
        // budget slot now (budget is settled at FIRE time on every platform).
        settlePausedCheckinBudgetIfFired()
        // Today's first foreground → wake-window calibration (once per day).
        recordWakeWindowIfNeeded()
        // Foreground re-exchange for a live partner-shared session (Rejoin
        // reconciliation v2): un-park a `.disconnected` socket (supabase-swift
        // handleClose never auto-reconnects), force a real re-join when the
        // channel isn't genuinely subscribed, and re-send `hello` (any focuser
        // re-broadcasts its state — the rejoining/diverged side's convergence
        // trigger). HELLO-ONLY — never a state re-announce (a stale-healthy
        // status read must not impose unflagged offline state by rev
        // authority). Belt-and-braces beside the channel's socket monitor.
        if isPartnerCoFocusCandidate(cachedLiveSession) { liveCoFocus?.reexchange() }
        guard let coord = coordinator else { return }
        Task { await coord.syncNow() }
    }

    /// Whether the app is currently foregrounded, as last reported. Read by
    /// `start()` so a cold launch applies the visibility the scenePhase handler
    /// may already have reported before the engine existed.
    @ObservationIgnored private var foregroundVisible = true

    /// Foreground safety net (spec 02-sync-engine §5), now a THIN REPORT rather
    /// than a mechanism of its own: while the app is visible the freshness
    /// owner runs the floor-interval pull (still 60s) and everything else —
    /// realtime events, reconnects, the network coming back — reports to the
    /// same place, so overlapping triggers collapse into one pull instead of
    /// racing. Kept under the old names because the scenePhase handler calls
    /// them.
    func startForegroundSafetyNet() {
        setFreshnessVisible(true)
    }

    func stopForegroundSafetyNet() {
        setFreshnessVisible(false)
    }

    /// The app's visibility, remembered here so it survives the cold-launch
    /// ordering that used to lose it: `.active` regularly arrives BEFORE
    /// `start()` has built the coordinator, and the old safety net simply
    /// early-returned and never retried — leaving the whole session with no
    /// periodic pull at all. Now the flag is kept and applied the moment the
    /// engine exists (start() calls this again), and the freshness owner owns
    /// the timer.
    func setFreshnessVisible(_ visible: Bool) {
        foregroundVisible = visible
        guard let coord = coordinator else { return }
        Task { await coord.setVisible(visible) }
    }

    /// Recompute + write the Start-Next widget snapshot from the local
    /// store, then poke WidgetKit (used by the BG refresh task).
    func refreshWidgetSnapshot() {
        guard let repo = taskRepo else { return }
        let tasks = (try? repo.all()) ?? []
        let blocks = (try? db?.fetchAllCalBlocks()) ?? []
        let collections = (try? db?.fetchAllCollections()) ?? []
        let now = Date().timeIntervalSince1970 * 1000
        // Tasks I've assigned away are someone else's now — never surface them in
        // the widget / Siri "Start Next" pick or the App-Intent task list. (The
        // ShareModel is only refreshed while the app is used; in a pure background
        // pass BackgroundSync.perform refreshes it first so this set is current.)
        let excludeIds = _shareState?.assignedOutIds ?? []
        let next = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: liveTaskId, excludeIds: excludeIds)

        // Widget snapshot (unchanged payload) — the home/lock "Start Next" tile.
        let openCount = tasks.filter { !$0.done && !($0.later ?? false) }.count
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, taskId: next?.id, updatedAt: Date()))

        // Enriched snapshot the Siri "ask" intents read + the App Intent entities
        // resolve against. Counts use the SAME bucketing the UI shows.
        let nonTemplates = tasks.filter { !isTemplate($0) }
        // One shared prep for the two views below (see VisibleTasksPrep).
        let visiblePrep = VisibleTasksPrep(tasks: tasks, blocks: blocks)
        let todayList = visibleTasks(view: .today, prep: visiblePrep,
                                     now: now, activeArea: nil, slipMode: false).filter { !$0.done }
        let todayIds = Set(todayList.map { $0.id })
        // Assigned-away tasks are excluded from the pending list Siri can start
        // focusing on (parity with the Start-Next pick + the today-list filter).
        let pending = nonTemplates.filter { !$0.done && !($0.later ?? false) && !excludeIds.contains($0.id) }
        let overdue = visibleTasks(view: .backlog, prep: visiblePrep,
                                   now: now, activeArea: nil, slipMode: true).filter { !$0.done }
        // Relevance BEFORE the cap (today → due soonest → most recently
        // touched): the cap decides which tasks Siri can resolve at all, and
        // created-at order made the NEWEST tasks — the ones a user names —
        // unresolvable past 50 open tasks.
        let taskRefs = siriTaskOrder(pending, todayIds: todayIds).prefix(50).map {
            UnstuckSnapshot.TaskRef(id: $0.id, name: $0.name, today: todayIds.contains($0.id))
        }
        let colRefs = collections.filter { $0.archived != true }.map {
            UnstuckSnapshot.CollectionRef(id: $0.id, name: $0.name,
                                          openCount: $0.items.filter { $0.done != true }.count)
        }
        AppGroup.writeSnapshot(UnstuckSnapshot(
            pendingCount: pending.count, todayCount: todayList.count, overdueCount: overdue.count,
            nextTaskName: next?.name, nextEstimateMin: next?.estimateMin,
            tasks: Array(taskRefs), collections: colRefs, updatedAt: Date()))

        WidgetCenter.shared.reloadAllTimelines()
    }

    func registerPush(_ tokenHex: String) {
        guard let coord = coordinator else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        Task { try? await coord.push.register(deviceId: deviceId, apnsToken: tokenHex) }
    }

    /// Best-effort usage-analytics ping on sign-in (platform + device; the
    /// server derives country/city from the IP). Throttled to once per 12h per
    /// user via UserDefaults, mirroring the Android SyncCoordinator loginPing.
    private func trackLogin() {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let key = "unstuck.loginPing.\(uid)"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        if now - last < 12 * 60 * 60 { return }
        UserDefaults.standard.set(now, forKey: key)
        let device = "\(Self.deviceModelName) · iOS \(UIDevice.current.systemVersion)"
        Task { await coord.loginTracker.track(device: device) }
    }

    func registerLiveActivityToken(activityId: String, token: String) {
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        Task {
            try? await coord.push.registerLiveActivityToken(
                userId: uid, deviceId: deviceId, activityId: activityId, pushToken: token, sessionId: nil)
        }
    }

    private func observeAuth(_ coord: SyncCoordinator) async {
        // Reflect auth changes into UI state. Runs for the app lifetime.
        Task { [weak self] in
            for await (event, session) in coord.auth.authStateChanges {
                // A password-recovery link establishes an authenticated session
                // whose intent is "set a new password". The implicit flow emits a
                // `.passwordRecovery` event; the PKCE flow (what we ship) emits only
                // `.signedIn`, so we additionally probe the session's JWT `amr`
                // claim when a recovery deep link armed the probe.
                let isRecoveryEvent: Bool = { if case .passwordRecovery = event { return true }; return false }()
                let token = session?.accessToken
                let isAuthed = session != nil
                // Only an explicit .signedOut (the button OR a server session
                // revocation) is a real logout. A transient/offline
                // .initialSession with no session must NOT scrub — that wrongly
                // wiped device-local data on a flaky connection.
                let isSignOut: Bool = { if case .signedOut = event { return true }; return false }()
                let isSignedInEvent: Bool = { if case .signedIn = event { return true }; return false }()
                await MainActor.run {
                    guard let self else { return }
                    // Scrub device-local personal content only on a genuine
                    // sign-out, so the next account on this device starts clean.
                    // Idempotent.
                    if self.signedIn && isSignOut { self.scrubDeviceLocalUserContent() }
                    let becameAuthed = isAuthed && !self.signedIn
                    self.signedIn = isAuthed
                    // Refresh cached identity from the session in hand (no
                    // keychain read). Sign-out passes nil → clears it.
                    self.cachedUserName = AuthService.displayName(from: session)
                    self.cachedEmail = AuthService.email(from: session)
                    self.cachedUserId = AuthService.userId(from: session)
                    self.cachedHasPassword = AuthService.hasPassword(from: session)
                    self.cachedAccessToken = token
                    // PKCE: classify the just-EXCHANGED session via `amr` once —
                    // only a .signedIn carrying a token the probe hasn't seen
                    // (never the stored-session .initialSession / a refresh).
                    var isRecovery = isRecoveryEvent
                    if isAuthed, self.pendingRecoveryProbe,
                       Self.shouldConsumeRecoveryProbe(isSignedInEvent: isSignedInEvent,
                                                       armedToken: self.recoveryProbeArmedToken, token: token) {
                        self.pendingRecoveryProbe = false   // one-shot
                        self.recoveryProbeArmedToken = nil
                        if let token, Self.isRecoverySession(token) { isRecovery = true }
                    }
                    if isRecovery { self.pendingPasswordRecovery = true }
                    // Re-register the APNs token on every transition to
                    // authenticated (spec 10 §1.8): sign-out deletes this
                    // device's token row, so a user switch within one launch
                    // must recreate it for the NEW user.
                    if isAuthed, let hex = PushRegistrar.shared.apnsTokenHex {
                        self.registerPush(hex)
                    }
                    // Usage-analytics sign-in ping (not on recovery — that's a
                    // re-auth, not a real login). Throttled to once / 12h / user.
                    if isAuthed, !isRecovery { self.trackLogin() }
                    // Resolve the account-wide onboarding gate EARLY (a single
                    // row read) rather than after the whole first hydrate, so
                    // an existing account on a fresh install isn't shown the
                    // 5 steps while the server is still being asked.
                    if becameAuthed {
                        self.reconcileAccountOnboardingIfNeeded()
                        // The zone the SERVER schedules this account in — pushed
                        // at sign-in (not only after a hydrate) so a phone-only
                        // account is never left on the UTC fallback.
                        self.pushTimezoneIfNeeded()
                        // Shared-focus accruals parked at THIS user's last
                        // (offline) sign-out rejoin the queue and drain now —
                        // the web's USER_LEDGER_KEYS rule.
                        if let uid = AuthService.userId(from: session) {
                            self.restoreParkedSharedFocusLedger(userId: uid)
                            self.drainPendingSharedFocusLedger()
                        }
                        self.recordWakeWindowIfNeeded()
                    }
                    // A circle invite link tapped while signed out stashed its
                    // code — ask (Accept / Not now) now that we're authenticated.
                    if isAuthed { self.promptPendingCircleInviteIfAny() }
                }
            }
        }
    }

    /// True if the access-token JWT's `amr` (authentication-methods-reference)
    /// claim contains a `recovery` entry — i.e. this session came from a
    /// password-reset link. Best-effort decode of the unsigned middle segment
    /// (base64url). Mirrors the Android isRecoverySession amr probe.
    ///
    /// `nonisolated`: a pure static over its `jwt` argument with no actor state,
    /// so it's correct to call off the main actor (and lets it be unit-tested
    /// from a non-isolated context).
    nonisolated static func isRecoverySession(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let amr = obj["amr"] as? [Any] else { return false }
        return amr.contains { entry in
            if let s = entry as? String { return s == "recovery" }
            if let d = entry as? [String: Any] { return (d["method"] as? String) == "recovery" }
            return false
        }
    }

    /// Pure: the armed recovery probe is spent only by a `.signedIn` (the PKCE
    /// code exchange) whose access token is not the one that was already in
    /// hand when the callback link armed it. `.initialSession` replays of a
    /// stored session, `.tokenRefreshed` and `.userUpdated` never qualify.
    nonisolated static func shouldConsumeRecoveryProbe(isSignedInEvent: Bool, armedToken: String?,
                                                       token: String?) -> Bool {
        guard isSignedInEvent, let token, !token.isEmpty else { return false }
        return token != armedToken
    }

    /// Finish password recovery: the user has set a new password, drop the flag
    /// so RootView leaves the set-new-password screen for the app.
    func consumeRecovery() { pendingPasswordRecovery = false; pendingRecoveryProbe = false; recoveryProbeArmedToken = nil }

    /// A pending trusted-circle invite code from a tapped invite LINK
    /// (unstucknow.io/circle/join?code=…), held until we're signed in so the
    /// confirm prompt can show. Cleared once prompted.
    private var pendingCircleCode: String?

    /// Drives the invite-link UI (MainTabScaffold alerts): a tapped invite link
    /// first asks Accept / Not now, then reports the outcome. The tester's
    /// feedback on the silent auto-redeem: "there's no way to accept or decline,
    /// when it auto accepts this isn't visible" — so nothing is redeemed until
    /// the user accepts, and the result is always shown.
    enum CircleInvitePrompt: Identifiable, Equatable {
        case confirm(code: String)
        case result(ok: Bool, message: String)
        var id: String {
            switch self {
            case .confirm(let code): return "confirm:\(code)"
            case .result(let ok, let message): return "result:\(ok):\(message)"
            }
        }
    }
    var circleInvitePrompt: CircleInvitePrompt?

    /// Accept a circle invite (the confirm alert's Accept) → redeem on the
    /// server → surface the outcome. Success also fires the circle-changed
    /// signal so an open People roster refetches.
    func acceptCircleInvite(code: String) {
        guard let circle = coordinator?.circle else {
            circleInvitePrompt = .result(ok: false, message: "Couldn’t join — you’re not signed in.")
            return
        }
        Task { [weak self] in
            let res = await circle.redeem(code: code)
            await MainActor.run {
                guard let self else { return }
                if res.ok {
                    let who = res.ownerName.flatMap { $0.isEmpty ? nil : $0 } ?? "them"
                    // Unified sharing v1: the link can carry an item, granted in
                    // the same step — say so, and point at where it landed.
                    let landed: String = res.grantedTaskId != nil
                        ? " The task they shared is in “Shared with you”."
                        : res.grantedCollectionId != nil ? " The list they shared is under Collections." : ""
                    let base = res.alreadyConnected == true
                        ? "You were already connected with \(who)."
                        : "You’re now connected with \(who). You’ll find each other under Settings → People, and tasks they share appear in “Shared with you”."
                    self.circleInvitePrompt = .result(ok: true, message: base + landed)
                    NotificationCenter.default.post(name: .unstuckCollabCircleChanged, object: nil)
                    if res.grantedItem { NotificationCenter.default.post(name: .unstuckCollabSharesChanged, object: nil) }
                } else {
                    self.circleInvitePrompt = .result(ok: false, message: Self.circleRedeemErrorText(res.error))
                }
            }
        }
    }

    /// Human copy for a failed redeem — mirrors the web /circle/join page.
    nonisolated static func circleRedeemErrorText(_ error: String?) -> String {
        switch error {
        case "invalid_or_expired": return "This invite has expired or already been used."
        case "self": return "That’s your own invite link."
        case "already_in_circle": return "You’re already in this circle."
        default: return "Couldn’t join with this link. Check your connection and try again."
        }
    }

    /// Extract the invite `code` from a circle-join UNIVERSAL LINK
    /// (https://unstucknow.io/circle/join?code=…). Returns nil for anything else.
    /// This is the https link the invite email/copy-link shares — Universal Links
    /// route it here so the app opens instead of Safari (bug: it opened the site).
    nonisolated static func circleJoinCode(from url: URL) -> String? {
        guard let host = url.host, host.hasSuffix("unstucknow.io") else { return nil }
        guard url.path.hasPrefix("/circle/join") else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let code = items?.first(where: { $0.name == "code" })?.value
        return (code?.isEmpty == false) ? code : nil
    }

    /// Surface the confirm prompt for a stashed invite code once signed in
    /// (a link tapped while signed out waits for auth, then asks).
    func promptPendingCircleInviteIfAny() {
        guard let code = pendingCircleCode, signedIn else { return }
        pendingCircleCode = nil
        circleInvitePrompt = .confirm(code: code)
    }

    func handleDeepLink(_ url: URL) {
        // A tapped invite LINK (https universal link) → ask Accept / Not now in
        // the app (was opening the website; then auto-redeeming with no visible
        // feedback). Signed out → stash and ask right after sign-in.
        if let code = Self.circleJoinCode(from: url) {
            if signedIn {
                circleInvitePrompt = .confirm(code: code)
            } else {
                pendingCircleCode = code
            }
            return
        }
        // OAuth / magic-link PKCE callback → the auth client; everything
        // else (unstuck://task/…, /focus/…, /today, capture) routes to the
        // matching surface (spec 10 §1.7 push-tap deep links).
        if url.host == "auth-callback" {
            // The implicit flow's type=recovery is an early belt-and-suspenders
            // flag (PKCE recovery carries no type=recovery in the URL).
            if url.absoluteString.range(of: "type=recovery", options: .caseInsensitive) != nil {
                pendingPasswordRecovery = true
            }
            // A cold launch off the link: the coordinator doesn't exist yet —
            // stash the URL and replay it at the end of start() (like
            // pendingCircleCode) instead of dropping the exchange.
            guard let coord = coordinator else { pendingAuthCallbackURL = url; return }
            // Arm the one-shot recovery probe for the session this callback is
            // about to exchange, remembering the token ALREADY in hand so only
            // the exchanged (different) token can spend it — observeAuth then
            // classifies that session via the JWT `amr`.
            pendingRecoveryProbe = true
            recoveryProbeArmedToken = coord.auth.accessToken
            Task { _ = await coord.auth.handleCallback(url: url) }
            return
        }
        routeDeepLink(url.absoluteString)
    }

    /// The task id of the active live focus session (nil when idle). Today uses
    /// it to exclude the in-progress task from the Start-Next suggestion + list.
    /// Reads the in-memory cache (kept current by `refreshLiveSession`) so the
    /// per-render access doesn't hit the GRDB store.
    var liveTaskId: String? {
        guard let live = cachedLiveSession, live.sessionStart != nil else { return nil }
        return live.taskId
    }

    /// The optimistic write API (local GRDB + server outbox), for features.
    /// Drives the UI instantly via each repository's ValueObservation. Falls
    /// back to the local-only writer in the XCUITest demo boot.
    var write: WriteThrough? { coordinator?.write ?? uiTestWrite }

    /// Sign out via the coordinator's spec'd path: drain the outbox
    /// (bounded; whatever can't be pushed — offline — is parked under this
    /// user and restored on their next sign-in, never discarded), unregister
    /// this device's push token while the JWT is still valid, then sign out
    /// (spec 02 §1.7 signOutAndUnregister).
    /// Also wipe the device-local notification state (spec 10 §1.8/§1.11):
    /// the log + per-task reminder overrides, every scheduled reminder, and
    /// the pending paused check-in — so the next account on this device
    /// starts clean and never sees the previous user's task names.
    /// Edits still waiting to reach the server — the Settings sign-out row can
    /// say "N changes haven't synced yet; they'll sync when you next sign in
    /// here" (they're parked, not lost).
    var pendingSyncCount: Int { coordinator?.pendingOutboxCount() ?? 0 }

    func signOut() {
        guard let coord = coordinator else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        let uid = coord.auth.currentUserId ?? cachedUserId
        Task {
            // DRAIN BEFORE SCRUB (web parity): the scrub below wipes the App
            // Group (Siri's hands-free write queue) and the shared-focus ledger,
            // so first fold the queued Siri writes into the outbox (drained by
            // signOutAndUnregister) and give the pending shared-focus accruals a
            // bounded shot at the server WHILE the JWT is still valid. Whatever
            // still can't land is PARKED under this user and replayed on their
            // next sign-in here — never discarded (the web's USER_LEDGER_KEYS).
            //
            // A running focus session is finalized FIRST (Android parity): its
            // Session row + focus time are this user's — the sync sign-out's
            // clearAll would otherwise drop the live_session row and the
            // minutes with it — and its Live Activity ends now, so the lock
            // screen / Dynamic Island never keep counting under a task name
            // after the account is gone. A ledger accrual (partner-shared
            // task) is attempted while the JWT is still valid; a failure lands
            // in the pending ledger, which the park below carries over.
            // Also stops the guided tour so its lockdown never survives into
            // AuthView / the next account (the store itself is wiped by the scrub).
            _tour?.teardownForSignOut()
            if let accrual = finalizeLiveSessionForSignOut() {
                await logSharedFocusDurable(taskId: accrual.taskId, actualSec: accrual.sec,
                                            estimateMin: accrual.estimateMin, sessionId: accrual.sessionId)
            }
            _ = drainSiriWriteQueue()
            await drainPendingSharedFocusLedgerBounded(seconds: 5)
            if let uid { parkPendingSharedFocusLedger(userId: uid) }
            scrubDeviceLocalUserContent()
            await ReminderScheduler.shared.cancelAll()
            await coord.signOutAndUnregister(deviceId: deviceId)
        }
    }

    /// The guided tour is mid-run (its lockdown owns the screen). Settings
    /// reads this to keep the account danger rows (Sign out / Delete account /
    /// Export) disabled while the tour runs — a sign-out mid-tour used to leave
    /// the running lockdown live over AuthView.
    var tourRunning: Bool { _tour?.phase == .running }

    /// Wipe device-local personal content (notification log + per-task reminder
    /// overrides, the pending paused check-in, the Inbox archive set, the
    /// assistant chat) so the next account on this device starts clean and never
    /// sees the prior user's content. Idempotent — runs from the Sign-out button
    /// (immediate) AND reactively in observeAuth on ANY session→nil transition
    /// (server revocation, refresh failure, password-change-elsewhere), since
    /// those never route through the button.
    func scrubDeviceLocalUserContent() {
        // A live focus session still in the store (the REACTIVE path — the
        // Sign-out button finalized before reaching here, so this is a no-op
        // there): finalize the own session + end its Live Activity. The JWT is
        // already gone on this path, so a ledger accrual goes straight into the
        // pending ledger — parked under this user at the tail of this scrub.
        if let accrual = finalizeLiveSessionForSignOut() {
            var queue = pendingSharedFocusLogs.filter { $0.sessionId != accrual.sessionId }
            queue.append(accrual)
            pendingSharedFocusLogs = queue
        }
        // The guided tour: stop a running/offered tour (lockdown, audio,
        // polls, the accessibility lock) and forget its state, so the next
        // account gets its own one-time welcome instead of A's resume card,
        // and a sign-out mid-tour never leaves the lockdown over AuthView.
        _tour?.teardownForSignOut()
        _tour = nil
        TourStore.clear()
        // What the bottom-bar + is aimed at: the Collections surface described
        // A's shelf. The tab setter retracts it on every tab change, but a
        // sign-out tears the whole scaffold down without one.
        router.clearCollectionsSurface()
        NotificationLog.shared.clear()
        NotificationPrefs.clearUserContent()   // per-task overrides + the cached level / lead
        PausedCheckinBudget.disarm()           // no budget settlement — the JWT is going away
        // The Inbox archive cache — from the store side (the outbox / archive
        // table are wiped by the sync clearAll), never as unarchive writes.
        captureArchiveWriteThroughSuppressed = true
        archivedCaptureIds = []
        captureArchiveWriteThroughSuppressed = false
        // Account-scoped flags + prefs the next account must not inherit: the
        // onboarding gate + struggles (else B skips onboarding under A's picks
        // and never pulls its own), the call window / lead, dismissed nudges,
        // blocked collaborators, the usable-minutes cache, the call-outcome
        // queue (A's reports would be sent — and 404 — under B), the per-user
        // login-ping throttles, and the hydrate-once guards.
        let d = UserDefaults.standard
        for key in ["unstuck.onboarded", "unstuck.adhdStruggles",
                    "unstuck.dismissedNudges", "unstuck.blockedEmails",
                    "unstuck.usableMinutesPerDay", "unstuck.usableMinutesWeekend",
                    "unstuck.calls.outcomeQueue"] + CallSettings.userContentKeys {
            d.removeObject(forKey: key)
        }
        callProactivePrefs = .defaults
        for key in d.dictionaryRepresentation().keys
        where key.hasPrefix("unstuck.loginPing.") || key.hasPrefix("unstuck.wakeWindow.") {
            d.removeObject(forKey: key)
        }
        onboarded = false
        onboardingResolved = false
        onboardingReconciledFor = nil
        serverPrefsPulledFor = nil
        timezonePushedFor = nil
        // The App Group container: the widget / Siri snapshots carry this
        // account's task + list names, and hands-free Siri writes queued after
        // the sign-out would otherwise land in the NEXT account on drain.
        clearAppGroupUserContent()
        // The assistant's memory is personal by definition — wipe the local
        // rows (the server keeps the account's facts; the sync clearAll on the
        // signed-out event covers the same table for reactive sign-outs).
        profileFacts?.wipeLocal()
        // The next account waits for ITS hydrate before an empty memory means
        // "never met" (and re-pulls its struggles).
        profileFactsHydrated = false
        // Push tokens: a reactive sign-out (server revocation, refresh failure)
        // never routes through signOutAndUnregister, so drop the VoIP token +
        // any call in progress best-effort here too — else the previous
        // account's calls could still ring this device.
        VoipPushRegistry.shared.unregisterBestEffort()
        // Gateway state is per-user too: ritual prefs + dismissed moments
        // (PAPrefsStore.scrub() under the hood, then the in-memory reset) and
        // the first-run interview flag + resume step, so the next account on
        // this device is greeted, not silently skipped.
        paPrefs.scrub()
        InterviewMachine.resetDone()
        // The server flag re-applies on the next sign-in's hydrate — for
        // WHOEVER signs in next, so forget which account was reconciled.
        interviewFlagPulledFor = nil
        _assistant?.clear()
        AssistantModel.scrubPersisted()
        Task { await ReminderScheduler.shared.cancelAll() }
        // One-true-shared-session: stop any in-flight drain and PARK the
        // signed-out account's pending ledger accruals under that account —
        // the NEXT account on this device must never post the previous
        // account's shared-focus records, and the previous account must not
        // lose them either (replayed on THEIR next sign-in here). The Sign-out
        // button parks after its bounded drain; this also covers the reactive
        // path (server revocation / refresh failure), where `cachedUserId`
        // still names the account being signed out. Unknown owner → dropped.
        sharedLedgerDrainTask?.cancel()
        sharedLedgerDrainTask = nil
        if let owner = cachedUserId ?? coordinator?.auth.currentUserId {
            parkPendingSharedFocusLedger(userId: owner)
        } else {
            pendingSharedFocusLogs = []
        }
    }

    /// Wipe the App Group container's per-user content (Start-Next widget
    /// snapshot, the enriched Siri snapshot, the hands-free write queue and
    /// any stashed Siri prompt / route) and redraw the widget empty.
    private func clearAppGroupUserContent() {
        AppGroup.clearUserContent()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - capture archive (server `captures.archived_at`, migration 053)

    /// Mirror the local `capture_archive` table into the observable set the
    /// Inbox reads. Store → set only; suppressed so it isn't echoed back.
    private func startCaptureArchiveObservation(_ database: AppDatabase) {
        captureArchiveObservation?.cancel()
        captureArchiveObservation = Task { [weak self] in
            do {
                for try await ids in database.observeArchivedCaptureIds() {
                    guard let self else { return }
                    self.setArchivedCaptureIdsFromStore(ids)
                }
            } catch {}
        }
    }

    private func setArchivedCaptureIdsFromStore(_ ids: Set<String>) {
        guard ids != archivedCaptureIdsBacking else { return }
        captureArchiveWriteThroughSuppressed = true
        archivedCaptureIds = ids   // also refreshes the UserDefaults cache
        captureArchiveWriteThroughSuppressed = false
    }

    /// The observable set changed from the UI side (archive / restore taps,
    /// the assistant's archive_capture): write the diff through the
    /// repository + outbox so `archived_at` reaches the server. A capture that
    /// no longer exists locally is skipped by the write-through (no op).
    private func propagateCaptureArchiveChange(from old: Set<String>, to new: Set<String>) {
        guard !captureArchiveWriteThroughSuppressed, let write else { return }
        let added = new.subtracting(old), removed = old.subtracting(new)
        guard !added.isEmpty || !removed.isEmpty else { return }
        let now = Self.isoNow()
        Task {
            for id in added { _ = try? await write.setCaptureArchived(id: id, archivedAt: now, nowISO: now) }
            for id in removed { _ = try? await write.setCaptureArchived(id: id, archivedAt: nil, nowISO: now) }
        }
    }

    /// One-time: the pre-053 device-local archive set (UserDefaults) becomes
    /// server state — every id whose capture still exists locally is written
    /// through as `archived_at = now`; ids without a row are dropped. Runs
    /// before the observation starts so the Inbox never flashes empty.
    private func migrateLegacyCaptureArchiveIfNeeded() async {
        let key = "unstuck.captureArchive.migrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let write, let db else { return }
        let legacy = UserDefaults.standard.stringArray(forKey: "unstuck.archivedCaptureIds") ?? []
        let already = (try? db.archivedCaptureIds()) ?? []
        let now = Self.isoNow()
        for id in legacy where !already.contains(id) {
            _ = try? await write.setCaptureArchived(id: id, archivedAt: now, nowISO: now)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// `set_usable_minutes`: the budget lives on the server
    /// (`user_preferences.usable_minutes_per_day / _weekend` — the web
    /// calendar's capacity math reads it), so the server write IS the change;
    /// the local keys are written only after it lands. Returns the REAL
    /// outcome so a tool can refuse to claim a save that didn't happen.
    func setUsableMinutesAwaiting(perDay: Int?, weekend: Int?) async -> Bool {
        guard perDay != nil || weekend != nil else { return false }
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return false }
        do {
            try await coord.preferences.setUsableMinutes(userId: uid, perDay: perDay, weekend: weekend)
        } catch { return false }
        let d = UserDefaults.standard
        if let perDay { d.set(perDay, forKey: "unstuck.usableMinutesPerDay") }
        if let weekend { d.set(weekend, forKey: "unstuck.usableMinutesWeekend") }
        return true
    }

    func saveTask(_ task: TaskItem) {
        Task { await saveTaskAwaiting(task) }
    }

    // MARK: awaiting writes (the assistant executor)
    //
    // The fire-and-forget methods are what UI taps call. The assistant executor
    // READS the store synchronously between its own writes (add_capture →
    // promote_capture, create_task → schedule_task → delete_task in one turn),
    // so it needs writes that return only after the local GRDB row is committed
    // and the outbox op enqueued — same WriteThrough, same cascades, awaited.
    // Network side-effects (the Google mirror) stay fire-and-forget behind them.

    /// True once the local row + outbox op are committed.
    @discardableResult
    func saveTaskAwaiting(_ task: TaskItem) async -> Bool {
        guard let write else { return false }
        do { try await write.upsertTask(task, nowISO: Self.isoNow()); return true } catch { return false }
    }

    @discardableResult
    func deleteTaskAwaiting(_ id: String) async -> Bool {
        guard let write else { return false }
        // Read the row BEFORE the delete: a task promoted from a shared
        // collection item leaves that item ticked with nothing behind it unless
        // we un-tick it for the other members.
        let promoted = (try? taskRepo?.fetch(id: id)) ?? nil
        do { try await write.deleteTask(id: id, nowISO: Self.isoNow()) } catch { return false }
        if let promoted { notifyTaskReopenedIfShared(promoted) }
        return true
    }

    func saveTagAwaiting(_ tag: TagRow) async {
        guard let write else { return }
        try? await write.upsertTag(tag, nowISO: Self.isoNow())
    }

    /// `deleteTag`, awaited through the whole cascade. No strip runs over a
    /// failed delete, and a same-named twin left by the old unchecked rename
    /// keeps its tasks (audit 2026-09-22, C19).
    func deleteTagAwaiting(_ id: String) async {
        await afterPreviousLabelCascade {
            guard let write = self.write else { return }
            let rows = (try? self.db?.fetchAllTags()) ?? []
            let name = rows.first { $0.id == id }?.name
            do { try await write.deleteTag(id: id, nowISO: Self.isoNow()) } catch { return }
            guard let name, !labelNameTaken(name, among: rows.filter { $0.id != id }.map(\.name)) else { return }
            await self.relabelTasks { strippingTag($0, name: name, nowISO: Self.isoNow()) }
        }
    }

    /// Rename a tag and carry the new name onto every task that carries the
    /// old one (case-insensitive, Android renameTag parity). Tasks key tags by
    /// NAME, so the row-only rename Settings used to do orphaned them. A name
    /// another tag already has (ignoring case) is refused: the server's
    /// unique(user_id, name) rejects it and the outbox quarantines the row
    /// while the task relabels still sync (audit 2026-09-22, C19).
    /// True once the row and its tasks are committed.
    @discardableResult
    func renameTagAwaiting(_ id: String, to newName: String) async -> Bool {
        await afterPreviousLabelCascade {
            guard let write = self.write, let db = self.db else { return false }
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rows = (try? db.fetchAllTags()) ?? []
            let others = rows.filter { $0.id != id }.map(\.name)
            guard !name.isEmpty, let row = rows.first(where: { $0.id == id }), name != row.name,
                  !labelNameTaken(name, among: others) else { return false }
            var renamed = row
            renamed.name = name
            do { try await write.upsertTag(renamed, nowISO: Self.isoNow()) } catch { return false }
            // A twin the old unchecked rename left behind still owns the old
            // name; moving its tasks would empty that tag.
            guard !labelNameTaken(row.name, among: others) else { return true }
            await self.relabelTasks { renamingTag($0, from: row.name, to: name, nowISO: Self.isoNow()) }
            return true
        }
    }

    func saveLifeAreaAwaiting(_ area: LifeArea) async {
        guard let write else { return }
        try? await write.upsertLifeArea(area, nowISO: Self.isoNow())
    }

    /// Rename a life area and move every task filed under the old name onto
    /// the new one (exact match, like the web and Android). Tasks key areas by
    /// NAME, so the row-only rename Settings used to do left them behind: the
    /// new pill showed nothing, the count read 0, and web/Android still showed
    /// the old name. A name another area already has (ignoring case) is
    /// refused: the server's unique(user_id, name) rejects it and the outbox
    /// quarantines the row while the task relabels still sync (audit
    /// 2026-09-22, C19). True once the row and its tasks are committed.
    @discardableResult
    func renameLifeAreaAwaiting(_ id: String, to newName: String) async -> Bool {
        await afterPreviousLabelCascade {
            guard let write = self.write, let db = self.db else { return false }
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rows = (try? db.fetchAllLifeAreas()) ?? []
            guard !name.isEmpty, let row = rows.first(where: { $0.id == id }), name != row.name,
                  !labelNameTaken(name, among: rows.filter { $0.id != id }.map(\.name)) else { return false }
            var renamed = row
            renamed.name = name
            do { try await write.upsertLifeArea(renamed, nowISO: Self.isoNow()) } catch { return false }
            // A twin the old unchecked rename left behind still owns the old
            // name; its tasks stay where they are.
            guard !rows.contains(where: { $0.id != id && $0.name == row.name }) else { return true }
            await self.relabelTasks { relabelingArea($0, from: row.name, to: name, nowISO: Self.isoNow()) }
            return true
        }
    }

    /// Delete a life area and clear its label off every task filed under it,
    /// which is what the Settings delete alert promises ("they just lose this
    /// area label") and what web/Android do (audit 2026-09-22, C19). No
    /// relabel runs over a failed delete, and a same-named twin keeps its
    /// tasks.
    func deleteLifeAreaAwaiting(_ id: String) async {
        await afterPreviousLabelCascade {
            guard let write = self.write else { return }
            let rows = (try? self.db?.fetchAllLifeAreas()) ?? []
            let name = rows.first { $0.id == id }?.name
            do { try await write.deleteLifeArea(id: id, nowISO: Self.isoNow()) } catch { return }
            guard let name, !rows.contains(where: { $0.id != id && $0.name == name }) else { return }
            await self.relabelTasks { relabelingArea($0, from: name, to: nil, nowISO: Self.isoNow()) }
        }
    }

    /// Rewrite every task `transform` touches. Each match is re-read right
    /// before its write: the upsert sends the WHOLE row, so a snapshot taken
    /// before an earlier await would revert an edit that landed in between
    /// and push it as a fresh local change (audit 2026-09-22, C19).
    private func relabelTasks(_ transform: (TaskItem) -> TaskItem?) async {
        guard let write, let repo = taskRepo else { return }
        for t in (try? repo.all()) ?? [] where transform(t) != nil {
            guard let fresh = (try? repo.fetch(id: t.id)) ?? nil, let next = transform(fresh) else { continue }
            try? await write.upsertTask(next, nowISO: Self.isoNow())
        }
    }

    /// Runs one label rename/delete after the previous one has finished. The
    /// cascades yield at every task write, so a rename A→B still relabelling
    /// while a delete of B (or a rename B→C) reads the task list would skip
    /// the tasks not yet moved, and the first cascade would then park them on
    /// a name no area has (audit 2026-09-22, C19).
    private func afterPreviousLabelCascade<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = labelCascadeTail
        let run = Task { @MainActor in
            await previous?.value
            return await body()
        }
        labelCascadeTail = Task { _ = await run.value }
        return await run.value
    }

    /// `saveBlock`, returning once the local row is committed; the Google
    /// mirror runs behind it exactly as before.
    func saveBlockAwaiting(_ block: CalBlock) async {
        guard let write else { return }
        // Scheduling ends "Later" parking. Done HERE — the one choke point
        // every scheduling path funnels through (the Schedule sheet, a
        // calendar/mini-calendar drop, create, loop-promote, the assistant's
        // schedule_task/bulk tools) — so a parked task that just got a slot
        // stops being filtered out of every active list while sitting on the
        // calendar. Mirrors web's clearLaterFlag / Android's scheduleTaskNow.
        // (Only the block's OWN task is read — a whole-table fetch here would
        // run once per block in a bulk calendar turn.)
        let nowISO = Self.isoNow()
        if let taskId = block.taskId, let owner = (try? taskRepo?.fetch(id: taskId)) ?? nil,
           let unparked = unparkedTaskForBlock(block, tasks: [owner], nowISO: nowISO) {
            try? await write.upsertTask(unparked, nowISO: nowISO)
        }
        try? await write.upsertCalBlock(block, nowISO: Self.isoNow())
        // Only TASK blocks mirror to Google (spec §1.6): external g_ blocks are
        // read-only mirrors of the remote calendar and must never be
        // (re-)pushed; placeholders have nothing to push.
        guard isTaskBlock(block) else { return }
        Task { await self.mirrorBlockToGoogle(block) }
    }

    /// `deleteBlock`, returning once the local row is committed. The Google
    /// event delete (if it was pushed) follows behind — order doesn't matter
    /// to either side, and the executor must not wait on the network.
    func deleteBlockAwaiting(_ block: CalBlock) async {
        guard let write else { return }
        try? await write.deleteCalBlock(id: block.id, nowISO: Self.isoNow())
        Task { await self.deleteGoogleEvent(for: block) }
    }

    /// `unschedule` (AppModel+CalendarControls), awaited: reconcile Google for a
    /// pushed task block, plain delete when the block isn't in the store.
    func unscheduleAwaiting(_ blockId: String) async {
        if let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == blockId }) {
            await deleteBlockAwaiting(block)
        } else if let write {
            try? await write.deleteCalBlock(id: blockId, nowISO: Self.isoNow())
        }
    }

    @discardableResult
    func saveCaptureAwaiting(_ capture: Capture) async -> Bool {
        guard let write else { return false }
        do { try await write.upsertCapture(capture, nowISO: Self.isoNow()); return true } catch { return false }
    }

    /// `discardCapture` (AppModel+Captures), awaited: delete the row, then drop
    /// any device-local archived flag.
    func discardCaptureAwaiting(_ id: String) async {
        guard let write else { return }
        try? await write.deleteCapture(id: id, nowISO: Self.isoNow())
        unarchiveCapture(id)
    }

    /// `setNotificationLevel` (AppModel+Notifications) with the OUTCOME: the
    /// local write read back, then the server mirror awaited — false when
    /// either fails (web parity: `setNotificationLevel` resolves false on a
    /// failed upsert), so the assistant's "could not save" branch is real.
    func setNotificationLevelAwaiting(_ level: NotificationLevel) async -> Bool {
        NotificationPrefs.level = level
        ReminderScheduler.shared.resync()
        guard NotificationPrefs.level == level else { return false }
        // Pending until the server has it: the next hydrate re-pushes a
        // failed write instead of pulling the server's older level over it.
        NotificationPrefs.pendingServerPush = true
        notifPrefsPushGen += 1
        let gen = notifPrefsPushGen
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return false }
        do {
            try await coord.preferences.setNotificationLevel(
                userId: uid, morningBrief: level.morningBrief, pausedCheckin: level.pausedCheckin, level: level.rawValue)
            if notifPrefsPushGen == gen, coord.auth.currentUserId == uid { NotificationPrefs.pendingServerPush = false }
            return true
        } catch { return false }
    }

    /// `setReminderLeadMin`, with the outcome (local read-back + the awaited
    /// `reminder_lead_min` mirror the web also writes).
    func setReminderLeadAwaiting(_ minutes: Int) async -> Bool {
        NotificationPrefs.reminderLeadMin = minutes
        ReminderScheduler.shared.resync()
        guard NotificationPrefs.reminderLeadMin == minutes else { return false }
        NotificationPrefs.pendingServerPush = true
        notifPrefsPushGen += 1
        let gen = notifPrefsPushGen
        guard let coord = coordinator, let uid = coord.auth.currentUserId else { return false }
        do {
            try await coord.preferences.setReminderLead(userId: uid, minutes: minutes)
            if notifPrefsPushGen == gen, coord.auth.currentUserId == uid { NotificationPrefs.pendingServerPush = false }
            return true
        } catch { return false }
    }

    /// Save a task + reconcile its recurrence: materialize future cal_blocks
    /// (regenerateForTask) and drop mismatched ones. `existingBlocks` is the
    /// task's current blocks from the observed store. The horizon is anchored on
    /// the task's earliest LIVE task-block (`recurrenceAnchor`) so a recurrence
    /// change keeps the series where the user put it instead of snapping it to
    /// 09:00 today — or, as the old "earliest block of any kind" did, back to
    /// the time of some finished occurrence from weeks ago (audit 2026-09-21).
    func saveTaskWithRecurrence(_ task: TaskItem, existingBlocks: [CalBlock]) {
        saveTask(task)
        guard let write = coordinator?.write else { return }
        let anchor = recurrenceAnchor(taskId: task.id, blocks: existingBlocks, todayIso: Clock.todayISO())
        let startTime = anchor?.startTime ?? "09:00"
        let startDate: Date = anchor.flatMap { a in
            let parts = a.date.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? Time.civil(parts[0], parts[1], parts[2]) : nil
        } ?? Date()
        let plan = regenerateForTask(
            task: task, recurrence: task.recurrence, existingBlocks: existingBlocks,
            todayIso: Clock.todayISO(), startTime: startTime, startDate: startDate)
        let now = Self.isoNow()
        Task {
            for block in plan.toUpsert { try? await write.upsertCalBlock(block, nowISO: now) }
            for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
        }
    }

    /// Extend every repeating task's occurrences back out to the horizon.
    ///
    /// `regenerateForTask` only ever runs when the user touches a task, and it
    /// mints a fixed 8 weeks ahead. So 8 weeks after the last edit a repeating
    /// task has no future occurrence left: it disappears from Today, Upcoming
    /// and the calendar and survives only as one overdue row in Backlog. A beta
    /// that runs longer than that loses every recurring task its testers made
    /// (audit 2026-09-21). Run at launch and at a day rollover; the plan is a
    /// pure diff, so doing it repeatedly costs nothing and changes nothing.
    ///
    /// ADDITIONS ONLY: this is maintenance, not an edit. Honouring the plan's
    /// deletions here would let a background pass quietly remove occurrences
    /// the user moved by hand.
    func topUpRecurrenceHorizon() {
        guard let write = coordinator?.write, let repo = taskRepo else { return }
        let tasks = (try? repo.all()) ?? []
        let templates = tasks.filter { $0.recurrence != nil && !$0.done }
        guard !templates.isEmpty else { return }
        let blocks = (try? db?.fetchAllCalBlocks()) ?? []
        let today = Clock.todayISO()
        var toAdd: [CalBlock] = []
        for t in templates {
            guard let anchor = recurrenceAnchor(taskId: t.id, blocks: blocks, todayIso: today) else { continue }
            let parts = anchor.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            let plan = regenerateForTask(
                task: t, recurrence: t.recurrence, existingBlocks: blocks, todayIso: today,
                startTime: anchor.startTime, startDate: Time.civil(parts[0], parts[1], parts[2]))
            toAdd.append(contentsOf: plan.toUpsert)
        }
        guard !toAdd.isEmpty else { return }
        let now = Self.isoNow()
        Logger(subsystem: "io.unstucknow.app", category: "recurrence")
            .notice("horizon top-up: \(toAdd.count, privacy: .public) occurrence(s) across \(templates.count, privacy: .public) task(s)")
        Task { for b in toAdd { try? await write.upsertCalBlock(b, nowISO: now) } }
    }

    func deleteTask(_ id: String) {
        Task { await deleteTaskAwaiting(id) }
    }

    func saveTag(_ tag: TagRow) {
        Task { await saveTagAwaiting(tag) }
    }
    /// Delete a tag and strip its name from every task (case-insensitive
    /// cascade), mirroring the web/Android deleteTag — otherwise tasks keep a
    /// dangling reference to a vocabulary entry that no longer exists.
    func deleteTag(_ id: String) {
        Task { await deleteTagAwaiting(id) }
    }
    /// Rename a tag and carry the new name onto every task that uses it
    /// (audit 2026-09-22, C19).
    func renameTag(_ id: String, to name: String) {
        Task { await renameTagAwaiting(id, to: name) }
    }
    func saveLifeArea(_ area: LifeArea) {
        Task { await saveLifeAreaAwaiting(area) }
    }
    /// Rename an area and move every task filed under the old name (audit
    /// 2026-09-22, C19).
    func renameLifeArea(_ id: String, to name: String) {
        Task { await renameLifeAreaAwaiting(id, to: name) }
    }
    /// Delete an area and clear its label off every task filed under it,
    /// mirroring the web/Android deleteLifeArea (audit 2026-09-22, C19).
    func deleteLifeArea(_ id: String) {
        Task { await deleteLifeAreaAwaiting(id) }
    }

    var calendar: CalendarClient? { coordinator?.calendar }

    /// Save a cal_block (create or edit) + reconcile Google: PATCH if it
    /// already has an event id, otherwise INSERT and persist the new id.
    func saveBlock(_ block: CalBlock) {
        Task { await saveBlockAwaiting(block) }
    }

    /// The connection a pushed block's Google event lives on: the one it is
    /// STAMPED with (`externalConnectionId`, set at INSERT), else the first
    /// connection for a legacy un-stamped block.
    private func googleConnection(for block: CalBlock) -> CalendarConnection? {
        guard let database = db else { return nil }
        if let id = block.externalConnectionId, !id.isEmpty,
           let stamped = (try? database.fetchById(CalendarConnection.self, id: id)) ?? nil {
            return stamped
        }
        return (try? database.firstCalendarConnection()) ?? nil
    }

    /// The Google half of saveBlock — task blocks only (the caller gates).
    /// Stamps `externalConnectionId` with the connection the event was
    /// INSERTED on (the server's /disconnect cleanup and its event-id nulling
    /// select pushed rows by that column — un-stamped rows made both a
    /// no-op), and on a PATCH that answers 404 `event_gone` (deleted in
    /// Google) clears the stale id and falls through to a fresh INSERT.
    private func mirrorBlockToGoogle(_ block: CalBlock) async {
        guard let write = coordinator?.write, let calendar = coordinator?.calendar,
              let conn = googleConnection(for: block) else { return }
        let range = blockToIsoRange(block)
        // Always write task blocks to the user's PRIMARY calendar —
        // selectedCalendarIds can include read-only/subscribed calendars
        // (which 403 on insert). "primary" is Google's alias for the
        // main, always-writable calendar (Android pushBlockUpsert).
        let calId = "primary"
        var next = block
        if let eventId = block.externalEventId {
            do {
                try await calendar.patchEvent(eventId: eventId, connectionId: conn.id, calendarId: calId,
                                              summary: block.taskName, start: range.start, end: range.end)
                // A legacy row pushed before stamping: record the connection now.
                if block.externalConnectionId == nil {
                    next.externalConnectionId = conn.id
                    try? await write.upsertCalBlock(next, nowISO: Self.isoNow())
                }
                return
            } catch CalendarSyncError.eventGone {
                next.externalEventId = nil   // gone in Google → re-create below
            } catch {
                return   // offline / transient: the next save retries the PATCH
            }
        }
        guard let newId = try? await calendar.insertEvent(
            connectionId: conn.id, calendarId: calId,
            summary: block.taskName, start: range.start, end: range.end) else { return }
        next.externalEventId = newId
        next.externalConnectionId = conn.id
        try? await write.upsertCalBlock(next, nowISO: Self.isoNow())
    }

    /// Delete a block locally + on Google (if it was pushed). External g_
    /// blocks never delete the underlying Google event — they only mirror
    /// it (Android pushBlockDelete returns early for EXTERNAL).
    func deleteBlock(_ block: CalBlock) {
        Task { await deleteBlockAwaiting(block) }
    }

    /// The Google half of deleteBlock.
    private func deleteGoogleEvent(for block: CalBlock) async {
        guard let eventId = block.externalEventId, !isExternalBlock(block),
              let calendar = coordinator?.calendar,
              let conn = googleConnection(for: block) else { return }
        // Task blocks are inserted on "primary" — delete there too, on the
        // connection the block is stamped with.
        try? await calendar.deleteEvent(eventId: eventId, connectionId: conn.id, calendarId: "primary")
    }

    /// Move a block to a new day/time (drag-to-reschedule) + bump the task's
    /// moveCount. Pushes the change to Google.
    func moveBlock(_ block: CalBlock, toDate iso: String, startTime: String) {
        var next = block
        next.date = iso
        next.startTime = startTime
        saveBlock(next)
        guard let taskId = block.taskId, isUUID(taskId), let write = coordinator?.write,
              let repo = taskRepo, let task = (try? repo.fetch(id: taskId)) ?? nil else { return }
        // The bump is a WHOLE-ROW upsert, and `saveBlock` un-parks the owning
        // task asynchronously — a bump built from the row as it was BEFORE the
        // un-park raced it and wrote `later: true` straight back (the task then
        // sat on the calendar while every active list filtered it out).
        // Compose the two into ONE payload so either order lands correctly.
        let nowISO = Self.isoNow()
        let owner = unparkedTaskForBlock(next, tasks: [task], nowISO: nowISO) ?? task
        let bumped = bumpMoveCount(owner, nowISO: nowISO)
        Task { try? await write.upsertTask(bumped, nowISO: nowISO) }
    }

    /// Schedule a task into the first free slot on `date` (default today).
    func scheduleTask(_ task: TaskItem, on date: Date = Date()) {
        let blocks = (try? db?.blocks(forTask: task.id)) ?? []
        let iso = Clock.dateISO(date)
        let slots = findFreeSlotsForDate(blocks, durationMin: task.estimateMin, isoDate: iso, now: date, limit: 1)
        scheduleTaskAt(task, date: iso, startTime: slots.first?.startTime ?? "09:00")
    }

    /// Schedule a task at an explicit day + time. Persist-or-move (1:1 with the
    /// Android scheduleTask): reuse/move the task's existing block in place,
    /// bump moveCount only on a real date/time change, and diff recurrence via
    /// regenerateForTask — so re-tapping "Schedule" or dragging an already-
    /// scheduled task doesn't create duplicate blocks or falsely trip the slip
    /// detector. Brand-new tasks (e.g. move-to-task promote) fall through to a
    /// single insert.
    func scheduleTaskAt(_ task: TaskItem, date iso: String, startTime: String) {
        guard let write = coordinator?.write else { return }
        let existing = ((try? db?.blocks(forTask: task.id)) ?? []).filter { isTaskBlock($0) }
        let now = Self.isoNow()

        func earliest(_ blocks: [CalBlock]) -> CalBlock? {
            blocks.min { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
        }

        if let recurrence = task.recurrence {
            let parts = iso.split(separator: "-").compactMap { Int($0) }
            let startDate = parts.count == 3 ? Time.civil(parts[0], parts[1], parts[2]) : Date()
            let plan = regenerateForTask(task: task, recurrence: recurrence, existingBlocks: existing,
                                         todayIso: Clock.todayISO(), startTime: startTime, startDate: startDate)
            Task {
                for id in plan.toDelete { try? await write.deleteCalBlock(id: id, nowISO: now) }
                for b in plan.toUpsert { try? await write.upsertCalBlock(b, nowISO: now) }
            }
            // Guarantee the chosen slot is materialized (the horizon regen skips
            // today / off-pattern picks). Only when nothing already covers it —
            // computed POST-plan by the pure helper (an existing block the regen
            // is about to DELETE doesn't count, or the task would vanish from the
            // day just scheduled).
            let coversChosen = recurrenceCoversChosenDate(existing: existing, plan: plan, iso: iso)
            if !coversChosen {
                saveBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name,
                                   startTime: startTime, durationMinutes: task.estimateMin, date: iso, kind: .task))
            }
            if let anchor = earliest(existing), anchor.date != iso || anchor.startTime != startTime {
                let bumped = bumpMoveCount(task, nowISO: now)
                Task { try? await write.upsertTask(bumped, nowISO: now) }
            }
        } else if let cur = earliest(existing) {
            if cur.date != iso || cur.startTime != startTime {
                var moved = cur
                moved.date = iso
                moved.startTime = startTime
                saveBlock(moved)   // moves the Google event too (PATCH) when pushed
                // Compose the un-park into the bump: the bump is a whole-row
                // upsert and `saveBlock` un-parks asynchronously, so a bump
                // built from the pre-un-park row raced it and wrote
                // `later: true` back over the freshly-scheduled task.
                let owner = unparkedTaskForBlock(moved, tasks: [task], nowISO: now) ?? task
                let bumped = bumpMoveCount(owner, nowISO: now)
                Task { try? await write.upsertTask(bumped, nowISO: now) }
            }
        } else {
            saveBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name,
                               startTime: startTime, durationMinutes: task.estimateMin, date: iso, kind: .task))
        }
    }

    /// Manual "Sync now" pull — the reconciled [-7d, +30d] Google pull
    /// (own-event + all-day filters, deletion reconcile) lives on the
    /// coordinator, which also runs it from the sign-in pipeline + syncNow.
    /// An EXPLICIT pull ("Sync now", the post-connect refresh): forget the
    /// last verdict + any 429 back-off first — a fresh consent must clear
    /// "Reconnect Google" as soon as the server's `needs_reauth` is clear (the
    /// pull re-reads the flag, so a still-dead token simply re-flags itself).
    /// False = Google / the server could not be read, so the bar says so
    /// instead of ending silently (audit 2026-09-22, C18).
    @discardableResult
    func pullGoogleCalendar() async -> Bool {
        guard let coord = coordinator else { return false }
        await coord.resetCalendarStatus()
        calendarSyncStatus = nil
        let ok = await coord.pullCalendar()
        // Read the verdict now rather than waiting for the status hook's hop to
        // the main actor: the bar's caption keys a 429 off `backoffUntil`.
        calendarSyncStatus = await coord.calendarStatus
        return ok
    }

    func saveSession(_ session: Session) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertSession(session, nowISO: now) }
    }

    func saveReasonLog(_ log: ReasonLog) {
        guard let write = coordinator?.write else { return }
        let now = Self.isoNow()
        Task { try? await write.upsertReasonLog(log, nowISO: now) }
    }

    func saveCapture(_ capture: Capture) {
        Task { await saveCaptureAwaiting(capture) }
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: config

    static func loadConfig() -> SyncConfig? {
        let info = Bundle.main.infoDictionary
        guard let host = info?["SUPABASE_HOST"] as? String, !host.isEmpty,
              let key = info?["SUPABASE_ANON_KEY"] as? String, !key.isEmpty,
              let url = URL(string: "https://\(host)"),
              let redirect = URL(string: "unstuck://auth-callback")
        else { return nil }
        return SyncConfig(url: url, anonKey: key, authRedirectURL: redirect)
    }

    static func databasePath() -> String {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unstuck.sqlite").path
    }
}

// MARK: - deadline helper

private struct DeadlineExceeded: Error {}

/// Race `op` against a deadline; the loser is cancelled. For the sign-in reads
/// that gate UI (the interview flag) so a hung request can't hold a
/// "hydrated" flip hostage.
private func withDeadline<T: Sendable>(seconds: Double,
                                       _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}
