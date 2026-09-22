// CircleClient wire-shape tests — the load-bearing snake_case ↔ camelCase
// boundary between the SECURITY DEFINER RPCs (migrations 036/037/044) and the
// domain models. No network: we decode representative RPC-row JSON into the
// internal row structs, map to models, and assert the field mapping matches the
// web hooks (use-circle.ts / use-task-shares.ts). Also asserts the RPC param
// structs + edge-fn bodies serialize to the exact keys the backend expects.

import XCTest
import UnstuckCore
@testable import UnstuckSync

final class CircleClientTests: XCTestCase {

    private let dec = JSONDecoder()
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try dec.decode(T.self, from: Data(json.utf8))
    }
    private func encodedObject(_ value: Encodable) throws -> [String: AnyCodableValue] {
        let data = try JSONEncoder().encode(value)
        return try dec.decode([String: AnyCodableValue].self, from: data)
    }

    // MARK: RPC row → model mapping

    func testCircleMemberRowMapsActiveMember() throws {
        let json = """
        {"id":"c1","relationship_label":"Coach","level":"view","status":"active",
         "invite_code":null,"member_user_id":"u9","member_name":"Sam",
         "created_at":"2026-06-11T09:00:00.000Z"}
        """
        let m = try decode(CircleMemberRow.self, json).model()
        XCTAssertEqual(m.id, "c1")
        XCTAssertEqual(m.relationshipLabel, "Coach")
        XCTAssertEqual(m.level, "view")
        XCTAssertEqual(m.status, "active")
        XCTAssertNil(m.inviteCode)
        XCTAssertEqual(m.memberUserId, "u9")
        XCTAssertEqual(m.memberName, "Sam")
        XCTAssertEqual(m.createdAt, "2026-06-11T09:00:00.000Z")
    }

    func testCircleMemberRowMapsPendingInvite() throws {
        let json = """
        {"id":"c2","relationship_label":null,"level":"comment","status":"invited",
         "invite_code":"abc123","member_user_id":null,"member_name":null,
         "created_at":"2026-06-11T10:00:00.000Z"}
        """
        let m = try decode(CircleMemberRow.self, json).model()
        XCTAssertEqual(m.status, "invited")
        XCTAssertEqual(m.inviteCode, "abc123")
        XCTAssertNil(m.memberUserId)
        XCTAssertNil(m.memberName)
    }

    func testShareForTaskRowMapping() throws {
        let json = """
        {"share_id":"s1","recipient_user_id":"u2","recipient_name":"Alex","level":"partner"}
        """
        let s = try decode(ShareForTaskRow.self, json).model()
        XCTAssertEqual(s.shareId, "s1")
        XCTAssertEqual(s.recipientUserId, "u2")
        XCTAssertEqual(s.recipientName, "Alex")
        XCTAssertEqual(s.level, .partner)
    }

    func testSharedWithMeRowMapsDoneAndLevels() throws {
        // done true.
        let doneJson = """
        {"share_id":"s3","task_id":"t7","owner_name":"Pat","level":"assign",
         "title":"Ship the deck","done":true}
        """
        let done = try decode(SharedWithMeRow.self, doneJson).model()
        XCTAssertEqual(done.taskId, "t7")
        XCTAssertEqual(done.ownerName, "Pat")
        XCTAssertEqual(done.level, .assign)
        XCTAssertEqual(done.title, "Ship the deck")
        XCTAssertTrue(done.done)

        // done null (never surfaces nil — coalesced to false).
        let nullJson = """
        {"share_id":"s4","task_id":"t8","owner_name":"Kai","level":"view",
         "title":"Read spec","done":null}
        """
        let nullDone = try decode(SharedWithMeRow.self, nullJson).model()
        XCTAssertFalse(nullDone.done)
        XCTAssertEqual(nullDone.level, .view)

        // Pre-049 projection omits completed_at entirely — must still decode.
        XCTAssertNil(done.completedAt)
        XCTAssertNil(nullDone.completedAt)
    }

    /// Migration 049 projects the completion stamp so a completed share can
    /// move to Completed like any other task (SharedTaskVisibility).
    func testSharedWithMeRowCarriesCompletedAt() throws {
        let json = """
        {"share_id":"s5","task_id":"t9","owner_name":"Pat","level":"partner",
         "title":"Ship the deck","done":true,"completed_at":"2026-08-02T09:30:00+00:00"}
        """
        let s = try decode(SharedWithMeRow.self, json).model()
        XCTAssertEqual(s.completedAt, "2026-08-02T09:30:00+00:00")

        // Nullable column: an un-completed row projects null.
        let nullJson = """
        {"share_id":"s6","task_id":"t10","owner_name":"Pat","level":"partner",
         "title":"Draft it","done":false,"completed_at":null}
        """
        XCTAssertNil(try decode(SharedWithMeRow.self, nullJson).model().completedAt)
    }

    func testShareBadgeRowMapping() throws {
        let json = """
        {"task_id":"t1","level":"view","recipient_name":"Jo"}
        """
        let b = try decode(ShareBadgeRow.self, json).model()
        XCTAssertEqual(b.taskId, "t1")
        XCTAssertEqual(b.level, .view)
        XCTAssertEqual(b.recipientName, "Jo")
    }

    func testSharedTaskDetailRowMapping() throws {
        // Full row (migration 045): snake_case columns; objectives jsonb keeps
        // camelCase keys; tags is a text[] → string array; timestamptz → ISO.
        let json = """
        {"task_id":"t7","owner_name":"Pat","level":"partner","name":"Ship the deck",
         "done":false,"estimate_min":45,"total_focused":600,"life_area":"Work",
         "priority":"high","tags":["deck","q3"],
         "objectives":[{"text":"Outline","done":true},{"text":"Draft","done":false}],
         "due_at":"2026-06-20T17:00:00.000Z","created_at":"2026-06-11T09:00:00.000Z"}
        """
        let d = try decode(SharedTaskDetailRow.self, json).model()
        XCTAssertEqual(d.taskId, "t7")
        XCTAssertEqual(d.ownerName, "Pat")
        XCTAssertEqual(d.level, .partner)
        XCTAssertEqual(d.name, "Ship the deck")
        XCTAssertFalse(d.done)
        XCTAssertEqual(d.estimateMin, 45)
        XCTAssertEqual(d.totalFocused, 600)
        XCTAssertEqual(d.lifeArea, "Work")
        XCTAssertEqual(d.priority, .high)
        XCTAssertEqual(d.tags, ["deck", "q3"])
        XCTAssertEqual(d.objectives.count, 2)
        XCTAssertEqual(d.objectives.first?.text, "Outline")
        XCTAssertEqual(d.objectives.first?.done, true)
        XCTAssertEqual(d.dueAt, "2026-06-20T17:00:00.000Z")
        XCTAssertEqual(d.createdAt, "2026-06-11T09:00:00.000Z")
    }

    func testSharedWithMeRowCarriesTheScheduleAndToleratesItsAbsence() throws {
        // 052 row: estimate/area + the owner's next block.
        let json = """
        {"share_id":"s7","task_id":"t11","owner_name":"Anna","level":"view","title":"Deck","done":false,
         "completed_at":null,"estimate_min":45,"life_area":"Work","next_block_id":"b1",
         "next_date":"2026-09-06","next_start_time":"04:30","next_duration_minutes":45,"next_done":false}
        """
        let s = try decode(SharedWithMeRow.self, json).model()
        XCTAssertEqual(s.estimateMin, 45)
        XCTAssertEqual(s.lifeArea, "Work")
        XCTAssertEqual(s.nextBlockId, "b1")
        XCTAssertEqual(s.nextDate, "2026-09-06")
        XCTAssertEqual(s.nextStartTime, "04:30")
        XCTAssertEqual(s.nextDurationMinutes, 45)
        XCTAssertEqual(s.nextDone, false)

        // Pre-052 projection: the columns don't exist at all → nil, no throw.
        let legacy = """
        {"share_id":"s8","task_id":"t12","owner_name":"Anna","level":"view","title":"Deck","done":false}
        """
        let l = try decode(SharedWithMeRow.self, legacy).model()
        XCTAssertNil(l.estimateMin)
        XCTAssertNil(l.nextDate)
        XCTAssertNil(l.nextDone)
    }

    func testSharedBlockRowMapping() throws {
        let json = """
        {"block_id":"b1","task_id":"t1","share_id":"s1","level":"partner","owner_name":"Anna Lee",
         "title":"Deck","date":"2026-09-06","start_time":"04:30","duration_minutes":45,
         "done":false,"skipped":null,"kind":"task"}
        """
        let b = try decode(SharedBlockRow.self, json).model()
        XCTAssertEqual(b.blockId, "b1")
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

        // Sparse row → calm defaults.
        let sparse = """
        {"block_id":"b2","task_id":"t2","share_id":"s2","level":"weird","owner_name":null,"title":null,
         "date":"2026-09-07","start_time":"10:00","duration_minutes":null,"done":null,"skipped":true,"kind":null}
        """
        let sb = try decode(SharedBlockRow.self, sparse).model()
        XCTAssertEqual(sb.level, .view)
        XCTAssertEqual(sb.ownerName, "Someone")
        XCTAssertEqual(sb.title, "Untitled task")
        XCTAssertEqual(sb.durationMinutes, 25)
        XCTAssertTrue(sb.skipped)
        XCTAssertEqual(sb.kind, "task")
    }

    func testSharedBlocksParamKeys() throws {
        let obj = try encodedObject(SharedBlocksParams(p_from: "2026-09-01", p_to: "2026-09-30"))
        XCTAssertEqual(Set(obj.keys), ["p_from", "p_to"])
        XCTAssertEqual(obj["p_from"]?.stringValue, "2026-09-01")
        XCTAssertEqual(obj["p_to"]?.stringValue, "2026-09-30")
    }

    func testSharedTaskDetailRowCarriesTheNextBlock() throws {
        let json = """
        {"task_id":"t8","owner_name":"Anna","level":"view","name":"Deck","done":false,
         "estimate_min":45,"total_focused":0,"life_area":"Work","priority":null,
         "tags":[],"objectives":[],"due_at":null,"created_at":null,
         "next_block_id":"b1","next_date":"2026-09-06","next_start_time":"04:30",
         "next_duration_minutes":45,"next_done":false}
        """
        let d = try decode(SharedTaskDetailRow.self, json).model()
        XCTAssertEqual(d.nextBlockId, "b1")
        XCTAssertEqual(d.nextDate, "2026-09-06")
        XCTAssertEqual(d.nextStartTime, "04:30")
        XCTAssertEqual(d.nextDurationMinutes, 45)
        XCTAssertEqual(d.nextDone, false)
    }

    func testSharedTaskDetailRowTolerantDefaults() throws {
        // Sparse row (nulls / missing optionals) must decode to calm defaults,
        // never crash — the recipient still gets a usable detail.
        let json = """
        {"task_id":"t8","owner_name":null,"level":"future_tier","name":null,"done":null,
         "estimate_min":null,"total_focused":null,"life_area":null,"priority":null,
         "tags":null,"objectives":null,"due_at":null,"created_at":null}
        """
        let d = try decode(SharedTaskDetailRow.self, json).model()
        XCTAssertEqual(d.ownerName, "Someone")
        XCTAssertEqual(d.level, .view)              // unknown level → least-privilege
        XCTAssertEqual(d.name, "Untitled task")
        XCTAssertFalse(d.done)
        XCTAssertEqual(d.estimateMin, 25)
        XCTAssertEqual(d.totalFocused, 0)
        XCTAssertNil(d.lifeArea)
        XCTAssertNil(d.priority)
        XCTAssertTrue(d.tags.isEmpty)
        XCTAssertTrue(d.objectives.isEmpty)
        XCTAssertNil(d.dueAt)
        // Pre-052 row: no next_* columns at all → nil.
        XCTAssertNil(d.nextBlockId)
        XCTAssertNil(d.nextDate)
        XCTAssertNil(d.nextDone)
    }

    func testLogSharedFocusParamKeysAndValues() throws {
        // 3-arg RPC (migration 046): p_session_id makes the accrue idempotent.
        let obj = try encodedObject(LogSharedFocusParams(p_task_id: "t7", p_actual_sec: 1500,
                                                         p_session_id: "sess-1"))
        XCTAssertEqual(Set(obj.keys), ["p_task_id", "p_actual_sec", "p_session_id"])
        XCTAssertEqual(obj["p_task_id"]?.stringValue, "t7")
        XCTAssertEqual(obj["p_session_id"]?.stringValue, "sess-1")
        if case let .number(n) = obj["p_actual_sec"] { XCTAssertEqual(n, 1500) }
        else { XCTFail("p_actual_sec should be a number") }
    }

    func testUnknownLevelFallsBackToView() throws {
        // A forward-compat level this build doesn't know must not crash the
        // decode — it degrades to `.view` (least-privilege).
        let json = """
        {"share_id":"s9","recipient_user_id":"u1","recipient_name":"X","level":"future_tier"}
        """
        XCTAssertEqual(try decode(ShareForTaskRow.self, json).model().level, .view)
    }

    // MARK: RPC result decoding

    func testCircleRedeemResultDecoding() throws {
        let ok = try decode(CircleRedeemResult.self, #"{"ok":true,"owner_name":"Dana"}"#)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.ownerName, "Dana")
        XCTAssertNil(ok.error)

        let bad = try decode(CircleRedeemResult.self, #"{"ok":false,"error":"invalid_or_expired"}"#)
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "invalid_or_expired")
    }

    func testCircleInviteResultDecoding() throws {
        let added = try decode(CircleInviteResult.self, #"{"ok":true,"emailed":false,"added":true}"#)
        XCTAssertEqual(added.added, true)
        XCTAssertEqual(added.emailed, false)

        let emailed = try decode(CircleInviteResult.self,
            #"{"ok":true,"emailed":true,"link":"https://unstucknow.io/circle/join?code=x"}"#)
        XCTAssertEqual(emailed.emailed, true)
        XCTAssertEqual(emailed.link, "https://unstucknow.io/circle/join?code=x")

        let full = try decode(CircleInviteResult.self, #"{"error":"circle_full"}"#)
        XCTAssertEqual(full.error, "circle_full")
    }

    // MARK: RPC params + edge-fn bodies serialize to the backend's exact keys

    func testRpcParamKeys() throws {
        XCTAssertEqual(Set(try encodedObject(RedeemParams(p_code: "x")).keys), ["p_code"])
        XCTAssertEqual(Set(try encodedObject(IdParams(p_id: "x")).keys), ["p_id"])
        XCTAssertEqual(Set(try encodedObject(TaskIdParams(p_task_id: "x")).keys), ["p_task_id"])
        XCTAssertEqual(Set(try encodedObject(TaskShareParams(p_task_id: "t", p_user: "u", p_level: "view")).keys),
                       ["p_task_id", "p_user", "p_level"])
        XCTAssertEqual(Set(try encodedObject(SetDoneParams(p_task_id: "t", p_done: true)).keys),
                       ["p_task_id", "p_done"])
    }

    /// Audit 2026-09-22, C10 — the server-backed block + recipient-side
    /// removal RPCs (migration 075) take exactly these keys.
    func testBlockAndLeaveParamKeys() throws {
        let user = try encodedObject(UserParams(p_user: "u9"))
        XCTAssertEqual(Set(user.keys), ["p_user"])
        XCTAssertEqual(user["p_user"]?.stringValue, "u9")
        let share = try encodedObject(ShareIdParams(p_share_id: "s1"))
        XCTAssertEqual(Set(share.keys), ["p_share_id"])
        XCTAssertEqual(share["p_share_id"]?.stringValue, "s1")
    }

    /// block_user / block_task_sharer / unblock_user / task_share_leave return
    /// a scalar boolean — TRUE only when the server says so.
    func testBlockRPCsReadTheServersBoolean() {
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(Data("true".utf8)))
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(Data("[true]".utf8)))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(Data("false".utf8)))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(Data("null".utf8)))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(Data(#"{"code":"PGRST202"}"#.utf8)),
                       "a server without 075 is never a success")
    }

    func testBlockedUserRowMapping() throws {
        let b = try decode(BlockedUserRow.self,
            #"{"user_id":"u9","name":"Sam Lee","created_at":"2026-09-22T10:00:00+00:00"}"#).model()
        XCTAssertEqual(b, BlockedUser(userId: "u9", name: "Sam Lee", createdAt: "2026-09-22T10:00:00+00:00"))
        XCTAssertEqual(b.id, "u9")
        // A null / blank name never fails the row, and never shows blank.
        XCTAssertEqual(try decode(BlockedUserRow.self, #"{"user_id":"u8","name":null,"created_at":null}"#).model().name, "Someone")
        XCTAssertEqual(try decode(BlockedUserRow.self, #"{"user_id":"u7","name":"  "}"#).model().name, "Someone")
        let rows = try decode([BlockedUserRow].self, #"[{"user_id":"a","name":"A"},{"user_id":"b","name":"B"}]"#)
        XCTAssertEqual(rows.map { $0.model().userId }, ["a", "b"], "server order (newest first) is kept")
    }

    func testTaskShareParamValues() throws {
        let obj = try encodedObject(TaskShareParams(p_task_id: "t1", p_user: "u1", p_level: ShareLevel.assign.rawValue))
        XCTAssertEqual(obj["p_task_id"]?.stringValue, "t1")
        XCTAssertEqual(obj["p_user"]?.stringValue, "u1")
        XCTAssertEqual(obj["p_level"]?.stringValue, "assign")
    }

    func testInviteBodyOmitsBlankEmail() throws {
        // With an email, the key is present; nil email → omitted (→ link-only),
        // matching the web's `email: … || undefined`.
        XCTAssertEqual(try encodedObject(InviteBody(email: "a@b.com"))["email"]?.stringValue, "a@b.com")
        XCTAssertNil(try encodedObject(InviteBody(email: nil))["email"])
    }

    func testShareNotifyBodyKeys() throws {
        let full = try encodedObject(ShareNotifyBody(kind: "task_share", taskId: "t1", recipientId: "u2"))
        XCTAssertEqual(full["kind"]?.stringValue, "task_share")
        XCTAssertEqual(full["taskId"]?.stringValue, "t1")
        XCTAssertEqual(full["recipientId"]?.stringValue, "u2")
        // task_done has no recipient → key omitted.
        XCTAssertNil(try encodedObject(ShareNotifyBody(kind: "task_done", taskId: "t1", recipientId: nil))["recipientId"])
    }

    func testShareBadgesByTaskGrouping() {
        let badges = [
            ShareBadge(taskId: "t1", level: .view, recipientName: "A"),
            ShareBadge(taskId: "t1", level: .partner, recipientName: "B"),
            ShareBadge(taskId: "t2", level: .assign, recipientName: "C"),
        ]
        let map = CircleClient.shareBadgesByTask(badges)
        XCTAssertEqual(map["t1"]?.count, 2)
        XCTAssertEqual(map["t2"]?.count, 1)
        XCTAssertEqual(map["t2"]?.first?.recipientName, "C")
    }
}

/// Minimal JSON value decoder for asserting encoded param/body key sets +
/// string values without a Supabase AnyJSON dependency in the test.
enum AnyCodableValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null
    case other

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .other }
    }
}
