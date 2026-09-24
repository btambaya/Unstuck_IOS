// Tour spotlight — a light scrim with a cut-out pulsing ring around the
// target (port of web spotlight.tsx: four dim panels, never a heavy dark
// overlay, pointer-events none — the app stays usable), plus the anchor
// mechanism that resolves target rects.
//
// ANCHORS: the web uses `data-tour` selectors; the natural SwiftUI analogue
// is anchor preferences — but those only propagate within ONE view tree, and
// the tour renders in a separate always-on-top UIWindow so it can sit above
// sheets (Settings, TaskEditor, Inbox) and the focus fullScreenCover. So the
// anchors register tiny UIKit reader views in a registry instead; the
// orchestrator polls it (like the web's 90ms/600ms polls) and converts each
// live anchor's bounds to SCREEN coordinates — correct across presentation
// contexts and windows, including scrolls (no layout callback fires on
// scroll, hence the poll).

import SwiftUI
import UIKit
import UnstuckDesign

// MARK: - target registry

@MainActor
final class TourTargetRegistry {
    static let shared = TourTargetRegistry()

    private struct WeakView { weak var view: UIView? }
    private var anchors: [TourTargetID: [ObjectIdentifier: WeakView]] = [:]

    func register(_ id: TourTargetID, view: UIView) {
        anchors[id, default: [:]][ObjectIdentifier(view)] = WeakView(view: view)
    }

    func unregister(_ id: TourTargetID, view: UIView) {
        anchors[id]?.removeValue(forKey: ObjectIdentifier(view))
    }

    /// The current SCREEN-coordinate frame of a target, or nil when no live
    /// anchor for it is mounted in a window. Dead weak entries are pruned.
    func frame(of id: TourTargetID) -> CGRect? {
        guard var entries = anchors[id] else { return nil }
        var best: CGRect?
        for (key, box) in entries {
            guard let v = box.view else { entries.removeValue(forKey: key); continue }
            guard let window = v.window, !window.isHidden, v.bounds.width > 0, v.bounds.height > 0 else { continue }
            let inWindow = v.convert(v.bounds, to: nil)
            let onScreen = window.convert(inWindow, to: window.screen.coordinateSpace)
            // Ignore anchors fully off-screen (e.g. scrolled far away).
            guard onScreen.intersects(window.screen.bounds) else { continue }
            best = onScreen
            break
        }
        anchors[id] = entries
        return best
    }

    /// Resolve a step's spotlight rect: the primary target, else the first
    /// live fallback (web findTourTarget primary→fallback order).
    func resolve(target: TourTargetID?, fallbacks: [TourTargetID]) -> CGRect? {
        guard let target else { return nil }
        if let rect = frame(of: target) { return rect }
        for fb in fallbacks {
            if let rect = frame(of: fb) { return rect }
        }
        return nil
    }
}

// MARK: - .tourTarget modifier

/// Invisible UIKit reader that registers itself as a live anchor while
/// mounted in a window.
private struct TourAnchorReader: UIViewRepresentable {
    let id: TourTargetID

    final class AnchorView: UIView {
        var targetId: TourTargetID?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let targetId else { return }
            if window != nil {
                TourTargetRegistry.shared.register(targetId, view: self)
            } else {
                TourTargetRegistry.shared.unregister(targetId, view: self)
            }
        }
    }

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.targetId = id
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        if view.targetId != id {
            if let old = view.targetId { TourTargetRegistry.shared.unregister(old, view: view) }
            view.targetId = id
            if view.window != nil { TourTargetRegistry.shared.register(id, view: view) }
        }
    }
}

extension View {
    /// Mark this view as a tour spotlight anchor (the iOS `data-tour="…"`).
    /// Invisible; adds no layout or interaction.
    func tourTarget(_ id: TourTargetID) -> some View {
        background(TourAnchorSlot(id: id))
    }
}

/// The anchor, unless the environment switched anchors off (snapshots only).
private struct TourAnchorSlot: View {
    @Environment(\.tourAnchorsEnabled) private var enabled
    let id: TourTargetID
    var body: some View {
        if enabled { TourAnchorReader(id: id).allowsHitTesting(false) }
    }
}

private struct TourAnchorsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False ONLY for off-screen snapshots (ImageRenderer): it can't flatten
    /// the UIKit anchor view and paints a yellow placeholder where it sits —
    /// e.g. behind the bar's +. A snapshot has no window, so nothing could
    /// have registered anyway. The app never sets this.
    var tourAnchorsEnabled: Bool {
        get { self[TourAnchorsEnabledKey.self] }
        set { self[TourAnchorsEnabledKey.self] = newValue }
    }
}

// MARK: - spotlight view

/// The scrim + ring layer. `rect` in screen coordinates (the tour window is
/// full-screen so its space matches). Nil rect → whisper-light scrim only —
/// either the step has no target by design, or the anchor isn't (yet) on
/// screen; both degrade gracefully while the poll keeps looking.
/// Entirely non-interactive (`allowsHitTesting(false)` at the call site).
struct TourSpotlight: View {
    @Environment(\.uTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let rect: CGRect?
    let reduceMotion: Bool
    @State private var pulsing = false

    /// Web dim: rgba(20,18,40,0.20); whisper: rgba(20,18,40,0.14).
    private static let dimBase = Color(red: 20 / 255, green: 18 / 255, blue: 40 / 255)

    var body: some View {
        GeometryReader { geo in
            let screen = geo.frame(in: .global)
            if let rect {
                let pad: CGFloat = 8
                let ring = rect.insetBy(dx: -pad, dy: -pad)
                ZStack {
                    // Dim everything but the ring cut-out (four-panel effect,
                    // done with a destination-out mask so corners stay clean).
                    Self.dimBase.opacity(0.20)
                        .mask {
                            ZStack {
                                Rectangle()
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .frame(width: ring.width, height: ring.height)
                                    .position(x: ring.midX - screen.minX, y: ring.midY - screen.minY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                    // Ring — 2px ink + a soft 22% outer halo; the pulse is
                    // killed by reduce-motion (system or in-app setting).
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.palette.ink.opacity(0.22), lineWidth: 6)
                        .frame(width: ring.width + 8, height: ring.height + 8)
                        .position(x: ring.midX - screen.minX, y: ring.midY - screen.minY)
                        .scaleEffect(pulseScale, anchor: anchorPoint(for: ring, in: screen))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.palette.ink, lineWidth: 2)
                        .frame(width: ring.width, height: ring.height)
                        .position(x: ring.midX - screen.minX, y: ring.midY - screen.minY)
                }
                .animation(.easeOut(duration: 0.22), value: rect)
            } else {
                Self.dimBase.opacity(0.14)
            }
        }
        .ignoresSafeArea()
        .onAppear { startPulse() }
        .onChange(of: motionOff) { _, _ in startPulse() }
    }

    private var motionOff: Bool { reduceMotion || systemReduceMotion }
    private var pulseScale: CGFloat { (pulsing && !motionOff) ? 1.035 : 1.0 }

    private func anchorPoint(for ring: CGRect, in screen: CGRect) -> UnitPoint {
        guard screen.width > 0, screen.height > 0 else { return .center }
        return UnitPoint(x: (ring.midX - screen.minX) / screen.width,
                         y: (ring.midY - screen.minY) / screen.height)
    }

    private func startPulse() {
        guard !motionOff else { pulsing = false; return }
        pulsing = false
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
