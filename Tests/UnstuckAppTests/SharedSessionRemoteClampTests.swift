// An incoming partner control (one true shared session) is applied through
// AppModel.handleSharedControl → applyRemoteSnapshot. The partner's
// `sessionStartMs` must be stored CLAMPED to our clock — a partner whose wall
// clock runs ahead posts a start in our future, which used to be stored
// verbatim and inflate our elapsed once the skew passed (web parity:
// `clampAdoptedSessionStartMs`). Runs on the in-memory AppModel (UI-test mode:
// GRDB in memory, no coordinator / channel), so the reducer's persistence is
// exercised without a socket.

import XCTest
import UnstuckCore
import UnstuckData
@testable import Unstuck

@MainActor
final class SharedSessionRemoteClampTests: XCTestCase {
    private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// A live partner-shared session at rev 1, minted a minute ago.
    private func seed(_ model: AppModel, startedAgoMs: Double = 60_000) throws -> LiveSessionStore {
        let store = try XCTUnwrap(model.liveStore)
        var live = FocusTimer.start(.empty, taskId: "t-proposal", estimateMin: 25,
                                    now: nowMs() - startedAgoMs, newId: { "s1" })
        live.sharedFocusLevel = .partner
        live.sharedSessionRev = 1
        live.sharedSessionAtMs = nowMs() - startedAgoMs
        try store.set(live)
        model.refreshLiveSession()
        return store
    }

    /// A partner control as it arrives off the wire: every sender (web,
    /// Android, iOS) posts whole-ms timestamps.
    private func control(start: Double, rev: Int, paused: Bool = false, pausedAt: Double? = nil,
                         estimate: Int = 25) -> SharedSessionMsg {
        SharedSessionMsg(userId: "u-partner", sessionId: "s1", sessionStartMs: start.rounded(), paused: paused,
                         pausedAtMs: pausedAt.map { $0.rounded() }, estimateMin: estimate, rev: rev,
                         atMs: nowMs().rounded(), ended: false)
    }

    func testAPartnerStartInOurFutureIsClampedToNowWhenApplied() throws {
        let model = AppModel()
        model.startUITestMode()
        let store = try seed(model)
        let before = nowMs()
        // A partner clock 90s ahead: adoptable (< 2 min skew) but not displayable as-is.
        model.handleSharedControl(control(start: before + 90_000, rev: 2))
        let after = nowMs()
        let stored = try XCTUnwrap(try store.get())
        let start = try XCTUnwrap(stored.sessionStart)
        XCTAssertLessThanOrEqual(start, after, "never in our future")
        // The reducer floors `now` to whole ms — allow that sub-ms slack.
        XCTAssertGreaterThanOrEqual(start, before - 1, "clamped to now, not to some earlier value")
        XCTAssertEqual(stored.lastAppliedRev, 2, "the control itself was applied")
        XCTAssertEqual(FocusTimer.elapsedSec(stored, now: after), 0, "elapsed starts at 0 instead of going negative")
        XCTAssertEqual(model.liveSession?.sessionStart, start, "the in-memory cache agrees with the store")
        // Applying a clamped remote state is NOT a local control: the echo
        // baseline mirrors the stored start at the wire's rev, and nothing
        // is minted on top (a rev+1 here would shift the partner's clock).
        XCTAssertEqual(model.lastSharedBroadcast?.sessionStartMs, start.rounded())
        XCTAssertEqual(model.lastSharedBroadcast?.rev, 2)
        XCTAssertEqual(stored.sharedSessionRev, 1, "no spurious local rev bump")
    }

    func testAPartnerStartInOurPastIsStoredVerbatim() throws {
        let model = AppModel()
        model.startUITestMode()
        let store = try seed(model)
        let partnerStart = (nowMs() - 5 * 60_000).rounded()
        model.handleSharedControl(control(start: partnerStart, rev: 2))
        let stored = try XCTUnwrap(try store.get())
        XCTAssertEqual(stored.sessionStart, partnerStart, "a partner clock running behind is harmless — kept as posted")
        XCTAssertEqual(stored.lastAppliedRev, 2)
        XCTAssertEqual(stored.sharedSessionRev, 1, "a plain remote apply never mints a local rev")
        XCTAssertEqual(model.lastSharedBroadcast?.sessionStartMs, partnerStart)
    }

    func testAPausedPartnerControlClampsTheStartAndKeepsThePause() throws {
        let model = AppModel()
        model.startUITestMode()
        let store = try seed(model)
        let before = nowMs().rounded(.down)
        model.handleSharedControl(control(start: before + 60_000, rev: 2, paused: true, pausedAt: before + 60_000))
        let stored = try XCTUnwrap(try store.get())
        XCTAssertTrue(stored.paused)
        XCTAssertLessThanOrEqual(try XCTUnwrap(stored.sessionStart), nowMs())
        XCTAssertEqual(stored.pausedAt, before + 60_000, "pausedAt is wire state, untouched (web parity)")
        // Paused elapsed is pausedAt − start: frozen, never growing with our clock.
        let frozen = FocusTimer.elapsedSec(stored, now: nowMs())
        XCTAssertEqual(FocusTimer.elapsedSec(stored, now: nowMs() + 3_600_000), frozen)
        XCTAssertEqual(stored.lastAppliedRev, 2)
        XCTAssertEqual(stored.sharedSessionRev, 1, "no spurious local rev bump")
    }
}
