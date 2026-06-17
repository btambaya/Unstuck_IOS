// Collections — calm memory containers. 1:1 with the Android CollectionsScreen
// + CollectionDetailScreen + ShareCollectionSheet:
//  • Overview: shared AppBar, "Things you don't need to remember." serif title,
//    a search pill + "+ New", an Archived (N) toggle, and a 2-COLUMN grid of
//    cards (rounded color chip + SHARED badge + item count + first 2 items).
//  • Detail: colored chip + inline-rename title + archive/delete/share (owner)
//    or Leave (member), "shared with N" line, recolor swatches, Pinned/All item
//    rows (checkbox + body + ellipsis reveal: pin / move-to-task / remove +
//    accountability chips), add-item pill, move-to-task chooser + by-time picker.
//  • Share sheet: invite by email + role, live member/pending list.
// Reads via Repository<ItemCollection>; writes route through AppModel
// (own → outbox upsert, shared → atomic item RPCs).

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckSync

@MainActor
@Observable
final class CollectionsModel {
    var collections: [ItemCollection] = []
    private let repo: Repository<ItemCollection>
    init(_ repo: Repository<ItemCollection>) { self.repo = repo }
    func observe() async {
        do { for try await rows in repo.observeValues() { collections = rows } } catch {}
    }
}

private let COLLECTION_PALETTE = ["indigo", "coral", "green", "amber", "blue", "violet"]

/// Rounded-square color chip with a centered dot (1:1 with the Android
/// ColorChip the overview cards + detail title use).
private struct ColorChip: View {
    @Environment(\.uTheme) private var theme
    let token: String?
    var box: CGFloat = 26
    var dot: CGFloat = 8
    var body: some View {
        let color = theme.palette.areaColor(token)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color.opacity(0.22))
            .frame(width: box, height: box)
            .overlay(Circle().fill(color).frame(width: dot, height: dot))
    }
}

