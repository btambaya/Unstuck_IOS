// First-run onboarding: a calm welcome + the ADHD-struggle self-select
// from the design (Starting / Sustaining / Switching / Stopping /
// Recovering). Stored locally for now (see AppModel.completeOnboarding).

import SwiftUI
import UnstuckDesign

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var selected: Set<String> = []

    private let struggles = ["Starting", "Sustaining", "Switching", "Stopping", "Recovering"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Wordmark(size: 26)
            Text("Where does it break?")
                .font(UFont.serifItalic(30)).foregroundStyle(theme.palette.ink)
            Text("Pick what's hard right now — unstuck tunes its nudges to match. You can change this later.")
                .font(UFont.sans(15)).foregroundStyle(theme.palette.ink2)

            VStack(spacing: 10) {
                ForEach(struggles, id: \.self) { struggle in
                    let on = selected.contains(struggle)
                    Button {
                        if on { selected.remove(struggle) } else { selected.insert(struggle) }
                    } label: {
                        HStack {
                            Text(struggle).font(UFont.sans(16, .medium))
                                .foregroundStyle(on ? .white : theme.palette.ink)
                            Spacer()
                            if on { Image(systemName: "checkmark").foregroundStyle(.white) }
                        }
                        .padding(14)
                        .background(on ? theme.palette.primary : theme.palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer()
            UButton("Get started") { model.completeOnboarding(struggles: Array(selected)) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.palette.bg.ignoresSafeArea())
    }
}
