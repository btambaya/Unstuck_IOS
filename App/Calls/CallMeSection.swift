// Task editor → "Call me about this": book / update / cancel the
// call_requests row anchored to this task's next scheduled block. Lead-
// relative (`lead_min` + `block_id`, so the server follows the block if it
// moves); disabled with a hint until the task has a scheduled time. Notes
// are one per line (a note may contain ";"), 20 × 300 chars like the web —
// they're read back verbatim when the phone rings. Update / cancel are
// compare-and-set on the row still being live: a miss reloads instead of
// showing stale state.
//
// The row comes from the LOCAL call_requests mirror (offline-safe; a status
// change made by the dispatcher / the phone's outcome report / another device
// updates the toggle live through the mirror's observation) — the live read
// runs only when the mirror is still empty. Writes go through the same
// MirrorFirstCallStore the assistant's tools use.

import AVFoundation
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
    /// The microphone was refused: the call still rings, but can't hear them.
    @State private var micDenied = AVAudioApplication.shared.recordPermission == .denied

    private var store: MirrorFirstCallStore? { model.coordinator?.callStore }
    private var mirror: CallRequestsMirror? { model.coordinator?.callsMirror }
    private var nextBlock: CalBlock? { CallToolLogic.nextLiveBlock(blocks, now: Date()) }
    private var blockStart: Date? { nextBlock.flatMap { CallToolLogic.blockStart($0) } }
    private var canBook: Bool { blockStart != nil && task.later != true }
    private var notes: [String] { CallToolLogic.notes(notesText) }
    private var callAt: Date? { blockStart?.addingTimeInterval(TimeInterval(-lead * 60)) }
    /// This phone would decline the call at `callAt` (Calls off here, or
    /// outside its allowed hours) — worded for the editor. Also flags a row
    /// booked on the web, or moved with its block, into hours this phone
    /// declines (audit 2026-09-22, C12).
    private var hoursHint: String? {
        guard let callAt else { return nil }
        // A call IS the assistant: with it switched off, this phone declines
        // the call on arrival (CallCoordinator) — say so where it's booked.
        if !model.settings.assistantEnabled {
            return "The Assistant is off on this iPhone, so it would decline this call. Turn it on in Settings › Assistant & privacy."
        }
        guard CallToolLogic.deviceGuard(callAt) != nil else { return nil }
        guard CallSettings.enabled else {
            return "Calls are off on this iPhone, so it would decline this call. Switch them on in Settings › Notifications & calls."
        }
        let hours = CallSettings.hoursLabel(start: CallSettings.windowStart, end: CallSettings.windowEnd,
                                            refusing: CallSettings.minuteOfDay(callAt))
        return "\(CallSettings.hhmm(callAt)) is outside this iPhone's call hours (\(hours)), so it would decline this call. Pick another lead, move the task, or widen the hours in Settings › Notifications & calls."
    }
    /// Booking, or changing the ring time (lead / slot), meets the hint;
    /// a notes-only edit of an existing row doesn't — update_call's rule.
    private var changesTime: Bool {
        guard let row else { return true }
        return row.leadMin != lead || row.blockId != nextBlock?.id
    }

    var body: some View {
        if store != nil {
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
                if canBook, enabled, micDenied, CallSettings.enabled {
                    Text("Calls need microphone access — turn it on for Unstuck in iOS Settings, or it will ring but can't hear you.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error).font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                }
                AIConsentNoteLine(host: .taskEditor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .aiConsentSheet(.taskEditor)
            .task(id: task.id) { await load() }
            .task(id: task.id) { await observeMirror() }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CallSettings.leadOptions, id: \.self) { m in
                        // Remembers the last pick (slim settings): the next
                        // "Call me about this" — and the assistant's
                        // request_call — start from it (the same key the old
                        // Settings row wrote).
                        chip("\(m)m before", selected: lead == m) {
                            lead = m
                            CallSettings.defaultLeadMin = m
                        }
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
                .disabled(busy || !dirty || (hoursHint != nil && changesTime))
            }
            if let hoursHint {
                Text(hoursHint).font(UFont.sans(12)).foregroundStyle(theme.palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard let store else { return }
        // The mirror first; the server only while the mirror has nothing yet.
        var existing = try? store.mirror.forTask(taskId: task.id)
        if existing == nil, (try? store.mirror.isEmpty()) == true {
            existing = try? await store.client.forTask(taskId: task.id)
            if let existing { try? store.mirror.upsert(existing) }
        }
        apply(existing)
        // Re-read each time the editor opens: the mic may have been turned
        // on in iOS Settings since (audit 2026-09-22, C13).
        micDenied = AVAudioApplication.shared.recordPermission == .denied
        loaded = true
    }

    /// Follow the mirror: a call that rang / was cancelled elsewhere drops the
    /// toggle; one booked from the web / the assistant raises it.
    private func observeMirror() async {
        guard let mirror else { return }
        do {
            for try await live in mirror.observeForTask(taskId: task.id) {
                guard loaded, !busy else { continue }
                if live?.id != row?.id || live?.status != row?.status || live?.notes != row?.notes
                    || live?.leadMin != row?.leadMin || live?.blockId != row?.blockId {
                    apply(live)
                }
            }
        } catch {}
    }

    private func apply(_ existing: CallRequest?) {
        row = existing
        if let existing {
            enabled = true
            lead = existing.leadMin ?? CallSettings.defaultLeadMin
            notesText = existing.notes.joined(separator: "\n")
        } else {
            enabled = false
        }
    }

    private func toggle(_ on: Bool) {
        error = nil
        if on {
            // A call is a conversation with the assistant: the first one asks
            // for the AI-consent OK; "Not now" leaves the toggle off.
            model.withAIConsent(.callsOn, from: .taskEditor) { enabled = true }
            return
        }
        enabled = false
        guard let row, let store else { return }
        busy = true
        Task {
            do {
                // nil ⇒ it already rang / was cancelled elsewhere — gone either way.
                _ = try await store.cancelCall(id: row.id)
                self.row = nil
            } catch {
                self.error = "Couldn't cancel the call — try again."
                enabled = true
            }
            busy = false
        }
    }

    private func save() {
        guard let store, let callAt, let block = nextBlock,
              let uid = model.coordinator?.auth.currentUserId else { return }
        if let e = CallToolLogic.timeGuard(callAt, now: Date()) {
            error = e.replacingOccurrences(of: "error: ", with: "").capitalizedFirst
            return
        }
        // The button is disabled while the hint applies to a booking or a
        // time change, but CallSettings isn't observed, so the render can be
        // stale — the same check again before anything is written (audit
        // 2026-09-22, C12).
        if changesTime, let hint = hoursHint {
            error = hint
            return
        }
        error = nil
        busy = true
        let leadNow = lead
        let notesNow = notes
        func write() {
            Task {
                do {
                    if let row {
                        if let updated = try await store.patch(id: row.id, callAt: callAt, blockId: .some(block.id),
                                                               leadMin: .some(leadNow), label: nil, notes: notesNow) {
                            self.row = updated
                        } else {
                            // Zero rows: the call rang / was cancelled underneath us.
                            self.error = "That call changed underneath you — reloaded."
                            await load()
                        }
                    } else {
                        self.row = try await store.book(userId: uid, taskId: task.id, blockId: block.id,
                                                        callAt: callAt, leadMin: leadNow,
                                                        label: task.name, notes: notesNow)
                    }
                } catch {
                    self.error = "Couldn't book the call — check your connection and try again."
                }
                busy = false
            }
        }
        // "Call me about this" never asked for the microphone, and a
        // lock-screen answer can't show the prompt — so the first call
        // couldn't hear them (audit 2026-09-22, C13). Ask now, while the
        // editor is in front of them. A refusal still books (the ring is
        // still the reminder) and the red line says it can't hear them.
        // `busy` keeps the button off while the prompt is up. Not with Calls
        // off here: this phone declines the call anyway.
        guard CallSettings.enabled else { write(); return }
        CallSettingsView.ensureMicrophone { granted in
            micDenied = !granted
            write()
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
