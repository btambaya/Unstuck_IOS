// Ported from lib/assistant/share-request.test.ts. Sharing sends the user's
// content to another person and can't be silently undone, so the resolver's
// job is to STAGE and to refuse guessing — never to share.

import XCTest
@testable import UnstuckCore

final class AssistantShareRequestTests: XCTestCase {

    private func task(_ name: String, _ id: String? = nil) -> TaskItem {
        TaskItem(id: id ?? name.lowercased().replacingOccurrences(of: " ", with: "-"),
                 name: name, estimateMin: 25, totalFocused: 0, done: false,
                 createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
    }

    private let people = [
        ShareCandidate(userId: "u1", name: "Zubair Kazaure"),
        ShareCandidate(userId: "u2", name: "Ana Silva"),
    ]
    private let ids: () -> String = { "fixed-id" }

    private lazy var tasks = [task("Write the project update"), task("Grocery run")]

    // MARK: matchCandidate

    func testMatchesFullNameFirstNameAndUniquePrefixesCaseInsensitively() {
        XCTAssertEqual(matchCandidate("zubair kazaure", people)?.userId, "u1")
        XCTAssertEqual(matchCandidate("Zubair", people)?.userId, "u1")
        XCTAssertEqual(matchCandidate("an", people)?.userId, "u2")
    }

    func testRefusesAmbiguousOrUnknownNamesRatherThanGuessing() {
        let twoAnas = people + [ShareCandidate(userId: "u3", name: "Ana Bell")]
        XCTAssertNil(matchCandidate("ana", twoAnas))   // ambiguous prefix
        XCTAssertNil(matchCandidate("sam", people))
        XCTAssertNil(matchCandidate("", people))
    }

    // MARK: normalizeLevel

    func testAcceptsTheThreeRealLevelsAndDefaultsEverythingElseToView() {
        XCTAssertEqual(normalizeLevel("partner"), .partner)
        XCTAssertEqual(normalizeLevel("ASSIGN"), .assign)
        XCTAssertEqual(normalizeLevel("owner"), .view)
        XCTAssertEqual(normalizeLevel(nil), .view)
    }

    // MARK: resolveShareRequest

    func testStagesARequestWithTheResolvedTaskPersonAndLevel() {
        let r = resolveShareRequest(taskName: "Grocery run", person: "Ana", level: "partner",
                                    tasks: tasks, people: people, newId: ids)
        XCTAssertEqual(r.pending, PendingShare(id: "fixed-id", taskId: "grocery-run", taskName: "Grocery run",
                                               recipientUserId: "u2", recipientName: "Ana Silva", level: .partner))
        // The model is explicitly told NOT to claim it happened.
        XCTAssertTrue(r.message.contains("CONFIRM"))
        XCTAssertTrue(r.message.contains("do not claim it is shared"))
    }

    func testResolvesTheTaskByIdAndByFuzzyNameWhenTheIdIsUnknown() {
        XCTAssertEqual(resolveShareRequest(taskId: "grocery-run", person: "Ana",
                                           tasks: tasks, people: people, newId: ids).pending?.taskId,
                       "grocery-run")
        XCTAssertEqual(resolveShareRequest(taskName: "project update", person: "Ana",
                                           tasks: tasks, people: people, newId: ids).pending?.taskName,
                       "Write the project update")
    }

    func testStagesNothingWhenTheTaskCannotBeFound() {
        let r = resolveShareRequest(taskName: "nonexistent", person: "Ana",
                                    tasks: tasks, people: people, newId: ids)
        XCTAssertNil(r.pending)
        XCTAssertTrue(r.message.contains("task not found"))
    }

    func testStagesNothingWhenTheCircleIsEmptyAndSaysWhatToDo() {
        let r = resolveShareRequest(taskName: "Grocery run", person: "Ana",
                                    tasks: tasks, people: [], newId: ids)
        XCTAssertNil(r.pending)
        XCTAssertTrue(r.message.contains("trusted circle"))
    }

    func testStagesNothingForAnUnknownPersonAndListsWhoIsAvailable() {
        let r = resolveShareRequest(taskName: "Grocery run", person: "Sam",
                                    tasks: tasks, people: people, newId: ids)
        XCTAssertNil(r.pending)
        XCTAssertTrue(r.message.contains("Zubair Kazaure, Ana Silva"))
    }

    func testDefaultsAnUnrecognisedLevelToTheLeastPermissiveView() {
        let r = resolveShareRequest(taskName: "Grocery run", person: "Ana", level: "everything",
                                    tasks: tasks, people: people, newId: ids)
        XCTAssertEqual(r.pending?.level, .view)
    }

    func testAMissingPersonStagesNothingEvenWhenTheTaskResolves() {
        let r = resolveShareRequest(taskName: "Grocery run", tasks: tasks, people: people, newId: ids)
        XCTAssertNil(r.pending)
        XCTAssertTrue(r.message.hasPrefix("error:"))
    }
}
