// Quiet in-app nudges — surfaced on Today, never pushed (the "things slipping /
// follow-ups" catalog). Port of the Android AppViewModel.computeNudges + the
// Nudge/NudgeKind model (ui/AppViewModel.kt). Kept as a pure function of
// tasks + captures + now so it's deterministic and unit-testable like the rest
// of UnstuckCore.

import Foundation

/// What a nudge points at. SLIPPING → open the task's detail; CAPTURE → promote
/// the capture. (CAPTURE is unused today — the Inbox surfaces captures for
/// triage — but kept for parity with the Android enum + the catalog.)
public enum NudgeKind: Sendable {
    case slipping
    case capture
}

/// A quiet, in-app nudge surfaced on Today (no push).
public struct Nudge: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: NudgeKind
    public let title: String
    public let action: String
    public let taskId: String?
    public let captureId: String?

    public init(id: String, kind: NudgeKind, title: String, action: String,
                taskId: String? = nil, captureId: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.action = action
        self.taskId = taskId
        self.captureId = captureId
    }
}

/// Compute the quiet Today nudges from the current tasks + captures.
/// 1:1 with Android `computeNudges`:
///  - D1 slipping: open, non-recurring tasks older than 3 weeks OR rescheduled
///    3+ times. (recurrence == nil so a hidden template never "slips".)
///  - No capture nudge (the Inbox already surfaces captures for triage; a nudge
///    for a thought you just wrote was redundant + naggy).
/// Capped at the first 3.
public func computeNudges(tasks: [TaskItem], captures: [Capture], now: EpochMillis) -> [Nudge] {
    var out: [Nudge] = []
    for t in tasks where !t.done && t.recurrence == nil {
        let ageDays = Time.parseMillis(t.createdAt).map { (now - $0) / 86_400_000.0 } ?? 0
        if ageDays >= 21 || (t.moveCount ?? 0) >= 3 {
            out.append(Nudge(id: "slip:\(t.id)", kind: .slipping,
                             title: "“\(t.name)” has been waiting a while.",
                             action: "Open", taskId: t.id))
        }
    }
    return Array(out.prefix(3))
}