struct ListsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CollectionsModel?
    @State private var newName = ""
    @State private var newColor = "indigo"
    @State private var showNew = false
    @State private var query = ""
    @State private var showArchived = false
    @State private var showSettings = false
    @State private var showPalette = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                AppBar(title: "Collections", onSearch: { showPalette = true }, onAvatar: { showSettings = true })
                if let vm { content(vm) } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPalette) { CommandPalette() }
            .sheet(isPresented: $showNew) { newCollectionSheet }
            .feedbackBubble()
        }
        .task {
            guard vm == nil, let db = model.db else { return }
            let m = CollectionsModel(Repository<ItemCollection>(db, orderColumn: "sortOrder"))
            vm = m; await m.observe()
        }
    }

    private func shown(_ all: [ItemCollection]) -> [ItemCollection] {
        all.sorted { $0.sortOrder < $1.sortOrder }.filter {
            (($0.archived ?? false) == showArchived) &&
            (query.isEmpty
             || $0.name.localizedCaseInsensitiveContains(query)
             || $0.items.contains { $0.body.localizedCaseInsensitiveContains(query) })
        }
    }

    @ViewBuilder
    private func content(_ vm: CollectionsModel) -> some View {
        let archivedCount = vm.collections.filter { $0.archived ?? false }.count
        let list = shown(vm.collections)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Serif headline + subtitle.
                Text("Things you don't need to remember.")
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                    .padding(.top, 4)
                Text("A calm shelf. Nothing here is a task.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    .padding(.top, 8).padding(.bottom, 8)

                // Search pill + "+ New".
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.palette.ink3)
                        TextField("Search collections", text: $query)
                            .textFieldStyle(.plain).font(UFont.sans(13))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(theme.palette.bg2).clipShape(Capsule())
                    if !showArchived {
                        Button { showNew = true } label: {
                            Text("+ New").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(theme.palette.coral).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }

                // Archived filter toggle — only when there are archived lists (or while viewing them).
                if archivedCount > 0 || showArchived {
                    Button { showArchived.toggle() } label: {
                        Text(showArchived ? "← Back to active" : "Archived (\(archivedCount))")
                            .font(UFont.sans(12, .medium))
                            .foregroundStyle(showArchived ? theme.palette.amberInk : theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background((showArchived ? theme.palette.amberSoft : theme.palette.bg2))
                            .clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 10)
                }

                if list.isEmpty {
                    Text(showArchived ? "No archived lists." : "No lists yet. Tap + to start one.")
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        .frame(maxWidth: .infinity).padding(.top, 48)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(list) { col in
                            NavigationLink { CollectionDetailView(vm: vm, id: col.id) } label: { gridCard(col) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 96)   // clear the floating bottom nav
        }
    }

    private func gridCard(_ col: ItemCollection) -> some View {
        let shared = model.isShared(col)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ColorChip(token: col.color, box: 26, dot: 8)
                Spacer()
                HStack(spacing: 6) {
                    if shared {
                        Text("SHARED").font(UFont.sans(8, .bold)).foregroundStyle(theme.palette.primaryDeep)
                    }
                    Text("\(col.items.count)").font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
            }
            Text(col.name).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(col.items.prefix(2)) { item in
                    Text("· \(item.body)").font(UFont.sans(11)).foregroundStyle(theme.palette.ink2)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: 150, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line))
    }

    // New-collection bottom sheet — name + color swatch + dark Create button
    // (Android NewCollectionSheet parity; was a bare system alert with no color).
    private var newCollectionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("NEW COLLECTION").font(UFont.mono(11, .medium)).tracking(0.8)
                    .foregroundStyle(theme.palette.ink3)
                TextField("What would you like to remember?", text: $newName)
                    .textFieldStyle(.plain).font(UFont.sans(15))
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.palette.line2))
                    .submitLabel(.done).onSubmit { createCollection() }
                Text("COLOR").font(UFont.mono(11, .medium)).tracking(0.8)
                    .foregroundStyle(theme.palette.ink3)
                HStack(spacing: 10) {
                    ForEach(["indigo", "coral", "green", "amber", "blue", "violet"], id: \.self) { col in
                        Circle().fill(theme.palette.areaColor(col)).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(theme.palette.ink, lineWidth: newColor == col ? 2 : 0))
                            .onTapGesture { newColor = col }
                    }
                }
                UButton("Create", kind: .dark) { createCollection() }
                    .opacity(newName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                Spacer()
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNew = false; newName = ""; newColor = "indigo" }
                }
            }
        }
        .presentationDetents([.height(380)])
    }

    private func createCollection() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vm else { return }
        _ = model.addCollection(name: trimmed, color: newColor, existing: vm.collections)
        newName = ""; newColor = "indigo"; showNew = false
    }
}

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let vm: CollectionsModel
    let id: String

    @State private var draft = ""
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var revealedId: String?
    @State private var confirmDelete = false
    @State private var showShare = false
    @State private var promoteTarget: CollectionItem?
    @State private var byTimeTarget: CollectionItem?

    private var collection: ItemCollection? { vm.collections.first { $0.id == id } }

    var body: some View {
        Group {
            if let col = collection {
                detail(col)
            } else {
                Color.clear.onAppear { dismiss() }   // gone (deleted / lost access) → pop
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)   // keep the standard back button (overview hides its bar)
        .sheet(isPresented: $showShare) {
            if let col = collection { CollectionShareView(collectionId: col.id, collectionName: col.name) }
        }
        .sheet(item: $byTimeTarget) { item in
            if let col = collection {
                ByTimePicker { iso in model.moveItemToTask(col, item: item, mode: .loop, dueAtIso: iso) }
            }
        }
        .confirmationDialog("Move to task", isPresented: Binding(get: { promoteTarget != nil }, set: { if !$0 { promoteTarget = nil } }), titleVisibility: .visible) {
            if let col = collection, let target = promoteTarget {
                Button("Keep everyone in the loop") { promoteTarget = nil; byTimeTarget = target }
                Button("Just me") { promoteTarget = nil; model.moveItemToTask(col, item: target, mode: .selfOnly) }
                Button("Cancel", role: .cancel) { promoteTarget = nil }
            }
        } message: {
            Text("“\(promoteTarget?.body ?? "")” becomes a task in your list. Keep everyone in the loop and the others can see when it's done — you'll pick a “by” time.")
        }
        .alert("Delete \"\(collection?.name ?? "")\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteCollection(id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This collection and its \(collection?.items.count ?? 0) item(s) are removed.")
        }
    }

    @ViewBuilder
    private func detail(_ col: ItemCollection) -> some View {
        let owner = model.isOwner(col)
        let canEdit = model.canEdit(col)
        let shared = model.isShared(col)
        let archived = col.archived ?? false
        let pinned = col.items.filter { $0.pinned == true }
        let rest = col.items.filter { $0.pinned != true }

        VStack(alignment: .leading, spacing: 0) {
            // Pinned header — colored chip + inline-rename title + share/leave +
            // shared-with line. Stays put while the items below scroll.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    ColorChip(token: col.color, box: 30, dot: 9)
                    if editingTitle && owner {
                        TextField("Name", text: $titleDraft)
                            .font(UFont.serifItalic(26)).textFieldStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.renameCollection(col, name: titleDraft); editingTitle = false } label: {
                            Image(systemName: "checkmark").font(.system(size: 18)).foregroundStyle(theme.palette.green).padding(4)
                        }.buttonStyle(.plain)
                    } else {
                        Text(col.name).font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { if owner { titleDraft = col.name; editingTitle = true } }
                        if owner {
                            HStack(spacing: 4) {
                                Button { model.archiveCollection(col.id, archived: !archived); dismiss() } label: {
                                    Image(systemName: archived ? "tray.and.arrow.up" : "archivebox")
                                        .font(.system(size: 21)).foregroundStyle(theme.palette.ink3).padding(1)
                                }.buttonStyle(.plain)
                                Button { confirmDelete = true } label: {
                                    Image(systemName: "trash").font(.system(size: 21)).foregroundStyle(theme.palette.ink3).padding(1)
                                }.buttonStyle(.plain)
                                Button { showShare = true } label: {
                                    Image(systemName: "square.and.arrow.up").font(.system(size: 22)).foregroundStyle(theme.palette.ink2)
                                }.buttonStyle(.plain)
                            }
                        } else {
                            Button { model.leaveCollection(col.id); dismiss() } label: {
                                Text("Leave").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink3)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if shared {
                    Text(owner ? "Shared with \(col.members?.count ?? 0)"
                         : (canEdit ? "Shared with you · you can edit" : "Shared with you · view only"))
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                        .padding(.top, 8).padding(.leading, 2)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(theme.palette.bg)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Recolor swatches — owner only.
                    if owner {
                        HStack(spacing: 8) {
                            ForEach(COLLECTION_PALETTE, id: \.self) { token in
                                Circle().fill(theme.palette.areaColor(token)).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(theme.palette.ink, lineWidth: col.color == token ? 2 : 0))
                                    .onTapGesture { model.recolorCollection(col, color: token) }
                            }
                        }.padding(.top, 12)
                    }

                    if col.items.isEmpty {
                        VStack(spacing: 8) {
                            Text("Keep small things here.").font(UFont.serifItalic(19)).foregroundStyle(theme.palette.ink2)
                            Text("Type below. Hit return. Done.").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 38).padding(.horizontal, 20)
                        .background(theme.palette.bg2).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line2))
                        .padding(.top, 24)
                    } else {
                        if !pinned.isEmpty {
                            SectionLabel("Pinned").padding(.leading, 4).padding(.top, 20).padding(.bottom, 6)
                            ForEach(pinned) { item in itemRow(col, item, canEdit: canEdit) }
                        }
                        if !rest.isEmpty {
                            SectionLabel("All").padding(.leading, 4).padding(.top, 14).padding(.bottom, 6)
                            ForEach(rest) { item in itemRow(col, item, canEdit: canEdit) }
                        }
                    }

                    // Add-item pill — at the BOTTOM so new items append right above it.
                    // Hidden for view-only members.
                    if canEdit {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").foregroundStyle(theme.palette.ink3)
                            TextField("Add to this collection…", text: $draft)
                                .textFieldStyle(.plain).font(UFont.sans(15))
                                .onSubmit(add)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(theme.palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(theme.palette.line2))
                        .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 96)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ col: ItemCollection, _ item: CollectionItem, canEdit: Bool) -> some View {
        CollItemRow(
            col: col, item: item, readOnly: !canEdit,
            revealed: revealedId == item.id,
            onReveal: { revealedId = revealedId == item.id ? nil : item.id },
            onMoveToTask: { startPromote(col, item) })
    }

    private func startPromote(_ col: ItemCollection, _ item: CollectionItem) {
        revealedId = nil
        if model.isShared(col) { promoteTarget = item }
        else { model.moveItemToTask(col, item: item, mode: .selfOnly) }
    }

    private func add() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let col = collection else { return }
        model.addCollectionItem(col, body: body)
        draft = ""
    }
}

