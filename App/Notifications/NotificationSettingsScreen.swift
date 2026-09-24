// Settings → Notifications & calls (slim settings, 2026-09-24; section id
// stays "Notifications" so every old link lands here).
//
//   • a status line only when something is wrong: notifications are off for
//     Unstuck → Turn on;
//   • Reminders: "How much Unstuck checks in" Calm / Balanced / Coach (one
//     plain line each; the level also paces "Talk me through the session")
//     and "Remind me before a task" Off / 5 / 10 / 15. Changing either re-syncs
//     the reminder alarms; the level also mirrors its derived booleans to
//     notification_preferences (best-effort) so the server-driven morning
//     summary + paused-checkin cap honour it;
//   • Calls (CallSettingsView): "Let Unstuck call this phone", and only while
//     it's on — the hours, the morning / evening / after-a-block calls and a
//     test call. Without the Assistant or AI data sharing the whole block is
//     one line.
//
// The level picker is the guided tour's notifications anchor (.notifBody).
// This is a PUSHED screen — the tour's scoped lockdown needs that.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var level = NotificationPrefs.level
    @State private var leadMin = NotificationPrefs.reminderLeadMin
    /// nil until read; `.denied` / `.notDetermined` show the status line.
    @State private var permission: UNAuthorizationStatus?

    private let leadOptions = [0, 5, 10, 15]   // 0 = Off (Android parity)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Settings · Notifications & calls").padding(.top, 4)
                Text("How Unstuck reaches you.")
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                    .padding(.top, 4).padding(.bottom, 12)

                if let line = permissionLine { statusLine(line) .padding(.bottom, 14) }

                // Copy canon §1: "Reminders" heads the level and the lead;
                // those two are row titles under it (Android's layout).
                SectionLabel("Reminders").padding(.bottom, 10)
                rowTitle("How much Unstuck checks in").padding(.bottom, 8)
                VStack(spacing: 0) {
                    ForEach(NotificationLevel.allCases, id: \.self) { l in
                        if l != NotificationLevel.allCases.first {
                            Rectangle().fill(theme.palette.line).frame(height: 1)
                        }
                        levelRow(l)
                    }
                }
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                // Tour anchor: the notifications step rings the level picker.
                .tourTarget(.notifBody)
                SettingsNote(text: NotificationLevel.coachPaceNote).padding(.top, 8)

                rowTitle("Remind me before a task")
                    .padding(.top, 20).padding(.bottom, 8)
                HStack(spacing: 6) {
                    ForEach(leadOptions, id: \.self) { min in
                        leadChip(min)
                    }
                }
                SettingsNote(text: "Reminders work even offline. Any task can have its own time.")
                    .padding(.top, 10)

                SectionLabel("Calls").padding(.top, 26).padding(.bottom, 8)
                CallSettingsView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 96)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Notifications & calls")
        .navigationBarTitleDisplayMode(.inline)
        .task { await readPermission() }
        // Back from iOS Settings after "Turn on": read it again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await readPermission() } }
        }
    }

    // MARK: the status line (only when something is wrong)

    private var permissionLine: String? {
        switch permission {
        case .denied: return "Notifications are off for Unstuck, so reminders can't reach you."
        case .notDetermined: return "Unstuck hasn't been allowed to send notifications yet."
        default: return nil
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.slash").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.amberInk).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(UFont.sans(13)).foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button { turnOnNotifications() } label: {
                    Text("Turn on")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(theme.palette.ink, in: Capsule())
                        .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -7)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-notifications-turn-on")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.amberSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func readPermission() async {
        #if DEBUG
        // Demo boot (UITEST_SEED): the line only reflects the simulator's
        // permission state — keep screenshots and the tour on the product.
        if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" { permission = .authorized; return }
        #endif
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Never asked → ask now; refused → iOS Settings (only there can it change).
    private func turnOnNotifications() {
        if permission == .notDetermined {
            Task {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                if granted { PushRegistrar.shared.requestAPNsToken(); ReminderScheduler.shared.resync() }
                await readPermission()
            }
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: level + lead

    /// A row title under the Reminders heading (the settings rows' label style).
    private func rowTitle(_ text: String) -> some View {
        Text(text).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func levelRow(_ l: NotificationLevel) -> some View {
        Button {
            level = l
            model.setNotificationLevel(l)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: level == l ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(level == l ? theme.palette.ink : theme.palette.ink3)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.rawValue).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(l.plainLine).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(level == l ? [.isButton, .isSelected] : .isButton)
    }

    private func leadChip(_ min: Int) -> some View {
        let selected = leadMin == min
        return Button {
            leadMin = min
            model.setReminderLeadMin(min)
        } label: {
            Text(min == 0 ? "Off" : "\(min) min")
                .font(UFont.sans(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line2))
                .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(min == 0 ? "Remind me before a task: off" : "Remind me \(min) minutes before a task")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
