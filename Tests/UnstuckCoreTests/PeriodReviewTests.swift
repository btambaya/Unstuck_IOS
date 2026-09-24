// get_period_review + periodFacts: the SHARED vectors (every platform must
// reproduce every string exactly — PeriodReviewVectors.generated.swift is
// written by the web repo's scripts/gen-tool-registry.mjs), plus the spec §6
// unit cases (a) the tail-safe hard cut and (e) the stamp grammar, plus the
// numbers the Insights screen draws from the same facts.

import XCTest
@testable import UnstuckCore

// MARK: - vector file

private enum ArgValue: Decodable {
    case string(String)
    case other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) } else { self = .other }
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
}

struct PRDataset: Decodable {
    let tasks: [TaskItem]
    let blocks: [CalBlock]
    let sessions: [Session]
    let captures: [Capture]
    let reasons: [ReasonLog]
}

private struct PRVector: Decodable {
    let id: String
    let tz: String
    let now: String
    let dataset: String
    let historyFloor: String?
    let blocksPartial: Bool
    let args: [String: ArgValue]
    let expect: String
}

private struct PRFile: Decodable {
    let version: Int
    let datasets: [String: PRDataset]
    let vectors: [PRVector]
}

private func loadVectors() throws -> PRFile {
    try JSONDecoder().decode(PRFile.self, from: Data(PeriodReviewVectors.json.utf8))
}

func prDataset(_ name: String) throws -> PRDataset {
    let file = try JSONDecoder().decode(PRFile.self, from: Data(PeriodReviewVectors.json.utf8))
    return try XCTUnwrap(file.datasets[name])
}

func prNow(_ iso: String) -> Date { Date(timeIntervalSince1970: Time.parseMillis(iso)! / 1000) }

/// Runs `body` with the process zone set to `tz` (Time.calendar follows it;
/// TimeZone.current does NOT — which is why the engine never reads it).
func withZone<T>(_ tz: String, _ body: () throws -> T) rethrows -> T {
    let saved = NSTimeZone.default
    NSTimeZone.default = TimeZone(identifier: tz)!
    defer { NSTimeZone.default = saved }
    return try body()
}

final class PeriodReviewVectorTests: XCTestCase {
    func testEverySharedVectorByteForByte() throws {
        let file = try loadVectors()
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.vectors.count, 25)
        for v in file.vectors {
            let d = try XCTUnwrap(file.datasets[v.dataset], v.id)
            let out = withZone(v.tz) {
                renderPeriodReview(
                    args: PeriodReviewArgs(period: v.args["period"]?.string, date: v.args["date"]?.string,
                                           from: v.args["from"]?.string, to: v.args["to"]?.string),
                    tasks: d.tasks, blocks: d.blocks, sessions: d.sessions, captures: d.captures, reasons: d.reasons,
                    now: prNow(v.now), historyFloor: v.historyFloor, blocksPartial: v.blocksPartial)
            }
            XCTAssertEqual(out, v.expect, "vector \(v.id)")
            XCTAssertLessThanOrEqual(out.utf16.count, PERIOD_REVIEW_MAX_CHARS, v.id)
        }
    }

    func testNonStringArgumentsCountAsAbsent() throws {
        let d = try prDataset("A")
        let out = withZone("UTC") {
            renderPeriodReview(args: PeriodReviewArgs(period: nil), tasks: d.tasks, blocks: d.blocks, sessions: d.sessions,
                               captures: d.captures, reasons: d.reasons, now: prNow("2026-09-24T15:30:00.000Z"),
                               historyFloor: nil, blocksPartial: false)
        }
        XCTAssertTrue(out.hasPrefix("error: period required — "), out)
    }
}

// MARK: - §6 (a) the hard cut keeps the tail and never splits a surrogate pair

