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
    /// Returns the new task (nil when the item was skipped) — the assistant's
    /// `promote_item_to_task` reports its id (2026-09-20 tooling rules §1).
    @discardableResult
    func moveItemToTask(_ col: ItemCollection, item: CollectionItem, mode: PromoteMode, dueAtIso: String? = nil) -> TaskItem? {
        // Don't duplicate a task for an item already promoted + in flight (a
        // completed one may be re-promoted for a fresh cycle).
        if item.promoted == true && item.promotedDone != true { return nil }
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
        return task
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
            setOccurrenceDone(occ, done: !occ.done)
            return
        }
        // Flip what the CALLER showed onto the STORED row (audit 2026-09-22,
        // C5). Callers hand in a copy taken earlier — the editor's open-time
        // snapshot, a list row — and saving that whole copy reverted every
        // field edited since, on every device (the outbox base is the current
        // row, so the old values went out as a fresh edit). Only done +
        // completedAt are this tap's change. A row already in the target state
        // (ticked elsewhere) needs no write, and a row that is gone (deleted
        // elsewhere, or an occurrence whose block vanished) is never re-created
        // from the copy. taskRepo is nil only when there is no writer either.
        guard let prior = (try? taskRepo?.fetch(id: task.id)) ?? nil else { return }
        let target = !task.done
        // A repeating series' TEMPLATE never takes a done flip (audit
        // 2026-09-22, C3): it ENDS the series — reminders, the horizon top-up
        // and the server's calls all skip a done task. Judged on the STORED
        // row, so a stale copy can't slip past. Occurrence rows (recurrence
        // nil) were routed to their block above; a template that is ALREADY
        // done may still be reopened, to recover a series the old path ended.
        // Same rule as resolveHandsFreeCompletion.
        if prior.recurrence != nil && target { return }
        guard prior.done != target else { return }
        var flipped = prior
        flipped.done = target
        saveTask(applyCompletion(flipped, prior: prior, nowISO: Self.isoNow()))
        // Un-completing has to travel too: the shared row stays ticked
        // forever otherwise, with a task behind it that is no longer done.
        notifySharedItem(prior, action: target ? .done : .reopen)
    }

    /// Mark ONE day of a recurring series done / not done: the occurrence's
    /// cal_block flips (un-skipped, completion-stamped), the template is never
    /// touched. Shared by the list toggle and the hands-free drain (widget /
    /// Siri "Done" on an occurrence id).
    func setOccurrenceDone(_ block: CalBlock, done: Bool) {
        var next = block
        next.done = done
        next.skipped = false
        next.completedAt = done ? Self.isoNow() : nil
        saveBlock(next)
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
    /// (regenerateForTask, anchored on the task's earliest LIVE timed block —
    /// recurrenceAnchor). Returns false and changes nothing when a repeat is
    /// set on a task with no timed block: the caller asks for a start day and
    /// time and starts the series with scheduleTaskAt (audit 2026-09-22, C7).
    @discardableResult
    func setRecurrence(_ task: TaskItem, _ recurrence: Recurrence?) -> Bool {
        let existing = (try? db?.blocks(forTask: task.id)) ?? []
        // "Never" carries today's ticked occurrence onto the task, and a
        // repeat turned back on never leaves a DONE template (audit
        // 2026-09-22, C3) — the same rule the assistant's set_task_recurrence
        // follows.
        let today = Clock.todayISO(), now = Self.isoNow()
        var next = taskAfterSettingRecurrence(task, recurrence: recurrence, blocks: existing,
                                              todayIso: today, nowISO: now)
        next.updatedAt = now
        // A refused repeat (no timed block to start from, C7) changes nothing,
        // so the carry and the shared-list notice below only follow a save.
        guard saveTaskWithRecurrence(next, existingBlocks: existing) else { return false }
        // A done task made to repeat keeps the day it was done ticked on that
        // day's occurrence (audit 2026-09-22, C3). Written straight through,
        // not via saveBlock: its un-park reads the task row, which may not
        // carry the repeat yet, and a stale plain row there is written back
        // whole — reverting it. A done-only change has nothing for Google.
        let carried = occurrencesCarryingTaskDone(task, recurrence: recurrence, blocks: existing,
                                                  todayIso: today, nowISO: now)
        if !carried.isEmpty, let write {
            Task { for b in carried { try? await write.upsertCalBlock(b, nowISO: now) } }
        }
        // The done flip travels to a loop-promoted task's shared-list row,
        // as the UI's toggle does — else it stays ticked over an open series.
        if next.done != task.done { notifySharedItem(task, action: next.done ? .done : .reopen) }
        return true
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
        // Land only this finish's delta — totalFocused, plus done/completedAt
        // on markDone — on the STORED row (audit 2026-09-22, C5). `task` is
        // FocusView's copy from when Focus opened: writing it whole reverted
        // renames, first steps, due dates or a completion made during the
        // session, and re-created a task deleted meanwhile. A row that is gone
        // gets no task write at all, and its Session goes up without the task
        // id — sessions.task_id references tasks(id), so the dead id would
        // fail the insert and quarantine the op (the minutes still count).
        let stored = (try? taskRepo?.fetch(id: task.id)) ?? nil
        var session = session
        if stored == nil { session.taskId = nil }
        saveSession(session)
        // Resolve the exact task row this finish lands (completion stamping /
        // occurrence semantics), so the sharedLedger path below can write it
        // ITSELF, ordered before the flush + RPC.
        var landedRow: TaskItem?
        if var focused = stored {
            if !sharedLedger { focused.totalFocused += elapsedSec }
            focused.updatedAt = Self.isoNow()
            landedRow = focused
        }
        if let occurrenceBlockId, let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == occurrenceBlockId }) {
            // Always accrue focus on the template; mark the DAY's block done.
            if markDone {
                var doneBlock = block
                doneBlock.done = true
                doneBlock.skipped = false
                doneBlock.completedAt = Self.isoNow()
                saveBlock(doneBlock)
            }
        } else if markDone, let base = stored, var done = landedRow, focusMayCompleteRow(base), !base.done {
            // Judged on the stored row: a repeat set elsewhere mid-session is
            // respected, and a task already completed elsewhere is neither
            // re-stamped nor announced to its shared list a second time.
            done.done = true
            landedRow = applyCompletion(done, prior: base, nowISO: Self.isoNow())
            notifyTaskDoneIfShared(base)
        }
        // markDone on a recurring TEMPLATE with no occurrence attached falls
        // through deliberately: flipping a template's own `done` ENDS the whole
        // series (it stops generating and appears in no list), which is never
        // what "I finished this session" means. It is reachable from the
        // starts-now notification's "Start" when today's occurrence was ticked
        // or skipped between the notification and the tap. The time still
        // accrues on the series; no day is falsely marked off.
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
                if let row { try? await write?.upsertTask(row, nowISO: Self.isoNow()) }
                await coord?.flushNow()
                await self.logSharedFocusDurable(taskId: taskId, actualSec: sec,
                                                 estimateMin: estimate, sessionId: sessionId)
            }
        } else if let landedRow {
            saveTask(landedRow)
        }
        let name = stored?.name ?? task.name
        sendSessionRecap(taskName: name, away: false)
        // Today's "Just now" recap card (Android: _lastRecap.value = RecapState(...)).
        lastRecap = RecapState(taskName: name, focusedSec: elapsedSec,
                               at: Date().timeIntervalSince1970 * 1000)
    }

    /// The Session for a live focus whose task row is gone (deleted elsewhere
    /// mid-session) — the fallback of the assistant's finish_focus, the
    /// notification's End and the sign-out finalize. It carries NO task id
    /// (audit 2026-09-22, C5), as finishFocus's own row-gone Session: the
    /// dead id failed sessions.task_id's reference to tasks(id), and the op
    /// sat quarantined in the outbox, so the minutes never reached insights
    /// on any device. The column is nullable (`on delete set null`).
    static func goneTaskSession(_ cur: LiveSession, elapsedSec: Int) -> Session {
        Session(id: cur.id ?? newUUID(), taskId: nil, taskName: "Focus session",
                estimateMin: cur.sessionEstimateMin, actualSec: elapsedSec, completedAt: isoNow())
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

    /// May a finished shared session tick the owner's task done? Not a
    /// repeating share (audit 2026-09-22, C3): its row is the owner's series,
    /// the server refuses the tick ('recurring_series'), and the Focus screen /
    /// assistant must not claim a completion that never happened. A share the
    /// list doesn't know yet (not loaded) falls back to the level, which every
    /// caller has already checked — the server still refuses a series.
    func sharedTaskAllowsTick(_ taskId: String) -> Bool {
        shareState.sharedWithMe.first { $0.taskId == taskId }.map(shareCanTickDone) ?? true
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
        if markDone && sharedTaskAllowsTick(taskId) {
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
        await shareCollection(collectionId, email: email, userId: nil, role: role)
    }

    /// Share by email (Someone new) or by user id (a connection tapped in the
    /// Share screen's People section — the roster carries no emails).
    func shareCollection(_ collectionId: String, email: String?, userId: String?, role: String) async -> ShareOutcome {
        guard let coord = coordinator else { return .error }
        let result = await coord.share.shareDetailed(collectionId: collectionId, email: email, userId: userId, role: role)
        if result.outcome.isSuccess, !result.memberUserIds.isEmpty {
            applyLocalMembers(collectionId, joined: result.memberUserIds)
        }
        if result.outcome.isSuccess { await coord.rehydrateCollections() }
        return result.outcome
    }

    /// The ONE Share screen's model (tasks + collections; `.handOver` = the
    /// "Hand over to…" people picker). Bound to the live transport; a nil
    /// coordinator (demo / UITest boot) degrades to empty, inert sections.
    func makeShareScreenModel(target: ShareTarget, mode: ShareScreenModel.Mode = .share) -> ShareScreenModel {
        #if DEBUG
        // UITEST_SHARE_PEOPLE — a scripted roster for the People card shots.
        if let demo = DemoShareTransport.fromEnvironment() {
            return ShareScreenModel(target: target, mode: mode, transport: demo)
        }
        #endif
        return ShareScreenModel(target: target, mode: mode, transport: LiveShareTransport(model: self))
    }

    /// Report a person you shared a task or list with (App Store 1.2 safety) —
    /// same feedback channel as `reportConcern`, with the item named.
    func reportShareConcern(target: ShareTarget, about who: String, reason: String) async {
        switch target {
        case .collection(let id, _):
            await reportConcern(collectionId: id, about: who, reason: reason)
        case .task(let id, _):
            _ = await sendFeedback(
                body: "⚠️ REPORT — shared task \(id), recipient \(who): \(reason)",
                category: "report", screen: "shared-task")
        }
    }
    /// Revoke a member's access. TRUE only when the SERVER confirmed it — a
    /// refusal (403 / 5xx / offline) must not be reported as "removed" while
    /// the member still has the list.
    @discardableResult
    func unshareCollection(_ collectionId: String, userId: String) async -> Bool {
        guard let coord = coordinator else { return false }
        let ok = await coord.share.unshare(collectionId: collectionId, userId: userId)
        if ok { await coord.rehydrateCollections() }
        return ok
    }
    @discardableResult
    func cancelCollectionInvite(_ collectionId: String, email: String) async -> Bool {
        guard let coord = coordinator else { return false }
        return await coord.share.cancelInvite(collectionId: collectionId, email: email)
    }
    /// Not screen-scoped (the unstructured Task outlives the screen the caller
    /// pops), so the leave RPC + local drop always complete. The local row is
    /// dropped ONLY once the server confirms — dropping it on a refusal looked
    /// like it worked and brought the list straight back on the next hydrate
    /// with no explanation. `onResult` carries the verdict back to the UI.
    func leaveCollection(_ collectionId: String, onResult: (@MainActor (Bool) -> Void)? = nil) {
        guard let coord = coordinator, let db else { onResult?(false); return }
        let share = coord.share
        Task {
            guard await share.leave(collectionId: collectionId) else {
                onResult?(false)
                return
            }
            try? db.deleteById(ItemCollection.self, id: collectionId)  // lose access → drop locally
            await coord.rehydrateCollections()
            onResult?(true)
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

    /// Build a live circle roster view-model over the shared CircleClient
    /// (through the PeopleTransport seam). Nil client (unconfigured / demo
    /// boot) degrades to an empty, read-only roster — mirrors the web
    /// `useCircle` no-`sb` guard.
    func makeCircleModel() -> CircleModel {
        let m = CircleModel(transport: LivePeopleTransport(client: coordinator?.circle))
        // Removing a connection (circle_remove) or blocking someone now also
        // ends the list memberships between the two of us, both ways (075):
        // re-read so my lists stop listing them and the lists I was taken out
        // of go (audit 2026-09-22, C11/C10).
        m.onConnectionRemoved = { [weak self] in await self?.refreshAfterSevering() }
        return m
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
    /// A `report` / `bug` row additionally pages support through the
    /// `report-notify` edge function (fire-and-forget, AFTER the row is
    /// durable) so an abuse report is actioned rather than waiting to be
    /// noticed in the dashboard. The email is server-derived from auth.users
    /// (migration 057's insert trigger) — the client value is triage context only.
    func sendFeedback(body: String, category: String?, screen: String?) async -> Bool {
        guard let fb = coordinator?.feedback else { return false }
        let device = "\(Self.deviceModelName) · iOS \(UIDevice.current.systemVersion)"
        let id = newUUID()
        let ok = await fb.submit(id: id, body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                 category: category, email: currentEmail,
                                 appVersion: Self.appVersion, platform: "ios", device: device, screen: screen)
        if ok, feedbackNotifiesSupport(category: category) {
            Task { _ = await fb.notifySupport(feedbackId: id) }
        }
        return ok
    }

    // MARK: - Safety (App Store Guideline 1.2 — user-generated/shared content)

    // Blocks are server-backed (block_user / block_task_sharer, migration 075).
    // The old block was a device-local email set: nothing on the server read
    // it, it only guarded this device's "Someone new" field, sign-out wiped it,
    // and the blocked person stayed connected and could keep sharing and
    // pushing (audit 2026-09-22, C10). Its "unstuck.blockedEmails" key stays in
    // the sign-out scrub so the legacy data is cleared.

    /// Block someone by user id — a Share-screen row, a People row, the owner
    /// of a list shared with me. TRUE only when the server confirmed; the
    /// shared state is then re-read, because a block also cuts the connection,
    /// the task shares and the list memberships between us, both ways.
    @discardableResult
    func blockUser(userId: String) async -> Bool {
        guard let circle = coordinator?.circle, !userId.isEmpty else { return false }
        let ok = await circle.blockUser(userId: userId)
        if ok { await refreshAfterSevering() }
        return ok
    }

    /// Block the owner of a task shared WITH me (the recipient knows only the
    /// share id). TRUE only when the server confirmed.
    @discardableResult
    func blockTaskSharer(shareId: String) async -> Bool {
        guard let circle = coordinator?.circle, !shareId.isEmpty else { return false }
        let ok = await circle.blockTaskSharer(shareId: shareId)
        if ok { await refreshAfterSevering() }
        return ok
    }

    /// Remove a task shared WITH me from my list (the owner isn't told).
    /// TRUE only when the server confirmed.
    func leaveSharedTask(shareId: String) async -> Bool {
        await shareState.leave(shareId: shareId)
    }

    /// A block or a removed connection took task shares and list memberships
    /// away server-side: re-read both at once. The owner's collection_members
    /// channel is filtered to MY rows, so nothing live tells my device that
    /// someone left one of my lists (audit 2026-09-22, C10/C11).
    func refreshAfterSevering() async {
        await shareState.refresh()
        await coordinator?.rehydrateCollections()
    }

    /// Report a task someone shared WITH me — a recipient could only report
    /// from a Share screen they owned (audit 2026-09-22, C10). Same channel as
    /// `reportConcern`. False when the report didn't send.
    @discardableResult
    func reportSharedTask(taskId: String, shareId: String?, ownerName: String, reason: String) async -> Bool {
        await sendFeedback(body: Self.sharedTaskReportBody(taskId: taskId, shareId: shareId,
                                                           ownerName: ownerName, reason: reason),
                           category: "report", screen: "shared-with-me")
    }

    /// Pure: the report row's body — which task, which share, from whom, why.
    nonisolated static func sharedTaskReportBody(taskId: String, shareId: String?, ownerName: String, reason: String) -> String {
        "⚠️ REPORT — task shared with me \(taskId)\(shareId.map { " (share \($0))" } ?? "") from \(ownerName): \(reason)"
    }

    /// Report objectionable content / a collaborator. Routes through the
    /// feedback channel (triaged in the Supabase dashboard) so we can act.
    /// False when the report didn't send.
    @discardableResult
    func reportConcern(collectionId: String, about email: String, reason: String) async -> Bool {
        await sendFeedback(
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
