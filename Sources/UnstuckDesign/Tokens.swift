// Brand-v2 palette + theme. Values ported verbatim from
// ../unstuck/app/globals.css (:root light + .u-dark). Colors render via
// the oklch→sRGB converter so they match the web exactly.

import SwiftUI

public struct Palette: Sendable {
    public let bg, bg2, surface: Color
    public let ink, ink2, ink3, ink4: Color
    public let line, line2: Color
    public let primary, primarySoft, primaryDeep: Color
    public let coral, coralSoft, coralDeep: Color
    public let violet, blue, green, amber, red: Color
    /// Darker, readable "ink" green for small status text (e.g. "done by … ✓").
    public let greenInk: Color

    public static let light = Palette(
        bg: Color(hex: "#FAFAF7"), bg2: Color(hex: "#F4F2EC"), surface: Color(hex: "#FFFFFF"),
        ink: OKLCH(0.22, 0.02, 280).color, ink2: OKLCH(0.40, 0.02, 280).color,
        ink3: OKLCH(0.58, 0.02, 280).color, ink4: OKLCH(0.78, 0.01, 280).color,
        line: OKLCH(0.92, 0.005, 280).color, line2: OKLCH(0.88, 0.008, 280).color,
        primary: OKLCH(0.58, 0.13, 280).color, primarySoft: OKLCH(0.93, 0.04, 280).color,
        primaryDeep: OKLCH(0.42, 0.13, 280).color,
        coral: OKLCH(0.72, 0.13, 35).color, coralSoft: OKLCH(0.94, 0.05, 40).color,
        coralDeep: OKLCH(0.48, 0.16, 35).color,
        violet: OKLCH(0.55, 0.13, 300).color, blue: OKLCH(0.70, 0.10, 240).color,
        green: OKLCH(0.72, 0.10, 155).color, amber: OKLCH(0.80, 0.13, 75).color,
        red: OKLCH(0.66, 0.13, 25).color,
        greenInk: OKLCH(0.40, 0.10, 155).color)

    public static let dark = Palette(
        bg: OKLCH(0.205, 0.025, 270).color, bg2: OKLCH(0.24, 0.03, 270).color, surface: OKLCH(0.26, 0.03, 270).color,
        ink: OKLCH(0.96, 0.005, 270).color, ink2: OKLCH(0.82, 0.01, 270).color,
        ink3: OKLCH(0.66, 0.015, 270).color, ink4: OKLCH(0.45, 0.02, 270).color,
        line: OKLCH(0.34, 0.025, 270).color, line2: OKLCH(0.38, 0.03, 270).color,
        primary: OKLCH(0.72, 0.13, 280).color, primarySoft: OKLCH(0.32, 0.07, 280).color,
        primaryDeep: OKLCH(0.82, 0.12, 280).color,
        coral: OKLCH(0.72, 0.13, 35).color, coralSoft: OKLCH(0.36, 0.08, 35).color,
        coralDeep: OKLCH(0.48, 0.16, 35).color,
        violet: OKLCH(0.74, 0.13, 300).color, blue: OKLCH(0.70, 0.10, 240).color,
        green: OKLCH(0.72, 0.10, 155).color, amber: OKLCH(0.80, 0.13, 75).color,
        red: OKLCH(0.66, 0.13, 25).color,
        greenInk: OKLCH(0.86, 0.10, 155).color)

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
    /// Inject the brand palette resolved from the current color scheme.
    func unstuckTheme() -> some View {
        modifier(UThemeResolver())
    }
}

private struct UThemeResolver: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.uTheme, scheme == .dark ? .dark : .light)
    }
}
