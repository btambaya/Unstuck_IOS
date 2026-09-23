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
        // on the proposal so the Focus screen (entered from that row's context
        // menu, or from the editor) shows a real first step. It used to feed
        // the Today Start-Next hero's headline; the hero went on 2026-09-18,
        // the field and the screenshot flow that relies on it did not.
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
        let h = Time.calendar.component(.hour, from: Date())
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

// MARK: - bulk-turn repro (UITEST_ASSISTANT_BULK)
//
// Testers report the app dying "after being asked to add a lot of items to the
// calendar" (TestFlight 33/34/41). This replays exactly that turn through the
// REAL AssistantModel / harness / executor / store — no network, no LLM — so
// the whole app (SwiftUI thread + receipts, calendar relayout, reminder
// rescheduling, widget snapshots) runs the burst under XCUITest.

import Supabase

@MainActor
final class BulkAssistantScript: AssistantTransport {
    /// How many items per round (25 is the executor's create_tasks cap).
    private let n: Int
    private var round = 0
    init(items: Int = 25) { self.n = items }

    private var tomorrow: String { LocalDate.addDays(Clock.todayISO(), 1) }

    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk {
        round += 1
        switch round {
        case 1:
            // One create_tasks carrying date + startTime per item: each lands a
            // task AND a calendar block, all on the same day, overlapping.
            let items = (0..<n).map { i in
                #"{"name":"Bulk task \#(i + 1)","estimateMin":45,"date":"\#(tomorrow)","startTime":"\#(String(format: "%02d:00", 8 + i % 10))"}"#
            }.joined(separator: ",")
            return .ok(HarnessReply(content: "Adding those now.", toolCalls: [
                ToolCall(id: "bulk-1", type: "function",
                         function: ToolFunction(name: "create_tasks", arguments: #"{"tasks":[\#(items)]}"#)),
            ]))
        case 2:
            // A second round of block_time calls — 25 tool calls in ONE reply.
            let calls = (0..<n).map { i in
                ToolCall(id: "blk-\(i)", type: "function",
                         function: ToolFunction(name: "block_time",
                                                arguments: #"{"name":"Commitment \#(i + 1)","date":"\#(tomorrow)","startTime":"\#(String(format: "%02d:30", 8 + i % 10))","durationMin":90}"#))
            }
            return .ok(HarnessReply(content: "And the commitments.", toolCalls: calls))
        default:
            return .ok(HarnessReply(content: "That's \(n * 2) things on \(tomorrow)."))
        }
    }
}
#endif

// MARK: - canned reply (UITEST_ASSISTANT_CANNED)

/// One fixed reply per turn, no tool calls — enough for a UI walk to send a
/// message and see the assistant answer it BEFORE the interview questions
/// follow (InterviewThread). DEBUG-only + env-gated like the bulk script.
#if DEBUG
@MainActor
final class CannedAssistantScript: AssistantTransport {
    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk {
        .ok(HarnessReply(content: "I’ve got your day in front of me — tell me what you want to happen and I’ll do it."))
    }
}
#endif

// MARK: - HEAVY soak seed (UITEST_SEED_HEAVY) — TEMPORARY perf scaffolding
//
// A large-account fixture (~800 tasks / 4000 cal_blocks / 1500 sessions /
// 300 captures / 40 lists × 30 items) for cold-start measurement, written to a
// PERSISTENT sqlite file in Caches so the second and later launches are true
// cold starts against a heavy store (the light UITEST_SEED boot stays
// in-memory). Gated behind `#if DEBUG` AND the UITEST_SEED_HEAVY launch env
// var, so Release / TestFlight cannot reach it. Not part of any shipping path.
#if DEBUG
enum HeavyDemoSeed {
    static var enabled: Bool { ProcessInfo.processInfo.environment["UITEST_SEED_HEAVY"] == "1" }

    static let tasksN = 800
    static let blocksN = 4_000
    static let sessionsN = 1_500
    static let capturesN = 300
    static let collectionsN = 40
    static let itemsPerCollection = 30
    static let templatesN = 40
    static let busyDayBlocks = 60

    static func dbPath() -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("unstuck-heavy-soak.sqlite").path
    }

    private static func isoStamp(_ daysAgo: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private static func day(_ offset: Int) -> String { LocalDate.addDays(Clock.todayISO(), offset) }

    private static let areaNames = ["Work", "Personal", "Health", "Home", "Family", "Finance", "Learning", "Side project"]
    private static let tagNames = ["deep-work", "quick", "errand", "admin", "call", "review", "writing", "email",
                                   "planning", "chore", "reading", "research"]

    /// Seed only when the store is not already heavy — so relaunch #2+ pays no
    /// seeding cost and measures a real cold start.
    @discardableResult
    static func seedIfNeeded(_ db: AppDatabase) -> Bool {
        let have = (try? TaskRepository(db).all().count) ?? 0
        guard have < tasksN else { return false }
        try? db.replaceAll(TaskItem.self, with: tasks())
        try? db.replaceAll(CalBlock.self, with: blocks())
        try? db.replaceAll(UnstuckCore.Session.self, with: sessions())
        try? db.replaceAll(Capture.self, with: captures())
        try? db.replaceAll(ItemCollection.self, with: collections())
        try? db.replaceAll(LifeArea.self, with: lifeAreas())
        try? db.replaceAll(TagRow.self, with: tagRows())
        return true
    }

    static func tasks() -> [TaskItem] {
        (0..<tasksN).map { i in
            let created = isoStamp(Double(i % 400))
            let template = i < templatesN
            return TaskItem(
                id: "task-\(i)",
                name: "Heavy task \(i) — \(tagNames[i % tagNames.count]) work item",
                estimateMin: [10, 15, 25, 30, 45, 60, 90][i % 7],
                totalFocused: (i * 137) % 5_000,
                done: !template && i % 5 == 0,
                tags: [tagNames[i % tagNames.count], tagNames[(i + 3) % tagNames.count]],
                lifeArea: areaNames[i % areaNames.count],
                firstPhysicalAction: i % 4 == 0 ? "Open the doc and write one sentence" : nil,
                moveCount: i % 7,
                completedAt: (!template && i % 5 == 0) ? isoStamp(Double(i % 30)) : nil,
                later: i % 11 == 0,
                recurrence: template ? .weekly(daysOfWeek: [1, 3, 5], until: nil) : nil,
                createdAt: created, updatedAt: created)
        }
    }

    static func blocks() -> [CalBlock] {
        var out: [CalBlock] = []
        out.reserveCapacity(blocksN)
        let spread = blocksN - busyDayBlocks
        for i in 0..<spread {
            let offset = (i % 401) - 200
            let slot = i / 401
            let startMin = 6 * 60 + slot * 55
            let taskIdx = (i * 7) % tasksN
            out.append(CalBlock(
                id: "blk-\(i)", taskId: "task-\(taskIdx)", taskName: "Heavy task \(taskIdx)",
                startTime: String(format: "%02d:%02d", startMin / 60, startMin % 60),
                durationMinutes: [45, 60, 90][i % 3], date: day(offset), kind: .task,
                done: offset < 0 && i % 3 == 0, skipped: offset < 0 && i % 17 == 0,
                completedAt: (offset < 0 && i % 3 == 0) ? isoStamp(Double(-offset)) : nil))
        }
        for j in 0..<busyDayBlocks {
            let startMin = 7 * 60 + j * 15
            let taskIdx = (j * 13) % tasksN
            out.append(CalBlock(
                id: "blk-busy-\(j)", taskId: "task-\(taskIdx)", taskName: "Busy block \(j)",
                startTime: String(format: "%02d:%02d", (startMin / 60) % 24, startMin % 60),
                durationMinutes: 120, date: day(0), kind: .task))
        }
        return out
    }

    static func sessions() -> [UnstuckCore.Session] {
        (0..<sessionsN).map { i in
            UnstuckCore.Session(id: "sess-\(i)", taskId: "task-\(i % tasksN)",
                                taskName: "Heavy task \(i % tasksN)", tags: [tagNames[i % tagNames.count]],
                                estimateMin: [15, 25, 45][i % 3], actualSec: 600 + (i * 37) % 4_200,
                                completedAt: isoStamp(Double(i % 400) + Double(i % 24) / 24.0))
        }
    }

    static func captures() -> [Capture] {
        (0..<capturesN).map { i in
            Capture(id: "cap-\(i)", taskId: i % 3 == 0 ? "task-\(i % tasksN)" : nil,
                    sessionId: nil, tag: [CaptureTag.idea, .distraction, .followUp][i % 3],
                    body: "Captured thought number \(i) with a sentence of context after it.",
                    at: isoStamp(Double(i % 120) / 4.0))
        }
    }

    static func collections() -> [ItemCollection] {
        (0..<collectionsN).map { c in
            let items = (0..<itemsPerCollection).map { j in
                CollectionItem(id: "c\(c)-i\(j)", body: "List \(c) item \(j) — something to pick up",
                               at: isoStamp(Double(j)))
            }
            return ItemCollection(id: "col-\(c)", name: "Heavy list \(c)",
                                  color: ["green", "indigo", "coral"][c % 3],
                                  subtitle: nil, items: items, sortOrder: c, archived: false)
        }
    }

    static func lifeAreas() -> [LifeArea] {
        areaNames.enumerated().map { LifeArea(id: "area-\($0.element)", name: $0.element,
                                              color: ["indigo", "coral", "green"][$0.offset % 3], sortOrder: $0.offset) }
    }

    static func tagRows() -> [TagRow] {
        tagNames.enumerated().map { TagRow(id: "tag-\($0.element)", name: $0.element, color: nil, sortOrder: $0.offset) }
    }
}
#endif

// MARK: - Share screen · People card demo transport (UITEST_SHARE_PEOPLE)

// A scripted `ShareScreenTransport` so the Share screen's People card can be
// driven and screenshotted on the network-free demo boot, where the live
// transport has no coordinator and the section is always empty. Gated behind
// `#if DEBUG` AND the launch env var, like every other UITEST_* hook:
//
//   UITEST_SHARE_PEOPLE="<count>,<shared>[,<handed>]"
//
// `count` active connections (fixed names, some with a relationship label,
// one 24-character name + a long label for the accessibility-size check);
// the LAST `shared` of them, in roster order, already hold the item (so the
// shared-first ordering is visible: they float above the rest); `handed` = 1
// makes the last shared person the hand-over holder (level `assign`).
// Writes mutate the in-memory grants so a tap re-renders the row the way the
// live screen does. UITEST_SHARE_SLOW=1 adds a 1.5s delay to every write so
// the busy row can be shot mid-flight.
#if DEBUG
@MainActor
final class DemoShareTransport: ShareScreenTransport {
    static func fromEnvironment() -> DemoShareTransport? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UITEST_SHARE_PEOPLE"] else { return nil }
        let parts = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let count = parts.first else { return nil }
        return DemoShareTransport(count: count, shared: parts.count > 1 ? parts[1] : 0,
                                  handed: parts.count > 2 ? parts[2] : 0, slow: env["UITEST_SHARE_SLOW"] == "1")
    }

    private static let names = [
        "Maya Chen", "Zubair Kazaure", "Zoë Müller", "Nadia Ali", "Tomás Herrera",
        "Priya Raghunathan-Okafor", "Sam O'Brien", "Léa Dubois", "Kenji Watanabe", "Amara Okafor",
        "Mateo Rossi", "Ivy Park", "Omar Haddad", "Hana Sato", "Luca Bianchi",
        "Noor Rahman", "Elias Berg", "Sofia Lindqvist", "Yusuf Demir", "Grace Mwangi",
    ]
    private static let labels: [String?] = [
        "Coach", nil, "Accountability partner", nil, "Brother",
        "Accountability partner", nil, "Study buddy", nil, "Sister",
        nil, nil, "Manager", nil, nil,
        nil, "Coach", nil, nil, nil,
    ]

    private let circle: [CircleMember]
    private var shares: [ShareForTask]
    private var pending: [TaskSharePendingInvite]
    private var members: [CollectionMemberInfo]
    private let slow: Bool

    init(count: Int, shared: Int, handed: Int, slow: Bool) {
        self.slow = slow
        let n = max(0, count)
        let roster: [CircleMember] = (0..<n).map { i in
            let base = Self.names[i % Self.names.count]
            let name = i < Self.names.count ? base : "\(base) \(i / Self.names.count + 1)"
            return CircleMember(id: "c\(i)", relationshipLabel: Self.labels[i % Self.labels.count], level: "view",
                                status: "active", inviteCode: nil, memberUserId: "u\(i)", memberName: name,
                                createdAt: "2026-09-17T09:00:00Z")
        }
        let sharedCount = min(max(0, shared), n)
        let sharedIndices = Array((n - sharedCount)..<n)
        circle = roster
        shares = sharedIndices.enumerated().map { k, i in
            let level: ShareLevel = (handed > 0 && k == sharedIndices.count - 1) ? .assign : (k % 2 == 0 ? .partner : .view)
            return ShareForTask(shareId: "s\(i)", recipientUserId: "u\(i)", recipientName: roster[i].memberName ?? "", level: level)
        }
        members = sharedIndices.enumerated().map { k, i in
            CollectionMemberInfo(userId: "u\(i)", email: "\(i)@example.com", role: k % 2 == 0 ? "editor" : "viewer", pending: false)
        }
        pending = n > 0 ? [TaskSharePendingInvite(id: "i1", email: "new@example.com", level: .partner)] : []
    }

    private func delay() async {
        if slow { try? await Task.sleep(nanoseconds: 1_500_000_000) }
    }

    func listCircle() async -> [CircleMember] { circle }
    func taskShares(taskId: String) async -> [ShareForTask] { shares }
    func taskPendingInvites(taskId: String) async -> [TaskSharePendingInvite] { pending }
    func shareTask(taskId: String, userId: String, level: ShareLevel) async throws {
        await delay()
        shares.removeAll { $0.recipientUserId == userId }
        let name = circle.first { $0.memberUserId == userId }?.memberName ?? userId
        shares.append(ShareForTask(shareId: "s-\(userId)", recipientUserId: userId, recipientName: name, level: level))
    }
    func unshareTask(shareId: String) async -> Bool {
        await delay()
        shares.removeAll { $0.shareId == shareId }
        return true
    }
    func shareTaskByEmail(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome {
        await delay()
        pending.append(TaskSharePendingInvite(id: "i-\(email)", email: email, level: level))
        return .invited
    }
    func cancelTaskInvite(taskId: String, inviteId: String) async -> Bool {
        pending.removeAll { $0.id == inviteId }
        return true
    }
    func taskLink(taskId: String, level: ShareLevel) async -> ShareLinkOutcome {
        .ok(url: "https://unstucknow.io/circle/join?code=demo")
    }
    func notifyTaskShare(taskId: String, recipientId: String) async {}
    func collectionMembers(collectionId: String) async -> [CollectionMemberInfo] { members }
    func shareCollection(collectionId: String, email: String?, userId: String?, role: String) async -> ShareOutcome {
        await delay()
        if let userId {
            members.removeAll { $0.userId == userId }
            members.append(CollectionMemberInfo(userId: userId, email: email ?? "", role: role, pending: false))
            return .ok
        }
        return .accepted
    }
    func unshareCollection(collectionId: String, userId: String) async -> Bool {
        await delay()
        members.removeAll { $0.userId == userId }
        return true
    }
    func cancelCollectionInvite(collectionId: String, email: String) async -> Bool { true }
    func collectionLink(collectionId: String, role: String) async -> ShareLinkOutcome {
        .ok(url: "https://unstucknow.io/circle/join?code=demo")
    }
    func block(userId: String) async -> Bool {
        await delay()
        members.removeAll { $0.userId == userId }
        shares.removeAll { $0.recipientUserId == userId }
        return true
    }
}
#endif