final class PeriodReviewCapTests: XCTestCase {
    func testHardCutDropsADanglingHighSurrogateAndKeepsTheTail() {
        // 18 ASCII units then an emoji (2 UTF-16 units) straddling the cut.
        var head = ["abcdefghijklmnopqr🧾tail of the head"]
        let tail = ["Before that: x.", "note: y."]
        // room = max − 1 − (tail + 1) = 19 → the prefix ends on the emoji's high surrogate.
        let maxChars = 19 + 1 + tail.joined(separator: "\n").utf16.count + 1
        let out = capReview(head: &head, tail: tail, areaLine: nil, maxChars: maxChars)
        XCTAssertEqual(out, "abcdefghijklmnopqr…\nBefore that: x.\nnote: y.")
        XCTAssertLessThanOrEqual(out.utf16.count, maxChars)
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"))
    }

    func testDropsByAreaThenAlsoBeforeCutting() {
        var head = ["ok: review.", "Also: added 1 task.", "By area: Work 1."]
        let out = capReview(head: &head, tail: ["Before that (x): nothing done and no focus logged."], areaLine: "By area: Work 1.", maxChars: 90)
        XCTAssertEqual(out, "ok: review.\nAlso: added 1 task.\nBefore that (x): nothing done and no focus logged.")
        var head2 = ["ok: review.", "Also: added 1 task.", "By area: Work 1."]
        let out2 = capReview(head: &head2, tail: ["Before that (x): nothing done and no focus logged."], areaLine: "By area: Work 1.", maxChars: 70)
        XCTAssertEqual(out2, "ok: review.\nBefore that (x): nothing done and no focus logged.")
    }
}

// MARK: - §6 (e) the stamp grammar, on this platform's parser

final class PeriodStampGrammarTests: XCTestCase {
    private func utc(_ s: String) -> Int64? { withZone("UTC") { PeriodTime.ms(s) } }

    func testAcceptedShapes() {
        XCTAssertEqual(utc("2026-09-15T14:00:00.123456+00:00"), 1_789_480_800_123)
        XCTAssertEqual(utc("2026-09-15T14:00:00Z"), 1_789_480_800_000)
        XCTAssertEqual(utc("2026-09-15T14:00Z"), 1_789_480_800_000)
        XCTAssertEqual(utc("2026-09-15T14:00:00.5Z"), 1_789_480_800_500)
        XCTAssertEqual(utc("2026-09-15T14:00:00.123456789Z"), 1_789_480_800_123)
        XCTAssertEqual(utc("2026-09-15T19:30:00+05:30"), 1_789_480_800_000)
        XCTAssertEqual(utc("2026-09-15T19:30:00+0530"), 1_789_480_800_000)
        XCTAssertEqual(utc("2026-09-15T16:00:00+02"), 1_789_480_800_000)
        XCTAssertEqual(utc("2026-09-15T10:00:00-04:00"), 1_789_480_800_000)
        XCTAssertEqual(utc("2028-02-29T00:00:00Z"), 1_835_395_200_000)
    }

    func testRejectedShapes() {
        for s in ["2026-09-16", "2026-09-16 10:00:00+00", "2026-09-31T10:00:00Z", "2026-02-29T10:00:00Z",
                  "2026-09-15T24:00:00Z", "2026-09-15T10:60:00Z", "2026-09-15T10:00:60Z", "2026-09-15T10:00:00+24:00",
                  "2026-09-15T10:00:00+05:60", "2026-09-15t10:00:00Z", "2026-09-15T10:00:00z",
                  "2026-09-15T10:00:00.1234567890Z", "2026-09-15T10:00:00.Z", "2026-09-15T10:00:00+5",
                  "2026-09-15T10:00:00+05:3", "1899-12-31T10:00:00Z", "2026-13-01T10:00:00Z", "not a time", "",
                  "2026-09-15T10:00:00 Z", "2026-09-15T10:00:00Europe/London"] {
            XCTAssertNil(utc(s), s)
        }
        XCTAssertNil(PeriodTime.ms(nil))
    }

