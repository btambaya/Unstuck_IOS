// Settings — matches the Android SettingsScreen hub: a "SETTINGS" eyebrow, a
// "How Unstuck behaves." serif-italic title, and a single rounded surface card
// of hairline-separated rows. Each navigable row carries a chevron. Account,
// Backup, Insights, and Areas/Tags are wired to the live model; the export
// share sheet + URL Identifiable bridge are preserved.

import SwiftUI
import UIKit
import UnstuckDesign

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    @State private var exportURL: URL?
    @State private var accountOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Settings").foregroundStyle(theme.palette.primaryDeep)
                        .padding(.top, 4)
                    Text("How Unstuck behaves.")
                        .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                        .padding(.top, 4).padding(.bottom, 14)

                    hubCard

                    Text("Your data is yours — export a complete copy any time.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                        .padding(.top, 14)

                    aboutCard.padding(.top, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 96)   // clear the floating bottom nav
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $exportURL) { url in
                // Delete the full-PII dump once the share finishes/cancels so
                // it doesn't linger in tmp (makeExportFile sweeps stragglers).
                ActivityView(items: [url]) { AppModel.removeExportFile(url) }
            }
        }
    }

    // MARK: hub card — one grouped surface, hairline-separated rows

    private var hubCard: some View {
        VStack(spacing: 0) {
            // Account: expands inline to show status/email + sign out.
            disclosureRow("Account", open: accountOpen) {
                withAnimation(.easeInOut(duration: 0.2)) { accountOpen.toggle() }
            }
            if accountOpen { divider; accountBody }

            divider
            // Notification level (Calm/Balanced/Coach) + reminder lead.
            navRow("Notifications") { NotificationSettingsView() }

            divider
            navRow("Insights") { AnalyticsView() }

            divider
            // Backup: export everything as a JSON snapshot you keep.
            actionRow("Backup", sub: "A full JSON snapshot of your data.") {
                exportURL = model.makeExportFile()
            }

            divider
            navRow("Areas & tags") { TagsAreasView() }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    private var accountBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoLine("Status", model.signedIn ? "Signed in" : "Signed out")
            if let email = model.currentEmail {
                infoLine("Email", email)
            } else if let uid = model.coordinator?.auth.currentUserId {
                infoLine("User", String(uid.prefix(8)) + "…")
            }
            Button { model.signOut(); dismiss() } label: {
                Text("Sign out")
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: about card

    private var aboutCard: some View {
        VStack(spacing: 0) {
            aboutLine("Theme", "Follows system")
            divider
            aboutLine("Version", "0.1.0")
            divider
            aboutLine("Backend", "Supabase")
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    // MARK: row builders

    private var divider: some View {
        Rectangle().fill(theme.palette.line).frame(height: 1)
    }

    /// A row that navigates to `destination`, with a trailing chevron.
    @ViewBuilder
    private func navRow<Destination: View>(_ label: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack {
                Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                Spacer()
                chevron
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A tappable row with a label, a subtitle, and a trailing chevron.
    private func actionRow(_ label: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                Spacer()
                chevron
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A row that toggles an inline disclosure; chevron rotates when open.
    private func disclosureRow(_ label: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
    }

    /// Label + value line inside the expanded Account section.
    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            Spacer()
            Text(value).font(UFont.mono(12)).foregroundStyle(theme.palette.ink3).lineLimit(1)
        }
    }

    /// Static About row.
    private func aboutLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            Spacer()
            Text(value).font(UFont.mono(12)).foregroundStyle(theme.palette.ink3).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// UIActivityViewController bridge for the export share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void = {}
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
