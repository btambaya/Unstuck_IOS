// `AssistantAppState` backed by the live AppModel — every write goes through
// the SAME methods the UI uses (outbox, Google mirror, shared-list RPCs, Live
// Activity), so the assistant can never leave the store in a state a tap
// couldn't. Reads hit the GRDB store directly (freshest committed rows), the
// way the web's api reads localStorage at call time — which is why the store
// writes here use AppModel's `…Awaiting` variants: they return after the local
// GRDB row is committed, so the executor's next read sees it.

import Foundation
import UnstuckCore
import UnstuckData
import UnstuckSync

@MainActor
final class AppModelAssistantState: AssistantAppState {
    private unowned let model: AppModel
    private unowned let assistant: AssistantModel

    init(model: AppModel, assistant: AssistantModel) {
        self.model = model
        self.assistant = assistant
    }

    // MARK: reads

    func getTasks() -> [TaskItem] { (try? model.taskRepo?.all()) ?? [] }
    func getBlocks() -> [CalBlock] { (try? model.db?.fetchAllCalBlocks()) ?? [] }
    func getCollections() -> [ItemCollection] { (try? model.db?.fetchAllCollections()) ?? [] }
    func getAreaRows() -> [LifeArea] { ((try? model.db?.fetchAllLifeAreas()) ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    func getTagRows() -> [TagRow] { ((try? model.db?.fetchAllTags()) ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    func getAreas() -> [String] { getAreaRows().map(\.name) }
    func getTags() -> [String] { getTagRows().map(\.name) }
    func currentUserName() -> String { model.currentUserName ?? "" }
    func todayIso() -> String { Clock.todayISO() }
    func nowHM() -> String { localNowHM() }

    func getSessions() -> [UnstuckCore.Session] {
        guard let db = model.db else { return [] }
        return (try? Repository<Session>(db, orderColumn: "completedAt").all()) ?? []
    }
    func getReasonLogs() -> [ReasonLog] {
        guard let db = model.db else { return [] }
        return (try? Repository<ReasonLog>(db, orderColumn: "at").all()) ?? []
    }
    /// The engine's vocabulary ("Starting", "Switching", …) whatever labels
    /// onboarding stored — see AppModel.canonicalStruggles.
    func getStruggles() -> [String] { model.canonicalStruggles }

    // MARK: tasks + blocks (committed locally before returning)

    func upsertTask(_ t: TaskItem) async { await model.saveTaskAwaiting(t) }
    func removeTask(_ id: String) async { await model.deleteTaskAwaiting(id) }
    /// The UI's un-complete hook (AppModel.toggleDone → `.reopen`), best-effort.
    func notifyTaskReopenedIfShared(_ t: TaskItem) { model.notifyTaskReopenedIfShared(t) }
    /// The UI's completion hook (AppModel.toggleDone / finishFocus → `.done`), best-effort.
    func notifyTaskCompletedIfShared(_ t: TaskItem) { model.notifyTaskDoneIfShared(t) }
    func upsertBlock(_ b: CalBlock) async { await model.saveBlockAwaiting(b) }
    /// The mint path: the same un-park as `upsertBlock`, insert-if-absent, and
    /// the Google push deferred until the server confirms the insert (rule G).
    func insertBlockIfAbsent(_ b: CalBlock, retimeIfTaken: Bool) async -> Bool {
        await model.saveBlockInserting(b, retimeIfTaken: retimeIfTaken)
    }
    /// `unschedule` reconciles Google for a pushed task block, then deletes.
    func deleteBlock(_ id: String) async { await model.unscheduleAwaiting(id) }

    // MARK: lists

    private func collection(_ id: String) -> ItemCollection? { getCollections().first { $0.id == id } }

    /// Committed to GRDB BEFORE returning (the executor contract): the UI's
    /// `AppModel.addCollection` schedules its upsert in a detached Task, so a
    /// later tool in the same turn (add_to_list / rename_list on the id just
    /// returned) re-fetched a row that wasn't there yet and silently no-op'd
    /// while reporting `ok:`. Same row shape as the UI path, one transaction
    /// (row + outbox op), then the debounced flush kick.
    func addCollection(name: String, color: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let write = model.write else { return nil }
        let nextOrder = (getCollections().map(\.sortOrder).max() ?? -1) + 1
        let col = ItemCollection(id: newUUID(), name: trimmed, color: color, subtitle: nil,
                                 items: [], sortOrder: nextOrder, archived: false)
        do { try write.upsertCollectionSync(col, nowISO: AppModel.isoNow()) } catch { return nil }
        if let coord = model.coordinator { Task { await coord.kickFlush() } }
        return col.id
    }

    // The list writes below AWAIT the same WriteThrough calls AppModel's
    // mutate helpers fire-and-forget (`mutateCollection` / `mutateCollectionItem`
    // wrap them in a detached Task and return Void), so the executor can
    // report the REAL outcome (tooling rules §1, 2026-09-20): `true` only once
    // the local row + its outbox op are committed, `false` on a missing list
    // or a failed write — a `Void` seam let the assistant say `ok:` over a
    // write that never landed. Routing is AppModel's, byte for byte: a shared
    // list takes the atomic item RPC (never the items JSONB) and the owner's
    // partial metadata UPDATE; an own list takes the whole-row upsert.

    /// Item-array change, committed. `rpc` builds the shared-list descriptor.
    private func mutateItemsCommitted(_ id: String, _ transform: (ItemCollection) -> ItemCollection,
                                      rpc: (ItemCollection) -> CollectionRPC) async -> Bool {
        guard let write = model.write, let latest = collection(id) else { return false }
        let next = transform(latest)
        do {
            if model.isShared(latest) {
                try await write.applyCollectionRPC(next, rpc: rpc(next), nowISO: AppModel.isoNow())
            } else {
                try await write.upsertCollection(next, nowISO: AppModel.isoNow())
            }
        } catch { return false }
        return true
    }

    /// Metadata change (name / colour / archived), committed. A SHARED list
    /// goes through AppModel's own method (`viaModel`: a synchronous local
    /// save + the partial-UPDATE RPC queued per collection), then the row is
    /// read back to confirm it landed.
    private func mutateCollectionCommitted(_ id: String, _ transform: (ItemCollection) -> ItemCollection,
                                           viaModel: (ItemCollection) -> Void) async -> Bool {
        guard let write = model.write, let latest = collection(id) else { return false }
        let next = transform(latest)
        if model.isShared(latest) {
            viaModel(latest)
        } else {
            do { try await write.upsertCollection(next, nowISO: AppModel.isoNow()) } catch { return false }
        }
        return collection(id) == next
    }

    func addCollectionItem(collectionId: String, body: String) async -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let item = CollectionItem(id: newUUID(), body: text, at: AppModel.isoNow())
        let ok = await mutateItemsCommitted(collectionId, { var c = $0; c.items.append(item); return c },
            rpc: { _ in CollectionRPC.addItem(collectionId: collectionId, id: item.id, body: item.body, at: item.at) })
        return ok ? item.id : nil
    }
    /// The list UI's own path (task + promotion mark + loop scheduling) —
    /// it returns the task it made, nil when the item was skipped.
    func promoteItemToTask(collectionId: String, itemId: String, loop: Bool, dueAt: String?) -> String? {
        guard model.write != nil, let c = collection(collectionId), let item = c.items.first(where: { $0.id == itemId }) else { return nil }
        return model.moveItemToTask(c, item: item, mode: loop ? .loop : .selfOnly, dueAtIso: dueAt)?.id
    }
    func renameCollection(_ id: String, name: String) async -> Bool {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty else { return false }
        return await mutateCollectionCommitted(id, { var c = $0; c.name = nm; return c },
                                               viaModel: { model.renameCollection($0, name: nm) })
    }
    func updateCollection(_ id: String, archived: Bool?, color: String?) async -> Bool {
        var ok = true
        if let archived {
            ok = await mutateCollectionCommitted(id, { var c = $0; c.archived = archived; return c },
                                                 viaModel: { _ in model.archiveCollection(id, archived: archived) })
        }
        if ok, let color {
            ok = await mutateCollectionCommitted(id, { var c = $0; c.color = color; return c },
                                                 viaModel: { model.recolorCollection($0, color: color) })
        }
        return ok
    }
    func removeCollection(_ id: String) async -> Bool {
        guard let write = model.write, collection(id) != nil else { return false }
        do { try await write.deleteCollection(id: id, nowISO: AppModel.isoNow()) } catch { return false }
        return collection(id) == nil
    }
    func updateCollectionItem(collectionId: String, itemId: String, body: String?, done: Bool?, pinned: Bool?) async -> Bool {
        guard let c = collection(collectionId), c.items.contains(where: { $0.id == itemId }) else { return false }
        var ok = true
        if let body {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            ok = await mutateItemsCommitted(collectionId,
                { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].body = text }; return n },
                rpc: { _ in CollectionRPC.updateItem(collectionId: collectionId, itemId: itemId, body: text) })
        }
        if ok, let done {
            ok = await mutateItemsCommitted(collectionId,
                { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].done = done }; return n },
                rpc: { _ in CollectionRPC.setItemFlag(collectionId: collectionId, itemId: itemId, flag: "done", value: done) })
        }
        if ok, let pinned {
            ok = await mutateItemsCommitted(collectionId,
                { c in var n = c; if let i = n.items.firstIndex(where: { $0.id == itemId }) { n.items[i].pinned = pinned }; return n },
                rpc: { _ in CollectionRPC.setItemFlag(collectionId: collectionId, itemId: itemId, flag: "pinned", value: pinned) })
        }
        return ok
    }
    func removeCollectionItem(collectionId: String, itemId: String) async -> Bool {
        guard let c = collection(collectionId), c.items.contains(where: { $0.id == itemId }) else { return false }
        return await mutateItemsCommitted(collectionId,
            { c in var n = c; n.items.removeAll { $0.id == itemId }; return n },
            rpc: { _ in CollectionRPC.removeItem(collectionId: collectionId, itemId: itemId) })
    }
    /// The Lists screen's leave: the RPC + local drop, TRUE only when the
    /// server confirmed (a refusal keeps the row and says so).
    func leaveCollection(_ id: String) async -> Bool {
        guard collection(id) != nil else { return false }
        return await withCheckedContinuation { cont in
            model.leaveCollection(id) { cont.resume(returning: $0) }
        }
    }
    /// Unknown → false (the web's use-assistant-api rule); else editable unless viewer.
    func canEditCollection(_ id: String) -> Bool {
        guard let c = collection(id) else { return false }
        return model.canEdit(c)
    }
    /// Owner-only actions (rename / archive / delete) — the same `isOwner` the
    /// collection screen gates its own buttons on. Unknown → false.
    func ownsCollection(_ id: String) -> Bool {
        guard let c = collection(id) else { return false }
        return model.isOwner(c)
    }

    // MARK: sharing

    func getShareCandidates() -> [ShareCandidate] { assistant.shareCandidates }
    func stageShare(_ p: PendingShare) { assistant.stagePendingShare(p) }
    func getCirclePeople() -> [CirclePerson] { assistant.circlePeople }
    func listTaskShares(taskId: String) async -> [TaskShareInfo] {
        guard let circle = model.coordinator?.circle else { return [] }
        return await circle.sharesForTask(taskId: taskId).map {
            TaskShareInfo(shareId: $0.shareId, recipientName: $0.recipientName, level: $0.level.rawValue)
        }
    }
    func unshareTask(shareId: String) async throws {
        guard let circle = model.coordinator?.circle else { throw AssistantStateError.offline }
        guard await circle.unshareTask(shareId: shareId) else { throw AssistantStateError.revokeFailed }
    }

    // MARK: profile memory

    func getProfileFacts() -> [ProfileFact] { model.profileFacts?.all() ?? [] }
    func saveProfileFact(category: String?, fact: String, whenIso: String?) throws -> ProfileFact {
        // No store yet (before start()) is a store failure, not "not a fact".
        guard let service = model.profileFacts else { throw ProfileFactSaveError.storeFailed }
        return try service.store(category: ProfileFactsLogic.category(from: category), fact: fact, source: .chat, whenIso: whenIso)
    }
    func saveStylePreference(_ pref: StylePreference) -> ProfileFact? { model.profileFacts?.saveStylePreference(pref) }
    func removeProfileFact(_ id: String) -> Bool { model.profileFacts?.remove(id: id) ?? false }

    // MARK: first-run interview

    func interviewPending() -> Bool { !InterviewMachine.isDone() }
    /// Same flag + the same account mirror the in-thread interview uses.
    func markInterviewDone() {
        InterviewMachine.markDone()
        model.pushInterviewDone()
    }

    // MARK: captures

    func getCaptures() -> [Capture] {
        guard let db = model.db else { return [] }
        return (try? Repository<Capture>(db, orderColumn: "at").all()) ?? []
    }
    func getArchivedCaptureIds() -> [String] { Array(model.archivedCaptureIds) }
    func upsertCapture(_ c: Capture) async { await model.saveCaptureAwaiting(c) }
    func removeCapture(_ id: String) async { await model.discardCaptureAwaiting(id) }
    func archiveCapture(_ id: String, archived: Bool) {
        if archived { model.archiveCapture(id) } else { model.unarchiveCapture(id) }
    }

    // MARK: focus (the same FocusTimer transitions the Focus screen runs)

    func getLiveFocus() -> LiveSession? { (try? model.liveStore?.get()) ?? nil }

    /// JOIN-OR-MINT, exactly like the Focus screen: minting here directly used
    /// to create a SECOND sessionId on a task a partner was already running, so
    /// every partner control was dropped (sessionId mismatch) and the two
    /// clocks finalized separately. `startFocusJoinOrMint` finalizes a
    /// displaced session, probes the co-focus channel and ADOPTS a partner's
    /// in-flight session when there is one, else mints. It is resume-aware, so
    /// re-entering the same occurrence never restarts the clock. AWAITED
    /// (2026-09-20) — "focus started" is reported only once the store has it.
    func startFocus(taskId: String, estimateMin: Int?, occurrenceBlockId: String?) async -> Bool {
        await model.startFocusJoinOrMint(taskId: taskId, estimateMin: estimateMin, occurrenceBlockId: occurrenceBlockId)
        guard let live = getLiveFocus() else { return false }
        return live.sessionStart != nil && live.taskId == taskId
    }
    func pauseFocus() { model.pauseFocus() }
    func resumeFocus() { model.resumeFocus() }
    func extendFocus(_ minutes: Int) -> Bool {
        guard let store = model.liveStore, let cur = (try? store.get()) ?? nil, cur.sessionStart != nil else { return false }
        let next = FocusTimer.extend(cur, minutes: minutes)
        do { try store.set(next) } catch { return false }
        model.refreshLiveSession()
        LiveActivityController.shared.update(sessionStartMs: next.sessionStart ?? 0, paused: next.paused,
                                             estimateMin: next.sessionEstimateMin)
        return true
    }
    /// The focus screen's Done/End path, minus the screen (FocusFeature →
    /// FocusMachine.finish + AppModel.finishFocus): the Session row is
    /// attributed to the TEMPLATE (`cur.taskId`) for an occurrence focus, the
    /// store is cleared with `FocusTimer.done`, the Live Activity and the
    /// paused check-in end, and the accrual takes the same three routes —
    /// a session on a task shared WITH me → `finalizeSharedFocus` (owner's
    /// ledger, optional completion by level); an own task → `finishFocus`
    /// (partner-shared → exactly-once ledger); a task row that's gone →
    /// the bare Session, without the dead task id. nil = nothing was running.
    func finishFocus(markDone: Bool) async -> FocusFinishOutcome? {
        guard let store = model.liveStore, let cur = (try? store.get()) ?? nil, cur.sessionStart != nil else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        let elapsed = FocusTimer.elapsedSec(cur, now: now)
        let task = (try? model.taskRepo?.fetch(id: cur.taskId)) ?? nil
        let name = task?.name ?? "Focus session"
        let session = Session(id: cur.id ?? newUUID(), taskId: cur.taskId, taskName: name,
                              estimateMin: task?.estimateMin ?? cur.sessionEstimateMin, actualSec: elapsed,
                              completedAt: AppModel.isoNow())
        do { try store.set(FocusTimer.done(cur)) } catch { return nil }
        model.refreshLiveSession()
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()
        var markedDone = false
        if let level = cur.sharedFocusLevel {
            // Never a repeating share: the server refuses that tick, so
            // "task marked done" would be a claim of nothing (C3).
            markedDone = markDone && levelCanComplete(level) && model.sharedTaskAllowsTick(cur.taskId)
            model.finalizeSharedFocus(taskId: cur.taskId, taskName: name, sessionId: session.id,
                                      elapsedSec: elapsed, estimateMin: cur.sessionEstimateMin,
                                      markDone: markedDone, showRecap: false)
        } else if let task {
            // A recurring TEMPLATE with no occurrence attached is never marked
            // done (that would end the whole series) — AppModel.finishFocus
            // falls through there, so the outcome says the task stays open.
            markedDone = markDone && (cur.occurrenceBlockId != nil || focusMayCompleteRow(task))
            model.finishFocus(task: task, session: session, elapsedSec: elapsed, markDone: markDone,
                              occurrenceBlockId: cur.occurrenceBlockId,
                              sharedLedger: model.accruesViaSharedLedger(cur, taskId: task.id))
        } else {
            model.saveSession(AppModel.goneTaskSession(cur, elapsedSec: elapsed))
        }
        // A presented Focus screen would keep showing a clock the store no longer has.
        if model.router.focusTask != nil { model.router.focusTask = nil; model.router.sharedFocus = nil }
        return FocusFinishOutcome(taskId: cur.taskId, taskName: name, elapsedSec: elapsed, markedDone: markedDone)
    }
    func cancelFocus() {
        guard let store = model.liveStore, let cur = (try? store.get()) ?? nil, cur.sessionStart != nil else { return }
        _ = FocusTimer.cancel(cur)
        try? store.set(nil)
        model.refreshLiveSession()
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()
        // A presented Focus screen would keep showing a clock the store no longer has.
        if model.router.focusTask != nil { model.router.focusTask = nil; model.router.sharedFocus = nil }
    }

    // MARK: reminders

    /// Device-local per-task override (Settings → task reminder), then the
    /// scheduler rebuild the Settings toggle triggers — read back to confirm.
    func setTaskReminder(taskId: String, minutes: Int?) -> Bool {
        NotificationPrefs.setReminderOverride(taskId: taskId, leadMin: minutes)
        ReminderScheduler.shared.resync()
        return NotificationPrefs.reminderOverride(taskId: taskId) == minutes
    }

    // MARK: navigation

    func navigate(screen: String, id: String?) { _ = model.openScreen(screen, id: id) }

    // MARK: areas + tags
    //
    // The rename/delete cascade onto tasks lives in AppModel, shared with the
    // Settings rows, so there is one path (audit 2026-09-22, C19).

    func addArea(name: String, color: String?) async {
        let next = (getAreaRows().map(\.sortOrder).max() ?? -1) + 1
        await model.saveLifeAreaAwaiting(LifeArea(id: newUUID(), name: name, color: color ?? "indigo", sortOrder: next))
    }
    func updateArea(_ id: String, name: String?, color: String?) async {
        if let name { await model.renameLifeAreaAwaiting(id, to: name) }
        // Re-read after the rename so the colour write keeps the new name.
        if let color, var row = getAreaRows().first(where: { $0.id == id }) {
            row.color = color
            await model.saveLifeAreaAwaiting(row)
        }
    }
    /// AppModel clears the label off the area's tasks.
    func removeArea(_ id: String) async { await model.deleteLifeAreaAwaiting(id) }
    func addTag(name: String) async {
        let next = (getTagRows().map(\.sortOrder).max() ?? -1) + 1
        await model.saveTagAwaiting(TagRow(id: newUUID(), name: name, color: nil, sortOrder: next))
    }
    func updateTag(_ id: String, name: String?) async {
        if let name { await model.renameTagAwaiting(id, to: name) }
    }
    /// AppModel.deleteTag already strips the name from every task.
    func removeTag(_ id: String) async { await model.deleteTagAwaiting(id) }

    // MARK: settings

    /// `get_settings`: the same stores the Settings screen reads.
    func getSettings() -> AssistantSettingsSnapshot {
        let d = UserDefaults.standard
        let s = model.settings
        var rituals: [String: Bool] = [:]
        for key in RitualKey.allCases { rituals[key.rawValue] = model.paPrefs.rituals[key] }
        return AssistantSettingsSnapshot(
            notificationLevel: NotificationPrefs.level.rawValue.lowercased(),
            reminderLeadMin: NotificationPrefs.reminderLeadMin,
            usableWeekdayMin: d.object(forKey: "unstuck.usableMinutesPerDay") == nil ? nil : d.integer(forKey: "unstuck.usableMinutesPerDay"),
            usableWeekendMin: d.object(forKey: "unstuck.usableMinutesWeekend") == nil ? nil : d.integer(forKey: "unstuck.usableMinutesWeekend"),
            focusDefaultMin: s.focusDefaultMin, focusOverrunMin: s.focusOverrunMin,
            focusSoftExit: s.focusSoftExit, focusPauseReasons: s.focusPauseReasons,
            theme: s.theme.rawValue, ambient: s.ambient.rawValue, rituals: rituals)
    }

    /// The budget lives on the server (`user_preferences.usable_minutes_*` —
    /// the web calendar's capacity math reads it; nothing on iOS does yet), so
    /// the server write IS the change: awaited, and the local cache is written
    /// only after it lands. The REAL outcome is returned so the executor's
    /// `ok:` can't claim a save that didn't happen (see the tool contract).
    func setUsableMinutes(weekday: Int?, weekend: Int?) async -> Bool {
        await model.setUsableMinutesAwaiting(perDay: weekday, weekend: weekend)
    }
    /// The REAL outcome (web parity): the local write read back + the server
    /// mirror awaited — false makes the contract's "could not save" reachable.
    func setNotificationLevel(_ level: String) async -> Bool {
        let mapped: NotificationLevel
        switch level {
        case "calm": mapped = .calm
        case "coach": mapped = .coach
        default: mapped = .balanced
        }
        return await model.setNotificationLevelAwaiting(mapped)
    }
    func setReminderLead(_ minutes: Int) async -> Bool {
        await model.setReminderLeadAwaiting(minutes)
    }
    func setRitual(_ ritual: String, on: Bool) -> Bool {
        guard let key = RitualKey(rawValue: ritual) else { return false }
        // Through the shared observable (writes to PAPrefsStore underneath) so
        // the gateway card's moment picker and the Settings toggles update live.
        model.paPrefs.setRitual(key, on: on)
        return model.paPrefs.rituals[key] == on
    }
    // Theme / focus defaults / ambient are device-local SettingsState scalars
    // (UserDefaults-backed, observed app-wide) — the same properties the
    // Settings screen binds to, read back to confirm.
    func setTheme(_ theme: String) -> Bool {
        guard let pref = ThemePref(rawValue: theme) else { return false }
        model.settings.theme = pref
        return model.settings.theme == pref
    }
    func setFocusDefaults(defaultMinutes: Int?, overrunMinutes: Int?, softExit: Bool?, pauseReasons: Bool?) -> Bool {
        let s = model.settings
        if let defaultMinutes { s.focusDefaultMin = defaultMinutes }
        if let overrunMinutes { s.focusOverrunMin = overrunMinutes }
        if let softExit { s.focusSoftExit = softExit }
        if let pauseReasons { s.focusPauseReasons = pauseReasons }
        return (defaultMinutes.map { s.focusDefaultMin == $0 } ?? true)
            && (overrunMinutes.map { s.focusOverrunMin == $0 } ?? true)
            && (softExit.map { s.focusSoftExit == $0 } ?? true)
            && (pauseReasons.map { s.focusPauseReasons == $0 } ?? true)
    }
    func setAmbientSound(_ sound: String) -> Bool {
        guard let pref = AmbientSound(rawValue: sound) else { return false }
        model.settings.ambient = pref
        return model.settings.ambient == pref
    }
}

enum AssistantStateError: LocalizedError {
    case offline
    /// The server did not accept the unshare RPC.
    case revokeFailed
    var errorDescription: String? {
        switch self {
        case .offline: return "offline"
        case .revokeFailed: return "couldn't revoke the share"
        }
    }
}
