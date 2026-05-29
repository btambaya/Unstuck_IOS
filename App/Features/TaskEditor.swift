// Create / edit a task, including the recurrence editor. Saving with a
// recurrence materializes future cal_blocks via the tested
// regenerateForTask (AppModel.saveTaskWithRecurrence).

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem?
    let existingBlocks: [CalBlock]

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

    init(task: TaskItem?, existingBlocks: [CalBlock]) {
        self.task = task
        self.existingBlocks = existingBlocks
        _name = State(initialValue: task?.name ?? "")
        _estimate = State(initialValue: task?.estimateMin ?? 25)
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
        }
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
