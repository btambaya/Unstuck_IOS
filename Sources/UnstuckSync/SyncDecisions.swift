// Pure sync-engine decisions extracted from the web bootstrap listener +
// hydrator so they're unit-testable without a network or DB. The
// networked engine (Hydrator/RealtimeMirror/SyncCoordinator) calls these.

import Foundation
import UnstuckCore

/// The auth events that drive cache-wipe decisions (subset of the SDK's
/// AuthChangeEvent that the coordinator acts on).
public enum SyncAuthEvent: Sendable, Equatable {
    case signedIn
    case initialSession
    case userUpdated
}

public enum SyncDecision {

    /// Cache-wipe rule (mirrors bootstrap-listener.tsx / Android SyncDecision):
    /// wipe ONLY when the user actually changed (or first sign-in, prev=nil) —
    /// never for a same-user re-auth, so a SIGNED_IN re-emit can't clobber the
    /// already-signed-in user's pending offline edits + live focus session
    /// before the outbox flushes (spec 02-sync-engine §1.8 / gotcha 9).
    /// - SIGNED_IN / INITIAL_SESSION: wipe iff the user changed since last run.
    /// - USER_UPDATED: never wipe (same user, metadata change).
    public static func shouldWipeCache(event: SyncAuthEvent, prevUserId: String?, currentUserId: String) -> Bool {
        switch event {
        case .signedIn, .initialSession: return prevUserId != currentUserId
        case .userUpdated: return false
        }
    }

    /// Hydrate merge for cal_blocks: the server set is canonical, but
    /// locally-cached external (Google `g_`) blocks live only on-device
    /// (their ids aren't UUIDs so they never round-trip to Postgres), so
    /// preserve them across the replace. Remote rows win on id collision.
    public static func mergeHydratedCalBlocks(remote: [CalBlock], localExternal: [CalBlock]) -> [CalBlock] {
        var byId: [String: CalBlock] = [:]
        for b in localExternal where isExternalBlock(b) { byId[b.id] = b }
        for b in remote { byId[b.id] = b }
        return Array(byId.values)
    }
}
