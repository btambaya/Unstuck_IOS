// Custom app chrome matching the Android design: a bottom nav with a pill
// active-indicator and the rounded-square coral + as its middle slot, and a
// shared top AppBar (Orbit/title + search/bell/avatar). Replaces the native
// TabView bar.

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
    /// Lowercase key attached to a feedback submission for triage.
    var screenKey: String {
        switch self {
        case .today: return "today"
        case .tasks: return "tasks"
        case .calendar: return "calendar"
        case .lists: return "lists"
        }
    }
}

/// Bottom nav: ONE row of five equal slots — Today · Tasks · + · Calendar ·
/// Collections — under a hairline top divider. The coral + is the middle slot
/// (not lifted above the bar), vertically centred on the tab cells so it reads
/// as one line with them. 1:1 with BottomNavBar.kt.
struct BottomNavBar: View {
    @Environment(\.uTheme) private var theme
    let active: AppRouter.Tab
    let onSelect: (AppRouter.Tab) -> Void
    /// VoiceOver label for the +. The ONLY thing about the button that moves
    /// with the surface (see AppRouter.fabAction) — the coral square, its size
    /// and its position are fixed.
    var fabLabel: String = "New task"
    let onFab: () -> Void

    /// Every tab icon is drawn in this same box. SF Symbols differ in height
    /// ("square.stack.3d.up" is taller than "clock"/"tray"/"calendar"), and
    /// with each cell sized by its own symbol the Collections label sat ~3 pt
    /// below the others. A shared box gives every pill the same height, so all
    /// four icons share one line and all four labels one baseline.
    static let iconBox = CGSize(width: 24, height: 22)

    /// How far a tab's content (and the assistant launcher) sits above the
    /// bottom safe edge to clear this bar. The bar overlays the tab content
    /// (MainTabScaffold's ZStack), so a scroll view pads its end by this much.
    /// The bar is ~60 pt: an icon pill (22 + 2×4) + 2 + an 11-pt label ≈ 46,
    /// the + is 44, plus 8 above and 6 below. 72 leaves a 12-pt gap above its
    /// hairline. It was 96 while the + was lifted above the bar; with the +
    /// inline that left ~36 pt of dead space under a list scrolled to its end.
    static let clearance: CGFloat = 72

    private let tabs = AppRouter.Tab.allCases

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            let mid = (tabs.count + 1) / 2
            ForEach(tabs.prefix(mid), id: \.self) { cell($0) }
            // Tour anchor: the New-task fallback when an empty account has no
            // task detail to spotlight on the first-action step. That step runs
            // on the Tasks tab, where the + still opens New task — the anchor id
            // is unchanged on purpose. It hugs the 44-pt square, not the slot.
            CoralFab(action: onFab, label: fabLabel)
                .tourTarget(.newTask)
                .frame(maxWidth: .infinity)
            ForEach(tabs.suffix(tabs.count - mid), id: \.self) { cell($0) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(theme.palette.bg)
        .overlay(alignment: .top) { Rectangle().fill(theme.palette.line).frame(height: 0.5) }
    }

    private func cell(_ tab: AppRouter.Tab) -> some View {
        let on = tab == active
        return Button { onSelect(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.navIcon)
                    .font(.system(size: 19))
                    .foregroundStyle(on ? theme.palette.ink : theme.palette.ink3)
                    .frame(width: Self.iconBox.width, height: Self.iconBox.height)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(on ? theme.palette.bg2 : .clear, in: Capsule())
                Text(tab.navLabel)
                    .font(UFont.sans(11, on ? .semibold : .medium))
                    .foregroundStyle(on ? theme.palette.ink : theme.palette.ink3)
                    // One line always: a wrapped label would make its cell
                    // taller and knock the row off its common baseline.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The bar's + — a 44×44, 13-pt rounded coral square in the middle slot
/// (CoralFab.kt). Flat, no drop shadow: it is part of the bar, not floating
/// over the content. Its 44×44 frame is also its tap target.
struct CoralFab: View {
    @Environment(\.uTheme) private var theme
    let action: () -> Void
    /// Context label only — the drawn button is identical everywhere.
    var label: String = "New task"

    static let side: CGFloat = 44
    static let cornerRadius: CGFloat = 13

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                // Decorative: the Button carries the label. Left exposed, the
                // glyph came back from a keyboard hiding the bar as a separate
                // "Add" image inside the button, and an accessibility hit test
                // on the + (VoiceOver touch, XCUITest) no longer found it.
                .accessibilityHidden(true)
                .frame(width: Self.side, height: Self.side)
                .background(theme.palette.coral,
                            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
