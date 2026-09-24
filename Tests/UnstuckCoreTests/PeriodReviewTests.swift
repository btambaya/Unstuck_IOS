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
            // Added Sat 12 Sep 09:00, done Tue 22 Sep 08:00 → 9 whole days (web + Android count the same).
            XCTAssertEqual(gotUnstuck(f), [UnstuckWin(taskId: "t04", name: "Gym bag", waitedDays: 9, moves: 0)])
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

    /// "Waited a week" is elapsed time (floor((done − added) / 24 h)), the
    /// definition web and Android use — not calendar days, which called a task
    /// added Monday night and done the next Monday morning a week-long wait.
    func testGotUnstuckCountsElapsedDaysOrMoves() throws {
        try withZone("UTC") {
            func done(_ id: String, created: String, completed: String, moves: Int? = nil) -> TaskItem {
                TaskItem(id: id, name: id, estimateMin: 25, done: true, moveCount: moves, completedAt: completed, createdAt: created, updatedAt: created)
            }
            let tasks = [
                done("six-days-23h", created: "2026-09-14T21:00:00Z", completed: "2026-09-21T09:00:00Z"),
                done("seven-days", created: "2026-09-14T09:00:00Z", completed: "2026-09-21T09:00:00Z"),
                done("moved-twice", created: "2026-09-20T09:00:00Z", completed: "2026-09-21T10:00:00Z", moves: 2),
                done("quick", created: "2026-09-21T08:00:00Z", completed: "2026-09-21T11:00:00Z", moves: 1),
            ]
            let data = PeriodData(tasks: tasks, blocks: [], sessions: [])
            let f = periodFacts(data, PeriodWindow(from: "2026-09-21", to: "2026-09-27"))
            XCTAssertEqual(gotUnstuck(f), [UnstuckWin(taskId: "seven-days", name: "seven-days", waitedDays: 7, moves: 0),
                                           UnstuckWin(taskId: "moved-twice", name: "moved-twice", waitedDays: 1, moves: 2)])
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

// MARK: - the Insights page and get_period_review tell the same story

/// Both read ONE aggregation (periodFacts). For every shared vector that asks
/// about a week or a month, the page's period (resolveInsightsPeriod) must be
/// the review's span with the review's comparison window, and the headline
/// the page draws — Done, Focused, sessions, Showed up, and the numbers it
/// compares with — must be the numbers the assistant reads out.
final class PageAndReviewAgreeTests: XCTestCase {
    private func plural(_ n: Int, _ one: String) -> String { "\(n) \(n == 1 ? one : one + "s")" }

    func testTheInsightsHeadlineIsTheReviewForEveryWeekAndMonthVector() throws {
        let file = try loadVectors()
        var checked: [String] = []
        for v in file.vectors where v.expect.hasPrefix("ok:") {
            let d = try XCTUnwrap(file.datasets[v.dataset], v.id)
            try withZone(v.tz) {
                let now = prNow(v.now)
                let today = PeriodTime.at(Int64(now.timeIntervalSince1970 * 1000)).day
                let args = PeriodReviewArgs(period: v.args["period"]?.string, date: v.args["date"]?.string,
                                            from: v.args["from"]?.string, to: v.args["to"]?.string)
                guard case .success(let r) = resolvePeriod(args, today: today) else { return XCTFail(v.id) }
                let kind: InsightsPeriodKind
                let offset: Int
                switch r.period {
                case "this_week", "last_week", "week_of":
                    kind = .week
                    offset = CivilDay.between(r.from, CivilDay.monday(today)) / 7
                case "this_month", "last_month", "month_of":
                    kind = .month
                    let (y0, m0, _) = CivilDay.ymd(CivilDay.num(today)), (y1, m1, _) = CivilDay.ymd(CivilDay.num(r.from))
                    offset = (y0 * 12 + m0) - (y1 * 12 + m1)
                default:
                    return   // days / dates: the page has no such span
                }
                let data = PeriodData(tasks: d.tasks, blocks: d.blocks, sessions: d.sessions, captures: d.captures, reasons: d.reasons)
                let p = resolveInsightsPeriod(kind, offset: offset, now: now, earliest: nil)
                XCTAssertEqual([p.from, p.end], [r.from, r.end], v.id)
                XCTAssertEqual(p.clipped, r.clipped, v.id)
                XCTAssertEqual(p.days, r.days, v.id)
                let prev = try XCTUnwrap(p.prev, v.id)
                XCTAssertEqual([prev.from, prev.to], [r.prevFrom, r.prevTo], v.id)

                let h = periodHeadline(data, p)
                let prevSessions = periodFacts(data, prev).sessions.count
                let text = v.expect
                if text.contains(": nothing recorded — ") {
                    XCTAssertEqual([h.done, h.sessions, h.focusMin], [0, 0, 0], v.id)
                } else {
                    // Done
                    if h.done == 0 { XCTAssertTrue(text.contains("\nDone: nothing marked done.\n"), v.id) }
                    if h.plainDone > 0 { XCTAssertTrue(text.contains("\nDone: \(plural(h.plainDone, "task")) — "), v.id) }
                    if h.repeatingDone > 0 { XCTAssertTrue(text.contains("\(plural(h.repeatingDone, "repeating check-off")) — "), v.id) }
                    // Focused + sessions
                    switch h.sessions {
                    case 0: XCTAssertTrue(text.contains("\nFocus: no focus sessions logged.\n"), v.id)
                    case 1: XCTAssertTrue(text.contains("\nFocus: 1 session, \(fmtFocusDur(h.focusMin)) on "), v.id)
                    default: XCTAssertTrue(text.contains("\nFocus: \(h.sessions) sessions, \(fmtFocusDur(h.focusMin)) in all, "), v.id)
                    }
                    // Showed up (the review's "active N of M days"; the length cap may drop the Also line)
                    if text.contains("\nAlso: ") && h.days >= 2 {
                        XCTAssertTrue(text.contains("active \(h.showedUp) of \(h.days) days"), v.id)
                    }
                }
                // The comparison the page's neutral changes are built from.
                let prevDone = try XCTUnwrap(h.prevDone), prevMin = try XCTUnwrap(h.prevFocusMin)
                if prevDone == 0 && prevSessions == 0 {
                    if !(text.contains(": nothing recorded — ") && !text.contains("\nBefore that (")) {
                        XCTAssertTrue(text.contains("): nothing done and no focus logged."), v.id)
                    }
                } else {
                    XCTAssertTrue(text.contains("): done \(h.done) vs \(prevDone) ("), v.id)
                    XCTAssertTrue(text.contains(", focus \(fmtFocusDur(h.focusMin)) vs \(fmtFocusDur(prevMin)) ("), v.id)
                    XCTAssertTrue(text.contains(", sessions \(h.sessions) vs \(prevSessions) ("), v.id)
                }
                checked.append(v.id)
            }
        }
        // Weeks and months in UTC, New York, across DST and another year.
        XCTAssertEqual(checked.sorted(), ["V1-last-week", "V10-history-floor", "V11-this-month", "V12-monday-note",
                                          "V13-length-cap", "V15-stamp-grammar", "V16-hard-cut-keeps-tail", "V17-dst-week",
                                          "V18-other-year", "V19-padded-args", "V2-this-week-so-far", "V4-week-of",
                                          "V6-empty-month", "V8-timezone"])
    }

    /// A forgotten timer and an accidental start: the review, the page and
    /// the Today pill all go through the ONE D1 filter.
    func testTheReviewThePageAndThePillShareTheSessionFilter() throws {
        try withZone("UTC") {
            let now = prNow("2026-09-24T15:30:00.000Z")
            let task = TaskItem(id: "t1", name: "Deep work", estimateMin: 25, createdAt: "2026-09-01T09:00:00Z", updatedAt: "2026-09-01T09:00:00Z")
            let sessions = [
                Session(id: "runaway", taskId: "t1", taskName: "Deep work", estimateMin: 25, actualSec: 35 * 3600,
                        completedAt: "2026-09-22T09:00:00Z"),                      // left running overnight → 85 min
                Session(id: "blip", taskId: "t1", taskName: "Deep work", estimateMin: 25, actualSec: 19,
                        completedAt: "2026-09-23T09:00:00Z"),                      // an accidental start → nothing
            ]
            let review = renderPeriodReview(args: PeriodReviewArgs(period: "this_week"), tasks: [task], blocks: [],
                                            sessions: sessions, captures: [], reasons: [], now: now,
                                            historyFloor: nil, blocksPartial: false)
            XCTAssertTrue(review.contains("\nFocus: 1 session, 1h 25m on \"Deep work\".\n"), review)
            let data = PeriodData(tasks: [task], blocks: [], sessions: sessions)
            let h = periodHeadline(data, resolveInsightsPeriod(.week, offset: 0, now: now, earliest: nil))
            XCTAssertEqual([h.focusMin, h.sessions, h.showedUp], [85, 1, 1])
            XCTAssertEqual(weekFocusMin(sessions: sessions, now: now).thisWeek, 85)
        }
    }
}

// MARK: - cross-platform rules (analytics review, 2026-09-24)

final class InsightsCrossPlatformRulesTests: XCTestCase {
    private func occ(_ id: String, _ taskId: String, _ date: String, done: Bool = false, skipped: Bool = false) -> CalBlock {
        var b = mkBlock(id: id, taskId: taskId, taskName: taskId, date: date)
        b.done = done
        b.skipped = skipped
        return b
    }

    /// Repeating series: kept, then due so far, then name (web's order on all
    /// three). Two series with the same kept count: the one with more days
    /// due comes first even though its name sorts later.
    func testRepeatingSeriesSortByKeptThenDueThenName() {
        var a = mkTask(id: "a", name: "Alpha")
        a.recurrence = .daily(until: nil)
        var z = mkTask(id: "z", name: "Zulu")
        z.recurrence = .daily(until: nil)
        var m = mkTask(id: "m", name: "Mike")
        m.recurrence = .daily(until: nil)
        let blocks = [
            occ("a1", "a", "2026-09-21", done: true), occ("a2", "a", "2026-09-22", skipped: true),
            occ("z1", "z", "2026-09-21", done: true), occ("z2", "z", "2026-09-22"),
            occ("m1", "m", "2026-09-21", done: true), occ("m2", "m", "2026-09-22", done: true),
        ]
        let data = PeriodData(tasks: [a, z, m], blocks: blocks, sessions: [])
        let series = seriesRhythm(data, from: "2026-09-21", to: "2026-09-27", today: "2026-09-24")
        XCTAssertEqual(series.map(\.name), ["Mike", "Zulu", "Alpha"])
        XCTAssertEqual(series.map(\.kept), [2, 1, 1])
        XCTAssertEqual(series.map(\.dueSoFar), [2, 2, 1])
    }

    /// "All time" starts at the earliest task created, task DONE (its
    /// completion) or counted session end — web's rule. A reopened task's old
    /// completion stamp and an accidental 20-second start don't move it.
    func testAllTimeStartsAtTheFirstRealActivity() {
        let made = mkTask(id: "m", createdAt: "2026-09-10T09:00:00.000Z", updatedAt: "2026-09-10T09:00:00.000Z")
        let reopened = mkTask(id: "r", done: false, createdAt: "2026-09-12T09:00:00.000Z",
                              updatedAt: "2026-09-12T09:00:00.000Z", completedAt: "2026-09-01T09:00:00.000Z")
        let tiny = Session(id: "tiny", taskName: "x", actualSec: 20, completedAt: "2026-09-02T09:00:00.000Z")
        XCTAssertEqual(PeriodData(tasks: [made, reopened], blocks: [], sessions: [tiny]).earliestDay, "2026-09-10")
        // A done task's completion counts, even before any creation stamp.
        let done = mkTask(id: "d", done: true, createdAt: "2026-09-11T09:00:00.000Z",
                          updatedAt: "2026-09-11T09:00:00.000Z", completedAt: "2026-09-05T09:00:00.000Z")
        XCTAssertEqual(PeriodData(tasks: [made, done], blocks: [], sessions: []).earliestDay, "2026-09-05")
        // So does a counted session's end.
        let real = Session(id: "real", taskName: "x", actualSec: 1500, completedAt: "2026-09-03T09:00:00.000Z")
        XCTAssertEqual(PeriodData(tasks: [made], blocks: [], sessions: [real]).earliestDay, "2026-09-03")
        withZone("UTC") {
            let all = resolveInsightsPeriod(.all, offset: 0, now: prNow("2026-09-24T15:30:00.000Z"),
                                            earliest: PeriodData(tasks: [made, reopened], blocks: [], sessions: [tiny]).earliestDay)
            XCTAssertEqual(all.from, "2026-09-10")
        }
    }
}
