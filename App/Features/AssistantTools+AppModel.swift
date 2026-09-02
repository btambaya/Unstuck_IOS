// `AssistantAppState` backed by the live AppModel — every write goes through
// the SAME methods the UI uses (outbox, Google mirror, shared-list RPCs, Live
// Activity), so the assistant can never leave the store in a state a tap
// couldn't. Reads hit the GRDB store directly (freshest committed rows), the
// way the web's api reads localStorage at call time.

import Foundation
import UnstuckCore
import UnstuckData

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
    func getStruggles() -> [String] { UserDefaults.standard.stringArray(forKey: "unstuck.adhdStruggles") ?? [] }

    // MARK: tasks + blocks

    func upsertTask(_ t: TaskItem) { model.saveTask(t) }
    func removeTask(_ id: String) { model.deleteTask(id) }
    func upsertBlock(_ b: CalBlock) { model.saveBlock(b) }
    /// `unschedule` reconciles Google for a pushed task block, then deletes.
    func deleteBlock(_ id: String) { model.unschedule(id) }

    // MARK: lists

    private func collection(_ id: String) -> ItemCollection? { getCollections().first { $0.id == id } }

    func addCollection(name: String, color: String) -> String? {
        model.addCollection(name: name, color: color, existing: getCollections())?.id
    }
    func addCollectionItem(collectionId: String, body: String) {
        guard let c = collection(collectionId) else { return }
        model.addCollectionItem(c, body: body)
    }
    func promoteItemToTask(collectionId: String, itemId: String, loop: Bool, dueAt: String?) {
        guard let c = collection(collectionId), let item = c.items.first(where: { $0.id == itemId }) else { return }
        model.moveItemToTask(c, item: item, mode: loop ? .loop : .selfOnly, dueAtIso: dueAt)
    }
    func renameCollection(_ id: String, name: String) {
        guard let c = collection(id) else { return }
        model.renameCollection(c, name: name)
    }
    func updateCollection(_ id: String, archived: Bool?, color: String?) {
        guard let c = collection(id) else { return }
        if let archived { model.archiveCollection(id, archived: archived) }
        if let color { model.recolorCollection(c, color: color) }
    }
    func removeCollection(_ id: String) { model.deleteCollection(id) }
    func updateCollectionItem(collectionId: String, itemId: String, body: String?, done: Bool?) {
        guard let c = collection(collectionId), let item = c.items.first(where: { $0.id == itemId }) else { return }
        if let body { model.updateCollectionItemBody(c, itemId: itemId, body: body) }
        // The UI only has a toggle — flip only when the desired state differs.
        if let done, (item.done ?? false) != done { model.toggleCollectionItemDone(c, itemId: itemId) }
    }
    func removeCollectionItem(collectionId: String, itemId: String) {
        guard let c = collection(collectionId) else { return }
        model.removeCollectionItem(c, itemId: itemId)
    }
    /// Unknown → false (the web's use-assistant-api rule); else editable unless viewer.
    func canEditCollection(_ id: String) -> Bool {
        guard let c = collection(id) else { return false }
        return model.canEdit(c)
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
        await circle.unshareTask(shareId: shareId)
    }

    // MARK: profile memory

    func getProfileFacts() -> [ProfileFact] { model.profileFacts?.all() ?? [] }
    func saveProfileFact(category: String?, fact: String, whenIso: String?) -> ProfileFact? {
        model.profileFacts?.save(category: ProfileFactsLogic.category(from: category), fact: fact, source: .chat, whenIso: whenIso)
    }
    func saveStylePreference(_ pref: StylePreference) -> ProfileFact? { model.profileFacts?.saveStylePreference(pref) }
    func removeProfileFact(_ id: String) -> Bool { model.profileFacts?.remove(id: id) ?? false }

    // MARK: captures

    func getCaptures() -> [Capture] {
        guard let db = model.db else { return [] }
        return (try? Repository<Capture>(db, orderColumn: "at").all()) ?? []
    }
    func getArchivedCaptureIds() -> [String] { Array(model.archivedCaptureIds) }
    func upsertCapture(_ c: Capture) { model.saveCapture(c) }
    func removeCapture(_ id: String) { model.discardCapture(id) }
    func archiveCapture(_ id: String, archived: Bool) {
        if archived { model.archiveCapture(id) } else { model.unarchiveCapture(id) }
    }

    // MARK: focus (the same FocusTimer transitions the Focus screen runs)

    func getLiveFocus() -> LiveSession? { (try? model.liveStore?.get()) ?? nil }

    func startFocus(taskId: String, estimateMin: Int?, occurrenceBlockId: String?) {
        guard let store = model.liveStore else { return }
        let existing: LiveSession? = (try? store.get()) ?? nil
        let task = getTasks().first { $0.id == taskId }
        var session = FocusTimer.start(existing ?? .empty, taskId: taskId, estimateMin: estimateMin ?? task?.estimateMin,
                                       priorAccumulatedSec: task?.totalFocused,
                                       now: Date().timeIntervalSince1970 * 1000, occurrenceBlockId: occurrenceBlockId)
        let isFresh = existing?.sessionStart == nil || existing?.taskId != taskId
        if isFresh { session = FocusTimer.setTreatment(session, model.settings.defaultTreatment) }
        try? store.set(session)
        model.refreshLiveSession()
        // The Focus screen (opened by navigate("focus")) adopts this session —
        // FocusTimer.start is resume-aware, so it never restarts the clock.
    }
    func pauseFocus() { model.pauseFocus() }
    func resumeFocus() { model.resumeFocus() }
    func extendFocus(_ minutes: Int) {
        guard let store = model.liveStore, let cur = (try? store.get()) ?? nil, cur.sessionStart != nil else { return }
        let next = FocusTimer.extend(cur, minutes: minutes)
        try? store.set(next)
        model.refreshLiveSession()
        LiveActivityController.shared.update(sessionStartMs: next.sessionStart ?? 0, paused: next.paused,
                                             estimateMin: next.sessionEstimateMin)
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

    // MARK: navigation

    func navigate(screen: String, id: String?) { _ = model.openScreen(screen, id: id) }

    // MARK: areas + tags (rename/delete cascade like the web's use-life-areas / use-tags)

    func addArea(name: String, color: String?) {
        let next = (getAreaRows().map(\.sortOrder).max() ?? -1) + 1
        model.saveLifeArea(LifeArea(id: newUUID(), name: name, color: color ?? "indigo", sortOrder: next))
    }
    func updateArea(_ id: String, name: String?, color: String?) {
        guard let row = getAreaRows().first(where: { $0.id == id }) else { return }
        model.saveLifeArea(LifeArea(id: row.id, name: name ?? row.name, color: color ?? row.color, sortOrder: row.sortOrder))
        if let name, name != row.name {
            for var t in getTasks() where t.lifeArea == row.name {
                t.lifeArea = name
                t.updatedAt = AppModel.isoNow()
                model.saveTask(t)
            }
        }
    }
    func removeArea(_ id: String) {
        let row = getAreaRows().first { $0.id == id }
        model.deleteLifeArea(id)
        // "its tasks keep everything else" — they just lose the label.
        if let row {
            for var t in getTasks() where t.lifeArea == row.name {
                t.lifeArea = nil
                t.updatedAt = AppModel.isoNow()
                model.saveTask(t)
            }
        }
    }
    func addTag(name: String) {
        let next = (getTagRows().map(\.sortOrder).max() ?? -1) + 1
        model.saveTag(TagRow(id: newUUID(), name: name, color: nil, sortOrder: next))
    }
    func updateTag(_ id: String, name: String?) {
        guard let row = getTagRows().first(where: { $0.id == id }) else { return }
        model.saveTag(TagRow(id: row.id, name: name ?? row.name, color: row.color, sortOrder: row.sortOrder))
        if let name, name != row.name {
            for var t in getTasks() where (t.tags ?? []).contains(where: { $0.caseInsensitiveCompare(row.name) == .orderedSame }) {
                var seen = Set<String>()
                t.tags = (t.tags ?? []).map { $0.caseInsensitiveCompare(row.name) == .orderedSame ? name : $0 }
                    .filter { seen.insert($0.lowercased()).inserted }
                t.updatedAt = AppModel.isoNow()
                model.saveTask(t)
            }
        }
    }
    /// AppModel.deleteTag already strips the name from every task.
    func removeTag(_ id: String) { model.deleteTag(id) }

    // MARK: settings

    func setUsableMinutes(weekday: Int?, weekend: Int?) async {
        // Local first (the value the brief math reads), server best-effort.
        let d = UserDefaults.standard
        if let weekday { d.set(weekday, forKey: "unstuck.usableMinutesPerDay") }
        if let weekend { d.set(weekend, forKey: "unstuck.usableMinutesWeekend") }
        // Server mirror (user_preferences.usable_minutes_per_day / _weekend) —
        // best-effort: the local value is what the brief math reads.
        try? await model.coordinator?.preferences.setUsableMinutes(perDay: weekday, weekend: weekend)
    }
    func setNotificationLevel(_ level: String) async -> Bool {
        let mapped: NotificationLevel
        switch level {
        case "calm": mapped = .calm
        case "coach": mapped = .coach
        default: mapped = .balanced
        }
        model.setNotificationLevel(mapped)
        return true
    }
    func setReminderLead(_ minutes: Int) async -> Bool {
        model.setReminderLeadMin(minutes)
        return true
    }
    func setRitual(_ ritual: String, on: Bool) {
        guard let key = RitualKey(rawValue: ritual) else { return }
        // Through the shared observable (writes to PAPrefsStore underneath) so
        // the gateway card's moment picker and the Settings toggles update live.
        model.paPrefs.setRitual(key, on: on)
    }
}

enum AssistantStateError: LocalizedError {
    case offline
    var errorDescription: String? { "offline" }
}
