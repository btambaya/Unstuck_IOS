// Create-task sheet — a 1:1 port of the Android NewTaskSheet (scheduler-first,
// mirroring the web task-create-modal). Section order is identical:
//   name → When (Today/Tomorrow/Pick date/Later) → Time (free-slot chips +
//   custom + conflict warning) → Estimate chips → Remind me → Area pills →
//   First step → Tags → Repeat → Capture-a-thought drafts → "Add task".
// WHEN is mandatory; the time auto-picks the first free slot for the date
// unless the user chooses one. No priority picker (the web + DB don't surface
// one). Editing an existing task still goes through TaskEditor.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    let defaultEstimate: Int
    /// Optional prefill (e.g. tapping an empty calendar slot): a date and/or
    /// time the sheet should open on. Mirrors Android's prefillDate/prefillTime.
    let prefillDate: String?
    let prefillTime: String?

    init(defaultEstimate: Int = 25, prefillDate: String? = nil, prefillTime: String? = nil) {
        self.defaultEstimate = defaultEstimate
        self.prefillDate = prefillDate
        self.prefillTime = prefillTime
    }

    private static let estimatePresets = [15, 25, 45, 60, 90]
    private static let captureTags: [CaptureTag] = [.followUp, .idea, .edit, .question, .distraction]

    private struct CaptureDraft: Identifiable {
        let id = UUID()
        var body = ""
        var tag: CaptureTag = .followUp
    }

    // Stable "now" for the session so free-slot math doesn't drift mid-edit.
    private let now = Date()
    private var todayIso: String { Clock.dateISO(now) }
    private var tmrwIso: String { Clock.dateISO(Time.addDays(Time.startOfDay(now), 1)) }

    @State private var name = ""
    @State private var whenSel = "Today"          // Today / Tomorrow / Pick date / Later
    @State private var pickedDate = ""            // iso; only meaningful when whenSel == "Pick date"
    @State private var pickedTime: String?        // HH:mm
    @State private var autoTime = true            // false once a time is explicitly chosen
    @State private var estimate = 25
    @State private var area: String?
    @State private var firstMove = ""
    @State private var reminderLead: Int?         // nil = global default
    @State private var tags: [String] = []
    @State private var drafts: [CaptureDraft] = []

    // Recurrence (inline editor, same controls as TaskEditor).
    enum RepeatKind: String, CaseIterable { case none = "None", daily = "Daily", weekly = "Weekly", monthly = "Monthly" }
    @State private var repeatKind: RepeatKind = .none
    @State private var days: Set<Int> = []
    @State private var untilOn = false
    @State private var until = Date()

    // Live data.
    @State private var blocks: [CalBlock] = []
    @State private var areas: [LifeArea] = []
    @State private var vocab: [TagRow] = []

    // Pickers.
    @State private var showDatePicker = false
    @State private var showTimePicker = false
    @State private var showEstimate = false
    @State private var estimateText = ""
    @State private var datePick = Date()
    @State private var timePick = Date()
    @State private var tagPanelOpen = false
    @State private var tagQuery = ""

    private var effectiveDate: String? {
        switch whenSel {
        case "Later": return nil
        case "Today": return todayIso
        case "Tomorrow": return tmrwIso
        default: return pickedDate.isEmpty ? tmrwIso : pickedDate
        }
    }

    private var slots: [Slot] {
        guard let date = effectiveDate else { return [] }
        return findFreeSlotsForDate(blocks, durationMin: estimate, isoDate: date, now: now, limit: 4)
    }

    private var conflicts: [Conflict] {
        guard let date = effectiveDate, let t = pickedTime else { return [] }
        return findConflicts(date: date, startTime: t, durationMin: estimate, blocks: blocks)
    }

    private var canSubmit: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection
                    whenSection
                    if whenSel != "Later" { timeSection }
                    estimateSection
                    if whenSel != "Later" { remindSection }
                    if !areas.isEmpty { areaSection }
                    firstStepSection
                    tagsSection
                    repeatSection
                    captureSection
                    UButton("Add task", kind: canSubmit ? .primary : .dark) { submit() }
                        .disabled(!canSubmit)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await observe() }
            .onAppear(perform: seedPrefill)
            .onChange(of: effectiveDate) { _, _ in autoPick() }
            .onChange(of: estimate) { _, _ in autoPick() }
            // Re-pick the first free slot once blocks arrive (and on every
            // refresh) — autoPick is a no-op once the user chose a time.
            .onChange(of: blocks) { _, _ in autoPick() }
            .sheet(isPresented: $showDatePicker) { datePickerSheet }
            .sheet(isPresented: $showTimePicker) { timePickerSheet }
            .alert("Estimate (minutes)", isPresented: $showEstimate) {
                TextField("Minutes", text: $estimateText).keyboardType(.numberPad)
                Button("Save") { if let v = Int(estimateText), v > 0 { estimate = v } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }

    // MARK: sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("New task")
            TextField("What's the next thing on your mind?", text: $name, axis: .vertical)
                .font(UFont.sans(15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("When")
            chipScroll {
                ForEach(["Today", "Tomorrow", "Pick date", "Later"], id: \.self) { w in
                    let label = (w == "Pick date" && whenSel == "Pick date" && !pickedDate.isEmpty)
                        ? String(pickedDate.suffix(5)) : w
                    chip(label, selected: whenSel == w) {
                        autoTime = true
                        if w == "Pick date" {
                            datePick = Self.parseIso(pickedDate.isEmpty ? tmrwIso : pickedDate) ?? now
                            showDatePicker = true
                        } else {
                            whenSel = w
                        }
                    }
                }
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Time")
            chipScroll {
                if let pt = pickedTime, !slots.contains(where: { $0.startTime == pt }) {
                    chip(formatTime(pt), selected: true) { openTimePicker() }
                }
                ForEach(slots, id: \.startTime) { s in
                    chip(formatTime(s.startTime), selected: pickedTime == s.startTime) {
                        pickedTime = s.startTime; autoTime = false
                    }
                }
                chip("Custom…", selected: false) { openTimePicker() }
            }
            if slots.isEmpty && pickedTime == nil {
                Text("No free slots that day — pick a custom time, or it'll be added without one.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            if let c = conflicts.first {
                Text("Overlaps \(c.block.taskName)")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.palette.amberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Estimate")
            chipScroll {
                ForEach(Self.estimatePresets, id: \.self) { m in
                    chip("\(m)m", selected: estimate == m) { estimate = m }
                }
                if !Self.estimatePresets.contains(estimate) {
                    chip("\(estimate)m", selected: true) { openEstimate() }
                }
                chip("Custom…", selected: false) { openEstimate() }
            }
        }
    }

    private var remindSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Remind me")
            chipScroll {
                chip("Default", selected: reminderLead == nil) { reminderLead = nil }
                chip("Off", selected: reminderLead == 0) { reminderLead = 0 }
                ForEach([5, 10, 15], id: \.self) { m in
                    chip("\(m)m before", selected: reminderLead == m) { reminderLead = m }
                }
            }
        }
    }

    private var areaSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Area")
            chipScroll {
                pill("Unassigned", selected: area == nil, dot: nil) { area = nil }
                ForEach(areas) { a in
                    pill(a.name, selected: area == a.name, dot: theme.palette.areaColor(a.color)) {
                        area = (area == a.name) ? nil : a.name
                    }
                }
            }
        }
    }

    private var firstStepSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("First step", color: theme.palette.coral)
            TextField("The smallest concrete step…", text: $firstMove, axis: .vertical)
                .font(UFont.sans(15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Tags")
            tagPicker
        }
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Repeat")
            Picker("Repeat", selection: $repeatKind) {
                ForEach(RepeatKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if repeatKind == .weekly { weekdayToggles }
            if repeatKind != .none {
                Toggle("Ends on a date", isOn: $untilOn).font(UFont.sans(14))
                if untilOn { DatePicker("Until", selection: $until, displayedComponents: .date).font(UFont.sans(14)) }
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Capture a thought", color: theme.palette.primaryDeep)
            ForEach($drafts) { $draft in draftCard($draft) }
            Button { drafts.append(CaptureDraft()) } label: {
                Text("+ Capture")
                    .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(Capsule().stroke(theme.palette.line2))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: tag picker (Android TagPicker parity — #chips + search/create panel)

    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipScroll {
                ForEach(tags, id: \.self) { name in
                    Button { tags.removeAll { $0 == name } } label: {
                        HStack(spacing: 4) {
                            Text("#\(name)").font(UFont.sans(12, .medium))
                            Text("✕").font(UFont.sans(11))
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

    private var tagPanel: some View {
        let q = tagQuery.trimmingCharacters(in: .whitespaces)
        let matches = vocab.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let showCreate = !q.isEmpty && !vocab.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Search or create…", text: $tagQuery)
                .font(UFont.sans(13)).textFieldStyle(.plain)
                .padding(10)
                .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(8)
            ForEach(matches) { tag in
                let on = tags.contains(tag.name)
                Button {
                    if on { tags.removeAll { $0 == tag.name } } else { tags.append(tag.name) }
                } label: {
                    HStack(spacing: 8) {
                        Text(on ? "✓" : " ").font(UFont.sans(13)).foregroundStyle(theme.palette.primaryDeep).frame(width: 12)
                        Text("#\(tag.name)").font(UFont.sans(13)).foregroundStyle(theme.palette.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            if showCreate {
                Button {
                    let name = ensureTag(q)
                    if !tags.contains(name) { tags.append(name) }
                    tagQuery = ""
                } label: {
                    Text("Create \"\(q)\"").font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.primaryDeep)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
    }

    private func draftCard(_ draft: Binding<CaptureDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Something on your mind…", text: draft.body)
                    .font(UFont.sans(13)).textFieldStyle(.plain)
                Button {
                    drafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(theme.palette.ink3)
                }
                .buttonStyle(.plain)
            }
            chipScroll {
                ForEach(Self.captureTags, id: \.self) { tag in
                    let on = draft.wrappedValue.tag == tag
                    Button { draft.tag.wrappedValue = tag } label: {
                        HStack(spacing: 5) {
                            Circle().fill(captureTagColor(tag, theme)).frame(width: 6, height: 6)
                            Text(tag.rawValue).font(UFont.sans(12, on ? .semibold : .regular))
                                .foregroundStyle(on ? theme.palette.ink : theme.palette.ink2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(on ? theme.palette.ink.opacity(0.08) : .clear, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .background(on ? theme.palette.ink : theme.palette.bg2)
                        .foregroundStyle(on ? theme.palette.bg : theme.palette.ink)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: chip helpers

    private func chipScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
        }
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
                Text(label).font(UFont.sans(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line2))
        }
        .buttonStyle(.plain)
    }

    // MARK: picker sheets

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $datePick, in: now..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Pick date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDatePicker = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") {
                            pickedDate = Clock.dateISO(datePick)
                            whenSel = "Pick date"   // commit only on OK
                            showDatePicker = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private var timePickerSheet: some View {
        NavigationStack {
            DatePicker("Time", selection: $timePick, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding()
                .navigationTitle("Pick time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showTimePicker = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: timePick)
                            pickedTime = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
                            autoTime = false
                            showTimePicker = false
                        }
                    }
                }
        }
        .presentationDetents([.height(300)])
    }

    private func openTimePicker() {
        timePick = Self.parseHHmm(pickedTime) ?? now
        showTimePicker = true
    }

    private func openEstimate() {
        estimateText = String(estimate)
        showEstimate = true
    }

    // MARK: data + behavior

    private func observe() async {
        guard let repo = model.taskRepo, let db = model.db else { return }
        async let a: Void = {
            do { for try await snap in repo.observeTasksAndBlocks() { blocks = snap.blocks; areas = snap.areas } } catch {}
        }()
        async let b: Void = {
            do { for try await r in Repository<TagRow>(db, orderColumn: "sortOrder").observeValues() { vocab = r } } catch {}
        }()
        _ = await (a, b)
    }

    private func seedPrefill() {
        estimate = defaultEstimate
        if let pd = prefillDate {
            switch pd {
            case todayIso: whenSel = "Today"
            case tmrwIso: whenSel = "Tomorrow"
            default: whenSel = "Pick date"; pickedDate = pd
            }
        }
        if let pt = prefillTime { pickedTime = pt; autoTime = false }
        autoPick()
    }

    /// Re-pick the first free slot when the date/estimate changes — unless the
    /// user (or a prefill) chose a specific time. Mirrors Android's LaunchedEffect.
    private func autoPick() {
        if whenSel == "Later" { pickedTime = nil; return }
        if autoTime { pickedTime = slots.first?.startTime }
    }

    private func ensureTag(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = vocab.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing.name
        }
        let order = (vocab.map(\.sortOrder).max() ?? -1) + 1
        model.saveTag(TagRow(id: newUUID(), name: trimmed, color: nil, sortOrder: order))
        return trimmed
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

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = AppModel.isoNow()
        let recurrence = buildRecurrence()
        let later = whenSel == "Later"

        var t = model.addTask(
            name: trimmed, estimateMin: estimate,
            tags: tags.isEmpty ? nil : tags,
            lifeArea: area,
            firstPhysicalAction: firstMove.trimmingCharacters(in: .whitespaces).isEmpty ? nil : firstMove.trimmingCharacters(in: .whitespaces),
            later: later)

        // addTask persists the task without recurrence; attach it so the row
        // carries the rule and scheduleTaskAt can materialize the series.
        if let recurrence {
            t.recurrence = recurrence
            t.updatedAt = now
            model.saveTask(t)
        }

        if !later {
            if let lead = reminderLead { NotificationPrefs.setReminderOverride(taskId: t.id, leadMin: lead) }
            if let date = effectiveDate, let time = pickedTime {
                model.scheduleTaskAt(t, date: date, startTime: time)
            }
            ReminderScheduler.shared.resync()
        }

        for d in drafts {
            let body = d.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            model.saveCapture(Capture(id: newUUID(), taskId: t.id, tag: d.tag, body: body, at: now))
        }
        dismiss()
    }

    // MARK: date helpers

    private static func ymd(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func parseIso(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Time.civil(parts[0], parts[1], parts[2])
    }
    private static func parseHHmm(_ s: String?) -> Date? {
        guard let s else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts[0]; c.minute = parts[1]
        return Calendar.current.date(from: c)
    }
}
