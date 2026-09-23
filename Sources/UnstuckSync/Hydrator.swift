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
    ///
    /// A row's queued edits are judged as ONE chain, by its oldest op (audit
    /// 2026-09-22, C9). Only the first edit's base is a server stamp: every
    /// later edit's base is the previous LOCAL edit (device clock). Judging
    /// and merging each op on its own against the raw server row let a second
    /// offline edit revert the first one's fields to the server's old values,
    /// or skip the merge and re-open a task completed on the web. So the head
    /// decides for the whole chain; on a conflict every later op's own diff is
    /// merged onto the previous op's MERGED row. The ops are re-read inside
    /// the write transaction, after the fetch, so an edit queued while the
    /// fetch was in flight joins the chain instead of being overwritten.
    public func pruneStaleTaskOps() async {
        let ops = (try? box.pending()) ?? []
        guard ops.contains(where: Self.isLiveTaskUpsert) else { return }
        // Per-row tolerant: one un-decodable server task must not make the whole
        // prune a no-op (which would let stale local ops re-push and clobber).
        guard let serverRows = try? await gateway.fetchAllTolerant(TaskRow.self, table: "tasks") else { return }
        var serverById: [String: TaskRow] = [:]
        for r in serverRows { serverById[r.id] = r }
        try? db.transaction { conn in
            var chains: [String: [OutboxOp]] = [:]
            var rowOrder: [String] = []
            for op in try OutboxStore.pending(in: conn) where Self.isLiveTaskUpsert(op) {
                if chains[op.rowId] == nil { rowOrder.append(op.rowId) }
                chains[op.rowId, default: []].append(op)   // pending(in:) is op-seq order
            }
            for rowId in rowOrder {
                guard let chain = chains[rowId], let server = serverById[rowId] else { continue }
                // One row's failure must not roll back every other row's merge.
                do {
                    try conn.inSavepoint {
                        try Self.reconcileTaskChain(chain, server: server, in: conn)
                        return .commit
                    }
                } catch {
                    print("[outbox] tasks op chain \(rowId) not reconciled: \(error)")
                }
            }
        }
    }

    /// A `tasks` upsert the drain will still send.
    static func isLiveTaskUpsert(_ op: OutboxOp) -> Bool {
        op.tableName == "tasks" && op.kind == .upsert && !op.isQuarantined
    }

    /// Judge + merge one row's queued edits (op-seq order) against the server
    /// row, on an open write transaction. See `pruneStaleTaskOps`.
    private static func reconcileTaskChain(_ chain: [OutboxOp], server: TaskRow, in conn: Database) throws {
        let decoder = JSONDecoder()
        // Compare INSTANTS, not ISO strings: PostgREST emits microseconds +
        // "+00:00" while local ops use millis + "Z". If the server stamp
        // won't parse, DON'T prune (keep the op — it flushes and the server's
        // own conflict resolution decides).
        guard let serverMs = Time.parseMillis(server.updatedAt),
              let serverData = try? JSONEncoder().encode(server),
              let serverJSON = String(data: serverData, encoding: .utf8) else { return }
        // Once the chain is in conflict: the previous op's merged row (what it
        // will put on the server) — the next op's diff lands on THIS.
        var onto: (data: Data, json: String)?
        var previousPayload: Data?
        var lastMerged: (seq: Int64, row: TaskRow)?
        for op in chain {
            guard let seq = op.opSeq, let data = op.payload?.data(using: .utf8),
                  let row = try? decoder.decode(TaskRow.self, from: data) else { continue }
            defer { previousPayload = data }
            if let prev = onto {
                // Re-base on the previous merged row. The server stamp is a lower
                // bound: once the earlier op lands the server moves past it, so
                // the next prune merges this op against what actually landed.
                guard let base = op.basePayload?.data(using: .utf8) ?? previousPayload,
                      let merged = SyncDecision.threeWayMergeRow(op: data, base: base, server: prev.data),
                      let mergedRow = try? decoder.decode(TaskRow.self, from: merged),
                      let mergedJSON = String(data: merged, encoding: .utf8) else { continue }
                try OutboxStore.replacePayload(in: conn, seq, payload: mergedJSON,
                                               baseUpdatedAt: server.updatedAt, basePayload: prev.json)
                onto = (merged, mergedJSON)
                lastMerged = (seq, mergedRow)
                continue
            }
            // The chain's head — the only op whose base is a server stamp.
            let baseMs = op.baseUpdatedAt.flatMap(Time.parseMillis)
            switch SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: serverMs, baseUpdatedAtMs: baseMs,
                                                    opUpdatedAtMs: Time.parseMillis(row.updatedAt)) {
            case .keep:
                return   // the server hasn't moved: every later edit sits on top of this one
            case .prune:
                print("[outbox] pruning legacy stale tasks op \(op.rowId) — server is newer")
                try OutboxStore.markDone(in: conn, seq)   // the next op becomes the head
            case .conflict:
                guard let base = op.basePayload?.data(using: .utf8),
                      let merged = SyncDecision.threeWayMergeRow(op: data, base: base, server: serverData),
                      let mergedRow = try? decoder.decode(TaskRow.self, from: merged),
                      let mergedJSON = String(data: merged, encoding: .utf8) else { return }
                print("[outbox] merging tasks op \(op.rowId) onto a newer server row (3-way)")
                // Re-base on the server version we merged against.
                try OutboxStore.replacePayload(in: conn, seq, payload: mergedJSON,
                                               baseUpdatedAt: server.updatedAt, basePayload: serverJSON)
                onto = (merged, mergedJSON)
                lastMerged = (seq, mergedRow)
            }
        }
        // The local row follows the chain's LAST op, so the UI shows the
        // server's changes to the fields this device didn't touch — but only
        // when that op was merged; otherwise the local row already is its intent.
        if let lastMerged, lastMerged.seq == chain.last?.opSeq {
            try lastMerged.row.model().upsert(conn)
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
        await hydrateCallRequests()
    }

    /// `call_requests` — the local mirror the call surfaces read (see
    /// CallRequestsMirror). Server-canonical, with one preservation rule: a
    /// LOCAL-ONLY row stamped newer than every server row is a booking whose
    /// echo this fetch predated — kept until the next pull confirms it (there
    /// is no outbox op to consult; calls are direct writes). False = the fetch
    /// failed (local left intact).
    @discardableResult
    public func hydrateCallRequests() async -> Bool {
        do {
            let remote = try await gateway.fetchAllTolerant(CallRequest.self, table: "call_requests")
            try db.replaceAllAtomically(CallRequest.self) { _, local in
                CallRequestsMirror.mergeHydrated(remote: remote, local: local)
            }
            return true
        } catch {
            print("[hydrate] call_requests failed, leaving local intact: \(error)")
            return false
        }
    }

    /// Ids with a queued (non-quarantined or quarantined — either way un-acked)
    /// upsert op for `table`, read on the OPEN connection so the decision and
    /// the replace share one transaction.
    /// `.rpc` counts as pending too: a collection whose item edit is still a
    /// queued `collection_*` RPC (a transient failure held it back) must not be
    /// reverted to the server's older copy by a hydrate that runs while the op
    /// is still in the outbox. A flush normally precedes the hydrate, so this
    /// closes a narrow race rather than an everyday path.
    /// An insert-family op (a deterministic occurrence mint, stage 2) counts
    /// exactly like an upsert: a re-minted row must survive a pull that runs
    /// between its queued delete and its insert.
    private static func pendingUpsertIds(in conn: Database, table: String) throws -> Set<String> {
        Set(try OutboxStore.pending(in: conn)
            .filter { $0.tableName == table && $0.kind.isPendingWrite }
            .map(\.rowId))
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
    ///
    /// The row's base is the NEWEST base over all its queued ops (quarantined
    /// included) — the rule RealtimeMirror.incomingTaskWins uses. It was the
    /// LAST op's base, which for a second queued edit is the device-clock
    /// stamp of the first: a slow clock let the hydrate swap a pending chain's
    /// local row for the server row, and the next edit, built on it, dropped
    /// the earlier offline edits (audit 2026-09-22, C9).
    private func hydrateTasks() async {
        do {
            let remote = try await gateway.fetchAllTolerant(TaskRow.self, table: "tasks").map { $0.model() }
            try db.replaceAllAtomically(TaskItem.self) { conn, local in
                let ops = try OutboxStore.pending(in: conn).filter { $0.tableName == "tasks" && $0.kind == .upsert }
                let pending = Set(ops.map(\.rowId))
                var baseById: [String: String] = [:]
                for op in ops {
                    guard let base = op.baseUpdatedAt, let ms = Time.parseMillis(base) else { continue }
                    if let cur = baseById[op.rowId], let curMs = Time.parseMillis(cur), curMs >= ms { continue }
                    baseById[op.rowId] = base
                }
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
    /// The two tables the SERVER gives no monotonic column for — `cal_blocks`
    /// has no timestamp at all, and `captures.archived_at` moves without
    /// `created_at` moving — so a cursor pull cannot see their changes. The
    /// catch-up falls back to this full server-canonical replace for them,
    /// which is exactly what every 60s tick already did for all ten tables.
    /// Adding `updated_at` to those two server tables is the follow-up that
    /// would make them delta-capable too. False = the fetch failed (local
    /// left intact).
    @discardableResult
    public func hydrateFullReplaceTable(_ name: String) async -> Bool {
        switch name {
        case "cal_blocks": return await hydrateCalBlocks()
        case "captures":   return await hydrateCaptures()
        default:           return false
        }
    }

    @discardableResult
    private func hydrateCaptures() async -> Bool {
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
            return true
        } catch {
            print("[hydrate] captures failed, leaving local intact: \(error)")
            return false
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

    // Coalesce overlapping collections hydrates, like `hydrate()`. The
    // collection_members realtime channel runs one per burst of events
    // (RealtimeMirror.coalescedSignal), and that channel now carries the
    // owner's lists too (a membership DELETE anywhere reaches every client:
    // Realtime can't RLS-check a delete); the share / unshare / leave paths
    // run one each. One run at a time, one trailing run for whatever arrived
    // meanwhile, so two replaces never interleave. A caller that arrives
    // mid-run returns only after the trailing run, so "awaited = re-read
    // after my call" still holds for those paths. (audit 2026-09-22, C8)
    private var collectionsInFlight = false
    private var collectionsPendingUserId: String?
    private var collectionsWaiters: [CheckedContinuation<Void, Never>] = []

    /// True while the last membership read (a collections hydrate's or the
    /// catch-up's) failed. Only a successful read clears it; until then every
    /// catch-up re-reads, because a device that knew nothing (a fresh sign-in)
    /// filled its lists with no members and the owner's edits would route as
    /// unshared.
    private var membershipUnresolved = false

    /// Collections + their membership. RLS returns own AND shared-with-me rows;
    /// `collection_members` (visible to member or owner) supplies each row's
    /// members[] + the current user's myRole. Mirrors hydrate.ts / the Android
    /// Hydrator. Also invoked standalone when a collection_members realtime
    /// event fires.
    public func hydrateCollections(userId: String) async {
        guard !collectionsInFlight else {
            collectionsPendingUserId = userId
            await withCheckedContinuation { collectionsWaiters.append($0) }
            return
        }
        collectionsInFlight = true
        defer { collectionsInFlight = false }
        var next: String? = userId
        while let uid = next {
            collectionsPendingUserId = nil
            let covered = collectionsWaiters   // arrived before this run began
            collectionsWaiters.removeAll()
            await performHydrateCollections(userId: uid)
            for waiter in covered { waiter.resume() }
            next = collectionsPendingUserId
        }
    }

    /// The catch-up's membership re-read. The server's collections row carries
    /// no membership, and the catch-up (like realtime) carries the local
    /// members forward — so migration 056 §4's `updated_at` bump on every
    /// collection_members change is the owner's ONLY pull-side signal that a
    /// list became shared (a join by link, an invite claimed at sign-up, a
    /// share made on another device) or lost a member. Without this re-read
    /// the owner's phone kept `members == []`, `isShared` stayed false, and
    /// its item edits went out as whole-row upserts that deleted what the
    /// members added (audit 2026-09-22, C8).
    ///
    /// It only PATCHES members/myRole onto the local rows: the pull right
    /// before it already applied every newer collections row. A full
    /// collections replace here (it runs after the user's own list edits too:
    /// realtime never moves the cursor) raced the debounced flush. An edit
    /// acked, or echoed, between its collections read and its write was
    /// reverted to the older snapshot, and on an unshared list the owner's
    /// next whole-row upsert, built on that row, deleted the edit on the
    /// server. Rows are read and written in one transaction, so no content
    /// can go back.
    public func refreshCollectionMembership(userId: String, collectionsChanged: Bool) async {
        guard collectionsChanged || membershipUnresolved else { return }
        let memberRows: [MemberRow]
        do {
            memberRows = try await gateway.fetchAllTolerant(MemberRow.self, table: "collection_members")
        } catch {
            membershipUnresolved = true
            print("[catchup] collection_members failed, retrying on the next catch-up: \(error)")
            return
        }
        let byColl = Self.membersByCollection(memberRows)
        do {
            try db.transaction { conn in
                for var c in try ItemCollection.fetchAll(conn) {
                    let ms = byColl[c.id] ?? []
                    let role = c.ownerId == userId ? "owner" : ms.first { $0.0 == userId }?.1
                    // Someone else's list with no row for me: I can no longer see
                    // it, and the reconcile / the members event removes it. Don't
                    // strip its role in the meantime.
                    guard c.ownerId == userId || role != nil else { continue }
                    let members = ms.map { $0.0 }
                    guard c.members != members || c.myRole != role else { continue }
                    c.members = members
                    c.myRole = role
                    try c.update(conn)
                }
            }
            membershipUnresolved = false
        } catch {
            membershipUnresolved = true
            print("[catchup] collection membership not saved, retrying on the next catch-up: \(error)")
        }
    }

    /// collectionId -> [(userId, role)], in server order.
    private static func membersByCollection(_ rows: [MemberRow]) -> [String: [(String, String)]] {
        var byColl: [String: [(String, String)]] = [:]
        for m in rows {
            byColl[m.collectionId, default: []].append((m.userId, m.role ?? "editor"))
        }
        return byColl
    }

    /// Test seam: callers parked behind an in-flight collections hydrate.
    var collectionsHydrateWaiterCount: Int { collectionsWaiters.count }

    private func performHydrateCollections(userId: String) async {
        // A collections op queued now can be acked (and its row echoed) while
        // the reads below are in flight, so their snapshot predates it and the
        // replace finds nothing queued. Those rows count as pending anyway: an
        // edit acked mid-read was reverted to the pre-edit snapshot (and the
        // owner's next whole-row upsert, built on it, deleted the edit on the
        // server), and a list deleted mid-read came back. This runs on every
        // membership event now (audit 2026-09-22, C8).
        let queuedAtStart = ((try? box.pending()) ?? []).filter { $0.tableName == "collections" }
        do {
            // Per-row tolerant decode (see replace()): a single bad collection
            // row mustn't drop the user's entire list of collections.
            let base = try await gateway.fetchAllTolerant(CollectionRow.self, table: "collections").map { $0.model() }
            // A failed members read is NOT "nobody is a member": that emptied
            // every list's members, so an owner's shared list read as unshared
            // and its next edit shipped the whole `items` array over the
            // members' edits. Keep what this device knew instead; only a
            // successful read may empty `members` (web attachCollectionMembers /
            // Android Hydrator parity; audit 2026-09-22, C8).
            let memberRows: [MemberRow]?
            do {
                memberRows = try await gateway.fetchAllTolerant(MemberRow.self, table: "collection_members")
            } catch {
                print("[hydrate] collection_members failed, keeping the membership this device knows: \(error)")
                memberRows = nil
            }
            let byColl = Self.membersByCollection(memberRows ?? [])
            // Preserve unsynced optimistic collections (those with a pending
            // collections upsert op in the outbox): a just-created/edited list
            // isn't in `enriched` yet, so the replace would wipe it off the UI
            // until the next flush (spec 02-sync-engine §1.3 localPending).
            try db.replaceAllAtomically(ItemCollection.self) { conn, local in
                let known = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let enriched = base.map { c -> ItemCollection in
                    var out = c
                    if memberRows == nil {
                        out.members = known[c.id]?.members ?? []
                        out.myRole = c.ownerId == userId ? "owner" : known[c.id]?.myRole
                    } else {
                        let ms = byColl[c.id] ?? []
                        out.members = ms.map { $0.0 }
                        out.myRole = c.ownerId == userId ? "owner" : ms.first { $0.0 == userId }?.1
                    }
                    return out
                }
                // A list whose DELETE is still queued stays gone: this now runs
                // on every membership event, not only after a flush.
                let ops = try OutboxStore.pending(in: conn).filter { $0.tableName == "collections" } + queuedAtStart
                let pendingDeletes = Set(ops.filter { $0.kind == .delete }.map(\.rowId))
                let pending = Set(ops.filter { $0.kind == .upsert || $0.kind == .rpc }.map(\.rowId))
                // A queued row keeps its content intent but takes the membership
                // just read: membership is server truth, never a local edit.
                return SyncDecision.mergeHydratedRows(remote: enriched.filter { !pendingDeletes.contains($0.id) },
                                                      local: local, pendingIds: pending) { l, r in
                    var out = l
                    out.members = r.members
                    out.myRole = r.myRole
                    return out
                }
            }
            membershipUnresolved = memberRows == nil
        } catch {
            // The catch-up may have applied rows whose membership it can't know.
            membershipUnresolved = true
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

    // MARK: - the cal_blocks pull signal (stage 2, deterministic-occurrence-ids.md §3c)

    /// The last `cal_blocks` read that SUCCEEDED, stamped inside
    /// `hydrateCalBlocks` — the full hydrate and the catch-up's full replace
    /// both go through it. The recurrence top-up runs only after this advances
    /// (and not when the read hit the row cap, §f). The generic "pull
    /// succeeded" signals lie for this: the first pull of a session stamps
    /// success unconditionally, and the hydrate ignores this table's result.
    private var lastCalBlocksPull: CalBlocksPull?
    private var calBlocksPullSeq = 0

    public func calBlocksPull() -> CalBlocksPull? { lastCalBlocksPull }

    /// A signed-out / switched user: the next account's top-up must wait for
    /// ITS own successful read.
    public func resetCalBlocksPull() { lastCalBlocksPull = nil }

    @discardableResult
    private func hydrateCalBlocks() async -> Bool {
        do {
            // Per-row tolerant decode (see replace()): a single bad cal_block row
            // mustn't wipe the whole schedule. The RAW count is what the row cap
            // (PostgREST max_rows = 1000) is judged on.
            let raw = try await gateway.fetchAllRaw(table: "cal_blocks")
            let remote = raw.compactMap { try? decoder.decode(CalBlockRow.self, from: $0) }.map { $0.model() }
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
            calBlocksPullSeq += 1
            lastCalBlocksPull = CalBlocksPull(seq: calBlocksPullSeq, at: Date(), rowCount: raw.count)
            return true
        } catch {
            print("[hydrate] cal_blocks failed, leaving local intact: \(error)")
            return false
        }
    }
}

/// One successful `cal_blocks` read (see `Hydrator.calBlocksPull`). `seq` only
/// ever grows, so "has a new pull landed since?" never compares clocks.
public struct CalBlocksPull: Sendable, Equatable {
    public let seq: Int
    public let at: Date
    /// Rows the server returned. At PostgREST's cap the read is truncated.
    public let rowCount: Int

    /// PostgREST `max_rows`: a read that returned this many rows may be cut
    /// short (ordered by nothing, so any rows can be missing).
    public static let rowCap = 1000
    public var mayBeTruncated: Bool { rowCount >= Self.rowCap }

    public init(seq: Int, at: Date, rowCount: Int) {
        self.seq = seq
        self.at = at
        self.rowCount = rowCount
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
