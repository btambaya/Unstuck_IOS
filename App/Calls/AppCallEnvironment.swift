// Production implementations of the CallCoordinator seams that touch the
// app: the read-only CallEnvironment over AppModel, the UNUserNotification
// notifier, the call-outcome reporter (persisted queue, in-order, retried),
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
/// "anchor is live" for the stale rule (ring rather than silently drop), the
/// UserDefaults-backed call hours, and — for "signed in" — whether this
/// device still holds a VoIP registration (sign-out wipes it via
/// VoipPushRegistry.unregisterBestEffort, so a queued call that lands after
/// a sign-out is dropped instead of ringing with the old account's notes).
@MainActor
final class AppCallEnvironment: CallEnvironment {
    private weak var model: AppModel?

    init(model: AppModel?) { self.model = model }

    var isSignedIn: Bool {
        if let m = model { return m.signedIn }
        return VoipPushRegistry.storedToken != nil
    }

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

/// call-outcome reporter. A lost `missed` / `snoozed` / `done` would leave the
/// server row in `calling` forever (the cron never re-rings it), so:
///   • every report is PERSISTED (UserDefaults JSON) the moment it's queued —
///     a killed-state launch that reports before AppModel attaches a client,
///     or an app killed mid-retry, replays it on the next attach;
///   • the queue flushes IN ORDER (answered before done, never the reverse),
///     one send at a time;
///   • each item gets `maxAttempts` (3) tries with `backoff` (2 s, 5 s)
///     between them; after the last failure it stays at the head of the queue
///     (re-enqueued, not dropped) and the flush retries after `retryLater`
///     (15 s, then 30 / 60 / 120 s per consecutive failed cycle), on the next
///     report, or on the next attach.
/// Injectable sleep + sender so the ordering / retry / persistence rules run
/// in XCTest without a network (CallCoordinatorTests).
@MainActor
final class CallsOutcomeReporter: CallOutcomeReporting {
    struct Item: Codable, Equatable {
        let callId: String
        let callKitId: String?
        let outcome: CallOutcome
        let snooze: Int?
        let notes: [String]?
    }
    typealias Sender = @Sendable (Item) async throws -> Void

    static let queueKey = "unstuck.calls.outcomeQueue"
    static let maxAttempts = 3
    /// Between the attempts of one cycle.
    static let backoff: [TimeInterval] = [2, 5]
    /// Before the next cycle, per consecutive failed cycle (capped at the last).
    static let retryLater: [TimeInterval] = [15, 30, 60, 120]

    private let defaults: UserDefaults
    private let key: String
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var send: Sender?
    private(set) var queue: [Item] = []
    private(set) var flushTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var failedCycles = 0

    init(defaults: UserDefaults = .standard, key: String = CallsOutcomeReporter.queueKey,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
             try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
         }) {
        self.defaults = defaults
        self.key = key
        self.sleep = sleep
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            queue = saved
        }
    }

    func attach(client: CallsClient) {
        attach(send: { item in
            try await client.outcome(callId: item.callId, outcome: item.outcome, snoozeMinutes: item.snooze,
                                     outcomeNotes: item.notes, callKitId: item.callKitId)
        })
    }

    /// Bind the sender (tests: a recorder). Flushes whatever is queued.
    func attach(send: @escaping Sender) {
        self.send = send
        flush()
    }

    func report(callId: String, callKitId: UUID?, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?) {
        queue.append(Item(callId: callId, callKitId: callKitId?.uuidString.lowercased(), outcome: outcome,
                          snooze: snoozeMinutes, notes: outcomeNotes))
        persist()
        flush()
    }

    private func persist() {
        if queue.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: key)
        }
    }

    /// One flush at a time; a flush already running picks up items appended
    /// meanwhile (it re-reads `queue.first` each round).
    private func flush() {
        guard send != nil, flushTask == nil, !queue.isEmpty else { return }
        retryTimer?.cancel(); retryTimer = nil
        flushTask = Task { [weak self] in
            await self?.drain()
            self?.flushTask = nil
        }
    }

    private func drain() async {
        while let head = queue.first, let send {
            var sent = false
            for attempt in 0..<Self.maxAttempts {
                do {
                    try await send(head)
                    sent = true
                    break
                } catch {
                    if attempt + 1 < Self.maxAttempts {
                        await sleep(Self.backoff[min(attempt, Self.backoff.count - 1)])
                    }
                }
            }
            if Task.isCancelled { return }
            guard sent else {
                // Re-enqueued (still at the head, persisted). Try again later.
                scheduleRetry()
                return
            }
            failedCycles = 0
            if queue.first == head { queue.removeFirst() }
            persist()
        }
    }

    private func scheduleRetry() {
        retryTimer?.cancel()
        let delay = Self.retryLater[min(failedCycles, Self.retryLater.count - 1)]
        failedCycles += 1
        retryTimer = Task { [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.retryTimer = nil
            self?.flush()
        }
    }
}

extension CallCoordinator {
    /// The single AppModel.start() hook: bind the live environment + the calls
    /// client, re-arm PushKit (a previous sign-out may have unregistered it),
    /// and make sure the VoIP token reaches register-push-token even when
    /// there's no APNs token (notification permission denied) — PushClient
    /// treats an empty apnsToken as "none" and rides the VoIP token along.
    func attach(model: AppModel, client: CallsClient) {
        attachedModel = model
        attach(environment: AppCallEnvironment(model: model))
        attach(client: client)
        PushRegistrar.shared.onVoipToken = { [weak model] _ in
            model?.registerPush(PushRegistrar.shared.apnsTokenHex ?? "")
        }
        if model.signedIn { VoipPushRegistry.shared.rearm() }
        if PushRegistrar.shared.voipTokenHex != nil, PushRegistrar.shared.apnsTokenHex == nil {
            model.registerPush("")
        }
    }
}
