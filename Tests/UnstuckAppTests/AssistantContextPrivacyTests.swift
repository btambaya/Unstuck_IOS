// What leaves the device on every assistant turn (iOS side of
// lib/assistant/context-privacy.test.ts).
//
// buildAssistantContext() is serialised and sent to a third-party model
// provider with EVERY turn (and injected into the realtime voice session's
// instructions), so its shape is a privacy contract, not just a prompt
// detail. The published privacy policy (unstuck
// components/marketing/privacy-content.ts §9.1) describes exactly what these
// tests assert; if one of them has to change, the policy paragraph changes
// with it — and the web test changes with both.
//
// Privacy audit, 2026-09-12: the snapshot used to carry capture text, every
// list item's body (including items authored by OTHER people in a list shared
// with this user) and the names of the user's trusted circle — for a turn as
// small as "hi". It is now an inventory: ids, names and counts. Contents are
// fetched on demand through the read tools (get_captures / get_lists).

import XCTest
import Supabase
import UnstuckCore
@testable import Unstuck

@MainActor
final class AssistantContextPrivacyTests: XCTestCase {
    private var api = FakeAssistantState()

    private let CAPTURE_TEXT = "ring the clinic about the biopsy results"
    private let MY_ITEM_TEXT = "oat milk and paracetamol"
    private let THEIR_ITEM_TEXT = "Nadia's divorce solicitor — call Tuesday"
    private let CIRCLE_NAME = "Zubair Ahmed"

    /// The keys EVERY turn carries. Anything else is optional and only appears
    /// when its input exists (see `optionalKeys`). 1:1 with the web builder.
    private let requiredKeys: Set<String> = [
        "today", "todayWeekday", "upcoming", "now", "nowNote", "todayFree", "currentName",
        "profile", "tone", "noticed", "week", "areas", "tags",
        "captures", "people", "tasks", "lists",
    ]
    /// The complete set of conditional keys — nothing else may ever be added
    /// without the policy paragraph changing.
    private let optionalKeys: Set<String> = ["preferredName", "nameUse", "struggle", "focusWindow", "focus"]

    private func twoItemList(_ id: String, _ name: String, _ body: String, mine: Bool) -> ItemCollection {
        ItemCollection(
            id: id, name: name, color: "indigo",
            items: [
                CollectionItem(id: "\(id)-1", body: body, at: PAST_CREATED),
                CollectionItem(id: "\(id)-2", body: "\(body) (2)", done: true, at: PAST_CREATED),
            ],
            sortOrder: 0, myRole: mine ? "owner" : "viewer")
    }

    override func setUp() async throws {
        try await super.setUp()
        api = FakeAssistantState()
        api.tasks = [task("t1", "Renew passport")]
        api.collections = [
            twoItemList("l1", "Shopping", MY_ITEM_TEXT, mine: true),
            twoItemList("l2", "Nadia · handover", THEIR_ITEM_TEXT, mine: false),
        ]
        api.captures = [capture("cap1", CAPTURE_TEXT)]
        api.people = [CirclePerson(name: CIRCLE_NAME, status: "active"), CirclePerson(name: "Ana", status: "pending")]
    }

