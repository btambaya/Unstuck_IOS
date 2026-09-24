// Core brand components ported from ../unstuck/components/ui/*.

import SwiftUI

/// The Orbit mark: ink anchor + near-full ink ring with a tight ~51° gap
/// at the lower-right, and the coral orbit dot resting ON the ring at
/// 3 o'clock (the gap's edge). Canonical geometry = brand mark.svg
/// (`M 26.5 16 A 10.5 10.5 0 1 0 22.6 24.1`) — the previous 90°-gap trim
/// read as a "C" with a floating dot and was flagged as off-brand.
/// Ink/coral read from the theme so it flips to cream-on-dark
/// automatically. Port of components/ui/wordmark.tsx.
public struct Mark: View {
    @Environment(\.uTheme) private var theme
    public let size: CGFloat
    public init(size: CGFloat = 22) { self.size = size }

    public var body: some View {
        let ring = size * 21 / 32        // ring diameter (radius 10.5 of 32)
        let stroke = size * 2.2 / 32
        let anchor = size * 6.8 / 32     // anchor circle (r 3.4)
        let dot = size * 4.2 / 32        // coral dot (r 2.1)
        ZStack {
            // Ring: SwiftUI trim runs clockwise from 3 o'clock; the arc spans
            // 51°→360° so the gap is exactly the SVG's 0°→51° lower-right slice.
            Circle()
                .trim(from: 51.0 / 360.0, to: 1.0)
                .stroke(theme.palette.ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: ring, height: ring)
            Circle().fill(theme.palette.ink).frame(width: anchor, height: anchor)
            Circle().fill(theme.palette.coral).frame(width: dot, height: dot)
                .offset(x: ring / 2)     // ON the ring at 3 o'clock (gap edge)
        }
        .frame(width: size, height: size)
    }
}

/// Mark + "unstuck" lockup. Geist Medium, tightened tracking.
public struct Wordmark: View {
    @Environment(\.uTheme) private var theme
    public let size: CGFloat
    public init(size: CGFloat = 18) { self.size = size }

    public var body: some View {
        HStack(spacing: 8) {
            Mark(size: size + 4)
            Text("unstuck")
                .font(UFont.sans(size, .medium))
                .tracking(-0.03 * size)
                .foregroundStyle(theme.palette.ink)
        }
    }
}

/// Small life-area / collection color dot.
public struct AreaDot: View {
    @Environment(\.uTheme) private var theme
    public let token: String?
    public let size: CGFloat
    public init(_ token: String?, size: CGFloat = 8) { self.token = token; self.size = size }
    public var body: some View {
        Circle().fill(theme.palette.areaColor(token)).frame(width: size, height: size)
    }
}

public enum ButtonKind: Sendable { case primary, ghost, danger, dark }

/// Brand button. Primary uses the brand coral CTA.
public struct UButton: View {
    @Environment(\.uTheme) private var theme
    let title: String
    let kind: ButtonKind
    let action: () -> Void
    public init(_ title: String, kind: ButtonKind = .primary, action: @escaping () -> Void) {
        self.title = title; self.kind = kind; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(UFont.sans(15, .medium))
                .padding(.vertical, 11).padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private var foreground: Color {
        switch kind {
        case .primary, .danger: return .white
        case .ghost: return theme.palette.ink
        case .dark: return theme.palette.bg   // ink button, cream text (Android ButtonKind.DARK)
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return theme.palette.coral
        case .danger: return theme.palette.red
        case .ghost: return theme.palette.bg2
        case .dark: return theme.palette.ink
        }
    }
}

/// Pill / chip label (filters, tags).
public struct Chip: View {
    @Environment(\.uTheme) private var theme
    let title: String
    let selected: Bool
    public init(_ title: String, selected: Bool = false) { self.title = title; self.selected = selected }
    public var body: some View {
        Text(title)
            .font(UFont.sans(13, .medium))
            .padding(.vertical, 5).padding(.horizontal, 11)
            .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
            .background(selected ? theme.palette.ink : theme.palette.bg2)
            .clipShape(Capsule())
    }
}

public extension Palette {
    /// The ON colour of every switch / toggle: the brand coral (Ahmad,
    /// 2026-09-24 — shown the Notifications & calls screen with the old
    /// indigo switch). Never `coralDeep`, never `primary`. OFF keeps the
    /// system track; the thumb stays the system white.
    var switchOn: Color { coral }
}

/// Paints a `Toggle` (switch style) the brand way: ON = coral. Use this on
/// EVERY switch instead of a hand-picked `.tint` so no switch drifts back to
/// indigo or the system green/blue.
public struct UnstuckSwitchTint: ViewModifier {
    @Environment(\.uTheme) private var theme
    public init() {}
    public func body(content: Content) -> some View {
        content.tint(theme.palette.switchOn)
    }
}

public extension View {
    /// ON = coral for the switches inside (see `Palette.switchOn`).
    func unstuckSwitch() -> some View { modifier(UnstuckSwitchTint()) }
}

/// Eyebrow / section label — mono, uppercase, tracked. Neutral `ink3` — the
/// eyebrows are never an accent. Recolour only through `color:`: the Text
/// paints its own style, so an outer `.foregroundStyle(…)` does NOT reach it
/// (the old `SectionLabel(…).foregroundStyle(primaryDeep)` call sites were
/// no-ops for that reason and were removed in the colour sweep, 2026-09-24).
public struct SectionLabel: View {
    @Environment(\.uTheme) private var theme
    let text: String
    let color: Color?
    public init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    public var body: some View {
        Text(text.uppercased())
            .font(UFont.mono(11, .medium))
            .tracking(0.8)
            .foregroundStyle(color ?? theme.palette.ink3)
    }
}

/// Surface card container.
public struct Card<Content: View>: View {
    @Environment(\.uTheme) private var theme
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(16)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(theme.palette.line, lineWidth: 1))
    }
}
