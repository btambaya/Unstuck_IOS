// P4 — Calendar (read slice). Agenda of cal_blocks grouped by date from
// the live store. Block-time creation, drag-to-schedule, and Google
// two-way sync (via coordinator.calendar + ASWebAuthenticationSession)
// are the next P4 increments.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class CalendarModel {
    var blocks: [CalBlock] = []
    private let repo: Repository<CalBlock>
    init(_ repo: Repository<CalBlock>) { self.repo = repo }
    func observe() async {
        do { for try await rows in repo.observeValues() { blocks = rows } } catch {}
    }
    /// Blocks grouped by date (ascending), each day's blocks sorted by start.
    var byDate: [(date: String, blocks: [CalBlock])] {
        Dictionary(grouping: blocks, by: { $0.date })
            .map { ($0.key, $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { $0.date < $1.date }
    }
}

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CalendarModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm { content(vm) } else { ProgressView() }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Calendar")
        }
        .task {
            guard vm == nil, let db = model.db else { return }
            let m = CalendarModel(Repository<CalBlock>(db, orderColumn: "date"))
            vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func content(_ vm: CalendarModel) -> some View {
        if vm.byDate.isEmpty {
            EmptyHint(text: "No scheduled blocks yet. Schedule a task or block time — Google sync lands next.")
                .padding(20)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(vm.byDate, id: \.date) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(day.date)
                            ForEach(day.blocks) { block in blockRow(block) }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func blockRow(_ block: CalBlock) -> some View {
        HStack(spacing: 12) {
            Text(formatTime(block.startTime))
                .font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(isExternalBlock(block) ? theme.palette.blue : theme.palette.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.taskName).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                Text(blockTimeRange(block)).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
            }
            Spacer()
        }
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
    }
}
