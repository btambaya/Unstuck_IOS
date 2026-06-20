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
    @State private var model = AppModel()

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
                .task {
                    #if DEBUG
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
                        model.syncNow()
                        // Reap any focus Live Activity orphaned by a kill/crash
                        // mid-session (rebinds to a still-live session, else
                        // ends the ghost timer).
                        model.reapStaleLiveActivities()
                    }
                    if phase == .background { BackgroundSync.schedule() }
                }
        }
    }
}
