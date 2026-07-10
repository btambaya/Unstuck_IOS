// Covers coFocusPeers — the pure "who's here with me" reduction (port of
// lib/cofocus-presence.ts recompute): excludes yourself, sorts focusing-first
// then longest-present, and normalises an unknown/absent state to `.here`.

import XCTest
@testable import UnstuckCore

final class CoFocusPeersTests: XCTestCase {

    func testExcludesSelf() {
        let presences: [String: CoFocusMeta] = [
            "me": CoFocusMeta(userId: "me", name: "Me", state: .focusing, sinceMs: 1),
            "u1": CoFocusMeta(userId: "u1", name: "Ann", state: .here, sinceMs: 2),
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        XCTAssertEqual(peers.map(\.userId), ["u1"])
    }

    func testFocusingSortsBeforeHere() {
        let presences: [String: CoFocusMeta] = [
            "u1": CoFocusMeta(userId: "u1", name: "Ann", state: .here, sinceMs: 1),
            "u2": CoFocusMeta(userId: "u2", name: "Bob", state: .focusing, sinceMs: 5),
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        XCTAssertEqual(peers.map(\.userId), ["u2", "u1"])   // focusing first
    }

    func testSameStateOrdersByLongestPresent() {
        let presences: [String: CoFocusMeta] = [
            "late": CoFocusMeta(userId: "late", name: "L", state: .here, sinceMs: 100),
            "early": CoFocusMeta(userId: "early", name: "E", state: .here, sinceMs: 10),
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        XCTAssertEqual(peers.map(\.userId), ["early", "late"])   // earliest sinceMs first
    }

    func testUnknownStateNormalisesToHere() {
        // state nil → treated as `.here` (not focusing).
        let presences: [String: CoFocusMeta] = [
            "u1": CoFocusMeta(userId: "u1", name: "Ann", state: nil, sinceMs: 3),
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        XCTAssertEqual(peers.first?.state, .here)
    }

    func testFallsBackToKeyAndSomeoneWhenMetaSparse() {
        let presences: [String: CoFocusMeta] = [
            "u1": CoFocusMeta(),   // no fields at all
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        XCTAssertEqual(peers.first?.userId, "u1")     // falls back to the key
        XCTAssertEqual(peers.first?.name, "Someone")  // falls back to "Someone"
        XCTAssertEqual(peers.first?.state, .here)
        XCTAssertEqual(peers.first?.sinceMs, 0)
    }

    func testEmptyWhenAlone() {
        let presences: [String: CoFocusMeta] = [
            "me": CoFocusMeta(userId: "me", name: "Me", state: .focusing, sinceMs: 1),
        ]
        XCTAssertTrue(coFocusPeers(from: presences, selfId: "me").isEmpty)
    }
}
