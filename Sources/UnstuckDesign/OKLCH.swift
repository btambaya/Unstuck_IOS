// The web brand tokens are authored in oklch (app/globals.css). SwiftUI
// has no oklch color, so we convert oklch → oklab → linear sRGB → gamma
// to reproduce the exact brand colors rather than eyeball hex. This is
// the standard oklab matrix (Björn Ottosson).

import SwiftUI

public struct OKLCH: Sendable, Equatable {
    public let l: Double   // perceptual lightness 0…1
    public let c: Double   // chroma
    public let h: Double   // hue degrees
    public let alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l; self.c = c; self.h = h; self.alpha = alpha
    }

    /// Linear-to-gamma sRGB components in 0…1 (clamped).
    public func toRGB() -> (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let bb = c * sin(hr)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = l - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = l - 0.0894841775 * a - 1.2914855480 * bb

        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        let rLin =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        func gamma(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        return (gamma(rLin), gamma(gLin), gamma(bLin))
    }

    public var color: Color {
        let (r, g, b) = toRGB()
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

public extension Color {
    /// Parse `#RRGGBB` (the few non-oklch tokens: cream / surface).
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
