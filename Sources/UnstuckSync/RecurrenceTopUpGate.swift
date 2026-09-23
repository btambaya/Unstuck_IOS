// RecurrenceTopUpGate — when the horizon top-up may run (audit 2026-09-22 C21,
// stage 2; deterministic-occurrence-ids.md §3c "C21 ordering" and §f).
//
// The top-up extends every repeating task's tail from what THIS device's store
// holds. Run against a stale store it mints days another device already has
// (insert-if-absent makes those harmless, but they are wasted requests and,
// before stage 2, twins), and run against a truncated one it keeps re-minting
// rows it can't see. So it runs only:
//  • after a pull whose cal_blocks read SUCCEEDED (Hydrator.calBlocksPull —
//    the generic "pull succeeded" signals don't say that), and only when that
//    stamp has moved since the last run. A caller that pulls first (the
//    day / time-zone observers, §3c "topUpAfterCatchUp") also needs ITS OWN
//    pull to have moved it: an earlier floor pull would otherwise stand in
//    for a pull that failed (`pulledAfter`);
//  • when that read did not hit PostgREST's row cap (a truncated read would
//    feed the phantom-row re-mint of §f; paginating the pull is the real fix);
//  • once per local day per user, and again when the time zone changes.
// The caller serialises the runs (one in flight, one trailing).

import Foundation

public struct RecurrenceTopUpGate: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case run
        /// No cal_blocks read has succeeded this session.
        case noPull
        /// The read hit the row cap: the store may be missing rows.
        case truncated
        /// No new successful read since the last run.
        case pullNotAdvanced
        /// Already ran for this user today, in this time zone.
        case alreadyRanToday
    }

    public struct Run: Sendable, Equatable {
        public let userId: String
        public let day: String
        public let timeZone: String
        public let pullSeq: Int
    }

    public private(set) var lastRun: Run?

    public init() {}

    /// `pulledAfter`: the stamp's `seq` read just BEFORE the caller's own pull
    /// (0 when there was none yet); nil when the caller did not pull (the
    /// hydrate hook, which has just pulled). The pull must have moved past it.
    public func verdict(pull: CalBlocksPull?, userId: String, today: String, timeZone: String,
                        pulledAfter: Int? = nil) -> Verdict {
        guard let pull else { return .noPull }
        if let before = pulledAfter, pull.seq <= before { return .pullNotAdvanced }
        if pull.mayBeTruncated { return .truncated }
        guard let last = lastRun, last.userId == userId else { return .run }
        if pull.seq <= last.pullSeq { return .pullNotAdvanced }
        if last.day == today && last.timeZone == timeZone { return .alreadyRanToday }
        return .run
    }

    public mutating func recordRun(pull: CalBlocksPull, userId: String, today: String, timeZone: String) {
        lastRun = Run(userId: userId, day: today, timeZone: timeZone, pullSeq: pull.seq)
    }
}
