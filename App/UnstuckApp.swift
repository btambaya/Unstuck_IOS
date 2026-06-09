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
    static let taskId = "tech.csalliance.unstuck.refresh"

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

@main
struct UnstuckApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .unstuckTheme()
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
                    if phase == .active { model.syncNow() }
                    if phase == .background { BackgroundSync.schedule() }
                }
        }
    }
}
