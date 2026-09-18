// The bottom-bar + creates the thing you're looking at. The DECISION — which
// action the coral + resolves to for a given surface and my rights on the
// collection that's open — is pure logic in AppRouter.fabAction, so it's pinned
// here rather than left to be inferred from the UI:
//
//   • Today / Tasks / Calendar → New task (unchanged; the guided tour's
//     first-action step falls back to this anchor on the Tasks tab).
//   • The Collections grid → New collection.
//   • Inside a collection I can edit → its ONE inline add field.
//   • Inside a collection I can only VIEW → New collection, never an add the
//     server would refuse.
//   • The Collections tab with no surface published (store not up) → New task:
//     never a New collection the shelf can't actually create.
//
// The other half of the contract is RETRACTION — the + must never keep pointing
// at a collection that isn't on screen. Two independent mechanisms cover that,
// and both are exercised below: ListsView republishes `collectionsSurface` from
// derived state (the nav path + the live rows), and `AppRouter.tab`'s setter
// clears it on any tab change, so no single lifecycle callback is load-bearing.

import XCTest
@testable import Unstuck

final class FabActionTests: XCTestCase {

    private func resolve(_ tab: AppRouter.Tab,
                         _ surface: AppRouter.CollectionsSurface? = .grid) -> AppRouter.FabAction {
        AppRouter.fabAction(tab: tab, surface: surface)
    }

    // MARK: - the three unchanged tabs

    func testTaskTabsStillOpenNewTask() {
        XCTAssertEqual(resolve(.today), .newTask)
        XCTAssertEqual(resolve(.tasks), .newTask)
        XCTAssertEqual(resolve(.calendar), .newTask)
    }

    /// A stale Collections surface (a retraction that hasn't landed yet) must
    /// NOT leak onto the task tabs — off Collections it's ignored by
    /// construction, on top of the two retraction paths.
    func testStaleSurfaceCannotMisrouteTheTaskTabs() {
        let open = AppRouter.CollectionsSurface.detail(id: "c1", canEdit: true)
        XCTAssertEqual(resolve(.today, open), .newTask)
        XCTAssertEqual(resolve(.tasks, open), .newTask)
        XCTAssertEqual(resolve(.calendar, open), .newTask)
    }

    // MARK: - Collections

    func testCollectionsGridCreatesACollection() {
        XCTAssertEqual(resolve(.lists, .grid), .newCollection)
    }

    func testInsideAnEditableCollectionItAddsToThatCollection() {
        XCTAssertEqual(resolve(.lists, .detail(id: "groceries", canEdit: true)),
                       .addToCollection(id: "groceries"))
    }

    /// Two collections open in sequence: the action always carries the id of
    /// the one on screen, never the previous one.
    func testTheAddTargetsTheCollectionOnScreen() {
        XCTAssertEqual(resolve(.lists, .detail(id: "a", canEdit: true)), .addToCollection(id: "a"))
        XCTAssertEqual(resolve(.lists, .detail(id: "b", canEdit: true)), .addToCollection(id: "b"))
    }

    /// View-only share: no add rights, so the + falls back to New collection
    /// rather than offering something the member can't do.
    func testViewOnlyCollectionFallsBackToNewCollection() {
        XCTAssertEqual(resolve(.lists, .detail(id: "shared", canEdit: false)), .newCollection)
    }

    /// Popping back to the grid (or the collection being deleted / access
    /// lost, which pops too) → straight back to New collection.
    func testPoppingBackToTheGridRestoresNewCollection() {
        XCTAssertEqual(resolve(.lists, .detail(id: "c1", canEdit: true)), .addToCollection(id: "c1"))
        XCTAssertEqual(resolve(.lists, .grid), .newCollection)
    }

    /// The Collections tab with NO surface published — a boot that reached the
    /// tab before the store was built, so the shelf is still a ProgressView and
    /// the New-collection sheet's Create would write nowhere. The + must not
    /// offer it; it offers the one thing that does work, and its label says so.
    func testAnUnbuiltCollectionsShelfIsNotOfferedANewCollection() {
        XCTAssertEqual(resolve(.lists, nil), .newTask)
        XCTAssertEqual(AppRouter.fabAction(tab: .lists, surface: nil).accessibilityLabel, "New task")
    }

