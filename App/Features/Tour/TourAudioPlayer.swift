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
//
// ROUND 2 — "Tell me more" audio: every `more` text has its own Cherry clip
// (<id>-more.m4a). Expanding Tell-me-more in Listen mode PAUSES the narration,
// plays the more clip, and RESUMES the narration where it left off when the
// clip finishes (or when the section is collapsed). `clip` + `progress` always
// describe the ACTIVE clip, so the live captions and the progress bar follow
// whichever clip is speaking.

import AVFoundation
import Foundation
import Observation

/// Which clip the player is currently on (drives captions + progress).
enum TourClipKind: Equatable, Sendable { case narration, more }

@MainActor
@Observable
final class TourAudioPlayer {
    private(set) var playing = false
    /// 0…1 for the progress bar — of the ACTIVE clip.
    private(set) var progress: Double = 0
    /// Whether the CURRENT step has a playable narration clip (Listen hidden
    /// otherwise).
    private(set) var available = false
    /// The clip currently owning playback/captions (narration vs Tell-me-more).
    private(set) var clip: TourClipKind = .narration

    /// The user's chosen narration speed (persisted by the orchestrator).
    var speed: Double = 1 {
        didSet {
            player?.rate = Float(speed)
            morePlayer?.rate = Float(speed)
        }
    }

    private var player: AVAudioPlayer?
    private var morePlayer: AVAudioPlayer?
    private var stepId: String?
    /// The user paused this step — the same step must never force-resume.
    private var userPaused = false
    /// The narration was audibly playing when the more clip took over — it
    /// resumes (from its paused position) once the more clip ends/stops.
    /// CLEARED by an explicit pause() (round 3): collapsing Tell-me-more after
    /// the user paused must stay paused, never restart the narration.
    private var resumeNarrationAfterMore = false
    /// The narration's progress at the moment the more clip took over — the
    /// handback restores THIS when the narration had already finished
    /// naturally (progress 1): AVAudioPlayer rewinds currentTime to 0 after a
    /// natural finish, so recomputing would snap the bar 1 → 0 (round 3).
    private var progressBeforeMore: Double = 0
    /// WE configured + activated the shared audio session (configureSession
    /// actually ran, vs. skipping for a live record session) — the only case
    /// stop() may deactivate it.
    private var activatedSession = false
    private var tickTask: Task<Void, Never>?
    private let delegateProxy = DelegateProxy()

    static let voiceLabel = "Cherry"

