// profile_facts in GRDB: the v3 migration, upsert-in-place, the active-only
// read that hides soft-delete tombstones, softRemove keeping the row, the
// sign-out wipe, and the live observation the Settings / gateway surfaces sit on.

import XCTest
import GRDB
import UnstuckCore
@testable import UnstuckData

final class ProfileFactsRepositoryTests: XCTestCase {
    private var db: AppDatabase!
    private var repo: ProfileFactsRepository!
    private let t0 = "2026-08-01T10:00:00.000Z"
    private let t1 = "2026-08-01T11:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        repo = ProfileFactsRepository(db)
    }

    private func fact(_ id: String, _ text: String, category: ProfileFactCategory = .person,
                      whenIso: String? = nil, updatedAt: String? = nil) -> ProfileFact {
        ProfileFact(id: id, category: category, fact: text, source: .chat, whenIso: whenIso,
                    createdAt: t0, updatedAt: updatedAt ?? t0)
    }

    func testMigrationCreatesTheTableAndRowsRoundTrip() throws {
        let cols = try db.writer.read { db in try db.columns(in: "profile_facts").map(\.name) }
        XCTAssertEqual(Set(cols), ["id", "category", "fact", "source", "whenIso", "active", "createdAt", "updatedAt"])
        let f = fact("p1", "Zara's birthday", whenIso: "2026-09-14")
        try repo.upsert(f)
        XCTAssertEqual(try repo.fetch(id: "p1"), f)
        XCTAssertEqual(try repo.fetch(id: "p1")?.source, .chat)
        XCTAssertEqual(try repo.fetch(id: "p1")?.active, true)
    }

    func testUpsertUpdatesInPlace() throws {
        try repo.upsert(fact("p1", "Maleek — son"))
        try repo.upsert(fact("p1", "Maleek — son, 9", updatedAt: t1))
        XCTAssertEqual(try repo.all().count, 1)
        XCTAssertEqual(try repo.fetch(id: "p1")?.fact, "Maleek — son, 9")
        XCTAssertEqual(try repo.fetch(id: "p1")?.updatedAt, t1)
    }

    func testAllIsNewestUpdatedFirstAndHidesTombstonesByDefault() throws {
        try repo.upsert(fact("old", "Mornings are good", category: .rhythm))
        try repo.upsert(fact("new", "Never before 10", category: .constraint, updatedAt: t1))
        var gone = fact("gone", "Forgotten", category: .context)
        gone.active = false
        try repo.upsert(gone)
        XCTAssertEqual(try repo.all().map(\.id), ["new", "old"])
        XCTAssertEqual(Set(try repo.all(activeOnly: false).map(\.id)), ["new", "old", "gone"])
    }

    func testSoftRemoveKeepsTheRowAsATombstone() throws {
        try repo.upsert(fact("p1", "Maleek — son"))
        XCTAssertTrue(try repo.softRemove(id: "p1", nowISO: t1))
        XCTAssertEqual(try repo.all().count, 0, "hidden from the active read")
        let row = try XCTUnwrap(try repo.fetch(id: "p1"))
        XCTAssertFalse(row.active)
        XCTAssertEqual(row.updatedAt, t1, "the deletion carries a fresh updated_at for last-write-wins")
        XCTAssertEqual(row.fact, "Maleek — son", "the text is kept (the server row keeps it too)")
        // Removing again, or removing an unknown id, is a no-op that reports false.
        XCTAssertFalse(try repo.softRemove(id: "p1", nowISO: t1))
        XCTAssertFalse(try repo.softRemove(id: "nope", nowISO: t1))
    }

    func testClearWipesEverythingIncludingTombstones() throws {
        try repo.upsert(fact("p1", "A"))
        try repo.upsert(fact("p2", "B"))
        try repo.softRemove(id: "p2", nowISO: t1)
        try repo.clear()
        XCTAssertEqual(try repo.all(activeOnly: false).count, 0)
    }

    func testClearAllWipesProfileFactsOnSignOut() throws {
        try repo.upsert(fact("p1", "A"))
        try db.clearAll()
        XCTAssertEqual(try repo.all(activeOnly: false).count, 0)
    }

    func testObservationEmitsInitialValueThenChanges() async throws {
        try repo.upsert(fact("p1", "A"))
        var seen: [[String]] = []
        for try await facts in repo.observeValues() {
            seen.append(facts.map(\.id))
            if seen.count == 1 {
                try repo.upsert(fact("p2", "B", updatedAt: t1))
            } else if seen.count == 2 {
                try repo.softRemove(id: "p1", nowISO: t1)
            } else {
                break
            }
        }
        XCTAssertEqual(seen, [["p1"], ["p2", "p1"], ["p2"]])
    }
}
