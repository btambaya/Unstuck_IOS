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

    /// Outcome of a `profile_facts` hydrate merge.
    public struct ProfileFactsMerge: Equatable, Sendable {
        /// What the local table becomes (server-canonical + surviving local rows).
        public var merged: [ProfileFact]
        /// Local rows the server has never seen — push them up (web hydrate:
        /// "local-only rows get pushed up").
        public var pushLocalOnly: [ProfileFact]
        /// Local rows a strictly-newer server row replaced — their queued
        /// upsert ops are stale and must be dropped before the next flush.
        public var staleLocalIds: [String]
    }

    /// Hydrate merge for `profile_facts` (mirrors web hydrateProfileFacts, with
    /// last-write-wins instead of remote-always-wins):
    ///  • shared id → the row with the strictly newer `updatedAt` INSTANT wins
    ///    (ties, and anything that won't parse, go to the server — it is the
    ///    cross-device truth); server tombstones are kept as local tombstones;
    ///  • local-only rows (server never saw them — created before the table
    ///    existed, or an offline save whose push hasn't landed) survive AND are
    ///    reported for pushing, tombstones included (a tombstone the server
    ///    lacks is harmless and keeps every device consistent).
    /// Output order is deterministic: remote order, then local-only in local order.
    public static func mergeHydratedProfileFacts(remote: [ProfileFact], local: [ProfileFact]) -> ProfileFactsMerge {
        var localById: [String: ProfileFact] = [:]
        for f in local { localById[f.id] = f }
        var merged: [ProfileFact] = []
        var stale: [String] = []
        var seen = Set<String>()
        for r in remote {
            guard seen.insert(r.id).inserted else { continue }   // duplicate server row → first wins
            if let l = localById[r.id] {
                let localMs = Time.parseMillis(l.updatedAt)
                let remoteMs = Time.parseMillis(r.updatedAt)
                if let localMs, let remoteMs, localMs > remoteMs {
                    merged.append(l)
                } else {
                    merged.append(r)
                    if l != r { stale.append(l.id) }
                }
            } else {
                merged.append(r)
            }
        }
        let localOnly = local.filter { !seen.contains($0.id) }
        merged.append(contentsOf: localOnly)
        return ProfileFactsMerge(merged: merged, pushLocalOnly: localOnly, staleLocalIds: stale)
    }
}
