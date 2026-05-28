// Verify the oklch→sRGB conversion against known anchors so the brand
// palette renders the intended colors (not eyeballed approximations).

import XCTest
import SwiftUI
@testable import UnstuckDesign

final class OKLCHTests: XCTestCase {

    private func rgb(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        OKLCH(l, c, h).toRGB()
    }

    func testWhite() {
        let (r, g, b) = rgb(1.0, 0.0, 0.0)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 1.0, accuracy: 0.01)
        XCTAssertEqual(b, 1.0, accuracy: 0.01)
    }

    func testBlack() {
        let (r, g, b) = rgb(0.0, 0.0, 0.0)
        XCTAssertEqual(r, 0.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
    }

    func testMidGrayIsNeutral() {
        // oklch with zero chroma → equal channels (a neutral gray).
        let (r, g, b) = rgb(0.6, 0.0, 0.0)
        XCTAssertEqual(r, g, accuracy: 0.005)
        XCTAssertEqual(g, b, accuracy: 0.005)
        XCTAssertGreaterThan(r, 0.4)
        XCTAssertLessThan(r, 0.75)
    }

    func testInkIsDarkBluish() {
        // --u-ink = oklch(0.22 0.02 280): dark, all channels low.
        let (r, g, b) = rgb(0.22, 0.02, 280)
        XCTAssertLessThan(r, 0.35)
        XCTAssertLessThan(g, 0.35)
        XCTAssertLessThan(b, 0.4)
    }

    func testCoralIsWarm() {
        // --u-coral = oklch(0.72 0.13 35): red channel highest, blue lowest.
        let (r, g, b) = rgb(0.72, 0.13, 35)
        XCTAssertGreaterThan(r, g)
        XCTAssertGreaterThan(g, b)
    }

    func testPrimaryIndigoIsBlueDominant() {
        // --u-primary = oklch(0.58 0.13 280): blue channel highest.
        let (r, g, b) = rgb(0.58, 0.13, 280)
        XCTAssertGreaterThan(b, r)
        XCTAssertGreaterThan(b, g)
    }

    func testClampStaysInGamut() {
        // A very saturated value stays clamped to [0,1].
        let (r, g, b) = rgb(0.5, 0.4, 120)
        for v in [r, g, b] {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    func testHexParsesCream() {
        // Smoke: Color(hex:) doesn't crash on the cream token.
        _ = Color(hex: "#FAFAF7")
    }
}
