// Production implementations of the CallCoordinator seams that touch the
// app: the read-only CallEnvironment over AppModel, the UNUserNotification
// notifier, the call-outcome reporter (buffers until a client is attached),
// and the one-line AppModel hook `CallCoordinator.attach(model:client:)`.

import ActivityKit
import Foundation
import UnstuckCore
import UnstuckShared
import UnstuckSync
import UserNotifications

/// Reads focus/anchor state from AppModel when it's up. Before AppModel is
/// attached (a killed-state VoIP launch) it falls back to the only signals
/// that exist without the store: the focus Live Activity for "mid-focus",
/// "anchor is live" for the stale rule (ring rather than silently drop), and
/// the UserDefaults-backed call hours.
@MainActor
final class AppCallEnvironment: CallEnvironment {
    private weak var model: AppModel?

    init(model: AppModel?) { self.model = model }

    var isFocusSessionLive: Bool {
        if let m = model { return m.liveSession?.sessionStart != nil }
        return !Activity<FocusSessionAttributes>.activities.isEmpty
    }

    func anchorIsLive(taskId: String?, blockId: String?) -> Bool {
        guard let taskId else { return true }
        guard let m = model, let repo = m.taskRepo else { return true }   // no store yet → ring
        guard let task = (try? repo.fetch(id: taskId)) ?? nil else { return false }
        if task.done { return false }
        guard let blockId else { return true }
        let blocks = (try? m.db?.blocks(forTask: taskId)) ?? []
        guard let block = blocks.first(where: { $0.id == blockId }) else { return false }
        return !block.done && !block.skipped
    }

    func isWithinCallHours(_ date: Date) -> Bool { CallSettings.isWithinWindow(date) }
}

/// Posts the coordinator's notifications through UNUserNotificationCenter.
@MainActor
final class SystemCallNotifier: CallNotifier {
    func post(_ n: CallNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.threadIdentifier = n.threadId
        if let cat = n.categoryId { content.categoryIdentifier = cat }
        content.userInfo = n.userInfo
        content.interruptionLevel = n.timeSensitive ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }
}

/// call-outcome reporter. Reports are queued until a CallsClient is attached
/// (killed-state launch → AppModel.start attaches one moments later) and each
/// send gets one retry, since a lost `missed`/`snoozed` would leave the server
/// row in `calling` forever.
@MainActor
final class CallsOutcomeReporter: CallOutcomeReporting {
    private struct Item { let callId: String; let outcome: CallOutcome; let snooze: Int?; let notes: [String]? }
    private var client: CallsClient?
    private var queue: [Item] = []

    func attach(client: CallsClient) {
        self.client = client
        flush()
    }

    func report(callId: String, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?) {
        queue.append(Item(callId: callId, outcome: outcome, snooze: snoozeMinutes, notes: outcomeNotes))
        flush()
    }

    private func flush() {
        guard let client else { return }
        let items = queue
        queue = []
        for i in items {
            Task {
                do {
                    try await client.outcome(callId: i.callId, outcome: i.outcome,
                                             snoozeMinutes: i.snooze, outcomeNotes: i.notes)
                } catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    try? await client.outcome(callId: i.callId, outcome: i.outcome,
                                              snoozeMinutes: i.snooze, outcomeNotes: i.notes)
                }
            }
        }
    }
}

extension CallCoordinator {
    /// The single AppModel.start() hook: bind the live environment + the calls
    /// client, and make sure the VoIP token reaches register-push-token even
    /// when there's no APNs token (notification permission denied) — PushClient
    /// treats an empty apnsToken as "none" and rides the VoIP token along.
    func attach(model: AppModel, client: CallsClient) {
        attachedModel = model
        attach(environment: AppCallEnvironment(model: model))
        attach(client: client)
        PushRegistrar.shared.onVoipToken = { [weak model] _ in
            model?.registerPush(PushRegistrar.shared.apnsTokenHex ?? "")
        }
        if PushRegistrar.shared.voipTokenHex != nil, PushRegistrar.shared.apnsTokenHex == nil {
            model.registerPush("")
        }
    }
}
