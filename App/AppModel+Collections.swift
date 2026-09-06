// Phase 3 orchestration — shared collections, accountability (move-to-task),
// and beta feedback. 1:1 with the Android AppViewModel:
//
//  • Routing: OWN/unshared lists take the whole-row outbox path (handles new
//    rows + offline). SHARED lists take an optimistic local write + an atomic
//    item RPC so two members editing concurrently don't clobber the items array.
//  • Each mutation re-resolves the LATEST collection from the store first
//    (the web's functional-update guard) so a stale captured copy can't revert
//    a concurrent edit.

import Foundation
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckSync

extension AppModel {

    // MARK: - shared / role predicates

    /// Shared if it has members, or it's owned by someone else. Guarded on a
    /// KNOWN current uid — a transiently-null uid must not mis-classify your OWN
    /// list as shared (that would route edits down the RPC-only path with no
    /// outbox → silent loss).
    func isShared(_ c: ItemCollection) -> Bool {
        // cachedUserId (not auth.currentUserId) — this runs per collection card in a
        // view body; auth.currentUserId hits the keychain synchronously, which during
        // a notification-tap state-restoration snapshot trips the T4 crash. [[cached]]
        let uid = cachedUserId
        return !(c.members ?? []).isEmpty || (c.ownerId != nil && uid != nil && c.ownerId != uid)
    }
    /// Owner (or a local/demo row with no ownerId). Gates rename/recolor/delete/share.
    func isOwner(_ c: ItemCollection) -> Bool {
        let uid = cachedUserId
        return c.ownerId == nil || c.ownerId == uid
    }
    /// A view-only member can't edit items; owner + editor + local can.
    func canEdit(_ c: ItemCollection) -> Bool { c.myRole != "viewer" }

    // Read the CACHED identity (seeded on start(), refreshed from the auth
    // stream), never `auth.currentSession` — that does a synchronous keychain
    // read per call and reading it from a view body during a notification-tap
    // state-restoration snapshot aborts with a CATransaction NSAssertion (T4).
    var currentUserName: String? { cachedUserName }
    var currentEmail: String? { cachedEmail }

    // MARK: - account management (Settings · Account)

    /// True for an email/password account (vs Google-only) — gates "Change
    /// password" vs "Add a password" copy in Settings.
    var hasPassword: Bool { cachedHasPassword }   // cached — Settings body reads it; avoids a keychain read during render (T4)

    func updateDisplayName(_ name: String) async -> AuthOutcome {
        guard let auth = coordinator?.auth else { return .error("Not signed in.") }
        let outcome = await auth.updateDisplayName(name)
        // Reflect the new name in the cached identity immediately — the auth
        // `.userUpdated` event also refreshes it, but updating here avoids a
        // stale Settings row / avatar between the save and that async event.
        if case .ok = outcome {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { setCachedUserName(trimmed) }
        }
        return outcome
    }

    /// Re-auth with the current password, then set the new one (Android parity:
    /// a password change requires proving the current password first).
    func changePassword(current: String?, new: String) async -> AuthOutcome {
        guard let auth = coordinator?.auth else { return .error("Not signed in.") }
        if hasPassword {
            guard let email = currentEmail, !email.isEmpty else {
                return .error("Can't verify your current password — no email is set on this account.")
            }
            guard let current, !current.isEmpty else { return .error("Enter your current password.") }
            if case .error(let msg) = await auth.reauthenticate(email: email, password: current) {
                return .error(msg)
            }
        }
        return await auth.changePassword(new)
    }

    func deleteAccount() async -> AuthOutcome {
        guard let auth = coordinator?.auth else { return .error("Not signed in.") }
        let outcome = await auth.deleteAccount()
        if case .ok = outcome {
            // The server wipe + signOut already happened (the latter also fires
            // the reactive scrub in observeAuth); scrub device-local content +
            // wipe the local DB here too in case that event is delayed.
            scrubDeviceLocalUserContent()
            try? db?.clearAll()
        }
        return outcome
    }

    // MARK: - mutate helpers (route shared vs own)

    /// Metadata-only change (name/color/subtitle/archived). Shared → a partial
    /// UPDATE so the items JSONB isn't shipped + can't clobber a member's edit.
    private func mutateCollection(_ id: String, _ transform: (ItemCollection) -> ItemCollection) {
        guard let coord = coordinator, let db, let latest = try? db.fetchById(ItemCollection.self, id: id) else { return }
        let next = transform(latest)
        if isShared(latest) {
            try? db.save(next)
            let share = coord.share
            enqueueCollectionRPC(id) {
                await share.updateCollectionFields(id: id, name: next.name, color: next.color,
                                                   subtitle: next.subtitle ?? "", archived: next.archived ?? false)
            }
        } else {
            Task { try? await coord.write.upsertCollection(next, nowISO: Self.isoNow()) }
        }
    }

