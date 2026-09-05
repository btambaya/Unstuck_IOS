// Codable round-trips for the sharing domain models — the camelCase public
// shapes the CircleClient decodes RPC rows into. Guards against an accidental
// field rename drifting from the web contract (use-circle / use-task-shares).

import XCTest
@testable import UnstuckCore

final class SharingModelsTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testShareLevelRawValues() {
        XCTAssertEqual(ShareLevel.view.rawValue, "view")
        XCTAssertEqual(ShareLevel.partner.rawValue, "partner")
        XCTAssertEqual(ShareLevel.assign.rawValue, "assign")
        XCTAssertEqual(ShareLevel.allCases.count, 3)
        XCTAssertEqual(ShareLevel(rawValue: "assign"), .assign)
        XCTAssertNil(ShareLevel(rawValue: "co_owner"))   // legacy tier is gone
    }

    func testShareLevelEncodesAsBareString() throws {
        let data = try JSONEncoder().encode(ShareLevel.partner)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"partner\"")
    }

    func testCircleMemberRoundTrip() throws {
        let active = CircleMember(id: "c1", relationshipLabel: "Coach", level: "view",
                                  status: "active", inviteCode: nil, memberUserId: "u9",
                                  memberName: "Sam", createdAt: "2026-06-11T09:00:00.000Z")
        XCTAssertEqual(try roundTrip(active), active)

        // Pending invite: no member yet, carries the code.
        let pending = CircleMember(id: "c2", relationshipLabel: nil, level: "comment",
                                   status: "invited", inviteCode: "abc123", memberUserId: nil,
                                   memberName: nil, createdAt: "2026-06-11T10:00:00.000Z")
        XCTAssertEqual(try roundTrip(pending), pending)
    }

    func testShareForTaskRoundTrip() throws {
        let s = ShareForTask(shareId: "s1", recipientUserId: "u2", recipientName: "Alex", level: .partner)
        let back = try roundTrip(s)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.id, "s1")   // Identifiable id == shareId
    }

    func testSharedWithMeRoundTrip() throws {
        let s = SharedWithMe(shareId: "s3", taskId: "t7", ownerName: "Pat",
                             level: .assign, title: "Ship the deck", done: true)
        let back = try roundTrip(s)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.id, "s3")
    }

    func testShareBadgeRoundTrip() throws {
        let b = ShareBadge(taskId: "t1", level: .view, recipientName: "Jo")
        XCTAssertEqual(try roundTrip(b), b)
    }

    // T1/T3: the read-only shared-task detail model + its focus-action label.
    func testSharedTaskDetailIdentityAndEquality() {
        let d = SharedTaskDetail(taskId: "t7", ownerName: "Pat", level: .partner,
                                 name: "Ship the deck", done: false, estimateMin: 45,
                                 totalFocused: 600, lifeArea: "Work", priority: .high,
                                 tags: ["deck"], objectives: [Objective(text: "Outline", done: true)],
                                 dueAt: nil, createdAt: nil)
        XCTAssertEqual(d.id, "t7")            // Identifiable id == taskId
        XCTAssertEqual(d, d)
        XCTAssertEqual(d.objectives.first?.text, "Outline")
    }

    // MARK: migration 052 — the owner's schedule on the recipient's models

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testSharedWithMeDecodesTheScheduleFromSnakeCase() throws {
        // The exact row shape tasks_shared_with_me() projects since 052.
        let s = try decode(SharedWithMe.self, """
        {"shareId":"s1","taskId":"t1","ownerName":"Anna Lee","level":"view","title":"Deck","done":false,
         "completed_at":null,"estimate_min":45,"life_area":"Work","next_block_id":"b1",
         "next_date":"2026-09-06","next_start_time":"04:30","next_duration_minutes":45,"next_done":false}
        """)
        XCTAssertEqual(s.estimateMin, 45)
        XCTAssertEqual(s.lifeArea, "Work")
        XCTAssertEqual(s.nextBlockId, "b1")
        XCTAssertEqual(s.nextDate, "2026-09-06")
        XCTAssertEqual(s.nextStartTime, "04:30")
        XCTAssertEqual(s.nextDurationMinutes, 45)
        XCTAssertEqual(s.nextDone, false)
    }

    func testSharedWithMeDecodesTheScheduleFromCamelCase() throws {
        let s = try decode(SharedWithMe.self, """
        {"shareId":"s1","taskId":"t1","ownerName":"Anna","level":"partner","title":"Deck","done":false,
         "estimateMin":30,"lifeArea":"Home","nextBlockId":"b2","nextDate":"2026-09-07",
         "nextStartTime":"10:00","nextDurationMinutes":30,"nextDone":true}
        """)
        XCTAssertEqual(s.estimateMin, 30)
        XCTAssertEqual(s.lifeArea, "Home")
        XCTAssertEqual(s.nextBlockId, "b2")
        XCTAssertEqual(s.nextDate, "2026-09-07")
        XCTAssertEqual(s.nextStartTime, "10:00")
        XCTAssertEqual(s.nextDurationMinutes, 30)
        XCTAssertEqual(s.nextDone, true)
    }

    func testSharedWithMeToleratesAPre052ServerAndNulls() throws {
        // Pre-052: none of the schedule keys exist → all nil, still decodes.
        let legacy = try decode(SharedWithMe.self, """
        {"shareId":"s1","taskId":"t1","ownerName":"Anna","level":"view","title":"Deck","done":false}
        """)
        XCTAssertNil(legacy.estimateMin)
        XCTAssertNil(legacy.lifeArea)
        XCTAssertNil(legacy.nextBlockId)
        XCTAssertNil(legacy.nextDate)
        XCTAssertNil(legacy.nextStartTime)
        XCTAssertNil(legacy.nextDurationMinutes)
        XCTAssertNil(legacy.nextDone)
        // 052 with nothing scheduled: the next_* set is null.
        let unscheduled = try decode(SharedWithMe.self, """
        {"shareId":"s1","taskId":"t1","ownerName":"Anna","level":"view","title":"Deck","done":false,
         "estimate_min":25,"life_area":null,"next_block_id":null,"next_date":null,
         "next_start_time":null,"next_duration_minutes":null,"next_done":null}
        """)
        XCTAssertEqual(unscheduled.estimateMin, 25)
        XCTAssertNil(unscheduled.lifeArea)
        XCTAssertNil(unscheduled.nextDate)
        XCTAssertNil(unscheduled.nextDone)
    }

    func testSharedWithMeRoundTripsTheSchedule() throws {
        let s = SharedWithMe(shareId: "s3", taskId: "t7", ownerName: "Pat", level: .assign,
                             title: "Ship the deck", done: false, completedAt: nil,
                             estimateMin: 45, lifeArea: "Work", nextBlockId: "b1",
                             nextDate: "2026-09-06", nextStartTime: "04:30",
                             nextDurationMinutes: 45, nextDone: false)
        XCTAssertEqual(try roundTrip(s), s)
    }

    func testSharedBlockDecodesSnakeCaseRowAndCamelCase() throws {
        // The exact row shape shared_task_blocks() returns.
        let b = try decode(SharedBlock.self, """
        {"block_id":"b1","task_id":"t1","share_id":"s1","level":"partner","owner_name":"Anna Lee",
         "title":"Deck","date":"2026-09-06","start_time":"04:30","duration_minutes":45,
         "done":null,"skipped":null,"kind":"task"}
        """)
        XCTAssertEqual(b.id, "b1")
        XCTAssertEqual(b.taskId, "t1")
        XCTAssertEqual(b.shareId, "s1")
        XCTAssertEqual(b.level, .partner)
        XCTAssertEqual(b.ownerName, "Anna Lee")
        XCTAssertEqual(b.title, "Deck")
        XCTAssertEqual(b.date, "2026-09-06")
        XCTAssertEqual(b.startTime, "04:30")
        XCTAssertEqual(b.durationMinutes, 45)
        XCTAssertFalse(b.done)
        XCTAssertFalse(b.skipped)
        XCTAssertEqual(b.kind, "task")

        let camel = try decode(SharedBlock.self, """
        {"blockId":"b2","taskId":"t2","shareId":"s2","level":"view","ownerName":"Bo","title":"Call",
         "date":"2026-09-07","startTime":"10:00","durationMinutes":25,"done":true,"skipped":false,"kind":"task"}
        """)
        XCTAssertEqual(camel.blockId, "b2")
        XCTAssertTrue(camel.done)
        // Unknown level → least privilege; missing kind → task.
        let odd = try decode(SharedBlock.self, """
        {"block_id":"b3","task_id":"t3","share_id":"s3","level":"future","owner_name":"Bo",
         "date":"2026-09-07","start_time":"10:00","duration_minutes":25}
        """)
        XCTAssertEqual(odd.level, .view)
        XCTAssertEqual(odd.kind, "task")
        XCTAssertEqual(odd.title, "")
    }

    func testSharedBlockRoundTrip() throws {
        let b = SharedBlock(blockId: "b1", taskId: "t1", shareId: "s1", level: .assign, ownerName: "Anna",
                            title: "Deck", date: "2026-09-06", startTime: "04:30", durationMinutes: 45,
                            done: false, skipped: true, kind: "task")
        XCTAssertEqual(try roundTrip(b), b)
    }

    func testSharedTaskDetailCarriesTheNextBlockWithNilDefaults() {
        let bare = SharedTaskDetail(taskId: "t7", ownerName: "Pat", level: .view, name: "Deck", done: false,
                                    estimateMin: 45, totalFocused: 0, lifeArea: nil, priority: nil,
                                    tags: [], objectives: [], dueAt: nil, createdAt: nil)
        XCTAssertNil(bare.nextBlockId)
        XCTAssertNil(bare.nextDate)
        XCTAssertNil(bare.nextStartTime)
        XCTAssertNil(bare.nextDurationMinutes)
        XCTAssertNil(bare.nextDone)
        let planned = SharedTaskDetail(taskId: "t7", ownerName: "Pat", level: .view, name: "Deck", done: false,
                                       estimateMin: 45, totalFocused: 0, lifeArea: nil, priority: nil,
                                       tags: [], objectives: [], dueAt: nil, createdAt: nil,
                                       nextBlockId: "b1", nextDate: "2026-09-06", nextStartTime: "04:30",
                                       nextDurationMinutes: 45, nextDone: false)
        XCTAssertEqual(planned.nextDate, "2026-09-06")
        XCTAssertNotEqual(planned, bare)
    }

    // The focus action is offered only for the focus-capable levels — the same
    // partner+assign rule log_shared_focus enforces server-side.
    func testSharedFocusActionLabelMatchesGate() {
        XCTAssertEqual(sharedFocusActionLabel(.partner), "Focus with them")
        XCTAssertEqual(sharedFocusActionLabel(.assign), "Focus")
        XCTAssertTrue(levelCanComplete(.partner))
        XCTAssertTrue(levelCanComplete(.assign))
        XCTAssertFalse(levelCanComplete(.view))   // view = read-only, no focus/complete
    }
}
