// In-app beta feedback — a floating bubble that opens a one-way composer.
// Type → pick a category → Send → "Thanks". Triaged in the Supabase dashboard
// (no replies). Each submission auto-attaches app version / device / screen /
// email so a one-line report is still actionable. 1:1 with the Android
// FeedbackSheet + bubble; gated on the same on-by-default intent.

import SwiftUI
import UnstuckCore
import UnstuckDesign

/// The floating coral bubble, overlaid bottom-trailing over the tab content.
/// Opens the dual-purpose sheet (Assistant chat + Feedback) — matching Android,
/// whose bubble exposes both surfaces behind one entry point.
struct FeedbackBubble: View {
    @Environment(\.uTheme) private var theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(theme.palette.coralDeep)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant")
    }
}

/// Overlays the bubble on a tab's ROOT content (bottom-trailing). Applied
/// INSIDE each tab's NavigationStack so a pushed detail screen covers it —
/// mirroring Android's `stack.isEmpty()` gate. Opens the bubble sheet on the
/// Assistant tab.
struct FeedbackBubbleModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            FeedbackBubble {
                model.router.bubbleStartTab = .assistant
                model.router.showBubble = true
            }
            .padding(.trailing, 16)
            .padding(.bottom, 18)
        }
    }
}

extension View {
    func feedbackBubble() -> some View { modifier(FeedbackBubbleModifier()) }
}

private enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug = "Bug", idea = "Idea", praise = "Praise", other = "Other"
    var id: String { rawValue }
    var apiValue: String { rawValue.lowercased() }
}

/// The feedback composer CONTENT (no chrome) — embedded in the bubble's dual
/// sheet under the Feedback tab. `onDone` dismisses the host sheet after a
/// successful send. Mirrors Android's FeedbackForm reused inside AssistantSheet.
struct FeedbackForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    /// The tab the user was on (today / tasks / calendar / lists), for triage.
    let screen: String
    /// Called after a successful send so the host can dismiss.
    let onDone: () -> Void

    init(screen: String, onDone: @escaping () -> Void) {
        self.screen = screen
        self.onDone = onDone
    }

    @State private var category: FeedbackCategory = .bug
    @State private var body_ = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failed = false
    @SwiftUI.FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sent { thanks } else { composer }
            }
            .padding(20)
        }
        .background(theme.palette.bg)
        .onAppear { fieldFocused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bugs, ideas, anything — straight to the team.")
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)

            // Category chips
            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases) { c in
                    Button { category = c } label: { Chip(c.rawValue, selected: category == c) }
                        .buttonStyle(.plain)
                }
            }

            // Message
            ZStack(alignment: .topLeading) {
                if body_.isEmpty {
                    Text("What's on your mind?")
                        .font(UFont.sans(15)).foregroundStyle(theme.palette.ink4)
                        .padding(.top, 10).padding(.leading, 6)
                }
                TextEditor(text: $body_)
                    .font(UFont.sans(15))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .focused($fieldFocused)
                    .disabled(sending)   // lock the field while a send is in flight (Android parity)
            }
            .padding(8)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))

            // Transparency context line
            Text("Sent with v\(AppModel.appVersion) · \(screen)")
                .font(UFont.mono(11)).foregroundStyle(theme.palette.ink4)

            if failed {
                Text("Couldn't send — check your connection.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.red)
            }

            UButton(sending ? "Sending…" : "Send") { send() }
                .disabled(sending || body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thanks — we got it. 🙏")
                .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
            Text("Your note is on its way to the team.")
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func send() {
        let text = body_.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true; failed = false
        Task {
            let ok = await model.sendFeedback(body: text, category: category.apiValue, screen: screen)
            sending = false
            if ok {
                sent = true
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                onDone()
            } else {
                failed = true
            }
        }
    }
}
