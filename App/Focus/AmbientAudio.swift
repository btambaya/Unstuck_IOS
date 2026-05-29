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
        let noise = self.noise
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
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
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        do { try engine.start(); running = true } catch { teardown() }
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
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }
}
