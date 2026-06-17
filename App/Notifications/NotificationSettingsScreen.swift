// Settings → Notifications (spec 10 §1.12): the NotificationLevel picker
// (Calm / Balanced / Coach, verbatim blurbs from the Android
// SettingsStore) and the global "remind me N min before" lead. Changing
// either re-syncs the reminder alarms; the level additionally mirrors its
// derived booleans to notification_preferences (best-effort) so the
// server-driven morning brief + paused-checkin cap honour it.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var level = NotificationPrefs.level
    @State private var leadMin = NotificationPrefs.reminderLeadMin

    private let leadOptions = [0, 5, 10, 15]   // 0 = Off (Android parity)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Notification level").padding(.top, 4).padding(.bottom, 8)
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

                SectionLabel("Remind me before a scheduled task")
                    .padding(.top, 22).padding(.bottom, 8)
                HStack(spacing: 6) {
                    ForEach(leadOptions, id: \.self) { min in
                        leadChip(min)
                    }
                }
                Text("Reminders fire on this device, even offline.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 96)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func levelRow(_ l: NotificationLevel) -> some View {
        Button {
            level = l
            model.setNotificationLevel(l)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: level == l ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(level == l ? theme.palette.primary : theme.palette.ink3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.rawValue).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(l.blurb).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func leadChip(_ min: Int) -> some View {
        let selected = leadMin == min
        return Button {
            leadMin = min
            model.setReminderLeadMin(min)
        } label: {
            Text(min == 0 ? "Off" : "\(min)m")
                .font(UFont.sans(12, .medium))
                .foregroundStyle(selected ? .white : theme.palette.ink2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? theme.palette.primary : theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain)
    }
}
