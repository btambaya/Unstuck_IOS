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

    // MARK: - Shared-view timer (T1b): coFocusPeerTimer + payload carry-through

    /// A running focusing peer: elapsed = now − sessionStartMs; remaining counts
    /// down from estimateMin*60. Mirrors the focuser's own FocusTimer.elapsedSec.
    func testFocusingPeerRunningTimer() {
        let peer = CoFocusPeer(userId: "u1", name: "Ann", state: .focusing, sinceMs: 0,
                               sessionStartMs: 1_000_000, paused: false, pausedAtMs: nil, estimateMin: 25)
        let t = coFocusPeerTimer(peer, now: 1_090_000)   // +90s
        XCTAssertEqual(t?.elapsedSec, 90)
        XCTAssertEqual(t?.remainingSec, 25 * 60 - 90)     // 1410
        XCTAssertEqual(t?.paused, false)
    }

    /// A paused focusing peer freezes at pausedAtMs − sessionStartMs, ignoring now.
    func testFocusingPeerPausedFreezes() {
        let peer = CoFocusPeer(userId: "u1", name: "Ann", state: .focusing, sinceMs: 0,
                               sessionStartMs: 1_000_000, paused: true, pausedAtMs: 1_030_000, estimateMin: 25)
        let t = coFocusPeerTimer(peer, now: 9_999_999)    // now is irrelevant while paused
        XCTAssertEqual(t?.elapsedSec, 30)
        XCTAssertEqual(t?.remainingSec, 25 * 60 - 30)     // 1470
        XCTAssertEqual(t?.paused, true)
    }

    /// Remaining never goes negative once the peer runs past their estimate.
    func testRemainingClampsAtZero() {
        let peer = CoFocusPeer(userId: "u1", name: "Ann", state: .focusing, sinceMs: 0,
                               sessionStartMs: 1_000_000, paused: false, pausedAtMs: nil, estimateMin: 25)
        let t = coFocusPeerTimer(peer, now: 1_000_000 + 2_000_000)   // +2000s past a 1500s estimate
        XCTAssertEqual(t?.elapsedSec, 2000)
        XCTAssertEqual(t?.remainingSec, 0)
    }

    /// No timer for a non-focusing peer, or a focusing peer without a session.
    func testNoTimerWhenNotFocusingOrNoSession() {
        let here = CoFocusPeer(userId: "u1", name: "Ann", state: .here, sinceMs: 0,
                               sessionStartMs: 1_000_000, paused: false, pausedAtMs: nil, estimateMin: 25)
        XCTAssertNil(coFocusPeerTimer(here, now: 2_000_000))
        let noSession = CoFocusPeer(userId: "u2", name: "Bob", state: .focusing, sinceMs: 0)
        XCTAssertNil(coFocusPeerTimer(noSession, now: 2_000_000))
    }

    /// The reduction carries timer fields through for a focusing peer, and drops
    /// them for a `here` peer (so coFocusPeerTimer stays a clean gate).
    func testReductionCarriesTimerForFocusingPeerOnly() {
        let presences: [String: CoFocusMeta] = [
            "owner": CoFocusMeta(userId: "owner", name: "Ann", state: .focusing, sinceMs: 1,
                                 sessionStartMs: 1_000_000, paused: true, pausedAtMs: 1_060_000, estimateMin: 45),
            "sitter": CoFocusMeta(userId: "sitter", name: "Bob", state: .here, sinceMs: 2,
                                  sessionStartMs: 1_000_000, paused: false, pausedAtMs: nil, estimateMin: 25),
        ]
        let peers = coFocusPeers(from: presences, selfId: "me")
        let owner = peers.first { $0.userId == "owner" }
        XCTAssertEqual(owner?.sessionStartMs, 1_000_000)
        XCTAssertEqual(owner?.paused, true)
        XCTAssertEqual(owner?.pausedAtMs, 1_060_000)
        XCTAssertEqual(owner?.estimateMin, 45)
        let sitter = peers.first { $0.userId == "sitter" }
        XCTAssertNil(sitter?.sessionStartMs)             // dropped for a `here` peer
        XCTAssertEqual(sitter?.paused, false)
        XCTAssertNil(sitter?.estimateMin)
    }
}
