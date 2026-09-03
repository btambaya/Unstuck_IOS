// Ports the gateway surfaces need from AppModel: the fact edit-in-place the
// Settings "What Unstuck knows" panel uses (ProfileFactsService has save /
// remove / clear but no update). `profileFactsHydrated` and
// `canonicalStruggles` live in AppModel.swift.

import Foundation
import UnstuckCore
import UnstuckData
import UnstuckSync

extension AppModel {

    /// Edit a fact's text IN PLACE — same id, one `upsert` + one outbox push
    /// (web `saveProfileFact` on an existing row). Category stays; `whenIso`
    /// replaces the date only when valid. False when there's no active row
    /// with that id (forgotten elsewhere) or the text is empty.
    // TODO(fix-B): fold into ProfileFactsService as
    //   `@discardableResult public func update(id: String, fact: String, whenIso: String? = nil) -> ProfileFact?`
    // (same sequencing as `save`'s refine branch: prepareFact → mutate →
    // repo.upsert → push(id:nowISO:)) and call that instead.
    @discardableResult
    func updateProfileFact(id: String, fact: String, whenIso: String? = nil) -> Bool {
        guard let db, let text = ProfileFactsLogic.prepareFact(fact) else { return false }
        let repo = ProfileFactsRepository(db)
        guard var f = ((try? repo.fetch(id: id)) ?? nil), f.active else { return false }
        let nowISO = ProfileFactsService.isoNow()
        f.fact = text
        f.source = .settings
        if let when = ProfileFactsLogic.validWhenIso(whenIso) { f.whenIso = when }
        f.updatedAt = nowISO
        do { try repo.upsert(f) } catch { return false }
        if let write { Task { try? await write.pushProfileFact(id: id, nowISO: nowISO) } }
        return true
    }
}
