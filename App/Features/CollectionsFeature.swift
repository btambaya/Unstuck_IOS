// Collections — calm memory containers. 1:1 with the Android CollectionsScreen
// + CollectionDetailScreen + ShareCollectionSheet:
//  • Overview: shared AppBar, "Things you don't need to remember." serif title,
//    a search pill + "+ New", an Archived (N) toggle, and a 2-COLUMN grid of
//    cards (rounded color chip + SHARED badge + item count + first 2 items).
//  • Detail: colored chip + inline-rename title + archive/delete/share (owner)
//    or Leave (member), "shared with N" line, recolor swatches, Pinned/All item
//    rows (tap = strike out, swipe left = Delete, swipe right = Pin / Move to
//    task, hold = edit; + accountability chips), add-item pill, move-to-task
//    chooser + by-time picker.
//  • Sharing: the ONE ShareScreen (ShareScreen.swift) — from the detail's
//    Share button and the card's "Share…" context menu (owner only).
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
    /// The card whose "Share…" context action opened the Share screen.
    @State private var shareTarget: ShareTarget?
    /// The tab's navigation path — the collection ids pushed on top of the grid
    /// (a card tap, or a `unstuck://collections/<id>` deep link). NavigationStack
    /// owns this binding and rewrites it on every push and pop, the Back button,
    /// swipe-back and a destination's own `dismiss()` included, so `path.last`
    /// IS what's on screen. That's what `surface` reports to the router, which
    /// is why the bottom-bar + can't keep pointing at a collection that has
    /// already been popped.
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                AppBar(title: "Collections", onSearch: { showPalette = true }, onAvatar: { showSettings = true })
                if let vm { content(vm) } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(for: String.self) { id in
                if let vm { CollectionDetailView(vm: vm, id: id) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPalette) { CommandPalette() }
            .sheet(isPresented: $showNew) { newCollectionSheet }
            .sheet(item: $shareTarget) { target in ShareScreen(target: target) }
            .assistantLauncher()
        }
        // Consume a deep-linked collection id (push tap on a shared list).
        .onChange(of: model.router.openCollectionId, initial: true) { _, _ in consumeOpenCollection() }
        .onChange(of: vm?.collections.count ?? -1) { _, _ in consumeOpenCollection() }
        // Tell the scaffold what the + is looking at. Republished from `surface`
        // — derived from the nav path and the live rows — on EVERY update that
        // changes it, so a push, a pop, a rights downgrade and a deleted row all
        // land without any one lifecycle callback having to fire. (`tab`'s
        // setter clears it on the way out of the tab, for the case where this
        // view is gone and can't republish anything.)
        .onChange(of: surface, initial: true) { _, s in model.router.collectionsSurface = s }
        // The bottom-bar + resolved to "New collection" — the sheet is this
        // view's @State, so the scaffold can only ask (AppRouter.fabAction).
        .onChange(of: model.router.collectionFabRequest) { _, req in consumeFabRequest(req) }
        // A shared-list edit the server refused: the outbox dropped it and the
        // row was rolled back to the server's copy — say so once (never a
        // silent vanish on the next echo).
        .alert("Change undone", isPresented: Binding(
            get: { model.collectionSyncError != nil },
            set: { if !$0 { model.collectionSyncError = nil } })) {
            Button("OK", role: .cancel) { model.collectionSyncError = nil }
        } message: {
            Text(model.collectionSyncError ?? "")
        }
        // The guided tour is about to navigate — close the locally-presented
        // sheets (they live on this view's @State, out of the router's reach).
        .onReceive(NotificationCenter.default.publisher(for: .unstuckTourWillNavigate)) { _ in
            showSettings = false; showPalette = false; showNew = false
        }
        // Keyed on "is the store up yet" so this RE-RUNS when it comes up. The
        // plain `.task` this replaces bailed for good on a boot that reached
        // this tab before `AppModel.start()` had the database: the shelf stayed
        // a ProgressView forever and the + offered a New collection whose
        // Create could never write. Nothing else retried it.
        .task(id: model.db != nil) {
            guard vm == nil, let db = model.db else { return }
            let m = CollectionsModel(Repository<ItemCollection>(db, orderColumn: "sortOrder"))
            vm = m; await m.observe()
        }
    }

    /// What this tab is showing, for the bottom-bar + (`AppRouter.fabAction`).
    /// Entirely DERIVED — nothing here is a flag some callback has to remember
    /// to unset:
    ///   • no store yet → nil: the shelf is a spinner, and a New collection
    ///     created against no store would be a tap into the void.
    ///   • nothing pushed → the grid.
    ///   • a collection pushed → that collection, with the rights on the LIVE
    ///     row, so a mid-view downgrade to viewer moves the + off "add" at once
    ///     and a deleted / lost-access row falls back to the grid (which is also
    ///     when the detail pops itself).
    private var surface: AppRouter.CollectionsSurface? {
        guard let vm else { return nil }
        guard let id = path.last else { return .grid }
        guard let col = vm.collections.first(where: { $0.id == id }) else { return .grid }
        return .detail(id: id, canEdit: model.canEdit(col))
    }

    /// Push the router's parked collection once it exists locally (a share
    /// push can land before the hydrate that brings the row; the count
    /// onChange retries). An id that never appears stays parked, harmlessly.
    private func consumeOpenCollection() {
        guard let id = model.router.openCollectionId, let vm,
              vm.collections.contains(where: { $0.id == id }) else { return }
        model.router.openCollectionId = nil
        guard path.last != id else { return }   // already showing it
        path.append(id)
    }

    /// Open the New-collection sheet for a + tap the scaffold resolved to
    /// `.newCollection` (the grid, or a shared collection I can only view).
    /// Ignores `.addToCollection` — that one belongs to the open detail, and
    /// clearing it here would swallow it.
    private func consumeFabRequest(_ req: AppRouter.CollectionFabRequest?) {
        guard let req, case .newCollection = req.action else { return }
        model.router.collectionFabRequest = nil
        // The inline "+ New" pill is hidden while the Archived filter is on,
        // and a new collection is born ACTIVE — drop back to the active shelf
        // first or it would be created straight out of sight.
        showArchived = false
        showNew = true
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
                            // Value-based, so the push goes through `path` —
                            // the one place that says which collection is open.
                            NavigationLink(value: col.id) { gridCard(col) }
                                .buttonStyle(.plain)
                                // Owner-only "Share…" straight from the card (unified sharing v1).
                                .contextMenu {
                                    if model.isOwner(col) {
                                        Button { shareTarget = .collection(id: col.id, name: col.name) } label: {
                                            Label("Share…", systemImage: "person.badge.plus")
                                        }
                                    }
                                }
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
                            // 44pt hit target; negative padding keeps the swatch row's
                            // drawn size (the 30pt circle is unchanged).
                            .frame(width: 44, height: 44).contentShape(Circle())
                            .onTapGesture { newColor = col }
                            .padding(-7)
                            .accessibilityElement()
                            .accessibilityLabel(col.capitalized)
                            .accessibilityAddTraits(newColor == col ? [.isButton, .isSelected] : .isButton)
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
    /// Set when the server REFUSED a "Leave" — the screen stays put and says so
    /// instead of popping as though access were gone.
    @State private var leaveFailed = false
    @State private var leaving = false
    /// A member's own controls next to Leave — Report… and Block the owner
    /// (server-side, migration 075). A member used to have only Leave, and the
    /// owner could simply add them back (audit 2026-09-22, C10).
    @State private var showReport = false
    @State private var reportNote: String?
    @State private var confirmBlockOwner = false
    @State private var blockFailed = false
    @State private var promoteTarget: CollectionItem?
    @State private var byTimeTarget: CollectionItem?
    @SwiftUI.FocusState private var addFocused: Bool
    @SwiftUI.FocusState private var titleFocused: Bool

    private var collection: ItemCollection? { vm.collections.first { $0.id == id } }

    /// Scroll anchor on the inline add pill — the + scrolls it into view before
    /// focusing it.
    private static let addFieldAnchor = "collection-add-field"

    var body: some View {
        Group {
            if let col = collection {
                detail(col)
            } else {
                Color.clear.onAppear { dismiss() }   // gone (deleted / lost access) → pop
            }
        }
        // NOTE: this screen deliberately publishes NOTHING to the router. The
        // bottom-bar + learns a collection is open from ListsView, which derives
        // it from the navigation path it owns plus the live row — see
        // `ListsView.surface`. An `onAppear`/`onDisappear` pair here would make
        // one callback load-bearing: miss the disappear (leave the tab straight
        // from an open collection) and the + goes on offering "add to that
        // collection" over the grid.
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)   // keep the standard back button (overview hides its bar)
        .sheet(isPresented: $showShare) {
            if let col = collection { ShareScreen(target: .collection(id: col.id, name: col.name)) }
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
        .alert("Couldn't leave this list", isPresented: $leaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The server didn't accept it, so you still have access. Check your connection and try again.")
        }
        .confirmationDialog("Report this list?", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(["Objectionable content", "Spam", "Harassment", "Other"], id: \.self) { reason in
                Button(reason) {
                    Task {
                        let ok = await model.reportConcern(collectionId: id, about: "list owner", reason: reason)
                        reportNote = ok ? "Report sent — we review every report." : "Couldn't send the report — try again."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send a report about this list to the Unstuck team. We review reports and take action.")
        }
        .alert(reportNote ?? "", isPresented: Binding(get: { reportNote != nil }, set: { if !$0 { reportNote = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Block the owner?", isPresented: $confirmBlockOwner, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let ownerId = collection?.ownerId else { return }
                leaving = true
                Task {
                    // Pop only once the SERVER confirms — the block also takes
                    // me out of this list (and every other list between us).
                    let ok = await model.blockUser(userId: ownerId)
                    leaving = false
                    if ok { dismiss() } else { blockFailed = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to share tasks or lists with you, and everything shared between you stops — this list too. You can unblock them in Settings › People.")
        }
        .alert("Couldn't block the owner", isPresented: $blockFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The server didn't accept it, so nothing changed. Check your connection and try again.")
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
                            .focused($titleFocused)
                            .submitLabel(.done)
                            .onSubmit { commitTitleRename(col) }
                            // Re-sync the draft from the live name whenever the
                            // field isn't focused — so a concurrent rename (sync)
                            // isn't silently clobbered by a stale once-seeded draft.
                            .onChange(of: col.name) { _, new in if !titleFocused { titleDraft = new } }
                        Button { commitTitleRename(col) } label: {
                            Image(systemName: "checkmark").font(.system(size: 18)).foregroundStyle(theme.palette.green).padding(4)
                        }.buttonStyle(.plain)
                        // Cancel — discard the draft, keep the live name (mirrors
                        // TaskEditor.cancelButton).
                        Button { titleDraft = col.name; editingTitle = false; titleFocused = false } label: {
                            Image(systemName: "xmark").font(.system(size: 18)).foregroundStyle(theme.palette.ink3).padding(4)
                        }.buttonStyle(.plain)
                    } else {
                        Text(col.name).font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { if owner { titleDraft = col.name; editingTitle = true; titleFocused = true } }
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
                                    Image(systemName: "person.badge.plus").font(.system(size: 22)).foregroundStyle(theme.palette.ink2)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("Share")
                            }
                        } else {
                            // Leave / Report… / Block the owner (audit
                            // 2026-09-22, C10). Pop only once the SERVER
                            // confirms the leave — the old immediate dismiss
                            // claimed access was gone even when the call was
                            // refused, and the list reappeared on the next
                            // hydrate unexplained.
                            Menu {
                                Button {
                                    leaving = true
                                    model.leaveCollection(col.id) { ok in
                                        leaving = false
                                        if ok { dismiss() } else { leaveFailed = true }
                                    }
                                } label: { Label("Leave", systemImage: "rectangle.portrait.and.arrow.right") }
                                Button { showReport = true } label: { Label("Report…", systemImage: "flag") }
                                if col.ownerId != nil {
                                    Button(role: .destructive) { confirmBlockOwner = true } label: {
                                        Label("Block the owner", systemImage: "hand.raised")
                                    }
                                }
                            } label: {
                                Text(leaving ? "Leaving…" : "Leave")
                                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink3)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                            }.buttonStyle(.plain).disabled(leaving)
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

            // ScrollViewReader so the bottom-bar + can bring the add field into
            // view before focusing it (see consumeFabRequest).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Recolor swatches — owner only.
                        if owner {
                            HStack(spacing: 8) {
                                ForEach(COLLECTION_PALETTE, id: \.self) { token in
                                    Circle().fill(theme.palette.areaColor(token)).frame(width: 26, height: 26)
                                        .overlay(Circle().stroke(theme.palette.ink, lineWidth: col.color == token ? 2 : 0))
                                        // 44pt hit target; negative padding preserves the
                                        // drawn 26pt swatch + row spacing.
                                        .frame(width: 44, height: 44).contentShape(Circle())
                                        .onTapGesture { model.recolorCollection(col, color: token) }
                                        .padding(-9)
                                        .accessibilityElement()
                                        .accessibilityLabel(token.capitalized)
                                        .accessibilityAddTraits(col.color == token ? [.isButton, .isSelected] : .isButton)
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
                                    .focused($addFocused)
                                    .onSubmit(add)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(theme.palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(theme.palette.line2))
                            .padding(.top, 18)
                            .id(Self.addFieldAnchor)
                            // Autofocus on open so the keyboard is already up for rapid entry
                            // (Android requestFocus on collectionId). add() re-focuses after each item.
                            .onAppear { addFocused = true }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 96)
                }
                // The + on this screen = "put the cursor in the ONE add field".
                .onChange(of: model.router.collectionFabRequest) { _, req in
                    consumeFabRequest(req, proxy: proxy)
                }
            }
        }
    }

    /// The bottom-bar + resolved to "add to this collection". Deliberately not
    /// a second add UI — it drives the inline field that's already here, so
    /// there stays exactly one add path. Scroll it into view first: in a long
    /// collection it sits well below the fold, and a focused-but-offscreen
    /// field swallows typing invisibly.
    private func consumeFabRequest(_ req: AppRouter.CollectionFabRequest?, proxy: ScrollViewProxy) {
        // Match the id too: only the collection actually on screen consumes it.
        guard let req, case .addToCollection(let target) = req.action, target == id else { return }
        model.router.collectionFabRequest = nil
        withAnimation { proxy.scrollTo(Self.addFieldAnchor, anchor: .bottom) }
        addFocused = true
    }

    @ViewBuilder
    private func itemRow(_ col: ItemCollection, _ item: CollectionItem, canEdit: Bool) -> some View {
        CollItemRow(
            col: col, item: item, readOnly: !canEdit,
            // One row open at a time: opening a swipe closes any other.
            revealed: revealedId == item.id,
            onReveal: { open in revealedId = open ? item.id : (revealedId == item.id ? nil : revealedId) },
            onMoveToTask: { startPromote(col, item) })
            // Key the row to item identity: pinning moves an item between the
            // Pinned/All sections, and without a stable id an in-progress edit's
            // @State could re-attach to a different recycled item.
            .id(item.id)
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
        addFocused = true   // keep the keyboard up for rapid entry (Android requestFocus)
    }

    /// Commit the inline title rename. An empty/blank draft would silently wipe
    /// the name, so treat it as a cancel (revert to the live name) instead.
    private func commitTitleRename(_ col: ItemCollection) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { titleDraft = col.name }
        else { model.renameCollection(col, name: trimmed) }
        editingTitle = false; titleFocused = false
    }
}

private struct CollItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let col: ItemCollection
    let item: CollectionItem
    let readOnly: Bool
    /// This row is the open one (its swipe actions showing).
    let revealed: Bool
    /// Open (true) or close (false) this row's swipe actions.
    let onReveal: (Bool) -> Void
    let onMoveToTask: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @SwiftUI.FocusState private var editFocused: Bool
    /// Horizontal offset of the card: > 0 shows the leading actions (Pin, Move
    /// to task), < 0 the trailing one (Delete).
    @State private var offset: CGFloat = 0
    /// Offset when the current drag began (a drag can start from an open row).
    @State private var dragStart: CGFloat? = nil

    /// Ahmad, 2026-09-23: the row did too many things at once (tap = edit, an
    /// ellipsis that slid out three icons, hold = the same icons). Now each
    /// gesture does one thing: TAP strikes it out, SWIPE LEFT offers Delete,
    /// SWIPE RIGHT offers Pin and Move to task, HOLD edits the text.
    private static let actionWidth: CGFloat = 74
    private var canMove: Bool { !(item.promoted == true) || item.promotedDone == true }
    private var leadingWidth: CGFloat { Self.actionWidth * (canMove ? 2 : 1) }
    private var trailingWidth: CGFloat { Self.actionWidth }

    /// Commit the inline body edit. Blank draft → cancel (revert), never wipe
    /// the item body silently.
    private func commitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.updateCollectionItemBody(col, itemId: item.id, body: trimmed) }
        editing = false; editFocused = false
    }

    private func close() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { offset = 0 }
        if revealed { onReveal(false) }
    }

    private func toggleDone() {
        guard !readOnly else { return }
        if offset != 0 { close(); return }
        model.toggleCollectionItemDone(col, itemId: item.id)
    }

    private func startEdit() {
        guard !readOnly else { return }
        close()
        draft = item.body; editing = true; editFocused = true
    }

    var body: some View {
        ZStack {
            if !readOnly && offset != 0 { actions }
            card
                .offset(x: offset)
                .simultaneousGesture(readOnly || editing ? nil : swipe)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 3)
        // Another row opened (or a promote started): slide this one shut.
        .onChange(of: revealed) { _, open in
            if !open && offset != 0 { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { offset = 0 } }
        }
        // Swipes are not reachable with VoiceOver — every action is here too.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(readOnly ? "" : "Double-tap to strike it out. Swipe up or down for more actions.")
        .accessibilityAction { toggleDone() }
        .accessibilityActions {
            if !readOnly {
                Button(item.pinned == true ? "Unpin" : "Pin") { model.toggleCollectionItemPin(col, itemId: item.id) }
                if canMove { Button("Move to task") { onMoveToTask() } }
                Button("Edit") { startEdit() }
                Button("Delete") { model.removeCollectionItem(col, itemId: item.id) }
            }
        }
    }

    // MARK: swipe

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { v in
                // Horizontal only: a vertical drag belongs to the ScrollView.
                guard abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                if dragStart == nil { dragStart = offset }
                let raw = (dragStart ?? 0) + v.translation.width
                // Rubber-band past each side's actions.
                if raw > leadingWidth { offset = leadingWidth + (raw - leadingWidth) * 0.25 }
                else if raw < -trailingWidth { offset = -trailingWidth + (raw + trailingWidth) * 0.25 }
                else { offset = raw }
            }
            .onEnded { v in
                guard dragStart != nil else { return }
                dragStart = nil
                let target: CGFloat
                if offset > leadingWidth * 0.45 || (v.predictedEndTranslation.width > 160 && offset > 0) { target = leadingWidth }
                else if offset < -trailingWidth * 0.45 || (v.predictedEndTranslation.width < -160 && offset < 0) { target = -trailingWidth }
                else { target = 0 }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { offset = target }
                if target != 0 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReveal(true)
                } else if revealed { onReveal(false) }
            }
    }

    /// The actions under the card: Pin + Move to task on the left (swipe
    /// right), Delete on the right (swipe left). Neutral ink for the two
    /// quiet ones; the system's destructive red only for Delete.
    private var actions: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                actionButton(item.pinned == true ? "Unpin" : "Pin",
                             icon: item.pinned == true ? "pin.slash" : "pin",
                             tint: theme.palette.ink2) {
                    model.toggleCollectionItemPin(col, itemId: item.id); close()
                }
                if canMove {
                    actionButton("To task", icon: "arrow.up.forward.app", tint: theme.palette.ink) {
                        close(); onMoveToTask()
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                actionButton("Delete", icon: "trash", tint: theme.palette.red) {
                    close(); model.removeCollectionItem(col, itemId: item.id)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(UFont.sans(11, .semibold))
            }
            .foregroundStyle(theme.palette.bg)
            .frame(width: Self.actionWidth)
            .frame(maxHeight: .infinity)
            .background(tint)
        }.buttonStyle(.plain)
        .accessibilityHidden(true)   // the row's accessibilityActions carry these
    }

    // MARK: card

    private var card: some View {
        let done = item.done == true
        let promoted = item.promoted == true
        let struck = done || promoted        // promoted items read as "handled / in flight"

        return HStack(spacing: 10) {
            // Done checkbox (always visible) — the same toggle as tapping the row.
            ZStack {
                Circle().fill(done ? theme.palette.coral : theme.palette.surface).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(theme.palette.line2, lineWidth: done ? 0 : 1.5))
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            }

            VStack(alignment: .leading, spacing: 2) {
                if editing && !readOnly {
                    HStack {
                        TextField("Item", text: $draft).textFieldStyle(.plain).font(UFont.sans(14))
                            .focused($editFocused)
                            .submitLabel(.done)
                            .onSubmit(commitEdit)
                            // Re-sync from the live body when not focused so a
                            // concurrent edit isn't clobbered by a stale draft.
                            .onChange(of: item.body) { _, new in if !editFocused { draft = new } }
                        Button(action: commitEdit) {
                            Image(systemName: "checkmark").font(.system(size: 16)).foregroundStyle(theme.palette.green).padding(2)
                        }.buttonStyle(.plain)
                        // Cancel — discard the draft, keep the live body.
                        Button { draft = item.body; editing = false; editFocused = false } label: {
                            Image(systemName: "xmark").font(.system(size: 16)).foregroundStyle(theme.palette.ink3).padding(2)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Text(item.body).font(UFont.sans(14))
                        .strikethrough(struck)
                        .foregroundStyle(struck ? theme.palette.ink3 : theme.palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if promoted, let label = promotedLabel() {
                    Text(label).font(UFont.sans(11, .medium)).foregroundStyle(promotedColor())
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { toggleDone() } }
        .onLongPressGesture(minimumDuration: 0.45) { if !editing { startEdit() } }
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

// MARK: - ISO helpers

/// Shared, configured-once formatters — hoisted to static so the per-row due-time
/// rendering (parseISO + fmtTime) doesn't allocate three formatters per call.
/// Read-only after the fixed config; `nonisolated(unsafe)` documents that to the
/// Swift 6 concurrency checker.
private enum ColFmt {
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mm a"; return f
    }()
}

private func parseISO(_ iso: String) -> Date? {
    if let d = ColFmt.isoFractional.date(from: iso) { return d }
    return ColFmt.isoPlain.date(from: iso)
}

private func fmtTime(_ iso: String?) -> String {
    guard let iso, let date = parseISO(iso) else { return "" }
    return ColFmt.time.string(from: date)
}
