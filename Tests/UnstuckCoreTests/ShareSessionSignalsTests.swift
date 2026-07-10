// Ports lib/use-share-session-signals.test.ts case-for-case — the pure reducer
// distinguishes a genuine start from a mid-session reload via session id, fires
// session_start/session_end only for shared tasks, and handles A→B switch,
// private sessions, and pause/resume.

import XCTest
@testable import UnstuckCore

final class ShareSessionSignalsTests: XCTestCase {

    /// Drive a sequence of (sid, shared) observations through the pure reducer
    /// and collect everything it would fire. Mirrors how the observer feeds it.
    private func run(_ steps: [(sid: String?, shared: String?)]) -> [SigFire] {
        var s = initSigState()
        var fired: [SigFire] = []
        for step in steps {
            let (state, fires) = sessionSignalStep(s, sid: step.sid, shared: step.shared)
            s = state
            fired.append(contentsOf: fires)
        }
        return fired
    }

    func testFiresStartThenEndForFreshSharedSession() {
        XCTAssertEqual(run([
            (nil, nil),          // mount, idle
            ("s1", "t1"),        // start on shared task
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionStart, taskId: "t1"),
            SigFire(kind: .sessionEnd, taskId: "t1"),
        ])
    }

    func testStillFiresStartWhenBadgesResolveAfterSessionBegan() {
        XCTAssertEqual(run([
            (nil, nil),          // mount, idle, badges empty
            ("s1", nil),         // start — badges not loaded yet
            ("s1", "t1"),        // badges resolve, same session
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionStart, taskId: "t1"),
            SigFire(kind: .sessionEnd, taskId: "t1"),
        ])
    }

    func testDoesNotReAnnounceReloadedSessionButStillFiresEnd() {
        XCTAssertEqual(run([
            ("s1", "t1"),        // mount MID-session (reload) — adopt, no start
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionEnd, taskId: "t1"),
        ])
    }

    func testDoesNotReAnnounceReloadedSessionEvenIfBadgesResolveLate() {
        XCTAssertEqual(run([
            ("s1", nil),         // mount mid-session, badges empty → adopt
            ("s1", "t1"),        // badges resolve, same adopted session
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionEnd, taskId: "t1"),   // no start, but end fires
        ])
    }

    func testHandlesDirectSwitchFromSharedAToSharedB() {
        XCTAssertEqual(run([
            (nil, nil),
            ("s1", "A"),         // start A
            ("s2", "B"),         // displace → new session on B
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionStart, taskId: "A"),
            SigFire(kind: .sessionEnd, taskId: "A"),
            SigFire(kind: .sessionStart, taskId: "B"),
            SigFire(kind: .sessionEnd, taskId: "B"),
        ])
    }

    func testNeverFiresForPrivateSession() {
        XCTAssertEqual(run([
            (nil, nil),
            ("s1", nil),         // start on a private task
            (nil, nil),          // done
        ]), [])
    }

    func testQuietAcrossPauseResume() {
        XCTAssertEqual(run([
            (nil, nil),
            ("s1", "t1"),        // start → one start
            ("s1", "t1"),        // pause tick
            ("s1", "t1"),        // resume tick
            (nil, nil),          // done → one end
        ]), [
            SigFire(kind: .sessionStart, taskId: "t1"),
            SigFire(kind: .sessionEnd, taskId: "t1"),
        ])
    }

    func testSwitchingSharedToPrivateEndsSharedOnly() {
        XCTAssertEqual(run([
            (nil, nil),
            ("s1", "t1"),        // start shared
            ("s2", nil),         // switch to private task
            (nil, nil),          // done
        ]), [
            SigFire(kind: .sessionStart, taskId: "t1"),
            SigFire(kind: .sessionEnd, taskId: "t1"),
        ])
    }
}