    /// Item-array change. Shared → optimistic local write + the atomic item RPC
    /// queued through the OUTBOX as an `rpc` op (one transaction with the row
    /// save): it retries offline / on a 5xx like every other edit, and a
    /// server REFUSAL rolls the row back to the server's copy with a visible
    /// error (`handleCollectionRPCRejected`). The old fire-and-forget RPC left
    /// a failed write's optimistic row to be silently deleted by the next
    /// echo / hydrate. `rpc` receives the resulting row and returns the
    /// descriptor (idempotent by item id, so a replay is a no-op).
    private func mutateCollectionItem(
        _ id: String,
        _ transform: (ItemCollection) -> ItemCollection,
        rpc: (ItemCollection) -> CollectionRPC
    ) {
        guard let coord = coordinator, let db, let latest = try? db.fetchById(ItemCollection.self, id: id) else { return }
        let next = transform(latest)
        if isShared(latest) {
            let descriptor = rpc(next)
            let write = coord.write
            let now = Self.isoNow()
            Task { try? await write.applyCollectionRPC(next, rpc: descriptor, nowISO: now) }
        } else {
            Task { try? await coord.write.upsertCollection(next, nowISO: Self.isoNow()) }
        }
    }

    /// The outbox dropped a refused shared-list RPC (terminal): re-pull the
    /// server's copy of the list (rolls the optimistic row back) and say so
    /// once on the Lists surface — never a silent no-op.
    func handleCollectionRPCRejected(collectionId: String, fn: String, error: Error) {
        let name = ((try? db?.fetchById(ItemCollection.self, id: collectionId)) ?? nil)?.name
        collectionSyncError = Self.collectionRPCRejectionMessage(fn: fn, listName: name)
        Task { await coordinator?.rehydrateCollections() }
    }

    /// Pure: the one-line explanation for a refused shared-list edit.
    nonisolated static func collectionRPCRejectionMessage(fn: String, listName: String?) -> String {
        let what: String
        switch fn {
        case "collection_add_item": what = "add that item to"
        case "collection_remove_item": what = "remove that item from"
        case "collection_update_item": what = "edit that item on"
        case "collection_set_item_flag": what = "update that item on"
        case "collection_set_item_promotion": what = "mark that item on"
        default: what = "change"
        }
        let list = listName.map { "\u{201C}\($0)\u{201D}" } ?? "the shared list"
        return "Couldn\u{2019}t \(what) \(list) \u{2014} the change was undone. You may no longer have access."
    }

    // MARK: - collection CRUD

