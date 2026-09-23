// "What Unstuck knows" — every fact the assistant has learned, visible and
// deletable (iOS port of components/settings/facts-panel.tsx). Memory
// transparency is part of the same consent surface as the AI toggle
// (docs/ai-gateway-brainstorm.md): nothing is stored silently, and forgetting
// is immediate, everywhere (soft-delete tombstones sync through profile_facts).
//
// Settings → "What Unstuck knows". Lists each ACTIVE fact with its category
// chip + date (the date it refers to when set, else when it was last
// updated), edit-in-place, forget one, "Forget everything" (confirmed), an
// add row, and the four ritual toggles (which recurring moments run).

import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

struct FactsPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var facts: [ProfileFact] = []
    @State private var editing: ProfileFact?
    @State private var editText = ""
    @State private var draft = ""
    @State private var draftCategory: ProfileFactCategory = .context
    @State private var confirmForgetAll = false

    var body: some View {
        SettingsScaffold(eyebrow: "Settings · Memory", title: "What Unstuck knows about you.") {
            Text("The assistant’s memory — built from your answers and conversations. These facts are shared with our AI provider (which doesn’t train on them) so it can personalise your help. Delete anything; it forgets immediately, everywhere.")
                .font(UFont.sans(12.5)).foregroundStyle(theme.palette.ink3)
                .padding(.bottom, 12)

            SettingsCard {
                if facts.isEmpty {
                    Text("Nothing yet — it learns as you talk to it.")
                        .font(UFont.sans(13)).italic().foregroundStyle(theme.palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 16)
                } else {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { CardDivider() }
                        factRow(f)
                    }
                }
                CardDivider()
                addRow
            }

            if !facts.isEmpty {
                Button { confirmForgetAll = true } label: {
                    Text("Forget everything")
                        .font(UFont.sans(12.5, .medium)).foregroundStyle(theme.palette.red)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel("Forget everything the assistant has learned")
            }

            Text("Moments it runs for you")
                .font(UFont.sans(13.5, .semibold)).foregroundStyle(theme.palette.ink)
                .padding(.top, 18).padding(.bottom, 8)
            SettingsCard {
                ForEach(Array(RITUAL_LABELS.enumerated()), id: \.element.key) { i, r in
                    if i > 0 { CardDivider() }
                    RitualToggleRow(label: r.label, sub: r.sub,
                                    isOn: Binding(get: { model.paPrefs.rituals[r.key] },
                                                  set: { model.paPrefs.setRitual(r.key, on: $0) }))
                }
            }
            Text("Your tone is derived from these facts — tell it “keep me honest” or “gently” and it adapts. No separate dial.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .padding(.top, 10)
        }
        .navigationTitle("What Unstuck knows")
        .task { await observe() }
        .alert("Forget everything?", isPresented: $confirmForgetAll) {
            Button("Forget everything", role: .destructive) { model.profileFacts?.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forget everything the assistant has learned about you? This can’t be undone.")
        }
        .sheet(item: $editing) { f in
            FactEditSheet(fact: f) { text in
                guard text != f.fact else { return }
                // Edit = update IN PLACE (same id: one outbox op, and a moment
                // dismissed against this fact's id stays dismissed). The old
                // soft-remove + re-save minted a new id and re-fired those.
                // Falls back to a plain save only if the row vanished
                // underneath the sheet (forgotten on another device).
                if !model.updateProfileFact(id: f.id, fact: text, whenIso: f.whenIso) {
                    model.profileFacts?.save(category: f.category, fact: text, source: .settings, whenIso: f.whenIso)
                }
            }
        }
    }

    /// Live rows off the store — a forget / add / clear (or a sync from
    /// another device) re-renders the list without a manual refresh.
    private func observe() async {
        guard let service = model.profileFacts else { return }
        do {
            for try await list in service.observeAll() { facts = list.filter { $0.active } }
        } catch {}
    }

    private func factRow(_ f: ProfileFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(f.category.rawValue.uppercased())
                .font(UFont.mono(9.5, .semibold)).tracking(0.6)
                .foregroundStyle(theme.palette.coral)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 2)
            Button { editing = f; editText = f.fact } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.fact)
                        .font(UFont.sans(13.5)).foregroundStyle(theme.palette.ink)
                        .lineSpacing(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(FactDate.label(for: f))
                        .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Edit fact: \(f.fact)")
            Button { _ = model.profileFacts?.remove(id: f.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Forget \"\(f.fact)\"")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var addRow: some View {
        let can = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            Menu {
                ForEach(ProfileFactCategory.allCases, id: \.self) { c in
                    Button(c.rawValue.capitalized) { draftCategory = c }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(draftCategory.rawValue).font(UFont.sans(12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.palette.ink2)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Fact category")
            TextField("Add something it should know…", text: $draft)
                .font(UFont.sans(13.5)).foregroundStyle(theme.palette.ink)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(add)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button(action: add) {
                Text("Add").font(UFont.sans(12.5, .semibold))
                    .foregroundStyle(can ? .white : theme.palette.ink3)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(can ? theme.palette.coral : theme.palette.bg2,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plain).disabled(!can)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.profileFacts?.save(category: draftCategory, fact: t, source: .settings, whenIso: nil)
        draft = ""
    }
}

/// "for 12 Sept" (the date the fact is about) or "12 Sept" (last updated).
/// Internal for UnstuckAppTests.
enum FactDate {
    nonisolated(unsafe) private static let short: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"; return f
    }()
    nonisolated(unsafe) private static let withYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM yyyy"; return f
    }()

    static func label(for f: ProfileFact, now: Date = Date()) -> String {
        if let when = f.whenIso, let d = parseIsoDate(when) {
            let sameYear = Time.calendar.component(.year, from: d) == Time.calendar.component(.year, from: now)
            return "for " + (sameYear ? short : withYear).string(from: d)
        }
        if let ms = Time.parseMillis(f.updatedAt) {
            let d = Date(timeIntervalSince1970: ms / 1000)
            let sameYear = Time.calendar.component(.year, from: d) == Time.calendar.component(.year, from: now)
            return (sameYear ? short : withYear).string(from: d)
        }
        return ""
    }

    private static func parseIsoDate(_ s: String) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Time.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// Label + sub + switch — one ritual (Settings variant of the interview chips).
struct RitualToggleRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let sub: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
        }
        .tint(theme.palette.primary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Edit one fact's text (category + date stay). Save re-stores it.
private struct FactEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    let fact: ProfileFact
    let onSave: (String) -> Void
    @State private var value: String

    init(fact: ProfileFact, onSave: @escaping (String) -> Void) {
        self.fact = fact; self.onSave = onSave
        _value = State(initialValue: fact.fact)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Edit · \(fact.category.rawValue)")
            TextField("The fact", text: $value, axis: .vertical)
                .font(UFont.sans(16)).textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(12).background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            UButton("Save") { save() }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(260)])
    }

    private func save() {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSave(t); dismiss()
    }
}
