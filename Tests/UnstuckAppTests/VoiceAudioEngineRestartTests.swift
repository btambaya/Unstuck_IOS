// The engine's restart-on-configuration-change path (VoiceAudioEngine, file
// header): iOS stops AVAudioEngine by itself when the IO unit is reconfigured
// — on a real device that happens ~100 ms after start, when voice processing
// re-clocks the speaker — and the app must restart it. The AVAudio half can
// only be proven on a device (the simulator never reconfigures); what is
// unit-tested here is the pure loop guard and the engine's inert behaviour
// before it has started.

import XCTest
@testable import Unstuck

final class VoiceAudioEngineRestartTests: XCTestCase {

    func testPolicyAllowsABurstThenRefusesInsideTheWindow() {
        var p = EngineRestartPolicy(maxRestarts: 3, window: 10)
        XCTAssertTrue(p.allowRestart(now: 100))
        XCTAssertTrue(p.allowRestart(now: 100.5))
        XCTAssertTrue(p.allowRestart(now: 101))
        XCTAssertFalse(p.allowRestart(now: 101.2), "a fourth restart inside 10 s is a loop")
        XCTAssertFalse(p.allowRestart(now: 105), "still inside the window")
    }

    func testPolicyRecoversOnceTheWindowSlides() {
        var p = EngineRestartPolicy(maxRestarts: 2, window: 10)
        XCTAssertTrue(p.allowRestart(now: 0))
        XCTAssertTrue(p.allowRestart(now: 1))
        XCTAssertFalse(p.allowRestart(now: 2))
        XCTAssertTrue(p.allowRestart(now: 10.5), "the first stamp (t=0) has aged out")
        XCTAssertFalse(p.allowRestart(now: 10.6), "t=1 and t=10.5 still count")
        XCTAssertTrue(p.allowRestart(now: 11.5), "t=1 aged out")
    }

    func testDefaultsAreGenerousEnoughForARealRouteChangeButFinite() {
        // One real route change costs one restart; a headset plugged then
        // unplugged costs two. Six in ten seconds is well past anything a
        // user does by hand, so it only ever trips on a genuine loop.
        var p = EngineRestartPolicy()
        for i in 0..<6 { XCTAssertTrue(p.allowRestart(now: Double(i))) }
        XCTAssertFalse(p.allowRestart(now: 6.5))
    }

    func testVoiceProcessingIsOnForEveryRoute() {
        // Build 55 skipped it on the loudspeaker (half-duplex then, and its
        // double-talk suppressor chops playback under near-end noise); since
        // build 69 the loudspeaker is full-duplex and the canceller is the
        // one thing that keeps the reply's echo out of the mic stream.
        XCTAssertTrue(VoiceAudioEngine.wantsVoiceProcessing(for: .speaker), "the loudspeaker too, since build 69: the echo canceller is what keeps the reply out of the mic stream")
        XCTAssertTrue(VoiceAudioEngine.wantsVoiceProcessing(for: .lowEcho))
        XCTAssertTrue(VoiceAudioEngine.wantsVoiceProcessing(for: VoiceRoute(portType: nil)), "no port info = the built-in speaker: still on")
        XCTAssertTrue(VoiceAudioEngine.wantsVoiceProcessing(for: VoiceRoute(portType: "Receiver")))
        XCTAssertTrue(VoiceAudioEngine.wantsVoiceProcessing(for: VoiceRoute(portType: "BluetoothHFP")))
    }

    func testAnEngineThatNeverStartedIgnoresConfigurationChangesAndShutsDownCleanly() {
        // Nothing is observed until the engine actually runs, so a stray
        // notification before start() must be a no-op: no restart, no capture
        // error, and shutdown() stays a safe no-op.
        let control = FakeAudioSessionControl()
        let engine = VoiceAudioEngine(sessionOwnership: .app, sessionControl: control)
        final class Counter: @unchecked Sendable { var n = 0 }
        let captureErrors = Counter()
        engine.onCaptureError = { captureErrors.n += 1 }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        engine.shutdown()
        XCTAssertEqual(engine.configurationRestarts, 0)
        XCTAssertEqual(captureErrors.n, 0)
        XCTAssertTrue(control.setActiveCalls.isEmpty, "never activated, so nothing to deactivate")
    }
}
