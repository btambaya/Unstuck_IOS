// Focus Live Activity — lock screen banner + Dynamic Island. The timer
// self-ticks via Text(timerInterval:) so it costs no push budget; the app
// only pushes state changes (pause/resume/end).

import WidgetKit
import SwiftUI
import ActivityKit
import UnstuckShared

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusSessionAttributes.self) { context in
            // Lock screen / banner.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.taskName).font(.headline).lineLimit(1)
                    Text(context.state.paused ? "Paused" : "Focusing")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                timer(context.state).font(.title2.monospacedDigit())
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.25))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.taskName).lineLimit(1).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context.state).font(.title3.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : "timer")
            } compactTrailing: {
                timer(context.state).monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "timer")
            }
        }
    }

    @ViewBuilder
    private func timer(_ state: FocusSessionAttributes.ContentState) -> some View {
        if state.paused {
            Text("Paused")
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}
