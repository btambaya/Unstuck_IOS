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

    func testNotDoneLabelsReflectTheLevel() {
        XCTAssertEqual(shareStatusLabel(.view, done: false), "watching")
        XCTAssertEqual(shareStatusLabel(.partner, done: false), "partner")
        XCTAssertEqual(shareStatusLabel(.assign, done: false), "yours")
    }

    // MARK: shareLevelLabel (owner side)

    func testMapsEachLevelToItsGrantedWord() {
        XCTAssertEqual(shareLevelLabel(.view), "view")
        XCTAssertEqual(shareLevelLabel(.partner), "partner")
        XCTAssertEqual(shareLevelLabel(.assign), "assigned")
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