private struct CollItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let col: ItemCollection
    let item: CollectionItem
    let readOnly: Bool
    let revealed: Bool
    let onReveal: () -> Void
    let onMoveToTask: () -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let done = item.done == true
        let promoted = item.promoted == true
        let struck = done || promoted        // promoted items read as "handled / in flight"

        HStack(spacing: 10) {
            // Done checkbox (always visible).
            Button { if !readOnly { model.toggleCollectionItemDone(col, itemId: item.id) } } label: {
                ZStack {
                    Circle().fill(done ? theme.palette.coral : theme.palette.surface).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(theme.palette.line2, lineWidth: done ? 0 : 1.5))
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                }
            }.buttonStyle(.plain).disabled(readOnly)

            VStack(alignment: .leading, spacing: 2) {
                if editing && !readOnly {
                    HStack {
                        TextField("Item", text: $draft).textFieldStyle(.plain).font(UFont.sans(14))
                        Button { model.updateCollectionItemBody(col, itemId: item.id, body: draft); editing = false } label: {
                            Image(systemName: "checkmark").font(.system(size: 16)).foregroundStyle(theme.palette.green).padding(2)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Text(item.body).font(UFont.sans(14))
                        .strikethrough(struck)
                        .foregroundStyle(struck ? theme.palette.ink3 : theme.palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if !readOnly { if revealed { onReveal() } else { draft = item.body; editing = true } } }
                }
                if promoted, let label = promotedLabel() {
                    Text(label).font(UFont.sans(11, .medium)).foregroundStyle(promotedColor())
                        .padding(.top, 2)
                }
            }

            if !readOnly && !revealed {
                Button { onReveal() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(theme.palette.ink4)
                }.buttonStyle(.plain)
            }

            // Action bar — hidden by default, revealed on tap of the ellipsis.
            if !readOnly && revealed {
                HStack(spacing: 8) {
                    Button { model.toggleCollectionItemPin(col, itemId: item.id) } label: {
                        Image(systemName: "pin\(item.pinned == true ? ".fill" : "")")
                            .font(.system(size: 19))
                            .foregroundStyle(item.pinned == true ? theme.palette.coral : theme.palette.ink4)
                    }.buttonStyle(.plain)
                    // Hide Move-to-task while a promotion is in flight (avoids a duplicate task).
                    if !(item.promoted == true) || item.promotedDone == true {
                        Button { onMoveToTask() } label: {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 19)).foregroundStyle(theme.palette.ink4)
                        }.buttonStyle(.plain)
                    }
                    Button { model.removeCollectionItem(col, itemId: item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 19)).foregroundStyle(theme.palette.ink4)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line))
        .padding(.vertical, 3)
    }

    private func promotedLabel() -> String? {
        let promotedDone = item.promotedDone == true
        let dueDate = item.dueAt.flatMap(parseISO)
        let overdue = !promotedDone && (dueDate.map { $0 < Date() } ?? false)
        if promotedDone { return "done by \(item.assignee ?? "someone") ✓" }
        if overdue { return "⚠ overdue · due \(fmtTime(item.dueAt))" }
        if let a = item.assignee, dueDate != nil { return "\(a)'s on it · by \(fmtTime(item.dueAt))" }
        if let a = item.assignee { return "\(a)'s on it" }
        return "Promoted"
    }
    private func promotedColor() -> Color {
        let promotedDone = item.promotedDone == true
        let dueDate = item.dueAt.flatMap(parseISO)
        let overdue = !promotedDone && (dueDate.map { $0 < Date() } ?? false)
        if overdue { return theme.palette.red }
        if promotedDone { return theme.palette.greenInk }
        return theme.palette.primaryDeep
    }
}

