// Create-task sheet — the "conversational" redesign (mirrors the Android
// NewTaskSheet + web task-create-modal). Four serif questions instead of ten
// stacked sections:
//   What's on your mind? → When? (+ Time sub-row) → How long? → Which area?
// then a collapsed "More options" disclosure holding Share (one "Share with…"
// row → the pre-create Share screen, applied on submit), Tags and Repeat.
// WHEN is mandatory; the time auto-picks the first free slot for the date
// unless the user chooses one. First step / reminder / capture drafts moved to TaskEditor — new tasks
// use the global default reminder. No priority picker (the web + DB don't
// surface one). Editing an existing task still goes through TaskEditor.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckSync

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    /// The "Share with…" row's monogram disc (same as the Share screen's).
    @ScaledMetric(relativeTo: .body) private var monogramSize: CGFloat = 22
    /// How far each disc tucks under the next, and the row-coloured ring
    /// around each — 4 + 1.5 (web and Android's numbers) covers at most 5.5pt
    /// of the disc beneath, clear of its centred letter.
    private static let monogramOverlap: CGFloat = 4
    private static let monogramRing: CGFloat = 1.5
    /// The row's summary budgets, widest first: 28 is the one rule's
    /// (`shareDraftSummaryMaxLength`, same on web and Android); the tighter
    /// ones only cut NAMES, so the grade still shows on a narrow row.
    private static let summaryBudgets = [shareDraftSummaryMaxLength, 24, 20, 16, 12]   // five: see shareRow
    @Environment(\.dynamicTypeSize) private var typeSize

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

    private static let estimatePresets = [15, 25, 45, 90]

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
    @State private var tags: [String] = []

    // Recurrence (inline editor, same controls as TaskEditor).
    enum RepeatKind: String, CaseIterable { case none = "None", daily = "Daily", weekly = "Weekly", monthly = "Monthly" }
    @State private var repeatKind: RepeatKind = .none
    @State private var days: Set<Int> = []
    /// Weekly's rhythm: 1 = every week, 2…4 = every N weeks (spec §6).
    @State private var everyWeeks = 1
    /// The week picked in "Starts" (its Monday); nil = the first chip.
    @State private var startsAnchor: String?
    @State private var untilOn = false
    @State private var until = Date()

    // "More options" disclosure — collapsed by default so the sheet reads as
    // four questions; Share · Tags · Repeat live behind it.
    @State private var moreOpen = false

    // Per-task sharing: ONE "Share with…" row that opens the Share screen in
    // pre-create mode. The picks (Can edit / Can view / Hand over per person,
    // typed addresses held until the task is added) are LOCAL create-state in
    // the draft — the share RPCs fire on submit, after the task row exists.
    // Nothing is sent if the sheet is closed without adding the task.
    @State private var shareDraft: DraftShareTransport?
    @State private var showSharePicker = false

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

    /// Effective date resolved against a FRESH clock — used at submit time. The
    /// session's `now` is frozen at init so free-slot math doesn't drift mid-edit,
    /// but a sheet left open across midnight would otherwise schedule "Today"
    /// onto yesterday. Re-derive Today/Tomorrow from the real date on submit.
    private func effectiveDateNow() -> String? {
        let fresh = Date()
        let today = Clock.dateISO(fresh)
        switch whenSel {
        case "Later": return nil
        case "Today": return today
        case "Tomorrow": return Clock.dateISO(Time.addDays(Time.startOfDay(fresh), 1))
        default: return pickedDate.isEmpty ? Clock.dateISO(Time.addDays(Time.startOfDay(fresh), 1)) : pickedDate
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

    /// A repeating task needs a day and a time, and a one-off for a later day
    /// needs a time: every occurrence is a timed block and nothing can invent
    /// the time later (audit 2026-09-22, C7 / tasks-ui#5).
    private var needsTime: Bool {
        newTaskNeedsTime(repeats: repeatKind != .none, date: effectiveDate, todayIso: todayIso, pickedTime: pickedTime)
    }

    private var canSubmit: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !needsTime }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameSection
                    whenSection
                    estimateSection
                    if !areas.isEmpty { areaSection }
                    moreOptionsSection
                    if needsTime {
                        Text(whenSel == "Later" && repeatKind != .none
                             ? "A repeating task needs a day and a time — pick Today, Tomorrow or a date."
                             : "Pick a time to add this task.")
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    }
                    UButton("Add task", kind: canSubmit ? .primary : .dark) { submit() }
                        .disabled(!canSubmit)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Text("New task")
                        .font(UFont.serif(22, italic: true))
                        .foregroundStyle(theme.palette.ink)
                }
            }
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
                // Bounded to the server's 1…1440 (audit 2026-09-22, C4): the chip
                // shows what is stored, and 2000 was refused on every flush.
                Button("Save") { if let v = Int(estimateText), v > 0 { estimate = clampEstimateMin(v) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }

    // MARK: sections

    /// Serif "conversational" question header (the redesign's signature type).
    private func question(_ text: String) -> some View {
        Text(text).font(UFont.serif(22)).foregroundStyle(theme.palette.ink)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            question("What's on your mind?")
            TextField("What's the next thing on your mind?", text: $name, axis: .vertical)
                .font(UFont.sans(15))
                .textFieldStyle(.plain)
                // Stable handle for UI tests: Today's gateway composer is a
                // TextField too and sits behind this sheet, so `textFields
                // .firstMatch` resolves to the wrong one, and the placeholder
                // stops being reported the moment anything is typed.
                .accessibilityIdentifier("new-task-name")
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2))
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            question("When?")
            chipScroll {
                ForEach(["Today", "Tomorrow", "Pick date", "Later"], id: \.self) { w in
                    let label = (w == "Pick date" && whenSel == "Pick date" && !pickedDate.isEmpty)
                        ? String(pickedDate.suffix(5)) : w
                    chip(label, selected: whenSel == w) {
                        // Preserve a manually-chosen time across a WHEN-bucket
                        // switch — silently wiping the user's typed/picked time
                        // (forcing autoTime back on) was the surprising behavior.
                        // Only re-arm auto-pick when no explicit time was set.
                        if pickedTime == nil { autoTime = true }
                        if w == "Pick date" {
                            datePick = Self.parseIso(pickedDate.isEmpty ? tmrwIso : pickedDate) ?? now
                            showDatePicker = true
                        } else {
                            whenSel = w
                        }
                    }
                }
            }
            if whenSel != "Later" { timeSubsection }
        }
    }

    private var timeSubsection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Time")
            chipScroll {
                chip("Custom…", selected: false) { openTimePicker() }
                if let pt = pickedTime, !slots.contains(where: { $0.startTime == pt }) {
                    chip(ClockFormat.device.time(pt), selected: true) { openTimePicker() }
                }
                ForEach(slots, id: \.startTime) { s in
                    chip(ClockFormat.device.time(s.startTime), selected: pickedTime == s.startTime) {
                        pickedTime = s.startTime; autoTime = false
                    }
                }
            }
            if slots.isEmpty && pickedTime == nil {
                // "…added without one" is only true for a one-off today (C7).
                Text(needsTime ? "No free slots that day — pick a custom time."
                               : "No free slots that day — pick a custom time, or it'll be added without one.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            if let c = conflicts.first {
                Text("Overlaps \(c.block.taskName)")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.palette.amberSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.top, 4)
    }

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            question("How long?")
            chipScroll {
                chip("Custom…", selected: false) { openEstimate() }
                if !Self.estimatePresets.contains(estimate) {
                    chip("\(estimate)m", selected: true) { openEstimate() }
                }
                ForEach(Self.estimatePresets, id: \.self) { m in
                    chip("\(m)m", selected: estimate == m) { estimate = m }
                }
            }
        }
    }

    private var areaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            question("Which area?")
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

    // MARK: more options (Share · Tags · Repeat)

    private var moreOptionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(theme.palette.line).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { moreOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("More options").font(UFont.sans(14, .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(moreOpen ? 180 : 0))
                    Spacer()
                    Text("Share · Tags · Repeat").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                .foregroundStyle(theme.palette.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if moreOpen {
                shareSection
                tagsSection
                repeatSection
            }
        }
    }

    /// ONE row — "Share with…" · who (monograms + a one-line summary) · ›.
    /// It opens the Share screen in pre-create mode (the grade switch, the
    /// people picker, "Someone new", the connect-invite link); the picks stay
    /// LOCAL and the share RPCs fire on submit, after the task exists — a
    /// failed share never blocks creation. Ahmad 2026-09-24: a card per person
    /// with a full-width Off / Can edit / Can view switch was "terrible".
    /// Labelled "SHARE" like the sections around it (Tags, Repeat) — the
    /// same label web and Android put above the row.
    private var shareSection: some View {
        // Connections first, then held addresses — the summary's order, so
        // the first monogram is the first name it reads.
        let picks = shareDraftSummaryOrder(shareDraft?.draft.picks ?? [])
        let summary = shareDraftSummary(picks)
        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Share")
            Button(action: openSharePicker) { shareRow(picks: picks, summary: summary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Share with")
                .accessibilityValue(summary.spoken)
                .accessibilityHint("Pick who gets this task")
                .accessibilityIdentifier("new-task-share-row")
        }
        .sheet(isPresented: $showSharePicker) {
            if let shareDraft {
                ShareScreen(target: .task(id: "", name: name.trimmingCharacters(in: .whitespacesAndNewlines)),
                            draft: shareDraft)
            }
        }
    }

    /// The row's face. One line at normal sizes, never wrapped: when space is
    /// short the monograms drop out first, then the summary is re-cut to a
    /// tighter budget by the SAME rule (names give way, the grade stays), and
    /// only past the last budget does the text itself truncate. At
    /// accessibility sizes "Share with…" and the summary stack.
    private func shareRow(picks: [ShareDraftPick], summary: ShareDraftSummary) -> some View {
        func line(_ text: String) -> some View {
            Text(text).font(UFont.sans(13))
                .foregroundStyle(picks.isEmpty ? theme.palette.ink3 : theme.palette.ink2)
                .lineLimit(1)
        }
        let summaryText = line(summary.text)
        // The same rule at each tighter budget (`summaryBudgets[0]` is
        // `summary` itself).
        let cut = Self.summaryBudgets.map { shareDraftSummary(picks, maxLength: $0).text }
        let title = Text("Share with…").font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
        let chevron = Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.palette.ink3)
        return Group {
            if typeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        title.fixedSize(horizontal: false, vertical: true)
                        Text(summary.text).font(UFont.sans(13))
                            .foregroundStyle(picks.isEmpty ? theme.palette.ink3 : theme.palette.ink2)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    chevron
                }
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 10) {
                    title.lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if !picks.isEmpty { shareMonograms(picks) }
                            summaryText
                        }
                        // Explicit candidates (not a ForEach): ViewThatFits
                        // tries its direct children in order.
                        summaryText
                        line(cut[1])
                        line(cut[2])
                        line(cut[3])
                        line(cut[4]).truncationMode(.tail)
                    }
                    chevron
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line2))
        .contentShape(Rectangle())
    }

    /// Up to three picked people, overlapping — the Share screen's "has it"
    /// monogram (ink disc, bg letter; selection is the black-and-white pair),
    /// each ringed OUTSIDE its disc in the row's surface so the overlap reads.
    /// The ring used to be a stroke centred on the disc edge with a 20 %
    /// overlap, and the next disc bit into the letter beneath; now each disc
    /// tucks 4pt under the next plus the 1.5pt ring — 5.5pt, clear of the
    /// centred letter at every size. Decorative: the summary says who.
    private func shareMonograms(_ picks: [ShareDraftPick]) -> some View {
        let ring = Self.monogramRing
        return HStack(spacing: -(Self.monogramOverlap + ring * 2)) {
            ForEach(picks.prefix(3)) { p in
                Text(String(p.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(UFont.sans(10, .semibold))
                    .foregroundStyle(theme.palette.bg)
                    .frame(width: monogramSize, height: monogramSize)
                    .background(theme.palette.ink, in: Circle())
                    .padding(ring)
                    .background(theme.palette.surface, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }

    private func openSharePicker() {
        // Put the keyboard away first: UIKit hands focus back to the name
        // field when the Share screen closes, which scrolled the sheet to the
        // top — away from the row that just changed — with the keyboard up.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if shareDraft == nil { shareDraft = model.makeShareDraftTransport() }
        showSharePicker = true
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
            if repeatKind == .weekly {
                weekdayToggles
                weeksRow
                if everyWeeks >= 2 { startsRow }
            }
            if repeatKind != .none {
                Toggle("Ends on a date", isOn: $untilOn).font(UFont.sans(14))
                if untilOn { DatePicker("Until", selection: $until, in: Date()..., displayedComponents: .date).font(UFont.sans(14)) }
            }
        }
        // Weekly always keeps at least one day (Android seeds Monday) — a
        // weekly rule with no days would materialize nothing.
        .onChange(of: repeatKind) { _, kind in
            if kind == .weekly && days.isEmpty { days = [1] }
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
                .submitLabel(.done)
                // Return = the "Create" row when the query is a new tag; else
                // it just drops the keyboard.
                .onSubmit {
                    guard showCreate else { return }
                    let name = ensureTag(q)
                    if !tags.contains(name) { tags.append(name) }
                    tagQuery = ""
                }
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

    private var weekdayToggles: some View {
        HStack(spacing: 6) {
            ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { idx, label in
                let on = days.contains(idx)
                Button {
                    // Never empty the set (Android re-seeds the removed day).
                    if on { if days.count > 1 { days.remove(idx) } } else { days.insert(idx) }
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

    /// Every week · 2 weeks · 3 weeks · 4 weeks (every-n-weeks spec §6).
    private var weeksRow: some View {
        chipScroll {
            ForEach([1, 2, 3, 4], id: \.self) { n in
                chip(n == 1 ? "Every week" : "\(n) weeks", selected: everyWeeks == n) { everyWeeks = n }
            }
        }
    }

    /// The "Starts" chips: one per week of the cycle, each the first chosen
    /// weekday on or after the day picked above (else today) in its week, so
    /// "which Thursdays?" is explicit. The first is the default.
    private func startsCandidates(base: String) -> [StartsChip] {
        startsChips(days: Array(days), interval: everyWeeks, baseIso: base)
    }

    private func selectedStart(_ chips: [StartsChip]) -> StartsChip? {
        chips.first { $0.anchor == startsAnchor } ?? chips.first
    }

    private var startsRow: some View {
        let chips = startsCandidates(base: effectiveDate ?? todayIso)
        let picked = selectedStart(chips)
        return HStack(spacing: 8) {
            Text("Starts").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            chipScroll {
                ForEach(chips, id: \.anchor) { c in
                    chip(shortDayName(c.date), selected: c == picked) { startsAnchor = c.anchor }
                }
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
                            let c = Time.calendar.dateComponents([.hour, .minute], from: timePick)
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

    /// The rule to save, and — for every N weeks — the day its first
    /// occurrence is scheduled on (createSeriesStart): always the day picked
    /// (fresh clock), as for weekly and as on web; a later "Starts" chip only
    /// moves week one, and the picked day keeps its slot before it.
    private func buildRecurrence(startDate: String?) -> (Recurrence?, firstDate: String?) {
        let untilStr = untilOn ? Self.ymd(until) : nil
        switch repeatKind {
        case .none: return (nil, nil)
        case .daily: return (.daily(until: untilStr), nil)
        case .weekly:
            guard everyWeeks >= 2,
                  let s = createSeriesStart(days: Array(days), interval: everyWeeks, until: untilStr,
                                            pickedIso: startDate ?? todayIso, startsAnchor: startsAnchor) else {
                return (.weekly(daysOfWeek: days.sorted(), until: untilStr), nil)
            }
            return (s.rule, s.scheduleIso)
        case .monthly: return (.monthly(until: untilStr), nil)
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSubmit else { return }
        let now = AppModel.isoNow()
        let (recurrence, seriesStart) = buildRecurrence(startDate: effectiveDateNow())
        let later = whenSel == "Later"

        // The sheet remembers the estimate (slim settings, 2026-09-24): the
        // next new task starts at the last one picked. Same key as the old
        // Settings "Default focus length", so the assistant's
        // set_focus_defaults still sets it.
        model.settings.focusDefaultMin = estimate

        var t = model.addTask(
            name: trimmed, estimateMin: estimate,
            tags: tags.isEmpty ? nil : tags,
            lifeArea: area,
            firstPhysicalAction: nil,
            later: later)

        // addTask persists the task without recurrence; attach it so the row
        // carries the rule and scheduleTaskAt can materialize the series.
        if let recurrence {
            t.recurrence = recurrence
            t.updatedAt = now
            model.saveTask(t)
        }

        if !later {
            // Re-resolve Today/Tomorrow against a fresh clock so a sheet left open
            // across midnight doesn't schedule onto yesterday.
            // The picked day, as for weekly (see buildRecurrence) — never
            // re-anchored: the rule already carries the week one picked in
            // "Starts", and a later chip keeps the picked day as a one-off
            // before its weeks, as web's create modal does.
            if let date = seriesStart ?? effectiveDateNow(), let time = pickedTime {
                model.scheduleTaskAt(t, date: date, startTime: time, reanchor: false)
            }
            ReminderScheduler.shared.resync()
        }

        // Apply the picked share levels AFTER the created row lands server-side.
        // task_share validates ownership server-side, so firing it in a bare Task
        // (as before) races the still-uncommitted insert → `not_your_task` → the
        // share silently drops (T2). applyCreateShares flushes the tasks upsert to
        // the server first, mirroring the web awaitPendingUpsert('tasks', id).
        // Fire-and-forget by design: creation must never block on a share, so a
        // failed share (e.g. offline) is INTENTIONALLY non-blocking here — the
        // returned failures are discarded rather than surfaced, matching the web's
        // create flow. A dropped share is re-addable from the task's Share sheet.
        // The picks come from the pre-create Share screen's draft: connections
        // → task_share, typed addresses → share-task add (same grade mapping).
        let draft = shareDraft?.draft ?? ShareDraft()
        let shares = draft.userShares.map { (user: $0.userId, level: $0.level) }
        let emails = draft.emailShares.map { (email: $0.email, level: $0.level) }
        if !shares.isEmpty || !emails.isEmpty {
            let task = t
            Task { await model.applyCreateShares(task: task, shares: shares, emails: emails) }
        }
        dismiss()
    }

    // MARK: date helpers

    private static func ymd(_ date: Date) -> String {
        let c = Time.calendar.dateComponents([.year, .month, .day], from: date)
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
        var c = Time.calendar.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts[0]; c.minute = parts[1]
        return Time.calendar.date(from: c)
    }
}
