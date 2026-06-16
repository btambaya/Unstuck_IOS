// Brand-v2 palette + theme. Values ported verbatim from
// ../unstuck/app/globals.css (:root light + .u-dark). Colors render via
// the oklch→sRGB converter so they match the web exactly.

import SwiftUI

public struct Palette: Sendable {
    public let bg, bg2, surface: Color
    public let ink, ink2, ink3, ink4: Color
    public let line, line2: Color
    // `var` (not `let`): the accent remap (`withAccent`) rewrites these ramps.
    public var primary, primarySoft, primaryDeep: Color
    public var coral, coralSoft, coralDeep: Color
    public let violet, blue, green, amber, red: Color
    /// Soft fills + readable "ink" shades for status chips / rollups (Android parity).
    public let greenInk, greenSoft, blueSoft, blueInk, amberSoft, amberInk: Color
    /// Start-Next hero gradient (lavender→pink light, indigo→plum dark).
    public let heroGradient: [Color]

    public static let light = Palette(
        bg: Color(hex: "#FAFAF7"), bg2: Color(hex: "#F4F2EC"), surface: Color(hex: "#FFFFFF"),
        // Exact hex (matches Android's literal ink/ink2) so primary + secondary
        // text render identically across platforms, not via an OKLCH approximation.
        ink: Color(hex: "#1A1C26"), ink2: Color(hex: "#414252"),
        ink3: OKLCH(0.58, 0.02, 280).color, ink4: OKLCH(0.78, 0.01, 280).color,
        line: OKLCH(0.92, 0.005, 280).color, line2: OKLCH(0.88, 0.008, 280).color,
        primary: OKLCH(0.58, 0.13, 280).color, primarySoft: OKLCH(0.93, 0.04, 280).color,
        primaryDeep: OKLCH(0.42, 0.13, 280).color,
        coral: Color(hex: "#E89077"), coralSoft: OKLCH(0.94, 0.05, 40).color,
        coralDeep: OKLCH(0.48, 0.16, 35).color,
        violet: OKLCH(0.55, 0.13, 300).color, blue: OKLCH(0.70, 0.10, 240).color,
        green: OKLCH(0.72, 0.10, 155).color, amber: OKLCH(0.80, 0.13, 75).color,
        red: OKLCH(0.66, 0.13, 25).color,
        greenInk: OKLCH(0.40, 0.10, 155).color, greenSoft: OKLCH(0.94, 0.04, 155).color,
        blueSoft: OKLCH(0.94, 0.03, 240).color, blueInk: OKLCH(0.40, 0.10, 240).color,
        amberSoft: OKLCH(0.95, 0.05, 75).color, amberInk: OKLCH(0.45, 0.13, 75).color,
        heroGradient: [OKLCH(0.96, 0.04, 280).color, OKLCH(0.95, 0.05, 320).color])

    public static let dark = Palette(
        bg: OKLCH(0.205, 0.025, 270).color, bg2: OKLCH(0.24, 0.03, 270).color, surface: OKLCH(0.26, 0.03, 270).color,
        ink: OKLCH(0.96, 0.005, 270).color, ink2: OKLCH(0.82, 0.01, 270).color,
        ink3: OKLCH(0.66, 0.015, 270).color, ink4: OKLCH(0.45, 0.02, 270).color,
        line: OKLCH(0.34, 0.025, 270).color, line2: OKLCH(0.38, 0.03, 270).color,
        primary: OKLCH(0.72, 0.13, 280).color, primarySoft: OKLCH(0.32, 0.07, 280).color,
        primaryDeep: OKLCH(0.82, 0.12, 280).color,
        coral: Color(hex: "#E89077"), coralSoft: OKLCH(0.36, 0.08, 35).color,
        coralDeep: OKLCH(0.58, 0.16, 35).color,
        violet: OKLCH(0.74, 0.13, 300).color, blue: OKLCH(0.70, 0.10, 240).color,
        green: OKLCH(0.72, 0.10, 155).color, amber: OKLCH(0.80, 0.13, 75).color,
        red: OKLCH(0.66, 0.13, 25).color,
        greenInk: OKLCH(0.86, 0.10, 155).color, greenSoft: OKLCH(0.34, 0.07, 155).color,
        blueSoft: OKLCH(0.34, 0.06, 240).color, blueInk: OKLCH(0.86, 0.08, 240).color,
        amberSoft: OKLCH(0.36, 0.08, 75).color, amberInk: OKLCH(0.88, 0.11, 75).color,
        heroGradient: [OKLCH(0.34, 0.09, 280).color, OKLCH(0.30, 0.07, 322).color])

    /// Resolve a life-area / collection color token (indigo, coral, …) to
    /// a Color. Mirrors the web area palette mapping.
    public func areaColor(_ token: String?) -> Color {
        switch (token ?? "").lowercased() {
        case "indigo", "primary": return primary
        case "coral": return coral
        case "violet": return violet
        case "blue": return blue
        case "green": return green
        case "amber": return amber
        case "red": return red
        default: return ink3
        }
    }
}

/// Corner radii + the brand surface tokens.
public enum Radius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 14
    public static let lg: CGFloat = 22
}

/// Accent palettes — mirror the Android/web ACCENT_PALETTES. Indigo+coral is
/// the brand default (no remap).
public enum Accent: String, CaseIterable, Sendable {
    case indigo, rose, forest
}

public extension Palette {
    /// Override the primary/coral ramps for the chosen accent. Same override
    /// values for light + dark, matching Android's `withAccent`.
    func withAccent(_ accent: Accent) -> Palette {
        var p = self
        switch accent {
        case .indigo:
            return self
        case .rose:
            p.primary = OKLCH(0.62, 0.14, 265).color
            p.primaryDeep = OKLCH(0.42, 0.16, 265).color
            p.primarySoft = OKLCH(0.94, 0.04, 265).color
            p.coral = OKLCH(0.74, 0.14, 15).color
            p.coralSoft = OKLCH(0.95, 0.05, 15).color
            p.coralDeep = OKLCH(0.50, 0.16, 15).color
        case .forest:
            p.primary = OKLCH(0.55, 0.10, 170).color
            p.primaryDeep = OKLCH(0.38, 0.10, 170).color
            p.primarySoft = OKLCH(0.94, 0.04, 170).color
            p.coral = OKLCH(0.74, 0.14, 65).color
            p.coralSoft = OKLCH(0.95, 0.05, 65).color
            p.coralDeep = OKLCH(0.48, 0.13, 65).color
        }
        return p
    }
}

public struct UTheme: Sendable {
    public var palette: Palette
    public init(palette: Palette) { self.palette = palette }
    public static let light = UTheme(palette: .light)
    public static let dark = UTheme(palette: .dark)
}

private struct UThemeKey: EnvironmentKey {
    static let defaultValue = UTheme.light
}

public extension EnvironmentValues {
    var uTheme: UTheme {
        get { self[UThemeKey.self] }
        set { self[UThemeKey.self] = newValue }
    }
}

public extension View {
    /// Inject the brand palette resolved from the current color scheme,
    /// remapped for the chosen accent (Settings · Interface).
    func unstuckTheme(accent: Accent = .indigo) -> some View {
        modifier(UThemeResolver(accent: accent))
    }
}

private struct UThemeResolver: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let accent: Accent
    func body(content: Content) -> some View {
        content.environment(\.uTheme,
                            UTheme(palette: (scheme == .dark ? Palette.dark : Palette.light).withAccent(accent)))
    }
}
