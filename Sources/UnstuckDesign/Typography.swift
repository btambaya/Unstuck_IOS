// Brand fonts (bundled in App/Fonts/, registered via Info.plist UIAppFonts).
// Referenced by their real PostScript names so they actually load (and match
// Android, which bundles the same families); fall back to the system font if
// absent so UnstuckDesign still builds/previews without them.
//   sans  — Geist (UI text)          PS: Geist[-Regular] (variable)
//   serif — Instrument Serif         PS: InstrumentSerif-Regular / -Italic
//   mono  — IBM Plex Mono            PS: IBMPlexMono-Regular / -Medium

import SwiftUI

public enum UFont {
    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    /// Brand serif — Instrument Serif (matches the web app's display face).
    public static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }
    public static func serifItalic(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Italic", size: size)
    }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        // Two real cuts are bundled; pick Medium for any non-regular weight.
        .custom(weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium", size: size)
    }
}
