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
/// That proxy is only good enough for the VoIP path: `isSessionKnown` tells
/// the coordinator when it is the real session, so the alert-tap fallback
/// (which runs exactly when there is NO VoIP token) waits for AppModel
/// instead of dropping the tap.
@MainActor
final class AppCallEnvironment: CallEnvironment {
    private weak var model: AppModel?

    init(model: AppModel?) { self.model = model }

    var isSignedIn: Bool {
        if let m = model { return m.signedIn }
        return VoipPushRegistry.storedToken != nil
    }

    var isSessionKnown: Bool { model != nil }

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

    var isCallsEnabled: Bool { CallSettings.enabled }
}

/// Posts the coordinator's notifications through UNUserNotificationCenter.
@MainActor
final class SystemCallNotifier: CallNotifier {
    func post(_ n: CallNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = n.quiet ? nil : .default
        content.threadIdentifier = n.threadId
        if let cat = n.categoryId { content.categoryIdentifier = cat }
        content.userInfo = n.userInfo
        content.interruptionLevel = n.quiet ? .passive : (n.timeSensitive ? .timeSensitive : .active)
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
///     between them; after the last TRANSIENT failure it stays at the head of
///     the queue (re-enqueued, not dropped) and the flush retries after
///     `retryLater` (15 s, then 30 / 60 / 120 s per consecutive failed
///     cycle), on the next report, or on the next attach;
///   • a PERMANENT refusal (`CallOutcomeRejected` — 404 the row is gone /
///     not the caller's, 400 / 422 malformed) drops THAT item at once and the
///     drain continues: one dead report must never block every later
///     `missed` / `snoozed` / `done` behind it forever (`dropped` keeps the
///     tally for diagnostics);
///   • sign-out discards the queue (`discardAll`) — nothing left in it can be
///     sent with the next account's JWT;
///   • a `missed` report carries the "I called about X" notification with it
///     (persisted too): it is posted through `notifier` when the server takes
///     the report and answers `retry: false`, or refuses it for good (no
///     re-ring is coming either way) — and swallowed on `retry: true`, the
///     server's one automatic ring-back 5 min later (calls build-out §5).
///     The flag arrives asynchronously, so the coordinator never posts it at
///     the 30 s timeout itself.
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
        /// Posted once the server answers without `retry` (see above).
        var notification: CallNotification?

        init(callId: String, callKitId: String?, outcome: CallOutcome, snooze: Int?, notes: [String]?,
             notification: CallNotification? = nil) {
            self.callId = callId; self.callKitId = callKitId; self.outcome = outcome
            self.snooze = snooze; self.notes = notes; self.notification = notification
        }

        enum CodingKeys: String, CodingKey { case callId, callKitId, outcome, snooze, notes, notification }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            callId = try c.decode(String.self, forKey: .callId)
            callKitId = try c.decodeIfPresent(String.self, forKey: .callKitId)
            outcome = try c.decode(CallOutcome.self, forKey: .outcome)
            snooze = try c.decodeIfPresent(Int.self, forKey: .snooze)
            notes = try c.decodeIfPresent([String].self, forKey: .notes)
            notification = try c.decodeIfPresent(CallNotification.self, forKey: .notification)
        }
    }
    /// Sends one report; returns what the server answered (`retry`).
    typealias Sender = @Sendable (Item) async throws -> CallOutcomeReceipt

    static let queueKey = "unstuck.calls.outcomeQueue"
    static let maxAttempts = 3
    /// Between the attempts of one cycle.
    static let backoff: [TimeInterval] = [2, 5]
    /// Before the next cycle, per consecutive failed cycle (capped at the last).
    static let retryLater: [TimeInterval] = [15, 30, 60, 120]

    private let defaults: UserDefaults
    private let key: String
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// Posts a report's `notification` once the server has settled it.
    private let notifier: CallNotifier?
    private var send: Sender?
    private(set) var queue: [Item] = []
    private(set) var flushTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var failedCycles = 0
    /// Items the server refused for good (logged, never retried).
    private(set) var dropped: [(item: Item, error: Error)] = []

    init(defaults: UserDefaults = .standard, key: String = CallsOutcomeReporter.queueKey,
         notifier: CallNotifier? = nil,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
             try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
         }) {
        self.defaults = defaults
        self.key = key
        self.notifier = notifier
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

    func report(callId: String, callKitId: UUID?, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?,
                notifyUnlessRetry: CallNotification?) {
        queue.append(Item(callId: callId, callKitId: callKitId?.uuidString.lowercased(), outcome: outcome,
                          snooze: snoozeMinutes, notes: outcomeNotes, notification: notifyUnlessRetry))
        persist()
        flush()
    }

    /// Sign-out: forget everything queued (memory + disk) and stop retrying.
    /// A drain in flight finishes its current send and finds nothing left.
    func discardAll() {
        retryTimer?.cancel(); retryTimer = nil
        failedCycles = 0
        queue.removeAll()
        persist()
    }

    /// A refusal that no retry can fix (see `CallOutcomeRejected`).
    static func isPermanent(_ error: Error) -> Bool {
        error is CallOutcomeRejected
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
            var receipt = CallOutcomeReceipt()
            var rejected: Error?
            for attempt in 0..<Self.maxAttempts {
                do {
                    receipt = try await send(head)
                    sent = true
                    break
                } catch {
                    if Self.isPermanent(error) {
                        rejected = error
                        break
                    }
                    if attempt + 1 < Self.maxAttempts {
                        await sleep(Self.backoff[min(attempt, Self.backoff.count - 1)])
                    }
                }
            }
            if Task.isCancelled { return }
            if let rejected {
                // The server will answer the same way forever: drop this item
                // (logged) and carry on with the ones behind it. No re-ring is
                // coming for a row the server won't take a report on, so the
                // miss notification (if any) still goes out.
                dropped.append((head, rejected))
                NSLog("[calls] outcome %@ for %@ rejected for good: %@ — dropped",
                      head.outcome.rawValue, head.callId, String(describing: rejected))
                settleNotification(head, retry: false)
            } else {
                guard sent else {
                    // Re-enqueued (still at the head, persisted). Try again later.
                    scheduleRetry()
                    return
                }
                failedCycles = 0
                settleNotification(head, retry: receipt.retry)
            }
            if queue.first == head { queue.removeFirst() }
            persist()
        }
    }

    /// The server settled a report: post its notification unless a retry
    /// ring is coming. Pure decision (`shouldNotify`), tested.
    private func settleNotification(_ item: Item, retry: Bool) {
        guard let n = item.notification, Self.shouldNotify(retry: retry) else { return }
        notifier?.post(n)
    }

    /// `retry: true` ⇒ the server rings again in 5 min ⇒ stay quiet.
    static func shouldNotify(retry: Bool) -> Bool { !retry }

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
    /// keep re-arming it on every LATER sign-in within this launch (sign-out →
    /// sign-in without a relaunch used to leave the device with no VoIP
    /// registration, so every call degraded to the alert banner), and make
    /// sure the VoIP token reaches register-push-token even when there's no
    /// APNs token (notification permission denied) — PushClient treats an
    /// empty apnsToken as "none" and rides the VoIP token along.
    func attach(model: AppModel, client: CallsClient) {
        attachedModel = model
        attach(environment: AppCallEnvironment(model: model))
        attach(client: client)
        PushRegistrar.shared.onVoipToken = { [weak model] _ in
            model?.registerPush(PushRegistrar.shared.apnsTokenHex ?? "")
        }
        if model.signedIn { signedIn() }
        if PushRegistrar.shared.voipTokenHex != nil, PushRegistrar.shared.apnsTokenHex == nil {
            model.registerPush("")
        }
        // Every transition to authenticated from here on re-arms PushKit; the
        // fresh token then rides up through onVoipToken → registerPush, so
        // the recreated device_tokens row carries voip_token for the NEW user.
        authWatch?.cancel()
        guard let auth = model.coordinator?.auth else { return }
        authWatch = Task { [weak self] in
            for await (event, session) in auth.authStateChanges {
                guard session != nil, case .signedIn = event else { continue }
                await MainActor.run { self?.signedIn() }
            }
        }
    }
}