/// Pick a "by" time → builds an ISO instant (a chosen time earlier than now
/// rolls to tomorrow so the task isn't born already-overdue).
private struct ByTimePicker: View {
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("When should it be done?").font(UFont.sans(15)).foregroundStyle(theme.palette.ink2)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                UButton("Set the “by” time") {
                    onPick(Self.iso(from: time)); dismiss()
                }
                Spacer()
            }
            .padding(20)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Keep everyone in the loop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    static func iso(from time: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: time)
        var target = cal.date(bySettingHour: comps.hour ?? 9, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
        if target < Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: target)
    }
}

// MARK: - share sheet

struct CollectionShareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let collectionId: String
    let collectionName: String

    init(collectionId: String, collectionName: String) {
        self.collectionId = collectionId; self.collectionName = collectionName
    }

    @State private var email = ""
    @State private var role = "editor"
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @State private var members: [CollectionMemberInfo] = []
    @State private var loading = true
    @State private var reportTarget: CollectionMemberInfo?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Share · \(collectionName)")
                    Text("Invite anyone by email. If they don't have an Unstuck account yet, they'll get access the moment they sign up. Changes sync live between you.")
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)

                    TextField("partner@email.com", text: $email)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress).autocorrectionDisabled()
                        .onSubmit(submit)

                    HStack(spacing: 8) {
                        ForEach([("editor", "Can edit"), ("viewer", "Can view")], id: \.0) { value, label in
                            Button { role = value } label: {
                                Text(label).font(UFont.sans(12, .semibold))
                                    .foregroundStyle(role == value ? theme.palette.bg : theme.palette.ink2)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(role == value ? theme.palette.ink : theme.palette.bg2)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(theme.palette.line2))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Button { submit() } label: {
                            Text(busy ? "Sharing…" : "Share").font(UFont.sans(14, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(theme.palette.ink).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }.buttonStyle(.plain).disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let m = message {
                        Text(m.text).font(UFont.sans(13)).foregroundStyle(m.ok ? theme.palette.greenInk : theme.palette.coralDeep)
                    }

                    SectionLabel(memberSummary)
                    if loading {
                        Text("Loading…").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    } else {
                        ForEach(members) { m in memberRow(m) }
                    }
                }
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Share").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await refresh() }
        .confirmationDialog("Report this person?", isPresented: Binding(
            get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } }),
            titleVisibility: .visible, presenting: reportTarget) { m in
            ForEach(["Objectionable content", "Spam", "Harassment", "Other"], id: \.self) { reason in
                Button(reason) {
                    Task { await model.reportConcern(collectionId: collectionId, about: m.email, reason: reason) }
                    reportTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { reportTarget = nil }
        } message: { m in
            Text("Send a report about \(m.email) to the Unstuck team. We review reports and take action.")
        }
    }

    private var memberSummary: String {
        let accepted = members.filter { !$0.pending }.count
        let invited = members.filter { $0.pending }.count
        if accepted > 0 { return "Shared with \(accepted)" + (invited > 0 ? " · \(invited) invited" : "") }
        if invited > 0 { return "\(invited) invited" }
        return "Not shared yet"
    }

    private func memberRow(_ m: CollectionMemberInfo) -> some View {
        HStack(spacing: 8) {
            Text(m.email).font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if m.pending { Text("PENDING").font(UFont.sans(9, .bold)).foregroundStyle(theme.palette.amberInk) }
            Text(m.role == "viewer" ? "VIEW" : "EDIT").font(UFont.sans(10, .bold)).foregroundStyle(theme.palette.ink3)
            // Safety actions (App Store 1.2): report or block a collaborator,
            // plus remove them from this list.
            Menu {
                Button { remove(m) } label: { Label("Remove from list", systemImage: "xmark") }
                Button { reportTarget = m } label: { Label("Report…", systemImage: "flag") }
                Button(role: .destructive) {
                    model.blockUser(email: m.email, inCollection: collectionId, userId: m.userId)
                    members.removeAll { $0.id == m.id }
                } label: { Label("Block \(m.email)", systemImage: "hand.raised") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(theme.palette.ink3).padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.palette.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func refresh() async {
        members = await model.listCollectionMembers(collectionId)
        loading = false
    }

    private func submit() {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !busy else { return }
        guard !model.isBlocked(e) else {
            message = (false, "You've blocked that person."); return
        }
        busy = true; message = nil
        Task {
            let outcome = await model.shareCollection(collectionId, email: e, role: role)
            busy = false
            switch outcome {
            case .ok: email = ""; message = (true, "Shared with \(e) (\(role == "viewer" ? "can view" : "can edit"))."); await refresh()
            case .invited: email = ""; message = (true, "Invited \(e) — they'll get access when they sign up."); await refresh()
            case .selfError: message = (false, "That's you.")
            case .notFound: message = (false, "No Unstuck account for that email yet.")
            case .error: message = (false, "Could not share. Try again.")
            }
        }
    }

    private func remove(_ m: CollectionMemberInfo) {
        members.removeAll { $0.id == m.id }   // optimistic
        Task {
            if m.pending { await model.cancelCollectionInvite(collectionId, email: m.email) }
            else { await model.unshareCollection(collectionId, userId: m.userId) }
            await refresh()
        }
    }
}

// MARK: - ISO helpers

private func parseISO(_ iso: String) -> Date? {
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: iso) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: iso)
}

private func fmtTime(_ iso: String?) -> String {
    guard let iso, let date = parseISO(iso) else { return "" }
    let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "h:mm a"
    return df.string(from: date)
}