    private func json() -> String { assistantContextJSON(buildAssistantContext(api)) }
    private func objects(_ key: String) -> [[String: AnyJSON]] {
        guard case .array(let rows)? = buildAssistantContext(api)[key] else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    // MARK: - what must never leave

    func testNeverCarriesCaptureText() {
        XCTAssertFalse(json().contains(CAPTURE_TEXT))
        XCTAssertEqual(objects("captures"), [["id": .string("cap1"), "tag": .string("idea")]])
        // The task link survives (the model needs to know a capture is attached).
        api.captures = [capture("cap2", CAPTURE_TEXT, taskId: "t1")]
        XCTAssertFalse(json().contains(CAPTURE_TEXT))
        XCTAssertEqual(objects("captures"), [["id": .string("cap2"), "tag": .string("idea"), "taskId": .string("t1")]])
    }

    func testNeverCarriesListItemTextTheUsersOwnOrAnotherPersons() {
        let out = json()
        XCTAssertFalse(out.contains(MY_ITEM_TEXT))
        XCTAssertFalse(out.contains(THEIR_ITEM_TEXT))
        // Nor any item id — those come from get_lists.
        XCTAssertFalse(out.contains("l1-1"))
        XCTAssertFalse(out.contains("l2-1"))
    }

    func testNeverCarriesTheNamesOfPeopleInTheTrustedCircle() {
        XCTAssertFalse(json().contains(CIRCLE_NAME))
        XCTAssertEqual(buildAssistantContext(api)["people"],
                       .object(["active": .integer(1), "pending": .integer(1)]))
    }

    // MARK: - what must still be there (the 57-tool contract)

    func testStillTellsTheModelWhatExistsListNamesCountsAndWhatIsSharedWithThem() {
        XCTAssertEqual(objects("lists"), [
            ["id": .string("l1"), "name": .string("Shopping"), "items": .integer(2), "open": .integer(1)],
            ["id": .string("l2"), "name": .string("Nadia · handover"), "items": .integer(2), "open": .integer(1),
             "sharedWithYou": .bool(true)],
        ])
        // A local/unshared list carries no role at all → no flag.
        api.collections = [list("l3", "Errands", [("i1", "x")])]
        XCTAssertEqual(objects("lists"), [["id": .string("l3"), "name": .string("Errands"), "items": .integer(1), "open": .integer(1)]])
    }

    func testStillCarriesTheOpenTasksTheAssistantReasonsOver() {
        XCTAssertEqual(objects("tasks"), [["id": .string("t1"), "name": .string("Renew passport"), "estimateMin": .integer(25)]])
    }

    func testIsEmptySafeABrandNewAccountSendsNoInventoryItDoesNotHave() {
        api.tasks = []; api.collections = []; api.captures = []; api.people = []
        let ctx = buildAssistantContext(api)
        XCTAssertEqual(ctx["lists"], .array([]))
        XCTAssertEqual(ctx["captures"], .array([]))
        XCTAssertEqual(ctx["tasks"], .array([]))
        XCTAssertEqual(ctx["people"], .object(["active": .integer(0), "pending": .integer(0)]))
    }

    // MARK: - the exact key set

    func testTheTopLevelKeySetIsExactlyTheContract() {
        XCTAssertEqual(Set(buildAssistantContext(api).keys), requiredKeys,
                       "no optional key appears without its input")

        // Each optional key, and ONLY when its input exists.
        api.facts = [ProfileFact(id: "p", category: .preference, fact: "Call them Ari", source: .chat,
                                 createdAt: PAST_CREATED, updatedAt: PAST_CREATED),
                     ProfileFact(id: "n", category: .preference, fact: "Don't use their name in replies", source: .chat,
                                 createdAt: PAST_CREATED, updatedAt: PAST_CREATED)]
        api.struggles = ["Starting"]
        api.live = liveSession("t1")
        let now = Date()
        api.sessions = (0..<10).map { i in
            Session(id: "s\(i)", taskName: "Deep work", actualSec: 1500,
                    completedAt: isoUTC(now.addingTimeInterval(Double(-i) * 86_400 - 3600)))
        }
        XCTAssertEqual(Set(buildAssistantContext(api, now: now).keys), requiredKeys.union(optionalKeys))
    }

    /// A key set is only half the contract — these are the per-row key sets,
    /// which is where a body would sneak back in.
    func testThePerRowKeySetsAreExactlyTheContract() {
        api.captures = [capture("cap1", CAPTURE_TEXT, taskId: "t1")]
        XCTAssertEqual(objects("captures").map { Set($0.keys) }, [["id", "tag", "taskId"]])
        XCTAssertEqual(objects("lists").map { Set($0.keys) }, [["id", "name", "items", "open"],
                                                              ["id", "name", "items", "open", "sharedWithYou"]])
        guard case .object(let people)? = buildAssistantContext(api)["people"] else { return XCTFail("people") }
        XCTAssertEqual(Set(people.keys), ["active", "pending"])
    }

    // MARK: - the caps

    func testTheCapsAreTheWebsCaps() {
        let today = api.today
        let monday = LocalDate.mondayOf(today)
        api.captures = (0..<30).map { i in
            capture("c\(i)", CAPTURE_TEXT, at: String(format: "2026-09-01T%02d:00:00.000Z", i % 24))
        }
        api.collections = (0..<20).map { i in twoItemList("l\(i)", "List \(i)", MY_ITEM_TEXT, mine: true) }
        api.tasks = (0..<80).map { i in task("t\(i)", "Task \(i)") }
        // 7 days × 12 blocks = 84 in this week, all task-less so they cannot
        // reintroduce a task name beyond the `week` cap.
        api.blocks = (0..<7).flatMap { d in
            (0..<12).map { h in
                CalBlock(id: "b\(d)-\(h)", taskId: nil, taskName: "Block \(d)-\(h)",
                         startTime: String(format: "%02d:00", h + 6), durationMinutes: 30,
                         date: LocalDate.addDays(monday, d), kind: .external)
            }
        }
        api.facts = (0..<20).map { i in
            ProfileFact(id: "f\(i)", category: .context, fact: "Fact \(i)", source: .chat,
                        createdAt: PAST_CREATED, updatedAt: String(format: "2026-09-0%dT09:00:00.000Z", (i % 9) + 1))
        }

        let ctx = buildAssistantContext(api)
        XCTAssertEqual(objects("captures").count, 12)
        XCTAssertEqual(objects("lists").count, 12)
        XCTAssertEqual(objects("tasks").count, 60)
        XCTAssertEqual(objects("week").count, 60)
        guard case .array(let profile)? = ctx["profile"] else { return XCTFail("profile") }
        XCTAssertEqual(profile.count, 15)
        // And with everything capped, still no contents.
        let out = assistantContextJSON(ctx)
        XCTAssertFalse(out.contains(CAPTURE_TEXT))
        XCTAssertFalse(out.contains(MY_ITEM_TEXT))
    }

    private func isoUTC(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
