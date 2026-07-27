// Tour DEMO focus surface (round 2, item 6) — the focus + capture steps
// present THIS full-screen mock instead of navigating anywhere: visually
// faithful to FocusView's ambient look (same dark radial gradient, the REAL
// ProgressRing, the header Capture pill) with a session frozen mid-progress
// (18:24 of a 40-minute estimate). ZERO sessions are minted, ZERO router
// changes happen — the app stays on Today underneath the tour window.
//
// The spotlight targets for these steps live HERE: the focus step rings the
// progress ring (.focusRing) and the capture step rings the header Capture
// pill (.captureHint) — registered through the normal .tourTarget mechanism,
// which is window-agnostic (frames resolve to screen coordinates).
//
// Everything is INERT (plain Texts, no Buttons): while a demo step runs the
// tour window claims every point, and the runningLayer's swallow layer
// absorbs the touches — a tap on the demo does nothing.

import SwiftUI
import UnstuckDesign

struct TourDemoFocus: View {
    /// Kills the ring's easing (Settings · Accessibility → Reduce motion).
    let reduceMotion: Bool

    // FocusView's ambient palette, verbatim (the focus screen is always dark,
    // regardless of theme).
    private let bgTop = OKLCH(0.30, 0.10, 280).color
    private let bgBottom = OKLCH(0.16, 0.02, 280).color

    /// 18:24 elapsed of a 40-minute estimate → 1104 / 2400 of the ring.
    private let demoProgress = 1104.0 / 2400.0

    var body: some View {
        ZStack {
            RadialGradient(colors: [bgTop, bgBottom], center: .top, startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.bottom, 8)
                Text("FOCUSING")
                    .font(UFont.mono(11, .medium)).tracking(0.9)
                    .foregroundStyle(.white.opacity(0.55))
                treatments
                    .padding(.top, 8)
                Spacer()
                ProgressRing(progress: demoProgress, paused: false, animated: !reduceMotion)
                    .frame(width: 220, height: 220)
                    .padding(.bottom, 20)
                    .tourTarget(.focusRing)
                Text("Write the project update")
                    .font(UFont.serifItalic(24)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Text("→ Open the document")
                    .font(UFont.sans(13)).foregroundStyle(.white.opacity(0.82))
                    .padding(.top, 6).padding(.horizontal, 24)
                Text("40m estimate")
                    .font(UFont.sans(13)).foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 6)
                Text("18:24")
                    .font(UFont.sans(52, .light))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.top, 20)
                Text("21:36 left")
                    .font(UFont.sans(12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus demo")
    }

    // Header pills mirror the real focus top bar: ← Out · Capture · speaker.
    // The Capture pill is the capture step's spotlight anchor.
    private var header: some View {
        HStack {
            pill("← Out")
            Spacer()
            pill("Capture")
                .tourTarget(.captureHint)
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.10), in: Circle())
        }
    }

    private var treatments: some View {
        HStack(spacing: 8) {
            treatmentChip("ambient", selected: true)
            treatmentChip("cockpit", selected: false)
            treatmentChip("monk", selected: false)
        }
    }

    private func pill(_ label: String) -> some View {
        Text(label)
            .font(UFont.sans(12))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.10), in: Capsule())
    }

    private func treatmentChip(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(UFont.sans(12, .medium))
            .foregroundStyle(selected ? Color(hex: "#14122A") : .white.opacity(0.7))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(Color.white.opacity(0.08)),
                        in: Capsule())
    }
}
