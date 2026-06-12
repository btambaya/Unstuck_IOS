// Create / edit a task, including the recurrence editor. Saving with a
// recurrence materializes future cal_blocks via the tested
// regenerateForTask (AppModel.saveTaskWithRecurrence).

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    let task: TaskItem?
    let existingBlocks: [CalBlock]
    /// New-task default estimate (Settings · Focus → "Default focus length").
    /// Only used when creating a task (`task == nil`); an existing task keeps
    /// its own estimate.
    let defaultEstimate: Int

    enum RepeatKind: String, CaseIterable { case none = "None", daily = "Daily", weekly = "Weekly", monthly = "Monthly" }

    @State private var name: String
    @State private var estimate: Int
    @State private var priority: Priority
    @State private var lifeArea: String
    @State private var later: Bool
    @State private var repeatKind: RepeatKind
    @State private var days: Set<Int>
    @State private var untilOn: Bool
    @State private var until: Date
    @State private var reminderOverride: Int?

    // Captures attached to this task (existing-task editor) — live from GRDB,
    // so adds/discards and remote sync refresh the list (Android
    // TaskDetailSheet "Captures" section parity).
    @State private var captures: [Capture] = []
    @State private var captureBody = ""
    @State private var captureTag: CaptureTag = .followUp
    /// Draft captures composed on a brand-new task; they auto-save against the
    /// task when it's created (Android NewTaskSheet capture-drafts parity).
    private struct CaptureDraft: Identifiable {
        let id = UUID()
        var body = ""
        var tag: CaptureTag = .followUp
    }
    @State private var drafts: [CaptureDraft] = []

    init(task: TaskItem?, existingBlocks: [CalBlock], defaultEstimate: Int = 25) {
        self.task = task
        self.existingBlocks = existingBlocks
        self.defaultEstimate = defaultEstimate
        _reminderOverride = State(initialValue: task.flatMap { NotificationPrefs.reminderOverride(taskId: $0.id) })
        _name = State(initialValue: task?.name ?? "")
        _estimate = State(initialValue: task?.estimateMin ?? defaultEstimate)
        _priority = State(initialValue: task?.priority ?? .medium)
        _lifeArea = State(initialValue: task?.lifeArea ?? "")
        _later = State(initialValue: task?.later ?? false)
        switch task?.recurrence {
        case .daily: _repeatKind = State(initialValue: .daily); _days = State(initialValue: [])
        case .weekly(let d, _): _repeatKind = State(initialValue: .weekly); _days = State(initialValue: Set(d))
        case .monthly: _repeatKind = State(initialValue: .monthly); _days = State(initialValue: [])
        case nil: _repeatKind = State(initialValue: .none); _days = State(initialValue: [])
        }
        let untilStr = task?.recurrence?.untilDate
        _untilOn = State(initialValue: untilStr != nil)
        _until = State(initialValue: untilStr.flatMap(Self.parse) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What needs doing?", text: $name)
                    Stepper("Estimate \(estimate)m", value: $estimate, in: 5...240, step: 5)
                    Picker("Priority", selection: $priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("Life area (optional)", text: $lifeArea)
                    Toggle("Save for later", isOn: $later)
                }
                Section("Repeat") {
                    Picker("Repeat", selection: $repeatKind) {
                        ForEach(RepeatKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if repeatKind == .weekly { weekdayToggles }
                    if repeatKind != .none {
                        Toggle("Ends on a date", isOn: $untilOn)
                        if untilOn { DatePicker("Until", selection: $until, displayedComponents: .date) }
                    }
                }
                // Per-task reminder override (spec 10 §1.11): Default uses
                // the global lead; Off / 5 / 10 / 15 min before. Scheduled,
                // non-Later tasks only (a Later task has no block to fire
                // on). Device-local; cleared on sign-out.
                if let task, !later, !existingBlocks.isEmpty {
                    Section("Remind me") {
                        Picker("Remind me", selection: $reminderOverride) {
                            Text("Default").tag(Int?.none)
                            Text("Off").tag(Int?.some(0))
                            Text("5m").tag(Int?.some(5))
                            Text("10m").tag(Int?.some(10))
                            Text("15m").tag(Int?.some(15))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: reminderOverride) { _, value in
                            NotificationPrefs.setReminderOverride(taskId: task.id, leadMin: value)
                            ReminderScheduler.shared.resync()
                        }
                    }
                }
                if task != nil {
                    Section("Captures") {
                        ForEach(captures) { cap in captureRow(cap) }
                        captureComposer
                    }
                } else {
                    Section("Capture a thought") {
                        ForEach($drafts) { $draft in draftRow($draft) }
                        Button {
                            drafts.append(CaptureDraft())
                        } label: {
                            Label("Capture", systemImage: "plus").font(UFont.sans(13, .medium))
                        }
                    }
                }
                if let task {
                    Section {
                        Button("Schedule for today") {
                            model.scheduleTask(task)
                            dismiss()
                        }
                        Button("Delete task", role: .destructive) {
                            model.deleteTask(task.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(task == nil ? "New task" : "Edit task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await observeCaptures() }
        }
    }

    // MARK: captures (Android TaskDetailSheet section parity)

    private func captureRow(_ cap: Capture) -> some View {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let age = relPast(max(0, nowMs - (Time.parseMillis(cap.at) ?? nowMs)))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(captureTagColor(cap.tag, theme)).frame(width: 7, height: 7)
                Text(cap.tag.rawValue.uppercased()).font(UFont.mono(10, .bold))
                    .foregroundStyle(captureTagColor(cap.tag, theme))
                Text(age).font(UFont.mono(10)).foregroundStyle(.secondary)
            }
            Text(cap.body).font(UFont.sans(14))
            HStack(spacing: 18) {
                Button("Promote to task →") { model.promoteCapture(cap) }
                    .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                Button("Discard") { model.discardCapture(cap.id) }
                    .font(UFont.sans(12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var captureComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Capture a thought…", text: $captureBody)
                if !captureBody.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add") { addCapture() }
                        .font(UFont.sans(12, .semibold))
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            CaptureTagPicker(selection: $captureTag)
        }
        .padding(.vertical, 2)
    }

    private func draftRow(_ draft: Binding<CaptureDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Something on your mind…", text: draft.body)
                Button {
                    drafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            CaptureTagPicker(selection: draft.tag)
        }
        .padding(.vertical, 2)
    }

    private func addCapture() {
        guard let task else { return }
        let text = captureBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.saveCapture(Capture(id: newUUID(), taskId: task.id, tag: captureTag,
                                  body: text, at: AppModel.isoNow()))
        captureBody = ""
    }

    private func observeCaptures() async {
        guard let task, let repo = model.taskRepo else { return }
        do {
            for try await snap in repo.observeCaptures() {
                captures = snap.filter { $0.taskId == task.id }
            }
        } catch {}
    }

    private var weekdayToggles: some View {
        HStack(spacing: 6) {
            ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { idx, label in
                let on = days.contains(idx)
                Button {
                    if on { days.remove(idx) } else { days.insert(idx) }
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(on ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func buildRecurrence() -> Recurrence? {
        let untilStr = untilOn ? Self.ymd(until) : nil
        switch repeatKind {
        case .none: return nil
        case .daily: return .daily(until: untilStr)
        case .weekly: return .weekly(daysOfWeek: days.sorted(), until: untilStr)
        case .monthly: return .monthly(until: untilStr)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = AppModel.isoNow()
        let recurrence = buildRecurrence()
        var t = task ?? TaskItem(id: newUUID(), name: trimmed, estimateMin: estimate, createdAt: now, updatedAt: now)
        t.name = trimmed
        t.estimateMin = estimate
        t.priority = priority
        t.lifeArea = lifeArea.trimmingCharacters(in: .whitespaces).isEmpty ? nil : lifeArea
        t.later = later
        t.recurrence = recurrence
        t.updatedAt = now
        if recurrence != nil || !existingBlocks.isEmpty {
            model.saveTaskWithRecurrence(t, existingBlocks: existingBlocks)
        } else {
            model.saveTask(t)
        }
        // Capture drafts ride along with a brand-new task (Android NewTaskSheet:
        // drafts auto-save against the task on "Add task").
        if task == nil {
            for d in drafts {
                let body = d.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                model.saveCapture(Capture(id: newUUID(), taskId: t.id, tag: d.tag, body: body, at: now))
            }
        }
        dismiss()
    }

    private static func ymd(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return Calendar.current.date(from: c)
    }
}
