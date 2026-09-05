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

    // MARK: - hydrate: preserve rows with a pending upsert (spec §1.3 localPending)

    /// The server set is canonical, EXCEPT for rows this device still has a
    /// queued upsert for: those carry an un-acked local intent, so
    ///  • a pending row the server doesn't have yet survives the replace
    ///    (else an offline-created task vanishes until the flush), and
    ///  • a pending row the server ALSO has is decided by `resolve(local,
    ///    remote)` — last-write-wins on `updatedAt` for tasks, "local intent
    ///    wins" for tables without a timestamp.
    /// Output order: remote order, then the local-only pending rows.
    public static func mergeHydratedRows<T: Identifiable>(
        remote: [T], local: [T], pendingIds: Set<String>,
        resolve: (_ local: T, _ remote: T) -> T
    ) -> [T] where T.ID == String {
        guard !pendingIds.isEmpty else { return remote }
        var localById: [String: T] = [:]
        for l in local where pendingIds.contains(l.id) { localById[l.id] = l }
        var out: [T] = []
        var seen = Set<String>()
        for r in remote {
            seen.insert(r.id)
            if let l = localById[r.id] { out.append(resolve(l, r)) } else { out.append(r) }
        }
        for l in local where pendingIds.contains(l.id) && !seen.contains(l.id) { out.append(l) }
        return out
    }

    /// LWW resolver for rows with an `updatedAt` instant: the strictly-newer
    /// side wins, ties + unparseable go to the server (cross-device truth).
    public static func newerWins<T>(_ local: T, _ remote: T, updatedAt: (T) -> String) -> T {
        guard let l = Time.parseMillis(updatedAt(local)), let r = Time.parseMillis(updatedAt(remote)) else { return remote }
        return l > r ? local : remote
    }

    /// Hydrate resolver for a task with a pending upsert: the local row is the
    /// newest intent as long as the server row hasn't moved past the base the
    /// edit was made on (`serverUpdatedAt ≤ baseUpdatedAt`, server clocks on
    /// both sides); once the server has moved, last-write-wins decides.
    public static func resolvePendingTask(local: TaskItem, remote: TaskItem, baseUpdatedAt: String?) -> TaskItem {
        if let base = baseUpdatedAt, let b = Time.parseMillis(base), let r = Time.parseMillis(remote.updatedAt), r <= b + 1 {
            return local
        }
        return newerWins(local, remote, updatedAt: \.updatedAt)
    }

    // MARK: - prune-before-flush: skew-tolerant conflict detection + 3-way merge

    public enum StaleOpDecision: Equatable, Sendable {
        /// The server row hasn't moved since this device based its edit on it — flush as-is.
        case keep
        /// The server row changed underneath the edit — merge the local diff onto it.
        case conflict
        /// Legacy op (no base) that a strictly-newer server row supersedes — drop it.
        case prune
    }

    /// Skew allowance when comparing a device-clock stamp with a server one
    /// (the legacy no-base path only).
    public static let clockSkewMarginMs: Double = 2_000

    /// Decide what to do with a queued `tasks` op given the server row's
    /// `updated_at`. With a base (`baseUpdatedAtMs`, the server-stamped value
    /// this device last saw) the comparison is server-clock vs server-clock —
    /// no skew — and a moved server row is a CONFLICT to merge, never a drop.
    /// Without a base (an op enqueued by an older build) fall back to the
    /// device-clock compare, tolerating `clockSkewMarginMs` in the server's
    /// favour before pruning.
    public static func staleTaskOpDecision(serverUpdatedAtMs: Double, baseUpdatedAtMs: Double?,
                                           opUpdatedAtMs: Double?) -> StaleOpDecision {
        if let base = baseUpdatedAtMs {
            // A tiny tolerance covers the server re-emitting the same instant
            // with different sub-millisecond precision.
            return serverUpdatedAtMs > base + 1 ? .conflict : .keep
        }
        guard let op = opUpdatedAtMs else { return .keep }
        return serverUpdatedAtMs > op + clockSkewMarginMs ? .prune : .keep
    }

    /// 3-way merge of flat JSON row objects: for every top-level key, the
    /// LOCAL value is taken where the edit changed it (op ≠ base), otherwise
    /// the SERVER's value — so a rename made offline lands on top of a
    /// completion made on the web instead of clobbering it. `ignoreKeys`
    /// always take the op's value (updated_at). Nil when any input isn't a
    /// JSON object.
    public static func threeWayMergeRow(op: Data, base: Data, server: Data,
                                        ignoreKeys: Set<String> = ["updated_at"]) -> Data? {
        guard let o = (try? JSONSerialization.jsonObject(with: op)) as? [String: Any],
              let b = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let s = (try? JSONSerialization.jsonObject(with: server)) as? [String: Any] else { return nil }
        var out: [String: Any] = s
        let keys = Set(o.keys).union(b.keys).union(s.keys)
        for key in keys {
            let ov = o[key] ?? NSNull()
            let bv = b[key] ?? NSNull()
            if ignoreKeys.contains(key) || !jsonEqual(ov, bv) {
                out[key] = o[key] ?? NSNull()
            } else if s[key] == nil {
                // Neither side changed it and the server lacks it: keep the op's.
                out[key] = ov
            }
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// Structural JSON equality over Foundation's bridged values (NSNull /
    /// NSNumber / NSString / NSArray / NSDictionary all answer `isEqual`).
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b as AnyObject)
    }

    // MARK: - outbox failure classification

    public enum FlushFailure: Equatable, Sendable {
        /// The request never got a definitive answer (offline, timeout, 5xx,
        /// JWT refresh, rate limit) — retry later, never count it.
        case transient
        /// The server understood the request and refused it (PostgREST 4xx:
        /// FK / check / unknown column / bad JSON) — retrying the same bytes
        /// can't succeed; counts toward the quarantine cap.
        case rejected
        /// The drain itself was cancelled (sign-out timeout, BG-task stop).
        case cancelled
    }

    /// Classify a flush error. Only DEFINITE server rejections count toward
    /// the quarantine cap; everything ambiguous is transient (retrying costs a
    /// request, mis-counting cost the user's data).
    public static func classifyFlushFailure(_ error: Error) -> FlushFailure {
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            return url.code == .cancelled ? .cancelled : .transient
        }
        if let rejection = error as? ServerRejectionClassifiable {
            return rejection.isServerRejection ? .rejected : .transient
        }
        return .transient
    }
}

/// Errors that know whether they are a definitive server rejection. The
/// supabase-swift error types conform in OutboxFlusher (PostgrestError by
/// SQLSTATE / PGRST code class, HTTPError by status); tests conform a fake.
public protocol ServerRejectionClassifiable: Error {
    var isServerRejection: Bool { get }
}
