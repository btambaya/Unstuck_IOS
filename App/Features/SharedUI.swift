// Small shared building blocks for the feature screens.

import SwiftUI
import UnstuckDesign

struct TabScaffold<Content: View>: View {
    @Environment(\.uTheme) private var theme
    let eyebrow: String
    let title: String
    let content: Content
    init(_ eyebrow: String, _ title: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow; self.title = title; self.content = content()
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionLabel(eyebrow)
                    Text(title).font(UFont.serifItalic(34)).foregroundStyle(theme.palette.ink)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
        }
    }
}

struct EmptyHint: View {
    @Environment(\.uTheme) private var theme
    let text: String
    var body: some View {
        Card {
            Text(text)
                .font(UFont.sans(14))
                .foregroundStyle(theme.palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
