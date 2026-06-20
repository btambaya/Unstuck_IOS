// Custom app chrome matching the Android design: a bottom nav with a pill
// active-indicator + a floating rounded-square coral FAB, and a shared top
// AppBar (Orbit/title + search/bell/avatar). Replaces the native TabView bar.

import SwiftUI
import UnstuckCore
import UnstuckDesign

extension AppRouter.Tab {
    var navLabel: String {
        switch self {
        case .today: return "Today"
        case .tasks: return "Tasks"
        case .calendar: return "Calendar"
        case .lists: return "Collections"
        }
    }
    var navIcon: String {
        switch self {
        case .today: return "clock"
        case .tasks: return "tray"
        case .calendar: return "calendar"
        case .lists: return "square.stack.3d.up"
        }
    }
}

/// Bottom nav: 4 cells split around a centered FAB gap, a hairline top divider,
/// and the floating coral FAB lifted above the bar. 1:1 with BottomNavBar.kt.
struct BottomNavBar: View {
    @Environment(\.uTheme) private var theme
    let active: AppRouter.Tab
    let onSelect: (AppRouter.Tab) -> Void
    let onFab: () -> Void

    private let tabs = AppRouter.Tab.allCases

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                let mid = (tabs.count + 1) / 2
                ForEach(tabs.prefix(mid), id: \.self) { cell($0) }
                Color.clear.frame(width: 56, height: 1)   // FAB gap (fixed height so it can't expand)
                ForEach(tabs.suffix(tabs.count - mid), id: \.self) { cell($0) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(theme.palette.bg)
            .overlay(alignment: .top) { Rectangle().fill(theme.palette.line).frame(height: 0.5) }

            CoralFab(action: onFab).offset(y: -28)
        }
    }

    private func cell(_ tab: AppRouter.Tab) -> some View {
        let on = tab == active
        return Button { onSelect(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.navIcon)
                    .font(.system(size: 19))
                    .foregroundStyle(on ? theme.palette.ink : theme.palette.ink3)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(on ? theme.palette.bg2 : .clear, in: Capsule())
                Text(tab.navLabel)
                    .font(UFont.sans(11, on ? .semibold : .medium))
                    .foregroundStyle(on ? theme.palette.ink : theme.palette.ink3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 56×56, 16pt rounded-square coral FAB (CoralFab.kt).
struct CoralFab: View {
    @Environment(\.uTheme) private var theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(theme.palette.coral, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New task")
    }
}

/// Shared top app bar (Orbit/title + search/bell/avatar), used by the
/// Tasks/Calendar/Collections screens. Today has its own richer header.
struct AppBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    var title: String = ""
    var onSearch: () -> Void = {}
    var onAvatar: () -> Void = {}
    /// Optional notifications bell (Android AppBar parity). Defaults keep
    /// existing call sites (Calendar/Collections) bell-free: only callers
    /// that pass `onNotifications` get the bell, and `notifUnread > 0`
    /// lights the coral dot.
    var onNotifications: (() -> Void)? = nil
    var notifUnread: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(UFont.sans(20, .semibold))
                .foregroundStyle(theme.palette.ink)
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(theme.palette.ink2)
                    .frame(width: 40, height: 40)
            }.buttonStyle(.plain).accessibilityLabel("Search")
            if let onNotifications {
                Button(action: onNotifications) {
                    Image(systemName: "bell").font(.system(size: 18)).foregroundStyle(theme.palette.ink2)
                        .frame(width: 40, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if notifUnread {
                                Circle().fill(theme.palette.coral).frame(width: 7, height: 7)
                                    .offset(x: -9, y: 9)
                            }
                        }
                }.buttonStyle(.plain).accessibilityLabel("Notifications")
                    .accessibilityValue(notifUnread ? "Unread" : "")
            }
            Button(action: onAvatar) {
                Text(model.avatarInitials)
                    .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.greenInk)
                    .frame(width: 32, height: 32)
                    .background(theme.palette.greenSoft, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Account and settings")
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
    }
}

extension AppModel {
    /// Initials for the avatar chip (from display name / email local-part).
    var avatarInitials: String {
        let name = currentUserName ?? currentEmail ?? "U"
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? "U" : letters
    }
}
