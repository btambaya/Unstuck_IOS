// Guided-tour round 4 pure-logic tests:
//  • the SCOPED settings exemption — tourClaims() passes through only the
//    pushed section's content while a settings step's sheet is up; the nav
//    bar / root list (Sign out, Delete account, Export) stay claimed, and an
//    unresolved region fails CLOSED (panel-only);
//  • which steps are scoped (settings) vs. blanket-exempt (assistant/reentry);
//  • TourStore.clear — the per-account wipe the sign-out scrub relies on.

import UIKit
import XCTest
@testable import Unstuck

final class TourScopedSurfaceClaimTests: XCTestCase {
    private let panel = CGRect(x: 24, y: 500, width: 342, height: 320)
    /// The pushed Notifications section's content region (below the nav bar).
    private let section = CGRect(x: 24, y: 140, width: 366, height: 700)

    private func settingsStep(_ mutate: (inout TourClaimContext) -> Void = { _ in }) -> TourClaimContext {
        var ctx = TourClaimContext()
        ctx.running = true
        ctx.panelFrame = panel
        ctx.presentationActive = true
        ctx.surfaceExempt = true
        ctx.surfaceScoped = true
        mutate(&ctx)
        return ctx
    }

    func testScopedSurfacePassesThroughOnlyInsideTheSection() {
        let ctx = settingsStep { $0.surfaceRect = section }
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 300), ctx: ctx),
                       "the pushed section's controls (Calm / Balanced / Coach) are usable")
        XCTAssertFalse(tourClaims(point: CGPoint(x: 30, y: 145), ctx: ctx), "section top-left corner")
    }

    func testScopedSurfaceClaimsTheNavigationBar() {
        // The Back button lives above the section rect — swallowed, so the
        // tester can't pop to the root list mid-tour.
        let ctx = settingsStep { $0.surfaceRect = section }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 30, y: 100), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 60), ctx: ctx))
    }

    func testScopedSurfaceClaimsThePopGestureEdge() {
        // The resolver insets the leading edge out of the rect; a point left
        // of it (the interactive-pop strip) is claimed.
        let ctx = settingsStep { $0.surfaceRect = section }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 5, y: 300), ctx: ctx))
    }

    func testScopedSurfaceWithNoRegionFailsClosed() {
        // Section not pushed yet / popped back to the root / UIKit stack
        // unreadable → nothing but the panel passes: the root list with
        // Sign out / Delete account / Export is never reachable.
        let ctx = settingsStep { $0.surfaceRect = nil }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 300), ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 900), ctx: ctx), "root 'Sign out' row area")
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx), "panel still interactive")
    }

    func testScopedSurfaceWithADegenerateRegionFailsClosed() {
        let ctx = settingsStep { $0.surfaceRect = CGRect(x: 24, y: 140, width: 0, height: 0) }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 24, y: 140), ctx: ctx))
    }

    func testPanelStaysInteractiveOverTheSection() {
        // The panel outranks the section pass-through where they overlap.
        let ctx = settingsStep { $0.surfaceRect = CGRect(x: 0, y: 0, width: 400, height: 900) }
        XCTAssertTrue(tourClaims(point: CGPoint(x: 100, y: 600), ctx: ctx))
    }

    func testUnscopedExemptionIsUnchanged() {
        // assistant/reentry: the whole opened sheet stays usable (you type
        // into it) — the round-3 behaviour, untouched by the scoping.
        var ctx = settingsStep { $0.surfaceRect = nil }
        ctx.surfaceScoped = false
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 300), ctx: ctx))
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 900), ctx: ctx))
    }

    func testNonExemptStepIgnoresTheSurfaceRect() {
        // A display-only step (task detail / inbox / insights) claims the sheet
        // even if some region was resolved.
        var ctx = settingsStep { $0.surfaceRect = section }
        ctx.surfaceExempt = false
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 300), ctx: ctx))
    }

    func testOnlySettingsStepsAreScoped() {
        for step in TourScript.full + TourScript.essential {
            XCTAssertEqual(step.surfaceScoped, step.view == .settings, step.id)
            if step.surfaceScoped { XCTAssertTrue(step.surfaceInteractive, step.id) }
        }
        XCTAssertTrue(TourScript.full.contains { $0.surfaceScoped })
        XCTAssertTrue(TourScript.full.contains { $0.surfaceInteractive && !$0.surfaceScoped },
                      "assistant/reentry keep the blanket exemption")
    }
}

/// The a11y half of the lockdown. The invariant under test: the app window is
/// hidden from VoiceOver EXACTLY while `tourClaims` swallows every app point.
/// Hiding it on a step that passes a real control through (the ringed assistant
/// launcher; the section a settings step opens) made those steps followable by
/// sighted users only — the control simply wasn't in the accessibility tree.
final class TourAccessibilityHidingTests: XCTestCase {
    private let ring = CGRect(x: 20, y: 600, width: 360, height: 180)

    private func running(_ mutate: (inout TourClaimContext) -> Void = { _ in }) -> TourClaimContext {
        var ctx = TourClaimContext()
        ctx.running = true
        ctx.panelFrame = CGRect(x: 24, y: 60, width: 342, height: 320)
        mutate(&ctx)
        return ctx
    }

