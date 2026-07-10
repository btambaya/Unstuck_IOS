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
}
