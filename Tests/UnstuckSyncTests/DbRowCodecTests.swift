import XCTest
import UnstuckCore
@testable import UnstuckSync

final class DbRowCodecTests: XCTestCase {

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func richTask() -> TaskItem {
        TaskItem(id: "11111111-1111-4111-8111-111111111111", name: "Write spec", estimateMin: 30,
                 totalFocused: 120, done: false, priority: .high, tags: ["deep-work"],
                 objectives: [Objective(text: "outline", done: true, minutes: 5)],
                 comments: [Comment(text: "c", at: "2026-05-21T10:00:00.000Z")],
                 intentWhen: "after lunch", intentThen: "open editor", lifeArea: "Work",
                 firstPhysicalAction: "open doc", moveCount: 2, completedAt: nil, later: true,
                 recurrence: .weekly(daysOfWeek: [1, 3], until: "2026-09-01"),
                 createdAt: "2026-05-21T10:00:00.000Z", updatedAt: "2026-05-21T10:00:00.000Z")
    }

    func testTaskTopLevelSnakeCaseButJsonbStaysCamelCase() throws {
        let dict = try jsonObject(TaskRow(richTask()))
        // Top-level columns are snake_case.
        XCTAssertNotNil(dict["estimate_min"])
        XCTAssertNotNil(dict["total_focused"])
        XCTAssertNotNil(dict["intent_when"])
        XCTAssertNotNil(dict["first_physical_action"])
        XCTAssertNil(dict["estimateMin"])           // camelCase must NOT leak to columns
        // JSONB recurrence keeps camelCase keys (the critical case).
        let rec = dict["recurrence"] as! [String: Any]
        XCTAssertEqual(rec["kind"] as? String, "weekly")
        XCTAssertNotNil(rec["daysOfWeek"])
        XCTAssertNil(rec["days_of_week"])           // must NOT be snake_cased
        // JSONB objectives keep camelCase keys too.
        let objs = dict["objectives"] as! [[String: Any]]
        XCTAssertEqual(objs.first?["text"] as? String, "outline")
        XCTAssertEqual(objs.first?["done"] as? Bool, true)
    }

    func testTaskDefaultsMatchWeb() throws {
        let bare = TaskItem(id: "t", name: "N", estimateMin: 25, createdAt: "c", updatedAt: "u")
        let dict = try jsonObject(TaskRow(bare))
        XCTAssertEqual(dict["move_count"] as? Int, 0)        // moveCount ?? 0
        XCTAssertEqual(dict["later"] as? Bool, false)        // later ?? false
        XCTAssertEqual(dict["tags"] as? [String], [])        // tags ?? []
        XCTAssertTrue(dict["recurrence"] is NSNull)          // nil → explicit null (matches web)
        XCTAssertTrue(dict["priority"] is NSNull)
    }

    func testTaskRoundTripIdentity() throws {
        let task = richTask()
        let back = TaskRow(task).model()
        XCTAssertEqual(back, task)
    }

    // ── Move-to-task / accountability columns (migration 025) ───────────────
    func testTaskSourceColumnsSnakeCase() throws {
        let task = TaskItem(id: "t", name: "N", estimateMin: 25, createdAt: "c", updatedAt: "u",
                            sourceCollectionId: "cid", sourceItemId: "iid", dueAt: "2026-06-15T18:00:00.000Z")
        let dict = try jsonObject(TaskRow(task))
        XCTAssertEqual(dict["source_collection_id"] as? String, "cid")
        XCTAssertEqual(dict["source_item_id"] as? String, "iid")
        XCTAssertEqual(dict["due_at"] as? String, "2026-06-15T18:00:00.000Z")
        XCTAssertNil(dict["sourceCollectionId"])      // camelCase must NOT leak
    }

    func testTaskSourceColumnsRoundTrip() throws {
        let task = TaskItem(id: "t", name: "N", estimateMin: 25, createdAt: "c", updatedAt: "u",
                            sourceCollectionId: "cid-123", sourceItemId: "iid-456", dueAt: "2026-06-15T18:00:00.000Z")
        let back = TaskRow(task).model()
        XCTAssertEqual(back.sourceCollectionId, "cid-123")
        XCTAssertEqual(back.sourceItemId, "iid-456")
        XCTAssertEqual(back.dueAt, "2026-06-15T18:00:00.000Z")
    }

