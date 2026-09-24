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
        XCTAssertEqual(out, [.sendCancel, .truncatePlayback(generating: true), .flushPlayback, .restore, .clearCaption, .uiState(.listening)])
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
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates (2026-09-20)")
        _ = c.handle(.responseCreated(id: "r2"), now: 3.2)
        XCTAssertFalse(c.pendingCreate)
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

        // Nothing to cut: the label is simply Listening (C46 — it used to stay
        // on whatever it showed, "Thinking…" through a rate-limit wait).
        var idle = BargeInController(profile: .speaker)
        XCTAssertEqual(core(idle.handle(.interruptPressed, now: 0)), [.uiState(.listening)])
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
        XCTAssertEqual(out, [.sendCancel, .truncatePlayback(generating: true), .flushPlayback, .restore, .clearCaption, .uiState(.listening)])
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
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates")
        _ = c.handle(.responseCreated(id: "r3"), now: 2.2)
        XCTAssertFalse(c.pendingCreate)
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

    func test19c_theReplysWordsAfterTheQueueDrainedAreTheUsers() {
        // 22:39:35.645 drained; 35.680 a segment began; it transcribed as the
        // reply's last words — before echo cancellation came back (build 69).
        // Since then no tail echo has reached the transcriber, and the user's
        // answers in that window were being deleted ("Have you set up the
        // call?", 2026-09-20 15:36): after the drain the words are theirs.
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Tuesday's wide open. Want to block something?")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 2.0)
        _ = c.handle(.playbackDrained, now: 3.0)
        _ = c.handle(.speechStarted(itemId: "tail"), now: 3.03)          // 30 ms after drain
        _ = c.handle(.speechStopped, now: 3.8)
        let out = core(c.handle(.transcription(text: "Want to block something?", itemId: "tail", final: true), now: 3.9))
        XCTAssertEqual(out, [.userTurn("Want to block something?"), .startConfirmTimer(ms: 500), .uiState(.thinking)], "after the drain: a turn, never judged by its words")
        XCTAssertEqual(c.pendingDeletes, [])
        XCTAssertTrue(c.pendingCreate)
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
        XCTAssertEqual(out, [.userTurn("no, book the dentist instead"), .sendCancel, .truncatePlayback(generating: true), .flushPlayback, .restore, .clearCaption, .uiState(.listening),
                             .startConfirmTimer(ms: 500), .startConfirmTimer(ms: 2500), .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate)
        XCTAssertFalse(c.shouldEnqueueAudio(id: "r1"), "audio still in flight for the cancelled reply is dropped")
        // A late done for some OTHER id changes nothing.
        XCTAssertEqual(core(c.handle(.responseDone(id: "r0", status: "completed"), now: 2.0)), [])
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 2.2)), [.startConfirmTimer(ms: 500)], "settled 300 ms in: held")
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates")
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
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates")
        XCTAssertFalse(c.responseActive)
        // "no active response" to our cancel = it had already finished: ask now.
        var e = speaking(.speaker)
        _ = e.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = e.handle(.speechStopped, now: 1.6)
        _ = e.handle(.transcription(text: "no, book the dentist instead", itemId: "u", final: true), now: 1.9)
        XCTAssertEqual(core(e.handle(.benignActiveResponseError, now: 2.0)), [.startConfirmTimer(ms: 500)], "nothing to wait for but the hold")
        XCTAssertEqual(core(e.handle(.tick, now: 2.5)), [.createResponse, .uiState(.thinking)])
        XCTAssertTrue(e.pendingCreate, "asked for; pending until the server creates")
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
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates")
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
        // Even the tail itself, in the grace window, is theirs now (2026-09-20:
        // echo cancellation removes it; the user's short answers were dying).
        var t = BargeInController(profile: .speaker)
        _ = t.handle(.responseCreated(id: "r1"), now: 0)
        _ = t.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&t, "Tuesday's wide open.")
        _ = t.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = t.handle(.playbackDrained, now: 2)
        _ = t.handle(.speechStarted(itemId: "tail"), now: 2.05)
        XCTAssertEqual(core(t.handle(.transcription(text: "wide open.", itemId: "tail", final: true), now: 2.9)),
                       [.userTurn("wide open."), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertEqual(t.pendingDeletes, [])
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

    func test22d_wordsAfterAFlushAreTheUsersAndRideWithTheirAsk() {
        // Before echo cancellation came back, the flushed audio's last words
        // came back through the mic 90 ms after a flush ("And Friday.",
        // device log 2026-09-20 00:04:43). Since build 69 nothing after the
        // drain is judged by its words: a segment there is the user's, it
        // never cancels twice, and the one pending ask covers it.
        var c = speaking(.speaker)
        said(&c, "Looks pretty solid. Friday's coming up.")
        _ = c.handle(.speechStarted(itemId: "q"), now: 1.0)
        let cut = core(c.handle(.transcription(text: "What about Monday?", itemId: "q", final: true), now: 1.9))
        XCTAssertTrue(cut.contains(.flushPlayback))
        XCTAssertTrue(c.pendingCreate)
        _ = c.handle(.speechStarted(itemId: "e"), now: 1.99)
        _ = c.handle(.speechStopped, now: 2.7)
        let more = core(c.handle(.transcription(text: "And Friday.", itemId: "e", final: true), now: 2.8))
        XCTAssertTrue(more.contains(.userTurn("And Friday.")))
        XCTAssertEqual(count(more, .sendCancel), 0, "the reply is already cancelled — never twice")
        XCTAssertEqual(c.pendingDeletes, [])
        XCTAssertTrue(c.pendingCreate, "one ask, held from their last words")
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "cancelled"), now: 3.0)), [.startConfirmTimer(ms: 500)], "cancel settled; the hold since 2.8 is not up")
        XCTAssertEqual(core(c.handle(.tick, now: 3.4)), [.createResponse, .uiState(.thinking)])
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

    // MARK: 24 — Ahmad's call-booking session, 2026-09-20 15:21–15:37
    // (assistant_turns): three real utterances deleted as echo of the question
    // they answered, zero true echoes caught since echo cancellation came back.
    // The verdict now: only a segment that began ON AIR is judged by its
    // words; four words or more must be verbatim; after the drain it is theirs.

    func test24a_answeringOverTheReplyInItsOwnWordsIsTheUsersTurn() {
        var c = speaking(.speaker)
        said(&c, "I can't set a reminder without a call being booked first. Shall I schedule a task to remind you, or would you like me to book a quick call now?")
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)               // on air
        _ = c.handle(.speechStopped, now: 2.2)
        let out = core(c.handle(.transcription(text: "Book the cool call now.", itemId: "u", final: true), now: 2.4))
        XCTAssertTrue(out.contains(.userTurn("Book the cool call now.")), "3 of 4 content words, but 5 words with one the model never said: theirs")
        XCTAssertEqual(count(out, .sendCancel), 1, "their words stop the reply")
        XCTAssertFalse(out.contains(.deleteItem(id: "u")))
        XCTAssertEqual(c.pendingDeletes, [])
    }

    func test24b_aQuestionRightAfterTheReplyEndsIsNeverEcho() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&c, "Got it, I'll set that up now. What's the call about?")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 1.5)
        _ = c.handle(.playbackDrained, now: 3.0)
        _ = c.handle(.speechStarted(itemId: "q"), now: 3.3)               // in the grace: both content words are the reply's
        _ = c.handle(.speechStopped, now: 4.6)
        XCTAssertEqual(core(c.handle(.transcription(text: "Have you set up the call?", itemId: "q", final: true), now: 4.8)),
                       [.userTurn("Have you set up the call?"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertEqual(c.pendingDeletes, [])
        // The test call's opening, answered with the one word it ended on.
        var d = BargeInController(profile: .speaker)
        _ = d.handle(.responseCreated(id: "r1"), now: 0)
        _ = d.handle(.audioDelta(id: "r1"), now: 0.1)
        said(&d, "Hi — this is your test call from Unstuck. Everything works. Want to try something — ask me what's on today?")
        _ = d.handle(.responseDone(id: "r1", status: "completed"), now: 2)
        _ = d.handle(.playbackDrained, now: 7)
        _ = d.handle(.speechStarted(itemId: "w"), now: 7.6)
        _ = d.handle(.speechStopped, now: 8.4)
        XCTAssertEqual(core(d.handle(.transcription(text: "What is today?", itemId: "w", final: true), now: 8.6)),
                       [.userTurn("What is today?"), .startConfirmTimer(ms: 500), .uiState(.thinking)])
    }

    func test24c_fourWordsOrMoreOnAirAreEchoOnlyWhenVerbatim() {
        var c = speaking(.speaker)
        said(&c, "You've got a few tasks wrapped up, and Friday coming up.")
        _ = c.handle(.speechStarted(itemId: "e"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "Coming up on Friday", itemId: "e", final: true), now: 1.9)), [], "every word the model's: echo")
        XCTAssertEqual(c.pendingDeletes, ["e"])
        var d = speaking(.speaker)
        said(&d, "You've got a few tasks wrapped up, and Friday coming up.")
        _ = d.handle(.speechStarted(itemId: "u"), now: 1.0)
        let out = core(d.handle(.transcription(text: "Coming up on Sunday", itemId: "u", final: true), now: 1.9))
        XCTAssertTrue(out.contains(.userTurn("Coming up on Sunday")), "one word the model never said: theirs")
        XCTAssertEqual(count(out, .sendCancel), 1)
        // Three words or fewer keep the content-word scoring: a garble is echo.
        var g = speaking(.speaker)
        said(&g, "Saturday's clear.")
        _ = g.handle(.speechStarted(itemId: "b"), now: 1.0)
        XCTAssertEqual(core(g.handle(.transcription(text: "Saturday's players.", itemId: "b", final: true), now: 1.9)), [])
        XCTAssertEqual(g.pendingDeletes, ["b"])
    }

    // MARK: 25 — a create the server swallowed (Zubair's call, 2026-09-20
    // 18:02: a cancel went unanswered, the fallback create produced nothing,
    // the muted reply completed, his "Yes." was never answered — 20 s of
    // silence). The turn now stays pending until response.created.

    func test25a_theTurnStaysPendingUntilTheServerCreates() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        XCTAssertEqual(core(c.handle(.tick, now: 1.8)), [.createResponse, .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate, "asked for, not yet created")
        XCTAssertEqual(c.createSentAt, 1.8)
        XCTAssertEqual(core(c.handle(.tick, now: 2.5)), [.startConfirmTimer(ms: 2301)], "in flight: no second create, a timer for the rest of the grace")
        _ = c.handle(.responseCreated(id: "r1"), now: 2.6)
        XCTAssertFalse(c.pendingCreate)
        XCTAssertNil(c.createSentAt)
        XCTAssertEqual(core(c.handle(.tick, now: 5.0)), [], "nothing pending once created")
    }

    func test25b_aSwallowedFallbackCreateIsReaskedWhenTheActiveReplyFinishes() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)                 // the results reply: thinking, no audio yet
        _ = c.handle(.speechStarted(itemId: "y"), now: 0.4)
        _ = c.handle(.speechStopped, now: 0.9)
        let turn = core(c.handle(.transcription(text: "Yes.", itemId: "y", final: true), now: 1.0))
        XCTAssertEqual(count(turn, .sendCancel), 1)
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.tick, now: 1.5)), [], "waiting for the cancelled done")
        XCTAssertEqual(core(c.handle(.tick, now: 3.6)), [.createResponse, .uiState(.thinking)], "no done, no error: the 2.5 s fallback asks")
        XCTAssertTrue(c.pendingCreate, "still pending: nothing was created")
        // The server swallowed the create AND the cancel: the reply completes, muted.
        XCTAssertEqual(core(c.handle(.responseDone(id: "r1", status: "completed"), now: 4.0)), [.createResponse, .uiState(.thinking)], "re-asked at once — hold long up, server quiet")
        _ = c.handle(.responseCreated(id: "r2"), now: 4.5)
        XCTAssertFalse(c.pendingCreate)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"), "the answer to \"Yes.\" plays")
    }

    func test25c_aCreateSwallowedWhileIdleIsResentAfterTheGrace() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        XCTAssertEqual(core(c.handle(.tick, now: 1.8)), [.createResponse, .uiState(.thinking)])
        XCTAssertEqual(core(c.handle(.tick, now: 2.0)), [.startConfirmTimer(ms: 2801)])
        XCTAssertEqual(core(c.handle(.tick, now: 4.9)), [.createResponse, .uiState(.thinking)], "nothing came in 3 s: ask again")
        // "Already has an active response" to that re-send: a reply IS
        // generating (the first create's, its response.created lost). Re-asking
        // at once met the same refusal at network speed until it ended (audit
        // 2026-09-22, C46): wait for its done — or, if that never comes, the
        // grace.
        let complaint = core(c.handle(.responseAlreadyActive, now: 5.0))
        XCTAssertEqual(count(complaint, .createResponse), 0, "no create into the same refusal: \(complaint)")
        XCTAssertTrue(c.responseActive, "something is generating")
        XCTAssertTrue(complaint.contains(.startConfirmTimer(ms: 3000)))
        XCTAssertEqual(core(c.handle(.tick, now: 5.5)), [.startConfirmTimer(ms: 2401)], "the refused create's grace first")
        XCTAssertTrue(c.responseActive, "not presumed lost inside the grace")
        XCTAssertEqual(core(c.handle(.responseDone(id: "rX", status: "completed"), now: 6.0)), [.createResponse, .uiState(.thinking)],
                       "its done re-asks the turn")
        // Its done never comes: asked again once the grace is out — one create
        // per grace, not one per round trip.
        var g = BargeInController(profile: .speaker)
        _ = g.handle(.speechStarted(itemId: "u"), now: 0)
        _ = g.handle(.speechStopped, now: 1.0)
        _ = g.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        _ = g.handle(.tick, now: 1.8)
        _ = g.handle(.responseAlreadyActive, now: 1.9)
        XCTAssertEqual(count(core(g.handle(.tick, now: 4.0)), .createResponse), 0)
        XCTAssertEqual(core(g.handle(.tick, now: 4.9)), [.createResponse, .uiState(.thinking)])
    }

    // MARK: 26 — a rate-limited reply (OpenAI: the token bucket ran dry;
    // Ahmad's 2026-09-20 23:48 session went silent) is asked for again after
    // the bucket's reset, three times at most.

    func test26a_aRateLimitedReplyIsReaskedAfterTheReset() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        XCTAssertEqual(core(c.handle(.tick, now: 1.8)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r1"), now: 2.0)
        XCTAssertFalse(c.pendingCreate)
        let out = core(c.handle(.responseRateLimited(retryAfterMs: 7000), now: 2.3))
        XCTAssertEqual(out, [.startConfirmTimer(ms: 7000), .uiState(.thinking)], "the turn is pending again; the tick after the reset asks")
        XCTAssertTrue(c.pendingCreate)
        XCTAssertFalse(c.responseActive)
        XCTAssertEqual(c.rateLimitRetries, 1)
        XCTAssertEqual(core(c.handle(.tick, now: 9.4)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r2"), now: 9.6)
        _ = c.handle(.audioDelta(id: "r2"), now: 9.7)
        XCTAssertTrue(c.shouldEnqueueAudio(id: "r2"), "the retried reply plays")
        _ = c.handle(.responseDone(id: "r2", status: "completed"), now: 12)
        XCTAssertEqual(c.rateLimitRetries, 0, "a completed reply clears the count")
    }

    func test26b_afterThreeRateLimitedRetriesTheTurnIsDropped() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        _ = c.handle(.tick, now: 1.8)
        var t = 2.0
        for i in 1...3 {
            _ = c.handle(.responseCreated(id: "r\(i)"), now: t)
            XCTAssertEqual(core(c.handle(.responseRateLimited(retryAfterMs: 2000), now: t + 0.3)), [.startConfirmTimer(ms: 2000), .uiState(.thinking)], "retry \(i)")
            XCTAssertEqual(core(c.handle(.tick, now: t + 2.4)), [.createResponse, .uiState(.thinking)])
            t += 3
        }
        _ = c.handle(.responseCreated(id: "r4"), now: t)
        XCTAssertEqual(core(c.handle(.responseRateLimited(retryAfterMs: 2000), now: t + 0.3)), [.uiState(.listening)], "fourth failure: give up (the client says so out loud)")
        XCTAssertFalse(c.pendingCreate)
        // A new turn starts the count afresh.
        _ = c.handle(.speechStarted(itemId: "v"), now: t + 5)
        _ = c.handle(.speechStopped, now: t + 6)
        _ = c.handle(.transcription(text: "hello?", itemId: "v", final: true), now: t + 6.2)
        XCTAssertEqual(c.rateLimitRetries, 0)
        XCTAssertEqual(VoiceRealtimeClient.retryAfterMs(message: "Rate limit reached … Please try again in 6.946s.", tokenReset: nil), 7196)
        XCTAssertEqual(VoiceRealtimeClient.retryAfterMs(message: "", tokenReset: 12.5), 12750)
        XCTAssertEqual(VoiceRealtimeClient.retryAfterMs(message: "", tokenReset: nil), 5250)
        XCTAssertEqual(VoiceRealtimeClient.retryAfterMs(message: "", tokenReset: 90), 30250)
    }

    // MARK: 27 — one word is the user (Zubair's morning call, 2026-09-21 07:01:
    // "Morning." answering "Morning. Want to walk through today?" was deleted
    // as echo of the greeting; nothing happened until "Hello?").

    func test27a_aOneWordAnswerThatSharesTheGreetingsWordIsATurn() {
        var c = speaking(.speaker)
        said(&c, "Morning. Want to walk through today?")
        _ = c.handle(.speechStarted(itemId: "m"), now: 1.0)          // on air, as the greeting's last words play
        _ = c.handle(.speechStopped, now: 1.6)
        let out = core(c.handle(.transcription(text: "Morning.", itemId: "m", final: true), now: 1.8))
        XCTAssertTrue(out.contains(.userTurn("Morning.")), "\(out)")
        XCTAssertEqual(count(out, .sendCancel), 1, "their word ends the greeting's tail")
        XCTAssertEqual(c.pendingDeletes, [])
        // Two words that are the reply's are still judged (a garble is echo).
        var d = speaking(.speaker)
        said(&d, "Saturday's clear.")
        _ = d.handle(.speechStarted(itemId: "b"), now: 1.0)
        XCTAssertEqual(core(d.handle(.transcription(text: "Saturday's players.", itemId: "b", final: true), now: 1.9)), [])
        XCTAssertEqual(d.pendingDeletes, ["b"])
        // A one-word later piece of an echo-judged segment stays echo.
        var e = speaking(.speaker)
        said(&e, "Looks pretty solid. You've got a few tasks wrapped up, and Friday coming up.")
        _ = e.handle(.speechStarted(itemId: "p"), now: 1.0)
        XCTAssertEqual(core(e.handle(.transcription(text: "Coming up on.", itemId: "p", final: true), now: 1.9)), [])
        XCTAssertEqual(core(e.handle(.transcription(text: "Day.", itemId: "p", final: true), now: 2.5)), [])
        XCTAssertEqual(e.pendingDeletes, ["p"])
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
        XCTAssertTrue(c.pendingCreate, "asked for; pending until the server creates")
        XCTAssertFalse(core(c.handle(.tick, now: 4.0)).contains(.createResponse), "never twice — in flight, only the grace timer")
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

    // MARK: 28 — a reply cut on air is TRUNCATED to what was heard (Zubair's
    // voice session, 2026-09-23 05:05:56–05:06:17, assistant_turns): he talked
    // over "Ah, good question. I can nudge you in a couple of ways…", the
    // cancel found no active response (the reply had finished GENERATING —
    // only its playback was cut), he said "Carry on", and the assistant opened
    // a new topic: the server still held the whole reply, so the model
    // believed it had said all of it. Ahmad 2026-09-23.

    private func index(_ cmds: [BargeInCommand], _ c: BargeInCommand) -> Int? { cmds.firstIndex(of: c) }
    /// Truncates of either kind (generating or not).
    private func truncates(_ cmds: [BargeInCommand]) -> Int {
        cmds.filter { if case .truncatePlayback = $0 { return true } else { return false } }.count
    }

    func test28a_aConfirmedTalkOverTruncates_afterTheCancel_beforeTheFlush() {
        // Energy confirm (low-echo routes, calls): server VAD + mic for confirmMs.
        var e = speaking()
        _ = e.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = e.handle(.gateOpen, now: 1.05)
        let confirmed = core(e.handle(.tick, now: 1.3))
        XCTAssertEqual(count(confirmed, .truncatePlayback(generating: true)), 1)
        XCTAssertLessThan(index(confirmed, .sendCancel)!, index(confirmed, .truncatePlayback(generating: true))!, "cancel first (the reference client's order)")
        XCTAssertLessThan(index(confirmed, .truncatePlayback(generating: true))!, index(confirmed, .flushPlayback)!, "the playhead is read before the flush resets it")
        // Words (the loudspeaker): the live guess is clearly theirs.
        var w = speaking(.speaker)
        said(&w, "Ah, good question. I can nudge you in a couple of ways.")
        _ = w.handle(.speechStarted(itemId: "v"), now: 1.0)
        let words = core(w.handle(.transcription(text: "wait so how does", itemId: "v", final: false), now: 1.4))
        XCTAssertEqual(count(words, .truncatePlayback(generating: true)), 1)
        XCTAssertLessThan(index(words, .truncatePlayback(generating: true))!, index(words, .flushPlayback)!)
        // The Interrupt button and a hold-to-talk press cut what was on air too.
        var b = speaking(.speaker)
        XCTAssertEqual(count(b.handle(.interruptPressed, now: 1), .truncatePlayback(generating: true)), 1)
        var h = speaking(holdToTalk: true)
        XCTAssertEqual(count(h.handle(.pttDown, now: 1), .truncatePlayback(generating: true)), 1)
    }

    func test28b_zubairsCase_aReplyThatFinishedGeneratingIsTruncatedWithNoCancel() {
        var c = speaking(.speaker)
        said(&c, "Ah, good question. I can nudge you in a couple of ways.")
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 0.8)   // generated; still playing
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        let out = core(c.handle(.transcription(text: "wait so how does", itemId: "u", final: false), now: 1.4))
        XCTAssertEqual(count(out, .sendCancel), 0, "nothing is generating — a cancel finds nothing")
        XCTAssertEqual(Array(out.prefix(2)), [.truncatePlayback(generating: false), .flushPlayback], "but what he did not hear leaves the conversation")
    }

    func test28c_echoIsNeverTruncated_theReplyPlaysOn() {
        var c = speaking(.speaker)
        said(&c, "Taxi's at quarter to eight, after the gym.")
        _ = c.handle(.speechStarted(itemId: "echo"), now: 1.0)
        XCTAssertEqual(core(c.handle(.transcription(text: "taxi's at quarter", itemId: "echo", final: false), now: 1.2)), [], "an echo's live guess cuts nothing")
        _ = c.handle(.speechStopped, now: 1.3)
        let out = core(c.handle(.transcription(text: "taxi's at quarter to eight after the gym", itemId: "echo", final: true), now: 1.4))
        XCTAssertEqual(truncates(out), 0)
        XCTAssertEqual(out, [], "discarded: its item deleted later, nothing truncated")
        XCTAssertTrue(c.playbackQueued, "the reply is still on air, whole")
        // A blip on an energy route restores — nothing truncated either.
        var e = speaking()
        _ = e.handle(.speechStarted(itemId: "blip"), now: 1.0)
        XCTAssertEqual(truncates(e.handle(.speechStopped, now: 1.1)), 0)
        XCTAssertEqual(truncates(e.handle(.tick, now: 1.3)), 0)
    }

    func test28d_nothingOnAir_nothingTruncated() {
        // A reply that never played: still thinking when they speak.
        var t = BargeInController(profile: .speaker)
        _ = t.handle(.responseCreated(id: "r1"), now: 0)
        let thinking = core(t.handle(.transcription(text: "actually never mind", itemId: nil, final: true), now: 0.5))
        XCTAssertEqual(truncates(thinking), 0)
        XCTAssertEqual(truncates(t.handle(.interruptPressed, now: 0.6)), 0)
        // A reply played to the end (drained), the next one only thinking:
        // cutting that one truncates nothing — the last was heard whole.
        var d = speaking(.speaker)
        _ = d.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        _ = d.handle(.playbackDrained, now: 2)
        _ = d.handle(.responseCreated(id: "r2"), now: 2.5)
        let out = d.handle(.interruptPressed, now: 3)
        XCTAssertEqual(count(out, .sendCancel), 1)
        XCTAssertEqual(truncates(out), 0)
        // …and once a reply was cut, its late tail audio is not on air again.
        var x = speaking(.speaker)
        XCTAssertEqual(count(x.handle(.interruptPressed, now: 1), .truncatePlayback(generating: true)), 1)
        _ = x.handle(.audioDelta(id: "r1"), now: 1.1)   // dropped (cancelled id)
        XCTAssertEqual(truncates(x.handle(.interruptPressed, now: 1.2)), 0)
    }

    // The item and the ms come from the audio engine's ledger (frames at
    // 24 kHz on the player's timeline) and AudioTruncation — both pure.

    func test28e_msAccounting_heardNotReceived_roundedDown_neverPastTheItem() {
        func plan(_ played: Int, of received: Int, _ id: String? = "item_A") -> AudioTruncation? {
            AudioTruncation.plan(PlaybackPosition(itemId: id, playedFrames: played, receivedFrames: received))
        }
        XCTAssertEqual(plan(36_000, of: 48_000), AudioTruncation(itemId: "item_A", audioEndMs: 1500))
        XCTAssertEqual(plan(36_023, of: 48_000)?.audioEndMs, 1500, "rounded down — never a ms they did not hear")
        XCTAssertEqual(plan(47_999, of: 48_000)?.audioEndMs, 1999, "below what arrived (2000 ms)")
        XCTAssertNil(plan(48_000, of: 48_000), "heard to the end — nothing to take back")
        XCTAssertNil(plan(60_000, of: 48_000), "a playhead past what arrived is clamped to it: heard whole")
        XCTAssertNil(plan(0, of: 48_000), "nothing of it heard")
        XCTAssertNil(plan(23, of: 48_000), "under a millisecond is nothing")
        XCTAssertNil(plan(12_000, of: 48_000, nil), "no item id, nothing to name")
        XCTAssertNil(plan(12_000, of: 48_000, ""))
        XCTAssertNil(AudioTruncation.plan(nil))
        let ev = AudioTruncation(itemId: "item_A", audioEndMs: 1500).event(id: "evt_truncate_1")
        XCTAssertEqual(ev["type"] as? String, "conversation.item.truncate")
        XCTAssertEqual(ev["item_id"] as? String, "item_A")
        XCTAssertEqual(ev["content_index"] as? Int, 0)
        XCTAssertEqual(ev["audio_end_ms"] as? Int, 1500)
        XCTAssertEqual(ev["event_id"] as? String, "evt_truncate_1")
    }

    func test28f_ledger_theItemAtThePlayheadAndWhatOfItWasHeard() {
        var l = PlaybackLedger()
        // The player has been playing silence for 2 s when the greeting lands.
        l.scheduled(itemId: "A", frames: 24_000, playhead: 48_000)
        l.scheduled(itemId: "A", frames: 24_000, playhead: 48_100)   // queued behind
        XCTAssertNil(l.position(at: 47_000), "nothing had started")
        XCTAssertEqual(l.position(at: 60_000), PlaybackPosition(itemId: "A", playedFrames: 12_000, receivedFrames: 48_000))
        XCTAssertEqual(l.position(at: 84_000), PlaybackPosition(itemId: "A", playedFrames: 36_000, receivedFrames: 48_000))
        // The queue ran dry at 96 000; the next burst lands at 100 000.
        l.scheduled(itemId: "A", frames: 12_000, playhead: 100_000)
        XCTAssertEqual(l.position(at: 98_000), PlaybackPosition(itemId: "A", playedFrames: 48_000, receivedFrames: 60_000), "the gap is silence, not the reply")
        XCTAssertEqual(l.position(at: 106_000), PlaybackPosition(itemId: "A", playedFrames: 54_000, receivedFrames: 60_000))
    }

    func test28g_ledger_theRightItemWhenANewReplyIsQueuedBehindTheLast() {
        var l = PlaybackLedger()
        l.scheduled(itemId: "A", frames: 24_000, playhead: 0)
        l.scheduled(itemId: "B", frames: 24_000, playhead: 1_000)   // the next reply, behind A's tail
        XCTAssertEqual(l.position(at: 12_000), PlaybackPosition(itemId: "A", playedFrames: 12_000, receivedFrames: 24_000, laterItemQueued: true), "A's tail is on air: A is cut")
        XCTAssertNil(AudioTruncation.plan(l.position(at: 24_000)), "at the seam: A heard whole, B not yet begun")
        XCTAssertEqual(l.position(at: 30_000), PlaybackPosition(itemId: "B", playedFrames: 6_000, receivedFrames: 24_000))
        XCTAssertEqual(AudioTruncation.plan(l.position(at: 30_000)), AudioTruncation(itemId: "B", audioEndMs: 250))
    }

    func test28h_ledger_resetsWithThePlayersTimeline_andStaysBounded() {
        var l = PlaybackLedger()
        l.scheduled(itemId: "A", frames: 24_000, playhead: 500_000)
        // Stopped and restarted (a flush it was not told about): the playhead
        // runs backwards, and A's span means nothing on the new timeline.
        l.scheduled(itemId: "B", frames: 24_000, playhead: 1_000)
        XCTAssertEqual(l.end, 25_000)
        XCTAssertEqual(l.position(at: 13_000), PlaybackPosition(itemId: "B", playedFrames: 12_000, receivedFrames: 24_000))
        l.reset()
        XCTAssertNil(l.position(at: 13_000))
        XCTAssertEqual(l.end, 0)
        // No item id: the timeline moves on, nothing is named.
        l.scheduled(itemId: nil, frames: 24_000, playhead: 0)
        XCTAssertEqual(l.end, 24_000)
        XCTAssertNil(l.position(at: 12_000))
        // Only the last few items are kept.
        var m = PlaybackLedger()
        for (i, id) in ["A", "B", "C", "D"].enumerated() { m.scheduled(itemId: id, frames: 1_000, playhead: i * 1_000) }
        XCTAssertNil(m.position(at: 500), "A is forgotten")
        XCTAssertEqual(m.position(at: 3_500)?.itemId, "D")
        XCTAssertEqual(m.position(at: 1_500)?.itemId, "B")
    }

    // Second pass (review, 2026-09-23): a reply still GENERATING when cut —
    // the server's copy runs past what reached the phone, so "heard all that
    // arrived" is not "heard it all". OpenAI's own realtime client truncates
    // the item at the playhead while a response is ongoing, whatever was heard.

    func test28i_aReplyStillGeneratingThatDrainedBetweenBurstsIsTruncatedWhenCut() {
        // The queue ran dry mid-reply (a network hiccup, a slow burst); the
        // reply is still generating when they cut in. Before: playbackQueued
        // was false, nothing was truncated, and the words generated past what
        // arrived stayed in the conversation.
        var c = speaking(.speaker)
        said(&c, "Here's your week. Monday you have the dentist, then")
        _ = c.handle(.playbackDrained, now: 1.0)
        XCTAssertTrue(c.responseActive)
        XCTAssertFalse(c.playbackQueued)
        let out = core(c.handle(.interruptPressed, now: 1.4))
        XCTAssertEqual(Array(out.prefix(3)), [.sendCancel, .truncatePlayback(generating: true), .flushPlayback])
        // Energy confirm in the same gap (earphones, calls).
        var e = speaking()
        _ = e.handle(.playbackDrained, now: 1.0)
        _ = e.handle(.speechStarted(itemId: "u"), now: 1.2)
        _ = e.handle(.gateOpen, now: 1.25)
        XCTAssertEqual(count(core(e.handle(.tick, now: 1.5)), .truncatePlayback(generating: true)), 1)
    }

    func test28j_generatingIsOnlyTheReplyWhoseAudioWasOnAir() {
        // A finished reply still playing while the NEXT one only thinks (a
        // tool call's follow-up): the one cut on air is the finished one.
        var c = speaking(.speaker)
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = c.handle(.responseCreated(id: "r2"), now: 0.8)
        let out = core(c.handle(.interruptPressed, now: 1.0))
        XCTAssertEqual(Array(out.prefix(3)), [.sendCancel, .truncatePlayback(generating: false), .flushPlayback])
        // …but once r2's own audio is queued behind r1's tail, r2 is on air.
        var d = speaking(.speaker)
        _ = d.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = d.handle(.responseCreated(id: "r2"), now: 0.8)
        _ = d.handle(.audioDelta(id: "r2"), now: 0.9)
        XCTAssertEqual(count(core(d.handle(.interruptPressed, now: 1.0)), .truncatePlayback(generating: true)), 1)
        // A finished reply that drained, the next only thinking: nothing on air.
        var f = speaking(.speaker)
        _ = f.handle(.responseDone(id: "r1", status: "completed"), now: 0.5)
        _ = f.handle(.playbackDrained, now: 1.0)
        _ = f.handle(.responseCreated(id: "r2"), now: 1.2)
        XCTAssertEqual(truncates(f.handle(.interruptPressed, now: 1.5)), 0)
    }

    func test28k_generating_heardToTheEndOfWhatArrived_isTruncatedThere() {
        func plan(_ played: Int, of received: Int, later: Bool = false, generating: Bool) -> AudioTruncation? {
            AudioTruncation.plan(PlaybackPosition(itemId: "item_A", playedFrames: played, receivedFrames: received, laterItemQueued: later),
                                 generating: generating)
        }
        XCTAssertEqual(plan(48_000, of: 48_000, generating: true), AudioTruncation(itemId: "item_A", audioEndMs: 2000),
                       "all that arrived was heard, but the server generated on: end it there")
        XCTAssertEqual(plan(60_000, of: 48_000, generating: true)?.audioEndMs, 2000, "never past what arrived")
        XCTAssertEqual(plan(36_000, of: 48_000, generating: true)?.audioEndMs, 1500, "mid-item: what was heard, as before")
        XCTAssertNil(plan(48_000, of: 48_000, generating: false), "finished and heard whole: nothing to take back")
        XCTAssertNil(plan(48_000, of: 48_000, later: true, generating: true), "a later item is queued behind it: this one was finished, and heard whole")
        XCTAssertNil(plan(0, of: 48_000, generating: true), "nothing of it heard is still nothing")
        // Through the ledger: the queue ran dry at 24 000, the playhead moved on.
        var l = PlaybackLedger()
        l.scheduled(itemId: "item_A", frames: 24_000, playhead: 0)
        let dry = l.position(at: 40_000)
        XCTAssertEqual(dry, PlaybackPosition(itemId: "item_A", playedFrames: 24_000, receivedFrames: 24_000))
        XCTAssertEqual(AudioTruncation.plan(dry, generating: true)?.audioEndMs, 1000)
        XCTAssertNil(AudioTruncation.plan(dry, generating: false))
    }

    func test28l_ledger_aLongReplyKeepsItsStart() {
        // 20 ms deltas arriving faster than they play: back to back, one span
        // however many there are. Before, each delta was a span and the cap
        // dropped the OLDEST — the start of the reply being heard.
        var l = PlaybackLedger()
        for _ in 0..<10_000 { l.scheduled(itemId: "A", frames: 480, playhead: 0) }
        XCTAssertEqual(l.position(at: 2_160_000), PlaybackPosition(itemId: "A", playedFrames: 2_160_000, receivedFrames: 4_800_000),
                       "90 s into a 200 s reply")
        XCTAssertEqual(AudioTruncation.plan(l.position(at: 2_160_000))?.audioEndMs, 90_000)
        // A reply in more bursts than the cap keeps (the queue running dry
        // between every one): the oldest spans go, the item's place does not.
        var g = PlaybackLedger()
        for k in 0..<5_000 { g.scheduled(itemId: "A", frames: 480, playhead: k * 1_000) }
        XCTAssertEqual(g.position(at: 4_999_240), PlaybackPosition(itemId: "A", playedFrames: 4_999 * 480 + 240, receivedFrames: 5_000 * 480))
    }

    func test28m_ledger_aRestartMidReplyKeepsTheItemsPlace() {
        // AirPods connect 5 s into a reply still streaming: the engine
        // restarts (the queued audio dropped, the player's timeline back to
        // 0) and the reply's later deltas play on. They sit 5 s into the
        // ITEM, not at 0: a cut 1 s later is at 6000 ms, not 1000.
        var l = PlaybackLedger()
        l.scheduled(itemId: "A", frames: 120_000, playhead: 0)
        l.reset()
        l.scheduled(itemId: "A", frames: 48_000, playhead: 0)
        let p = l.position(at: 24_000)
        XCTAssertEqual(p, PlaybackPosition(itemId: "A", playedFrames: 144_000, receivedFrames: 168_000))
        XCTAssertEqual(AudioTruncation.plan(p)?.audioEndMs, 6000)
        // A new item after the restart starts at its own 0.
        l.scheduled(itemId: "B", frames: 24_000, playhead: 48_000)
        XCTAssertEqual(l.position(at: 54_000), PlaybackPosition(itemId: "B", playedFrames: 6_000, receivedFrames: 24_000))
    }

    // MARK: 29 — pre-launch audit 2026-09-22, C46: missed turns, deleted
    // answers, create loops.

    /// The tool continuation's create and the hold tick's create both went
    /// out; the server made r1 from the first and refused the second. r1 is
    /// generating: the screen says so, and a barge-in cancels it for real.
    func test29a_aCreateRefusedByALiveReplyLeavesThatReplyLive() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r0"), now: 0)                      // the reply that called a tool
        _ = c.handle(.responseDone(id: "r0", status: "completed"), now: 0.5)
        _ = c.handle(.speechStarted(itemId: "u"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.6)
        _ = c.handle(.transcription(text: "and the dentist too", itemId: "u", final: true), now: 1.9)
        XCTAssertEqual(core(c.handle(.tick, now: 2.4)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.responseCreated(id: "r1"), now: 2.5)                    // the continuation's reply
        let out = core(c.handle(.responseAlreadyActive, now: 2.55))           // our create, refused
        XCTAssertTrue(c.responseActive, "r1 is generating")
        XCTAssertEqual(out, [.uiState(.thinking)], "not Listening over a live reply, and nothing re-created")
        _ = c.handle(.audioDelta(id: "r1"), now: 2.8)
        XCTAssertEqual(count(core(c.handle(.interruptPressed, now: 3.0)), .sendCancel), 1, "the server stops generating r1")
    }

    func test29b_theTwoActiveResponseComplaintsAreToldApart() {
        XCTAssertEqual(VoiceRealtimeClient.activeResponseEvent(
            code: "conversation_already_has_active_response",
            message: "Conversation already has an active response in progress: resp_abc. Wait until the response is finished before creating a new one."),
                       .responseAlreadyActive)
        XCTAssertEqual(VoiceRealtimeClient.activeResponseEvent(code: "", message: "Conversation already has an active response"), .responseAlreadyActive)
        XCTAssertEqual(VoiceRealtimeClient.activeResponseEvent(code: "response_cancel_not_active", message: "Cancellation failed: no active response found"),
                       .benignActiveResponseError)
        XCTAssertEqual(VoiceRealtimeClient.activeResponseEvent(code: "", message: "Conversation has no active response"), .benignActiveResponseError)
        XCTAssertNil(VoiceRealtimeClient.activeResponseEvent(code: "", message: "Invalid value for 'audio'"))
    }

    /// The transcriber failed the segment: no words will come, and nothing
    /// else asks for a reply — dead air. The model hears the audio: ask.
    func test29c_aFailedTranscriptionIsStillAnswered() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        XCTAssertEqual(core(c.handle(.transcriptionFailed(itemId: "u"), now: 1.3)), [.startConfirmTimer(ms: 500), .uiState(.thinking)])
        XCTAssertTrue(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.tick, now: 1.8)), [.createResponse, .uiState(.thinking)])
        XCTAssertEqual(core(c.handle(.transcriptionFailed(itemId: "u"), now: 1.9)), [], "once per segment")

        // Under a reply still on air and uncut: no words to tell the user
        // from the echo, and the reply was never cut for it — nothing.
        var onAir = speaking(.speaker)
        _ = onAir.handle(.speechStarted(itemId: "e"), now: 1.0)
        _ = onAir.handle(.speechStopped, now: 1.6)
        XCTAssertEqual(core(onAir.handle(.transcriptionFailed(itemId: "e"), now: 1.9)), [])
        XCTAssertFalse(onAir.pendingCreate)

        // A barge-in the voice itself confirmed (low-echo route) cut the
        // reply: its failed transcription is still the user's turn.
        var cut = speaking(Self.energy)
        _ = cut.handle(.speechStarted(itemId: "b"), now: 1.0)
        _ = cut.handle(.gateOpen, now: 1.05)
        XCTAssertEqual(count(core(cut.handle(.tick, now: 1.3)), .sendCancel), 1)
        _ = cut.handle(.speechStopped, now: 2.0)
        let out = core(cut.handle(.transcriptionFailed(itemId: "b"), now: 2.3))
        XCTAssertTrue(out.contains(.uiState(.thinking)))
        XCTAssertTrue(cut.pendingCreate)
    }

    /// A CallKit call through the receiver (the low-echo profile): "Tuesday
    /// works" over the tail of "…move it to Tuesday?" cut the reply by voice,
    /// then scored 1 of 2 against it and was deleted as echo — the assistant
    /// stopped mid-word and said nothing.
    func test29d_onALowEchoRouteABargeInsWordsAreNeverDeletedAsEcho() {
        var c = BargeInController(profile: .lowEcho)
        _ = c.handle(.responseCreated(id: "r1"), now: 0)
        _ = c.handle(.audioDelta(id: "r1"), now: 0)
        said(&c, "Want me to move it to Tuesday?")
        _ = c.handle(.gateOpen, now: 1.0)
        XCTAssertEqual(count(core(c.handle(.speechStarted(itemId: "u"), now: 1.05)), .sendCancel), 1, "gate + server VAD: a barge-in")
        _ = c.handle(.speechStopped, now: 1.8)
        let out = core(c.handle(.transcription(text: "Tuesday works", itemId: "u", final: true), now: 2.1))
        XCTAssertTrue(out.contains(.userTurn("Tuesday works")), "their answer: \(out)")
        XCTAssertEqual(c.pendingDeletes, [], "never deleted as echo")
        XCTAssertTrue(c.pendingCreate)
        // The loudspeaker keeps the echo verdict (the tiered rule).
        var speaker = speaking(.speaker)
        said(&speaker, "Want me to move it to Tuesday?")
        _ = speaker.handle(.speechStarted(itemId: "e"), now: 1.0)
        _ = speaker.handle(.speechStopped, now: 1.6)
        _ = speaker.handle(.transcription(text: "move it to Tuesday", itemId: "e", final: true), now: 1.9)
        XCTAssertEqual(speaker.pendingDeletes, ["e"], "on air on the loudspeaker, the reply's own words are still echo")
    }

    /// A reply was rate-limited: "Thinking…" while the client waits out the
    /// bucket. Interrupt drops the turn — and the screen says Listening.
    func test29e_interruptWithNothingGeneratingReturnsToListening() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)
        _ = c.handle(.tick, now: 1.8)
        _ = c.handle(.responseCreated(id: "r1"), now: 2.0)
        XCTAssertEqual(core(c.handle(.responseRateLimited(retryAfterMs: 7000), now: 2.3)), [.startConfirmTimer(ms: 7000), .uiState(.thinking)])
        XCTAssertFalse(c.modelBusy)
        XCTAssertEqual(core(c.handle(.interruptPressed, now: 3.0)), [.uiState(.listening)])
        XCTAssertFalse(c.pendingCreate)
        XCTAssertEqual(core(c.handle(.tick, now: 9.3)), [], "the retry is dropped with the turn")
    }

    /// "What's next today?" — asked; a cough before response.created. The
    /// cough kept the turn pending, and the finished reply's done asked for
    /// it again: the same question answered twice.
    func test29f_aNoWordsNoiseWhileTheAskIsInFlightNeverAsksTheTurnAgain() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        XCTAssertEqual(core(c.handle(.tick, now: 1.7)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.speechStarted(itemId: "cough"), now: 1.8)
        _ = c.handle(.responseCreated(id: "r1"), now: 2.0)
        XCTAssertTrue(c.pendingCreate, "a sound after the ask keeps the turn pending until it has words")
        _ = c.handle(.speechStopped, now: 2.3)
        _ = c.handle(.transcription(text: "", itemId: "cough", final: true), now: 2.6)
        XCTAssertFalse(c.pendingCreate, "no words: the question is the one being answered")
        _ = c.handle(.audioDelta(id: "r1"), now: 2.7)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "r1", status: "completed"), now: 5.0)), .createResponse), 0, "answered once")
        _ = c.handle(.playbackDrained, now: 6.0)
        XCTAssertEqual(count(core(c.handle(.tick, now: 7.0)), .createResponse), 0)

        // A cough BEFORE the ask went out: the question is still owed.
        var b = BargeInController(profile: .speaker)
        _ = b.handle(.speechStarted(itemId: "u"), now: 0)
        _ = b.handle(.speechStopped, now: 1.0)
        _ = b.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = b.handle(.speechStarted(itemId: "cough"), now: 1.4)
        _ = b.handle(.speechStopped, now: 1.7)
        _ = b.handle(.transcription(text: "", itemId: "cough", final: true), now: 1.9)
        XCTAssertTrue(b.pendingCreate)
        XCTAssertEqual(core(b.handle(.tick, now: 2.2)), [.createResponse, .uiState(.thinking)])

        // Two sounds after the ask, both without words: still answered once.
        var d = BargeInController(profile: .speaker)
        _ = d.handle(.speechStarted(itemId: "u"), now: 0)
        _ = d.handle(.speechStopped, now: 1.0)
        _ = d.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = d.handle(.tick, now: 1.7)
        _ = d.handle(.speechStarted(itemId: "n1"), now: 1.8)
        _ = d.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = d.handle(.speechStopped, now: 2.1)
        _ = d.handle(.speechStarted(itemId: "n2"), now: 2.2)
        _ = d.handle(.transcription(text: "", itemId: "n1", final: true), now: 2.4)
        XCTAssertTrue(d.pendingCreate, "n2 is still unheard")
        _ = d.handle(.speechStopped, now: 2.5)
        _ = d.handle(.transcription(text: "", itemId: "n2", final: true), now: 2.8)
        XCTAssertFalse(d.pendingCreate)
        // And one WITH words is a turn of its own, asked after the reply.
        var w = BargeInController(profile: .speaker)
        _ = w.handle(.speechStarted(itemId: "u"), now: 0)
        _ = w.handle(.speechStopped, now: 1.0)
        _ = w.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = w.handle(.tick, now: 1.7)
        _ = w.handle(.speechStarted(itemId: "more"), now: 1.8)
        _ = w.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = w.handle(.speechStopped, now: 2.6)
        _ = w.handle(.transcription(text: "and tomorrow", itemId: "more", final: true), now: 2.9)
        XCTAssertTrue(w.pendingCreate)
    }

    /// The same cough, but the short reply's done lands BEFORE the cough's
    /// (empty) transcript: the done asked for the turn at once, and the empty
    /// transcript that cleared it came after the create was out — answered
    /// twice. Whether anything is owed waits for the cough's words.
    func test29g_aReplyDoneBeforeTheNoisesTranscriptNeverAsksTheTurnAgain() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.speechStopped, now: 1.0)
        _ = c.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        XCTAssertEqual(core(c.handle(.tick, now: 1.7)), [.createResponse, .uiState(.thinking)])
        _ = c.handle(.speechStarted(itemId: "cough"), now: 1.8)
        _ = c.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = c.handle(.speechStopped, now: 2.1)
        _ = c.handle(.audioDelta(id: "r1"), now: 2.2)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "r1", status: "completed"), now: 2.4)), .createResponse), 0,
                       "the cough may be nothing: wait for its words")
        XCTAssertEqual(count(core(c.handle(.tick, now: 2.9)), .createResponse), 0)
        _ = c.handle(.transcription(text: "", itemId: "cough", final: true), now: 3.0)
        XCTAssertFalse(c.pendingCreate, "no words: the question was the one answered")
        XCTAssertEqual(count(core(c.handle(.tick, now: 5.5)), .createResponse), 0, "answered once")

        // Its audio drained before its done: once the cough is heard as
        // nothing, the screen says so instead of the reply's last state.
        var drained = BargeInController(profile: .speaker)
        _ = drained.handle(.speechStarted(itemId: "u"), now: 0)
        _ = drained.handle(.speechStopped, now: 1.0)
        _ = drained.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = drained.handle(.tick, now: 1.7)
        _ = drained.handle(.speechStarted(itemId: "cough"), now: 1.8)
        _ = drained.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = drained.handle(.speechStopped, now: 2.1)
        _ = drained.handle(.audioDelta(id: "r1"), now: 2.2)
        _ = drained.handle(.playbackDrained, now: 2.3)
        XCTAssertEqual(count(core(drained.handle(.responseDone(id: "r1", status: "completed"), now: 2.4)), .createResponse), 0)
        XCTAssertEqual(core(drained.handle(.transcription(text: "", itemId: "cough", final: true), now: 3.0)), [.uiState(.listening)])
        XCTAssertEqual(drained.state, .idle)

        // A long reply: the fallback tick (2.5 s after the cough began, the
        // reply still generating) doesn't presume it lost and ask either.
        var f = BargeInController(profile: .speaker)
        _ = f.handle(.speechStarted(itemId: "u"), now: 0)
        _ = f.handle(.speechStopped, now: 1.0)
        _ = f.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = f.handle(.tick, now: 1.7)
        _ = f.handle(.speechStarted(itemId: "cough"), now: 1.8)
        _ = f.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = f.handle(.speechStopped, now: 2.1)
        XCTAssertEqual(count(core(f.handle(.tick, now: 4.4)), .createResponse), 0)
        XCTAssertTrue(f.responseActive, "r1 is still the live reply")
        _ = f.handle(.transcription(text: "", itemId: "cough", final: true), now: 4.6)
        XCTAssertFalse(f.pendingCreate)

        // The sound had words after all: a turn of its own, asked for.
        var w = BargeInController(profile: .speaker)
        _ = w.handle(.speechStarted(itemId: "u"), now: 0)
        _ = w.handle(.speechStopped, now: 1.0)
        _ = w.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = w.handle(.tick, now: 1.7)
        _ = w.handle(.speechStarted(itemId: "more"), now: 1.8)
        _ = w.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = w.handle(.speechStopped, now: 2.6)
        _ = w.handle(.responseDone(id: "r1", status: "completed"), now: 2.7)
        let heard = core(w.handle(.transcription(text: "and tomorrow", itemId: "more", final: true), now: 3.0))
        XCTAssertTrue(heard.contains(.userTurn("and tomorrow")))
        XCTAssertEqual(core(w.handle(.tick, now: 3.5)), [.createResponse, .uiState(.thinking)])

        // Its words never come (no completed, no failed): asked for as a turn
        // once the wait from the sound's end is out — never stuck.
        var lost = BargeInController(profile: .speaker)
        _ = lost.handle(.speechStarted(itemId: "u"), now: 0)
        _ = lost.handle(.speechStopped, now: 1.0)
        _ = lost.handle(.transcription(text: "what's next today", itemId: "u", final: true), now: 1.2)
        _ = lost.handle(.tick, now: 1.7)
        _ = lost.handle(.speechStarted(itemId: "x"), now: 1.8)
        _ = lost.handle(.responseCreated(id: "r1"), now: 2.0)
        _ = lost.handle(.speechStopped, now: 2.1)
        XCTAssertEqual(core(lost.handle(.responseDone(id: "r1", status: "completed"), now: 2.4)), [.startConfirmTimer(ms: 2701)])
        XCTAssertEqual(count(core(lost.handle(.tick, now: 5.2)), .createResponse), 1)
    }

    // MARK: 30 — the minutes notice (Ahmad 2026-09-23)
    //
    // At about a minute of today's voice minutes left the proxy sends
    // warn:true, and the assistant says so once, in its own voice — through
    // the turn-taking: after whatever is on air or being created, never over
    // the user, and after the pause in which they usually answer.

    private func notices(_ cmds: [BargeInCommand]) -> Int { count(cmds, .speakMinutesNotice) }
    /// Anything that would cut, duck or silence what is playing.
    private func cuts(_ cmds: [BargeInCommand]) -> Int {
        cmds.filter { [.sendCancel, .flushPlayback, .duck].contains($0) }.count
    }

    func test30a_theNoticeWaitsForTheReplyOnAirThenAQuietMoment_once() {
        var c = speaking(.speaker)
        let warned = core(c.handle(.minutesWarning, now: 1))
        XCTAssertEqual(warned, [], "a reply is on air: nothing is cut or asked")
        XCTAssertEqual(cuts(c.handle(.responseDone(id: "r1", status: "completed"), now: 2)), 0)
        XCTAssertEqual(core(c.handle(.playbackDrained, now: 3)), [.uiState(.listening), .startConfirmTimer(ms: 1201)],
                       "drained: the pause they answer in comes first")
        XCTAssertEqual(core(c.handle(.tick, now: 3.6)), [.startConfirmTimer(ms: 601)], "too soon")
        XCTAssertEqual(core(c.handle(.tick, now: 4.2)), [.speakMinutesNotice])
        XCTAssertNil(c.noticeOwedSince)
        XCTAssertTrue(c.noticeAsked)
        // One per session: a second warning, or a later tick, says nothing.
        XCTAssertEqual(core(c.handle(.minutesWarning, now: 5)), [])
        XCTAssertEqual(notices(c.handle(.tick, now: 9)), 0)
        // All quiet when it comes: at once.
        var idle = BargeInController(profile: .lowEcho)
        XCTAssertEqual(core(idle.handle(.minutesWarning, now: 30)), [.speakMinutesNotice])
    }

    func test30b_neverOverTheUser_theirTurnIsAnsweredFirst() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        XCTAssertEqual(core(c.handle(.minutesWarning, now: 0.5)), [], "they're talking")
        XCTAssertEqual(notices(c.handle(.speechStopped, now: 1.0)), 0)
        XCTAssertEqual(notices(c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 1.2)), 0)
        XCTAssertEqual(core(c.handle(.tick, now: 1.7)), [.createResponse, .uiState(.thinking)], "their turn is asked for, not the notice")
        XCTAssertEqual(notices(c.handle(.tick, now: 2.2)), 0, "its reply is being created")
        _ = c.handle(.responseCreated(id: "r1"), now: 2.5)
        _ = c.handle(.audioDelta(id: "r1"), now: 3)
        XCTAssertEqual(notices(c.handle(.responseDone(id: "r1", status: "completed"), now: 4)), 0, "still on air")
        XCTAssertEqual(notices(c.handle(.playbackDrained, now: 6)), 0)
        // They answer inside the pause: held again.
        _ = c.handle(.speechStarted(itemId: "v"), now: 6.8)
        XCTAssertEqual(notices(c.handle(.tick, now: 7.2)), 0, "the quiet timer's tick finds them talking")
        _ = c.handle(.speechStopped, now: 7.5)
        _ = c.handle(.transcription(text: "and tomorrow", itemId: "v", final: true), now: 7.6)
        XCTAssertEqual(count(core(c.handle(.tick, now: 8.1)), .createResponse), 1)
        _ = c.handle(.responseCreated(id: "r2"), now: 8.4)
        _ = c.handle(.audioDelta(id: "r2"), now: 8.6)
        _ = c.handle(.responseDone(id: "r2", status: "completed"), now: 9)
        XCTAssertEqual(core(c.handle(.playbackDrained, now: 10)), [.uiState(.listening), .startConfirmTimer(ms: 1201)])
        XCTAssertEqual(core(c.handle(.tick, now: 11.2)), [.speakMinutesNotice], "their pause, at last")
    }

    func test30c_neverIntoTheClientsOwnCreatesOrARunningTool() {
        var c = BargeInController(profile: .lowEcho)
        _ = c.handle(.clientCreate, now: 0)   // the opening
        XCTAssertEqual(core(c.handle(.minutesWarning, now: 0.1)), [.startConfirmTimer(ms: 2901)], "the opening's reply is on its way")
        _ = c.handle(.responseCreated(id: "r0"), now: 0.8)
        _ = c.handle(.audioDelta(id: "r0"), now: 1)
        _ = c.handle(.toolStarted, now: 1.5)   // the reply calls a tool
        _ = c.handle(.responseDone(id: "r0", status: "completed"), now: 2)
        XCTAssertEqual(core(c.handle(.playbackDrained, now: 3)), [.uiState(.listening)], "a tool is out: its reply comes first")
        XCTAssertEqual(core(c.handle(.tick, now: 10)), [], "however long it runs")
        XCTAssertEqual(core(c.handle(.toolFinished, now: 11)), [.startConfirmTimer(ms: 3001)], "its continuation is created next")
        _ = c.handle(.clientCreate, now: 11.12)
        _ = c.handle(.responseCreated(id: "r1"), now: 11.5)
        _ = c.handle(.audioDelta(id: "r1"), now: 12)
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 13)
        XCTAssertEqual(notices(c.handle(.playbackDrained, now: 14)), 0)
        XCTAssertEqual(core(c.handle(.tick, now: 15.2)), [.speakMinutesNotice])
        // The integrity corrective, sent outside the controller on a done.
        var k = speaking(.speaker)
        _ = k.handle(.minutesWarning, now: 0.5)
        _ = k.handle(.clientCreate, now: 1)
        _ = k.handle(.responseDone(id: "r1", status: "completed"), now: 1)
        XCTAssertEqual(core(k.handle(.playbackDrained, now: 1.2)), [.uiState(.listening), .startConfirmTimer(ms: 2801)])
        // Hold-to-talk: never while held, nor into the release's own create.
        var h = BargeInController(profile: .speaker, holdToTalk: true)
        _ = h.handle(.pttDown, now: 0)
        XCTAssertEqual(core(h.handle(.minutesWarning, now: 0.5)), [], "the button is held")
        XCTAssertEqual(notices(h.handle(.pttUp, now: 2)), 0)
        XCTAssertEqual(core(h.handle(.tick, now: 3)), [.startConfirmTimer(ms: 2001)])
        _ = h.handle(.responseCreated(id: "p1"), now: 3.2)
        _ = h.handle(.audioDelta(id: "p1"), now: 3.4)
        _ = h.handle(.responseDone(id: "p1", status: "completed"), now: 4)
        _ = h.handle(.playbackDrained, now: 5)
        XCTAssertEqual(core(h.handle(.tick, now: 6.2)), [.speakMinutesNotice])
    }

    func test30d_aConversationWithNoPauseGetsItAtTheFirstClearMomentAfter20s() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.responseCreated(id: "r0"), now: 0)
        _ = c.handle(.audioDelta(id: "r0"), now: 0)
        _ = c.handle(.minutesWarning, now: 0)
        var t = 0.0, k = 0
        var fired: TimeInterval?
        while fired == nil && t < 60 {
            XCTAssertEqual(notices(c.handle(.responseDone(id: "r\(k)", status: "completed"), now: t + 1)), 0)
            if notices(c.handle(.playbackDrained, now: t + 2)) > 0 { fired = t + 2; break }
            // They answer 0.6 s after each reply — inside the pause it waits for.
            _ = c.handle(.speechStarted(itemId: "u\(k)"), now: t + 2.6)
            XCTAssertEqual(notices(c.handle(.tick, now: t + 3.2)), 0, "never over them")
            _ = c.handle(.speechStopped, now: t + 3.5)
            _ = c.handle(.transcription(text: "and then what", itemId: "u\(k)", final: true), now: t + 3.6)
            XCTAssertEqual(count(core(c.handle(.tick, now: t + 4.1)), .createResponse), 1, "their turn, as ever")
            k += 1
            _ = c.handle(.responseCreated(id: "r\(k)"), now: t + 4.4)
            _ = c.handle(.audioDelta(id: "r\(k)"), now: t + 4.6)
            t += 4.6
        }
        XCTAssertNotNil(fired)
        XCTAssertGreaterThanOrEqual(fired ?? 0, 20, "held for a pause while one could still come")
        XCTAssertLessThan(fired ?? 99, 26, "then at the first moment nothing is on air")
    }

    func test30e_aTurnTakenWhileTheNoticeIsInFlightIsAnsweredAfterIt_neverDropped() {
        var c = BargeInController(profile: .speaker)
        XCTAssertEqual(core(c.handle(.minutesWarning, now: 10)), [.speakMinutesNotice])
        _ = c.handle(.speechStarted(itemId: "u"), now: 10.2)
        _ = c.handle(.speechStopped, now: 10.8)
        _ = c.handle(.transcription(text: "ok thanks", itemId: "u", final: true), now: 11.0)
        XCTAssertEqual(count(core(c.handle(.tick, now: 11.5)), .createResponse), 0, "the notice's create is in flight")
        _ = c.handle(.responseCreated(id: "n"), now: 11.6)
        XCTAssertTrue(c.pendingCreate, "their turn is not the notice's to answer")
        _ = c.handle(.audioDelta(id: "n"), now: 12)
        XCTAssertEqual(count(core(c.handle(.responseDone(id: "n", status: "completed"), now: 13)), .createResponse), 1)
        // Words while the notice plays are theirs, as over any reply: it is cut for them.
        var cut = BargeInController(profile: .speaker)
        _ = cut.handle(.minutesWarning, now: 0)
        _ = cut.handle(.responseCreated(id: "n"), now: 0.4)
        _ = cut.handle(.audioDelta(id: "n"), now: 0.6)
        _ = cut.handle(.assistantTranscript(delta: "We've got about a minute left today."), now: 0.6)
        _ = cut.handle(.speechStarted(itemId: "w"), now: 0.9)
        let words = core(cut.handle(.transcription(text: "hang on what about Friday", itemId: "w", final: false), now: 1.3))
        XCTAssertEqual(count(words, .sendCancel), 1)
    }

    // MARK: 30 (review 2026-09-23) — the notice keeps the turn-taking's rules

    /// The held echo / no-words deletes go before the notice, as before any
    /// ask (voice-echo-verdict): the model must not hear its own words or a
    /// noise back as the user and answer that in the warning.
    func test30f_theHeldEchoDeletesGoBeforeTheNotice() {
        var c = speaking(.speaker)
        said(&c, "You have three things left today.")
        _ = c.handle(.minutesWarning, now: 0.6)
        // The reply's own words back through the loudspeaker while it plays.
        _ = c.handle(.speechStarted(itemId: "e"), now: 1.0)
        _ = c.handle(.speechStopped, now: 1.8)
        XCTAssertEqual(count(c.handle(.transcription(text: "three things left today", itemId: "e", final: true), now: 2.0),
                             .deleteItem(id: "e")), 0, "echo: its delete is held")
        XCTAssertEqual(c.pendingDeletes, ["e"])
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 2.5)
        _ = c.handle(.playbackDrained, now: 3.0)
        XCTAssertEqual(core(c.handle(.tick, now: 4.201)), [.deleteItem(id: "e"), .speakMinutesNotice], "the delete first")
        XCTAssertEqual(c.pendingDeletes, [])
        // A noise with no words while the notice waits: the same.
        var n = BargeInController(profile: .speaker)
        _ = n.handle(.speechStarted(itemId: "x"), now: 0)
        XCTAssertEqual(core(n.handle(.minutesWarning, now: 0.2)), [], "a sound is going on")
        _ = n.handle(.speechStopped, now: 0.6)
        XCTAssertEqual(core(n.handle(.transcription(text: "", itemId: "x", final: true), now: 0.9)), [.startConfirmTimer(ms: 901)])
        XCTAssertEqual(core(n.handle(.tick, now: 1.801)), [.deleteItem(id: "x"), .speakMinutesNotice])
    }

    /// A segment whose words haven't come yet may be a turn of theirs: the
    /// notice waits for them (up to the create grace) instead of going out
    /// after 1.2 s and being cut by them when they land.
    func test30g_theNoticeWaitsForTheLastSegmentsWords() {
        var c = BargeInController(profile: .speaker)
        _ = c.handle(.speechStarted(itemId: "u"), now: 0)
        _ = c.handle(.minutesWarning, now: 0.3)
        XCTAssertEqual(core(c.handle(.speechStopped, now: 1.0)), [.startConfirmTimer(ms: 3001)], "their words are still coming")
        XCTAssertEqual(notices(c.handle(.tick, now: 2.3)), 0, "1.2 s of quiet is not enough without them")
        _ = c.handle(.transcription(text: "what's on today", itemId: "u", final: true), now: 2.5)
        XCTAssertEqual(core(c.handle(.tick, now: 3.0)), [.createResponse, .uiState(.thinking)], "their turn first")
        _ = c.handle(.responseCreated(id: "r1"), now: 3.3)
        _ = c.handle(.audioDelta(id: "r1"), now: 3.5)
        _ = c.handle(.responseDone(id: "r1", status: "completed"), now: 4)
        _ = c.handle(.playbackDrained, now: 5)
        XCTAssertEqual(core(c.handle(.tick, now: 6.201)), [.speakMinutesNotice])
        // Words that never come hold it no longer than the grace.
        var lost = BargeInController(profile: .speaker)
        _ = lost.handle(.speechStarted(itemId: "v"), now: 10)
        _ = lost.handle(.minutesWarning, now: 10.2)
        _ = lost.handle(.speechStopped, now: 10.5)
        XCTAssertEqual(core(lost.handle(.tick, now: 13.501)), [.speakMinutesNotice])
    }

    /// On the energy routes the gate hears a voice ~250 ms before the server
    /// VAD: an open gate holds the notice — for a second, not for ever (a
    /// gate held open by the room). And after Interrupt it waits 3 s: they
    /// asked for silence — past the 20 s maximum wait too.
    func test30h_neverIntoAnOpeningGateNorStraightAfterInterrupt() {
        var g = BargeInController(profile: .lowEcho)
        _ = g.handle(.gateOpen, now: 0)
        XCTAssertEqual(core(g.handle(.minutesWarning, now: 0.1)), [.startConfirmTimer(ms: 901)], "the gate hears them first")
        _ = g.handle(.speechStarted(itemId: "u"), now: 0.3)
        XCTAssertEqual(notices(g.handle(.tick, now: 1.001)), 0, "and the VAD agrees")
        _ = g.handle(.speechStopped, now: 1.5)
        _ = g.handle(.gateClose, now: 1.5)
        _ = g.handle(.transcription(text: "move it to Tuesday", itemId: "u", final: true), now: 1.7)
        XCTAssertEqual(count(core(g.handle(.tick, now: 2.2)), .createResponse), 1, "their turn first")
        // The room holds the gate open, the VAD silent: a second, then the notice.
        var room = BargeInController(profile: .lowEcho)
        _ = room.handle(.gateOpen, now: 0)
        XCTAssertEqual(core(room.handle(.minutesWarning, now: 0.2)), [.startConfirmTimer(ms: 801)])
        XCTAssertEqual(core(room.handle(.tick, now: 1.001)), [.speakMinutesNotice])
        // Interrupt: 3 s of silence first (1.2 s was enough before).
        var i = speaking(.speaker)
        _ = i.handle(.minutesWarning, now: 0.5)
        XCTAssertEqual(count(i.handle(.interruptPressed, now: 1.0), .sendCancel), 1)
        _ = i.handle(.responseDone(id: "r1", status: "cancelled"), now: 1.2)
        XCTAssertEqual(notices(i.handle(.tick, now: 2.5)), 0, "they asked for silence")
        XCTAssertEqual(core(i.handle(.tick, now: 4.001)), [.speakMinutesNotice])
        // …even once the notice has waited its 20 s.
        var w = speaking(.speaker)
        _ = w.handle(.minutesWarning, now: 0)
        _ = w.handle(.interruptPressed, now: 19.5)
        _ = w.handle(.responseDone(id: "r1", status: "cancelled"), now: 19.6)
        XCTAssertEqual(notices(w.handle(.tick, now: 20.6)), 0)
        XCTAssertEqual(core(w.handle(.tick, now: 22.501)), [.speakMinutesNotice])
    }

    /// Hold-to-talk: a create already in flight when they press (here the
    /// notice's own) must not play over the held button; and the release's
    /// create that its reply refused is asked again once it is done — before,
    /// nothing asked and their words went unanswered.
    func test30i_holdToTalk_aReplyArrivingWhileHeldIsCut_andARefusedReleaseIsAskedAgain() {
        var h = BargeInController(profile: .speaker, holdToTalk: true)
        XCTAssertEqual(core(h.handle(.minutesWarning, now: 0)), [.speakMinutesNotice])
        XCTAssertEqual(count(h.handle(.pttDown, now: 0.3), .sendCancel), 0, "its create is in flight: nothing to cancel yet")
        let arrived = core(h.handle(.responseCreated(id: "n"), now: 0.6))
        XCTAssertEqual(count(arrived, .sendCancel), 1, "cut as it arrives — never over the held button")
        XCTAssertEqual(h.state, .hold)
        XCTAssertTrue(h.gateContext.forcedOpen, "the mic stays open for them")
        XCTAssertFalse(h.shouldEnqueueAudio(id: "n"))
        XCTAssertTrue(core(h.handle(.pttUp, now: 0.8)).contains(.commitAndRespond))
        // The cancelled reply isn't done yet: the release's create is refused.
        _ = h.handle(.responseAlreadyActive, now: 0.85)
        XCTAssertTrue(h.pendingCreate, "their words are owed an answer")
        XCTAssertEqual(count(core(h.handle(.responseDone(id: "n", status: "cancelled"), now: 0.9)), .createResponse), 1,
                       "asked again once it is done")
        _ = h.handle(.responseCreated(id: "p1"), now: 1.2)
        XCTAssertFalse(h.pendingCreate)
        XCTAssertTrue(h.shouldEnqueueAudio(id: "p1"))
        // A release whose create was answered is never asked twice.
        var ok = BargeInController(profile: .speaker, holdToTalk: true)
        _ = ok.handle(.pttDown, now: 0)
        _ = ok.handle(.pttUp, now: 1)
        _ = ok.handle(.responseCreated(id: "p"), now: 1.3)
        _ = ok.handle(.responseAlreadyActive, now: 1.5)   // another create collided with its reply
        XCTAssertFalse(ok.pendingCreate)
    }

    // MARK: the review flag and the loudspeaker (analytics review, 2026-09-24)

    /// The voice review flag (VoiceIntegrityGuard.periodReviewed) clears only
    /// when the app answers a REAL user turn — the client calls
    /// userTurnAnswered() on exactly `.createResponse` / `.commitAndRespond`
    /// (VoiceRealtimeClient). The loudspeaker echo of the spoken review fires
    /// speech_started and even transcribes, but the controller turns it into
    /// no answer, so the flag survives it and the review is never bounced as
    /// a false claim. Android's rule; the same on all three.
    func testTheReviewsOwnEchoNeverClearsTheReviewFlag() {
        var g = VoiceIntegrityGuard()
        func apply(_ cmds: [BargeInCommand]) {
            for c in cmds where c == .createResponse || c == .commitAndRespond { g.userTurnAnswered() }
        }
        g.toolFinished("get_period_review", result: "ok: review of last week (Mon 14 Sep – Sun 20 Sep).")
        var c = speaking(.speaker)
        said(&c, "You finished the report and kept Stretch five days.")
        apply(c.handle(.speechStarted(itemId: "echo"), now: 1.0))
        apply(c.handle(.speechStopped, now: 1.3))
        apply(c.handle(.transcription(text: "you finished the report and kept stretch five days", itemId: "echo", final: true), now: 1.4))
        apply(c.handle(.tick, now: 2.0))
        XCTAssertTrue(g.periodReviewed, "echo is not a user turn")
        g.responseCreated()
        g.transcriptDelta("You also completed \"Tax return\".")
        XCTAssertFalse(g.shouldCorrect(), "the rest of the review still reads as a review")
        // The user's real next question is answered — and only then does the review stop vouching.
        apply(c.handle(.responseDone(id: "r1", status: "completed"), now: 3.0))
        apply(c.handle(.playbackDrained, now: 3.2))
        apply(c.handle(.speechStarted(itemId: "q"), now: 5))
        apply(c.handle(.speechStopped, now: 6))
        apply(c.handle(.transcription(text: "what have I got left today", itemId: "q", final: true), now: 6.3))
        apply(c.handle(.tick, now: 6.8))
        XCTAssertFalse(g.periodReviewed)
    }
}
