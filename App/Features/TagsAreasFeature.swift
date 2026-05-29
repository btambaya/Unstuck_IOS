// P5 — manage the user's tag + life-area vocabularies. Lists from the live
// store with add + swipe-to-delete; writes through WriteThrough.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class TagsAreasModel {
    var tags: [TagRow] = []
    var areas: [LifeArea] = []
    private let tagRepo: Repository<TagRow>
    private let areaRepo: Repository<LifeArea>
    init(_ tagRepo: Repository<TagRow>, _ areaRepo: Repository<LifeArea>) {
        self.tagRepo = tagRepo; self.areaRepo = areaRepo
    }
    func observe() async {
        async let a: Void = observeTags()
        async let b: Void = observeAreas()
        _ = await (a, b)
    }
    private func observeTags() async {
        do { for try await r in tagRepo.observeValues() { tags = r } } catch {}
    }
    private func observeAreas() async {
        do { for try await r in areaRepo.observeValues() { areas = r } } catch {}
    }
}

struct TagsAreasView: View {
    @Environment(AppModel.self) private var model
    @State private var vm: TagsAreasModel?
    @State private var newTag = ""
    @State private var newArea = ""

    var body: some View {
        Group {
            if let vm { list(vm) } else { ProgressView() }
        }
        .navigationTitle("Tags & areas")
        .task {
            guard vm == nil, let db = model.db else { return }
            let m = TagsAreasModel(Repository<TagRow>(db, orderColumn: "sortOrder"),
                                   Repository<LifeArea>(db, orderColumn: "sortOrder"))
            vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func list(_ vm: TagsAreasModel) -> some View {
        List {
            Section("Tags") {
                ForEach(vm.tags) { Text($0.name) }
                    .onDelete { idx in idx.map { vm.tags[$0].id }.forEach(model.deleteTag) }
                HStack {
                    TextField("Add tag", text: $newTag).onSubmit { addTag(vm) }
                    Button("Add") { addTag(vm) }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Life areas") {
                ForEach(vm.areas) { area in
                    HStack { AreaDot(area.color); Text(area.name) }
                }
                .onDelete { idx in idx.map { vm.areas[$0].id }.forEach(model.deleteLifeArea) }
                HStack {
                    TextField("Add area", text: $newArea).onSubmit { addArea(vm) }
                    Button("Add") { addArea(vm) }.disabled(newArea.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addTag(_ vm: TagsAreasModel) {
        let name = newTag.trimmingCharacters(in: .whitespacesAndNewlines); newTag = ""
        guard !name.isEmpty else { return }
        let order = (vm.tags.map(\.sortOrder).max() ?? -1) + 1
        model.saveTag(TagRow(id: newUUID(), name: name, color: nil, sortOrder: order))
    }
    private func addArea(_ vm: TagsAreasModel) {
        let name = newArea.trimmingCharacters(in: .whitespacesAndNewlines); newArea = ""
        guard !name.isEmpty else { return }
        let order = (vm.areas.map(\.sortOrder).max() ?? -1) + 1
        model.saveLifeArea(LifeArea(id: newUUID(), name: name, color: "indigo", sortOrder: order))
    }
}
