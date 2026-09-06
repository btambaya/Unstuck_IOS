// Pure rules behind the hands-free write paths (widget "Done", Siri "complete
// <task>", the App-Group entity snapshot) and the support-notify decision for
// in-app feedback. Kept UI/store-free so the app's drain + snapshot writer and
// the tests share ONE definition of "what does this id resolve to" and "which
// tasks does Siri get to see".

import Foundation

/// What a hands-free `completeTask` op targets once resolved against the local
/// store: a raw task row, or one DAY of a recurring series (the occurrence's id
/// is its cal_block id — completing it marks the block, never the template).
public enum HandsFreeCompletionTarget: Equatable, Sendable {
    case task(TaskItem)
    case occurrence(CalBlock)
}

/// Resolve a hands-free completion id against BOTH the raw task rows and the
/// recurring occurrences projected from cal_blocks. The widget's Start-Next
/// tile carries an occurrence id whenever a recurring task is scheduled today,
/// so a raw-row-only lookup silently dropped those completions.
/// Templates (rows with a recurrence) are never a completion target — done on
/// the template would end the whole series.
public func resolveHandsFreeCompletion(id: String, tasks: [TaskItem], blocks: [CalBlock]) -> HandsFreeCompletionTarget? {
    if let block = occurrenceBlockFor(id, tasks: tasks, blocks: blocks) { return .occurrence(block) }
    guard let task = tasks.first(where: { $0.id == id }), !isTemplate(task) else { return nil }
    return .task(task)
}

/// Whether a hands-free op whose target could NOT be found may be dropped.
/// Before the account's first hydrate has landed, the local store is not yet a
/// faithful copy of the server (a fresh sign-in on this device), so an
/// unresolved id is most likely "not pulled yet", not "gone" — keep the op
/// queued for the next drain. Once hydrated, an unresolved id really is gone
/// (deleted elsewhere) and the op is consumed.
public func handsFreeWriteMayDrop(targetFound: Bool, storeHydrated: Bool) -> Bool {
    targetFound || storeHydrated
}

/// Relevance order for the open tasks Siri / the App-Intent entity query can
/// resolve: scheduled today first, then anything with a due date (soonest
/// first), then most recently touched. The snapshot caps the list, so the
/// order decides WHICH tasks stay addressable — created-at ascending made the
/// newest tasks (the ones a user is most likely to name) fall off the end.
public func siriTaskOrder(_ tasks: [TaskItem], todayIds: Set<String>) -> [TaskItem] {
    func rank(_ t: TaskItem) -> (Int, Int, String, String) {
        let today = todayIds.contains(t.id) ? 0 : 1
        let hasDue = (t.dueAt?.isEmpty == false) ? 0 : 1
        return (today, hasDue, t.dueAt ?? "", t.updatedAt)
    }
    return tasks.enumerated().sorted { a, b in
        let ra = rank(a.element), rb = rank(b.element)
        if ra.0 != rb.0 { return ra.0 < rb.0 }
        if ra.1 != rb.1 { return ra.1 < rb.1 }
        if ra.1 == 0, ra.2 != rb.2 { return ra.2 < rb.2 }   // due soonest first
        if ra.3 != rb.3 { return ra.3 > rb.3 }               // updated most recently first
        return a.offset < b.offset                            // stable
    }.map(\.element)
}

/// Feedback categories that page support (the `report-notify` edge function
/// emails support@ so an abuse report / bug is actioned, not just stored).
public func feedbackNotifiesSupport(category: String?) -> Bool {
    guard let c = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
    return c == "report" || c == "bug"
}