    // MARK: - labels (the only part of the button that changes)

    func testAccessibilityLabelFollowsTheAction() {
        XCTAssertEqual(AppRouter.FabAction.newTask.accessibilityLabel, "New task")
        XCTAssertEqual(AppRouter.FabAction.newCollection.accessibilityLabel, "New collection")
        XCTAssertEqual(AppRouter.FabAction.addToCollection(id: "c1").accessibilityLabel,
                       "Add to this collection")
    }

    // MARK: - the request mailbox

    /// Two identical taps in a row must be two distinct requests, or the
    /// second one is swallowed by `onChange` seeing no change.
    func testRepeatedRequestsAreDistinct() {
        let first = AppRouter.CollectionFabRequest(action: .newCollection)
        let second = AppRouter.CollectionFabRequest(action: .newCollection)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - end-to-end through the live router

    @MainActor
    func testRouterStateDrivesTheResolvedAction() {
        let router = AppRouter()
        router.tab = .today
        XCTAssertEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface), .newTask)

        router.tab = .lists
        // Nothing published yet (ListsView hasn't built its store) → New task.
        XCTAssertEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface), .newTask)

        router.collectionsSurface = .grid
        XCTAssertEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface), .newCollection)

        router.collectionsSurface = .detail(id: "c1", canEdit: true)
        XCTAssertEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface),
                       .addToCollection(id: "c1"))

        router.collectionsSurface = .grid
        XCTAssertEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface), .newCollection)
    }

    // MARK: - retraction: leaving the surface

    /// THE REGRESSION. Leave the Collections tab straight from an open
    /// collection — tap Today in the bottom nav without tapping back — and come
    /// straight back. The marker used to be retracted only by the detail's
    /// `onDisappear`; if that didn't fire the + went on offering "add to that
    /// collection" over the grid. Changing tab now retracts it itself.
    @MainActor
    func testLeavingTheTabRetractsTheOpenCollection() {
        let router = AppRouter()
        router.tab = .lists
        router.collectionsSurface = .detail(id: "c1", canEdit: true)

        router.tab = .today                     // bottom nav, no back tap
        XCTAssertNil(router.collectionsSurface)

        router.tab = .lists                     // …and back to the grid
        XCTAssertNil(router.collectionsSurface,
                     "a returning tab must not inherit the last visit's collection")
        XCTAssertNotEqual(AppRouter.fabAction(tab: router.tab, surface: router.collectionsSurface),
                          .addToCollection(id: "c1"),
                          "the + is still aimed at a collection that is not on screen")
    }

    /// Every route into a tab goes through the same setter, `select(_:)`
    /// included (deep links, the command palette, the tour, the assistant).
    @MainActor
    func testSelectRetractsTooAndReSelectingTheSameTabDoesNot() {
        let router = AppRouter()
        router.tab = .lists
        router.collectionsSurface = .detail(id: "c1", canEdit: true)

        // Re-selecting the tab you're already on is not leaving it: the open
        // collection is still on screen, so the + must keep pointing at it.
        router.select(.lists)
        XCTAssertEqual(router.collectionsSurface, .detail(id: "c1", canEdit: true))

        router.select(.calendar)
        XCTAssertNil(router.collectionsSurface)
    }

    /// An unconsumed + request belongs to the surface that was asked for it —
    /// it must not fire at whatever is showing after a tab change.
    @MainActor
    func testLeavingTheTabDropsAnUnconsumedRequest() {
        let router = AppRouter()
        router.tab = .lists
        router.collectionFabRequest = .init(action: .addToCollection(id: "c1"))
        router.tab = .calendar
        XCTAssertNil(router.collectionFabRequest)
    }

    /// Sign-out tears the whole scaffold down without a tab change, so the
    /// surface is retracted explicitly there as well.
    @MainActor
    func testSignOutClearsTheSurface() {
        let router = AppRouter()
        router.tab = .lists
        router.collectionsSurface = .detail(id: "c1", canEdit: true)
        router.collectionFabRequest = .init(action: .newCollection)

        router.clearCollectionsSurface()
        XCTAssertNil(router.collectionsSurface)
        XCTAssertNil(router.collectionFabRequest)
    }
}