    init() {
        delegateProxy.onFinish = { [weak self] finishedId in
            guard let self else { return }
            if let mp = self.morePlayer, ObjectIdentifier(mp) == finishedId {
                self.moreFinished()
            } else if let p = self.player, ObjectIdentifier(p) == finishedId {
                self.stopTick()
                self.progress = 1
                self.playing = false
            }
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

    /// The step's Tell-me-more clip (`<id>-more.m4a`). Missing = the more text
    /// simply expands silently in Listen mode (never a crash).
    nonisolated static func hasMoreAudio(forStep id: String) -> Bool {
        url(forStep: "\(id)-more") != nil
    }

    /// Load a step's clip (fresh state) and optionally auto-play (Listen mode).
    /// Re-preparing the SAME step is a no-op so a panel re-render can't restart
    /// a step the user paused.
    func prepare(step id: String, autoplay: Bool) {
        guard id != stepId else { return }
        stopTick()
        player?.stop()
        player = nil
        morePlayer?.stop()
        morePlayer = nil
        clip = .narration
        resumeNarrationAfterMore = false
        progressBeforeMore = 0
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
        guard let p = activePlayer else { return }
        userPaused = false
        configureSession()
        if progress >= 1 { p.currentTime = 0; progress = 0 }
        p.rate = Float(speed)
        if p.play() {
            playing = true
            startTick()
        }
    }

    func pause() {
        userPaused = true
        // An explicit pause also disarms the pending narration handback — a
        // later Tell-me-more collapse must respect the pause, not restart the
        // narration (round-3 fix).
        resumeNarrationAfterMore = false
        activePlayer?.pause()
        playing = false
        stopTick()
    }

    func playPause() { playing ? pause() : play() }

    /// Replay the ACTIVE clip from the top (the more clip while it's expanded,
    /// the narration otherwise).
    func replay() {
        guard let p = activePlayer else { return }
        userPaused = false
        p.currentTime = 0
        progress = 0
        play()
    }

    /// Cycle 0.75 → 1 → 1.25 → 1.5 → 1.75 → 2 → 0.75; applies live (enableRate).
    func cycleSpeed() {
        speed = nextTourSpeed(speed)
    }

    // MARK: - Tell-me-more clip (round 2)

    /// Expanding Tell-me-more in Listen mode: pause the narration (remembering
    /// whether it was audibly playing) and play the step's `<id>-more.m4a`.
    /// No clip / undecodable → silent no-op (the text still expands).
    func playMore() {
        guard clip == .narration, let stepId,
              let url = Self.url(forStep: "\(stepId)-more"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        resumeNarrationAfterMore = playing
        progressBeforeMore = progress
        stopTick()
        player?.pause()
        p.enableRate = true
        p.rate = Float(speed)
        p.delegate = delegateProxy
        p.prepareToPlay()
        morePlayer = p
        clip = .more
        progress = 0
        userPaused = false
        configureSession()
        if p.play() {
            playing = true
            startTick()
        } else {
            playing = false
        }
    }

    /// Collapsing Tell-me-more: stop the more clip and hand playback back to
    /// the narration (resuming it where it paused, if it had been playing).
    func stopMore() {
        guard clip == .more else { return }
        stopTick()
        morePlayer?.stop()
        morePlayer = nil
        clip = .narration
        playing = false
        restoreNarrationProgress()
        if resumeNarrationAfterMore { play() }
        resumeNarrationAfterMore = false
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
        morePlayer?.stop()
        morePlayer = nil
        clip = .narration
        resumeNarrationAfterMore = false
        progressBeforeMore = 0
        stepId = nil
        playing = false
        progress = 0
        available = false
        guard activatedSession else { return }
        activatedSession = false
        let session = AVAudioSession.sharedInstance()
        if !AmbientAudio.shared.isRunning,
           session.category != .playAndRecord, session.category != .record {
            // Never deactivate the shared session under a live voice conversation —
            // it would silence the call with no error anywhere (audit, 2026-09-11).
            if !VoiceAudioOwnership.isHeld {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
    }

    // MARK: - internals

    private var activePlayer: AVAudioPlayer? { clip == .more ? morePlayer : player }

    /// The more clip finished on its own — back to the narration, resuming it
    /// if it was audibly playing when the more clip took over.
    private func moreFinished() {
        stopTick()
        morePlayer = nil
        clip = .narration
        playing = false
        restoreNarrationProgress()
        if resumeNarrationAfterMore { play() }
        resumeNarrationAfterMore = false
    }

    /// Point `progress` back at the (paused) narration clip's position — or
    /// keep it at 1 when the narration had already finished naturally before
    /// the more clip took over (tourHandbackProgress, pure + unit-tested).
    private func restoreNarrationProgress() {
        progress = tourHandbackProgress(preMoreProgress: progressBeforeMore,
                                        currentTime: player?.currentTime ?? 0,
                                        duration: player?.duration ?? 0)
    }

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
                guard let self, let p = self.activePlayer else { return }
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
/// The finished player crosses as an ObjectIdentifier (Sendable) so the main
/// actor can tell the more clip from the narration. `onFinish` is set once at
/// init (before any playback) — hence @unchecked.
private final class DelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor @Sendable (ObjectIdentifier) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        let cb = onFinish
        Task { @MainActor in cb?(id) }
    }
}
