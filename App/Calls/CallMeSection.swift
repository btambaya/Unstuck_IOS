// Task editor → "Call me about this": book / update / cancel the
// call_requests row anchored to this task's next scheduled block. Lead-
// relative (`lead_min` + `block_id`, so the server follows the block if it
// moves); disabled with a hint until the task has a scheduled time. Notes
// are one per line — they're read back verbatim when the phone rings.

import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

struct CallMeSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    let task: TaskItem
    let blocks: [CalBlock]

    @State private var loaded = false
    @State private var row: CallRequest?
    @State private var enabled = false
    @State private var lead = CallSettings.defaultLeadMin
    @State private var notesText = ""
    @State private var busy = false
    @State private var error: String?

    private var client: CallsClient? { model.coordinator?.calls }
    private var nextBlock: CalBlock? { CallToolLogic.nextLiveBlock(blocks, now: Date()) }
    private var blockStart: Date? { nextBlock.flatMap { CallToolLogic.blockStart($0) } }
    private var canBook: Bool { blockStart != nil && task.later != true }
    private var notes: [String] { CallToolLogic.notes(notesText) }
    private var callAt: Date? { blockStart?.addingTimeInterval(TimeInterval(-lead * 60)) }

    var body: some View {
        if client != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("Call me about this")
                    Spacer()
                    Toggle("", isOn: Binding(get: { enabled }, set: { toggle($0) }))
                        .labelsHidden()
                        .disabled(!canBook || busy || !loaded)
                        .tint(theme.palette.primary)
                }
                if !canBook {
                    Text("Schedule it first — the call rings a few minutes before the task starts.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if enabled {
                    editor
                } else if loaded {
                    Text("Your phone rings before it starts and reads your notes back.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error).font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: task.id) { await load() }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CallSettings.leadOptions, id: \.self) { m in
                        chip("\(m)m before", selected: lead == m) { lead = m }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes to read back — one per line").font(UFont.sans(11, .medium)).foregroundStyle(theme.palette.ink3)
                TextEditor(text: $notesText)
                    .font(UFont.sans(14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                    .padding(8)
                    .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                if let callAt {
                    Text("Rings \(CallToolLogic.fmt(callAt))").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                }
                Spacer()
                Button { save() } label: {
                    Text(row == nil ? "Book call" : "Update call")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(theme.palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy || !dirty)
            }
        }
        .padding(12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
    }

    private var dirty: Bool {
        guard let row else { return true }
        return row.notes != notes || row.leadMin != lead || row.blockId != nextBlock?.id
    }

    private func chip(_ label: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(UFont.sans(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line2))
        }
        .buttonStyle(.plain)
    }

    // MARK: behaviour

    private func load() async {
        guard let client else { return }
        let existing = try? await client.forTask(taskId: task.id)
        row = existing
        if let existing {
            enabled = true
            lead = existing.leadMin ?? CallSettings.defaultLeadMin
            notesText = existing.notes.joined(separator: "\n")
        }
        loaded = true
    }

    private func toggle(_ on: Bool) {
        error = nil
        if on {
            enabled = true
            return
        }
        enabled = false
        guard let row, let client else { return }
        busy = true
        Task {
            do {
                try await client.cancel(id: row.id)
                self.row = nil
            } catch {
                self.error = "Couldn't cancel the call — try again."
                enabled = true
            }
            busy = false
        }
    }

    private func save() {
        guard let client, let callAt, let block = nextBlock,
              let uid = model.coordinator?.auth.currentUserId else { return }
        if let e = CallToolLogic.timeGuard(callAt, now: Date()) {
            error = e.replacingOccurrences(of: "error: ", with: "").capitalizedFirst
            return
        }
        error = nil
        busy = true
        let leadNow = lead
        let notesNow = notes
        Task {
            do {
                if let row {
                    let updated = try await client.update(id: row.id, callAt: callAt, blockId: .some(block.id),
                                                          leadMin: .some(leadNow), notes: notesNow)
                    self.row = updated ?? row
                } else {
                    self.row = try await client.create(userId: uid, taskId: task.id, blockId: block.id,
                                                       callAt: callAt, leadMin: leadNow,
                                                       label: task.name, notes: notesNow)
                }
            } catch {
                self.error = "Couldn't book the call — check your connection and try again."
            }
            busy = false
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
