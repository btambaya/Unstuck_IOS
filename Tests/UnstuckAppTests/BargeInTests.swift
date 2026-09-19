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
    // the gate; the timer alone is a blip → restore. Ahmad's iPhone, 2026-09-17.

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

    func test2b_serverBlipWithNoMicEnergyAtConfirmRestores_andItsSegmentAnswersNothing() {
        // The loudspeaker case that cut every reply: the server VAD fired on
        // a tap, the gate had already closed again (or never opened), and
        // speech_stopped cannot arrive inside the window (600 ms of silence
        // first). The timer must NOT cancel.
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: "blip"), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.02)
        _ = c.handle(.gateClose, now: 1.25)         // the tap ended; server still in its segment
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server), "a server duck waits for the tick")
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(out, [.restore])
        XCTAssertEqual(count(out, .sendCancel), 0)
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the reply keeps playing")
        XCTAssertEqual(c.falseBargeIns, 1)
        _ = c.handle(.speechStopped, now: 1.9)
        // The server answers nothing by itself (create_response:false); the
        // segment's transcript has no words → its item goes, nothing is asked.
        XCTAssertEqual(core(c.handle(.transcription(text: "", itemId: "blip", final: true), now: 2.2)), [])
        XCTAssertEqual(c.pendingDeletes, ["blip"], "held until the next segment starts")
        XCTAssertFalse(c.pendingCreate)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    func test2c_gateOnlyDuckWithNoServerAgreementRestores() {
        // Sustained mic energy the server never called speech (a fan, a
        // loud room): nothing was committed server-side, so restore.
        var c = speaking()
        _ = c.handle(.gateOpen, now: 1.0)
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .gate))
        let out = core(c.handle(.tick, now: 1.3))
        XCTAssertEqual(out, [.restore])
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.gateOpen, "the gate is still open; a later speech_started re-ducks and can then confirm")
        _ = c.handle(.speechStarted(itemId: nil), now: 2.0)
        XCTAssertEqual(c.state, .ducked(since: 2.0, trigger: .server))
        XCTAssertEqual(count(core(c.handle(.tick, now: 2.3)), .sendCancel), 1, "gate + server agree at confirm → real talk-over")
    }

    // MARK: 3 — speech_stopped inside confirm → restore; the segment's WORDS
    // then decide whether anything is answered (the server never replies by
    // itself since build 66).

    func test3_blipRestores_thenNoWordsAnswersNothingAndRealWordsAreATurn() {
        var c = speaking()
        _ = c.handle(.speechStarted(itemId: "s1"), now: 1.0)
        let out = core(c.handle(.speechStopped, now: 1.15))
        XCTAssertEqual(out, [.restore])
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(c.falseBargeIns, 1)
        // The late tick from that duck must not cancel anything.
        XCTAssertEqual(count(c.handle(.tick, now: 1.3), .sendCancel), 0)
        // No words: a cough. Its item goes, nothing is asked, the reply plays on.
        XCTAssertEqual(core(c.handle(.transcription(text: "…", itemId: "s1", final: true), now: 1.5)), [])
        XCTAssertEqual(c.pendingDeletes, ["s1"], "held until the next segment starts")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertFalse(c.pendingCreate)
        // A second segment WITH words on a low-echo route is the user even
        // though the mic never confirmed it: stop the reply, answer once the
        // cancel has settled.
        _ = c.handle(.speechStarted(itemId: "s2"), now: 2.0)
        _ = c.handle(.speechStopped, now: 2.1)
        let words = core(c.handle(.transcription(text: "no wait, the other one", itemId: "s2", final: true), now: 2.4))
        XCTAssertEqual(count(words, .sendCancel), 1)
        XCTAssertTrue(words.contains(.flushPlayback))
        XCTAssertTrue(words.contains(.userTurn("no wait, the other one")))
        XCTAssertFalse(words.contains(.createResponse), "never in the same breath as the cancel")
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.7)), [.startConfirmTimer(ms: 500)], "settled, but the hold is not up")
        XCTAssertEqual(core(c.handle(.tick, now: 3.0)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(c.pendingCreate)
        _ = c.handle(.responseCreated(id: "r2"), now: 3.2)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
    }

    // MARK: 4 — gate_close before confirm with no server agreement → restore only

    func test4_gateBlipRestoresWithoutSuppression() {
        var c = speaking()
        let ducked = core(c.handle(.gateOpen, now: 1.0))
        XCTAssertEqual(ducked, [.duck, .startConfirmTimer(ms: 300)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .gate))
        let out = core(c.handle(.gateClose, now: 1.12))
        XCTAssertEqual(out, [.restore])
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
        let out = core(c.handle(.transcription(text: "yes go ahead", itemId: nil, final: false), now: 1.1))
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
        XCTAssertEqual(core(c.handle(.transcription(text: "yes go ahead", itemId: nil, final: false), now: 1.1)), [])
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
        XCTAssertEqual(json?["interrupt_response"] as? Bool, false, "the server never cuts a reply on its own VAD")
        XCTAssertEqual(json?["create_response"] as? Bool, false, "and never answers by itself")
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
    // MARK: 13 — nothing to barge into: idle / listening no-ops — and a plain
    // turn while idle is answered from its completed transcript (the client
    // creates every reply since build 66).

    func test13_idleEventsNeverDuckOrCancel_andAnIdleTurnIsAnswered() {
        var c = BargeInController(profile: .speaker)
        _ = c.initialGateContext()
        XCTAssertEqual(c.handle(.speechStarted(itemId: "q"), now: 0), [], "normal turn-taking: no duck, no gate change")
        XCTAssertEqual(c.handle(.gateOpen, now: 0.1), [])
        XCTAssertEqual(c.handle(.transcription(text: "yes go", itemId: "q", final: false), now: 0.4), [], "streaming words of an idle turn: nothing yet")
        XCTAssertEqual(c.handle(.speechStopped, now: 0.5), [])
        XCTAssertEqual(c.handle(.gateClose, now: 0.6), [])
        XCTAssertEqual(c.handle(.transcription(text: "yes go ahead", itemId: "q", final: true), now: 0.7),
                       [.userTurn("yes go ahead"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertEqual(c.handle(.transcription(text: "yes go ahead", itemId: "q", final: true), now: 0.8), [], "a re-sent completed transcript never asks twice")
        XCTAssertEqual(c.handle(.tick, now: 1), [], "300 ms after the transcript: the hold is not up")
        XCTAssertEqual(c.handle(.tick, now: 1.3), [.createResponse, .uiState(.thinking)])
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.falseBargeIns, 0)
        // "Thinking" (response active, no audio yet) can be stopped before the
        // first delta too. On the loudspeaker that is by WORDS (speech alone
        // does nothing); on a low-echo route by energy, as before.
        _ = c.handle(.responseCreated(id: "r1"), now: 2)
        XCTAssertEqual(c.uiStateNow, .thinking)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: "i1"), now: 2.5)), [], "loudspeaker: no duck, no timer")
        let out = core(c.handle(.transcription(text: "no wait", itemId: "i1", final: false), now: 2.8))
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
    // has no words. Since build 66 the server neither truncates nor answers by
    // itself: the client cancels on real words and creates the reply from the
    // segment's completed transcript.

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

    func test17b_echoOfTheReplyIsDiscardedAndAnswersNothing() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "item-echo"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.3)
        let out = core(c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "item-echo", final: true), now: 1.4))
        XCTAssertEqual(out, [], "its own words: out of the conversation, nothing asked, nothing shown")
        XCTAssertEqual(c.pendingDeletes, ["item-echo"], "held until the next segment starts")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the real reply keeps playing")
        XCTAssertFalse(c.pendingCreate)
        XCTAssertEqual(c.lastEchoScore.hits, 5, "content words only: taxi's, quarter, eight, after, gym")
        XCTAssertEqual(c.lastEchoScore.heard, 5)
    }

    func test17c_realWordsOverTheReplyStopIt_andAreAnsweredOnceTheCancelSettles() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "item-1"), now: 1.0)
        let out = core(c.handle(.transcription(text: "actually make it before the gym", itemId: "item-1", final: false), now: 1.4))
        XCTAssertEqual(out, [.sendCancel, .flushPlayback, .restore, .clearCaption, .uiState(.listening)])
        XCTAssertTrue(c.muted)
        XCTAssertFalse(c.playbackQueued)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.cancelledResponseId, "r1")
        _ = c.handle(.speechStopped, now: 2.0)
        let final = core(c.handle(.transcription(text: "actually make it before the gym", itemId: "item-1", final: true), now: 2.3))
        XCTAssertEqual(final, [.userTurn("actually make it before the gym"), .startConfirmTimer(ms: 500), .startConfirmTimer(ms: 2500), .uiState(.thinking)])
        XCTAssertFalse(final.contains(.deleteItem(id: "item-1")), "a real turn stays in the conversation")
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.6)), [.startConfirmTimer(ms: 500)])
        XCTAssertEqual(core(c.handle(.tick, now: 2.9)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r2"), now: 3.0)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
        XCTAssertFalse(c.pendingCreate)
    }

    func test17d_noWordsIsNotAnInterruption_andItsItemIsDeleted() {
        var c = speaking(.speaker)
        _ = c.handle(.speechStarted(itemId: "i"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "…", itemId: "i", final: false), now: 1.2)), [])
        XCTAssertEqual(core(c.handle(.transcription(text: "a", itemId: "i", final: false), now: 1.2)), [], "one-letter tokens match everything and are dropped")
        XCTAssertEqual(c.state, .speaking)
        _ = c.handle(.speechStopped, now: 1.5)
        XCTAssertEqual(core(c.handle(.transcription(text: "a", itemId: "i", final: true), now: 1.8)), [], "a cough: out, nothing asked")
        XCTAssertEqual(c.pendingDeletes, ["i"], "held until the next segment starts")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    func test17e_wordsThatLandAfterTheSegmentEndedStillStopTheReplyAndAreAnswered() {
        // The transcript only completes ~300 ms after speech_stopped; the
        // reply is still on air then.
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "i2"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.3)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "no words yet: the reply plays on")
        let out = core(c.handle(.transcription(text: "no wait cancel that one", itemId: "i2", final: true), now: 1.6))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertTrue(out.contains(.userTurn("no wait cancel that one")))
        XCTAssertFalse(out.contains(.createResponse))
        XCTAssertTrue(c.pendingCreate)
        _ = c.handle(.responseDone(id: "r1", status: "cancelled"), now: 1.9)
        XCTAssertTrue(c.pendingCreate, "settled, but held")
        XCTAssertEqual(core(c.handle(.tick, now: 2.2)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(c.pendingCreate)
        _ = c.handle(.responseCreated(id: "r3"), now: 2.2)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r3"))
    }

    func test17f_streamingWordsCancelOnce_theCompletedTranscriptAsksOnce() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "i3"), now: 1.0)
        XCTAssertEqual(count(core(c.handle(.transcription(text: "make it", itemId: "i3", final: false), now: 1.2)), .sendCancel), 0, "two words are not evidence yet")
        let first = core(c.handle(.transcription(text: "make it before", itemId: "i3", final: false), now: 1.3))
        XCTAssertEqual(count(first, .sendCancel), 1, "the first three real words stop the reply")
        XCTAssertEqual(count(core(c.handle(.transcription(text: "make it before the", itemId: "i3", final: false), now: 1.4)), .sendCancel), 0, "once")
        _ = c.handle(.speechStopped, now: 1.5)
        let done = core(c.handle(.transcription(text: "make it before the gym", itemId: "i3", final: true), now: 1.8))
        XCTAssertEqual(count(done, .sendCancel), 0)
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 1.9)), .createResponse), 0, "held")
        XCTAssertEqual(count(core(c.handle(.tick, now: 2.4)), .createResponse), 1)
        _ = c.handle(.responseCreated(id: "r2"), now: 2.2)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
        // The same completed transcript again never asks twice.
        XCTAssertEqual(core(c.handle(.transcription(text: "make it before the gym", itemId: "i3", final: true), now: 2.3)), [])
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
    }

    func test17g_lowEchoRouteStillConfirmsByEnergy() {
        var c = speaking(.lowEcho)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: nil), now: 1.0)), [.duck, .startConfirmTimer(ms: 200)])
        XCTAssertEqual(c.state, .ducked(since: 1.0, trigger: .server))
    }

    func test17h_tokensAndEchoRule() {
        XCTAssertEqual(BargeInController.tokens("Taxi's at 7:45, after the GYM!"), ["taxis", "at", "45", "after", "the", "gym"])
        var c = BargeInController(profile: .speaker)
        XCTAssertFalse(c.isEcho(BargeInController.tokens("after the gym")), "nothing said yet: nothing can be echo")
        said(&c, "Taxi's at quarter to eight, after the gym.")
        XCTAssertTrue(c.isEcho(BargeInController.tokens("after the gym")))
        XCTAssertTrue(c.isEcho(BargeInController.tokens("taxi at quarter to eight after gym")), "transcription drops words; 70 % is enough")
        XCTAssertFalse(c.isEcho(BargeInController.tokens("book the dentist")), "one shared word out of three is not echo")
        XCTAssertFalse(c.isEcho(BargeInController.tokens("stop")))
    }

    // MARK: 18 — the loop from Ahmad's phone, 2026-09-19 22:18, replayed from
    // the device log: the greeting's echo was committed as the user's turn
    // and answered; the answer echoed and was answered; the assistant talked
    // to itself. Since build 66 the server answers nothing by itself — the
    // echo is recognised by its words and deleted, and nothing is asked.

    func test18a_theGreetingsEchoIsDeletedAndNothingIsAsked() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 3.5)
        _ = c.handle(.audioDelta(id: "r1"), now: 3.6)
        said(&c, "Hey, just what's on your plate?")
        _ = c.handle(.gateOpen, now: 3.96)
        _ = c.handle(.speechStarted(itemId: "item_A"), now: 4.52)       // the echo, while r1 is on air
        for _ in 0..<8 { XCTAssertEqual(core(c.handle(.transcription(text: "", itemId: "item_A", final: false), now: 4.7)), []) }   // DashScope's empty deltas
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 5.0)
        _ = c.handle(.playbackDrained, now: 5.24)                          // the greeting finished
        XCTAssertEqual(c.state, .idle)
        _ = c.handle(.speechStopped, now: 6.22)
        let out = core(c.handle(.transcription(text: "Hey, just what's on your plate?", itemId: "item_A", final: true), now: 6.376))
        XCTAssertEqual(out, [], "the echo leaves the conversation; no reply, no caption")
        XCTAssertEqual(c.pendingDeletes, ["item_A"], "held until the next segment starts")
        XCTAssertFalse(c.pendingCreate)
        // A real turn afterwards is answered.
        _ = c.handle(.speechStarted(itemId: "item_Q"), now: 8)
        _ = c.handle(.speechStopped, now: 9)
        let q = core(c.handle(.transcription(text: "what have I got left today", itemId: "item_Q", final: true), now: 9.3))
        XCTAssertEqual(q, [.userTurn("what have I got left today"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertEqual(core(c.handle(.tick, now: 9.8)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r2"), now: 9.8)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
    }

    func test18b_echoWhileTheReplyStreamsIsDeleted_theReplyKeepsPlaying() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "item_B"), now: 1.0)          // echo of r1 while r1 streams
        XCTAssertEqual(core(c.handle(.speechStopped, now: 1.8)), [])
        _ = c.handle(.audioDelta(id: "r1"), now: 2.0)
        XCTAssertTrue(c.playbackQueued)
        let out = core(c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "item_B", final: true), now: 2.2))
        XCTAssertEqual(out, [])
        XCTAssertEqual(c.pendingDeletes, ["item_B"], "held until the next segment starts")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertEqual(c.state, .speaking)
    }

    func test18c_echoThatBeganOnAirAndCompletedAfterTheDrainIsStillEcho() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Do small things.")
        _ = c.handle(.speechStarted(itemId: "item_C"), now: 0.4)          // echo begins while r1 is on air
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = c.handle(.playbackDrained, now: 0.9)
        XCTAssertEqual(c.state, .idle)
        _ = c.handle(.speechStopped, now: 1.7)
        let out = core(c.handle(.transcription(text: "do small things", itemId: "item_C", final: true), now: 2.0))
        XCTAssertEqual(out, [])
        XCTAssertEqual(c.pendingDeletes, ["item_C"], "held until the next segment starts")
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.pendingCreate)
    }

    func test18d_theUsersQuestionIsAnsweredFromItsTranscript_neverTwice() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "item_Q"), now: 0)            // the user asks, while idle
        _ = c.handle(.speechStopped, now: 1.0)
        let out = core(c.handle(.transcription(text: "what have I got left today", itemId: "item_Q", final: true), now: 1.3))
        XCTAssertEqual(out, [.userTurn("what have I got left today"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r1"), now: 1.8)
        _ = c.handle(.audioDelta(id: "r1"), now: 2.0)
        said(&c, "You have three things left today.")
        // The same completed transcript again (a re-send) neither interrupts nor asks.
        XCTAssertEqual(core(c.handle(.transcription(text: "what have I got left today", itemId: "item_Q", final: true), now: 2.2)), [])
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    // MARK: 19 — the second phone test, 2026-09-19 22:39

    func test19a_theReplysTailEchoNeverEatsTheUsersNextTurn() {
        // 22:38:59 the reply's last words echoed after its audio drained;
        // 22:39:02 the user's real question. The echo answers nothing and
        // leaves nothing armed against the question.
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "I'm doing well. How about you?")
        _ = c.handle(.speechStarted(itemId: "echo"), now: 1.0)
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 1.2)
        _ = c.handle(.playbackDrained, now: 1.3)
        _ = c.handle(.speechStopped, now: 1.8)
        XCTAssertEqual(core(c.handle(.transcription(text: "How about you?", itemId: "echo", final: true), now: 1.9)), [])
        XCTAssertEqual(c.pendingDeletes, ["echo"], "held until the next segment starts")
        _ = c.handle(.speechStarted(itemId: "q"), now: 3.5)
        _ = c.handle(.speechStopped, now: 5.8)
        let q = core(c.handle(.transcription(text: "how is my day going to be tomorrow", itemId: "q", final: true), now: 6.1))
        XCTAssertTrue(q.contains(.startConfirmTimer(ms: 500)), "the question is answered once the hold is up")
        XCTAssertTrue(core(c.handle(.tick, now: 6.7)).contains(.createResponse))
        _ = c.handle(.responseCreated(id: "r2"), now: 6.5)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"), "the answer to the question plays")
    }

    func test19b_aCurlyApostropheDoesNotMakeAnEchoLookLikeRealWords() {
        var c = BargeInController(profile: .speaker)
        said(&c, "Tuesday’s wide open.")                          // the model, curly
        XCTAssertTrue(c.isEcho(BargeInController.tokens("Tuesday's wide open.")), "the transcriber, straight")
        XCTAssertEqual(BargeInController.tokens("Tuesday’s wide open."), ["tuesdays", "wide", "open"])
        XCTAssertEqual(BargeInController.tokens("I'm doing well."), ["im", "doing", "well"])
    }

    func test19c_theReplysTailEchoingAfterTheQueueDrainedIsStillEcho() {
        // 22:39:35.645 drained; 35.680 a segment began; it transcribed as the
        // reply's last words.
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Tuesday's wide open. Want to block something?")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 2.0)
        _ = c.handle(.playbackDrained, now: 3.0)
        _ = c.handle(.speechStarted(itemId: "tail"), now: 3.03)          // 30 ms after drain
        _ = c.handle(.speechStopped, now: 3.8)
        let out = core(c.handle(.transcription(text: "Want to block something?", itemId: "tail", final: true), now: 3.9))
        XCTAssertEqual(out, [], "the tail is echo, not a question from the user")
        XCTAssertEqual(c.pendingDeletes, ["tail"], "held until the next segment starts")
        XCTAssertFalse(c.pendingCreate)
        // Well after the grace window, the same words from the user are a turn.
        var d = BargeInController(profile: .speaker)
        _ = d.handle(.responseCreated(id: "r1"), now: 0)
        _ = d.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&d, "Want to block something?")
        _ = d.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = d.handle(.playbackDrained, now: 2)
        _ = d.handle(.speechStarted(itemId: "later"), now: 6)
        _ = d.handle(.speechStopped, now: 7)
        XCTAssertEqual(core(d.handle(.transcription(text: "want to block something", itemId: "later", final: true), now: 7.3)),
                       [.userTurn("want to block something"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
    }

    func test19d_aTranscriptWithNoLatinWordsIsNoiseNotAnInterruption() {
        XCTAssertEqual(BargeInController.tokens("嘿。"), [])
        XCTAssertEqual(BargeInController.tokens("你好吗？"), [])
        var c = speaking(.speaker)
        _ = c.handle(.speechStarted(itemId: "cn"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "你好吗？", itemId: "cn", final: false), now: 1.5)), [])
        _ = c.handle(.speechStopped, now: 1.7)
        XCTAssertEqual(core(c.handle(.transcription(text: "你好吗？", itemId: "cn", final: true), now: 2.0)), [],
                       "never shown as the user's words (Ahmad: \"then it just shows a Chinese phrase\")")
        XCTAssertEqual(c.pendingDeletes, ["cn"], "deleted once the next segment starts")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
    }

    // MARK: 20 — the client owns turn-taking (build 66, 2026-09-19). Measured
    // against the live proxy: with the defaults the server cancelled its own
    // reply the moment its VAD heard the loudspeaker's echo (status=cancelled,
    // reason=turn_detected); with interrupt_response and create_response off
    // it still segments + transcribes but never cuts or answers by itself; and
    // a response.create in the same breath as a response.cancel drops the
    // connection ("thread pool exhausted").

    func test20a_sessionTurnDetectionTurnsTheServersInterruptAndAutoReplyOff() {
        for profile in [BargeInProfile.speaker, .lowEcho] {
            let td = TurnDetection.serverVAD(profile)
            XCTAssertFalse(td.interruptResponse)
            XCTAssertFalse(td.createResponse)
            let json = TurnDetection.json(td) as? [String: Any]
            XCTAssertEqual(json?["type"] as? String, "server_vad")
            XCTAssertEqual(json?["interrupt_response"] as? Bool, false, "the server never cuts a reply on its own VAD")
            XCTAssertEqual(json?["create_response"] as? Bool, false, "and never answers by itself")
            XCTAssertEqual(json?["threshold"] as? Double, profile.threshold)
        }
        XCTAssertTrue(TurnDetection.json(nil) is NSNull, "hold-to-talk stays null")
    }

    func test20b_theReplyIsAskedOnlyAfterTheCancelledOnesDone() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.6)
        let out = core(c.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9))
        XCTAssertEqual(out, [.userTurn("no, book the dentist instead"), .sendCancel, .flushPlayback, .restore, .clearCaption, .uiState(.listening),
                             .startConfirmTimer(ms: 500), .startConfirmTimer(ms: 2500), .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"), "audio still in flight for the cancelled reply is dropped")
        // A late done for some OTHER id changes nothing.
        XCTAssertEqual(core(c.handle(.responseDone(id: "r0", status: "completed"), now: 2.0)), [])
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.2)), [.startConfirmTimer(ms: 500)], "settled 300 ms in: held")
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(c.pendingCreate)
        XCTAssertFalse(c.responseActive)
        _ = c.handle(.responseCreated(id: "r2"), now: 2.7)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"))
        XCTAssertFalse(c.muted)
    }

    func test20c_ifTheDoneNeverComesTheFallbackTickAsks_andTheInterruptButtonDropsAPendingAsk() {
        var c = speaking(.speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.6)
        _ = c.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9)
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [], "not yet")
        XCTAssertEqual(core(c.handle(.tick, now: 3.4)), [], "1.5 s: a done took 1.9 s once, with a tool call in flight")
        XCTAssertEqual(core(c.handle(.tick, now: 4.4)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(c.pendingCreate)
        XCTAssertFalse(c.responseActive)
        // "no active response" to our cancel = it had already finished: ask now.
        var e = speaking(.speaker)
        _ = e.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = e.handle(.speechStopped, now: 1.6)
        _ = e.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9)
        XCTAssertEqual(core(e.handle(.benignActiveResponseError, now: 2.0)), [.startConfirmTimer(ms: 500)], "nothing to wait for but the hold")
        XCTAssertEqual(core(e.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(e.pendingCreate)
        // Interrupt pressed while an ask is pending: the user wants silence.
        var i = speaking(.speaker)
        _ = i.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = i.handle(.speechStopped, now: 1.6)
        _ = i.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9)
        _ = i.handle(.interruptPressed, now: 2.0)
        XCTAssertFalse(i.pendingCreate)
        XCTAssertEqual(count(core(i.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.2)), .createResponse), 0)
    }

    func test20d_onlyTheTailLeft_realWordsFlushAndAskAtOnce() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)   // generated; audio still queued
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.6)
        let out = core(c.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9))
        XCTAssertEqual(count(out, .sendCancel), 0, "nothing is generating — never cancel")
        XCTAssertTrue(out.contains(.flushPlayback))
        XCTAssertTrue(out.contains(.startConfirmTimer(ms: 500)), "no done to wait for — only the hold")
        XCTAssertFalse(out.contains(.startConfirmTimer(ms: 2500)))
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
        XCTAssertFalse(c.pendingCreate)
        XCTAssertEqual(c.cancelledResponseId, "r1", "late audio for the flushed tail stays dropped")
    }

    func test20e_echoReferenceIsTheCurrentAndPreviousReplyOnly() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        said(&c, "Book the dentist tomorrow morning.")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = c.handle(.responseCreated(id: "r2"), now: 2)
        said(&c, "Taxi's at quarter to eight.")
        XCTAssertTrue(c.isEcho(BargeInController.tokens("book the dentist tomorrow morning")), "the previous reply can still echo")
        _ = c.handle(.responseDone(id: "r2", status: "completed"), now: 3)
        _ = c.handle(.responseCreated(id: "r3"), now: 4)
        said(&c, "Anything else?")
        XCTAssertFalse(c.isEcho(BargeInController.tokens("book the dentist tomorrow morning")), "two replies back: no longer echo")
        XCTAssertTrue(c.isEcho(BargeInController.tokens("taxi's at quarter to eight")))
        XCTAssertEqual(c.spokenPrevious, ["taxis", "at", "quarter", "to", "eight"])
        XCTAssertEqual(c.spokenCurrent, ["anything", "else"])
    }

    func test20f_lowEchoRoute_confirmedTalkOverIsAnsweredAfterTheCancelSettles() {
        var c = speaking(.lowEcho)
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.gateOpen, now: 1.02)
        XCTAssertEqual(count(core(c.handle(.tick, now: 1.2)), .sendCancel), 1, "energy confirms in 200 ms")
        XCTAssertEqual(c.state, .idle)
        _ = c.handle(.speechStopped, now: 2.0)
        let out = core(c.handle(.transcription(text: "actually make it before the gym", itemId: "u", final: true), now: 2.3))
        XCTAssertEqual(count(out, .sendCancel), 0, "already cancelled by the mic")
        XCTAssertTrue(out.contains(.userTurn("actually make it before the gym")))
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.5)), .createResponse), 0, "held")
        XCTAssertEqual(count(core(c.handle(.tick, now: 2.9)), .createResponse), 1)
    }

    func test20g_holdToTalk_theTranscriptIsCaptionOnly() {
        var c = speaking(holdToTalk: true)
        _ = c.handle(.pttDown, now: 1)
        _ = c.handle(.pttUp, now: 2)                     // commit + response.create already sent
        _ = c.handle(.responseCreated(id: "r2"), now: 2.3)
        let out = core(c.handle(.transcription(text: "book the dentist", itemId: "h", final: true), now: 2.4))
        XCTAssertEqual(out, [.userTurn("book the dentist")], "never cancels the reply it already asked for, never asks twice")
        XCTAssertTrue(c.responseActive)
        XCTAssertFalse(c.pendingCreate)
    }

    func test20h_aTranscriptWhoseSpeechWeNeverSawBeginNeverCutsAReply() {
        // The ASR of the question a reply is already answering can land after
        // the reply started (VoiceCaptionTests); a server may send no
        // speech_started at all. Caption only while on air; a turn when idle.
        var c = speaking(.speaker)
        said(&c, "You have three things left today.")
        let late = core(c.handle(.transcription(text: "what's on today", itemId: nil, final: true), now: 1.0))
        XCTAssertEqual(late, [.userTurn("what's on today")], "captioned, never cancelled, never asked again")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertFalse(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.transcription(text: "what's on", itemId: "x", final: false), now: 1.1)), [], "streaming words of an unknown segment: nothing")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 2)
        _ = c.handle(.playbackDrained, now: 3)
        XCTAssertEqual(core(c.handle(.transcription(text: "and tomorrow", itemId: nil, final: true), now: 4)),
                       [.userTurn("and tomorrow"), .startConfirmTimer(ms: 500), .uiState(.thinking)], "idle: a turn")
    }

    // MARK: 21 — the fourth phone test, 2026-09-19 23:50 (build 66): echo
    // handled, real turns answered, one genuine talk-over — and two SHORT
    // replies whose echo the transcriber garbled ("Saturday's clear" →
    // "Saturday's players", "Monday's open" → "Monday is open") scored 1/2
    // and 2/3 against a 70 % all-words rule, were taken for the user, cut the
    // reply and were answered again. Filler words are ignored, plurals and
    // possessives fold, a segment that began while the reply's AUDIO was on
    // air needs only half its content words to match, one in the drain grace
    // (only the tail can echo) needs more, and one that began while the model
    // was merely thinking is never echo.

    func test21a_garbledEchoOfAShortReplyIsStillEcho() {
        var c = speaking(.speaker)
        said(&c, "Monday's open.")
        _ = c.handle(.speechStarted(itemId: "a"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.8)
        XCTAssertEqual(core(c.handle(.transcription(text: "Monday is open.", itemId: "a", final: true), now: 1.9)), [])
        XCTAssertEqual(c.pendingDeletes, ["a"], "held until the next segment starts")
        XCTAssertEqual(c.lastEchoScore.hits, 2)
        XCTAssertEqual(c.lastEchoScore.heard, 2, "\"is\" carries nothing; Monday's and Monday fold")
        var d = speaking(.speaker)
        said(&d, "Saturday's clear.")
        _ = d.handle(.speechStarted(itemId: "b"), now: 1.0)
        XCTAssertEqual(core(d.handle(.transcription(text: "Saturday's players.", itemId: "b", final: true), now: 1.9)), [], "half the content words, on air: echo")
        XCTAssertEqual(d.pendingDeletes, ["b"], "held until the next segment starts")
        XCTAssertTrue(d.shouldEnqueueAudio(id: "r1"), "the reply plays on")
        XCTAssertEqual(d.state, .speaking)
    }

    func test21b_aRealTalkOverSharingOnlyFillerWordsIsStillReal() {
        var c = speaking(.speaker)
        said(&c, "I'm doing well. How about you?")
        _ = c.handle(.speechStarted(itemId: "q"), now: 1.0)
        let out = core(c.handle(.transcription(text: "How about Tuesday?", itemId: "q", final: true), now: 1.9))
        XCTAssertTrue(out.contains(.userTurn("How about Tuesday?")))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(c.lastEchoScore.hits, 0)
        XCTAssertEqual(c.lastEchoScore.heard, 1, "only \"tuesday\" carries content")
    }

    func test21c_inTheDrainGraceOnlyTheTailCanEcho() {
        // A follow-up sharing one topic word, right after the reply ended: a turn.
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Tuesday's wide open.")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = c.handle(.playbackDrained, now: 2)
        _ = c.handle(.speechStarted(itemId: "f"), now: 2.3)              // inside the grace window
        _ = c.handle(.speechStopped, now: 3.2)
        XCTAssertEqual(core(c.handle(.transcription(text: "Tuesday morning", itemId: "f", final: true), now: 3.4)),
                       [.userTurn("Tuesday morning"), .startConfirmTimer(ms: 500), .uiState(.thinking)], "1 of 2 content words in the grace window is not echo")
        // The tail itself, in the grace window, is.
        var t = BargeInController(profile: .speaker)
        _ = t.handle(.responseCreated(id: "r1"), now: 0)
        _ = t.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&t, "Tuesday's wide open.")
        _ = t.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = t.handle(.playbackDrained, now: 2)
        _ = t.handle(.speechStarted(itemId: "tail"), now: 2.05)
        XCTAssertEqual(core(t.handle(.transcription(text: "wide open.", itemId: "tail", final: true), now: 2.9)), [])
        XCTAssertEqual(t.pendingDeletes, ["tail"], "held until the next segment starts")
        // The same follow-up while that reply's audio was still on air would be echo.
        var d = speaking(.speaker)
        said(&d, "Tuesday's wide open.")
        _ = d.handle(.speechStarted(itemId: "g"), now: 1.0)
        XCTAssertEqual(core(d.handle(.transcription(text: "Tuesday morning", itemId: "g", final: true), now: 1.9)), [])
        XCTAssertEqual(d.pendingDeletes, ["g"], "held until the next segment starts")
    }

    func test21d_wordsWhileTheModelIsOnlyThinkingAreNeverEcho() {
        // The reply's transcript arrives ~1 s BEFORE its audio: the reference
        // already holds "Monday's open" while nothing has been said aloud.
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        said(&c, "Monday's open.")
        XCTAssertFalse(c.playbackQueued)
        _ = c.handle(.speechStarted(itemId: "k"), now: 0.5)
        _ = c.handle(.speechStopped, now: 1.3)
        let out = core(c.handle(.transcription(text: "Monday is open?", itemId: "k", final: true), now: 1.4))
        XCTAssertTrue(out.contains(.userTurn("Monday is open?")))
        XCTAssertEqual(count(out, .sendCancel), 1, "the user spoke over a thinking model: stop it, answer them")
        XCTAssertTrue(c.pendingCreate)
        // Streaming words in that state stop it early too.
        var d = BargeInController(profile: .speaker)
        _ = d.handle(.responseCreated(id: "r1"), now: 0)
        said(&d, "Monday's open.")
        _ = d.handle(.speechStarted(itemId: "m"), now: 0.5)
        XCTAssertEqual(count(core(d.handle(.transcription(text: "Monday is", itemId: "m", final: false), now: 0.9)), .sendCancel), 1)
    }

    func test21e_fillerOnlyUtterancesAreJudgedWhole() {
        var c = speaking(.speaker)
        said(&c, "Okay. How about you?")
        _ = c.handle(.speechStarted(itemId: "h"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "How about you?", itemId: "h", final: true), now: 1.9)), [])
        XCTAssertEqual(c.pendingDeletes, ["h"], "held until the next segment starts")
        var d = speaking(.speaker)
        said(&d, "Taxi's at quarter to eight.")
        _ = d.handle(.speechStarted(itemId: "i"), now: 1.0)
        XCTAssertEqual(count(core(d.handle(.transcription(text: "No!", itemId: "i", final: true), now: 1.9)), .sendCancel), 1, "a \"No!\" the model never said is an interruption")
    }

    func test21f_stemFoldsPluralsAndPossessives() {
        XCTAssertEqual(BargeInController.stem("mondays"), "monday")
        XCTAssertEqual(BargeInController.stem("players"), "player")
        XCTAssertEqual(BargeInController.stem("gym"), "gym")
        XCTAssertEqual(BargeInController.stem("was"), "was")
        XCTAssertEqual(BargeInController.tokens("Monday's open."), ["mondays", "open"], "tokens stay raw; folding happens at the comparison")
    }

    // MARK: 22 — the fifth phone test, 2026-09-20 00:04 (build 67): the
    // garbled-echo rule held ("How will this be like? You've got a few tasks
    // wrapped up" 4/5 → echo). Then the transcriber completed ONE segment in
    // two pieces — "Coming up on." (echo) and "Day." — and the fragment,
    // judged on its own, cut the reply; its own echo "And Friday." landed
    // 90 ms after the flush, outside any grace window, and was answered too.

    func test22a_aLaterPieceOfAnEchoSegmentIsStillEcho() {
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. You've got a few tasks wrapped up, and Friday coming up.")
        _ = c.handle(.speechStarted(itemId: "p"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "Coming up on.", itemId: "p", final: true), now: 1.9)), [])
        XCTAssertEqual(c.pendingDeletes, ["p"])
        XCTAssertEqual(core(c.handle(.transcription(text: "Day.", itemId: "p", final: true), now: 2.5)), [], "a fragment of the echo, not a turn")
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"), "the reply plays on")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(c.pendingDeletes, ["p"])
        XCTAssertEqual(core(c.handle(.transcription(text: "Day", itemId: "p", final: false), now: 2.6)), [], "nor do its streaming words cancel")
    }

    func test22b_theUsersQuestionInsideTheEchoSegmentIsKept() {
        // The reply ends; the user speaks before the VAD's 600 ms is up, so
        // the echo tail and the question share one segment and one item.
        var c = speaking(.speaker)
        said(&c, "You've got a few tasks wrapped up, and Friday coming up.")
        _ = c.handle(.speechStarted(itemId: "m"), now: 1.0)
        let whole = core(c.handle(.transcription(text: "Coming up on Friday. What about Monday?", itemId: "m", final: true), now: 2.4))
        XCTAssertTrue(whole.contains(.userTurn("Coming up on Friday. What about Monday?")), "three words after the last echoed word are the user's")
        XCTAssertEqual(count(whole, .sendCancel), 1)
        XCTAssertFalse(whole.contains(.deleteItem(id: "m")), "the item is theirs, echo prefix and all")
        XCTAssertEqual(c.pendingDeletes, [])
        // Or in pieces: the echo first, then the question for the SAME item.
        var d = speaking(.speaker)
        said(&d, "You've got a few tasks wrapped up, and Friday coming up.")
        _ = d.handle(.speechStarted(itemId: "n"), now: 1.0)
        XCTAssertEqual(core(d.handle(.transcription(text: "Coming up on Friday.", itemId: "n", final: true), now: 1.9)), [])
        XCTAssertEqual(d.pendingDeletes, ["n"], "held, not sent")
        let q = core(d.handle(.transcription(text: "What about Monday?", itemId: "n", final: true), now: 2.6))
        XCTAssertTrue(q.contains(.userTurn("What about Monday?")))
        XCTAssertEqual(count(q, .sendCancel), 1)
        XCTAssertEqual(d.pendingDeletes, [], "the held delete is dropped: the item is the user's turn")
        XCTAssertFalse(q.contains(.deleteItem(id: "n")))
    }

    func test22c_heldDeletesGoOutWhenTheNextSegmentStarts() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "e1"), now: 1.0)
        _ = c.handle(.transcription(text: "after the gym", itemId: "e1", final: true), now: 1.9)
        XCTAssertEqual(c.pendingDeletes, ["e1"])
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: "e2"), now: 2.5)), [.deleteItem(id: "e1")], "sent when the next segment begins")
        XCTAssertEqual(c.pendingDeletes, [])
        _ = c.handle(.transcription(text: "quarter to eight", itemId: "e2", final: true), now: 3.2)
        XCTAssertEqual(c.pendingDeletes, ["e2"])
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 3.5)
        _ = c.handle(.playbackDrained, now: 4.0)
        XCTAssertEqual(core(c.handle(.speechStarted(itemId: "u"), now: 6.0)), [.deleteItem(id: "e2")])
        XCTAssertEqual(core(c.handle(.transcription(text: "book the dentist", itemId: "u", final: true), now: 7.0)),
                       [.userTurn("book the dentist"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
    }

    func test22d_aFlushStartsTheEchoGraceWindow() {
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. Friday's coming up.")
        _ = c.handle(.speechStarted(itemId: "q"), now: 1.0)
        let cut = core(c.handle(.transcription(text: "What about Monday?", itemId: "q", final: true), now: 1.9))
        XCTAssertTrue(cut.contains(.flushPlayback))
        XCTAssertTrue(c.pendingCreate)
        // 90 ms later the flushed audio's last words come back through the mic.
        _ = c.handle(.speechStarted(itemId: "e"), now: 1.99)
        _ = c.handle(.speechStopped, now: 2.7)
        XCTAssertEqual(core(c.handle(.transcription(text: "And Friday.", itemId: "e", final: true), now: 2.8)), [], "echo of the flushed tail: no second cancel, no second ask")
        XCTAssertEqual(c.pendingDeletes, ["e"])
        XCTAssertTrue(c.pendingCreate, "the user's ask is still the one waiting")
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 3.0)), [.createResponse, .uiState(.thinking)], "hold up, server quiet, cancel settled")
    }

    func test22e_noWordsFirstThenWordsForTheSameItemIsATurn() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight.")
        _ = c.handle(.speechStarted(itemId: "w"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: ".", itemId: "w", final: true), now: 1.5)), [])
        XCTAssertEqual(c.pendingDeletes, ["w"])
        let words = core(c.handle(.transcription(text: "book the dentist instead", itemId: "w", final: true), now: 2.2))
        XCTAssertTrue(words.contains(.userTurn("book the dentist instead")))
        XCTAssertEqual(count(words, .sendCancel), 1)
        XCTAssertEqual(c.pendingDeletes, [], "never deleted: the words came")
    }

    // MARK: 23 — the same phone test: three interruptions "totally ignored
    // till it finished". On the loudspeaker a segment can only end when the
    // reply pauses, so a verdict at the end of the segment is a verdict after
    // the reply — and the user's words, first in the segment, were outscored
    // by the echo of what played after them ("How will this be like? You've
    // got a few tasks wrapped up" → 4/5). The transcriber's live guess grows
    // word by word from ~200 ms in; the reply is cut on it.

    func test23a_theUsersWordsFirstAndTheEchoAfterAreTheUsers() {
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. You've got a few tasks wrapped up, and Friday coming up.")
        _ = c.handle(.speechStarted(itemId: "o"), now: 1.0)
        let out = core(c.handle(.transcription(text: "How will this be like? You've got a few tasks wrapped up.", itemId: "o", final: true), now: 4.6))
        XCTAssertTrue(out.contains(.userTurn("How will this be like? You've got a few tasks wrapped up.")))
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(c.pendingDeletes, [])
    }

    func test23b_theLiveGuessCutsTheReplyWhileTheyAreStillTalking() {
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. You've got a few tasks wrapped up, and Friday coming up.")
        _ = c.handle(.speechStarted(itemId: "o"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "How", itemId: "o", final: false), now: 1.2)), [], "one word proves nothing")
        XCTAssertEqual(core(c.handle(.transcription(text: "How will this", itemId: "o", final: false), now: 1.5)), [], "filler only: could be anything")
        let cut = core(c.handle(.transcription(text: "How will this be like", itemId: "o", final: false), now: 1.9))
        XCTAssertEqual(count(cut, .sendCancel), 1, "\"like\" the model never said: theirs — cut now")
        XCTAssertTrue(cut.contains(.flushPlayback))
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(count(core(c.handle(.transcription(text: "How will this be like you've got", itemId: "o", final: false), now: 2.3)), .sendCancel), 0, "once")
        _ = c.handle(.speechStopped, now: 4.4)
        let final = core(c.handle(.transcription(text: "How will this be like? You've got a few tasks wrapped up.", itemId: "o", final: true), now: 4.6))
        XCTAssertTrue(final.contains(.userTurn("How will this be like? You've got a few tasks wrapped up.")))
        XCTAssertEqual(count(final, .sendCancel), 0)
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 4.9)), .createResponse), 0, "held")
        XCTAssertEqual(count(core(c.handle(.tick, now: 5.2)), .createResponse), 1)
    }

    func test23c_theLiveGuessOfAnEchoNeverCuts() {
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. You've got a few tasks wrapped up.")
        _ = c.handle(.speechStarted(itemId: "e"), now: 1.0)
        for guess in ["Looks", "Looks pretty", "Lucks pretty solid", "Looks pretty solid you've got", "Looks pretty solid. You've got a few"] {
            XCTAssertEqual(core(c.handle(.transcription(text: guess, itemId: "e", final: false), now: 1.5)), [], guess)
        }
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        _ = c.handle(.speechStopped, now: 2.6)
        XCTAssertEqual(core(c.handle(.transcription(text: "Looks pretty solid. You've got a few tasks wrapped up.", itemId: "e", final: true), now: 2.8)), [])
        XCTAssertEqual(c.pendingDeletes, ["e"])
        // A short real interruption is cut at three words: "How about Tuesday".
        var d = speaking(.speaker)
        said(&d, "I'm doing well. How about you?")
        _ = d.handle(.speechStarted(itemId: "q"), now: 1.0)
        XCTAssertEqual(core(d.handle(.transcription(text: "How about", itemId: "q", final: false), now: 1.3)), [])
        XCTAssertEqual(count(core(d.handle(.transcription(text: "How about Tuesday", itemId: "q", final: false), now: 1.6)), .sendCancel), 1)
    }

    func test23d_nothingSaidYetMeansAnyThreeWordsAreTheUsers() {
        // First reply, no reference yet, audio on air: the first three words
        // of a guess cut it (there is nothing they could be an echo of… except
        // the reply itself, whose transcript always precedes its audio).
        var c = speaking(.speaker)
        _ = c.handle(.speechStarted(itemId: "z"), now: 1.0)
        XCTAssertEqual(count(core(c.handle(.transcription(text: "Wait one", itemId: "z", final: false), now: 1.3)), .sendCancel), 0)
        XCTAssertEqual(count(core(c.handle(.transcription(text: "Wait one second", itemId: "z", final: false), now: 1.6)), .sendCancel), 1)
    }

    // MARK: 24 — the sixth phone test, 2026-09-20 00:25 (build 68): the live
    // guess cut two real talk-overs within a second and the held deletes
    // kept a question that shared its segment with the echo. Then: long
    // questions "kept tripping itself" — a pause mid-sentence ended the
    // segment, the fragment was answered, the continuation cancelled that and
    // got its own; "Alright" heard as "All right" (two unknown words) cut a
    // reply; the echo of "Is there anything…" caught mid-word as "Is there
    // any" cut another; "Have to go" cut on "go" alone.

    func test24a_aTurnIsHeldHalfASecondAndWhileTheyGoOnTalking() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "f1"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "Um. I can't remember.", itemId: "f1", final: true), now: 1.2)),
                       [.userTurn("Um. I can't remember."), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate)
        // They go on before the hold is up: nothing is asked.
        _ = c.handle(.speechStarted(itemId: "f2"), now: 1.5)
        XCTAssertEqual(core(c.handle(.tick, now: 1.7)), [], "still talking")
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [], "still talking")
        XCTAssertEqual(core(c.handle(.speechStopped, now: 3.0)), [.startConfirmTimer(ms: 500)])
        let rest = core(c.handle(.transcription(text: "you know, that I normally do in a week.", itemId: "f2", final: true), now: 3.2))
        XCTAssertEqual(rest, [.userTurn("you know, that I normally do in a week."), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertEqual(core(c.handle(.tick, now: 3.5)), [], "300 ms after the second piece")
        XCTAssertEqual(core(c.handle(.tick, now: 3.7)), [.createResponse, .uiState(.thinking)], "one ask, for both pieces")
        XCTAssertFalse(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.tick, now: 4.0)), [], "never twice")
        // A segment that ends WITHOUT a transcript still lets the ask through.
        var d = BargeInController(profile: .speaker)
        _ = d.handle(.speechStarted(itemId: "g1"), now: 0)
        _ = d.handle(.speechStopped, now: 1.0)
        _ = d.handle(.transcription(text: "what's on tomorrow", itemId: "g1", final: true), now: 1.2)
        _ = d.handle(.speechStarted(itemId: "g2"), now: 1.4)
        XCTAssertEqual(core(d.handle(.speechStopped, now: 2.0)), [.startConfirmTimer(ms: 500)])
        XCTAssertEqual(core(d.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
    }

    func test24b_theHoldAppliesAfterAnInterruptionToo() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight.")
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.6)
        _ = c.handle(.transcription(text: "no, I meant", itemId: "u", final: true), now: 1.9)
        XCTAssertTrue(c.pendingCreate)
        _ = c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.2)
        // They go on: "…the dentist, not the taxi" — the ask waits for it.
        _ = c.handle(.speechStarted(itemId: "v"), now: 2.3)
        XCTAssertEqual(core(c.handle(.tick, now: 2.4)), [])
        _ = c.handle(.speechStopped, now: 3.4)
        let rest = core(c.handle(.transcription(text: "the dentist, not the taxi", itemId: "v", final: true), now: 3.6))
        XCTAssertTrue(rest.contains(.userTurn("the dentist, not the taxi")))
        XCTAssertEqual(count(rest, .sendCancel), 0, "nothing is playing")
        XCTAssertEqual(core(c.handle(.tick, now: 4.1)), [.createResponse, .uiState(.thinking)])
    }

    func test24c_aHeardWordThatStartsASaidWordMatches() {
        // ("Alright" heard as "All right" is NOT this case — a-l-l is not the
        // start of a-l-r-i-g-h-t. That one is left to echo cancellation: no
        // amount of text matching will cover every way a transcriber can
        // render an echo, which is why the loudspeaker runs voice processing
        // again since build 69.)
        var c = speaking(.speaker)
        said(&c, "Alright. Not much else on my end. Is there anything you'd like to do?")
        _ = c.handle(.speechStarted(itemId: "b"), now: 2.5)
        XCTAssertEqual(core(c.handle(.transcription(text: "Is there any", itemId: "b", final: false), now: 2.9)), [], "\"any\" is \"anything\" cut short: no cut")
        XCTAssertEqual(c.state, .speaking)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r1"))
        XCTAssertFalse(c.isEcho(BargeInController.tokens("on Monday")), "two letters never match by prefix")
        var d = speaking(.speaker)
        said(&d, "Monday's open.")
        XCTAssertTrue(d.isEcho(BargeInController.tokens("Mon"), onAir: true), "three do")
    }

    func test24d_aTwoLetterWordIsNoEvidenceForAnEarlyCut() {
        var c = speaking(.speaker)
        said(&c, "Looks solid. A few things to get through this week.")
        _ = c.handle(.speechStarted(itemId: "h"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "Have to go", itemId: "h", final: false), now: 1.4)), [], "\"go\" alone proves nothing")
        XCTAssertEqual(core(c.handle(.transcription(text: "Have to go through", itemId: "h", final: false), now: 1.6)), [], "\"through\" the model said")
        XCTAssertEqual(count(core(c.handle(.transcription(text: "Have to go through Friday", itemId: "h", final: false), now: 1.9)), .sendCancel), 1, "\"friday\" it never said")
    }

}
