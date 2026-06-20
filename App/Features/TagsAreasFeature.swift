// Settings → Areas & tags. 1:1 with the Android AreasContent + TagsContent:
// each row shows a tappable color chip (opens a palette to RECOLOR), inline
// RENAME, a per-row menu (Rename / Delete) with a delete-confirm, and a live
// count — "<n> open" for areas (open, non-recurring tasks in that area) and a
// usage count for tags (tasks whose `tags` contain the name). Add rejects
// case-insensitive duplicates, and picks color = first-unused token +
// sortOrder = max+1. Recolor/rename re-upsert the existing row (preserving id +
// sortOrder) via the AppModel full-upsert (saveTag / saveLifeArea) — no new
// AppModel methods. Tasks/areas are observed from the same tracked GRDB
// snapshot the list uses, so a rename/recolor/count refreshes immediately.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

/// The color tokens `Palette.areaColor` actually resolves (teal would fall
/// through to gray on iOS, so it's omitted vs. Android's list). Used both for
/// the recolor palette and the "first unused" pick on Add.
private let areaPalette = ["indigo", "coral", "green", "amber", "blue", "violet", "red"]

@MainActor
@Observable
final class TagsAreasModel {
    var tags: [TagRow] = []
    var areas: [LifeArea] = []
    var tasks: [TaskItem] = []
    private let tagRepo: Repository<TagRow>
    private let areaRepo: Repository<LifeArea>
    private let taskRepo: TaskRepository
    init(_ tagRepo: Repository<TagRow>, _ areaRepo: Repository<LifeArea>, _ taskRepo: TaskRepository) {
        self.tagRepo = tagRepo; self.areaRepo = areaRepo; self.taskRepo = taskRepo
    }
    func observe() async {
        async let a: Void = observeTags()
        async let b: Void = observeAreas()
        async let c: Void = observeTasks()
        _ = await (a, b, c)
    }
    private func observeTags() async {
        do { for try await r in tagRepo.observeValues() { tags = r } } catch {}
    }
    private func observeAreas() async {
        do { for try await r in areaRepo.observeValues() { areas = r } } catch {}
    }
    // Counts come off the same tracked snapshot the list watches, so completing
    // a task or applying a tag re-renders the "<n> open" / usage numbers live.
    private func observeTasks() async {
        do { for try await snap in taskRepo.observeTasksAndBlocks() { tasks = snap.tasks } } catch {}
    }

    /// Open, non-recurring tasks filed under this area (Android: tasks where
    /// lifeArea == name && !done && recurrence == nil).
    func openCount(_ area: LifeArea) -> Int {
        tasks.filter { $0.lifeArea == area.name && !$0.done && $0.recurrence == nil }.count
    }
    /// Tasks whose tag list contains this tag name (Android usage count).
    func usageCount(_ tag: TagRow) -> Int {
        tasks.filter { ($0.tags ?? []).contains(tag.name) }.count
    }
}

