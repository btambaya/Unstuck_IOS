// Full task detail / edit screen — a 1:1 port of the Android TaskDetailSheet.
// Editable in place (no Save button): every field commits immediately, like
// Android's `vm.updateTask(...)`. Inline-edit name + first action, estimate +
// area chips, a per-task reminder override (scheduled tasks), Focus / Schedule /
// Mark-done / Skip actions, a Status + Schedule meta row, recurrence, tags, a
// sessions list, and capture management.
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

    init(task: TaskItem) {
        self.initialTask = task
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
    /// A repeat chosen on a task with no timed block: held until the Schedule
    /// sheet (titled "Start repeating") gives the series a day and a time.
    @State private var pendingRecurrence: Recurrence?

    // Recurrence end-date picker.
    @State private var showUntil = false
    @State private var untilDraft = Date()

    // Tag picker panel.
    @State private var tagPanelOpen = false
    @State private var tagQuery = ""

    // The ONE Share screen (unified sharing v1) + the "Hand over to…" picker.
    @State private var showShare = false
    @State private var showHandOver = false

    // Bumped after each reminder-override write so the device-local (UserDefaults,
    // non-observable) value re-reads — `reminderLead` depends on it.
    @State private var reminderTick = 0

    // MARK: derived (occurrence resolution + live task)

    private var occBlock: CalBlock? { occurrenceBlockFor(initialTask.id, tasks: tasks, blocks: blocks) }
    private var isOcc: Bool { occBlock != nil }
    /// Field edits target the TEMPLATE for an occurrence, else the live row.
    private var editTarget: TaskItem {
        if let b = occBlock, let tpl = tasks.first(where: { $0.id == b.taskId }) { return tpl }
        return tasks.first(where: { $0.id == initialTask.id }) ?? initialTask
    }
    private var isDone: Bool { occBlock?.done ?? editTarget.done }
    /// For a recurring occurrence the row's estimate is its block duration
    /// (Android projects `estimateMin = block.durationMinutes`); the template's
    /// estimate can differ. Show the occurrence's own duration.
    private var displayEstimate: Int { occBlock?.durationMinutes ?? editTarget.estimateMin }
    private var myBlocks: [CalBlock] {
        blocks.filter { $0.taskId == editTarget.id && isTaskBlock($0) }
            .sorted { ($0.date, $0.startTime) < ($1.date, $1.startTime) }
    }
    private var scheduleText: String {
        Self.scheduleLabel(later: editTarget.later == true, occurrence: occBlock,
                           blocks: myBlocks, clock: .device)
    }
    /// The Schedule cell. On ONE DAY of a repeating task (an occurrence row,
    /// opened from Today or the calendar) it reads that day's own block: the
    /// series' blocks are sorted oldest first, so `blocks.first` showed
    /// yesterday's "09-23 17:00" on today's 09-24 occurrence. A plain task, or
    /// the series itself, keeps reading its first block.
    nonisolated static func scheduleLabel(later: Bool, occurrence: CalBlock?,
                                          blocks: [CalBlock], clock: ClockFormat) -> String {
        if later { return "Later" }
        if let b = occurrence ?? blocks.first { return "\(b.date.suffix(5)) \(clock.time(b.startTime))" }
        return "Unscheduled"
    }
    private var statusText: String {
        Self.statusLabel(done: isDone, isOccurrence: isOcc, focusedSec: editTarget.totalFocused)
    }
    /// The Status cell. For a day of a repeating task `editTarget` is the
    /// series TEMPLATE, whose totalFocused is the series' LIFETIME focus (every
    /// occurrence session accrues onto it), so reading it showed an untouched
    /// day as "In progress". A day is "Completed" or "Not started" — web and
    /// Android project occurrence rows with totalFocused 0 for the same reason
    /// (web/Android audit 2026-09-23, W10/A13). A plain task, or the series
    /// itself, keeps reading its own total.
    nonisolated static func statusLabel(done: Bool, isOccurrence: Bool, focusedSec: Int) -> String {
        if done { return "Completed" }
        if !isOccurrence && focusedSec > 0 { return "In progress" }
        return "Not started"
    }
    /// The task is handed to someone else (an outgoing 'assign' share): the
    /// owner's view is read-only — no Focus / Mark-done — but the Share controls
    /// stay live so they can take it back (downgrade / unshare), which re-enables
    /// Focus + completion (T3). Occurrences are never assigned out, so only a real
    /// task with an outgoing assign badge is gated.
    private var isAssignedOut: Bool {
        guard !isOcc else { return false }
        return model.shareState.assignedOut[editTarget.id] != nil
    }
    private var assignedOutName: String { model.shareState.assignedOut[editTarget.id] ?? "" }
    /// The editor is open on a repeating series itself (its TEMPLATE), not on
    /// one day of it.
    private var isSeries: Bool { !isOcc && editTarget.recurrence != nil }

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
                    // "Call me about this" (C1) — anchored to the task's next block.
                    if !isOcc { CallMeSection(task: editTarget, blocks: myBlocks).padding(.top, 18) }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                // A LABELLED "Share" (unified sharing v1 — testers couldn't find
                // the old bare icon) + the task-action menu ("Hand over to…").
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showShare = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.badge.plus")
                            Text("Share").font(UFont.sans(15, .medium))
                        }
                    }
                    .accessibilityLabel("Share task")
                    if !isOcc {
                        Menu {
                            Button { showHandOver = true } label: {
                                Label("Hand over to…", systemImage: "arrowshape.turn.up.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More actions")
                    }
                }
            }
            .sheet(isPresented: $showShare) { ShareScreen(target: .task(id: editTarget.id, name: editTarget.name)) }
            .sheet(isPresented: $showHandOver) {
                ShareScreen(target: .task(id: editTarget.id, name: editTarget.name), mode: .handOver)
            }
            // Live outgoing badges → the view-only (assigned-out) gate (T3).
            // Idempotent; refetches so a directly-opened editor has current state.
            .task { model.shareState.start() }
            .task { await observe() }
            .alert("Estimate (minutes)", isPresented: $showEstimate) {
                TextField("Minutes", text: $estimateText).keyboardType(.numberPad)
                // Bounded to the server's 1…1440 (audit 2026-09-22, C4): an estimate
                // over 1440 was resent and refused by every later whole-row edit.
                Button("Save") { if let v = Int(estimateText), v > 0 { update { $0.estimateMin = clampEstimateMin(v) } } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete this task?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteTask(editTarget.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its scheduled blocks and captures are removed too.") }
            // Cancel / swipe-down on "Start repeating" abandons the repeat.
            .sheet(isPresented: $showSchedule, onDismiss: { pendingRecurrence = nil }) { scheduleSheet }
            // A sheet presented while another is still dismissing is dropped,
            // so the until sheet hands over to "Start repeating" here.
            .sheet(isPresented: $showUntil, onDismiss: { if pendingRecurrence != nil { openSchedule() } }) { untilSheet }
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
        // Tour anchor: the first-action step opens a real task and rings this
        // block (empty account → the New-task FAB fallback takes over).
        .tourTarget(.firstAction)
        .padding(.top, 14)
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Assigned-out tasks are view-only for the owner — no Focus (T3).
                if !isAssignedOut {
                    Button { startFocus() } label: {
                        HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 13)); Text("Focus").font(UFont.sans(15, .medium)) }
                            .foregroundStyle(.white)
                            .padding(.vertical, 11).frame(maxWidth: .infinity)
                            .background(theme.palette.coral, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if !isOcc {
                    Button { openSchedule() } label: {
                        Text("Schedule").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line2))
                    }
                    .buttonStyle(.plain)
                }
                // …and no Mark-done (T3). The Share controls stay live to take it back.
                // An OPEN series has no done of its own — Mark done there
                // ended the whole series (audit 2026-09-22, C3), the reason the
                // Recurring tab hides its circle. A series the old path already
                // ended still shows "✓ Done", so it can be reopened.
                if !isAssignedOut && !(isSeries && !editTarget.done) {
                    Button { toggleDone() } label: {
                        Text(isDone ? "✓ Done" : "Mark done").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                }
                if isOcc {
                    Button { model.skipOccurrence(initialTask.id); dismiss() } label: {
                        Text("Skip today").font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
            if isAssignedOut {
                Text("You assigned this to \(shortName(assignedOutName)) — view only")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
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
                            chip("\(m)m", selected: displayEstimate == m) { update { $0.estimateMin = m } }
                        }
                        if !Self.estimatePresets.contains(displayEstimate) {
                            chip("\(displayEstimate)m", selected: true) { openEstimate() }
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
                // Pre-task reminder override — the create sheet no longer sets one
                // (new tasks use the global default), so the editor owns it. Only
                // meaningful for a scheduled, non-Later task (reminders fire off
                // scheduled blocks). "Default" clears the override.
                if editTarget.later != true && !myBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Remind me")
                        chipScroll {
                            chip("Default", selected: reminderLead == nil) { setReminder(nil) }
                            chip("Off", selected: reminderLead == 0) { setReminder(0) }
                            ForEach([5, 10, 15], id: \.self) { m in
                                chip("\(m)m before", selected: reminderLead == m) { setReminder(m) }
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
        let weeks = rec?.intervalWeeks ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            chipScroll {
                chip("Never", selected: mode == .none) { applyRecurrence(nil) }
                chip("Daily", selected: mode == .daily) { applyRecurrence(.daily(until: until)) }
                // Already weekly (every week or every N weeks): re-tapping keeps
                // the rule as it is, never drops an every-N-weeks to every week.
                chip("Weekly", selected: mode == .weekly) {
                    if mode != .weekly { applyWeekly(days: days.isEmpty ? [1] : days, interval: 1) }
                }
                chip("Monthly", selected: mode == .monthly) { applyRecurrence(.monthly(until: until)) }
            }
            if mode == .weekly {
                HStack(spacing: 6) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { idx, label in
                        let on = days.contains(idx)
                        Button {
                            let next = on ? days.filter { $0 != idx } : (days + [idx]).sorted()
                            // Moving days KEEPS the rhythm (and the weeks).
                            applyWeekly(days: next.isEmpty ? [idx] : next, interval: weeks)
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
                weeksRow(days: days, weeks: weeks)
                if weeks >= 2, case .everyNWeeks(_, _, let anchor, _)? = rec { startsRow(days: days, weeks: weeks, anchor: anchor) }
            }
            if mode != .none {
                HStack(spacing: 8) {
                    Text("Ends").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    chip(until.map { "by \($0.suffix(5))" } ?? "Open-ended", selected: until != nil) {
                        untilDraft = until.flatMap(Self.parseIso) ?? Date()
                        showUntil = true
                    }
                    if until != nil {
                        Button("Clear") { applyRecurrence(withUntil(rec, nil)) }
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2).buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Every week · 2 weeks · 3 weeks · 4 weeks (every-n-weeks spec §6); a
    /// rhythm set elsewhere past 4 (the assistant goes up to 8) shows as a
    /// fifth, selected chip.
    private func weeksRow(days: [Int], weeks: Int) -> some View {
        chipScroll {
            ForEach([1, 2, 3, 4], id: \.self) { n in
                chip(n == 1 ? "Every week" : "\(n) weeks", selected: weeks == n) {
                    if weeks != n { applyWeekly(days: days.isEmpty ? [1] : days, interval: n) }
                }
            }
            if weeks > 4 { chip("Every \(weeks) weeks", selected: true) {} }
        }
    }

    /// "Starts": one chip per week of the cycle, from the series' next date
    /// counted on the days shown (startsBase — web's rule), so the stored
    /// weeks are the first (selected) chip and it names the series' real
    /// first date. Tapping another moves week one there (the off weeks' open
    /// days go, the new ones come).
    private func startsRow(days: [Int], weeks: Int, anchor: String) -> some View {
        let today = Clock.todayISO()
        let base = startsBase(current: editTarget.recurrence, interval: weeks, todayIso: today,
                              blockIso: recurrenceAnchor(taskId: editTarget.id, blocks: myBlocks, todayIso: today)?.date,
                              newDays: days)
        let chips = startsChips(days: days, interval: weeks, baseIso: base)
        return HStack(spacing: 8) {
            Text("Starts").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            chipScroll {
                ForEach(chips, id: \.anchor) { c in
                    let on = sameWeeks(c.anchor, anchor, interval: weeks)
                    chip(shortDayName(c.date), selected: on) {
                        if !on { applyWeekly(days: days, interval: weeks, anchor: c.anchor) }
                    }
                }
            }
        }
    }

    /// Save a weekly-days rule with `interval` weeks (1 = plain weekly). Week
    /// one (spec §5): `anchor` when the user picked it in "Starts"; else the
    /// stored one when N is unchanged; else the week of the current rule's
    /// next date (or, from daily / monthly / no repeat, of the series' next
    /// block, else today).
    private func applyWeekly(days: [Int], interval: Int, anchor: String? = nil) {
        let rec = editTarget.recurrence
        let today = Clock.todayISO()
        let week1 = anchor ?? recurrenceEditAnchor(
            current: rec, newDays: days, newInterval: interval, todayIso: today,
            startIso: recurrenceAnchor(taskId: editTarget.id, blocks: myBlocks, todayIso: today)?.date)
        applyRecurrence(weeklyRule(days: days, interval: interval, anchor: week1, until: rec?.untilDate))
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
                            .foregroundStyle(theme.palette.bg)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(theme.palette.ink, in: Capsule())
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
                .submitLabel(.done)
                // Return = the "Create" row when the query is a new tag; else
                // it just drops the keyboard.
                .onSubmit {
                    guard showCreate else { return }
                    setTags(selected + [ensureTag(q)]); tagQuery = ""
                }
            ForEach(matches) { tag in
                let on = selected.contains(tag.name)
                Button { setTags(on ? selected.filter { $0 != tag.name } : selected + [tag.name]) } label: {
                    HStack(spacing: 8) {
                        Text(on ? "✓" : " ").font(UFont.sans(13)).foregroundStyle(theme.palette.ink).frame(width: 12)
                        Text("#\(tag.name)").font(UFont.sans(13)).foregroundStyle(theme.palette.ink); Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            if showCreate {
                Button { setTags(selected + [ensureTag(q)]); tagQuery = "" } label: {
                    Text("Create \"\(q)\"").font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
    }

    // MARK: sessions + captures

    /// This task's counted sessions (D1: no accidental < 1 min starts, runaway
    /// timers clamped — the Insights numbers), NEWEST first.
    private var taskSessions: [Session] {
        countableSessions(sessions.filter { $0.taskId == editTarget.id })
            .sorted { (PeriodTime.ms($0.completedAt) ?? 0) > (PeriodTime.ms($1.completedAt) ?? 0) }
    }
    private var taskCaptures: [Capture] { captures.filter { $0.taskId == editTarget.id } }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Sessions")
            ForEach(taskSessions.prefix(6)) { s in
                let when = sessionDayLabel(s.completedAt, now: Date()).map { "\($0) · " } ?? ""
                Text("• \(when)\(fmtFocusDur(roundedMinutes(s.actualSec))) focused")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2).padding(.vertical, 2)
            }
            if taskSessions.count > 6 {
                Text("+\(taskSessions.count - 6) earlier").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
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
                    .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink)
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
                    // Return = Add (addCapture no-ops on empty → just drops focus).
                    .submitLabel(.done)
                    .onSubmit(addCapture)
                if !captureBody.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { addCapture() } label: {
                        Text("Add").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                            .padding(.horizontal, 16).padding(.vertical, 7).background(theme.palette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            CaptureLengthNote(text: captureBody)
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
                DatePicker("Day", selection: $datePick, in: Time.calendar.startOfDay(for: Date())..., displayedComponents: .date)
                DatePicker("Time", selection: $timePick, displayedComponents: .hourAndMinute)
            }
            .navigationTitle(pendingRecurrence == nil ? "Schedule" : "Start repeating").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedule = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { if let pending = pendingRecurrence { startRepeating(pending) } else { commitSchedule() } }
                }
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
                        Button("OK") {
                            let r = withUntil(editTarget.recurrence, Self.ymd(untilDraft))
                            if !model.setRecurrence(editTarget, r) { pendingRecurrence = r }   // → "Start repeating" on dismiss
                            showUntil = false
                        }
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
        // Defense-in-depth: a deep-link / command-palette must not start focus on
        // a task the owner has assigned out (the button is already hidden) (T3).
        guard !isAssignedOut else { return }
        // Focus the day's OCCURRENCE row (audit 2026-09-22, C3): handed the
        // template, FocusView attached no block and "Done" ticked nothing. An
        // occurrence resolves to its own row (id = block id), a series to the
        // day's occurrence, a plain task to itself.
        let t = focusRowForId(isOcc ? initialTask.id : editTarget.id, tasks: tasks, blocks: blocks,
                              todayISO: Clock.todayISO()) ?? editTarget
        dismiss()
        Task { try? await Task.sleep(nanoseconds: 350_000_000); model.router.beginFocus(t) }
    }

    /// Mark-done, guarded so a hidden-button bypass can't complete a task the
    /// owner has assigned out (T3). Re-enabled by downgrading / unsharing.
    private func toggleDone() {
        guard !isAssignedOut else { return }
        // The LIVE row, never the open-time snapshot (audit 2026-09-22, C5):
        // the snapshot reverted every edit made in this sheet, and its frozen
        // `done` made a second tap re-complete instead of undo. An occurrence
        // passes its own row id (the cal_block id) so the flip lands on the
        // day's block — the template's id would target the whole series.
        model.toggleDone(isOcc ? initialTask : editTarget)
    }

    private func openEstimate() { estimateText = String(displayEstimate); showEstimate = true }

    /// Per-task reminder lead (minutes before the block; 0 = Off), or nil for the
    /// global default. Read live from NotificationPrefs so an occurrence resolves
    /// to its TEMPLATE's override (editTarget) — the id the create/schedule flow
    /// keys on. `reminderTick` forces the re-read after a write.
    private var reminderLead: Int? {
        _ = reminderTick
        return NotificationPrefs.reminderOverride(taskId: editTarget.id)
    }

    private func setReminder(_ lead: Int?) {
        NotificationPrefs.setReminderOverride(taskId: editTarget.id, leadMin: lead)
        ReminderScheduler.shared.resync()
        reminderTick += 1
    }

    private func openSchedule() {
        // Clamp the seed to today: the DatePicker range starts at startOfDay(now),
        // so seeding a past block's date would leave the bound value below the
        // range (the picker shows today but the stale past date persists until the
        // user scrolls). max(parsed, today) keeps the binding in range.
        let today = Time.calendar.startOfDay(for: Date())
        // A series seeds from its NEXT occurrence at the series' own time, not
        // from myBlocks.first — the oldest block, history at a time the series
        // may have left long ago — so OK without changes never re-plans the
        // series (audit 2026-09-22, C7). A repeat being started seeds its
        // first matching day: Weekly (Mon) opened on a Tuesday would otherwise
        // mint an off-pattern occurrence today.
        var seed = myBlocks.first
        var seedTime = seed?.startTime
        var parsed = seed.flatMap { Self.parseIso($0.date) } ?? Date()
        if let pending = pendingRecurrence {
            // Every N weeks: the rule's own next date (a 35-day scan finds
            // none from N = 6 when this week's days have passed).
            if case .everyNWeeks = pending {
                parsed = nextRuleDate(pending, fromIso: Clock.todayISO()).flatMap(Self.parseIso) ?? today
            } else {
                parsed = materializeOccurrences(pending, startDate: today, startTime: "00:00", horizonDays: 35)
                    .first.flatMap { Self.parseIso($0.date) } ?? today
            }
        } else if let rec = editTarget.recurrence {
            let todayIso = Clock.todayISO()
            seed = recurrenceAnchor(taskId: editTarget.id, blocks: myBlocks, todayIso: todayIso) ?? myBlocks.first
            seedTime = recurrenceEditStart(taskId: editTarget.id, recurrence: editTarget.recurrence,
                                           blocks: myBlocks, todayIso: todayIso)?.startTime ?? seed?.startTime
            parsed = seed.flatMap { Self.parseIso($0.date) } ?? Date()
            // Every N weeks seeds a date the RULE has: the first live block on
            // one, else the rule's next date — never an occurrence moved into
            // an off week, or "OK" without changes would re-anchor the series
            // there (every-n-weeks spec §6).
            if case .everyNWeeks = rec {
                let onRule = myBlocks.filter { !$0.done && !$0.skipped && $0.date >= todayIso && isRuleDay(rec, iso: $0.date) }
                if let first = onRule.first.flatMap({ Self.parseIso($0.date) }) ?? nextRuleDate(rec, fromIso: todayIso).flatMap(Self.parseIso) {
                    parsed = first
                }
            }
        }
        datePick = max(parsed, today)
        timePick = seedTime.flatMap { Self.parseHHmm($0) } ?? Date()
        showSchedule = true
    }

    /// Commit "Start repeating": the task had no timed block, so the rule is
    /// saved FIRST (awaited) and scheduleTaskAt then builds the series plus the
    /// chosen day's occurrence — today's too when today is picked (audit
    /// 2026-09-22, C7 / tasks-ui#11). The Later un-park rides in the same row:
    /// a separate setLater would write the row back without the rule.
    private func startRepeating(_ recurrence: Recurrence) {
        let dateIso = Clock.dateISO(datePick)
        let c = Time.calendar.dateComponents([.hour, .minute], from: timePick)
        let timeIso = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        pendingRecurrence = nil
        var next = editTarget
        next.recurrence = recurrence
        if next.later == true { next.later = false }
        next.updatedAt = AppModel.isoNow()
        Task {
            guard await model.saveTaskAwaiting(next) else { return }
            model.scheduleTaskAt(next, date: dateIso, startTime: timeIso)
            ReminderScheduler.shared.resync()
        }
        scheduledLabel = "\(dateIso.suffix(5)) \(ClockFormat.device.time(timeIso))"
        showSchedule = false
    }

    private func commitSchedule() {
        let dateIso = Clock.dateISO(datePick)
        let c = Time.calendar.dateComponents([.hour, .minute], from: timePick)
        let timeIso = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        // Schedule the LIVE row (audit 2026-09-22, C5): the open-time snapshot
        // routed on a stale recurrence (a Repeat set in this sheet took the
        // one-off path) and its whole-row bump reverted this session's edits.
        // The un-park is composed INTO the row handed on, so every whole-row
        // write in the chain carries later=false and scheduleTaskAt's
        // move-count bump is the last write — a trailing setLater built from
        // the pre-schedule row used to land after it and undo the bump.
        var target = editTarget
        // Scheduling an every-N-weeks series re-anchors it on the chosen day
        // (spec §5). With a Later un-park in play, both whole-row writes carry
        // the new weeks, the row awaited before the series is planned —
        // setLater's un-awaited write could otherwise land after it and put
        // the old weeks back.
        if let re = reanchoredForSchedule(target.recurrence, chosenIso: dateIso), target.later == true {
            target.recurrence = re
            target.later = false
            target.updatedAt = AppModel.isoNow()
            let row = target
            Task {
                guard await model.saveTaskAwaiting(row) else { return }
                model.scheduleTaskAt(row, date: dateIso, startTime: timeIso)
                ReminderScheduler.shared.resync()
            }
            scheduledLabel = "\(dateIso.suffix(5)) \(ClockFormat.device.time(timeIso))"
            showSchedule = false
            return
        }
        if target.later == true {
            model.setLater(target, false)
            target.later = false
        }
        model.scheduleTaskAt(target, date: dateIso, startTime: timeIso)
        scheduledLabel = "\(dateIso.suffix(5)) \(ClockFormat.device.time(timeIso))"
        ReminderScheduler.shared.resync()
        showSchedule = false
    }

    // MARK: recurrence helpers

    /// Set / change / clear the repeat. On a task with no timed block the model
    /// refuses (a series needs a day and a time), so ask via the Schedule sheet
    /// instead of inventing 09:00 from tomorrow and hiding the task from Today
    /// (audit 2026-09-22, C7 / tasks-ui#11).
    private func applyRecurrence(_ r: Recurrence?) {
        if !model.setRecurrence(editTarget, r) {
            pendingRecurrence = r
            openSchedule()
        }
    }

    private enum RKind { case none, daily, weekly, monthly }
    private func kindOf(_ r: Recurrence?) -> RKind {
        switch r {
        case .none: return .none
        case .daily: return .daily
        // Every N weeks is the Weekly mode with its weeks row set past 1.
        case .weekly, .everyNWeeks: return .weekly
        case .monthly: return .monthly
        }
    }
    private func weeklyDays(_ r: Recurrence?) -> [Int] {
        r?.weekDays ?? []
    }
    private func withUntil(_ r: Recurrence?, _ until: String?) -> Recurrence? {
        // An every-N-weeks rule is written through weeklyRule, so its anchor
        // goes back as its Monday (spec §0 rule 3) — the weeks never change.
        if case .everyNWeeks(let n, let days, let anchor, _)? = r {
            return weeklyRule(days: days, interval: n, anchor: anchor, until: until)
        }
        return r?.withUntil(until)
    }

    private static func ymd(_ date: Date) -> String {
        let c = Time.calendar.dateComponents([.year, .month, .day], from: date)
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
        var c = Time.calendar.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts[0]; c.minute = parts[1]
        return Time.calendar.date(from: c)
    }
}
