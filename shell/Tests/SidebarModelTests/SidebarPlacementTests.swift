import XCTest
@testable import SidebarModel

/// P3.14: the sidebar on the window's right. Every piece's edge, the sign of
/// each slide offset and the peek strip, with the left layout unchanged.
final class SidebarPlacementTests: XCTestCase {
    private let left = SidebarPlacement(side: .left)
    private let right = SidebarPlacement(side: .right)

    func testTheSideIsSavedAndDefaultsToTheLeft() {
        let defaults = UserDefaults(suiteName: "SidebarPlacementTests")!
        defaults.removePersistentDomain(forName: "SidebarPlacementTests")
        XCTAssertEqual(SidebarSide.load(from: defaults), .left)
        SidebarSide.right.save(to: defaults)
        XCTAssertEqual(SidebarSide.load(from: defaults), .right)
        defaults.set("middle", forKey: SidebarSide.defaultsKey)
        XCTAssertEqual(SidebarSide.load(from: defaults), .left, "an unknown value falls back")
        defaults.removePersistentDomain(forName: "SidebarPlacementTests")
    }

    func testOppositeIsTheOtherSide() {
        XCTAssertEqual(SidebarSide.left.opposite, .right)
        XCTAssertEqual(SidebarSide.right.opposite, .left)
        for side in SidebarSide.allCases { XCTAssertEqual(side.opposite.opposite, side) }
    }

    func testEachPieceTakesItsEdge() {
        XCTAssertEqual(left.sidebarEdge, .left)
        XCTAssertEqual(right.sidebarEdge, .right)
        XCTAssertEqual(left.cardSidebarEdge, .left, "⌘S cuts the card beside the sidebar")
        XCTAssertEqual(right.cardSidebarEdge, .right)
        XCTAssertEqual(left.resizeHandleEdge, .right, "the handle is on the inner edge")
        XCTAssertEqual(right.resizeHandleEdge, .left)
        XCTAssertEqual(left.libraryRailEdge, .left, "the rail keeps to the window's edge")
        XCTAssertEqual(right.libraryRailEdge, .right)
        XCTAssertEqual(left.hoverPreviewEdge, .right, "previews open over the page")
        XCTAssertEqual(right.hoverPreviewEdge, .left)
    }

    func testTrafficLightsStayAtTheTopLeft() {
        XCTAssertEqual(left.trafficLightsEdge, .left)
        XCTAssertEqual(right.trafficLightsEdge, .left)
        XCTAssertTrue(left.trafficLightsInSidebar)
        XCTAssertFalse(right.trafficLightsInSidebar)
    }

    func testSpaceSwipesStayNatural() {
        XCTAssertFalse(left.mirrorsSpaceSwipe)
        XCTAssertFalse(right.mirrorsSpaceSwipe)
    }

    func testTheLeftLayoutIsUnchanged() {
        // The formulas BrowserView used before P3.14.
        XCTAssertEqual(left.inward, 1)
        for reveal in [0, 0.37, 1.0] {
            XCTAssertEqual(left.sidebarOffset(reveal: reveal, width: 228), (reveal - 1) * 228, accuracy: 1e-9)
        }
        let growth = LibrarySidebarGrowth(from: 228, shown: 322)
        XCTAssertEqual(left.sidebarOffset(reveal: 1, width: 416, growth: growth), growth.sidebarOffset(width: 416))
        XCTAssertEqual(left.pageOffset(slide: 50, growth: growth), 50 + growth.pageOffset)
        XCTAssertEqual(left.resizedWidth(start: 228, translation: 30), 258)
    }

    func testTheSidebarHidesThroughItsOwnEdge() {
        // Hidden, it is a full width past the window's edge; shown, in place.
        XCTAssertEqual(left.sidebarOffset(reveal: 0, width: 228), -228)
        XCTAssertEqual(right.sidebarOffset(reveal: 0, width: 228), 228)
        XCTAssertEqual(right.sidebarOffset(reveal: 1, width: 228), 0)
        XCTAssertEqual(right.sidebarOffset(reveal: 0.5, width: 228), 114)
        XCTAssertEqual(right.inward, -1)
    }

    func testThePageSlidesAwayFromTheSidebar() {
        // ⌘S showing: the wide card moves away from the sidebar's edge.
        XCTAssertGreaterThan(left.pageOffset(slide: 80), 0)
        XCTAssertLessThan(right.pageOffset(slide: 80), 0)
        XCTAssertEqual(right.pageOffset(slide: 80), -80)
        XCTAssertEqual(right.pageOffset(slide: 0), 0)
    }

    func testTheLibraryWideningIsMirrored() {
        let growth = LibrarySidebarGrowth(from: 228, shown: 322)
        // Left: the rail comes in from the left edge and the page moves right.
        XCTAssertLessThan(left.sidebarOffset(reveal: 1, width: 416, growth: growth), 0)
        XCTAssertGreaterThan(left.pageOffset(slide: 0, growth: growth), 0)
        // Right: the rail comes in from the right edge and the page moves left.
        XCTAssertEqual(right.sidebarOffset(reveal: 1, width: 416, growth: growth), 94)
        XCTAssertEqual(right.pageOffset(slide: 0, growth: growth), -94)
        let settled = LibrarySidebarGrowth(from: 228, shown: 416)
        XCTAssertEqual(right.sidebarOffset(reveal: 1, width: 416, growth: settled), 0)
    }

    func testResizingFollowsTheInnerEdge() {
        // On the right, dragging the inner edge left (negative) widens the sidebar.
        XCTAssertEqual(right.resizedWidth(start: 228, translation: -30), 258)
        XCTAssertEqual(right.resizedWidth(start: 258, translation: 20), 238)
        XCTAssertEqual(right.resizedWidth(start: 228, translation: -10_000), SidebarWidth.clamped(10_000), "clamped")
    }

    func testThePeekStripIsAtTheSidebarsEdge() {
        let window = 1200.0, strip = 4.0, dismiss = 264.0
        XCTAssertTrue(left.revealsPeek(x: 2, windowWidth: window, revealWidth: strip))
        XCTAssertFalse(left.revealsPeek(x: 1198, windowWidth: window, revealWidth: strip))
        XCTAssertTrue(right.revealsPeek(x: 1198, windowWidth: window, revealWidth: strip))
        XCTAssertTrue(right.revealsPeek(x: 1196, windowWidth: window, revealWidth: strip))
        XCTAssertFalse(right.revealsPeek(x: 1195, windowWidth: window, revealWidth: strip))
        XCTAssertFalse(right.revealsPeek(x: 2, windowWidth: window, revealWidth: strip))
        XCTAssertFalse(right.revealsPeek(x: 1201, windowWidth: window, revealWidth: strip), "outside the window")

        XCTAssertFalse(left.dismissesPeek(x: 200, windowWidth: window, dismissWidth: dismiss))
        XCTAssertTrue(left.dismissesPeek(x: 300, windowWidth: window, dismissWidth: dismiss))
        XCTAssertFalse(right.dismissesPeek(x: 1000, windowWidth: window, dismissWidth: dismiss), "over the floating sidebar")
        XCTAssertTrue(right.dismissesPeek(x: 900, windowWidth: window, dismissWidth: dismiss))
        XCTAssertTrue(right.dismissesPeek(x: 300, windowWidth: window, dismissWidth: dismiss), "far into the page")
    }
}