struct TagsAreasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TagsAreasModel?

    var body: some View {
        Group {
            if let vm { content(vm) } else { ProgressView() }
        }
        .navigationTitle("Areas & tags")
        .navigationBarTitleDisplayMode(.inline)
        .background(theme.palette.bg.ignoresSafeArea())
        .task {
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = TagsAreasModel(Repository<TagRow>(db, orderColumn: "sortOrder"),
                                   Repository<LifeArea>(db, orderColumn: "sortOrder"),
                                   taskRepo)
            vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func content(_ vm: TagsAreasModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AreasSection(vm: vm)
                TagsSection(vm: vm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .background(theme.palette.bg.ignoresSafeArea())
    }
}

// MARK: - Areas

private struct AreasSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: TagsAreasModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Settings · Areas").foregroundStyle(theme.palette.primaryDeep)
            Text("One list. The whole life.")
                .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
            Text("Areas filter the same list — flat on purpose.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .padding(.bottom, 6)

            ForEach(vm.areas.sorted { $0.sortOrder < $1.sortOrder }) { area in
                AreaRow(area: area, open: vm.openCount(area))
            }

            AddRow(placeholder: "New area", draft: $draft, onAdd: add)
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject blank + case-insensitive duplicates (areas key tasks by name
        // string → two same-named areas make filtering ambiguous). Keep the
        // draft on a dup so the typed text isn't lost.
        guard !name.isEmpty,
              !vm.areas.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        // first-unused color + sortOrder = max+1 (anti-collision after a delete
        // shrank the list), mirroring Android.
        let color = areaPalette.first { tok in !vm.areas.contains { $0.color == tok } }
            ?? areaPalette[vm.areas.count % areaPalette.count]
        let order = (vm.areas.map(\.sortOrder).max() ?? -1) + 1
        model.saveLifeArea(LifeArea(id: newUUID(), name: name, color: color, sortOrder: order))
        draft = ""
    }
}

private struct AreaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let area: LifeArea
    let open: Int

    @State private var editing = false
    @State private var nameDraft = ""
    @State private var showPalette = false
    @State private var showDelete = false
    @SwiftUI.FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 11) {
            // Tappable color chip → recolor palette.
            Button { showPalette = true } label: {
                ColorChip(token: area.color, box: 30, dot: 9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Color")
            .accessibilityValue(area.color.capitalized)
            .popover(isPresented: $showPalette) {
                PalettePicker { tok in
                    // Recolor = re-upsert preserving id + sortOrder + name.
                    model.saveLifeArea(LifeArea(id: area.id, name: area.name, color: tok, sortOrder: area.sortOrder))
                    showPalette = false
                }
            }

            if editing {
                TextField("Area name", text: $nameDraft)
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(commitRename)
                    // Re-sync from the live name when not focused so a concurrent
                    // rename isn't clobbered by a stale once-seeded draft.
                    .onChange(of: area.name) { _, new in if !nameFocused { nameDraft = new } }
                Button(action: commitRename) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.green)
                }.buttonStyle(.plain)
                Button { nameDraft = area.name; editing = false; nameFocused = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(area.name).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    Text("\(open) open").font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
                Spacer()
                Menu {
                    Button("Rename") { nameDraft = area.name; editing = true; nameFocused = true }
                    Button("Delete area", role: .destructive) { showDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .alert("Delete \u{201C}\(area.name)\u{201D}?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteLifeArea(area.id) }
        } message: {
            Text("Tasks keep their data — they just lose this area label.")
        }
    }

    private func commitRename() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false; nameFocused = false
        guard !name.isEmpty else { nameDraft = area.name; return }
        // Rename = re-upsert preserving id + sortOrder + color.
        model.saveLifeArea(LifeArea(id: area.id, name: name, color: area.color, sortOrder: area.sortOrder))
    }
}

// MARK: - Tags

private struct TagsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: TagsAreasModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Settings · Tags").foregroundStyle(theme.palette.primaryDeep)
            Text("Your tag vocabulary.")
                .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
            Text("Tags cut across areas — apply as many as you like.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .padding(.bottom, 6)

            ForEach(vm.tags.sorted { $0.sortOrder < $1.sortOrder }) { tag in
                TagRowView(tag: tag, uses: vm.usageCount(tag))
            }

            AddRow(placeholder: "New tag", draft: $draft, onAdd: add)
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject blank + case-insensitive dup; keep the draft on a dup so the
        // typed text isn't lost (Android parity).
        guard !name.isEmpty,
              !vm.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        let color = areaPalette.first { tok in !vm.tags.contains { $0.color == tok } }
            ?? areaPalette[vm.tags.count % areaPalette.count]
        let order = (vm.tags.map(\.sortOrder).max() ?? -1) + 1
        model.saveTag(TagRow(id: newUUID(), name: name, color: color, sortOrder: order))
        draft = ""
    }
}

private struct TagRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let tag: TagRow
    let uses: Int

    @State private var editing = false
    @State private var nameDraft = ""
    @State private var showPalette = false
    @State private var showDelete = false
    @SwiftUI.FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 11) {
            Button { showPalette = true } label: {
                ColorChip(token: tag.color, box: 26, dot: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Color")
            .accessibilityValue((tag.color ?? "default").capitalized)
            .popover(isPresented: $showPalette) {
                PalettePicker { tok in
                    model.saveTag(TagRow(id: tag.id, name: tag.name, color: tok, sortOrder: tag.sortOrder))
                    showPalette = false
                }
            }

            if editing {
                TextField("Tag name", text: $nameDraft)
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(commitRename)
                    // Re-sync from the live name when not focused so a concurrent
                    // rename isn't clobbered by a stale once-seeded draft.
                    .onChange(of: tag.name) { _, new in if !nameFocused { nameDraft = new } }
                Button(action: commitRename) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.green)
                }.buttonStyle(.plain)
                Button { nameDraft = tag.name; editing = false; nameFocused = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
            } else {
                Text("#\(tag.name)")
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .onTapGesture { nameDraft = tag.name; editing = true; nameFocused = true }
                Spacer()
                Text("\(uses)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                Menu {
                    Button("Rename") { nameDraft = tag.name; editing = true; nameFocused = true }
                    Button("Delete", role: .destructive) { showDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .alert("Delete #\(tag.name)?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteTag(tag.id) }
        } message: {
            Text("It's removed from every task that uses it. This can't be undone.")
        }
    }

    private func commitRename() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false; nameFocused = false
        guard !name.isEmpty else { nameDraft = tag.name; return }
        model.saveTag(TagRow(id: tag.id, name: name, color: tag.color, sortOrder: tag.sortOrder))
    }
}

// MARK: - Shared building blocks

/// A bordered square holding a centered color dot — the iOS analog of Android's
/// `ColorChip(box:, dot:)`.
private struct ColorChip: View {
    @Environment(\.uTheme) private var theme
    let token: String?
    let box: CGFloat
    let dot: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.palette.bg2)
            .frame(width: box, height: box)
            .overlay(Circle().fill(theme.palette.areaColor(token)).frame(width: dot, height: dot))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }
}

/// The recolor popover — one row of tappable swatches.
private struct PalettePicker: View {
    @Environment(\.uTheme) private var theme
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(areaPalette, id: \.self) { tok in
                Button { onPick(tok) } label: {
                    ColorChip(token: tok, box: 30, dot: 11)
                }.buttonStyle(.plain)
                    .accessibilityLabel(tok.capitalized)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(14)
        .presentationCompactAdaptation(.popover)
    }
}

/// The "+ New …" input row: a bordered text field + a dark Add button.
private struct AddRow: View {
    @Environment(\.uTheme) private var theme
    let placeholder: String
    @Binding var draft: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(onAdd)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line2, lineWidth: 1))
            Button(action: onAdd) {
                Text("Add")
                    .font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.bg)
                    .padding(.vertical, 10).padding(.horizontal, 18)
                    .background(theme.palette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.top, 4)
    }
}
