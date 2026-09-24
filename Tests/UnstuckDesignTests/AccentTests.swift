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

    /// Ahmad, 2026-09-24: every ON switch is the brand coral — not the old
    /// indigo `primary`, not the rust `coralDeep` — in both schemes. The
    /// coral track stays clearly apart from the dark background (the light
    /// one is the same class as iOS's own green switch, ≈2.2:1 on white).
    func testSwitchOnIsTheBrandCoralInBothSchemes() {
        for p in [Palette.light, Palette.dark] {
            XCTAssertEqual(luminance(p.switchOn), luminance(p.coral), accuracy: 1e-9)
            XCTAssertNotEqual(luminance(p.switchOn), luminance(p.primary), accuracy: 1e-3, "never the indigo")
            XCTAssertNotEqual(luminance(p.switchOn), luminance(p.coralDeep), accuracy: 1e-3, "never the rust")
            let r = p.switchOn.resolve(in: EnvironmentValues())
            XCTAssertEqual(Double(r.red), 0xE8 / 255.0, accuracy: 0.004)
            XCTAssertEqual(Double(r.green), 0x90 / 255.0, accuracy: 0.004)
            XCTAssertEqual(Double(r.blue), 0x77 / 255.0, accuracy: 0.004)
        }
        XCTAssertGreaterThan(contrast(Palette.dark.switchOn, Palette.dark.bg), 6)
        XCTAssertGreaterThan(contrast(Palette.light.switchOn, Palette.light.bg), 2.1)
    }

    /// Eyebrows are neutral: SectionLabel paints its own Text `ink3`, and an
    /// outer `.foregroundStyle` never reaches it — which is why the old
    /// `SectionLabel(…).foregroundStyle(primaryDeep)` call sites rendered
    /// grey all along (and were removed as dead code, not recoloured).
    @MainActor
    func testSectionLabelIgnoresAnOuterForegroundStyleAndStaysInk3() throws {
        let p = Palette.light
        let view = SectionLabel("WWWWWWWW")
            .foregroundStyle(p.primaryDeep)
            .padding(4)
            .background(Color.white)
            .environment(\.uTheme, UTheme(palette: p))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage, "the label did not render")
        let (w, h) = (cg.width, cg.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The darkest glyph pixels carry the text colour at full coverage.
        var darkest = (lum: 3.0 * 255, r: 0.0, g: 0.0, b: 0.0)
        for i in stride(from: 0, to: px.count, by: 4) {
            let (r, g, b) = (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
            if r + g + b < darkest.lum { darkest = (r + g + b, r, g, b) }
        }
        func rgb(_ c: Color) -> (Double, Double, Double) {
            let r = c.resolve(in: EnvironmentValues())
            return (Double(r.red) * 255, Double(r.green) * 255, Double(r.blue) * 255)
        }
        func dist(_ c: (Double, Double, Double)) -> Double {
            let d = (darkest.r - c.0, darkest.g - c.1, darkest.b - c.2)
            return (d.0 * d.0 + d.1 * d.1 + d.2 * d.2).squareRoot()
        }
        XCTAssertLessThan(dist(rgb(p.ink3)), dist(rgb(p.primaryDeep)),
                          "the eyebrow rendered the outer indigo, not its own ink3")
        // …and it is not blue-shifted the way the indigo is.
        XCTAssertLessThan(darkest.b - darkest.r, 30, "eyebrow glyphs look indigo: \(darkest)")
    }

    /// The `bg`-on-`ink` chip pair the Share screen's monograms and filled
    /// buttons use inverts with the scheme; `.white` on dark `ink` did not.
    func testInkOnBgChipPairIsLegibleInBothSchemesAndWhiteOnDarkInkIsNot() {
        XCTAssertGreaterThan(contrast(Palette.light.bg, Palette.light.ink), 12)
        XCTAssertGreaterThan(contrast(Palette.dark.bg, Palette.dark.ink), 12)
        XCTAssertLessThan(contrast(.white, Palette.dark.ink), 1.2, "the shipped dark-mode invisibility")
    }
}
