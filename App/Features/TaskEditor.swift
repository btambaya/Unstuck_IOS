// Full task detail / edit screen — a 1:1 port of the Android TaskDetailSheet.
// Editable in place (no Save button): every field commits immediately, like
// Android's `vm.updateTask(...)`. Inline-edit name + first action, estimate +
// area chips, Focus / Schedule / Mark-done / Skip actions, a Status + Schedule
// meta row, recurrence, tags, a sessions list, and capture management.
// Recurring OCCURRENCES (row id = cal_block id) edit the TEMPLATE for field
// changes and route Mark-done / Skip to the occurrence block.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    let initialTask: TaskItem
    let existingBlocks: [CalBlock]

    init(task: TaskItem, existingBlocks: [CalBlock]) {
        self.initialTask = task
        self.existingBlocks = existingBlocks
    }

    private static let estimatePresets = [15, 25, 45, 60, 90]

    // Live store snapshots (Android's collectAsState flows).
    @State private var tasks: [TaskItem] = []
    @State private var blocks: [CalBlock] = []
    @State private var areas: [LifeArea] = []
    @State private var sessions: [Session] = []
    @State private var captures: [Capture] = []
    @State private var vocab: [TagRow] = []

    // Inline edit + dialog state.
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var editingAction = false
    @State private var actionDraft = ""
    @State private var showEstimate = false
    @State private var estimateText = ""
    @State private var confirmDelete = false
    @State private var scheduledLabel: String?

    // Schedule picker.
    @State private var showSchedule = false
    @State private var datePick = Date()
    @State private var timePick = Date()

    // Recurrence end-date picker.
    @State private var showUntil = false
    @State private var untilDraft = Date()

    // Tag picker panel.
    @State private var tagPanelOpen = false
    @State private var tagQuery = ""

    // MARK: derived (occurrence resolution + live task)

    private var occBlock: CalBlock? { occurrenceBlockFor(initialTask.id, tasks: tasks, blocks: blocks) }
    private var isOcc: Bool { occBlock != nil }
    /// Field edits target the TEMPLATE for an occurrence, else the live row.
    private var editTarget: TaskItem {
        if let b = occBlock, let tpl = tasks.first(where: { $0.id == b.taskId }) { return tpl }
        return tasks.first(where: { $0.id == initialTask.id }) ?? initialTask
    }
    private var isDone: Bool { occBlock?.done ?? editTarget.done }
    private var myBlocks: [CalBlock] {
        blocks.filter { $0.taskId == editTarget.id && isTaskBlock($0) }
            .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
    }
    private var scheduleText: String {
        if editTarget.later == true { return "Later" }
        if let b = myBlocks.first { return "\(b.date.suffix(5)) \(formatTime(b.startTime))" }
        return "Unscheduled"
    }
    private var statusText: String {
        if isDone { return "Completed" }
        if editTarget.totalFocused > 0 { return "In progress" }
        return "Not started"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow
                    nameField
                    firstActionCard
                    actionRow
                    if let s = scheduledLabel {
                        Text("Scheduled \(s)").font(UFont.sans(12)).foregroundStyle(theme.palette.green).padding(.top, 8)
                    }
                    if editTarget.later == true {
                        Button("Move out of Later") { model.setLater(editTarget, false) }
                            .font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(theme.palette.bg2, in: Capsule())
                            .buttonStyle(.plain).padding(.top, 8)
                    }
                    metaCard.padding(.top, 18)
                    repeatSection.padding(.top, 18)
                    tagsSection.padding(.top, 18)
                    if !taskSessions.isEmpty { sessionsSection.padding(.top, 18) }
                    capturesSection.padding(.top, 18)
                    if !isOcc {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Delete").font(UFont.sans(14, .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(theme.palette.red).padding(.top, 22)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 30)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await observe() }
            .alert("Estimate (minutes)", isPresented: $showEstimate) {
                TextField("Minutes", text: $estimateText).keyboardType(.numberPad)
                Button("Save") { if let v = Int(estimateText), v > 0 { update { $0.estimateMin = v } } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete this task?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteTask(editTarget.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its scheduled blocks and captures are removed too.") }
            .sheet(isPresented: $showSchedule) { scheduleSheet }
            .sheet(isPresented: $showUntil) { untilSheet }
        }
    }

    // MARK: header

    private var eyebrow: some View {
        HStack(spacing: 6) {
            AreaDot(areas.first(where: { $0.name == editTarget.lifeArea })?.color, size: 6)
            SectionLabel("\((editTarget.lifeArea ?? "Task").uppercased()) · TASK")
        }
    }

    private var nameField: some View {
        Group {
            if editingName {
                HStack(spacing: 8) {
                    TextField("Untitled task", text: $nameDraft, axis: .vertical)
                        .font(UFont.sans(28, .bold))
                    commitButton { let v = nameDraft.trimmingCharacters(in: .whitespaces); if !v.isEmpty && v != editTarget.name { update { $0.name = v } }; editingName = false }
                    cancelButton { editingName = false }
                }
            } else {
                Text(editTarget.name.isEmpty ? "Untitled task" : editTarget.name)
                    .font(UFont.sans(28, .bold))
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? theme.palette.ink3 : theme.palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { nameDraft = editTarget.name; editingName = true }
            }
        }
        .padding(.top, 6)
    }

    private var firstActionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("First physical action", color: theme.palette.coral)
            if editingAction {
                HStack(spacing: 8) {
                    TextField("Add one — the smallest concrete step.", text: $actionDraft, axis: .vertical)
                        .font(UFont.sans(14).italic())
                    commitButton { let v = actionDraft.trimmingCharacters(in: .whitespaces); update { $0.firstPhysicalAction = v.isEmpty ? nil : v }; editingAction = false }
                    cancelButton { editingAction = false }
                }
            } else {
                Text(editTarget.firstPhysicalAction ?? "Add one — the smallest concrete step.")
                    .font(UFont.sans(14).italic())
                    .foregroundStyle(editTarget.firstPhysicalAction == nil ? theme.palette.ink3 : theme.palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { actionDraft = editTarget.firstPhysicalAction ?? ""; editingAction = true }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 14)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { startFocus() } label: {
                HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 13)); Text("Focus").font(UFont.sans(15, .medium)) }
                    .foregroundStyle(.white)
                    .padding(.vertical, 11).frame(maxWidth: .infinity)
                    .background(theme.palette.coralDeep, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            if !isOcc {
                Button { openSchedule() } label: {
                    Text("Schedule").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line2))
                }
                .buttonStyle(.plain)
            }
            Button { model.toggleDone(initialTask) } label: {
                Text(isDone ? "✓ Done" : "Mark done").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            if isOcc {
                Button { model.skipOccurrence(initialTask.id); dismiss() } label: {
                    Text("Skip today").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 11)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
    }

    // MARK: estimate / area / meta card

    private var metaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Estimate")
                    chipScroll {
                        ForEach(Self.estimatePresets, id: \.self) { m in
                            chip("\(m)m", selected: editTarget.estimateMin == m) { update { $0.estimateMin = m } }
                        }
                        if !Self.estimatePresets.contains(editTarget.estimateMin) {
                            chip("\(editTarget.estimateMin)m", selected: true) { openEstimate() }
                        }
                        chip("Custom…", selected: false) { openEstimate() }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Area")
                    chipScroll {
                        pill("Unassigned", selected: editTarget.lifeArea == nil, dot: nil) { update { $0.lifeArea = nil } }
                        ForEach(areas) { a in
                            pill(a.name, selected: editTarget.lifeArea == a.name, dot: theme.palette.areaColor(a.color)) {
                                update { $0.lifeArea = (editTarget.lifeArea == a.name) ? nil : a.name }
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Button { if !isOcc { openSchedule() } } label: { metaCell("Schedule", scheduleText) }
                        .buttonStyle(.plain).disabled(isOcc).frame(maxWidth: .infinity, alignment: .leading)
                    metaCell("Status", statusText).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(UFont.sans(13)).foregroundStyle(theme.palette.ink)
        }
    }

    // MARK: repeat

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Repeat")
            if isOcc {
                Text("One day of “\(editTarget.name)” (\(recurrenceLabel(editTarget.recurrence).isEmpty ? "does not repeat" : recurrenceLabel(editTarget.recurrence))).")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
            } else {
                Text(recurrenceLabel(editTarget.recurrence).isEmpty ? "Does not repeat" : recurrenceLabel(editTarget.recurrence))
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                recurrenceEditor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recurrenceEditor: some View {
        let rec = editTarget.recurrence
        let mode = kindOf(rec)
        let days = weeklyDays(rec)
        let until = rec?.untilDate
        return VStack(alignment: .leading, spacing: 8) {
            chipScroll {
                chip("Never", selected: mode == .none) { model.setRecurrence(editTarget, nil) }
                chip("Daily", selected: mode == .daily) { model.setRecurrence(editTarget, .daily(until: until)) }
                chip("Weekly", selected: mode == .weekly) { model.setRecurrence(editTarget, .weekly(daysOfWeek: days.isEmpty ? [1] : days, until: until)) }
                chip("Monthly", selected: mode == .monthly) { model.setRecurrence(editTarget, .monthly(until: until)) }
            }
            if mode == .weekly {
                HStack(spacing: 6) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { idx, label in
                        let on = days.contains(idx)
                        Button {
                            let next = on ? days.filter { $0 != idx } : (days + [idx]).sorted()
                            model.setRecurrence(editTarget, .weekly(daysOfWeek: next.isEmpty ? [idx] : next, until: until))
                        } label: {
                            Text(label).font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(on ? theme.palette.ink : theme.palette.bg2)
                                .foregroundStyle(on ? theme.palette.bg : theme.palette.ink)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if mode != .none {
                HStack(spacing: 8) {
                    Text("Ends").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    chip(until.map { "by \($0.suffix(5))" } ?? "Open-ended", selected: until != nil) {
                        untilDraft = until.flatMap(Self.parseIso) ?? Date()
                        showUntil = true
                    }
                    if until != nil {
                        Button("Clear") { model.setRecurrence(editTarget, withUntil(rec, nil)) }
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.primaryDeep).buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Tags")
            VStack(alignment: .leading, spacing: 8) {
                chipScroll {
                    ForEach(editTarget.tags ?? [], id: \.self) { name in
                        Button { setTags((editTarget.tags ?? []).filter { $0 != name }) } label: {
                            HStack(spacing: 4) {
                                Text("#\(name)").font(UFont.sans(12, .medium)); Text("✕").font(UFont.sans(11))
                            }
                            .foregroundStyle(theme.palette.primaryDeep)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(theme.palette.primarySoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { tagPanelOpen.toggle(); tagQuery = "" } label: {
                        Text("+ Tag").font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .overlay(Capsule().stroke(theme.palette.line2))
                    }
                    .buttonStyle(.plain)
                }
                if tagPanelOpen { tagPanel }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagPanel: some View {
        let q = tagQuery.trimmingCharacters(in: .whitespaces)
        let selected = editTarget.tags ?? []
        let matches = vocab.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let showCreate = !q.isEmpty && !vocab.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Search or create…", text: $tagQuery)
                .font(UFont.sans(13)).textFieldStyle(.plain).padding(10)
                .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(8)
            ForEach(matches) { tag in
                let on = selected.contains(tag.name)
                Button { setTags(on ? selected.filter { $0 != tag.name } : selected + [tag.name]) } label: {
                    HStack(spacing: 8) {
                        Text(on ? "✓" : " ").font(UFont.sans(13)).foregroundStyle(theme.palette.primaryDeep).frame(width: 12)
                        Text("#\(tag.name)").font(UFont.sans(13)).foregroundStyle(theme.palette.ink); Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            if showCreate {
                Button { setTags(selected + [ensureTag(q)]); tagQuery = "" } label: {
                    Text("Create \"\(q)\"").font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.primaryDeep)
                        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
    }

    // MARK: sessions + captures

    private var taskSessions: [Session] { sessions.filter { $0.taskId == editTarget.id } }
    private var taskCaptures: [Capture] { captures.filter { $0.taskId == editTarget.id } }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Sessions")
            ForEach(taskSessions.prefix(6)) { s in
                Text("• \(s.actualSec / 60)m focused").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2).padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var captureBody = ""
    @State private var captureTag: CaptureTag = .followUp

    private var capturesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Captures")
            ForEach(taskCaptures) { cap in captureRow(cap) }
            addCaptureRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureRow(_ cap: Capture) -> some View {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let age = relPast(max(0, nowMs - (Time.parseMillis(cap.at) ?? nowMs)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(cap.tag.rawValue).font(UFont.sans(10, .medium)).foregroundStyle(captureTagColor(cap.tag, theme))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(captureTagColor(cap.tag, theme).opacity(0.14), in: Capsule())
                Text(age).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
            }
            Text(cap.body).font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
            HStack(spacing: 14) {
                Button("Promote to task →") { model.promoteCapture(cap) }
                    .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.primaryDeep)
                Button("Discard") { model.discardCapture(cap.id) }
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
        .padding(.vertical, 4)
    }

    private var addCaptureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Capture a thought…", text: $captureBody).font(UFont.sans(14)).textFieldStyle(.plain)
                if !captureBody.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { addCapture() } label: {
                        Text("Add").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                            .padding(.horizontal, 16).padding(.vertical, 7).background(theme.palette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            CaptureTagPicker(selection: $captureTag)
        }
        .padding(12)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 6)
    }

    // MARK: schedule + until sheets

    private var scheduleSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $datePick, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                DatePicker("Time", selection: $timePick, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("Schedule").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedule = false } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { commitSchedule() } }
            }
        }
        .presentationDetents([.medium])
    }

    private var untilSheet: some View {
        NavigationStack {
            DatePicker("Ends", selection: $untilDraft, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical).padding()
                .navigationTitle("Ends on").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showUntil = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { model.setRecurrence(editTarget, withUntil(editTarget.recurrence, Self.ymd(untilDraft))); showUntil = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: chip helpers (shared look with NewTaskSheet)

    private func chipScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content() } }
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
    private func pill(_ label: String, selected: Bool, dot: Color?, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(UFont.sans(13, selected ? .semibold : .regular)).foregroundStyle(selected ? theme.palette.bg : theme.palette.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line2))
        }
        .buttonStyle(.plain)
    }
    private func commitButton(_ tap: @escaping () -> Void) -> some View {
        Button(action: tap) { Text("✓").font(UFont.sans(18)).foregroundStyle(theme.palette.green) }.buttonStyle(.plain)
    }
    private func cancelButton(_ tap: @escaping () -> Void) -> some View {
        Button(action: tap) { Text("✕").font(UFont.sans(18)).foregroundStyle(theme.palette.ink3) }.buttonStyle(.plain)
    }

    // MARK: behavior

    private func observe() async {
        guard let repo = model.taskRepo, let db = model.db else { return }
        async let a: Void = {
            do { for try await snap in repo.observeTasksAndBlocks() { tasks = snap.tasks; blocks = snap.blocks; areas = snap.areas; sessions = snap.sessions } } catch {}
        }()
        async let b: Void = {
            do { for try await snap in repo.observeCaptures() { captures = snap } } catch {}
        }()
        async let c: Void = {
            do { for try await r in Repository<TagRow>(db, orderColumn: "sortOrder").observeValues() { vocab = r } } catch {}
        }()
        _ = await (a, b, c)
    }

    /// Mutate + persist the edit target (Android's `vm.updateTask(copy(...))`).
    private func update(_ mutate: (inout TaskItem) -> Void) {
        var t = editTarget
        mutate(&t)
        t.updatedAt = AppModel.isoNow()
        model.saveTask(t)
    }
    private func setTags(_ next: [String]) { update { $0.tags = next.isEmpty ? nil : next } }

    private func ensureTag(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = vocab.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing.name }
        let order = (vocab.map(\.sortOrder).max() ?? -1) + 1
        model.saveTag(TagRow(id: newUUID(), name: trimmed, color: nil, sortOrder: order))
        return trimmed
    }

    private func addCapture() {
        let text = captureBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.saveCapture(Capture(id: newUUID(), taskId: editTarget.id, tag: captureTag, body: text, at: AppModel.isoNow()))
        captureBody = ""
    }

    private func startFocus() {
        let t = editTarget
        dismiss()
        Task { try? await Task.sleep(nanoseconds: 350_000_000); model.router.beginFocus(t) }
    }

    private func openEstimate() { estimateText = String(editTarget.estimateMin); showEstimate = true }

    private func openSchedule() {
        datePick = myBlocks.first.flatMap { Self.parseIso($0.date) } ?? Date()
        timePick = myBlocks.first.flatMap { Self.parseHHmm($0.startTime) } ?? Date()
        showSchedule = true
    }

    private func commitSchedule() {
        let dateIso = Clock.dateISO(datePick)
        let c = Calendar.current.dateComponents([.hour, .minute], from: timePick)
        let timeIso = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        model.scheduleTaskAt(initialTask, date: dateIso, startTime: timeIso)
        if editTarget.later == true { model.setLater(editTarget, false) }
        scheduledLabel = "\(dateIso.suffix(5)) \(formatTime(timeIso))"
        ReminderScheduler.shared.resync()
        showSchedule = false
    }

    // MARK: recurrence helpers

    private enum RKind { case none, daily, weekly, monthly }
    private func kindOf(_ r: Recurrence?) -> RKind {
        switch r {
        case .none: return .none
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        }
    }
    private func weeklyDays(_ r: Recurrence?) -> [Int] {
        if case .weekly(let d, _) = r { return d }
        return []
    }
    private func withUntil(_ r: Recurrence?, _ until: String?) -> Recurrence? {
        switch r {
        case .none: return nil
        case .daily: return .daily(until: until)
        case .weekly(let d, _): return .weekly(daysOfWeek: d, until: until)
        case .monthly: return .monthly(until: until)
        }
    }

    private static func ymd(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func parseIso(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Time.civil(parts[0], parts[1], parts[2])
    }
    private static func parseHHmm(_ s: String) -> Date? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts[0]; c.minute = parts[1]
        return Calendar.current.date(from: c)
    }
}
