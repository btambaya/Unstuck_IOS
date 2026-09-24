// In-app beta feedback — a one-way composer. Type → pick a category → Send →
// "Thanks". Triaged in the Supabase dashboard (no replies). Each submission
// auto-attaches app version / device / screen / email so a one-line report is
// still actionable.
//
// Since the assistant redesign the composer is NO LONGER inside the assistant
// panel: its entry point is Settings → "Send feedback" (matching the
// web, which moved it out for the same reason — the panel is the assistant,
// nothing else). The floating ✦ launcher below opens the Assistant.

import SwiftUI
import UnstuckCore
import UnstuckDesign

/// The floating coral ✦ launcher, overlaid bottom-trailing over the tab
/// content. Opens the Assistant panel.
struct AssistantLauncher: View {
    @Environment(\.uTheme) private var theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                // Brand coral — the Focus/Start-now action color. Matches the
                // Android bubble tint (c.coral) and the web launcher's
                // var(--u-coral), so the AI affordance reads the same on all
                // three platforms.
                .background(theme.palette.coral)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant")
    }
}

/// Overlays the launcher on a tab's ROOT content (bottom-trailing). Applied
/// INSIDE each tab's NavigationStack so a pushed detail screen covers it —
/// mirroring Android's `stack.isEmpty()` gate. Renders NOTHING while the AI
/// kill-switch (Settings → Assistant & privacy) is off.
struct AssistantLauncherModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if model.assistantEnabled {
                AssistantLauncher { model.openAssistant() }
                    // Tour anchor: the assistant/re-entry steps ring this launcher.
                    .tourTarget(.assistantLaunch)
                    .padding(.trailing, 16)
                    // Clear the floating bottom nav (~84pt incl. the safe area) so
                    // the launcher isn't occluded by / mis-tapped into the
                    // Collections tab beneath it. Content already pads 96pt here.
                    .padding(.bottom, 96)
            }
        }
    }
}

extension View {
    func assistantLauncher() -> some View { modifier(AssistantLauncherModifier()) }
}

/// The feedback composer as its own sheet — the Settings → "Send feedback" entry point.
struct FeedbackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FeedbackForm(screen: model.router.tab.screenKey, onDone: { dismiss() })
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.palette.bg.ignoresSafeArea())
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }
}

/// What actually gets sent: the user's note, plus the previous session's crash
/// trail when they left the attach toggle on. This is the ONLY path the trail
/// ever leaves the device — a report with no trail, or an untoggled one, sends
/// the note verbatim (a trailing-whitespace-clean body, so the dashboard row
/// reads the same as it always has).
func feedbackPayload(note: String, report: String?, attach: Bool) -> String {
    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard attach, let report, !report.isEmpty else { return text }
    return "\(text)\n\n\(report)"
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
    /// The previous session ended in a crash / main-thread stall: its trail is
    /// offered here (on by default) so a one-line "it crashed" report finally
    /// arrives WITH a stack. Tool names + phase markers only — never message
    /// text (App/Diagnostics/CrashBreadcrumbs.swift).
    @State private var attachDiagnostics = true
    private var crashReport: String? { CrashBreadcrumbs.lastReport }

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
            Text("Sent with v\(AppModel.appVersion) · \(screen) · \(AppModel.deviceModelName)")
                .font(UFont.mono(11)).foregroundStyle(theme.palette.ink4)

            // The last session ended badly — offer its trail, visibly.
            if crashReport != nil {
                Toggle(isOn: $attachDiagnostics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attach the last crash report")
                            .font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
                        Text("Technical only — what the app was doing and where it stopped. No message text.")
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    }
                }
                .unstuckSwitch()
                .disabled(sending)
                .accessibilityLabel("Attach the last crash report")
            }

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
        let attached = (attachDiagnostics ? crashReport : nil)
        let payload = feedbackPayload(note: text, report: crashReport, attach: attachDiagnostics)
        Task {
            let ok = await model.sendFeedback(body: payload, category: category.apiValue, screen: screen)
            sending = false
            if ok {
                if attached != nil { CrashBreadcrumbs.clearLastReport() }
                sent = true
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                onDone()
            } else {
                failed = true
            }
        }
    }
}