    func testZoneLessStampsAreLocalWallClockInTimeCalendar() {
        withZone("America/New_York") {
            // Monday 01:00 LOCAL (05:00Z) — would be Sunday 20 Sep read as UTC.
            XCTAssertEqual(PeriodTime.parse("2026-09-21T01:00:00")?.day, "2026-09-21")
            XCTAssertEqual(PeriodTime.ms("2026-09-21T01:00:00"), 1_789_966_800_000)
            // DST gap moves forward; the overlap takes the earlier offset (JS + Java agree).
            XCTAssertEqual(PeriodTime.ms("2026-03-08T02:30:00"), Int64(Time.parseMillis("2026-03-08T07:30:00Z")!))
            XCTAssertEqual(PeriodTime.ms("2026-11-01T01:30:00"), Int64(Time.parseMillis("2026-11-01T05:30:00Z")!))
            // A +05:30 stamp that is Monday in UTC is Sunday in New York.
            XCTAssertEqual(PeriodTime.parse("2026-09-21T09:00:00+05:30")?.day, "2026-09-20")
            XCTAssertEqual(PeriodTime.parse("2026-09-21T09:00:00+05:30")?.minute, 23 * 60 + 30)
        }
    }
}

// MARK: - the D1 session filter

final class SessionFilterTests: XCTestCase {
    private func s(_ sec: Int, est: Int?) -> Session {
        Session(id: "s", taskName: "x", estimateMin: est, actualSec: sec, completedAt: "2026-09-15T10:00:00Z")
    }

    func testDropsSubMinuteStartsAndClampsRunawayTimers() {
        XCTAssertNil(countedSec(s(59, est: 25)))
        XCTAssertEqual(countedSec(s(60, est: 25)), 60)
        XCTAssertEqual(countedSec(s(25 * 60, est: 25)), 25 * 60)
        // est 25 → cap max(75, 85) = 85 min.
        XCTAssertEqual(countedSec(s(5 * 3600, est: 25)), 85 * 60)
        // est 45 → max(135, 105) = 135 min.
        XCTAssertEqual(countedSec(s(5 * 3600, est: 45)), 135 * 60)
        // est 90 → 270 min, but never past 4 h.
        XCTAssertEqual(countedSec(s(143 * 3600, est: 90)), 4 * 3600)
        // No estimate → 4 h.
        XCTAssertEqual(countedSec(s(35 * 3600, est: nil)), 4 * 3600)
        XCTAssertEqual(countedSec(s(35 * 3600, est: 0)), 4 * 3600)
        XCTAssertEqual(countableSessions([s(5, est: 25), s(19, est: 25), s(37, est: 25), s(600, est: 25)]).map(\.actualSec), [600])
    }
}

// MARK: - the facts the Insights screen draws (dataset A, Thu 24 Sep 2026 15:30 UTC)

final class PeriodFactsTests: XCTestCase {
    private let now = prNow("2026-09-24T15:30:00.000Z")

    private func data() throws -> PeriodData {
        let d = try prDataset("A")
        return PeriodData(tasks: d.tasks, blocks: d.blocks, sessions: d.sessions, captures: d.captures, reasons: d.reasons)
    }

