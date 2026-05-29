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
    var connections: [CalendarConnection] = []
    private let repo: Repository<CalBlock>
    private let connRepo: Repository<CalendarConnection>
    init(_ repo: Repository<CalBlock>, _ connRepo: Repository<CalendarConnection>) {
        self.repo = repo
        self.connRepo = connRepo
    }
    func observe() async {
        async let a: Void = observeBlocks()
        async let b: Void = observeConnections()
        _ = await (a, b)
    }
    private func observeBlocks() async {
        do { for try await rows in repo.observeValues() { blocks = rows } } catch {}
    }
    private func observeConnections() async {
        do { for try await rows in connRepo.observeValues() { connections = rows } } catch {}
    }
    var connected: Bool { !connections.isEmpty }
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
    @State private var connecting = false
    @State private var connectError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let vm { content(vm) } else { ProgressView() }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if vm?.connected == true {
                        Button { Task { await model.pullGoogleCalendar() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
        }
        .task {
            guard vm == nil, let db = model.db else { return }
            let m = CalendarModel(
                Repository<CalBlock>(db, orderColumn: "date"),
                Repository<CalendarConnection>(db, orderColumn: "connectedAt"))
            vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func content(_ vm: CalendarModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !vm.connected { connectBanner }
                if vm.byDate.isEmpty {
                    EmptyHint(text: "No scheduled blocks yet. Schedule a task, or connect Google Calendar above.")
                } else {
                    agenda(vm)
                }
            }
            .padding(20)
        }
    }

    private var connectBanner: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Google Calendar")
                Text("See your events alongside your plan, and push task blocks back.")
                    .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                if let connectError { Text(connectError).font(UFont.sans(12)).foregroundStyle(theme.palette.red) }
                UButton(connecting ? "Connecting…" : "Connect Google Calendar") { connect() }
                    .disabled(connecting)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func connect() {
        guard let calendar = model.calendar else { connectError = "Sign in first."; return }
        connecting = true; connectError = nil
        Task {
            let controller = GoogleConnectController(calendar)
            let result = await controller.connect()
            connecting = false
            switch result {
            case .success: await model.pullGoogleCalendar()
            case .failure(let error): connectError = "Couldn't connect. \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func agenda(_ vm: CalendarModel) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(vm.byDate, id: \.date) { day in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(day.date)
                    ForEach(day.blocks) { block in blockRow(block) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
