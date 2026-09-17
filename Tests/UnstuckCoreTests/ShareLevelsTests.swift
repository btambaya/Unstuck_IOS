// Pure sharing-logic tests — the iOS mirror of lib/share-levels.test.ts +
// components/tasks/delegated-group.test.ts. Guards the capability labels + the
// delegation derivation that the share sheet, the "Shared with you"/"Delegated"
// groups, and the Start-Next exclusion all depend on.

import XCTest
@testable import UnstuckCore

final class ShareLevelsTests: XCTestCase {

    // MARK: share levels v3 — view / partner / assign

    func testHasThreeCapabilityLevelsInOrder() {
        XCTAssertEqual(SHARE_LEVELS.map(\.value), [.view, .partner, .assign])
    }

    func testOnlyPartnerAndAssignCanAct() {
        XCTAssertFalse(levelCanComplete(.view))
        XCTAssertTrue(levelCanComplete(.partner))
        XCTAssertTrue(levelCanComplete(.assign))
    }

    // MARK: shareStatusLabel (recipient side)

    func testDoneWinsForAnyLevel() {
        XCTAssertEqual(shareStatusLabel(.view, done: true), "done")
        XCTAssertEqual(shareStatusLabel(.partner, done: true), "done")
        XCTAssertEqual(shareStatusLabel(.assign, done: true), "done")
    }

    /// Unified sharing v1 §2: the recipient reads the SENDER's words, never
    /// the storage level ("partner" / "watching" leaked the backend).
    func testNotDoneLabelsSpeakTheOneVocabulary() {
        XCTAssertEqual(shareStatusLabel(.view, done: false), "can view")
        XCTAssertEqual(shareStatusLabel(.partner, done: false), "can edit")
        XCTAssertEqual(shareStatusLabel(.assign, done: false), "yours")
        // and never the raw levels again
        for level in ShareLevel.allCases {
            XCTAssertNotEqual(shareStatusLabel(level, done: false), level.rawValue)
        }
    }

    // MARK: shareLevelLabel (owner side)

    func testMapsEachLevelToItsGrantedWord() {
        XCTAssertEqual(shareLevelLabel(.view), "can view")
        XCTAssertEqual(shareLevelLabel(.partner), "can edit")
        XCTAssertEqual(shareLevelLabel(.assign), "handed over")
    }

    // MARK: assignedOutMap / assignedOutIds (delegation derivation)

    /// Share badges keyed by taskId, as produced by shareBadgesByTask.
    private let badges: [String: [ShareBadge]] = [
        "t1": [ShareBadge(taskId: "t1", level: .assign, recipientName: "Bob")],
        "t2": [ShareBadge(taskId: "t2", level: .view, recipientName: "Cara")],
        "t3": [ShareBadge(taskId: "t3", level: .partner, recipientName: "Dee"),
               ShareBadge(taskId: "t3", level: .assign, recipientName: "Eve")],
    ]

    func testAssignedOutMapMapsOnlyAssignLevelToAssignee() {
        XCTAssertEqual(assignedOutMap(badges), ["t1": "Bob", "t3": "Eve"])
    }

    func testAssignedOutMapIgnoresViewAndPartnerOnly() {
        XCTAssertEqual(assignedOutMap(["t2": [ShareBadge(taskId: "t2", level: .view, recipientName: "Cara")]]), [:])
        XCTAssertEqual(assignedOutMap([:]), [:])
    }

    func testAssignedOutIdsReturnsAnyAssignBadgeTasks() {
        let ids = assignedOutIds(badges)
        XCTAssertTrue(ids.contains("t1"))
        XCTAssertTrue(ids.contains("t3"))
        XCTAssertFalse(ids.contains("t2"))
        XCTAssertEqual(ids.count, 2)
    }

    func testAssignedOutIdsExcludesViewAndPartnerOnly() {
        let ids = assignedOutIds([
            "a": [ShareBadge(taskId: "a", level: .view, recipientName: "X")],
            "b": [ShareBadge(taskId: "b", level: .partner, recipientName: "Y")],
        ])
        XCTAssertTrue(ids.isEmpty)
    }
}
