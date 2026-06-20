// Procedural ambient sound for the focus "ambient" treatment — soft brown
// noise generated on the fly (no bundled audio asset). Mixes with other
// audio and ducks nothing. Best-effort; silently no-ops if the engine
// can't start.

import Foundation
import AVFoundation

@MainActor
final class AmbientAudio {
    static let shared = AmbientAudio()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var running = false

    // Real-time-safe state: a small xorshift RNG + a leaky integrator for
    // brown noise. @unchecked Sendable so the render closure can capture it.
    private final class Noise: @unchecked Sendable {
        var seed: UInt32 = 0x12345678
        var last: Float = 0
        func white() -> Float {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return (Float(seed) / Float(UInt32.max)) * 2 - 1
        }
    }
    private let noise = Noise()

    func start() {
        guard !running else { return }
        configureSession()
        let format = engine.outputNode.inputFormat(forBus: 0)
        // A 0-channel / 0-rate output format (no audio route — e.g. the
        // simulator) makes engine.connect throw an uncatchable ObjC exception.
        // Bail before connecting; ambient sound is best-effort.
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        // The render block runs on the real-time AUDIO thread, so it must NOT be
        // main-actor-isolated — build it in a nonisolated context, else Swift 6's
        // executor check (swift_task_checkIsolatedSwift) SIGTRAPs at render time.
        let node = AVAudioSourceNode(renderBlock: Self.renderBlock(noise))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        do { try engine.start(); running = true } catch { teardown() }
    }

    /// Build the real-time render block in a NONISOLATED context so the closure
    /// doesn't inherit AmbientAudio's @MainActor isolation. It runs on the audio
    /// IO thread; a main-actor executor check there fires SIGTRAP under Swift 6.
    /// Captures only `noise` (a Sendable box).
    private nonisolated static func renderBlock(_ noise: Noise) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                noise.last = (noise.last + 0.02 * noise.white()) / 1.02
                let sample = noise.last * 3.0 * 0.12   // gentle gain
                for buffer in buffers {
                    if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        data[frame] = sample
                    }
                }
            }
            return noErr
        }
    }

    func stop() {
        guard running else { return }
        teardown()
    }

    private func teardown() {
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        running = false
        // configureSession() left the shared session active; release it so the
        // .playback category doesn't leak into whatever plays next (and so the
        // system can power down audio). .notifyOthersOnDeactivation lets other
        // apps resume. Matches VoiceAudioEngine.deactivateSession().
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }
}
