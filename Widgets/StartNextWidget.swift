// Home / lock "Start Next" widget. Reads the App-Group snapshot the app
// writes on task changes (no network in the widget). Idle reload ~15 min;
// the app also pokes WidgetCenter on relevant changes.

import WidgetKit
import SwiftUI
import UnstuckShared

struct StartNextEntry: TimelineEntry {
    let date: Date
    let snapshot: StartNextSnapshot
}

struct StartNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartNextEntry {
        StartNextEntry(date: Date(), snapshot: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (StartNextEntry) -> Void) {
        completion(StartNextEntry(date: Date(), snapshot: AppGroup.readStartNext()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StartNextEntry>) -> Void) {
        let entry = StartNextEntry(date: Date(), snapshot: AppGroup.readStartNext())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct StartNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StartNext", provider: StartNextProvider()) { entry in
            StartNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Start Next")
        .description("Your next thing to focus on.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StartNextWidgetView: View {
    let entry: StartNextEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("START NEXT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            if let name = entry.snapshot.taskName {
                Text(name).font(.system(size: 16, weight: .medium)).lineLimit(3)
                HStack(spacing: 8) {
                    if let est = entry.snapshot.estimateMin {
                        Text("\(est) min").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if entry.snapshot.openCount > 1 {
                        Text("+\(entry.snapshot.openCount - 1) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("All clear").font(.system(size: 15, weight: .medium))
                Text("Add a task to get going.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
