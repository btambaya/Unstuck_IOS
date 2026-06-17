// First-run onboarding — a 5-step calm setup, 1:1 with the Android
// OnboardingScreen: Welcome → life areas → ADHD struggles → first task (+ its
// smallest first action) → focus treatment. Progress dots, a Skip escape, and
// a Continue/Begin button. Everything is seeded through AppModel.completeOnboarding
// (areas only if empty, the first task, the chosen default treatment).

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    private static let steps = 5

    @State private var step = 0
    // Ordered (not a Set) so the FIRST picked area can file the onboarding first
    // task + seed colors in pick order, matching Android's pickedAreas list.
    @State private var areas: [String] = ["Work", "Personal", "Home"]
    @State private var struggles: Set<String> = []
    @State private var firstTask = ""
    @State private var firstAction = ""
    @State private var treatment: FocusTreatment = .ambient

    // Match the web/Android vocabulary so the synced adhd_struggles + seeded
    // areas stay consistent across platforms (the morning brief keys on them).
    private let areaOptions = ["Work", "Personal", "Home", "Health", "Family", "Volunteering", "Study", "Side project"]
    private let struggleOptions = ["Getting started", "Switching tasks", "Time blindness", "Distraction", "Overwhelm"]

    private var lastStep: Int { Self.steps - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressDots

            // Step content lives in a rounded surface card (progress dots stay
            // above it) — mirrors Android's RoundedCornerShape(24) surface card.
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("STEP \(step + 1) OF \(Self.steps)")
                    .foregroundStyle(theme.palette.primaryDeep)

                ScrollView { stepBody.padding(.top, 14) }
                    .frame(maxWidth: .infinity, alignment: .leading)

                footer
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).stroke(theme.palette.line))
            .padding(.top, 22)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.palette.bg.ignoresSafeArea())
    }

    // MARK: progress + footer

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? theme.palette.ink : theme.palette.line2)
                    .frame(width: i == step ? 16 : 6, height: 6)
            }
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack {
            Button("Skip") { model.completeOnboarding(struggles: []) }
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                .buttonStyle(.plain)
            Spacer()
            UButton(step == lastStep ? "Begin" : "Continue") {
                if step == lastStep { finish() } else { withAnimation(.easeInOut(duration: 0.2)) { step += 1 } }
            }
        }
        .padding(.top, 8)
    }

    private func finish() {
        // Emit struggles in the canonical struggleOptions order so the saved
        // payload is deterministic (Set iteration order is not).
        let ordered = struggleOptions.filter { struggles.contains($0) }
        model.completeOnboarding(
            struggles: ordered, areas: areas,
            firstTask: firstTask, firstAction: firstAction, treatment: treatment)
    }

    // MARK: step bodies

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome.").font(UFont.serifItalic(32)).foregroundStyle(theme.palette.ink)
                Text("Unstuck is built for minds that struggle to start. Three minutes to set up.")
                    .font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                // The Orbit mark (iOS `Mark`), centered — mirrors Android's `Orbit(size = 88)`.
                Mark(size: 88)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        case 1:
            stepHeader("What parts of life share your attention?", "Pick a few. You can change these any time.")
            wrap(areaOptions, selected: Set(areas)) { v in
                if let i = areas.firstIndex(of: v) { areas.remove(at: i) } else { areas.append(v) }
            }
        case 2:
            stepHeader("What gets you stuck?", "Pick what rings true. It helps us meet you where you are.")
            wrap(struggleOptions, selected: struggles) { toggle($0, in: &struggles) }
        case 3:
            stepHeader("What's one thing on your mind right now?", "Just one. Small is good. We'll start there.")
            field("Reply to landlord about parking", text: $firstTask)
            SectionLabel("FIRST STEP").foregroundStyle(theme.palette.primaryDeep).padding(.top, 10)
            field("The smallest first move (optional)", text: $firstAction)
        default:
            stepHeader("Pick how focus feels.", "You can switch any time. Most people start with Ambient.")
            VStack(spacing: 10) {
                treatmentRow(.ambient, "Ambient", "A gentle breathing ring. Calm presence.")
                treatmentRow(.cockpit, "Cockpit", "Timer, controls visible. Tighter feedback.")
                treatmentRow(.monk, "Monk", "Just the task. Everything else hidden.")
            }
            .padding(.top, 8)
        }
    }

    private func stepHeader(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
            Text(sub).font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
        }
    }

    // MARK: controls

    /// A flowing wrap of selectable pills (areas / struggles).
    private func wrap(_ options: [String], selected: Set<String>, _ tap: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { opt in
                let on = selected.contains(opt)
                Button { tap(opt) } label: {
                    Text(opt)
                        .font(UFont.sans(14, .medium))
                        .foregroundStyle(on ? theme.palette.bg : theme.palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(on ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line))
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(UFont.sans(16))
            .padding(12).background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            .padding(.top, 12)
    }

    private func treatmentRow(_ t: FocusTreatment, _ name: String, _ blurb: String) -> some View {
        let on = treatment == t
        return Button { treatment = t } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    // Selected = ink fill, so the text must be the bg (cream / dark)
                    // for contrast in BOTH themes — matches Android's `c.bg`.
                    Text(name).font(UFont.sans(16, .medium)).foregroundStyle(on ? theme.palette.bg : theme.palette.ink)
                    Text(blurb).font(UFont.sans(13)).foregroundStyle(on ? theme.palette.bg.opacity(0.85) : theme.palette.ink3)
                }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(theme.palette.bg) }
            }
            .padding(14)
            .background(on ? theme.palette.ink : theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
        }.buttonStyle(.plain)
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

/// Minimal flow layout (left-to-right, wrap to the next line) for the pill
/// groups — SwiftUI's `Layout` so the pills size to their content.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
