// UI-test support — a local, network-free "demo" boot so XCUITest can drive
// every real screen (Today / Tasks / Calendar / Lists / Focus / Insights /
// Settings) with representative data, no Supabase config or sign-in required.
// Gated behind a launch env var and #if DEBUG, so it never affects Release /
// TestFlight builds.

#if DEBUG
import Foundation
import UnstuckCore
import UnstuckData
import UnstuckSync

enum DemoSeed {
    private static func iso(_ offsetSec: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(offsetSec))
    }

    static func seed(_ db: AppDatabase) {
        let now = iso(0)
        let today = Clock.todayISO()

        // Life areas + tags (the editable vocabularies).
        for (i, a) in ["Work", "Personal", "Health"].enumerated() {
            try? db.save(LifeArea(id: "area-\(a)", name: a, color: ["indigo", "coral", "green"][i], sortOrder: i))
        }
        for (i, t) in ["deep-work", "quick", "errand"].enumerated() {
            try? db.save(TagRow(id: "tag-\(t)", name: t, color: nil, sortOrder: i))
        }

        // Tasks — a realistic open/later/done spread, with a firstPhysicalAction
        // on the Start-Next candidate so the headline shows the smallest step.
        let tasks: [TaskItem] = [
            TaskItem(id: "t-proposal", name: "Draft the Q3 proposal", estimateMin: 45, tags: ["deep-work"],
                     lifeArea: "Work", firstPhysicalAction: "Open the doc and write one sentence",
                     createdAt: now, updatedAt: now),
            TaskItem(id: "t-sarah", name: "Reply to Sarah", estimateMin: 10, tags: ["quick"],
                     lifeArea: "Work", createdAt: now, updatedAt: now),
            TaskItem(id: "t-walk", name: "30-minute walk", estimateMin: 30, lifeArea: "Health", createdAt: now, updatedAt: now),
            TaskItem(id: "t-dentist", name: "Book the dentist", estimateMin: 5, tags: ["errand"],
                     lifeArea: "Personal", later: true, createdAt: now, updatedAt: now),
            TaskItem(id: "t-inbox", name: "Inbox to zero", estimateMin: 20, done: true,
                     lifeArea: "Work", completedAt: now, createdAt: now, updatedAt: now),
        ]
        tasks.forEach { try? db.save($0) }

        // Scheduled blocks placed RELATIVE to the current hour — the calendar
        // day view auto-scrolls to NOW, so screenshots always show a populated
        // schedule regardless of when the tour runs. Clamped to the 6–21h grid.
        let h = Calendar.current.component(.hour, from: Date())
        func hm(_ hour: Int) -> String { String(format: "%02d:00", min(max(hour, 6), 21)) }
        let blocks: [(id: String, taskId: String, name: String, start: String, mins: Int)] = [
            ("blk-sarah", "t-sarah", "Reply to Sarah", hm(h - 1), 15),
            ("blk-proposal", "t-proposal", "Draft the Q3 proposal", hm(h + 1), 45),
            ("blk-walk", "t-walk", "30-minute walk", hm(h + 2), 30),
            ("blk-review", "t-review", "Review the launch checklist", hm(h + 3), 30),
        ]
        for b in blocks {
            try? db.save(CalBlock(id: b.id, taskId: b.taskId, taskName: b.name,
                                  startTime: b.start, durationMinutes: b.mins, date: today, kind: .task))
        }
        try? db.save(TaskItem(id: "t-review", name: "Review the launch checklist", estimateMin: 30,
                              tags: ["deep-work"], lifeArea: "Work", createdAt: now, updatedAt: now))

        // Six recent sessions (linked to tasks, spread across this week's
        // weekdays) so Insights clears the real-data threshold (≥5) and the
        // calibration / weekday / heatmap panels have representative signal.
        let sessions: [(id: String, taskId: String, name: String, est: Int, actualSec: Int, offset: Double)] = [
            ("sess-0", "t-proposal", "Draft the Q3 proposal", 45, 2_700, -3_600),     // today, 45m vs 45 ✓
            ("sess-1", "t-sarah", "Reply to Sarah", 10, 540, -108_000),               // Fri, 9m vs 10 ✓
            ("sess-2", "t-inbox", "Inbox to zero", 20, 1_500, -201_600),              // Thu, 25m vs 20 ✓
            ("sess-3", "t-walk", "30-minute walk", 30, 1_800, -277_200),              // Wed, 30m vs 30 ✓
            ("sess-4", "t-proposal", "Draft the Q3 proposal", 45, 3_300, -360_000),   // Tue, 55m vs 45 ✗
            ("sess-5", "t-sarah", "Reply to Sarah", 10, 720, -444_000),               // Mon, 12m vs 10 ✓
        ]
        for s in sessions {
            try? db.save(Session(id: s.id, taskId: s.taskId, taskName: s.name, tags: nil,
                                 estimateMin: s.est, actualSec: s.actualSec, completedAt: iso(s.offset)))
        }

        // Captures + a pause reason so the deep-dive interruption/pause panels fill.
        try? db.save(Capture(id: "cap-1", taskId: "t-proposal", sessionId: "sess-0", tag: .idea, body: "Mention the pilot results", at: iso(-3_300)))
        try? db.save(Capture(id: "cap-2", taskId: nil, sessionId: "sess-1", tag: .distraction, body: "Slack ping", at: iso(-7_000)))
        try? db.save(ReasonLog(id: "rl-1", taskId: "t-proposal", reason: "Distracted", action: .pause, at: iso(-3_400), durationSec: 120))

        // Collections (Lists) — one with a pinned item.
        try? db.save(ItemCollection(id: "col-groceries", name: "Groceries", color: "green", subtitle: "Weekend run",
                                    items: [
                                        CollectionItem(id: "g1", body: "Milk", at: now),
                                        CollectionItem(id: "g2", body: "Eggs", at: now),
                                        CollectionItem(id: "g3", body: "Coffee beans", at: now),
                                    ], sortOrder: 0, archived: false))
        try? db.save(ItemCollection(id: "col-books", name: "Books to read", color: "indigo", subtitle: nil,
                                    items: [
                                        CollectionItem(id: "b1", body: "Four Thousand Weeks", pinned: true, at: now),
                                        CollectionItem(id: "b2", body: "Deep Work", at: now),
                                    ], sortOrder: 1, archived: false))
    }
}
#endif