    func testLastWeekMatchesTheReviewNumbers() throws {
        try withZone("UTC") {
            let data = try self.data()
            let p = resolveInsightsPeriod(.week, offset: 1, now: now, earliest: data.earliestDay)
            XCTAssertEqual([p.from, p.to, p.end], ["2026-09-14", "2026-09-20", "2026-09-20"])
            XCTAssertFalse(p.clipped)
            XCTAssertEqual(p.title, "Last week")
            XCTAssertEqual(p.subtitle, "14–20 Sep")
            XCTAssertEqual(p.compareLabel, "vs the week before")
            let h = periodHeadline(data, p)
            // "Done 9 vs 4, focus 2h 50m vs 1h 5m, sessions 5 vs 2, active 6 of 7 days".
            XCTAssertEqual(h, PeriodHeadline(done: 9, plainDone: 3, repeatingDone: 6, added: 2, focusMin: 170, sessions: 5,
                                             showedUp: 6, days: 7, prevDone: 4, prevFocusMin: 65, prevShowedUp: 3))
            let f = periodFacts(data, p.window)
            let days = dailyFacts(f, from: p.from, to: p.to)
            XCTAssertEqual(days.map(\.date), ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20"])
            XCTAssertEqual(days.map(\.done), [1, 2, 3, 1, 1, 1, 0])
            XCTAssertEqual(days.map { roundedMinutes($0.focusSec) }, [40, 65, 10, 25, 30, 0, 0])
            XCTAssertEqual(busiestDay(f)?.date, "2026-09-16")

            let plan = try XCTUnwrap(planFacts(data, from: p.from, end: p.end, clipped: false, nowMs: Int64(Time.parseMillis("2026-09-24T15:30:00.000Z")!)))
            XCTAssertEqual(plan.planned, 11)
            XCTAssertEqual(plan.doneToPlan, 7)
            XCTAssertEqual(plan.slipped.map(\.task.name), ["Tax return", "Gym bag"])
            XCTAssertEqual(plan.doneLater, 1)
            XCTAssertEqual(plan.stillOpen, 3)          // Tax return + 2 repeating days
            XCTAssertEqual(plan.skipped, 1)
            XCTAssertEqual(plan.deadlines.map(\.name), ["Invoice Acme"])

            let series = seriesRhythm(data, from: p.from, to: p.to, today: "2026-09-24")
            XCTAssertEqual(series.map(\.name), ["Stretch", "Walk the dog"])
            XCTAssertEqual(series[0].dots.map(\.state), [.done, .done, .done, .done, .done, .skipped, .open])
            XCTAssertEqual([series[0].kept, series[0].dueSoFar, series[0].skipped], [5, 6, 1])
            XCTAssertEqual(series[1].dots.map(\.state), [.done, .open])

            XCTAssertEqual(doneByArea(f), [AreaCount(area: "Health", count: 6), AreaCount(area: "Home", count: 1),
                                           AreaCount(area: "Work", count: 1), AreaCount(area: nil, count: 1)])
            XCTAssertEqual(gotUnstuck(f), [])
        }
    }

    func testThisWeekSoFarIsCutAtTheSameMinuteAndFlagsTheWin() throws {
        try withZone("UTC") {
            let data = try self.data()
            let p = resolveInsightsPeriod(.week, offset: 0, now: now, earliest: data.earliestDay)
            XCTAssertEqual([p.from, p.to, p.end], ["2026-09-21", "2026-09-27", "2026-09-24"])
            XCTAssertEqual(p.cut, 15 * 60 + 30)
            XCTAssertEqual(p.prev, PeriodWindow(from: "2026-09-14", to: "2026-09-17", cut: 930))
            XCTAssertEqual(p.title, "This week")
            XCTAssertEqual(p.subtitle, "21–24 Sep, so far")
            XCTAssertEqual(p.compareLabel, "vs same point last week")
            let h = periodHeadline(data, p)
            XCTAssertEqual([h.done, h.focusMin, h.sessions, h.showedUp, h.days], [5, 65, 2, 4, 4])
            XCTAssertEqual([h.prevDone, h.prevFocusMin], [7, 140])
            let f = periodFacts(data, p.window)
            XCTAssertEqual(gotUnstuck(f), [UnstuckWin(taskId: "t04", name: "Gym bag", waitedDays: 10, moves: 0)])
            XCTAssertEqual(stillOpenOn(data, day: "2026-09-24"), 2)
            let series = seriesRhythm(data, from: p.from, to: p.to, today: "2026-09-24")
            XCTAssertEqual(series.first?.dots.map(\.state), [.done, .done, .open, .upcoming])
            XCTAssertEqual(weekFocusMin(sessions: data.sessions, now: now).thisWeek, 65)
            XCTAssertEqual(weekFocusMin(sessions: data.sessions, now: now).lastWeek, 170)
        }
    }

    func testMonthsAndStepping() throws {
        try withZone("UTC") {
            let data = try self.data()
            let m0 = resolveInsightsPeriod(.month, offset: 0, now: now, earliest: data.earliestDay)
            XCTAssertEqual([m0.from, m0.to, m0.end], ["2026-09-01", "2026-09-30", "2026-09-24"])
            XCTAssertEqual(m0.prev, PeriodWindow(from: "2026-08-01", to: "2026-08-24", cut: 930))
            XCTAssertEqual(m0.compareLabel, "vs same point in August")
            let m1 = resolveInsightsPeriod(.month, offset: 1, now: now, earliest: data.earliestDay)
            XCTAssertEqual([m1.from, m1.to, m1.end, m1.title], ["2026-08-01", "2026-08-31", "2026-08-31", "August"])
            XCTAssertEqual(m1.compareLabel, "vs July")
            XCTAssertEqual(data.earliestDay, "2026-09-01")
            XCTAssertFalse(canStepBack(m0, earliest: data.earliestDay))    // nothing before September
            let w2 = resolveInsightsPeriod(.week, offset: 2, now: now, earliest: data.earliestDay)
            XCTAssertEqual(w2.title, "7–13 Sep")
            XCTAssertEqual(w2.compareLabel, "vs 31 Aug – 6 Sep")
            XCTAssertTrue(canStepBack(w2, earliest: data.earliestDay))
            let w3 = resolveInsightsPeriod(.week, offset: 3, now: now, earliest: data.earliestDay)
            XCTAssertFalse(canStepBack(w3, earliest: data.earliestDay))   // 31 Aug week holds the first day
            let all = resolveInsightsPeriod(.all, offset: 0, now: now, earliest: data.earliestDay)
            XCTAssertEqual([all.from, all.end, all.title, all.subtitle], ["2026-09-01", "2026-09-24", "All time", "since 1 Sep"])
            XCTAssertNil(all.prev)
            let h = periodHeadline(data, all)
            XCTAssertEqual([h.done, h.focusMin, h.sessions], [18, 300, 9])
            XCTAssertNil(h.prevDone)
        }
    }

    func testTrendIsOldestFirstAndMarksTheSelectedWeek() throws {
        try withZone("UTC") {
            let data = try self.data()
            let t = periodTrend(data, kind: .week, selectedFrom: "2026-09-14", now: now, count: 4)
            XCTAssertEqual(t.map(\.from), ["2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21"])
            XCTAssertEqual(t.map(\.label), ["31 Aug", "7 Sep", "14 Sep", "21 Sep"])
            XCTAssertEqual(t.map(\.done), [0, 4, 9, 5])
            XCTAssertEqual(t.map(\.focusMin), [0, 65, 170, 65])
            XCTAssertEqual(t.map(\.selected), [false, false, true, false])
            XCTAssertEqual(t.map(\.partial), [false, false, false, true])
            let months = periodTrend(data, kind: .month, selectedFrom: nil, now: now, count: 2)
            XCTAssertEqual(months.map(\.label), ["Aug", "Sep"])
            XCTAssertEqual(months.map(\.done), [0, 18])
        }
    }

    func testNeutralDeltas() {
        XCTAssertEqual(neutralDelta(0), "same")
        XCTAssertEqual(neutralDelta(2), "+2")
        XCTAssertEqual(neutralDelta(-3), "−3")
        XCTAssertEqual(neutralDurDelta(-40), "−40m")
        XCTAssertEqual(neutralDurDelta(65), "+1h 5m")
        XCTAssertEqual(fmtFocusDur(120), "2h")
        XCTAssertEqual(roundedMinutes(89), 1)
        XCTAssertEqual(roundedMinutes(29), 0)
    }

    func testCivilDatesAreZoneFree() {
        XCTAssertEqual(CivilDay.add("2026-03-08", 1), "2026-03-09")
        XCTAssertEqual(CivilDay.monday("2026-09-27"), "2026-09-21")   // Sunday → its Monday
        XCTAssertEqual(CivilDay.monday("2026-09-21"), "2026-09-21")
        XCTAssertEqual(CivilDay.weekday("2026-09-24"), 4)
        XCTAssertEqual(CivilDay.lastOfMonth("2028-02-10"), "2028-02-29")
        XCTAssertNil(CivilDay.parse("2026-02-30"))
        XCTAssertNil(CivilDay.parse("0099-01-01"))
        XCTAssertEqual(CivilDay.range("2026-09-29", "2026-10-02"), ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"])
    }
}
