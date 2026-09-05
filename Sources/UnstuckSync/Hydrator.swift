// Hydrator — pulls every synced table and replaces the local store
// (server-canonical). Per-table error isolation: a table whose fetch
// fails is left intact rather than blanked (mirrors hydrate.ts's
// `if (res.ok) replace(...)`). Every table preserves rows that still have
// a queued upsert op (spec 02-sync-engine §1.3 localPending) — an offline
// edit must not vanish / revert off the UI until its flush lands — and
// cal_blocks additionally preserves locally cached Google external blocks
// across the replace. RLS auto-scopes reads to the signed-in user.

import Foundation
import GRDB
import UnstuckCore
import UnstuckData

public actor Hydrator {
    private let gateway: any SyncReadGatewayProtocol
    private let db: AppDatabase
    private let box: OutboxStore
    private let decoder = JSONDecoder()

    public init(gateway: any SyncReadGatewayProtocol, db: AppDatabase) {
        self.gateway = gateway
        self.db = db
        self.box = OutboxStore(db)
    }

    /// Reconcile queued `tasks` upsert ops with the server BEFORE the flush.
    /// Without it, a stale local op — e.g. an old `done=false` edit still
    /// sitting in the outbox — re-pushes and clobbers a newer server change (a
    /// completion made on the WEB), which the following hydrate then pulls
    /// back as not-done. This is the load-bearing fix for "completed on web,
    /// didn't reflect on the phone".
    ///
    /// Skew-safe: the op carries the BASE (`baseUpdatedAt` — the server-stamped
    /// `updated_at` this device last saw for the row), so the question "did
    /// the server move underneath this edit?" compares server clock with
    /// server clock. When it did, the op is NOT dropped: the local diff (op vs
    /// base) is 3-way merged onto the server row, the local row updated to
    /// match, and the op re-based — a rename made offline lands on top of the
    /// web completion instead of losing either. Only a LEGACY op (no base,
    /// enqueued by an older build) still falls back to the device-clock
    /// compare, with a skew margin. Reads the server only when task ops are
    /// actually queued, so it's free in the common empty-outbox case.
    public func pruneStaleTaskOps() async {
        let ops = (try? box.pending()) ?? []
        let taskOps = ops.filter { $0.tableName == "tasks" && $0.kind == .upsert && !$0.isQuarantined }
        guard !taskOps.isEmpty else { return }
        // Per-row tolerant: one un-decodable server task must not make the whole
        // prune a no-op (which would let stale local ops re-push and clobber).
        guard let serverRows = try? await gateway.fetchAllTolerant(TaskRow.self, table: "tasks") else { return }
        var serverById: [String: TaskRow] = [:]
        for r in serverRows { serverById[r.id] = r }
        for op in taskOps {
            guard let seq = op.opSeq, let data = op.payload?.data(using: .utf8),
                  let row = try? decoder.decode(TaskRow.self, from: data),
                  let server = serverById[op.rowId] else { continue }
            // Compare INSTANTS, not ISO strings: PostgREST emits microseconds +
            // "+00:00" while local ops use millis + "Z". If the server stamp
            // won't parse, DON'T prune (keep the op — it flushes and the server's
            // own conflict resolution decides).
            guard let serverMs = Time.parseMillis(server.updatedAt) else { continue }
            let baseMs = op.baseUpdatedAt.flatMap(Time.parseMillis)
            switch SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: serverMs, baseUpdatedAtMs: baseMs,
                                                    opUpdatedAtMs: Time.parseMillis(row.updatedAt)) {
            case .keep:
                continue
            case .prune:
                print("[outbox] pruning legacy stale tasks op \(op.rowId) — server is newer")
                try? box.markDone(seq)
            case .conflict:
                guard let base = op.basePayload?.data(using: .utf8),
                      let serverData = try? JSONEncoder().encode(server),
                      let merged = SyncDecision.threeWayMergeRow(op: data, base: base, server: serverData),
                      let mergedRow = try? decoder.decode(TaskRow.self, from: merged),
                      let mergedJSON = String(data: merged, encoding: .utf8) else { continue }
                print("[outbox] merging tasks op \(op.rowId) onto a newer server row (3-way)")
                // Re-base on the server version we merged against; the local row
                // follows so the UI shows the server's changes to the fields this
                // device didn't touch.
                try? box.replacePayload(seq, payload: mergedJSON, baseUpdatedAt: server.updatedAt,
                                        basePayload: String(data: serverData, encoding: .utf8))
                try? db.save(mergedRow.model())
            }
        }
    }

    // Coalesce overlapping full hydrates. The socket-reconnect resync, the 60s
    // foreground safety-net (syncNow), and the auth-event hydrate all funnel
    // into hydrate() and can interleave at await points (actor isolation gates
    // each step, not the whole run). Gate so at most ONE full hydrate runs at a
    // time; any request that arrives while one is in flight collapses into a
    // SINGLE trailing run afterwards (in-flight → remember latest → run once
    // more). BUG 2.
    private var hydrateInFlight = false
    private var hydratePendingUserId: String?

    public func hydrate(userId: String) async {
        guard !hydrateInFlight else {
            hydratePendingUserId = userId   // coalesce concurrent requests → one trailing run
            return
        }
        hydrateInFlight = true
        defer { hydrateInFlight = false }
        var next: String? = userId
        while let uid = next {
            hydratePendingUserId = nil
            await performHydrate(userId: uid)
            next = hydratePendingUserId     // a request arrived mid-run → run once more, for it
        }
    }

    private func performHydrate(userId: String) async {
        await hydrateTasks()
        await replacePreservingPending("sessions", SessionRow.self, Session.self)
        await hydrateCaptures()
        await replacePreservingPending("reason_logs", ReasonLogRow.self, ReasonLog.self)
        await hydrateCollections(userId: userId)
        await replacePreservingPending("tags", TagDbRow.self, TagRow.self)
        await replacePreservingPending("life_areas", LifeAreaDbRow.self, LifeArea.self)
        await replace("calendar_connections", CalendarConnectionRow.self) { try self.db.replaceAll(CalendarConnection.self, with: $0.map { $0.model() }) }
        await hydrateCalBlocks()
        await hydrateProfileFacts()
    }

    /// Ids with a queued (non-quarantined or quarantined — either way un-acked)
    /// upsert op for `table`, read on the OPEN connection so the decision and
    /// the replace share one transaction.
    private static func pendingUpsertIds(in conn: Database, table: String) throws -> Set<String> {
        Set(try OutboxStore.pending(in: conn).filter { $0.tableName == table && $0.kind == .upsert }.map(\.rowId))
    }

    /// Server-canonical replace that keeps rows with a pending upsert op
    /// (spec §1.3 localPending): a row the server doesn't have yet survives;
    /// one it also has is decided by `resolve` (default: the local intent wins
    /// — tables without `updatedAt` can't do better; tasks use LWW).
    private func replacePreservingPending<Row: Decodable & Sendable & ModelConvertible, M>(
        _ table: String, _ rowType: Row.Type, _ modelType: M.Type,
        resolve: @escaping (M, M) -> M = { local, _ in local }
    ) async where Row.Model == M, M: PersistableRecord & FetchableRecord & Sendable & Identifiable, M.ID == String {
        do {
            let remote = try await gateway.fetchAllTolerant(Row.self, table: table).map { $0.model() }
            try db.replaceAllAtomically(M.self) { conn, local in
                let pending = try Self.pendingUpsertIds(in: conn, table: table)
                return SyncDecision.mergeHydratedRows(remote: remote, local: local, pendingIds: pending, resolve: resolve)
            }
        } catch {
            print("[hydrate] \(table) failed, leaving local intact: \(error)")
        }
    }

    /// Tasks: a row with a pending upsert keeps the LOCAL version when the
    /// server row hasn't moved since the edit was based (server `updated_at`
    /// ≤ the op's `baseUpdatedAt` — server clock vs server clock, so a slow
    /// device clock can't make the server "win" over a genuine offline edit,
    /// the trap pruneStaleTaskOps also closes); a server row that DID move
    /// falls back to last-write-wins (the prune's 3-way merge normally
    /// re-bases the op before this runs). Rows without a pending op are
    /// server-canonical.
    private func hydrateTasks() async {
        do {
            let remote = try await gateway.fetchAllTolerant(TaskRow.self, table: "tasks").map { $0.model() }
            try db.replaceAllAtomically(TaskItem.self) { conn, local in
                let ops = try OutboxStore.pending(in: conn).filter { $0.tableName == "tasks" && $0.kind == .upsert }
                let pending = Set(ops.map(\.rowId))
                var baseById: [String: String] = [:]
                for op in ops { if let base = op.baseUpdatedAt { baseById[op.rowId] = base } }   // last op's base wins
                return SyncDecision.mergeHydratedRows(remote: remote, local: local, pendingIds: pending) { l, r in
                    SyncDecision.resolvePendingTask(local: l, remote: r, baseUpdatedAt: baseById[r.id])
                }
            }
        } catch {
            print("[hydrate] tasks failed, leaving local intact: \(error)")
        }
    }

    /// Captures + their archive state (`archived_at`, migration 053). The
    /// archive table is replaced from the server rows in the SAME transaction
    /// as the captures — but only when the server rows actually carry the
    /// column (a pre-053 server must not blank a local archive); rows with a
    /// pending upsert keep their local state in both tables.
    private func hydrateCaptures() async {
        do {
            let raw = try await gateway.fetchAllRaw(table: "captures")
            let rows = raw.compactMap { try? decoder.decode(CaptureRow.self, from: $0) }
            let columnPresent = raw.isEmpty || raw.contains(where: CaptureRow.hasArchivedAtColumn)
            let remote = rows.map { $0.model() }
            var serverArchived: [String: String] = [:]
            for r in rows { if let at = r.archivedAt { serverArchived[r.id] = at } }
            try db.replaceAllAtomically(Capture.self) { conn, local in
                let pending = try Self.pendingUpsertIds(in: conn, table: "captures")
                if columnPresent {
                    try AppDatabase.replaceCaptureArchive(in: conn, serverArchived: serverArchived, keepLocalIds: pending)
                }
                return SyncDecision.mergeHydratedRows(remote: remote, local: local, pendingIds: pending) { l, _ in l }
            }
        } catch {
            print("[hydrate] captures failed, leaving local intact: \(error)")
        }
    }

    /// `profile_facts` — the assistant's cross-device memory. NOT a blanket
    /// replace: the server is cross-device truth, but a strictly-newer local
    /// row (an offline save / forget whose push hasn't landed) must survive,
    /// and rows the server has never seen get PUSHED — mirroring the web's
    /// `hydrateProfileFacts` (remote wins on shared ids, local-only rows
    /// pushed up) with last-write-wins on `updated_at` instead of remote-
    /// always-wins. Server tombstones (`active=false`) are kept locally as
    /// tombstones so "forget" propagates everywhere and nothing resurrects.
    /// A local row the server superseded also drops its queued upsert op, so
    /// a stale offline edit can't clobber the newer server state on the next
    /// flush (the same trap pruneStaleTaskOps closes for tasks).
    ///
    /// The local read, the stale-op cancels, the replace and the local-only
    /// pushes run in ONE write transaction: a fact saved on another thread
    /// while this ran used to land between the read and the replace and get
    /// deleted (its queued op cancelled with it). Now it lands either before
    /// (merged, LWW) or after (untouched).
    public func hydrateProfileFacts() async {
        // Fires on success AND failure/offline — "hydrated once" is what the
        // surfaces wait on before treating an empty local store as "never met".
        defer { onProfileFactsHydrated?() }
        do {
            let remote = try await gateway.fetchAllTolerant(ProfileFactRow.self, table: "profile_facts").map { $0.model() }
            let now = ProfileFactsService.isoNow()
            let afterLocalRead = afterProfileFactsLocalRead
            try db.replaceAllAtomically(ProfileFact.self) { db, local in
                afterLocalRead?()
                let merge = SyncDecision.mergeHydratedProfileFacts(remote: remote, local: local)
                let seenUpdatedAt = Dictionary(local.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
                for id in merge.staleLocalIds {
                    // Cancel only when the row is still the one the merge judged
                    // stale. Inside this transaction that always holds; the check
                    // keeps the cancel safe if the read and the cancel are ever
                    // split into separate transactions again.
                    guard try ProfileFact.fetchOne(db, key: id)?.updatedAt == seenUpdatedAt[id] else { continue }
                    try? OutboxStore.cancelPendingUpserts(in: db, table: "profile_facts", rowId: id)
                }
                for f in merge.pushLocalOnly {
                    try? ProfileFactPush.enqueue(f, in: db, nowISO: now)
                }
                return merge.merged
            }
        } catch {
            print("[hydrate] profile_facts failed, leaving local intact: \(error)")
        }
    }

    /// Completion hook for `hydrateProfileFacts` — called once per run, on
    /// success OR failure (offline included). The app flips its
    /// "profile facts hydrated once" flag from here.
    private var onProfileFactsHydrated: (@Sendable () -> Void)?
    public func setOnProfileFactsHydrated(_ hook: @escaping @Sendable () -> Void) {
        onProfileFactsHydrated = hook
    }

    /// Test seam: runs INSIDE the profile_facts merge transaction, right after
    /// the local read — lets a test race a concurrent save against the merge
    /// and prove it can't land in between. Never set in production.
    private var afterProfileFactsLocalRead: (@Sendable () -> Void)?
    func setAfterProfileFactsLocalRead(_ hook: (@Sendable () -> Void)?) {
        afterProfileFactsLocalRead = hook
    }

    /// Collections + their membership. RLS returns own AND shared-with-me rows;
    /// `collection_members` (visible to member or owner) supplies each row's
    /// members[] + the current user's myRole. Mirrors hydrate.ts / the Android
    /// Hydrator. Also invoked standalone when a collection_members realtime
    /// event fires.
    public func hydrateCollections(userId: String) async {
        do {
            // Per-row tolerant decode (see replace()): a single bad collection
            // row mustn't drop the user's entire list of collections.
            let base = try await gateway.fetchAllTolerant(CollectionRow.self, table: "collections").map { $0.model() }
            let memberRows = (try? await gateway.fetchAllTolerant(MemberRow.self, table: "collection_members")) ?? []
            var byColl: [String: [(String, String)]] = [:]   // collectionId -> [(userId, role)]
            for m in memberRows {
                byColl[m.collectionId, default: []].append((m.userId, m.role ?? "editor"))
            }
            let enriched = base.map { c -> ItemCollection in
                let ms = byColl[c.id] ?? []
                var out = c
                out.members = ms.map { $0.0 }
                out.myRole = c.ownerId == userId ? "owner" : ms.first { $0.0 == userId }?.1
                return out
            }
            // Preserve unsynced optimistic collections (those with a pending
            // collections upsert op in the outbox): a just-created/edited list
            // isn't in `enriched` yet, so the replace would wipe it off the UI
            // until the next flush (spec 02-sync-engine §1.3 localPending).
            try db.replaceAllAtomically(ItemCollection.self) { conn, local in
                let pending = try Self.pendingUpsertIds(in: conn, table: "collections")
                return SyncDecision.mergeHydratedRows(remote: enriched, local: local, pendingIds: pending) { l, _ in l }
            }
        } catch {
            print("[hydrate] collections failed, leaving local intact: \(error)")
        }
    }

    private struct MemberRow: Decodable, Sendable {
        let collectionId: String
        let userId: String
        let role: String?
        enum CodingKeys: String, CodingKey {
            case collectionId = "collection_id"
            case userId = "user_id"
            case role
        }
    }

    private func replace<Row: Decodable & Sendable>(_ table: String, _ rowType: Row.Type, save: ([Row]) throws -> Void) async {
        do {
            // Per-ROW tolerant decode: one un-decodable row (e.g. a forward-compat
            // shape this build can't parse — an unknown recurrence kind already
            // degrades, but any other new enum value could still throw) must not
            // abort the whole table and wipe every good row off the UI. Drop only
            // the bad row. Mirrors the Android Hydrator.
            let rows = try await gateway.fetchAllTolerant(Row.self, table: table)
            try save(rows)
        } catch {
            print("[hydrate] \(table) failed, leaving local intact: \(error)")
        }
    }

    private func hydrateCalBlocks() async {
        do {
            // Per-row tolerant decode (see replace()): a single bad cal_block row
            // mustn't wipe the whole schedule.
            let remote = try await gateway.fetchAllTolerant(CalBlockRow.self, table: "cal_blocks").map { $0.model() }
            try db.replaceAllAtomically(CalBlock.self) { conn, local in
                let localExternal = local.filter { isExternalBlock($0) }
                let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: localExternal)
                // Preserve unsynced optimistic TASK blocks (those with a pending
                // cal_blocks upsert op in the outbox): a just-scheduled / just-moved
                // block must not vanish or snap back until the flush lands (spec
                // 02-sync-engine §1.3 localPending). The local intent wins.
                let pending = try Self.pendingUpsertIds(in: conn, table: "cal_blocks")
                let ownLocal = local.filter { !isExternalBlock($0) }
                return SyncDecision.mergeHydratedRows(remote: merged, local: ownLocal, pendingIds: pending) { l, _ in l }
            }
        } catch {
            print("[hydrate] cal_blocks failed, leaving local intact: \(error)")
        }
    }
}

/// A DbRowCodec row that converts to its UnstuckCore model — lets the
/// pending-preserving replace be written once for every table.
protocol ModelConvertible {
    associatedtype Model
    func model() -> Model
}

extension TaskRow: ModelConvertible {}
extension SessionRow: ModelConvertible {}
extension ReasonLogRow: ModelConvertible {}
extension TagDbRow: ModelConvertible {}
extension LifeAreaDbRow: ModelConvertible {}
