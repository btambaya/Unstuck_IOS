// Tour narration player — the bundled Cherry m4a clips (the SAME files the
// web serves from public/tour-audio/), one per step id. AVAudioPlayer with
// enableRate so the speed cycle (0.75→2, pitch-preserving) applies live.
//
// Behavior parity with web listen-bar.tsx (audio path):
//  • auto-plays each new step while in Listen mode;
//  • pausing a step never force-resumes THAT step (the next step starts fresh);
//  • play/pause/replay + speed cycle + smooth progress;
//  • a missing/undecodable clip hides Listen for that step (never a crash —
//    and no on-device TTS fallback: the bundled voice or nothing, per spec).

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class TourAudioPlayer {
    private(set) var playing = false
    /// 0…1 for the progress bar.
    private(set) var progress: Double = 0
    /// Whether the CURRENT step has a playable clip (Listen hidden otherwise).
    private(set) var available = false

    /// The user's chosen narration speed (persisted by the orchestrator).
    var speed: Double = 1 {
        didSet { player?.rate = Float(speed) }
    }

    private var player: AVAudioPlayer?
    private var stepId: String?
    /// The user paused this step — the same step must never force-resume.
    private var userPaused = false
    /// WE configured + activated the shared audio session (configureSession
    /// actually ran, vs. skipping for a live record session) — the only case
    /// stop() may deactivate it.
    private var activatedSession = false
    private var tickTask: Task<Void, Never>?
    private let delegateProxy = DelegateProxy()

    static let voiceLabel = "Cherry"

    init() {
        delegateProxy.onFinish = { [weak self] in
            guard let self else { return }
            self.stopTick()
            self.progress = 1
            self.playing = false
        }
    }

    /// Locate a step's clip in the bundle: flat resource first (xcodegen adds
    /// the files to the app's resources phase → bundle root), then the
    /// TourAudio subdirectory (folder-reference layout), so either wiring works.
    nonisolated static func url(forStep id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "m4a")
            ?? Bundle.main.url(forResource: id, withExtension: "m4a", subdirectory: "TourAudio")
    }

    nonisolated static func hasAudio(forStep id: String) -> Bool {
        url(forStep: id) != nil
    }

    /// Load a step's clip (fresh state) and optionally auto-play (Listen mode).
    /// Re-preparing the SAME step is a no-op so a panel re-render can't restart
    /// a step the user paused.
    func prepare(step id: String, autoplay: Bool) {
        guard id != stepId else { return }
        stopTick()
        player?.stop()
        player = nil
        stepId = id
        userPaused = false
        playing = false
        progress = 0
        guard let url = Self.url(forStep: id), let p = try? AVAudioPlayer(contentsOf: url) else {
            available = false
            return
        }
        p.enableRate = true
        p.rate = Float(speed)
        p.delegate = delegateProxy
        p.prepareToPlay()
        player = p
        available = true
        if autoplay { play() }
    }

    func play() {
        guard let player else { return }
        userPaused = false
        configureSession()
        if progress >= 1 { player.currentTime = 0; progress = 0 }
        player.rate = Float(speed)
        if player.play() {
            playing = true
            startTick()
        }
    }

    func pause() {
        userPaused = true
        player?.pause()
        playing = false
        stopTick()
    }

    func playPause() { playing ? pause() : play() }

    func replay() {
        guard let player else { return }
        userPaused = false
        player.currentTime = 0
        progress = 0
        play()
    }

    /// Cycle 0.75 → 1 → 1.25 → 1.5 → 1.75 → 2 → 0.75; applies live (enableRate).
    func cycleSpeed() {
        speed = nextTourSpeed(speed)
    }

    /// Stop + release (Read-mode switch, tour pause/exit). Deactivates the
    /// shared session only if WE activated it AND nothing else is using it —
    /// the focus ambient bed keeps playing, and a record-capable session
    /// (voice Talk / Focus Copilot) is never yanked out from under its owner.
    /// Mirrors AmbientAudio.teardown's release discipline.
    func stop() {
        stopTick()
        player?.stop()
        player = nil
        stepId = nil
        playing = false
        progress = 0
        available = false
        guard activatedSession else { return }
        activatedSession = false
        let session = AVAudioSession.sharedInstance()
        if !AmbientAudio.shared.isRunning,
           session.category != .playAndRecord, session.category != .record {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - internals

    /// Playback category so narration is audible with the ring switch muted;
    /// mixWithOthers keeps it polite (matches AmbientAudio's session config).
    /// A live RECORD-capable session (voice Talk's .playAndRecord, the
    /// copilot's .record) is never flipped to .playback — that would cut the
    /// mic mid-capture; narration just plays through the existing config.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord, session.category != .record else { return }
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        activatedSession = true
    }

    private func startTick() {
        stopTick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, let p = self.player else { return }
                if p.duration > 0 {
                    self.progress = min(1, p.currentTime / p.duration)
                }
                if !p.isPlaying && self.playing && self.progress < 1 {
                    // Interrupted externally (call, route change) — reflect it.
                    self.playing = false
                    return
                }
            }
        }
    }

    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }

}

/// AVAudioPlayerDelegate requires NSObject; the callback can arrive off the
/// main thread, so it hops to the main actor for the observable state writes.
/// `onFinish` is set once at init (before any playback) — hence @unchecked.
private final class DelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor @Sendable () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let cb = onFinish
        Task { @MainActor in cb?() }
    }
}