    func testAnOrdinaryStepHidesTheAppWindow() {
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: running()))
    }

    func testADisplayOnlyRingStillHidesTheAppWindow() {
        // The Start-Next hero is ringed but swallowed, so hiding it is right:
        // nothing under the scrim is operable by anyone.
        let ctx = running { $0.targetRect = ring; $0.cutoutInteractive = false }
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: ctx))
        XCTAssertTrue(tourClaims(point: CGPoint(x: 200, y: 690), ctx: ctx), "ring swallowed")
    }

    func testACutoutInteractiveStepLeavesTheAppWindowReachable() {
        // The assistant launcher takes real touches here, so VoiceOver must be
        // able to find it.
        let ctx = running { $0.targetRect = ring; $0.cutoutInteractive = true }
        XCTAssertFalse(tourHidesAppFromAccessibility(ctx: ctx))
        XCTAssertFalse(tourClaims(point: CGPoint(x: 200, y: 690), ctx: ctx), "ring passes through")
    }

    func testACutoutInteractiveStepWithNoResolvedRingStillHides() {
        // Nothing is passed through until the anchor resolves — fail closed.
        let ctx = running { $0.cutoutInteractive = true; $0.targetRect = nil }
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: ctx))
    }

    func testAnInteractiveStepOpenedSurfaceLeavesTheAppWindowReachable() {
        // Settings → Notifications: the section IS the step, so its controls
        // have to be in the tree.
        let ctx = running { $0.presentationActive = true; $0.surfaceExempt = true; $0.surfaceScoped = true }
        XCTAssertFalse(tourHidesAppFromAccessibility(ctx: ctx))
    }

    func testADisplayOnlyPresentedSheetStaysHidden() {
        // Task detail / inbox / insights: presented but swallowed.
        let ctx = running { $0.presentationActive = true; $0.surfaceExempt = false }
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: ctx))
    }

    func testDemoFocusStepsHideEvenWithAPresentationUp() {
        // tourClaims puts demoStep above presentationActive; so does this.
        let ctx = running { $0.demoStep = true; $0.presentationActive = true; $0.surfaceExempt = true }
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: ctx))
    }

    func testTheWelcomeCardHidesEverything() {
        var ctx = TourClaimContext()
        ctx.cardVisible = true
        XCTAssertTrue(tourHidesAppFromAccessibility(ctx: ctx))
    }

    func testNothingIsHiddenWhileTheTourIsAway() {
        // Paused (chip only) / hidden: the app is fully usable, so it must be
        // fully reachable too.
        var ctx = TourClaimContext()
        ctx.chipVisible = true
        XCTAssertFalse(tourHidesAppFromAccessibility(ctx: ctx))
        XCTAssertFalse(tourHidesAppFromAccessibility(ctx: TourClaimContext()))
    }

    /// The invariant, stated as a property: whenever the app window is hidden,
    /// there must be no point the claim passes through to it.
    func testHidingImpliesEveryPointIsSwallowed() {
        let probes = (0..<40).map { CGPoint(x: 20 + Double($0 % 8) * 45, y: 40 + Double($0 / 8) * 170) }
        for cutout in [false, true] {
            for presented in [false, true] {
                for exempt in [false, true] {
                    for demo in [false, true] {
                        let ctx = running {
                            $0.targetRect = ring
                            $0.cutoutInteractive = cutout
                            $0.presentationActive = presented
                            $0.surfaceExempt = exempt
                            $0.demoStep = demo
                        }
                        guard tourHidesAppFromAccessibility(ctx: ctx) else { continue }
                        for p in probes {
                            XCTAssertTrue(tourClaims(point: p, ctx: ctx),
                                          "hidden from VoiceOver but \(p) passes touches through "
                                          + "(cutout:\(cutout) presented:\(presented) exempt:\(exempt) demo:\(demo))")
                        }
                    }
                }
            }
        }
    }
}

final class TourStoreClearTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.tour.clear.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testClearForgetsTheRunEntirely() {
        let defaults = freshDefaults()
        let store = TourStore(defaults: defaults)
        store.save { $0.started = true; $0.paused = true; $0.index = 6; $0.mode = .full; $0.eligible = true }
        TourStore.clear(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: TourStore.key))
        XCTAssertEqual(store.load(), TourState())
        // The next account on this device is a blank slate: no resume card for
        // the previous user's paused run, no inherited eligibility.
        XCTAssertEqual(tourInitialPhase(store.load()), .hidden)
    }

    func testClearIsIdempotentOnAnEmptyStore() {
        let defaults = freshDefaults()
        TourStore.clear(defaults: defaults)
        TourStore(defaults: defaults).clear()
        XCTAssertEqual(TourStore(defaults: defaults).load(), TourState())
    }

    func testFreshEligibilityAfterClearOffersTheWelcomeOnce() {
        // completeOnboarding re-arms `eligible` for the NEXT account after the
        // scrub cleared A's run: B gets the one-time welcome, not A's
        // "Continue your tour?" card.
        let defaults = freshDefaults()
        let store = TourStore(defaults: defaults)
        store.save { $0.started = true; $0.paused = true; $0.index = 4; $0.mode = .essential }
        TourStore.clear(defaults: defaults)
        store.save { $0.eligible = true }
        XCTAssertEqual(tourInitialPhase(store.load()), .welcome)
    }
}