    func testTaskSourceColumnsNilEncodeAsNull() throws {
        let dict = try jsonObject(TaskRow(TaskItem(id: "t", name: "N", estimateMin: 25, createdAt: "c", updatedAt: "u")))
        // nil → explicit null (so an upsert CLEARS the link), never omitted.
        XCTAssertTrue(dict["source_collection_id"] is NSNull)
        XCTAssertTrue(dict["source_item_id"] is NSNull)
        XCTAssertTrue(dict["due_at"] is NSNull)
    }

    // ── Collection sharing fields (migrations 020/026) ──────────────────────
    func testCollectionArchivedRoundTrips() throws {
        let col = ItemCollection(id: "c1", name: "Trip", color: "indigo", items: [], sortOrder: 0, archived: true)
        let dict = try jsonObject(CollectionRow(col))
        XCTAssertEqual(dict["archived"] as? Bool, true)
        XCTAssertNil(dict["user_id"])                 // ownerId is decode-only — never encoded
        XCTAssertEqual(CollectionRow(col).model().archived, true)
    }

    func testCollectionDecodesOwnerIdFromUserId() throws {
        let json = """
        {"id":"c1","name":"Trip","color":"indigo","subtitle":"","items":[],"sort_order":0,
         "archived":false,"user_id":"owner-uuid"}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(CollectionRow.self, from: json).model()
        XCTAssertEqual(model.ownerId, "owner-uuid")
        XCTAssertEqual(model.archived, false)
    }

    func testDecodeServerShapedJson() throws {
        let json = """
        {"id":"t1","name":"N","estimate_min":30,"total_focused":0,"done":false,
         "priority":"high","tags":["x"],"objectives":[{"text":"o","done":true,"minutes":5}],
         "comments":[],"intent_when":null,"intent_then":null,"life_area":"Work",
         "first_physical_action":null,"move_count":2,"completed_at":null,"later":true,
         "recurrence":{"kind":"weekly","daysOfWeek":[1,3],"until":null},
         "created_at":"2026-05-21T10:00:00.000Z","updated_at":"2026-05-21T10:00:00.000Z"}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(TaskRow.self, from: json).model()
        XCTAssertEqual(model.estimateMin, 30)
        XCTAssertEqual(model.lifeArea, "Work")
        XCTAssertEqual(model.later, true)
        XCTAssertEqual(model.moveCount, 2)
        XCTAssertEqual(model.objectives?.first?.minutes, 5)
        XCTAssertEqual(model.recurrence, .weekly(daysOfWeek: [1, 3], until: nil))
    }

