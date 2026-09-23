import BackgroundTasks
import SwiftUI
import UnstuckDesign

// BackgroundSync — BGAppRefreshTask registration + scheduling (spec
// 02-sync-engine §5: the iOS analog of Android's 30-min SyncWorker).
// iOS gives no guaranteed cadence — this is best-effort; the scenePhase
// .active trigger below covers the common path. The handler runs
// `perform` (syncNow + widget snapshot refresh, wired by AppModel) and
// chains the next refresh request.
enum BackgroundSync {
    static let taskId = "io.unstucknow.app.refresh"

    /// Wired by AppModel once the coordinator exists (flush + hydrate +
    /// widget refresh). Nil until then — the handler just completes.
    @MainActor static var perform: (@Sendable () async -> Void)?

    /// Must be called before the app finishes launching
    /// (PushAppDelegate.didFinishLaunching).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    /// Queue the next refresh — called when the app enters the background.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)   // Android parity: 30-min cadence (best-effort)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// BGTask isn't Sendable, but setTaskCompleted is documented safe to
    /// call from any thread — box it so Swift 6 region isolation lets the
    /// completion task carry it across.
    private struct CompletionBox: @unchecked Sendable {
        let task: BGAppRefreshTask
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // chain the next refresh
        let work = Task { @MainActor in
            await perform?()
        }
        task.expirationHandler = { work.cancel() }
        let box = CompletionBox(task: task)
        Task {
            await work.value
            box.task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}

/// Shifts the system DynamicTypeSize by N steps (density: ±1, larger type:
/// +2). Every app font is `Font.custom(_:size:)`, which scales relative to
/// body, so the shift rescales all text. Positive shifts cap at xxxLarge —
/// the accessibility sizes stay reserved for the SYSTEM setting (which we
/// never reduce).
private struct TypeScale: ViewModifier {
    @Environment(\.dynamicTypeSize) private var system
    let steps: Int

    func body(content: Content) -> some View {
        content.dynamicTypeSize(shifted)
    }

    private var shifted: DynamicTypeSize {
        guard steps != 0 else { return system }
        let all = Array(DynamicTypeSize.allCases)
        guard let i = all.firstIndex(of: system) else { return system }
        let cap = all.firstIndex(of: .xxxLarge) ?? all.count - 1
        let j = steps > 0 ? min(i + steps, max(cap, i)) : max(i + steps, 0)
        return all[j]
    }
}

@main
struct UnstuckApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// The shared instance: a VoIP push that launches the app with no scene
    /// starts THIS model (CallCoordinator.bootApp → startWithoutScene), so the
    /// store, sync engine and call wiring it built are the ones shown when a
    /// scene connects; the .task below then finds start() done (audit
    /// 2026-09-22, C16).
    @State private var model = AppModel.shared

    init() {
        // Arm the crash/hang trail before anything else runs, so a fault during
        // launch is recorded too (App/Diagnostics/CrashBreadcrumbs.swift).
        CrashBreadcrumbs.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Theme override (Settings · Interface): system=nil follows the
                // OS, light/dark force the scheme. This flows into colorScheme
                // and thus unstuckTheme()'s palette resolution below.
                .preferredColorScheme(model.settings.theme.colorScheme)
                .unstuckTheme(accent: model.settings.accent)
                // Density + larger-type (Settings · Interface/Accessibility):
                // shift DynamicTypeSize relative to the system size, the iOS
                // analogue of Android's fontScale multiplier.
                .modifier(TypeScale(steps: model.settings.typeStepShift))
                .onOpenURL { model.handleDeepLink($0) }
                // Universal Links (https invite link) arrive as a browsing-web
                // user activity, NOT onOpenURL — route its URL through the same
                // handler so unstucknow.io/circle/join opens + redeems in-app.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handleDeepLink(url) }
                }
                .task {
                    #if DEBUG
                    // Diagnostics self-test: the ONLY way to regression-test a
                    // crash reporter is to crash. `UITEST_FORCE_CRASH=signal|
                    // exception` faults ~2s after launch; the next launch must
                    // find the trail with a fault line in it. DEBUG only.
                    if let kind = ProcessInfo.processInfo.environment["UITEST_FORCE_CRASH"] {
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            CrashBreadcrumbs.drop("forcing crash \(kind)")
                            if kind == "exception" {
                                NSException(name: .genericException, reason: "forced diagnostics self-test", userInfo: nil).raise()
                            } else {
                                raise(SIGSEGV)
                            }
                        }
                    }
                    if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" {
                        model.startUITestMode()
                        return
                    }
                    #endif
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Foreground sync (spec 02-sync-engine §5): flush queued
                    // offline edits + hydrate whenever the app returns to the
                    // foreground; queue the next BG refresh on exit.
                    if phase == .active {
                        // Merge any Siri-queued hands-free writes into the outbox
                        // BEFORE syncNow so they flush on this same foreground.
                        model.drainSiriWriteQueue()
                        model.syncNow()
                        // Start the ~60s foreground safety-net pull: realtime can
                        // silently drop while the app stays continuously
                        // foregrounded — the periodic hydrate is the backstop.
                        model.startForegroundSafetyNet()
                        // Reap any focus Live Activity orphaned by a kill/crash
                        // mid-session (rebinds to a still-live session, else
                        // ends the ghost timer).
                        model.reapStaleLiveActivities()
                        // Consume any route a Siri "open the app" intent stashed
                        // (Add task / Capture / Start focus / Open today). No-ops
                        // until repos exist — start() consumes it on cold launch.
                        model.consumePendingSiriRoute()
                        // Calls booked on the web / Android / by the server
                        // ring here too: ask for the microphone while the app
                        // is in front of them (audit 2026-09-22, C13).
                        model.askForCallMicrophoneIfNeeded()
                    }
                    // Stop the safety-net pull whenever we leave the foreground
                    // (it restarts on the next .active).
                    if phase == .inactive || phase == .background {
                        model.stopForegroundSafetyNet()
                    }
                    if phase == .background {
                        // Push the outbox now, inside background time: the
                        // post-write debounce alone was suspended with the
                        // app, so an edit made just before locking waited for
                        // the next open (audit 2026-09-22, C31).
                        model.flushOnBackground()
                        BackgroundSync.schedule()
                        // A RUNNING guided tour checkpoints { paused, index,
                        // mode } now, so a jetsam kill relaunches into the
                        // resume card instead of losing the run. Reads the
                        // lazy backing — never *constructs* the tour here.
                        model._tour?.appDidEnterBackground()
                        // Capture the latest in-session state into the App-Group
                        // snapshot NOW, so a hands-free Siri query right after
                        // backgrounding reflects what the user just did.
                        model.refreshWidgetSnapshot()
                    }
                }
        }
    }
}
