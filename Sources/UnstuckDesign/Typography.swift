// Brand fonts. The .ttf files are bundled in the app target (added with
// the Xcode project); these helpers reference them by PostScript name and
// fall back to the system font if absent, so UnstuckDesign builds + previews
// without the font files present.
//   sans  — Geist (UI text)
//   serif — Instrument Serif (italic display headers)
//   mono  — IBM Plex Mono (eyebrows / labels)

import SwiftUI

public enum UFont {
    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    public static func serifItalic(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Italic", size: size)
    }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("IBMPlexMono", size: size).weight(weight)
    }
}
