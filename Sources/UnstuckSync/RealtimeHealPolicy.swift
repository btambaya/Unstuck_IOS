// RealtimeHealPolicy — when a set of realtime channels must be rebuilt, and how
// soon a rebuild may run again (audit 2026-09-22, C30). Shared by
// RealtimeMirror and CollabRealtime; pure, so the rules are tested without a
// socket.
//
// supabase-swift 2.46 brings a channel back in exactly one shape: a socket that
// was `.connected` errors, the SDK reconnects and runs `rejoinChannels()`.
// Every other shape left our channels dead for the rest of the process:
//  • an OFFLINE launch — `connect()` fails, every subscribe exhausts its
//    retries and ends `.unsubscribed`, and nothing connects the socket again;
//  • a socket that DROPPED and came back — a drop does not reset channel
//    state, so each channel still reads `.subscribed` and the SDK's rejoin
//    (`subscribeWithError`) no-ops on it: no fresh `phx_join` reaches the new
//    socket (CoFocusPresenceClient documents the same trap);
//  • a remote close — the socket parks at `.disconnected` and the SDK never
//    reconnects it.
// So the channel owner rebuilds (fresh instances, fresh joins) when one of
// those holds, on a reconnect and on the freshness owner's triggers (network
// back, foreground, the floor tick) — with a growing gap between rebuilds that
// don't bring the set live, so a persistent failure can't churn joins.

import Foundation
import Supabase

public struct RealtimeHealPolicy: Sendable, Equatable {
    /// Rebuilds since the set was last seen live.
    public private(set) var failedHeals = 0
    public private(set) var lastHealAt: Date?

    /// Never two rebuilds closer than this, whatever triggered them.
    public static let minSpacing: TimeInterval = 5
    /// The longest a dead set waits between rebuilds.
    public static let maxBackoff: TimeInterval = 300

    public init() {}

    /// True when the channels can't be delivering and only a rebuild brings
    /// them back. `channels` is every channel of the set, read through
    /// `effectiveStatus` (an empty set counts as dead). A connect already in
    /// flight is left to finish: its `.connected` is observed and re-asks.
    public static func needsRebuild(socket: RealtimeClientStatus, channels: [RealtimeChannelStatus],
                                    droppedSinceJoin: Bool) -> Bool {
        switch socket {
        case .connecting:
            return false
        case .disconnected:
            return true
        case .connected:
            return droppedSinceJoin || channels.isEmpty || channels.contains(.unsubscribed)
        @unknown default:
            return false
        }
    }

    /// A channel as `needsRebuild` reads it. One whose subscribe is still
    /// running (a fresh channel before its first try, or a retry's back-off
    /// sleep) reads `.unsubscribed` too, but it hasn't given up: it counts as
    /// joining. Read as dead, a floor tick or a foreground restarted a set
    /// that was still coming up (audit 2026-09-22, C30).
    public static func effectiveStatus(_ status: RealtimeChannelStatus, joining: Bool) -> RealtimeChannelStatus {
        joining && status == .unsubscribed ? .subscribing : status
    }

    /// The whole set is delivering: only then did a rebuild work. One channel
    /// going live beside one that keeps failing used to reset the back-off,
    /// so the set was rebuilt on every floor tick (C30).
    public static func isLive(_ channels: [RealtimeChannelStatus]) -> Bool {
        !channels.isEmpty && channels.allSatisfy { $0 == .subscribed }
    }

    /// Seconds to wait after `failures` rebuilds that didn't bring the set
    /// live: 5, 10, 20, … capped at `maxBackoff`.
    public static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(minSpacing * pow(2, Double(min(failures, 16) - 1)), maxBackoff)
    }

    /// May a rebuild run at `now`?
    public func mayHeal(now: Date) -> Bool {
        guard let last = lastHealAt else { return true }
        return now.timeIntervalSince(last) >= max(Self.minSpacing, Self.backoff(afterFailures: failedHeals))
    }

    /// A rebuild is starting. Counted as failed until the set reports live.
    public mutating func recordHeal(now: Date) {
        lastHealAt = now
        failedHeals += 1
    }

    /// The set is live again (`isLive`).
    public mutating func recordLive() {
        failedHeals = 0
    }

    /// The network came back: whatever failed before gets a fresh chance (the
    /// minimum spacing still applies).
    public mutating func resetBackoff() {
        failedHeals = 0
    }

    /// Open the shared socket unless it is open or opening; true once it is
    /// open. supabase-swift 2.46's `connect()` re-runs its message listener
    /// even on a socket that is already up, and tearing down the old listener
    /// clears the new one (`WebSocket.events`' onTermination nils `onEvent`):
    /// the socket stops reading join replies, heartbeat acks and rows until a
    /// heartbeat timeout reconnects it — and a rebuild on that reconnect would
    /// break it again. A socket that is opening is waited for (bounded), never
    /// connected a second time, for the same reason (audit 2026-09-22, C30).
    public static func connectIfNeeded(_ realtime: RealtimeClientV2,
                                       waitAtMost seconds: TimeInterval = 15) async -> Bool {
        if realtime.status == .connecting {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await status in realtime.statusChange where status != .connecting { return }
                }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        if realtime.status == .disconnected { await realtime.connect() }
        return realtime.status == .connected
    }
}

/// What the shared socket's statuses mean to a channel set. `statusChange`
/// REPLAYS the current status to every new listener, and RealtimeMirror starts
/// a new listener after every rebuild: the replayed `.connected` read as a
/// first connect and asked `ensureLive` to rebuild the set just built (audit
/// 2026-09-22, C30). So the watch starts from what the owner already knows —
/// whether the set was joined on an open socket — and only a change from that
/// counts.
public struct SocketWatch: Sendable {
    public enum Event: Sendable, Equatable {
        case none
        /// Open, and the set was built without a socket: bring it up.
        case firstConnected
        /// Open again after a drop: the set is stale (rebuild + report the gap).
        case reconnected
        /// Down (or reopening) after the set had a socket.
        case dropped
    }

    private var last: RealtimeClientStatus
    private var everConnected: Bool

    /// `joinedOpen`: the set's channels were joined on an open socket.
    public init(joinedOpen: Bool) {
        last = joinedOpen ? .connected : .disconnected
        everConnected = joinedOpen
    }

    public mutating func see(_ status: RealtimeClientStatus) -> Event {
        guard status != last else { return .none }
        last = status
        switch status {
        case .connected:
            let event: Event = everConnected ? .reconnected : .firstConnected
            everConnected = true
            return event
        case .disconnected, .connecting:
            return everConnected ? .dropped : .none
        @unknown default:
            return .none
        }
    }
}