    // An unknown recurrence kind (a newer release's shape) decodes inside a whole
    // TaskRow to a USABLE task — recurrence present but inert — rather than throwing
    // and dropping the row entirely (which would make the task VANISH). Mirrors
    // Android's CoreModelsTest.unknownKindKeepsTaskDecodable.
    func testTaskWithUnknownRecurrenceKindStillDecodes() throws {
        let json = """
        {"id":"t1","name":"Ship","estimate_min":25,"total_focused":0,"done":false,
         "priority":null,"tags":[],"objectives":[],"comments":[],
         "intent_when":null,"intent_then":null,"life_area":null,
         "first_physical_action":null,"move_count":0,"completed_at":null,"later":false,
         "recurrence":{"kind":"yearly"},
         "created_at":"2026-05-21T10:00:00.000Z","updated_at":"2026-05-21T10:00:00.000Z"}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(TaskRow.self, from: json).model()
        XCTAssertEqual(model.name, "Ship")            // the task survived
        XCTAssertTrue(Recurrence.isUnknown(model.recurrence))   // recurrence is inert
    }

    func testForeignKeysDroppedWhenNotUUID() throws {
        let valid = "22222222-2222-4222-8222-222222222222"
        let bad = CalBlock(id: "b", taskId: "not-a-uuid", taskName: "B", startTime: "09:00",
                           durationMinutes: 25, date: "2026-05-21", externalConnectionId: "also-bad", kind: .task)
        let badDict = try jsonObject(CalBlockRow(bad))
        XCTAssertTrue(badDict["task_id"] is NSNull)
        XCTAssertTrue(badDict["external_connection_id"] is NSNull)

        let good = CalBlock(id: "b", taskId: valid, taskName: "B", startTime: "09:00",
                            durationMinutes: 25, date: "2026-05-21", externalConnectionId: valid, kind: .task)
        let goodDict = try jsonObject(CalBlockRow(good))
        XCTAssertEqual(goodDict["task_id"] as? String, valid)
        XCTAssertEqual(goodDict["external_connection_id"] as? String, valid)
    }

    func testReasonLogOmitsDurationWhenNilButSendsWhenPresent() throws {
        let withoutDur = ReasonLog(id: "r", taskId: nil, reason: "x", action: .pause, at: "a", durationSec: nil)
        XCTAssertNil(try jsonObject(ReasonLogRow(withoutDur))["duration_sec"])   // omitted entirely
        let withDur = ReasonLog(id: "r", taskId: nil, reason: "x", action: .pause, at: "a", durationSec: 42)
        XCTAssertEqual(try jsonObject(ReasonLogRow(withDur))["duration_sec"] as? Int, 42)
    }

    func testEachEntityRoundTrips() throws {
        let u = "33333333-3333-4333-8333-333333333333"
        XCTAssertEqual(SessionRow(Session(id: "s", taskId: u, taskName: "S", tags: ["x"], estimateMin: 25, actualSec: 1500, completedAt: "c")).model(),
                       Session(id: "s", taskId: u, taskName: "S", tags: ["x"], estimateMin: 25, actualSec: 1500, completedAt: "c"))
        XCTAssertEqual(CalBlockRow(CalBlock(id: "b", taskId: u, taskName: "B", startTime: "09:00", durationMinutes: 50, date: "2026-05-21", externalEventId: "g_1", externalConnectionId: u, kind: .external)).model().kind, .external)
        XCTAssertEqual(CaptureRow(Capture(id: "c", taskId: u, sessionId: u, tag: .idea, body: "b", at: "a")).model(),
                       Capture(id: "c", taskId: u, sessionId: u, tag: .idea, body: "b", at: "a"))
        XCTAssertEqual(ReasonLogRow(ReasonLog(id: "r", taskId: u, reason: "x", action: .switch, at: "a", durationSec: 10)).model(),
                       ReasonLog(id: "r", taskId: u, reason: "x", action: .switch, at: "a", durationSec: 10))
        // archived normalizes nil → false on round-trip (web/Android parity), so
        // the input carries archived: false for the identity comparison.
        let col = ItemCollection(id: "c", name: "Books", color: "indigo", subtitle: "read",
                                 items: [CollectionItem(id: "i", body: "x", at: "a")], sortOrder: 1, archived: false)
        XCTAssertEqual(CollectionRow(col).model(), col)
        XCTAssertEqual(TagDbRow(TagRow(id: "t", name: "urgent", color: "coral", sortOrder: 0)).model(),
                       TagRow(id: "t", name: "urgent", color: "coral", sortOrder: 0))
        XCTAssertEqual(LifeAreaDbRow(LifeArea(id: "a", name: "Work", color: "indigo", sortOrder: 0)).model(),
                       LifeArea(id: "a", name: "Work", color: "indigo", sortOrder: 0))
        let conn = CalendarConnection(id: "cc", provider: .google, accountEmail: "a@b.com", displayName: "W",
                                      selectedCalendarIds: ["primary"], colorSlot: 2, lastSyncCursor: "cur", connectedAt: "c")
        XCTAssertEqual(CalendarConnectionRow(conn).model(), conn)
    }

    func testCalendarConnectionColumnsAreSnakeCase() throws {
        let conn = CalendarConnection(id: "cc", provider: .google, accountEmail: "a@b.com", displayName: "W",
                                      selectedCalendarIds: ["primary"], colorSlot: 2, lastSyncCursor: nil, connectedAt: "c")
        let dict = try jsonObject(CalendarConnectionRow(conn))
        XCTAssertNotNil(dict["account_email"])
        XCTAssertNotNil(dict["selected_calendar_ids"])
        XCTAssertNotNil(dict["color_slot"])
        XCTAssertTrue(dict["last_sync_cursor"] is NSNull)
    }
}
