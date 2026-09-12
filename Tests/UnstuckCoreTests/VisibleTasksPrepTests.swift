// `visibleTasks(view:prep:…)` must return EXACTLY what
// `visibleTasks(view:tasks:blocks:…)` returns — same rows, same order — for
// every view and every filter combination. The prep overload exists only so a
// caller that needs two views (TodayModel.recomputeSnapshot) stops paying for
// the shared derivation twice; if it ever diverged, Today and Backlog would
// silently show different rows than the Tasks screen.

import XCTest
@testable import UnstuckCore

final class VisibleTasksPrepTests: XCTestCase {

    // A fixture with every shape the filter branches on: templates and their
    // occurrences, today/future/past blocks, done, later, slipping, areas,
    // tags, unscheduled, created-today and completed-today.
    private func fixture() -> (tasks: [TaskItem], blocks: [CalBlock]) {
        let today = Clock.todayISO()
        let yesterday = LocalDate.addDays(today, -1)
        let lastWeek = LocalDate.addDays(today, -7)
        let tomorrow = LocalDate.addDays(today, 1)
        let nextWeek = LocalDate.addDays(today, 7)
        let nowMs = Date().timeIntervalSince1970 * 1000
        func stamp(_ daysAgo: Double) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: Date(timeIntervalSince1970: (nowMs - daysAgo * DAY_MS) / 1000))
        }
        let areas = ["Work", "Home", "Health", nil]
        let tags = [["deep-work"], ["errand", "quick"], [], ["Deep-Work"]]

        var tasks: [TaskItem] = []
        for i in 0..<120 {
            let isTemplate = i % 17 == 0
            let done = !isTemplate && i % 6 == 0
            // a spread of ages: 0 = created today, else 1…40 days old
            let age = i % 5 == 0 ? 0.0 : Double(i % 41)
            tasks.append(TaskItem(
                id: "t\(i)",
                name: "Task \(i)",
                estimateMin: [10, 25, 45][i % 3],
                totalFocused: i * 60,
                done: done,
                tags: tags[i % tags.count],
                lifeArea: areas[i % areas.count],
                moveCount: i % 5,
                completedAt: done ? stamp(Double(i % 3) * 0.4) : nil,
                later: i % 9 == 0,
                recurrence: isTemplate ? .weekly(daysOfWeek: [1, 3, 5], until: nil) : nil,
                createdAt: stamp(age),
                updatedAt: stamp(age)))
        }

        var blocks: [CalBlock] = []
        let dates = [lastWeek, yesterday, today, tomorrow, nextWeek]
        for i in 0..<200 {
            let t = tasks[i % tasks.count]
            blocks.append(CalBlock(
                id: "b\(i)", taskId: i % 11 == 0 ? nil : t.id,
                taskName: t.name,
                startTime: String(format: "%02d:%02d", 6 + (i % 14), (i % 4) * 15),
                durationMinutes: [30, 45, 60][i % 3],
                date: dates[i % dates.count],
                kind: i % 13 == 0 ? .external : (i % 23 == 0 ? .placeholder : .task),
                done: i % 7 == 0,
                skipped: i % 19 == 0,
                completedAt: i % 7 == 0 ? stamp(Double(i % 4)) : nil))
        }
        return (tasks, blocks)
    }

    func testPrepOverloadMatchesTheArrayOverloadEverywhere() {
        let (tasks, blocks) = fixture()
        let now = Date().timeIntervalSince1970 * 1000
        let prep = VisibleTasksPrep(tasks: tasks, blocks: blocks)

        let areas: [String?] = [nil, "", "Work", "Home", "Health", UNASSIGNED_AREA, "No Such Area"]
        let tagFilters: [String?] = [nil, "", "deep-work", "DEEP-WORK", "errand", "nope"]

        for view in TaskListView.allCases {
            for area in areas {
                for tag in tagFilters {
                    for slip in [false, true] {
                        let want = visibleTasks(view: view, tasks: tasks, blocks: blocks, now: now,
                                                activeArea: area, activeTag: tag, slipMode: slip)
                        let got = visibleTasks(view: view, prep: prep, now: now,
                                               activeArea: area, activeTag: tag, slipMode: slip)
                        let label = "view=\(view) area=\(String(describing: area)) tag=\(String(describing: tag)) slip=\(slip)"
                        // Same rows, always.
                        XCTAssertEqual(Set(got.map(\.id)), Set(want.map(\.id)), label)
                        XCTAssertEqual(got.count, want.count, label)
                        XCTAssertEqual(got.map(\.id).sorted(), want.map(\.id).sorted(), label)
                        // Same ORDER too — except for Backlog's overdue recurring
                        // rows. `projectOverdueOccurrences` (Occurrences.swift:77)
                        // iterates a Dictionary, so the order of THOSE rows already
                        // varies between two calls in the same process, before and
                        // after this change alike; pinning it here would be asserting
                        // a bug. Everything else, including the whole task-row
                        // prefix that carries the visible ordering, is exact.
                        let wantStable = want.filter { !$0.id.hasPrefix("b") }
                        let gotStable = got.filter { !$0.id.hasPrefix("b") }
                        XCTAssertEqual(gotStable.map(\.id), wantStable.map(\.id), label)
                        XCTAssertEqual(gotStable.map(\.name), wantStable.map(\.name), label)
                        XCTAssertEqual(gotStable.map(\.done), wantStable.map(\.done), label)
                        // …and the occurrence rows keep their derived fields.
                        let byId = Dictionary(want.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        for row in got {
                            XCTAssertEqual(row.name, byId[row.id]?.name, "\(label) id=\(row.id)")
                            XCTAssertEqual(row.done, byId[row.id]?.done, "\(label) id=\(row.id)")
                            XCTAssertEqual(row.estimateMin, byId[row.id]?.estimateMin, "\(label) id=\(row.id)")
                            XCTAssertEqual(row.lifeArea, byId[row.id]?.lifeArea, "\(label) id=\(row.id)")
                        }
                    }
                }
            }
        }
    }

    /// The prep is pure: building it twice from the same input, or reusing one
    /// across views, can't change a view's rows.
    func testPrepIsReusableAndDeterministic() {
        let (tasks, blocks) = fixture()
        let now = Date().timeIntervalSince1970 * 1000
        let a = VisibleTasksPrep(tasks: tasks, blocks: blocks)
        let b = VisibleTasksPrep(tasks: tasks, blocks: blocks)
        for view in TaskListView.allCases {
            let first = visibleTasks(view: view, prep: a, now: now, activeArea: nil, slipMode: false)
            let second = visibleTasks(view: view, prep: a, now: now, activeArea: nil, slipMode: false)
            let other = visibleTasks(view: view, prep: b, now: now, activeArea: nil, slipMode: false)
            // A prep reused across calls IS fully stable — that is the point of
            // hoisting it, and it is strictly MORE deterministic than before.
            XCTAssertEqual(first.map(\.id), second.map(\.id), "\(view) not idempotent")
            XCTAssertEqual(Set(first.map(\.id)), Set(other.map(\.id)), "\(view) prep-dependent")
        }
    }

    /// Empty input must behave the same through both doors.
    func testEmptyInputs() {
        let now = Date().timeIntervalSince1970 * 1000
        for view in TaskListView.allCases {
            let want = visibleTasks(view: view, tasks: [], blocks: [], now: now, activeArea: nil, slipMode: false)
            let got = visibleTasks(view: view, prep: VisibleTasksPrep(tasks: [], blocks: []),
                                   now: now, activeArea: nil, slipMode: false)
            XCTAssertEqual(got.map(\.id), want.map(\.id), "\(view)")
            XCTAssertTrue(got.isEmpty)
        }
    }
}
