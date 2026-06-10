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
        let uid = coordinator?.auth.currentUserId
        return !(c.members ?? []).isEmpty || (c.ownerId != nil && uid != nil && c.ownerId != uid)
    }
    /// Owner (or a local/demo row with no ownerId). Gates rename/recolor/delete/share.
    func isOwner(_ c: ItemCollection) -> Bool {
        let uid = coordinator?.auth.currentUserId
        return c.ownerId == nil || c.ownerId == uid
    }
    /// A view-only member can't edit items; owner + editor + local can.
    func canEdit(_ c: ItemCollection) -> Bool { c.myRole != "viewer" }

    var currentUserName: String? { coordinator?.auth.currentUserName }
    var currentEmail: String? { coordinator?.auth.currentEmail }

    // MARK: - account management (Settings · Account)

    /// True for an email/password account (vs Google-only) — gates "Change
    /// password" vs "Add a password" copy in Settings.
    var hasPassword: Bool { coordinator?.auth.hasPassword ?? true }

    func updateDisplayName(_ name: String) async -> AuthOutcome {
        guard let auth = coordinator?.auth else { return .error("Not signed in.") }
        return await auth.updateDisplayName(name)
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
            // The server wipe + signOut already happened; clear device-local
            // state the same way signOut does so nothing leaks to the next user.
            NotificationLog.shared.clear()
            NotificationPrefs.clearUserContent()
            PausedCheckinScheduler.cancel()
            archivedCaptureIds = []
            // Scrub the assistant chat — same cross-account leak class. Clear the
            // live model if opened; always wipe the persisted store.
            _assistant?.clear()
            AssistantModel.scrubPersisted()
            Task { await ReminderScheduler.shared.cancelAll() }
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

    /// Item-array change. Shared → optimistic local write (no outbox — the RPC is
    /// the server write) + the atomic item RPC. `rpc` receives the resulting row.
    private func mutateCollectionItem(
        _ id: String,
        _ transform: (ItemCollection) -> ItemCollection,
        rpc: @escaping @Sendable (CollectionShareClient, ItemCollection) async -> Void
    ) {
        guard let coord = coordinator, let db, let latest = try? db.fetchById(ItemCollection.self, id: id) else { return }
        let next = transform(latest)
        if isShared(latest) {
            try? db.save(next)
            let share = coord.share
            enqueueCollectionRPC(id) { await rpc(share, next) }
        } else {
            Task { try? await coord.write.upsertCollection(next, nowISO: Self.isoNow()) }
        }
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
            rpc: { share, _ in await share.addItem(collectionId: col.id, id: item.id, body: item.body, at: item.at) })
    }
    func updateCollectionItemBody(_ col: ItemCollection, itemId: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].body = text }; return n },
            rpc: { share, _ in await share.updateItem(collectionId: col.id, itemId: itemId, body: text) })
    }
    func toggleCollectionItemPin(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].pinned = !(n.items[i].pinned ?? false) }; return n },
            rpc: { share, next in
                let v = next.items.first { $0.id == itemId }?.pinned ?? false
                await share.setItemFlag(collectionId: col.id, itemId: itemId, flag: "pinned", value: v)
            })
    }
    func toggleCollectionItemDone(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].done = !(n.items[i].done ?? false) }; return n },
            rpc: { share, next in
                let v = next.items.first { $0.id == itemId }?.done ?? false
                await share.setItemFlag(collectionId: col.id, itemId: itemId, flag: "done", value: v)
            })
    }
    func removeCollectionItem(_ col: ItemCollection, itemId: String) {
        mutateCollectionItem(col.id,
            { c in var n = c; n.items.removeAll { $0.id == itemId }; return n },
            rpc: { share, _ in await share.removeItem(collectionId: col.id, itemId: itemId) })
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
            rpc: { share, _ in await share.setItemPromotion(collectionId: col.id, itemId: itemId, assignee: assignee, done: done, dueAt: dueAt) })
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
                 sourceCollectionId: String? = nil, sourceItemId: String? = nil, dueAt: String? = nil) -> TaskItem {
        let now = Self.isoNow()
        let t = TaskItem(id: newUUID(), name: name, estimateMin: estimateMin, tags: tags,
                         createdAt: now, updatedAt: now,
                         sourceCollectionId: sourceCollectionId, sourceItemId: sourceItemId, dueAt: dueAt)
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
        if flipped.done && !task.done, let cid = task.sourceCollectionId, let iid = task.sourceItemId {
            let share = coordinator?.share
            let by = currentUserName ?? "Someone"
            Task { await share?.taskDone(collectionId: cid, itemId: iid, taskName: task.name, by: by) }
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

    /// The task to OPEN in the editor for a list row: an occurrence row (id =
    /// block id) resolves to its TEMPLATE so edits apply to the series and never
    /// mint a phantom task; a normal row returns itself.
    func editableTask(for row: TaskItem) -> TaskItem {
        guard let block = occurrenceBlockForId(row.id),
              let tpl = (try? taskRepo?.all())?.first(where: { $0.id == block.taskId }) else { return row }
        return tpl
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
        guard let cid = task.sourceCollectionId, let iid = task.sourceItemId else { return }
        let share = coordinator?.share
        let by = currentUserName ?? "Someone"
        Task { await share?.taskDone(collectionId: cid, itemId: iid, taskName: task.name, by: by) }
    }

    /// Before starting Focus on `newTaskId`, finalize a still-in-flight session
    /// that belongs to a DIFFERENT task — write its Session row + accumulate its
    /// focus time — so opening Focus on B doesn't silently discard A's elapsed
    /// time when FocusTimer.start overwrites the live session. 1:1 with the
    /// Android startFocus finalize.
    func finalizeDisplacedFocus(forNewTaskId newTaskId: String) {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, cur.taskId != newTaskId,
              let prev = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil else { return }
        let elapsed = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        saveSession(Session(id: cur.id ?? newUUID(), taskId: prev.id, taskName: prev.name,
                            estimateMin: prev.estimateMin, actualSec: elapsed, completedAt: Self.isoNow()))
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
    func finishFocus(task: TaskItem, session: Session, elapsedSec: Int, markDone: Bool, occurrenceBlockId: String? = nil) {
        saveSession(session)
        var focused = task
        focused.totalFocused += elapsedSec
        focused.updatedAt = Self.isoNow()
        if let occurrenceBlockId, let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == occurrenceBlockId }) {
            // Always accrue focus on the template; mark the DAY's block done.
            saveTask(focused)
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
            saveTask(applyCompletion(done, prior: task, nowISO: Self.isoNow()))
            notifyTaskDoneIfShared(task)
        } else {
            saveTask(focused)
        }
        sendSessionRecap(taskName: task.name, away: false)
    }

    // MARK: - sharing (edge-function backed)

    func shareCollection(_ collectionId: String, email: String, role: String) async -> ShareOutcome {
        guard let share = coordinator?.share else { return .error }
        return await share.share(collectionId: collectionId, email: email, role: role)
    }
    func unshareCollection(_ collectionId: String, userId: String) async {
        await coordinator?.share.unshare(collectionId: collectionId, userId: userId)
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
        }
    }
    func listCollectionMembers(_ collectionId: String) async -> [CollectionMemberInfo] {
        await coordinator?.share.listMembers(collectionId: collectionId) ?? []
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
