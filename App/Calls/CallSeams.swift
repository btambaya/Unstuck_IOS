// The seams the CallCoordinator is built on, so the state machine runs in
// XCTest without CallKit / PushKit / AVFoundation / the network:
//
//   CallVoiceLauncher   — starts/stops the live conversation (VoiceRealtimeClient
//                         + VoiceAudioEngine) once CallKit has activated audio.
//                         Implemented by the integrator; NoopCallVoiceLauncher
//                         ships as the default so the path compiles + degrades.
//   CallEnvironment     — read-only app facts the receipt rules need (is a focus
//                         session live? is the anchor still live? call hours).
//   CallNotifier        — posts the "I called about …" local notifications.
//   CallOutcomeReporting— reports end states to call-outcome (CallsClient).
//   CallProviding / CallControlling — the CXProvider / CXCallController surface
//                         the coordinator touches (CallKitBridge adapts them).
//   CallClock           — now + one-shot timers (30 s ring, launcher grace).

import Foundation
import UnstuckSync

/// Why a live conversation ended, as the launcher reports it.
enum CallEndReason: Equatable, Sendable {
    /// The user (or the model saying goodbye) ended it normally.
    case hungUp
    /// "Call me back in N" — handled locally: outcome `snoozed` + snoozeMinutes.
    case snoozed(minutes: Int)
    /// Voice couldn't start or dropped (socket, proxy, mic) — the user still
    /// gets the notes as a notification.
    case failed(String)
}

/// How the coordinator tells CallKit a call ended (maps 1:1 onto
/// CXCallEndedReason in the bridge; kept CallKit-free for tests).
enum CallEndedReason: Equatable, Sendable {
    case failed, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
}

/// Starts the live conversation for an answered call.
///
/// CONTRACT (the classic silent-call bug lives here):
/// - `start` is invoked ONLY after CallKit's `provider(_:didActivate:)` — the
///   AVAudioSession is ALREADY active with category .playAndRecord / mode
///   .voiceChat. The launcher MUST NOT call `AVAudioSession.setActive(true)`
///   (or change the category) and MUST NOT deactivate it on `stop()` — CallKit
///   owns activation; the coordinator observes `didDeactivate`.
/// - `onEnded` is called at most once, on the main actor, when the conversation
///   ends on its own (socket dropped, the model snoozed, goodbye). The
///   coordinator then asks CallKit to end the call and reports the outcome.
///   After `stop()` the launcher must NOT call `onEnded`.
/// - `setMuted` mirrors the CallKit mute button into the mic upload.
@MainActor
protocol CallVoiceLauncher: AnyObject {
    func start(_ session: CallSession, onEnded: @escaping @MainActor (CallEndReason) -> Void)
    func stop()
    func setMuted(_ muted: Bool)
}

extension CallVoiceLauncher {
    func setMuted(_ muted: Bool) {}
}

/// Default launcher until the voice layer is wired: ends the conversation at
/// once as `.failed`, so an answered call degrades into the "here's what it
/// was about" notification instead of dead air.
@MainActor
final class NoopCallVoiceLauncher: CallVoiceLauncher {
    func start(_ session: CallSession, onEnded: @escaping @MainActor (CallEndReason) -> Void) {
        onEnded(.failed("voice launcher not installed"))
    }
    func stop() {}
}

/// Read-only app facts for the receipt rules. Every member must be cheap and
/// synchronous — it's consulted right after `reportNewIncomingCall`, possibly
/// on a killed-state launch before AppModel exists (see AppCallEnvironment).
@MainActor
protocol CallEnvironment: AnyObject {
    /// Someone is signed in on this device. A call that arrives with NO session
    /// (a reactive sign-out left the VoIP token registered and the server still
    /// had a queued call) is dropped at once as `.failed` — no ring, no
    /// notification, no notes from the previous account.
    var isSignedIn: Bool { get }
    /// Whether `isSignedIn` is the REAL session (AppModel attached) or the
    /// killed-state proxy (a VoIP registration exists). The VoIP path can act
    /// on the proxy; the alert-tap fallback (transport B — used exactly when
    /// there is NO VoIP token) must not, and waits for the real answer.
    var isSessionKnown: Bool { get }
    /// A focus session is live (started, paused or not) → the call ends as `busy`.
    var isFocusSessionLive: Bool { get }
    /// The task/block the call anchors to still stands. `nil` taskId → true.
    /// Task done/deleted, or block done/skipped/gone → false (→ `stale`).
    func anchorIsLive(taskId: String?, blockId: String?) -> Bool
    /// The user's own allowed-hours guard (Settings → Calls from Unstuck).
    func isWithinCallHours(_ date: Date) -> Bool
}

extension CallEnvironment {
    var isSessionKnown: Bool { true }
}

/// A local notification the coordinator wants posted.
struct CallNotification: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var categoryId: String?
    var threadId: String
    var userInfo: [String: String]
    var timeSensitive: Bool
}

@MainActor
protocol CallNotifier: AnyObject {
    func post(_ n: CallNotification)
}

@MainActor
protocol CallOutcomeReporting: AnyObject {
    /// `callKitId` is the CXCall UUID the phone presented (CallSession.uuid);
    /// the server stores it on the row (`call_id`) for cross-referencing.
    func report(callId: String, callKitId: UUID?, outcome: CallOutcome, snoozeMinutes: Int?, outcomeNotes: [String]?)
    /// Late-bind the network client (a killed-state launch reports before the
    /// coordinator has one — implementations buffer + flush).
    func attach(client: CallsClient)
    /// The account signed out: whatever is still queued belongs to a session
    /// that no longer exists (no JWT to send it with; the next account's
    /// server would answer not_found) — forget it, on disk too.
    func discardAll()
}

extension CallOutcomeReporting {
    func attach(client: CallsClient) {}
    func discardAll() {}
}

/// The CXProvider surface the coordinator uses.
@MainActor
protocol CallProviding: AnyObject {
    /// `reportNewIncomingCall` — MUST be called synchronously on receipt.
    func reportIncoming(uuid: UUID, callerName: String, completion: @escaping @MainActor (Error?) -> Void)
    /// `reportCall(with:endedAt:reason:)`.
    func reportEnded(uuid: UUID, reason: CallEndedReason)
    /// Configure (never activate) the AVAudioSession for a voice call.
    func configureAudioSession()
}

/// The CXCallController surface: request that CallKit end our call (→ the
/// provider delegate's CXEndCallAction → `performEnd`).
@MainActor
protocol CallControlling: AnyObject {
    func requestEnd(uuid: UUID, completion: @escaping @MainActor (Error?) -> Void)
}

@MainActor
protocol CallTimer: AnyObject {
    func cancel()
}

@MainActor
protocol CallClock: AnyObject {
    var now: Date { get }
    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> CallTimer
}

/// Task-backed one-shot timer (the production CallClock).
@MainActor
final class SystemCallClock: CallClock {
    final class Handle: CallTimer {
        private var task: Task<Void, Never>?
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task?.cancel(); task = nil }
    }
    var now: Date { Date() }
    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) -> CallTimer {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if !Task.isCancelled { block() }
        }
        return Handle(task)
    }
}
