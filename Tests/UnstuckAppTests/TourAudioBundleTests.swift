// The tour's narration clips as the APP sees them.
//
// TourAudioManifestTests proves the m4a files are on disk in
// App/Resources/TourAudio — it locates them from #filePath, so it would stay
// green if the files stopped being copied into the app bundle (a project.yml
// resource-glob slip). Listen is gated on `TourAudioPlayer.hasAudio`, which
// asks Bundle.main: bundle-less clips mean the Listen toggle silently vanishes
// from every step with nothing failing. These tests close that gap from the
// other side — every step's clip must RESOLVE FROM THE BUNDLE and DECODE.
// No playback here (no audio route to depend on): decoding is what proves the
// bytes are a real AAC clip and not a truncated copy.

import AVFoundation
import XCTest
@testable import Unstuck

final class TourAudioBundleTests: XCTestCase {
    private var allSteps: [TourStep] {
        var seen = Set<String>()
        return (TourScript.essential + TourScript.full).filter { seen.insert($0.id).inserted }
    }

    func testEveryStepsClipsResolveFromTheAppBundleAndDecode() throws {
        for s in allSteps {
            // A clip that no longer matches its step is never offered
            // (TourScript.staleClips — slim settings) — Listen is hidden there.
            if TourScript.staleClips.contains(s.id) {
                XCTAssertFalse(TourAudioPlayer.hasAudio(forStep: s.id),
                               "'\(s.id)': a stale narration clip must never play")
            } else {
                XCTAssertTrue(TourAudioPlayer.hasAudio(forStep: s.id),
                              "'\(s.id)': narration clip is not in the app bundle — Listen would be hidden")
                let url = try XCTUnwrap(TourAudioPlayer.url(forStep: s.id))
                let p = try AVAudioPlayer(contentsOf: url)
                XCTAssertGreaterThan(p.duration, 1, "'\(s.id)': narration clip decodes to nothing")
            }
            guard s.more != nil else { continue }
            if TourScript.staleClips.contains("\(s.id)-more") {
                XCTAssertFalse(TourAudioPlayer.hasMoreAudio(forStep: s.id),
                               "'\(s.id)': a stale Tell-me-more clip must never play")
                continue
            }
            XCTAssertTrue(TourAudioPlayer.hasMoreAudio(forStep: s.id),
                          "'\(s.id)': Tell-me-more clip is not in the app bundle")
            let moreURL = try XCTUnwrap(TourAudioPlayer.url(forStep: "\(s.id)-more"))
            let more = try AVAudioPlayer(contentsOf: moreURL)
            XCTAssertGreaterThan(more.duration, 1, "'\(s.id)': more clip decodes to nothing")
        }
    }

    /// The `today` clips were re-recorded for the hero-less home (2026-09-18).
    /// TourRound2Tests pins the STRINGS they speak; this pins that the bundled
    /// audio is the long new take, not the shorter pre-removal one (17.9 s /
    /// 12.2 s), which the string pin alone cannot see.
    func testTheRegeneratedTodayClipsAreTheOnesInTheBundle() throws {
        let narration = try AVAudioPlayer(contentsOf: try XCTUnwrap(TourAudioPlayer.url(forStep: "today")))
        let more = try AVAudioPlayer(contentsOf: try XCTUnwrap(TourAudioPlayer.url(forStep: "today-more")))
        XCTAssertEqual(narration.duration, 23.1, accuracy: 0.6, "today.m4a is not the regenerated take")
        XCTAssertEqual(more.duration, 13.9, accuracy: 0.6, "today-more.m4a is not the regenerated take")
    }
}
