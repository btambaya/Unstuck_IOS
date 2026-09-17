// The accent remap is SCHEME-AWARE (mirrors unstuck/app/globals.css, which
// defines both halves per accent). The old one-set-fits-both `withAccent`
// applied the light ramp on top of the dark palette — rose / forest in dark
// mode read at ≈1.9:1. An L-ordering assertion (not pinned colours) catches
// any future light/dark swap.

import XCTest
import SwiftUI
@testable import UnstuckDesign

final class AccentTests: XCTestCase {

    /// WCAG relative luminance from the resolved linear sRGB channels.
    private func luminance(_ color: Color) -> Double {
        let r = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testIndigoIsANoOpInBothSchemes() {
        for (base, dark) in [(Palette.light, false), (Palette.dark, true)] {
            let p = base.withAccent(.indigo, dark: dark)
            for pair in [(p.primary, base.primary), (p.primaryDeep, base.primaryDeep),
                         (p.primarySoft, base.primarySoft), (p.coral, base.coral),
                         (p.coralSoft, base.coralSoft), (p.coralDeep, base.coralDeep)] {
                XCTAssertEqual(luminance(pair.0), luminance(pair.1), accuracy: 1e-9)
            }
        }
    }

    func testDarkPrimaryDeepIsLighterThanDarkBgAndLightPrimaryDeepIsDarkerThanLightBg() {
        for accent in Accent.allCases {
            let light = Palette.light.withAccent(accent, dark: false)
            let dark = Palette.dark.withAccent(accent, dark: true)
            XCTAssertLessThan(luminance(light.primaryDeep), luminance(light.bg),
                              "\(accent): light primaryDeep must be darker than the light background")
            XCTAssertGreaterThan(luminance(dark.primaryDeep), luminance(dark.bg),
                                 "\(accent): dark primaryDeep must be lighter than the dark background")
            // primarySoft is a tint of the background, never the opposite pole.
            XCTAssertGreaterThan(luminance(light.primarySoft), luminance(light.primary),
                                 "\(accent): light primarySoft sits near the light bg")
            XCTAssertLessThan(luminance(dark.primarySoft), luminance(dark.primary),
                              "\(accent): dark primarySoft sits near the dark bg")
            XCTAssertLessThan(luminance(dark.coralSoft), luminance(dark.coral), "\(accent): dark coralSoft is a dark tint")
            // The text links the app paints in primaryDeep stay readable.
            XCTAssertGreaterThan(contrast(light.primaryDeep, light.bg), 4.5, "\(accent) light eyebrow / text link")
            XCTAssertGreaterThan(contrast(dark.primaryDeep, dark.bg), 4.5, "\(accent) dark eyebrow / text link")
        }
    }

    func testTheDarkRampSwapsOnlyWhatTheWebSwaps() {
        // The web's dark accent block overrides primary / primaryDeep /
        // primarySoft / coralSoft; coral and coralDeep keep the light values.
        for accent in [Accent.rose, .forest] {
            let light = Palette.light.withAccent(accent, dark: false)
            let dark = Palette.dark.withAccent(accent, dark: true)
            XCTAssertEqual(luminance(light.coral), luminance(dark.coral), accuracy: 1e-9, "\(accent) coral")
            XCTAssertEqual(luminance(light.coralDeep), luminance(dark.coralDeep), accuracy: 1e-9, "\(accent) coralDeep")
            XCTAssertNotEqual(luminance(light.primary), luminance(dark.primary), "\(accent) primary")
            XCTAssertNotEqual(luminance(light.primaryDeep), luminance(dark.primaryDeep), "\(accent) primaryDeep")
            XCTAssertNotEqual(luminance(light.primarySoft), luminance(dark.primarySoft), "\(accent) primarySoft")
            XCTAssertNotEqual(luminance(light.coralSoft), luminance(dark.coralSoft), "\(accent) coralSoft")
        }
    }

    /// The `bg`-on-`ink` chip pair the Share screen's monograms and filled
    /// buttons use inverts with the scheme; `.white` on dark `ink` did not.
    func testInkOnBgChipPairIsLegibleInBothSchemesAndWhiteOnDarkInkIsNot() {
        XCTAssertGreaterThan(contrast(Palette.light.bg, Palette.light.ink), 12)
        XCTAssertGreaterThan(contrast(Palette.dark.bg, Palette.dark.ink), 12)
        XCTAssertLessThan(contrast(.white, Palette.dark.ink), 1.2, "the shipped dark-mode invisibility")
    }
}
