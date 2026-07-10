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
