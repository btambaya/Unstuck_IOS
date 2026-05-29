// P5 — Collections ("Lists"). Calm memory containers: a collection holds
// inline items and syncs as a single row. Reads via Repository<ItemCollection>;
// adding a list or item writes the whole collection through WriteThrough.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

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

struct ListsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CollectionsModel?
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm { content(vm) } else { ProgressView() }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Lists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
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

    @ViewBuilder
    private func content(_ vm: CollectionsModel) -> some View {
        if vm.collections.isEmpty {
            EmptyHint(text: "No lists yet. Tap + to make one — groceries, books, anything to keep.")
                .padding(20)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.collections) { col in
                        NavigationLink { CollectionDetailView(collection: col) } label: { row(col) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    private func row(_ col: ItemCollection) -> some View {
        Card {
            HStack(spacing: 10) {
                AreaDot(col.color, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.name).font(UFont.sans(16, .medium)).foregroundStyle(theme.palette.ink)
                    if let s = col.subtitle, !s.isEmpty {
                        Text(s).font(UFont.serifItalic(13)).foregroundStyle(theme.palette.ink3)
                    }
                }
                Spacer()
                Text("\(col.items.count)").font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(theme.palette.ink4)
            }
        }
    }

    private func addCollection() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !trimmed.isEmpty, let write = model.write, let vm else { return }
        let nextOrder = (vm.collections.map(\.sortOrder).max() ?? -1) + 1
        let col = ItemCollection(id: newUUID(), name: trimmed, color: "indigo", subtitle: nil, items: [], sortOrder: nextOrder)
        Task { try? await write.upsertCollection(col, nowISO: AppModel.isoNow()) }
    }
}

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let collection: ItemCollection
    @State private var newItem = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(collection.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: (item.pinned ?? false) ? "pin.fill" : "circle.fill")
                            .font(.system(size: 6)).foregroundStyle(theme.palette.ink4)
                        Text(item.body).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                        Spacer()
                    }
                }
                HStack {
                    TextField("Add an item", text: $newItem)
                        .textFieldStyle(.plain).font(UFont.sans(15))
                        .onSubmit(addItem)
                    Button(action: addItem) { Image(systemName: "plus.circle.fill").foregroundStyle(theme.palette.coralDeep) }
                        .buttonStyle(.plain)
                }
                .padding(12)
                .background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            }
            .padding(20)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle(collection.name)
    }

    private func addItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        newItem = ""
        guard !trimmed.isEmpty, let write = model.write else { return }
        var next = collection
        next.items.append(CollectionItem(id: newUUID(), body: trimmed, at: AppModel.isoNow()))
        Task { try? await write.upsertCollection(next, nowISO: AppModel.isoNow()) }
    }
}
