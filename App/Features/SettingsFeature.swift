// P6 — Settings (slice). Account + sign-out + app info. Theme follows the
// system color scheme (light/dark palettes already wired). Accent palette,
// density, focus prefs, data export, and delete-account land as follow-ups.

import SwiftUI
import UnstuckDesign

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Wordmark(size: 22)

                    section("Account") {
                        row("Status", model.signedIn ? "Signed in" : "Signed out")
                        if let uid = model.coordinator?.auth.currentUserId {
                            row("User", String(uid.prefix(8)) + "…")
                        }
                        UButton("Sign out", kind: .ghost) {
                            model.signOut(); dismiss()
                        }
                        .padding(.top, 4)
                    }

                    section("Insights") {
                        NavigationLink { AnalyticsView() } label: {
                            HStack {
                                Text("View insights").font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.palette.ink4)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    section("Organize") {
                        NavigationLink { TagsAreasView() } label: {
                            HStack {
                                Text("Tags & areas").font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.palette.ink4)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    section("Appearance") {
                        row("Theme", "Follows system")
                    }

                    section("About") {
                        row("Version", "0.1.0")
                        row("Backend", "Supabase")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            Card { VStack(alignment: .leading, spacing: 10) { content() } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
            Spacer()
            Text(value).font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
        }
    }
}
