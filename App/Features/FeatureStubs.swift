// Tab screen scaffolds. These render the brand chrome + an empty state
// today; the real lists/calendar/focus surfaces land in P2–P6, reading
// from the local GRDB store via repositories + ValueObservation.

import SwiftUI
import UnstuckDesign

private struct TabScaffold<Content: View>: View {
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
                    Text(title)
                        .font(UFont.serifItalic(34))
                        .foregroundStyle(theme.palette.ink)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
        }
    }
}

private struct EmptyHint: View {
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

struct TodayView: View {
    var body: some View { TabScaffold("Today", "What's next.") { EmptyHint(text: "Start Next + today's plan land in P2.") } }
}

struct TasksView: View {
    var body: some View { TabScaffold("Tasks", "Everything.") { EmptyHint(text: "Task list with Backlog / Later / Upcoming lands in P2.") } }
}

struct CalendarView: View {
    var body: some View { TabScaffold("Calendar", "Your time.") { EmptyHint(text: "Day / week / month + Google sync land in P4.") } }
}

struct ListsView: View {
    var body: some View { TabScaffold("Lists", "Kept.") { EmptyHint(text: "Collections land in P5.") } }
}