    @discardableResult
    func addCollection(name: String, color: String = "indigo", existing: [ItemCollection]) -> ItemCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let write else { return nil }
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let col = ItemCollection(id: newUUID(), name: trimmed, color: color, subtitle: nil,
                                 items: [], sortOrder: nextOrder, archived: false)
        Task { try? await write.upsertCollection(col, nowISO: Self.isoNow()) }
        return col
    }

    func renameCollection(_ col: ItemCollection, name: String) {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty else { return }
        mutateCollection(col.id) { var c = $0; c.name = nm; return c }
    }
    func recolorCollection(_ col: ItemCollection, color: String) {
        mutateCollection(col.id) { var c = $0; c.color = color; return c }
    }
    func setCollectionSubtitle(_ col: ItemCollection, subtitle: String?) {
        let s = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateCollection(col.id) { var c = $0; c.subtitle = (s?.isEmpty ?? true) ? nil : s; return c }
    }
    func archiveCollection(_ id: String, archived: Bool) {
        mutateCollection(id) { var c = $0; c.archived = archived; return c }
    }
    func deleteCollection(_ id: String) {
        guard let write else { return }
        Task { try? await write.deleteCollection(id: id, nowISO: Self.isoNow()) }
    }

    // MARK: - collection items

    func addCollectionItem(_ col: ItemCollection, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = CollectionItem(id: newUUID(), body: text, at: Self.isoNow())
        mutateCollectionItem(col.id, { var c = $0; c.items.append(item); return c },
            rpc: { _ in CollectionRPC.addItem(collectionId: col.id, id: item.id, body: item.body, at: item.at) })
    }
    func updateCollectionItemBody(_ col: ItemCollection, itemId: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].body = text }; return n },
            rpc: { _ in CollectionRPC.updateItem(collectionId: col.id, itemId: itemId, body: text) })
    }
    func toggleCollectionItemPin(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].pinned = !(n.items[i].pinned ?? false) }; return n },
            rpc: { next in
                let v = next.items.first { $0.id == itemId }?.pinned ?? false
                return CollectionRPC.setItemFlag(collectionId: col.id, itemId: itemId, flag: "pinned", value: v)
            })
    }
    func toggleCollectionItemDone(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].done = !(n.items[i].done ?? false) }; return n },
            rpc: { next in
                let v = next.items.first { $0.id == itemId }?.done ?? false
                return CollectionRPC.setItemFlag(collectionId: col.id, itemId: itemId, flag: "done", value: v)
            })
    }
    func removeCollectionItem(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; n.items.removeAll { $0.id == itemId }; return n },
            rpc: { _ in CollectionRPC.removeItem(collectionId: col.id, itemId: itemId) })
    }

    // MARK: - move-to-task accountability

    /// LOOP = keep everyone in the loop (shared accountability); SELF = just me.
    enum PromoteMode { case selfOnly, loop }

    /// Mark an item promoted (struck + status chip), synced to all members on a
    /// shared list. done = false → "on it", nil → static "Promoted".
    private func markItemPromoted(_ col: ItemCollection, itemId: String, assignee: String, done: Bool?, dueAt: String?) {
        mutateCollectionItem(col.id,
            { c in
                var n = c
                if let i = n.items.firstIndex(where: { $0.id == itemId }) {
                    n.items[i].promoted = true
                    n.items[i].assignee = assignee
                    n.items[i].promotedDone = done
                    n.items[i].dueAt = dueAt
                }
                return n
            },
            rpc: { _ in CollectionRPC.setItemPromotion(collectionId: col.id, itemId: itemId, assignee: assignee, done: done, dueAt: dueAt) })
    }

    /// Turn a collection item into a task. LOOP on a shared list links the task
    /// to the item (so completion/lateness flows back to everyone) + sets a "by"
    /// time and schedules it on the calendar.
    func moveItemToTask(_ col: ItemCollection, item: CollectionItem, mode: PromoteMode, dueAtIso: String? = nil) {
        // Don't duplicate a task for an item already promoted + in flight (a
        // completed one may be re-promoted for a fresh cycle).
        if item.promoted == true && item.promotedDone != true { return }
        let loop = mode == .loop && isShared(col)
        let task = addTask(name: item.body, estimateMin: 25, tags: ["from-collection"],
                           sourceCollectionId: loop ? col.id : nil,
                           sourceItemId: loop ? item.id : nil,
                           dueAt: loop ? dueAtIso : nil)
        if loop, let dueAtIso, let dt = Self.localDateTime(fromISO: dueAtIso) {
            scheduleTaskAt(task, date: dt.dateISO, startTime: dt.time)
        }
        // "Just me" on a SHARED list must NOT announce to the others (it would mark
        // the shared item "<you>'s on it" for everyone). Only mark when keeping-in-
        // loop, or on a solo list (a local-only "Promoted" chip).
        if loop || !isShared(col) {
            markItemPromoted(col, itemId: item.id, assignee: currentUserName ?? "Someone",
                             done: loop ? false : nil, dueAt: loop ? dueAtIso : nil)
        }
    }

    // MARK: - task add / completion (with shared-item notification)

    @discardableResult
    func addTask(name: String, estimateMin: Int = 25, tags: [String]? = nil,
                 lifeArea: String? = nil, firstPhysicalAction: String? = nil, later: Bool? = nil,
                 sourceCollectionId: String? = nil, sourceItemId: String? = nil, dueAt: String? = nil) -> TaskItem {
        let now = Self.isoNow()
        // Build the COMPLETE task in one write — mirrors Android's wide addTask.
        // The old mutate-then-resave idiom (set lifeArea / firstPhysicalAction
        // after) issued a second saveTask whose unordered Task could clobber the
        // first, and flashed a half-populated row to observers.
        var t = TaskItem(id: newUUID(), name: name, estimateMin: estimateMin, tags: tags,
                         createdAt: now, updatedAt: now,
                         sourceCollectionId: sourceCollectionId, sourceItemId: sourceItemId, dueAt: dueAt)
        t.lifeArea = lifeArea
        t.firstPhysicalAction = firstPhysicalAction
        t.later = later
        saveTask(t)
        return t
    }

    /// Toggle done + apply completion stamping. Completing a task promoted from a
    /// shared collection item flips the shared item to "done by <name>" + notifies
    /// the other members (best-effort).
    func toggleDone(_ task: TaskItem) {
        // A recurring OCCURRENCE's id is its cal_block id — complete the BLOCK,
        // never the template (which would end the whole series). Mirrors Android.
        if let occ = occurrenceBlockForId(task.id) {
            var next = occ
            let nextDone = !occ.done
            next.done = nextDone
            next.skipped = false
            next.completedAt = nextDone ? Self.isoNow() : nil
            saveBlock(next)
            return
        }
        var flipped = task
        flipped.done.toggle()
        let stamped = applyCompletion(flipped, prior: task, nowISO: Self.isoNow())
        saveTask(stamped)
        if let cid = task.sourceCollectionId, let iid = task.sourceItemId, flipped.done != task.done {
            let share = coordinator?.share
            let by = currentUserName ?? "Someone"
            // Un-completing has to travel too: the shared row stays ticked
            // forever otherwise, with a task behind it that is no longer done.
            let action: CollectionShareClient.TaskDoneAction = flipped.done ? .done : .reopen
            Task { await share?.taskDone(collectionId: cid, itemId: iid, taskName: task.name, by: by, action: action) }
        }
    }

    /// Resolve a list-row id to the recurring OCCURRENCE cal_block behind it
    /// (nil for a normal task). Reads the live local store so callers (toggle,
    /// skip, focus) don't need to thread the tasks/blocks lists through.
    func occurrenceBlockForId(_ rowId: String) -> CalBlock? {
        let tasks = (try? taskRepo?.all()) ?? []
        let blocks = (try? db?.fetchAllCalBlocks()) ?? []
        return occurrenceBlockFor(rowId, tasks: tasks, blocks: blocks)
    }

    /// Skip ("cancel today") one recurring occurrence — hides just this day; the
    /// series keeps generating tomorrow. `blockId` is the occurrence row's id.
    func skipOccurrence(_ blockId: String) {
        guard let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == blockId }) else { return }
        var next = block
        next.skipped = true
        next.done = false
        next.completedAt = nil
        saveBlock(next)
    }

    /// Defer / undefer a task to "Later".
    func setLater(_ task: TaskItem, _ later: Bool) {
        var next = task
        next.later = later
        next.updatedAt = Self.isoNow()
        saveTask(next)
    }

    /// Set/clear a task's recurrence and realign its future cal_blocks
    /// (regenerateForTask, anchored on the task's earliest existing block).
    func setRecurrence(_ task: TaskItem, _ recurrence: Recurrence?) {
        var next = task
        next.recurrence = recurrence
        next.updatedAt = Self.isoNow()
        let existing = (try? db?.blocks(forTask: task.id)) ?? []
        saveTaskWithRecurrence(next, existingBlocks: existing)
    }

    /// Fire the shared-item completion notification after a Focus session that
    /// marked the task done (mirrors finishFocus's taskDone hook).
    func notifyTaskDoneIfShared(_ task: TaskItem) {
        notifySharedItem(task, action: .done)
    }

    /// The task behind a promoted shared item is gone (deleted) or no longer
    /// done → un-tick the collection row for everyone. Server-side the reopen
    /// is allowed for the assignee/owner, and for any editor once no user holds
    /// a linked task, so delete-then-reopen works in either order.
    func notifyTaskReopenedIfShared(_ task: TaskItem) {
        notifySharedItem(task, action: .reopen)
    }

    private func notifySharedItem(_ task: TaskItem, action: CollectionShareClient.TaskDoneAction) {
        guard let cid = task.sourceCollectionId, let iid = task.sourceItemId else { return }
        let share = coordinator?.share
        let by = currentUserName ?? "Someone"
        Task { await share?.taskDone(collectionId: cid, itemId: iid, taskName: task.name, by: by, action: action) }
    }

    /// Before starting Focus on `newTaskId`, finalize a still-in-flight session
    /// that belongs to a DIFFERENT task — write its Session row + accumulate its
    /// focus time — so opening Focus on B doesn't silently discard A's elapsed
    /// time when FocusTimer.start overwrites the live session. 1:1 with the
    /// Android startFocus finalize.
    func finalizeDisplacedFocus(forNewTaskId newTaskId: String) {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, cur.taskId != newTaskId else { return }
        let elapsed = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        // A displaced SHARED focus (partner/assign) belongs to someone else — its
        // time accrues onto the OWNER's task via log_shared_focus, never an own
        // Session/totalFocused (there is no local row for it, so the old
        // taskRepo.fetch guard silently discarded it — the T3 no-op bug). CAP the
        // elapsed: this session may have been resurrected from the store after a
        // process-kill, so `now - sessionStart` is wall-clock — an uncapped value
        // would dump the whole app-closed time onto the owner (T2). Idempotent per
        // session id (migration 046).
        if let level = cur.sharedFocusLevel, levelCanComplete(level) {
            let taskId = cur.taskId
            let sessionId = cur.id ?? newUUID()
            let estimate = cur.sessionEstimateMin
            let capped = Self.cappedSharedElapsedSec(rawSec: elapsed, estimateMin: cur.sessionEstimateMin)
            Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: capped,
                                                    estimateMin: estimate, sessionId: sessionId) }
            return
        }
        guard let prev = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil else { return }
        saveSession(Session(id: cur.id ?? newUUID(), taskId: prev.id, taskName: prev.name,
                            estimateMin: prev.estimateMin, actualSec: elapsed, completedAt: Self.isoNow()))
        // One true shared session: an OWNER session on a partner-shared task
        // accrues via the exactly-once ledger with the SHARED session id — the
        // direct bump would double-count against the partner's finalize of the
        // same session. Capped like the other resurrected paths; durable (the
        // pending ledger retries a failed RPC on foreground/relaunch).
        if accruesViaSharedLedger(cur, taskId: prev.id) {
            let taskId = prev.id
            let sessionId = cur.id ?? newUUID()
            let estimate = cur.sessionEstimateMin
            let capped = Self.cappedSharedElapsedSec(rawSec: elapsed, estimateMin: cur.sessionEstimateMin)
            Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: capped,
                                                    estimateMin: estimate, sessionId: sessionId) }
            return
        }
        var bumped = prev
        bumped.totalFocused += elapsed
        bumped.updatedAt = Self.isoNow()
        saveTask(bumped)
    }

    /// For a focus row id: if it's a recurring OCCURRENCE, the (block, template)
    /// pair — the session runs on the template but completion marks the block;
    /// else nil (focus the task as-is). Used by FocusView to build the live
    /// session with the right identity.
    func occurrenceFocusTarget(_ rowId: String) -> (block: CalBlock, template: TaskItem)? {
        guard let block = occurrenceBlockForId(rowId),
              let tpl = (try? taskRepo?.all())?.first(where: { $0.id == block.taskId }) else { return nil }
        return (block, tpl)
    }

    /// Finish a Focus session: persist the Session, accumulate the task's
    /// totalFocused, optionally mark it done (with completion stamping + the
    /// shared-item notification), and record a session recap. 1:1 with the
    /// Android finishFocus. When `occurrenceBlockId` is set the session/focus
    /// time accrue on the TEMPLATE (`task`) but completion marks the BLOCK done,
    /// so just that day is ticked off without ending the series.
    ///
    /// `sharedLedger` (one true shared session): the task is partner-shared, so
    /// its focus time accrues EXCLUSIVELY via log_shared_focus with the SHARED
    /// session id (exactly-once per id — both participants finalize the same
    /// session, one accrual lands; migrations 046/047 admit the owner). The
    /// direct totalFocused bump is skipped (the server-side accrual comes back
    /// via realtime/hydrate); the own Session row (insights) is still written
    /// with id = the shared session id. `ledgerSec` overrides the accrued
    /// seconds (resurrected sessions pass a capped value); nil → elapsedSec.
    func finishFocus(task: TaskItem, session: Session, elapsedSec: Int, markDone: Bool,
                     occurrenceBlockId: String? = nil,
                     sharedLedger: Bool = false, ledgerSec: Int? = nil) {
        saveSession(session)
        var focused = task
        if !sharedLedger { focused.totalFocused += elapsedSec }
        focused.updatedAt = Self.isoNow()
        // Resolve the exact task row this finish lands (completion stamping /
        // occurrence semantics), so the sharedLedger path below can write it
        // ITSELF, ordered before the flush + RPC.
        var landedRow = focused
        if let occurrenceBlockId, let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == occurrenceBlockId }) {
            // Always accrue focus on the template; mark the DAY's block done.
            if markDone {
                var doneBlock = block
                doneBlock.done = true
                doneBlock.skipped = false
                doneBlock.completedAt = Self.isoNow()
                saveBlock(doneBlock)
            }
        } else if markDone {
            var done = focused
            done.done = true
            landedRow = applyCompletion(done, prior: task, nowISO: Self.isoNow())
            notifyTaskDoneIfShared(task)
        }
        if sharedLedger {
            // Order matters: enqueue the (whole-row) task write DIRECTLY and
            // await it, flush it to the server, THEN fire the RPC — so the
            // upsert's stale totalFocused can't land after (and stomp) the
            // fresh server-side accrual. Creating the flush Task before the
            // row op was enqueued (the old shape) let the row flush late.
            // Accrual is durable: a failed RPC lands in the pending ledger.
            let write = self.write
            let coord = coordinator
            let row = landedRow
            let taskId = task.id, sessionId = session.id
            let sec = ledgerSec ?? elapsedSec
            let estimate = session.estimateMin ?? task.estimateMin
            Task {
                try? await write?.upsertTask(row, nowISO: Self.isoNow())
                await coord?.flushNow()
                await self.logSharedFocusDurable(taskId: taskId, actualSec: sec,
                                                 estimateMin: estimate, sessionId: sessionId)
            }
        } else {
            saveTask(landedRow)
        }
        sendSessionRecap(taskName: task.name, away: false)
        // Today's "Just now" recap card (Android: _lastRecap.value = RecapState(...)).
        lastRecap = RecapState(taskName: task.name, focusedSec: elapsedSec,
                               at: Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - shared focus (T3, Option B — recipient side)

    /// The grace window added to a shared session's estimate when capping the
    /// elapsed accrued onto the OWNER. Generous enough to credit a genuine
    /// overrun, tight enough that an orphan resurrected from the store after a
    /// process-kill (whose `now - sessionStart` is wall-clock) can't dump hours.
    static let sharedFocusCapGraceSec = 30 * 60

    /// Seconds to accrue onto an OWNER's shared task from a session RESURRECTED
    /// from the store (displaced / notification-end / relaunch reap), capped to
    /// the session estimate + a grace window so a stale orphan measuring
    /// wall-clock time can never over-credit the owner (T2). In-app finishes (a
    /// live foreground timer) are already bounded and pass their real elapsed.
    static func cappedSharedElapsedSec(rawSec: Int, estimateMin: Int) -> Int {
        let cap = max(1, estimateMin) * 60 + sharedFocusCapGraceSec
        return min(max(0, rawSec), cap)
    }

    /// Open a REAL Focus session on a task shared WITH me (partner/assign). The
    /// recipient doesn't own the task (no local row), so we synthesize a display
    /// TaskItem from the read-only detail and carry the shared level via the
    /// router — FocusView seeds the live session from it and finalize accrues onto
    /// the OWNER's task (finalizeSharedFocus), never an own Session/totalFocused.
    func beginSharedFocus(_ detail: SharedTaskDetail) {
        guard levelCanComplete(detail.level) else { return }   // partner/assign only
        let now = Self.isoNow()
        // totalFocused stays 0 so the recipient's timer starts fresh at their own
        // contribution this session; log_shared_focus reflects it onto the owner.
        let synthesized = TaskItem(id: detail.taskId, name: detail.name,
                                   estimateMin: detail.estimateMin, totalFocused: 0,
                                   objectives: detail.objectives, lifeArea: detail.lifeArea,
                                   createdAt: detail.createdAt ?? now, updatedAt: now,
                                   dueAt: detail.dueAt)
        router.sharedFocus = SharedFocusContext(taskId: detail.taskId, title: detail.name,
                                                estimateMin: detail.estimateMin, level: detail.level)
        router.focusTask = synthesized
    }

    /// Finalize a shared Focus session: accrue the recipient's focus onto the
    /// OWNER's task via log_shared_focus (partner/assign only, gated server-side),
    /// optionally mark it done, and — when the recipient explicitly ended it —
    /// show them a normal local recap. Never writes an own Session/totalFocused
    /// (the task isn't theirs). `elapsedSec ≤ 0` still shows the recap but the RPC
    /// no-ops server-side. Durable: a failed accrual lands in the pending
    /// ledger and is retried on foreground/relaunch (idempotent per sessionId).
    func finalizeSharedFocus(taskId: String, taskName: String, sessionId: String,
                             elapsedSec: Int, estimateMin: Int, markDone: Bool, showRecap: Bool) {
        Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: elapsedSec,
                                                estimateMin: estimateMin, sessionId: sessionId) }
        if markDone {
            Task { try? await shareState.completeSharedTask(taskId: taskId, done: true) }
        }
        if showRecap {
            sendSessionRecap(taskName: taskName, away: false)
            lastRecap = RecapState(taskName: taskName, focusedSec: elapsedSec,
                                   at: Date().timeIntervalSince1970 * 1000)
        }
    }

    /// Apply opt-in shares AFTER the just-created task row is guaranteed to exist
    /// SERVER-side (T2). task_share validates ownership server-side, so it must not
    /// race the task insert — that raises `not_your_task` and the share is silently
    /// dropped. The web awaits `awaitPendingUpsert('tasks', id)`; the iOS write
    /// path is the offline outbox, so we re-issue the (idempotent, whole-row)
    /// upsert to guarantee it's enqueued, then flush the outbox to land it on the
    /// server before sharing. Per-recipient failures are RETURNED for a caller
    /// that wants to surface them; the create flow deliberately discards them to
    /// stay non-blocking (a dropped share is re-addable from the Share sheet).
    @discardableResult
    func applyCreateShares(task: TaskItem, shares: [(user: String, level: ShareLevel)]) async -> [String] {
        guard !shares.isEmpty else { return [] }
        // Deterministically enqueue the tasks upsert (addTask already did this
        // fire-and-forget; re-issuing is idempotent and removes the timing race),
        // then drain the outbox so the row is server-side before task_share.
        if let write = coordinator?.write {
            try? await write.upsertTask(task, nowISO: Self.isoNow())
        }
        await coordinator?.flushNow()
        var failed: [String] = []
        for (user, level) in shares {
            do {
                try await shareState.shareTask(taskId: task.id, user: user, level: level)
                await shareState.notifyShare(taskId: task.id, recipientId: user)
            } catch {
                failed.append(user)   // surfaced to the caller, not swallowed
            }
        }
        return failed
    }

    // MARK: - sharing (edge-function backed)

    /// Share with an email. On success the OWNER's local row is marked shared
    /// AT ONCE (`members` from the function's membership rows, else the added
    /// user) and the collections are re-hydrated — the owner's client used to
    /// keep `members == nil` until the next full hydrate, so `isShared` stayed
    /// false and its next item edit shipped the whole `items` JSONB, clobbering
    /// the member's atomic RPC edits.
    func shareCollection(_ collectionId: String, email: String, role: String) async -> ShareOutcome {
        guard let coord = coordinator else { return .error }
        let result = await coord.share.shareDetailed(collectionId: collectionId, email: email, role: role)
        if result.outcome == .ok { applyLocalMembers(collectionId, joined: result.memberUserIds) }
        if result.outcome == .ok || result.outcome == .invited { await coord.rehydrateCollections() }
        return result.outcome
    }
    func unshareCollection(_ collectionId: String, userId: String) async {
        await coordinator?.share.unshare(collectionId: collectionId, userId: userId)
        await coordinator?.rehydrateCollections()
    }
    func cancelCollectionInvite(_ collectionId: String, email: String) async {
        await coordinator?.share.cancelInvite(collectionId: collectionId, email: email)
    }
    /// Fire-and-forget (not screen-scoped): the caller pops the screen immediately,
    /// which would cancel a screen-scoped task before the leave RPC + local drop.
    func leaveCollection(_ collectionId: String) {
        guard let coord = coordinator, let db else { return }
        let share = coord.share
        Task {
            await share.leave(collectionId: collectionId)
            try? db.deleteById(ItemCollection.self, id: collectionId)  // lose access → drop locally
            await coord.rehydrateCollections()
        }
    }
    /// The share sheet's roster. Listing is also how the owner LEARNS a mailed
    /// invitee has claimed their invite (signed up): the joined ids are synced
    /// onto the local row so `isShared` flips without a full hydrate.
    func listCollectionMembers(_ collectionId: String) async -> [CollectionMemberInfo] {
        let members = await coordinator?.share.listMembers(collectionId: collectionId) ?? []
        applyLocalMembers(collectionId, joined: CollectionShareClient.joinedUserIds(members))
        return members
    }

    /// Merge joined member ids onto the local row (union with what's known;
    /// the hydrate is the authority for removals). Owner rows only — a member's
    /// own role/members come from the hydrate.
    private func applyLocalMembers(_ collectionId: String, joined: [String]) {
        guard let db, let latest = try? db.fetchById(ItemCollection.self, id: collectionId),
              isOwner(latest) else { return }
        let uid = cachedUserId
        let merged = Self.mergedMembers(existing: latest.members, joined: joined, ownerId: uid)
        guard merged != (latest.members ?? []) else { return }
        var next = latest
        next.members = merged
        if next.myRole == nil, next.ownerId == nil || next.ownerId == uid { next.myRole = "owner" }
        try? db.save(next)
    }

    /// Pure: existing ∪ joined, the owner never listed as a member, order kept.
    nonisolated static func mergedMembers(existing: [String]?, joined: [String], ownerId: String?) -> [String] {
        var out = existing ?? []
        for id in joined where !id.isEmpty && id != ownerId && !out.contains(id) { out.append(id) }
        return out
    }

    // MARK: - trusted circle (People / Connections)

    /// Build a live circle roster view-model bound to the shared CircleClient.
    /// Nil client (unconfigured / demo boot) degrades to an empty, read-only
    /// roster — mirrors the web `useCircle` no-`sb` guard.
    func makeCircleModel() -> CircleModel {
        CircleModel(client: coordinator?.circle)
    }

    // MARK: - co-focus presence (M5)

    /// The name we broadcast to co-focus peers (so the other side sees who's
    /// with them) — display name → email local-part → "Someone".
    var selfDisplayName: String { currentUserName ?? currentEmail ?? "Someone" }

    /// Build a co-focus presence model for a task id, bound to the shared
    /// realtime client. Nil client / signed-out (no user id) degrades to an inert
    /// model that never joins — the presence UI simply shows nothing.
    /// Every model's channel ops run on AppModel's ONE co-focus chain
    /// (chainCoFocusOp — strict FIFO, head read at enqueue time, never a stale
    /// captured task), and teardown consults `liveCoFocusTaskId` at EXECUTION
    /// time: when the session-lifetime channel owns this topic, the model
    /// detaches (keeps the topic-deduped channel subscribed) instead of
    /// removeChannel-ing it out from under the live stream.
    func makeCoFocusModel(taskId: String) -> CoFocusModel {
        let m = CoFocusModel(client: coordinator?.coFocus, taskId: taskId,
                             selfId: coordinator?.auth.currentUserId, selfName: selfDisplayName)
        m.chainOp = { [weak self] op in
            self?.chainCoFocusOp(op) ?? Task { @MainActor in await op() }
        }
        m.preserveTopicOnStop = { [weak self] in self?.liveCoFocusTaskId == taskId }
        return m
    }

    // MARK: - feedback

    /// One-way beta feedback with auto-attached context. False on failure
    /// (offline / not configured) so the composer can offer a retry.
    func sendFeedback(body: String, category: String?, screen: String?) async -> Bool {
        guard let fb = coordinator?.feedback else { return false }
        let device = "\(Self.deviceModelName) · iOS \(UIDevice.current.systemVersion)"
        return await fb.submit(id: newUUID(), body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: category, email: currentEmail,
                               appVersion: Self.appVersion, platform: "ios", device: device, screen: screen)
    }

    // MARK: - Safety (App Store Guideline 1.2 — user-generated/shared content)

    /// Device-local set of blocked collaborator emails (lowercased). A blocked
    /// person is removed from your shared lists and can't be re-invited. Cleared
    /// on sign-out alongside the other device-local state.
    private static let blockedEmailsKey = "unstuck.blockedEmails"

    var blockedEmails: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.blockedEmailsKey) ?? [])
    }

    func isBlocked(_ email: String) -> Bool {
        blockedEmails.contains(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Block an abusive collaborator: add to the blocklist + remove them from
    /// this shared collection (so they lose access immediately).
    func blockUser(email: String, inCollection collectionId: String, userId: String?) {
        var s = blockedEmails
        s.insert(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        UserDefaults.standard.set(Array(s), forKey: Self.blockedEmailsKey)
        Task {
            if let userId { await unshareCollection(collectionId, userId: userId) }
            else { await cancelCollectionInvite(collectionId, email: email) }
        }
    }

    /// Report objectionable content / a collaborator. Routes through the
    /// feedback channel (triaged in the Supabase dashboard) so we can act.
    func reportConcern(collectionId: String, about email: String, reason: String) async {
        _ = await sendFeedback(
            body: "⚠️ REPORT — shared collection \(collectionId), member \(email): \(reason)",
            category: "report", screen: "shared-collection")
    }

    /// e.g. "iPhone17,3". (Marketing names need a lookup table; the identifier is
    /// stable + sufficient for triage.)
    static var deviceModelName: String {
        var s = utsname(); uname(&s)
        let m = Mirror(reflecting: s.machine)
        return m.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: - helpers

    /// Parse an ISO-8601 instant into the local-timezone (dateISO "YYYY-MM-DD",
    /// time "HH:mm") used by cal_blocks.
    static func localDateTime(fromISO iso: String) -> (dateISO: String, time: String)? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? {
            let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]; return g.date(from: iso)
        }()
        guard let date else { return nil }
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (Clock.dateISO(date), String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
    }
}
