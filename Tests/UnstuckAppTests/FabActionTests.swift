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

import SwiftUI
import UIKit
import UnstuckDesign
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

// MARK: - the bar's look: the + sits IN the tab row

/// The + used to be a 56-pt square lifted 28 pt above the bar, covering the
/// last row of whatever was scrolled under it. It is now the middle one of five
/// equal slots, so it must render INSIDE the row: a 44-pt coral square,
/// centred on the bar horizontally and on the tab cells vertically, with no
/// coral above the bar's hairline. And the four tab labels share ONE baseline
/// (the taller Collections symbol used to push its label ~3 pt lower).
///
/// The bar is rendered off-screen (ImageRenderer, 3x, 430 pt wide) in light
/// and dark with Today and Collections active. PNGs are written ONLY when
/// `UNSTUCK_RENDER_DIR` is set (design review; pass it to xcodebuild as
/// `TEST_RUNNER_UNSTUCK_RENDER_DIR`), so normal runs write nothing.
extension FabActionTests {

    /// Bar-coloured band rendered above the bar: a + lifted out of the row
    /// would show up (and fail) here.
    fileprivate static let headroom: CGFloat = 40
    fileprivate static let width: CGFloat = 430
    private static let scale: CGFloat = 3

    @MainActor
    func testThePlusSitsInTheTabRow() throws {
        let dir = ProcessInfo.processInfo.environment["UNSTUCK_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for dark in [false, true] {
            for active in [AppRouter.Tab.today, .lists] {
                let name = "ios-\(dark ? "dark" : "light")-\(active == .today ? "today" : "lists")"
                let renderer = ImageRenderer(content:
                    BarShot(active: active)
                        .unstuckTheme(accent: .indigo)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        // The + carries the tour's UIKit anchor, which an image
                        // can't draw (yellow placeholder behind the square).
                        .environment(\.tourAnchorsEnabled, false))
                renderer.scale = Self.scale
                renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
                let image = try XCTUnwrap(renderer.cgImage, "\(name): the bar did not render")
                if let dir {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try XCTUnwrap(UIImage(cgImage: image).pngData())
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }

                let pixels = try XCTUnwrap(RenderedPixels(image))
                let palette = (dark ? Palette.dark : Palette.light).withAccent(.indigo, dark: dark)
                let px = Self.scale
                let barTop = Self.headroom * px
                // Cells band = the bar minus its 8-pt top / 6-pt bottom padding.
                let cellsMid = ((barTop + 8 * px) + (CGFloat(pixels.height) - 6 * px)) / 2

                let coral = try XCTUnwrap(pixels.bounds(matching: palette.coral), "\(name): no coral + drawn")
                XCTAssertGreaterThanOrEqual(coral.minY, barTop, "\(name): the + pokes above the bar")
                XCTAssertEqual(coral.width, 44 * px, accuracy: 3, "\(name): the + is 44 pt")
                XCTAssertEqual(coral.height, 44 * px, accuracy: 3, "\(name): the + is 44 pt")
                XCTAssertEqual(coral.midX, Self.width * px / 2, accuracy: 3, "\(name): the + is the middle slot")
                XCTAssertEqual(coral.midY, cellsMid, accuracy: 1.5 * px, "\(name): the + is centred on the tab cells")

                // Slots 0, 1, 3, 4 of five are the tabs. Every label starts with
                // a capital and has an ascender, so the top of its ink is a
                // fair proxy for its baseline.
                let tops = try [0, 1, 3, 4].map { slot in
                    try XCTUnwrap(pixels.labelTop(slot: slot, of: 5, below: Int(barTop) + 2),
                                  "\(name): no label drawn in slot \(slot)")
                }
                XCTAssertLessThanOrEqual(tops.max()! - tops.min()!, Int(px),
                                         "\(name): tab labels off one baseline (tops \(tops))")
            }
        }
    }
}

/// An RGBA8 sRGB copy of a render, rows top-down (a bitmap context's memory
/// starts at the image's top row).
private struct RenderedPixels {
    let width: Int, height: Int
    private var data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width; height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !drawn { return nil }
    }

    private func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// Bounds of every pixel within a small tolerance of `color` — the +
    /// square's fill. Anti-aliased edges and the white glyph drop out; the
    /// square's straight edges still set the bounds.
    func bounds(matching color: Color) -> CGRect? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let t = (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let p = rgb(x, y)
                if abs(p.0 - t.0) <= 6, abs(p.1 - t.1) <= 6, abs(p.2 - t.2) <= 6 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Top row of the LAST run of ink rows in one of `count` equal slots —
    /// the label under the icon. "Ink" = far from the bar colour (read at the
    /// top-left corner), so the faint active pill doesn't count.
    func labelTop(slot: Int, of count: Int, below top: Int) -> Int? {
        let bg = rgb(0, 0)
        let x0 = slot * width / count, x1 = (slot + 1) * width / count
        var lastRunTop: Int?
        var previous = false
        for y in top..<height {
            let ink = (x0..<x1).contains { x in
                let p = rgb(x, y)
                return abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 150
            }
            if ink && !previous { lastRunTop = y }
            previous = ink
        }
        return lastRunTop
    }
}

/// The bar as the scaffold shows it, with a bar-coloured band above it.
private struct BarShot: View {
    @Environment(\.uTheme) private var theme
    let active: AppRouter.Tab
    var body: some View {
        VStack(spacing: 0) {
            theme.palette.bg.frame(height: FabActionTests.headroom)
            BottomNavBar(active: active, onSelect: { _ in }, onFab: {})
        }
        .frame(width: FabActionTests.width)
        .background(theme.palette.bg)
    }
}
