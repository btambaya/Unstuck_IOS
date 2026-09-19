// Barge-in state machine + RMS gate — pure, driven with a fake clock and
// scripted events / synthetic PCM. The 12 cases mirror the web
// lib/voice/barge-in.test.ts and Android BargeInControllerTest so the three
// platforms stay in lock-step (spec §9).

import XCTest
@testable import Unstuck

final class BargeInTests: XCTestCase {

    // MARK: helpers

    /// Commands minus the derived gate-context pushes (asserted separately).
    private func core(_ cmds: [BargeInCommand]) -> [BargeInCommand] {
        cmds.filter { if case .updateGate = $0 { return false } else { return true } }
    }

    /// The ENERGY confirm with the loudspeaker's timings (300 ms, +9 dB while
    /// playing), so the 2026-09-06 state-machine cases read unchanged. The
    /// shipped loudspeaker profile confirms by WORDS since 2026-09-19 (test
    /// 17); the energy path still ships on low-echo routes.
    static let energy = BargeInProfile.speaker.with(confirm: .energy)

    /// A controller mid-reply: response r1 created and its first audio queued.
    private func speaking(_ profile: BargeInProfile = energy, holdToTalk: Bool = false) -> BargeInController {
        var c = BargeInController(profile: profile, holdToTalk: holdToTalk)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.responseActive && c.playbackQueued)
        return c
    }

    private func count(_ cmds: [BargeInCommand], _ c: BargeInCommand) -> Int { cmds.filter { $0 == c }.count }

    // MARK: 1 — speech_started ducks synchronously, no cancel yet

    func test1_speechStartedDucksWithoutCancelling() {
        var c = speaking()
        let out = c.handle(.speechStarted(itemId: nil), now: 1.0)
        XCTAssertEqual(core(out), [.duck, .startConfirmTimer(ms: 300)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server))
        XCTAssertFalse(c.muted)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "audio keeps flowing (ducked) until confirmed")
    }

    // MARK: 2 — confirm needs BOTH the server's segment and a mic still above
    // the gate; the timer alone is a blip → restore (+ suppress what the
    // server will reply to). Ahmad's iPhone, 2026-09-17.

    func test2_confirmWithSustainedMicEnergyCancels() {
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.05)          // the mic agrees, and stays open
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server), "gate opening while ducked is bookkeeping only")
        XCTAssertEqual(core(c.handle(.tick, now: 1.2)), [], "before confirmMs nothing happens")
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(out, [.sendCancel, .flushPlayback, .restore, .clearCaption, .uiState(.listening)])
        XCTAssertTrue(c.muted)
        XCTAssertFalse(c.playbackQueued)
        XCTAssertEqual(c.cancelledResponseId, "r1")
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertFalse(c.acceptsTranscript(id: "r1"))
        // A second tick (stale timer) is a no-op.
        XCTAssertEqual(core(c.handle(.tick, now: 1.6)), [])
        XCTAssertEqual(count(c.handle(.tick, now: 2), .sendCancel), 0)
    }

    func test2b_serverBlipWithNoMicEnergyAtConfirmRestoresAndSuppresses() {
        // The loudspeaker case that cut every reply: the server VAD fired on
        // a tap, the gate had already closed again (or never opened), and
        // speech_stopped cannot arrive inside the window (600 ms of silence
        // first). The timer must NOT cancel.
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.02)
        _ = c.handle(.gateClose, now: 1.25)         // the tap ended; server still in its segment
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server), "a server duck waits for the tick")
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(out, [.restore])
        XCTAssertEqual(count(out, .sendCancel), 0)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the reply keeps playing")
        XCTAssertTrue(c.suppressNextResponse, "the server will still reply to the blip — that reply is cancelled on creation")
        XCTAssertEqual(c.falseBargeIns, 1)
        _ = c.handle(.speechStopped, now: 1.9)
        let created = core(c.handle(.responseCreated(id: "r2"), now: 2.0))
        XCTAssertEqual(created, [.sendCancel, .uiState(.speaking)], "the reply on air keeps playing; only the blip's reply is cancelled")
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"))
    }

    func test2c_gateOnlyDuckWithNoServerAgreementRestoresWithoutSuppression() {
        // Sustained mic energy the server never called speech (a fan, a
        // loud room): nothing was committed server-side, so restore and
        // suppress nothing.
        var c = speaking()
        _ = c.handle(.gateOpen, now: 1.0)
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .gate))
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(out, [.restore])
        XCTAssertFalse(c.suppressNextResponse)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.gateOpen, "the gate is still open; a later speech_started re-ducks and can then confirm")
        _ = c.handle(.speechStarted(itemId: nil), now: 2.0)
        XCTAssertEqual(c.state, .ducked(since: 2.0, trigger: .server))
        XCTAssertEqual(count(core(c.handle(.tick, now: 2.3)), .sendCancel), 1, "gate + server agree at confirm → real talk-over")
    }

    // MARK: 3 — speech_stopped inside confirm → restore, suppress the blip's reply

    func test3_blipRestoresAndSuppressesTheNextResponse() {
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        let out = core(c.handle(.speechStopped, now: 1.15))
        XCTAssertEqual(out, [.restore])
        XCTAssertTrue(c.suppressNextResponse)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(c.falseBargeIns, 1)
        // The late tick from that duck must not cancel anything.
        XCTAssertEqual(count(c.handle(.tick, now: 1.3), .sendCancel), 0)
        // The server replies to the blip → cancelled the moment it is created.
        let created = core(c.handle(.responseCreated(id: "r2"), now: 1.8))
        XCTAssertEqual(created, [.sendCancel, .uiState(.speaking)], "the reply on air keeps playing; only the blip's reply is cancelled")
        XCTAssertFalse(c.suppressNextResponse)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"), "deltas for the suppressed reply are dropped")
        XCTAssertFalse(c.acceptsTranscript(id: "r2"))
        // Its done clears responseActive; a fresh reply plays normally.
        _ = c.handle(.responseDone(id: "r2", status: "cancelled"), now: 1.9)
        XCTAssertFalse(c.responseActive)
        _ = c.handle(.responseCreated(id: "r3"), now: 2.0)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r3"))
    }

    // MARK: 4 — gate_close before confirm with no server agreement → restore only

    func test4_gateBlipRestoresWithoutSuppression() {
        var c = speaking()
        let ducked = core(c.handle(.gateOpen, now: 1.0))
        XCTAssertEqual(ducked, [.duck, .startConfirmTimer(ms: 300)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .gate))
        let out = core(c.handle(.gateClose, now: 1.12))
        XCTAssertEqual(out, [.restore])
        XCTAssertFalse(c.suppressNextResponse)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(count(c.handle(.tick, now: 1.3), .sendCancel), 0)
        // A gate duck the server AGREES with is speech → cancel at once.
        _ = c.handle(.gateOpen, now: 2.0)
        let agreed = core(c.handle(.speechStarted(itemId: nil), now: 2.05))
        XCTAssertEqual(count(agreed, .sendCancel), 1)
        XCTAssertTrue(agreed.contains(.flushPlayback))
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: 5 — transcription while ducked → immediate cancel

    func test5_transcriptionWhileDuckedCancelsImmediately() {
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.02)           // the mic agrees
        let out = core(c.handle(.transcription(text: "yes go ahead", itemId: nil), now: 1.1))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertTrue(c.muted)
        XCTAssertEqual(c.state, .idle)
    }

    func test5b_transcriptionWithTheMicClosedIsNotAConfirm() {
        // Deltas stream for the previous turn and for the model's own echo
        // (device log 2026-09-17); with the gate closed they confirm nothing.
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        XCTAssertFalse(c.gateOpen)
        XCTAssertEqual(core(c.handle(.transcription(text: "yes go ahead", itemId: nil), now: 1.1)), [])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server), "still waiting for the tick")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertEqual(core(c.handle(.tick, now: 1.3)), [.restore], "and the tick restores (no mic energy)")
    }

    // MARK: 6 — Interrupt = hard cancel, never ducks; flush-only on the tail; idle no-op

    func test6_interruptPressed() {
        var c = speaking()
        let out = core(c.handle(.interruptPressed, now: 1))
        XCTAssertFalse(out.contains(.duck))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertTrue(out.contains(.uiState(.listening)))
        XCTAssertEqual(c.state, .idle)

        // Only the buffered tail left (response.done already arrived).
        var tail = speaking()
        _ = tail.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        XCTAssertTrue(tail.playbackQueued); XCTAssertFalse(tail.responseActive)
        let tailOut = core(tail.handle(.interruptPressed, now: 2))
        XCTAssertEqual(count(tailOut, .sendCancel), 0, "nothing is generating — never cancel")
        XCTAssertTrue(tailOut.contains(.flushPlayback))
        XCTAssertFalse(tail.playbackQueued)

        var idle = BargeInController(profile: .speaker)
        XCTAssertEqual(core(idle.handle(.interruptPressed, now: 0)), [])
    }

    // MARK: 7 — "active response" errors are benign

    func test7_activeResponseErrorsAreBenign() {
        var c = speaking()
        _ = c.handle(.playbackDrained, now: 1)
        let out = core(c.handle(.benignActiveResponseError, now: 2))
        XCTAssertFalse(c.responseActive)
        XCTAssertEqual(out, [.uiState(.listening)])
        XCTAssertFalse(out.contains(.uiState(.error)))
        // While ducked: the gain comes back too.
        var d = speaking()
        _ = d.handle(.speechStarted(itemId: nil), now: 1)
        let ducked = core(d.handle(.benignActiveResponseError, now: 1.1))
        XCTAssertTrue(ducked.contains(.restore))
        XCTAssertEqual(d.state, .speaking, "audio is still queued")
    }

    // MARK: 8 — response.done keeps "speaking" while audio is queued

    func test8_responseDoneThenDrained() {
        var c = speaking()
        let done = core(c.handle(.responseDone(id: "r1", status: "completed"), now: 1))
        XCTAssertEqual(done, [.uiState(.speaking)])
        XCTAssertTrue(c.modelBusy, "Interrupt stays enabled through the tail")
        let drained = core(c.handle(.playbackDrained, now: 2))
        XCTAssertEqual(drained, [.uiState(.listening)])
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.modelBusy)
        // With no audio queued, done goes straight to listening.
        var t = BargeInController(profile: .speaker)
        _ = t.handle(.responseCreated(id: "r1"), now: 0)
        XCTAssertEqual(core(t.handle(.responseDone(id: "r1", status: "completed"), now: 1)), [.uiState(.listening)])
    }

    // MARK: 9 — cancelled-id deltas dropped even after a new response (interleaving)

    func test9_cancelledDeltasDroppedAfterNewResponse() {
        var c = speaking()
        _ = c.handle(.interruptPressed, now: 1)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"))
        _ = c.handle(.responseCreated(id: "r2"), now: 2)
        XCTAssertFalse(c.muted)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"), "late r1 delta after r2 started")
        XCTAssertFalse(c.acceptsTranscript(id: "r1"))
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
        XCTAssertTrue(c.acceptsTranscript(id: "r2"))
        // r1's own late done doesn't clobber r2's active flag.
        _ = c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.1)
        XCTAssertTrue(c.responseActive)
        // A response.created for the cancelled id is ignored outright.
        _ = c.handle(.responseDone(id: "r2", status: "completed"), now: 3)
        _ = c.handle(.responseCreated(id: "r1"), now: 4)
        XCTAssertFalse(c.responseActive)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"))
    }

    // MARK: 10 — RMS gate

    /// One 20 ms sub-frame at an exact RMS (square wave: RMS == amplitude).
    private func frame(amp: Int) -> [Int16] {
        let a = Int16(clamping: amp)
        return (0..<RMSGate.subFrameSamples).map { $0 % 2 == 0 ? a : -a }
    }
    private func amp(dbAbove floor: Float, _ delta: Float) -> Int {
        Int((32768 * pow(10, (floor + delta) / 20)).rounded())
    }
    private func bytes(_ f: [Int16]) -> Data { Data(bytes: f, count: f.count * 2) }

    func test10_gateCalibrationOpenHoldClosePreRollSilenceAndFrozenAdaptation() {
        var g = RMSGate()
        let quiet = frame(amp: 100)          // ≈ −50.3 dBFS
        let cough = frame(amp: 1000)         // +20 dB outlier inside calibration
        var out = RMSGate.Output()
        for i in 0..<RMSGate.calibrationFrames {
            out = g.push(i == 7 ? cough : quiet)
            XCTAssertTrue(out.pcm.isEmpty, "nothing is uploaded during calibration")
        }
        XCTAssertTrue(g.isCalibrated)
        let floor = g.floorDb
        XCTAssertEqual(floor, RMSGate.rmsDb(quiet[...]), accuracy: 0.01, "median ignores the outlier")
        XCTAssertFalse(g.isOpen)

        // Closed: digital silence of the same size, every sub-frame.
        for _ in 0..<5 {
            out = g.push(quiet)
            XCTAssertEqual(out.pcm.count, RMSGate.subFrameSamples * 2)
            XCTAssertEqual(out.pcm, Data(count: RMSGate.subFrameSamples * 2))
            XCTAssertEqual(out.silenceFrames, 1)
            XCTAssertFalse(out.opened)
        }

        // Opens at floor + 6 (+0.5 dB for Int16 quantisation) after 2 sub-frames.
        let loud = frame(amp: amp(dbAbove: floor, 6.5))
        out = g.push(loud)
        XCTAssertFalse(out.opened, "one loud sub-frame is not enough")
        XCTAssertEqual(out.silenceFrames, 1)
        out = g.push(loud)
        XCTAssertTrue(out.opened)
        XCTAssertTrue(g.isOpen)
        // Pre-roll (300 ms = 15 sub-frames, the first loud one last) then the live frame.
        let sub = RMSGate.subFrameSamples * 2
        XCTAssertEqual(out.pcm.count, (RMSGate.preRollFrames + 1) * sub)
        XCTAssertEqual(out.pcm.suffix(sub), bytes(loud), "live frame last")
        XCTAssertEqual(out.pcm.dropLast(sub).suffix(sub), bytes(loud), "the onset sub-frame is in the pre-roll")
        XCTAssertEqual(out.pcm.prefix(sub), bytes(quiet), "pre-roll is raw audio, not silence")
        XCTAssertEqual(out.silenceFrames, 0)

        // Stays open at floor + 4 (above closeDb = floor + 3).
        let hold = frame(amp: amp(dbAbove: floor, 4))
        for _ in 0..<30 {
            out = g.push(hold)
            XCTAssertEqual(out.pcm, bytes(hold))
            XCTAssertFalse(out.closed)
        }
        // Closes after 200 ms (10 sub-frames) below floor + 3; live audio until then.
        let low = frame(amp: amp(dbAbove: floor, 1))
        for i in 0..<RMSGate.holdFrames {
            out = g.push(low)
            XCTAssertEqual(out.pcm, bytes(low))
            XCTAssertEqual(out.closed, i == RMSGate.holdFrames - 1, "closed on sub-frame \(i)")
        }
        XCTAssertFalse(g.isOpen)
        out = g.push(low)
        XCTAssertEqual(out.silenceFrames, 1)

        // No adaptation while the model plays.
        g.context.freezeAdaptation = true
        let floorBefore = g.floorDb
        for _ in 0..<100 { _ = g.push(frame(amp: amp(dbAbove: floor, 2))) }
        XCTAssertEqual(g.floorDb, floorBefore)
        // Unfrozen: upward drift is capped (≤ 10 dB/min ⇒ ≤ 0.34 dB over 100 sub-frames).
        g.context.freezeAdaptation = false
        for _ in 0..<100 { _ = g.push(frame(amp: amp(dbAbove: floor, 2))) }
        XCTAssertGreaterThan(g.floorDb, floorBefore)
        XCTAssertLessThanOrEqual(g.floorDb - floorBefore, 0.34)
        // A quieter room pulls the floor down quickly.
        for _ in 0..<50 { _ = g.push(frame(amp: 20)) }
        XCTAssertLessThan(g.floorDb, floorBefore - 3)

        // Recalibration measures again (nothing uploaded meanwhile).
        g.recalibrate()
        XCTAssertFalse(g.isCalibrated)
        for _ in 0..<RMSGate.calibrationFrames { XCTAssertTrue(g.push(quiet).pcm.isEmpty) }
        XCTAssertTrue(g.isCalibrated)
    }

    func test10b_gateHoldToTalkAppendsNothingWhileReleased() {
        var g = RMSGate()
        g.context = GateContext(marginDb: 6, freezeAdaptation: false, forcedOpen: false, emitSilenceWhenClosed: false)
        let quiet = frame(amp: 100)
        for _ in 0..<RMSGate.calibrationFrames { _ = g.push(quiet) }
        XCTAssertTrue(g.push(quiet).pcm.isEmpty, "released: no silence, no audio")
        g.context.forcedOpen = true
        let out = g.push(quiet)
        XCTAssertTrue(out.opened)
        XCTAssertEqual(out.pcm.count, (RMSGate.preRollFrames + 1) * RMSGate.subFrameSamples * 2, "pre-roll + live")
        XCTAssertEqual(g.push(quiet).pcm, bytes(quiet))
        g.context.forcedOpen = false
        let rel = g.push(quiet)
        XCTAssertTrue(rel.closed)
        XCTAssertTrue(rel.pcm.isEmpty)
    }

    func test10c_gateHandlesArbitraryBufferSizes() {
        var g = RMSGate()
        let quiet = frame(amp: 100)
        // 683-sample buffers (48k→16k of a 2048 tap) — remainders carry over.
        var fed = 0; var frames = 0
        while frames < RMSGate.calibrationFrames + 5 {
            _ = g.push(Array((quiet + quiet + quiet).prefix(683)))
            fed += 683
            frames = fed / RMSGate.subFrameSamples
        }
        XCTAssertTrue(g.isCalibrated)
        XCTAssertEqual(RMSGate.rmsDb([Int16](repeating: 0, count: 320)[...]), -90)
    }

    // MARK: 11 — route change → new turn_detection + profile

    func test11_routeChangeReprofiles() {
        var c = BargeInController(profile: .speaker)
        XCTAssertEqual(c.profile.confirmMs, 300)
        XCTAssertEqual(c.turnDetection, TurnDetection(threshold: 0.6))
        let out = core(c.handle(.routeChanged(.lowEcho), now: 0))
        XCTAssertEqual(out, [.updateTurnDetection(TurnDetection(threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 600))])
        XCTAssertEqual(c.profile, .lowEcho)
        XCTAssertEqual(c.profile.confirmMs, 200)
        XCTAssertEqual(core(c.handle(.routeChanged(.lowEcho), now: 1)), [], "same profile → nothing re-sent")
        let json = TurnDetection.json(c.turnDetection) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "server_vad")
        XCTAssertEqual(json?["threshold"] as? Double, 0.5)
        XCTAssertEqual(json?["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(json?["silence_duration_ms"] as? Int, 600)
        // Speaker margin is +9 dB only while playing; low-echo stays +6.
        XCTAssertEqual(BargeInProfile.speaker.gateMarginDb(playing: true), 9)
        XCTAssertEqual(BargeInProfile.speaker.gateMarginDb(playing: false), 6)
        XCTAssertEqual(BargeInProfile.lowEcho.gateMarginDb(playing: true), 6)
        // Port mapping: only open speakers take the speaker profile.
        XCTAssertEqual(VoiceRoute(portType: "Speaker"), .speaker)
        XCTAssertEqual(VoiceRoute(portType: "Receiver"), .lowEcho)
        XCTAssertEqual(VoiceRoute(portType: "Headphones"), .lowEcho)
        XCTAssertEqual(VoiceRoute(portType: "BluetoothHFP"), .lowEcho)
        XCTAssertEqual(VoiceRoute(portType: "BluetoothA2DP"), .lowEcho)
        XCTAssertEqual(VoiceRoute(portType: nil), .speaker)
        // The gate context follows playback: +9 while queued on speaker, frozen
        // while busy — and never forced closed (full-duplex since 2026-09-19).
        var s = speaking()
        XCTAssertEqual(s.gateContext, GateContext(marginDb: 9, freezeAdaptation: true, forcedOpen: false, emitSilenceWhenClosed: true, forcedClosed: false))
        _ = s.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        let drained = s.handle(.playbackDrained, now: 2)
        XCTAssertTrue(drained.contains(.updateGate(GateContext(marginDb: 6, freezeAdaptation: false, forcedOpen: false, emitSilenceWhenClosed: true))))
    }

    // MARK: 12 — hold-to-talk

    func test12_holdToTalk() {
        var c = speaking(holdToTalk: true)
        XCTAssertNil(c.turnDetection)
        XCTAssertTrue(TurnDetection.json(c.turnDetection) is NSNull)
        XCTAssertFalse(c.gateContext.emitSilenceWhenClosed, "null mode needs no silence frames")
        let down = c.handle(.pttDown, now: 1)
        XCTAssertEqual(count(down, .sendCancel), 1)
        XCTAssertTrue(down.contains(.flushPlayback))
        XCTAssertEqual(c.state, .hold)
        XCTAssertTrue(c.gateContext.forcedOpen)
        XCTAssertTrue(down.contains(.updateGate(c.gateContext)))
        // Nothing the server VAD would send matters while held.
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: nil), now: 1.2)), [])
        XCTAssertEqual(core(c.handle(.interruptPressed, now: 1.3)), [])
        let up = c.handle(.pttUp, now: 2)
        XCTAssertTrue(up.contains(.commitAndRespond))
        XCTAssertFalse(c.gateContext.forcedOpen)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(core(c.handle(.pttUp, now: 3)), [], "release without press is a no-op")
        // server-vad mode ignores ptt entirely.
        var s = speaking()
        XCTAssertEqual(core(s.handle(.pttDown, now: 1)), [])
        XCTAssertEqual(s.state, .speaking)
        // Route changes in hold mode never re-send turn_detection (it stays null).
        XCTAssertEqual(core(c.handle(.routeChanged(.lowEcho), now: 4)), [])
    }
    // MARK: 13 — nothing to barge into: idle / listening no-ops

    func test13_idleEventsNeverDuckOrCancel() {
        var c = BargeInController(profile: .speaker)
        _ = c.initialGateContext()
        XCTAssertEqual(c.handle(.speechStarted(itemId: nil), now: 0), [], "normal turn-taking: no duck, no gate change")
        XCTAssertEqual(c.handle(.gateOpen, now: 0.1), [])
        XCTAssertEqual(c.handle(.speechStopped, now: 0.5), [])
        XCTAssertEqual(c.handle(.gateClose, now: 0.6), [])
        XCTAssertEqual(c.handle(.transcription(text: "yes go ahead", itemId: nil), now: 0.7), [])
        XCTAssertEqual(c.handle(.tick, now: 1), [])
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.suppressNextResponse)
        XCTAssertEqual(c.falseBargeIns, 0)
        // "Thinking" (response active, no audio yet) can be stopped before the
        // first delta too. On the loudspeaker that is by WORDS (speech alone
        // does nothing); on a low-echo route by energy, as before.
        _ = c.handle(.responseCreated(id: "r1"), now: 2)
        XCTAssertEqual(c.uiStateNow, .thinking)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: nil), now: 2.5)), [], "loudspeaker: no duck, no timer")
        let out = core(c.handle(.transcription(text: "no wait", itemId: "i1"), now: 2.8))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(c.state, .idle)

        var e = BargeInController(profile: .lowEcho)
        _ = e.initialGateContext()
        _ = e.handle(.responseCreated(id: "r1"), now: 2)
        XCTAssertEqual(core(e.handle(.speechStarted(itemId: nil), now: 2.5)), [.duck, .startConfirmTimer(ms: 200)])
        _ = e.handle(.gateOpen, now: 2.55)           // the mic agrees (confirm needs both sides)
        let eout = core(e.handle(.tick, now: 2.7))
        XCTAssertEqual(count(eout, .sendCancel), 1)
        XCTAssertEqual(e.state, .idle)
    }

    // MARK: 14 — the reply ends on its own while ducked

    func test14_responseDoneAndDrainedWhileDucked() {
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.02)           // the mic agrees (confirm needs both sides)
        // Generation finished mid-duck: still speaking (tail queued), still ducked.
        let done = core(c.handle(.responseDone(id: "r1", status: "completed"), now: 1.05))
        XCTAssertEqual(done, [.uiState(.speaking)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server))
        // Confirmed: only the tail is left → flush, no response.cancel.
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(count(out, .sendCancel), 0)
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertEqual(c.cancelledResponseId, "r1")
        XCTAssertEqual(c.state, .idle)

        // Tail drains during the duck: nothing left to cancel; restore on confirm.
        var d = speaking()
        _ = d.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = d.handle(.speechStarted(itemId: nil), now: 1.0)
        let drained = core(d.handle(.playbackDrained, now: 1.1))
        XCTAssertEqual(drained, [.uiState(.listening)])
        XCTAssertFalse(d.modelBusy)
        let confirm = core(d.handle(.tick, now: 1.3))
        XCTAssertEqual(count(confirm, .sendCancel), 0)
        XCTAssertTrue(confirm.contains(.restore))
        XCTAssertEqual(d.state, .idle)
    }

    // MARK: 15 — gate context is pushed only when it changes

    func test15_gateContextPushedOnlyOnChange() {
        var c = BargeInController(profile: .speaker)
        let initial = c.initialGateContext()
        XCTAssertEqual(initial, GateContext(marginDb: 6, freezeAdaptation: false, forcedOpen: false, emitSilenceWhenClosed: true))
        // response.created freezes adaptation (residual echo is about to start);
        // the mic stays open — the loudspeaker is full-duplex (2026-09-19).
        let created = c.handle(.responseCreated(id: "r1"), now: 0)
        XCTAssertTrue(created.contains(.updateGate(GateContext(marginDb: 6, freezeAdaptation: true, forcedOpen: false, emitSilenceWhenClosed: true, forcedClosed: false))))
        // First audio: +9 dB margin on the loudspeaker, still full-duplex.
        let delta = c.handle(.audioDelta(id: "r1"), now: 0.1)
        XCTAssertTrue(delta.contains(.updateGate(GateContext(marginDb: 9, freezeAdaptation: true, forcedOpen: false, emitSilenceWhenClosed: true, forcedClosed: false))))
        // A second delta changes nothing → no gate push.
        let again = c.handle(.audioDelta(id: "r1"), now: 0.2)
        XCTAssertFalse(again.contains { if case .updateGate = $0 { return true } else { return false } })
        // Low-echo route: the margin stays +6 while playing, full-duplex.
        _ = c.handle(.routeChanged(.lowEcho), now: 0.3)
        XCTAssertEqual(c.gateContext.marginDb, 6)
        XCTAssertFalse(c.gateContext.forcedClosed)
    }

    // MARK: 16 — the loudspeaker is FULL-duplex (2026-09-19): the mic is never
    // forced closed. Build 54 muted it for the whole reply because the phone
    // heard its own echo; interruptions are now confirmed by WORDS instead
    // (test 17), so the upload stays open and echo is discarded downstream.

    func test16_speakerIsFullDuplexNow() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        XCTAssertFalse(c.gateContext.forcedClosed, "generating: mic open")
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        XCTAssertFalse(c.gateContext.forcedClosed, "audible: mic open — talk-over on the loudspeaker")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        XCTAssertFalse(c.gateContext.forcedClosed)
        _ = c.handle(.playbackDrained, now: 1.5)
        XCTAssertFalse(c.gateContext.forcedClosed)
        // Hold-to-talk still forces the gate OPEN mid-reply.
        var h = BargeInController(profile: .speaker, holdToTalk: true)
        _ = h.handle(.responseCreated(id: "r1"), now: 0)
        _ = h.handle(.audioDelta(id: "r1"), now: 0.1)
        _ = h.handle(.pttDown, now: 0.2)
        XCTAssertFalse(h.gateContext.forcedClosed)
        XCTAssertTrue(h.gateContext.forcedOpen)
        // Low-echo never did force it closed.
        var e = BargeInController(profile: .lowEcho)
        _ = e.handle(.responseCreated(id: "r1"), now: 0)
        _ = e.handle(.audioDelta(id: "r1"), now: 0.1)
        XCTAssertFalse(e.gateContext.forcedClosed)

        // Gate: an open gate slams shut, uploads digital silence for as long
        // as it is forced, drops the pre-roll, and reopens on speech after.
        var g = RMSGate()
        let quiet = frame(amp: 100)
        for _ in 0..<RMSGate.calibrationFrames { _ = g.push(quiet) }
        let floor = g.floorDb
        let loud = frame(amp: amp(dbAbove: floor, 12))
        _ = g.push(loud); let opened = g.push(loud)
        XCTAssertTrue(opened.opened && g.isOpen)
        g.context.forcedClosed = true
        let slammed = g.push(loud)
        XCTAssertTrue(slammed.closed)
        XCTAssertFalse(g.isOpen)
        let sub = RMSGate.subFrameSamples * 2
        XCTAssertEqual(slammed.pcm, Data(count: sub), "silence, not the loud frame")
        for _ in 0..<10 {
            let o = g.push(loud)
            XCTAssertEqual(o.pcm, Data(count: sub))
            XCTAssertFalse(o.opened)
        }
        g.context.forcedClosed = false
        for _ in 0..<3 { _ = g.push(quiet) }        // post-reply room tone → the new pre-roll
        _ = g.push(loud); let reopened = g.push(loud)
        XCTAssertTrue(reopened.opened)
        XCTAssertEqual(reopened.pcm.count, 5 * sub, "pre-roll = 3 quiet + the onset frame, then the live frame — nothing from before the mute")
        XCTAssertEqual(reopened.pcm.prefix(sub), bytes(quiet))
    }

    // MARK: 17 — transcript-confirmed barge-in on the loudspeaker (2026-09-19).
    // Words decide: nothing ducks, no timer runs, echo is discarded, a cough
    // has no words. Echo cancellation with ducking off was tried on the
    // device (builds 37→54) and still let the echo cancel the reply; words
    // do not depend on acoustics.

    private func said(_ c: inout BargeInController, _ text: String) {
        _ = c.handle(.assistantTranscript(delta: text), now: 0.5)
    }

    func test17a_speakerNeverDucksOrArmsATimerOnSpeechOrGate() {
        var c = speaking(.speaker)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: nil), now: 1.0)), [], "the server VAD hears the loudspeaker's echo on every reply")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(core(c.handle(.gateOpen, now: 1.05)), [], "so does the gate — ducking on either would dim every reply")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(core(c.handle(.tick, now: 2.0)), [])
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    func test17b_echoOfTheReplyIsDiscardedAndTheServersReplyToItSuppressed() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        let out = core(c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "item-echo"), now: 1.4))
        XCTAssertEqual(count(out, .sendCancel), 0, "its own words are not an interruption")
        XCTAssertEqual(count(out, .flushPlayback), 0)
        XCTAssertTrue(out.contains(.deleteItem(id: "item-echo")), "the echo leaves the conversation so the model never sees its words as the user's")
        XCTAssertTrue(c.suppressNextResponse)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the real reply keeps playing")
        // The server answers its own echo → cancelled on creation, its audio dropped.
        let created = core(c.handle(.responseCreated(id: "r2"), now: 1.6))
        XCTAssertEqual(count(created, .sendCancel), 1)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"))
        // A late completed transcript of the same echo does not re-arm suppression
        // against the NEXT legitimate reply.
        _ = c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "item-echo"), now: 1.7)
        XCTAssertFalse(c.suppressNextResponse)
    }

    func test17c_realWordsOverTheReplyStopIt() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        let out = core(c.handle(.transcription(text: "actually make it before the gym", itemId: "item-1"), now: 1.4))
        XCTAssertEqual(out, [.sendCancel, .flushPlayback, .restore, .clearCaption, .uiState(.listening)])
        XCTAssertTrue(c.muted)
        XCTAssertFalse(c.playbackQueued)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.cancelledResponseId, "r1")
        XCTAssertFalse(out.contains(.deleteItem(id: "item-1")), "a real turn stays in the conversation")
    }

    func test17d_noWordsIsNotAnInterruption_andTheSegmentCountsAsABlip() {
        var c = speaking(.speaker)
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "…", itemId: "i"), now: 1.2)), [])
        XCTAssertEqual(core(c.handle(.transcription(text: "a", itemId: "i"), now: 1.2)), [], "one-letter tokens match everything and are dropped")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertFalse(c.suppressNextResponse)
        _ = c.handle(.speechStopped, now: 1.5)
        XCTAssertTrue(c.suppressNextResponse, "a segment with no words is a cough: the server's reply to it is a blip")
    }

    func test17e_blipSuppressesTheServersReply_lateRealWordsLiftItAndAskAgain() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.3)
        XCTAssertTrue(c.suppressNextResponse)
        _ = c.handle(.responseCreated(id: "r2"), now: 1.4)   // the server replies first
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"), "cancelled as a blip")
        // Then the words land and they are real: stop the old reply AND ask again,
        // because their turn's reply was already thrown away.
        let out = core(c.handle(.transcription(text: "no wait cancel that one", itemId: "i2"), now: 1.6))
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertTrue(out.contains(.createResponse), "their turn was cancelled as a suspected blip before its words arrived")
        XCTAssertFalse(c.suppressNextResponse)
        // The fresh reply plays.
        _ = c.handle(.responseCreated(id: "r3"), now: 1.8)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r3"))
    }

    func test17f_streamingWordsCancelOnce_theServersAnswerToThemIsKept() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: nil), now: 1.0)
        let first = core(c.handle(.transcription(text: "make it", itemId: "i3"), now: 1.2))
        XCTAssertEqual(count(first, .sendCancel), 1, "the first real words stop the reply")
        _ = c.handle(.speechStopped, now: 1.5)
        XCTAssertFalse(c.suppressNextResponse, "words were heard: the server's reply to them is wanted")
        _ = c.handle(.responseCreated(id: "r2"), now: 1.6)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
        // The completed transcript arrives after the answer started — no second cancel.
        let late = core(c.handle(.transcription(text: "make it before the gym", itemId: "i3"), now: 1.7))
        XCTAssertEqual(count(late, .sendCancel), 0)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
    }

    func test17g_lowEchoRouteStillConfirmsByEnergy() {
        var c = speaking(.lowEcho)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: nil), now: 1.0)), [.duck, .startConfirmTimer(ms: 200)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server))
    }

    func test17h_tokensAndEchoRule() {
        XCTAssertEqual(BargeInController.tokens("Taxi's at 7:45, after the GYM!"), ["taxi's", "at", "45", "after", "the", "gym"])
        var c = BargeInController(profile: .speaker)
        XCTAssertFalse(c.isEcho(BargeInController.tokens("after the gym")), "nothing said yet: nothing can be echo")
        said(&c, "Taxi's at quarter to eight, after the gym.")
        XCTAssertTrue(c.isEcho(BargeInController.tokens("after the gym")))
        XCTAssertTrue(c.isEcho(BargeInController.tokens("taxi at quarter to eight after gym")), "transcription drops words; 70 % is enough")
        XCTAssertFalse(c.isEcho(BargeInController.tokens("book the dentist")), "one shared word out of three is not echo")
        XCTAssertFalse(c.isEcho(BargeInController.tokens("stop")))
    }


    // MARK: 18 — the loop from Ahmad's phone, 2026-09-19 22:18, replayed
    // event for event from the device log. The greeting's echo was committed
    // as the user's turn and ANSWERED 10 ms before its transcript arrived;
    // the answer echoed and was answered; the assistant talked to itself.

    func test18a_theGreetingsEchoIsDeletedAndTheServersReplyToItCancelledBeforeItPlays() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 3.5)
        _ = c.handle(.audioDelta(id: "r1"), now: 3.6)
        said(&c, "Hey, just what's on your plate?")
        _ = c.handle(.gateOpen, now: 3.96)
        _ = c.handle(.speechStarted(itemId: "item_A"), now: 4.52)       // the echo, while r1 is on air
        for _ in 0..<8 { _ = c.handle(.transcription(text: "", itemId: "item_A"), now: 4.7) }   // DashScope's empty deltas
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 5.0)
        _ = c.handle(.playbackDrained, now: 5.24)                          // played=5 — the greeting finished
        XCTAssertEqual(c.state, .idle)
        _ = c.handle(.speechStopped, now: 6.22)
        XCTAssertFalse(c.suppressNextResponse, "nothing was busy when the segment ended")
        // 06.36: the server answers the echo as the user's turn.
        _ = c.handle(.responseCreated(id: "r2"), now: 6.36)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"), "not yet known to be an echo reply")
        // 06.376: its transcript lands — and it is the greeting.
        let out = core(c.handle(.transcription(text: "Hey, just what's on your plate?", itemId: "item_A"), now: 6.376))
        XCTAssertTrue(out.contains(.deleteItem(id: "item_A")), "the echo leaves the conversation")
        XCTAssertEqual(count(out, .sendCancel), 1, "the server's reply to its own echo is cancelled")
        XCTAssertEqual(count(out, .flushPlayback), 0, "nothing was playing")
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"), "\"Do small things.\" never plays")
        XCTAssertFalse(c.suppressNextResponse)
        // A real turn afterwards is answered normally.
        _ = c.handle(.responseCreated(id: "r3"), now: 9)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r3"))
    }

    func test18b_anEchoReplyAlreadyOnAirIsCutAndTheOriginalKeepsPlaying() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "item_B"), now: 1.0)          // echo of r1 while r1 streams
        _ = c.handle(.speechStopped, now: 1.8)
        XCTAssertTrue(c.suppressNextResponse, "no words yet: a blip until proven otherwise")
        _ = c.handle(.responseCreated(id: "r2"), now: 1.9)               // the server answers the echo
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"), "cancelled on creation")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the reply on air keeps streaming — it is not muted by the cancel")
        _ = c.handle(.audioDelta(id: "r1"), now: 2.0)
        XCTAssertTrue(c.playbackQueued)
        let out = core(c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "item_B"), now: 2.2))
        XCTAssertTrue(out.contains(.deleteItem(id: "item_B")))
        XCTAssertEqual(count(out, .sendCancel), 0, "already cancelled on creation; nothing to cancel twice")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    func test18c_anEchoReplyThatStartedPlayingIsFlushedMidAir() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Do small things.")
        _ = c.handle(.speechStarted(itemId: "item_C"), now: 0.4)          // echo begins while r1 is on air
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = c.handle(.playbackDrained, now: 0.9)
        XCTAssertEqual(c.state, .idle)
        _ = c.handle(.responseCreated(id: "r2"), now: 1.5)                // server answers the echo…
        _ = c.handle(.audioDelta(id: "r2"), now: 1.6)                      // …and it is already playing
        XCTAssertEqual(c.playingResponseId, "r2")
        let out = core(c.handle(.transcription(text: "do small things", itemId: "item_C"), now: 2.0))
        XCTAssertTrue(out.contains(.deleteItem(id: "item_C")))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(count(out, .flushPlayback), 1, "cut mid-air")
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r2"))
    }

    func test18d_theLateTranscriptOfTheQuestionThisReplyAnswersIsCaptionsOnly() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "item_Q"), now: 0)            // the user asks, while idle
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.responseCreated(id: "r1"), now: 1.2)
        _ = c.handle(.audioDelta(id: "r1"), now: 1.4)
        said(&c, "You have three things left today.")
        let out = core(c.handle(.transcription(text: "what have I got left today", itemId: "item_Q"), now: 1.6))
        XCTAssertEqual(out, [], "its segment began before the reply: never an interruption")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

}
