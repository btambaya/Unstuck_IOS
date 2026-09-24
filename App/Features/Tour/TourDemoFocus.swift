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
// The demo is inert EXCEPT one affordance (round 3, Ahmad's decision): on the
// CAPTURE step the ringed Capture pill is a real button that opens a DEMO
// capture sheet — faithful to FocusView's captureSheet (same copy, the real
// CaptureTagPicker), typing allowed, but Save stores NOTHING. The demo sits
// above the swallow layer in runningLayer's ZStack, so its button receives
// the claimed touches; everything else still falls through and is swallowed.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct TourDemoFocus: View {
    /// Kills the ring's easing (the phone's own Reduce Motion).
    let reduceMotion: Bool
    /// Current step id — the Capture pill is live ONLY on the capture step,
    /// and the demo sheet closes/resets on any step change (the surface stays
    /// mounted across focus → capture, so @State alone wouldn't reset).
    let stepID: String

    // FocusView's ambient palette, verbatim (the focus screen is always dark,
    // regardless of theme).
    private let bgTop = OKLCH(0.30, 0.10, 280).color
    private let bgBottom = OKLCH(0.16, 0.02, 280).color

    /// 18:24 elapsed of a 40-minute estimate → 1104 / 2400 of the ring.
    private let demoProgress = 1104.0 / 2400.0

    // Demo capture sheet — local by design: nothing here may touch a repo,
    // the router, or persistence. Fixed light-surface/dark-ink colors (the
    // answer-bubble strategy) so the card is theme/cache-proof on the dark
    // demo; CaptureTagPicker's default environment theme is light — correct.
    @State private var captureOpen = false
    @State private var captureText = ""
    @State private var captureTag: CaptureTag = .followUp
    @State private var savedFlash = false
    // SwiftUI.-qualified: UnstuckCore has its own FocusState (session state).
    @SwiftUI.FocusState private var captureFocused: Bool
    private let cardSurface = OKLCH(0.975, 0.005, 280).color
    private let cardInk = OKLCH(0.25, 0.02, 280).color
    private let cardInk2 = OKLCH(0.45, 0.02, 280).color

    private var isCaptureStep: Bool { stepID == "capture" }

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

            // Demo capture sheet — TOP-anchored (under the header) so the
            // keyboard can never cover it: the tour root ignores the keyboard
            // safe area (the Ask focus-loop fix), so bottom placement would
            // put the field under the keyboard with no avoidance.
            if captureOpen {
                demoCaptureCard
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .padding(.horizontal, 24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if savedFlash {
                Text("Captured. In a real session it lands in your Inbox.")
                    .font(UFont.sans(13, .medium)).foregroundStyle(cardInk)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(cardSurface, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 72)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        savedFlash = false
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: captureOpen)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: savedFlash)
        .onChange(of: stepID) {
            captureOpen = false
            captureText = ""
            captureTag = .followUp
            savedFlash = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus demo")
    }

    // Header pills mirror the real focus top bar: ← Out · Capture · speaker.
    // The Capture pill is the capture step's spotlight anchor — and on that
    // step only, a live button opening the demo capture sheet.
    private var header: some View {
        HStack {
            pill("← Out")
            Spacer()
            if isCaptureStep {
                Button {
                    captureOpen = true
                } label: {
                    pill("Capture")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture — opens a demo capture sheet")
                .tourTarget(.captureHint)
            } else {
                pill("Capture")
                    .tourTarget(.captureHint)
            }
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.10), in: Circle())
        }
    }

    /// FocusView.captureSheet, demo edition: same copy + the real tag picker,
    /// fixed light card, Save clears + flashes — persists nothing.
    private var demoCaptureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CAPTURE · STAYS ATTACHED")
                    .font(UFont.mono(11, .medium)).tracking(0.9)
                    .foregroundStyle(cardInk2)
                Spacer()
                Button {
                    closeCapture()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(cardInk2)
                        .frame(width: 28, height: 28)
                        .background(cardInk.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close demo capture")
            }
            Text("Park a thought without losing focus.")
                .font(UFont.sans(13)).foregroundStyle(cardInk2)
            TextField("What just popped up?", text: $captureText, axis: .vertical)
                .font(UFont.sans(16)).textFieldStyle(.plain)
                .foregroundStyle(cardInk)
                .focused($captureFocused)
                .submitLabel(.done)
                .onSubmit { saveDemoCapture() }
                .padding(12).background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cardInk.opacity(0.14)))
            CaptureTagPicker(selection: $captureTag)
            Button {
                saveDemoCapture()
            } label: {
                Text("Save")
                    .font(UFont.sans(14, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(cardInk, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Demo — nothing is stored.")
                .font(UFont.sans(11)).foregroundStyle(cardInk2)
        }
        .padding(18)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Demo capture sheet")
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

    private func closeCapture() {
        captureFocused = false
        captureOpen = false
        captureText = ""
        captureTag = .followUp
    }

    private func saveDemoCapture() {
        captureFocused = false
        captureOpen = false
        captureText = ""
        captureTag = .followUp
        savedFlash = true
    }
}
