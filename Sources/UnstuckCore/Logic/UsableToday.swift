// Shared "usable time today" math — total scheduled minutes minus meetings
// (external blocks) and soft placeholders (settle/lunch buffers). Port of
// lib/use-usable-today.ts, so the assistant's context strip shows the SAME
// number the web's right-rail TimeRemaining panel does.

import Foundation

public struct UsableToday: Equatable, Sendable {
    /// Scheduled-minus-meetings-minus-buffers, floored at 0.
    public let usableMins: Int
    public let totalScheduled: Int
    public let meetingMins: Int
    public let bufferedMins: Int

    public init(usableMins: Int, totalScheduled: Int, meetingMins: Int, bufferedMins: Int) {
        self.usableMins = usableMins
        self.totalScheduled = totalScheduled
        self.meetingMins = meetingMins
        self.bufferedMins = bufferedMins
    }
}

/// "2h 40m" / "3h" / "45m" — the web `fmtHrs`.
public func fmtHrs(_ mins: Int) -> String {
    let h = mins / 60
    let m = mins % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

/// Today's usable time. A block that is already done or skipped isn't time
/// still to use (a skipped 30-min slot read "30m usable"; cross-check P0-10):
/// occurrence blocks carry their own `done`/`skipped`, and a plain task's
/// done-ness lives on the task, so the caller passes `doneTaskIds`.
public func usableToday(blocks: [CalBlock], todayIso: String = Clock.todayISO(),
                        doneTaskIds: Set<String> = []) -> UsableToday {
    let today = blocks.filter {
        $0.date == todayIso && !$0.done && !$0.skipped && !doneTaskIds.contains($0.taskId ?? "")
    }
    func total(_ predicate: (CalBlock) -> Bool) -> Int {
        today.filter(predicate).reduce(0) { $0 + $1.durationMinutes }
    }
    let totalScheduled = total { _ in true }
    let meetingMins = total(isExternalBlock)
    let bufferedMins = total(isPlaceholderBlock)
    return UsableToday(usableMins: max(0, totalScheduled - meetingMins - bufferedMins),
                       totalScheduled: totalScheduled,
                       meetingMins: meetingMins,
                       bufferedMins: bufferedMins)
}
