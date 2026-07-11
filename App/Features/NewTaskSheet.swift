// Create-task sheet — the "conversational" redesign (mirrors the Android
// NewTaskSheet + web task-create-modal). Four serif questions instead of ten
// stacked sections:
//   What's on your mind? → When? (+ Time sub-row) → How long? → Which area?
// then a collapsed "More options" disclosure holding Share/assign (per-task
// circle sharing, applied on submit), Tags and Repeat. WHEN is mandatory; the
// time auto-picks the first free slot for the date unless the user chooses
// one. First step / reminder / capture drafts moved to TaskEditor — new tasks
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
    @State private var untilOn = false
    @State private var until = Date()

    // "More options" disclosure — collapsed by default so the sheet reads as
    // four questions; Share · Tags · Repeat live behind it.
    @State private var moreOpen = false

    // Per-task sharing (picked levels are LOCAL create-state — the share RPCs
    // fire on submit, after the task row exists). userId → level; absent = Off.
    @State private var shareLevels: [String: ShareLevel] = [:]
    @State private var circle: CircleModel?

    // Inline invite-a-new-person state (same flow as ShareSheet).
    @State private var inviting = false
    @State private var inviteEmail = ""
    @State private var inviteResult: InviteOutcome?
    @State private var inviteErr: String?
    @State private var copied = false

    private struct InviteOutcome { let added: Bool; let emailed: Bool; let link: String?; let email: String }

    /// nil == "Off"; else the granted level. Mirrors ShareSheet's OPTIONS list.
    private let shareOptions: [(value: ShareLevel?, label: String)] = [
        (nil, "Off"), (.view, "View"), (.partner, "Partner"), (.assign, "Assign"),
    ]

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

    private var canSubmit: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var activeMembers: [CircleMember] {
        (circle?.members ?? []).filter { $0.status == "active" && $0.memberUserId != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameSection
                    whenSection
                    estimateSection
                    if !areas.isEmpty { areaSection }
                    moreOptionsSection
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
            .task {
                let c = circle ?? model.makeCircleModel()
                circle = c
                c.start()
            }
            .onAppear(perform: seedPrefill)
            .onDisappear { circle?.stop() }
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
                    chip(formatTime(pt), selected: true) { openTimePicker() }
                }
                ForEach(slots, id: \.startTime) { s in
                    chip(formatTime(s.startTime), selected: pickedTime == s.startTime) {
                        pickedTime = s.startTime; autoTime = false
                    }
                }
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

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Share or assign")
            if !activeMembers.isEmpty {
                VStack(spacing: 10) {
                    ForEach(activeMembers) { m in shareMemberRow(m) }
                }
            }
            if inviting { invitePanel } else { addSomeoneButton }
            if activeMembers.isEmpty && !inviting {
                Text("Share this task with someone in your circle.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
            } else if !activeMembers.isEmpty {
                shareExplainer
            }
        }
    }

    /// One circle member: initial avatar + name/relationship, and a full-width
    /// Off/View/Partner/Assign segmented row. Selection is LOCAL — the share
    /// RPCs fire on submit (a failed share must never block creation).
    private func shareMemberRow(_ m: CircleMember) -> some View {
        let userId = m.memberUserId ?? ""
        let current = shareLevels[userId]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String((m.memberName ?? "?").prefix(1)).uppercased())
                    .font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(theme.palette.primary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.memberName ?? "Member").font(UFont.sans(14, .semibold))
                        .foregroundStyle(theme.palette.ink).lineLimit(1)
                    if let label = m.relationshipLabel {
                        Text(label).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 2) {
                ForEach(shareOptions, id: \.label) { opt in
                    let selected = current == opt.value
                    Button {
                        if let level = opt.value { shareLevels[userId] = level }
                        else { shareLevels.removeValue(forKey: userId) }
                    } label: {
                        Text(opt.label)
                            .font(UFont.sans(11, .semibold))
                            .foregroundStyle(selected ? .white : theme.palette.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selected ? theme.palette.coralDeep : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.palette.bg, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line2))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: inline invite (same flow as ShareSheet)

    private var addSomeoneButton: some View {
        Button { inviting = true; inviteResult = nil; inviteErr = nil } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Add someone").font(UFont.sans(13, .semibold))
            }.foregroundStyle(theme.palette.primaryDeep)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var invitePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = inviteResult {
                if r.added {
                    Text("✓ Added — pick their level above.")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
                } else if r.emailed {
                    Text("✓ Invite sent to \(r.email). Pick their level once they accept.")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
                } else if let link = r.link {
                    Text("Invite link ready\(copied ? " · copied!" : "")")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(link).font(UFont.mono(12)).foregroundStyle(theme.palette.ink2)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .textSelection(.enabled)
                    Text(r.email.isEmpty ? "Send it to them — it's the only way in."
                         : "We couldn't email them — send this link instead.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                HStack(spacing: 8) {
                    if let link = r.link {
                        Button { copy(link) } label: {
                            Text("Copy link").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(theme.palette.ink, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Button { inviting = false; inviteResult = nil } label: {
                        Text("Done").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
            } else {
                Text("Their email (optional)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                TextField("name@example.com", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("We'll email them the invite. Or leave it blank for a link you send yourself.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                if let inviteErr {
                    Text(inviteErr).font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                }
                HStack(spacing: 8) {
                    Button { generateInvite() } label: {
                        Text(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty ? "Generate link" : "Send invite")
                            .font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.ink, in: Capsule())
                    }.buttonStyle(.plain)
                    Button { inviting = false; inviteErr = nil } label: {
                        Text("Cancel").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func generateInvite() {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        inviteErr = nil
        Task {
            guard let circle else { inviteErr = "Sign in to invite people."; return }
            let r = await circle.invite(email: email.isEmpty ? nil : email)
            if r.ok == false, r.added != true, r.emailed != true, r.link == nil {
                inviteErr = r.error == "circle_full" ? "Your circle is full." : "Could not create invite."
                return
            }
            inviteResult = InviteOutcome(added: r.added == true, emailed: r.emailed == true, link: r.link, email: email)
            inviteEmail = ""
            if let link = r.link { copy(link) }
        }
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
    }

    private var shareExplainer: some View {
        (Text("View").font(UFont.sans(12, .semibold)) + Text(" — they see it + get pinged when you start & finish. ").font(UFont.sans(12))
         + Text("Partner").font(UFont.sans(12, .semibold)) + Text(" — either of you can start/complete & focus together. ").font(UFont.sans(12))
         + Text("Assign").font(UFont.sans(12, .semibold)) + Text(" — it becomes their task; you keep view.").font(UFont.sans(12)))
            .foregroundStyle(theme.palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
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
            if let date = effectiveDateNow(), let time = pickedTime {
                model.scheduleTaskAt(t, date: date, startTime: time)
            }
            ReminderScheduler.shared.resync()
        }

        // Apply the picked share levels now the row exists — fire-and-forget,
        // exactly how ShareSheet calls the RPCs (a failed share, e.g. offline,
        // must never block creation).
        let shares = shareLevels
        if !shares.isEmpty {
            let share = model.shareState
            let taskId = t.id
            Task {
                for (userId, level) in shares {
                    do {
                        try await share.shareTask(taskId: taskId, user: userId, level: level)
                        await share.notifyShare(taskId: taskId, recipientId: userId)
                    } catch {}
                }
            }
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
