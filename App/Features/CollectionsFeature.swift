// Collections ("Lists") — calm memory containers. 1:1 with the Android
// CollectionsScreen + CollectionDetailScreen + ShareCollectionSheet:
//  • Overview grid with search, a SHARED badge, and an Archived (N) filter.
//  • Detail: inline rename, recolor swatches, archive/delete (owner), Leave
//    (member), per-item done/pin/remove + inline edit, and move-to-task with
//    the "just me / keep everyone in the loop" accountability chooser.
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

struct ListsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CollectionsModel?
    @State private var newName = ""
    @State private var showNew = false
    @State private var query = ""
    @State private var showArchived = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm { content(vm) } else { ProgressView() }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Lists")
            .alert("New list", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Add") { addCollection() }
                Button("Cancel", role: .cancel) { newName = "" }
            }
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Things you don't need to remember.")
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                Text("A calm shelf. Nothing here is a task.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.palette.ink3)
                        TextField("Search collections", text: $query)
                            .textFieldStyle(.plain).font(UFont.sans(13))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.palette.bg2).clipShape(Capsule())
                    if !showArchived {
                        Button { showNew = true } label: {
                            Text("+ New").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(theme.palette.coral).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }

                if archivedCount > 0 || showArchived {
                    Button { showArchived.toggle() } label: {
                        Text(showArchived ? "← Back to active" : "Archived (\(archivedCount))")
                            .font(UFont.sans(12, .medium))
                            .foregroundStyle(showArchived ? theme.palette.amber : theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background((showArchived ? theme.palette.amber.opacity(0.18) : theme.palette.bg2))
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }

                if list.isEmpty {
                    Text(showArchived ? "No archived lists." : "No lists yet. Tap + New to start one.")
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(list) { col in
                            NavigationLink { CollectionDetailView(vm: vm, id: col.id) } label: { gridCard(col) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func gridCard(_ col: ItemCollection) -> some View {
        let shared = model.isShared(col)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                AreaDot(col.color, size: 10)
                Spacer()
                if shared {
                    Text("SHARED").font(UFont.sans(8, .bold)).foregroundStyle(theme.palette.primaryDeep)
                }
                Text("\(col.items.count)").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
            }
            Text(col.name).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(col.items.prefix(2)) { item in
                    Text("· \(item.body)").font(UFont.sans(11)).foregroundStyle(theme.palette.ink2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: 150, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line))
    }

    private func addCollection() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty, let vm else { return }
        _ = model.addCollection(name: trimmed, existing: vm.collections)
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
            // Pinned header — title + share/leave + shared-with line.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 11) {
                    AreaDot(col.color, size: 11)
                    if editingTitle && owner {
                        TextField("Name", text: $titleDraft)
                            .font(UFont.serifItalic(24)).textFieldStyle(.plain)
                        Button { model.renameCollection(col, name: titleDraft); editingTitle = false } label: {
                            Image(systemName: "checkmark").foregroundStyle(theme.palette.green)
                        }.buttonStyle(.plain)
                    } else {
                        Text(col.name).font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { if owner { titleDraft = col.name; editingTitle = true } }
                        if owner {
                            HStack(spacing: 10) {
                                Button { model.archiveCollection(col.id, archived: !archived); dismiss() } label: {
                                    Image(systemName: archived ? "tray.and.arrow.up" : "archivebox").foregroundStyle(theme.palette.ink3)
                                }.buttonStyle(.plain)
                                Button { confirmDelete = true } label: {
                                    Image(systemName: "trash").foregroundStyle(theme.palette.ink3)
                                }.buttonStyle(.plain)
                                Button { showShare = true } label: {
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(theme.palette.ink2)
                                }.buttonStyle(.plain)
                            }.font(.system(size: 17))
                        } else {
                            Button { model.leaveCollection(col.id); dismiss() } label: {
                                Text("Leave").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink3)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if shared {
                    Text(owner ? "Shared with \(col.members?.count ?? 0)"
                         : (canEdit ? "Shared with you · you can edit" : "Shared with you · view only"))
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if owner {
                        HStack(spacing: 8) {
                            ForEach(COLLECTION_PALETTE, id: \.self) { token in
                                Circle().fill(theme.palette.areaColor(token)).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(theme.palette.ink, lineWidth: col.color == token ? 2 : 0))
                                    .onTapGesture { model.recolorCollection(col, color: token) }
                            }
                        }.padding(.top, 12).padding(.bottom, 4)
                    }

                    if col.items.isEmpty {
                        VStack(spacing: 8) {
                            Text("Keep small things here.").font(UFont.serifItalic(19)).foregroundStyle(theme.palette.ink2)
                            Text("Type below. Hit return. Done.").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 38)
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
                .padding(.horizontal, 18).padding(.bottom, 30)
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
        let struck = done || promoted

        HStack(spacing: 10) {
            // Done checkbox
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
                            Image(systemName: "checkmark").foregroundStyle(theme.palette.green)
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
                }
            }

            if !readOnly {
                Button { onReveal() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(theme.palette.ink4)
                }.buttonStyle(.plain)
            }

            if !readOnly && revealed {
                HStack(spacing: 8) {
                    Button { model.toggleCollectionItemPin(col, itemId: item.id) } label: {
                        Image(systemName: "pin\(item.pinned == true ? ".fill" : "")")
                            .foregroundStyle(item.pinned == true ? theme.palette.coral : theme.palette.ink4)
                    }.buttonStyle(.plain)
                    if !(item.promoted == true) || item.promotedDone == true {
                        Button { onMoveToTask() } label: {
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(theme.palette.ink4)
                        }.buttonStyle(.plain)
                    }
                    Button { model.removeCollectionItem(col, itemId: item.id) } label: {
                        Image(systemName: "xmark").foregroundStyle(theme.palette.ink4)
                    }.buttonStyle(.plain)
                }.font(.system(size: 15))
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
        if promotedDone { return theme.palette.green }
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
                        Text(m.text).font(UFont.sans(13)).foregroundStyle(m.ok ? theme.palette.green : theme.palette.coralDeep)
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
            if m.pending { Text("PENDING").font(UFont.sans(9, .bold)).foregroundStyle(theme.palette.amber) }
            Text(m.role == "viewer" ? "VIEW" : "EDIT").font(UFont.sans(10, .bold)).foregroundStyle(theme.palette.ink3)
            Button { remove(m) } label: { Image(systemName: "xmark").foregroundStyle(theme.palette.ink3) }
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
