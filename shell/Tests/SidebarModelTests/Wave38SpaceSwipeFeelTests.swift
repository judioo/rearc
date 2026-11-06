import XCTest
@testable import SidebarModel

/// Wave 38: the space swipe's colour, the pull past the last space and the
/// inline Create a Space draft
/// (docs/arc-recordings/2026-11-06-space-swipe-feel-and-new-space.md).
final class Wave38SpaceSwipeFeelTests: XCTestCase {

    private func color(_ hex: Int) -> SpaceColor {
        SpaceColor(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private func assertColor(_ actual: SpaceColor, _ expected: SpaceColor, within tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.red, expected.red, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: tolerance, file: file, line: line)
    }

    // MARK: Colour at a given progress

    func testTheColourIsTheMixAtThePagesFraction() {
        // §2.1: the top of the sidebar went #C0E57B → #62EBA9; at half a page it read #8FE691.
        let from = color(0xC0E57B), to = color(0x62EBA9)
        var paging = SpacePaging(pageCount: 2, page: 0)
        paging.beginTracking(at: 0)
        paging.track(by: 0.5, at: 0.5)
        let pages = paging.visiblePages(at: 0.5)
        XCTAssertEqual(pages.fraction, 0.5, accuracy: 1e-9)
        assertColor(ThemeGradient.crossfade(from, to, progress: pages.fraction), color(0x8FE691), within: 3 / 255)
    }

    func testTheColourMovesWithEveryStepOfTheFingers() {
        var paging = SpacePaging(pageCount: 3, page: 0)
        paging.beginTracking(at: 0)
        var last = 0.0
        for step in 1...9 {
            paging.track(by: 0.1, at: Double(step) * 0.016)
            let fraction = paging.visiblePages(at: Double(step) * 0.016).fraction
            XCTAssertEqual(fraction, Double(step) * 0.1, accuracy: 1e-9, "no jump at the end: the colour is the page")
            XCTAssertGreaterThan(fraction, last)
            last = fraction
        }
    }

    func testTheColourHoldsWhileThePageRubberBandsPastAnEnd() {
        var paging = SpacePaging(pageCount: 2, page: 1)
        paging.beginTracking(at: 0)
        paging.track(by: 0.3, at: 0.2)
        let pages = paging.visiblePages(at: 0.2)
        XCTAssertEqual(pages.from, 1)
        XCTAssertEqual(pages.to, 1)
        XCTAssertEqual(pages.fraction, 0)
        XCTAssertGreaterThan(paging.overscroll(at: 0.2), 0)
    }

    // MARK: Pull past the last space

    func testOverscrollIsOnlyPastTheLastPage() {
        var paging = SpacePaging(pageCount: 3, page: 2)
        XCTAssertEqual(paging.overscroll(at: 0), 0)
        paging.beginTracking(at: 0)
        paging.track(by: -0.4, at: 0.1)
        XCTAssertEqual(paging.overscroll(at: 0.1), 0, "pulling back toward the spaces")
        paging.track(by: 0.6, at: 0.2)
        XCTAssertGreaterThan(paging.overscroll(at: 0.2), 0)
        var first = SpacePaging(pageCount: 3, page: 0)
        first.beginTracking(at: 0)
        first.track(by: -0.3, at: 0.1)
        XCTAssertEqual(first.overscroll(at: 0.1), 0, "past the first space there is nothing to make")
    }

    func testTheIconSlidesInParksAndFills() {
        XCTAssertFalse(SpaceOverscroll(stretch: 0.01).isVisible)
        let entering = SpaceOverscroll(stretch: 0.02)
        XCTAssertEqual(entering.reveal, 0, accuracy: 1e-9)
        XCTAssertEqual(entering.centerInset, -13, accuracy: 1e-9, "just past the trailing edge")
        let parked = SpaceOverscroll(stretch: 0.07)
        XCTAssertEqual(parked.reveal, 1, accuracy: 1e-9)
        XCTAssertEqual(parked.centerInset, 26.5, accuracy: 1e-9)
        XCTAssertEqual(SpaceOverscroll(stretch: 0.2).centerInset, 26.5, accuracy: 1e-9, "it stays parked")
        // §2.3: the ring was ≈ 60 % drawn at 14 pt of stretch on a 228 pt sidebar.
        XCTAssertEqual(SpaceOverscroll(stretch: 14.0 / 228).ring, 0.61, accuracy: 0.02)
        XCTAssertFalse(SpaceOverscroll(stretch: 0.099).isArmed)
        XCTAssertTrue(SpaceOverscroll(stretch: 0.1).isArmed)
        XCTAssertEqual(SpaceOverscroll(stretch: 0.3).ring, 1)
        XCTAssertEqual(SpaceOverscroll(stretch: -1).stretch, 0)
    }

    func testTheThresholdTakesAQuarterPageOfFingerTravel() {
        func stretch(after pages: Double) -> Double {
            var paging = SpacePaging(pageCount: 2, page: 1)
            paging.beginTracking(at: 0)
            paging.track(by: pages, at: 0.3)
            return paging.overscroll(at: 0.3)
        }
        XCTAssertFalse(SpaceOverscroll(stretch: stretch(after: 0.2)).isArmed)
        XCTAssertTrue(SpaceOverscroll(stretch: stretch(after: 0.3)).isArmed, "≈ 60 pt of a 228 pt sidebar")
    }

    // MARK: Pages coming and going

    func testAddingAPageAtTheEndKeepsTheView() {
        var paging = SpacePaging(pageCount: 2, page: 1)
        paging.setPageCount(3, at: 0)
        XCTAssertEqual(paging.pageCount, 3)
        XCTAssertEqual(paging.position(at: 0), 1)
        XCTAssertFalse(paging.isAnimating(at: 0))
        paging.go(to: 2, pageCount: 3, animated: false, at: 0)
        XCTAssertEqual(paging.position(at: 0), 2)
        paging.setPageCount(2, at: 1)
        XCTAssertEqual(paging.targetPage, 1, "the removed page's place goes to the last space")
    }

    func testAPageCountChangeKeepsASpringAndATrackingFinger() {
        var springing = SpacePaging(pageCount: 3, page: 0)
        springing.go(to: 1, pageCount: 3, animated: true, at: 0)
        let position = springing.position(at: 0.05), velocity = springing.velocity(at: 0.05)
        springing.setPageCount(4, at: 0.05)
        XCTAssertEqual(springing.position(at: 0.05), position, accuracy: 1e-9)
        XCTAssertEqual(springing.velocity(at: 0.05), velocity, accuracy: 1e-9)
        XCTAssertEqual(springing.targetPage, 1)

        var tracking = SpacePaging(pageCount: 2, page: 1)
        tracking.beginTracking(at: 0)
        tracking.track(by: 0.2, at: 0.1)
        let shown = tracking.position(at: 0.1)
        tracking.setPageCount(3, at: 0.1)
        XCTAssertEqual(tracking.position(at: 0.1), shown, accuracy: 1e-9)
        XCTAssertTrue(tracking.isTracking)
    }

    // MARK: Create a Space draft

    func testTheDraftOpensBlankOnTheBuiltInTheme() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        var draft = SpaceDraft.blank(in: store)
        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.iconName, "")
        XCTAssertEqual(draft.theme, .arcDefault)
        XCTAssertEqual(draft.profileID, store.activeProfileID)
        XCTAssertFalse(draft.canCreate(in: store), "Create stays off until a name is typed")
        draft.name = "  Reading "
        XCTAssertTrue(draft.canCreate(in: store))
        let space = try! XCTUnwrap(store.createSpace(from: draft))
        XCTAssertEqual(space.name, "Reading")
        XCTAssertEqual(space.iconName, "circle.fill", "no icon chosen: Arc's plain dot")
        XCTAssertEqual(store.activeSpaceID, space.id)
    }

    func testTheSessionIsAPageAfterTheSpacesOfItsWindow() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let window = SidebarWindowID(), other = SidebarWindowID()
        let session = SpaceCreationSession(draft: .blank(in: store), window: window, origin: .overscroll)
        let ids = [UUID(), UUID()]
        XCTAssertEqual(SpaceCreationSession.pages(spaces: ids), ids + [SpaceCreationSession.pageID])
        XCTAssertFalse(ids.contains(SpaceCreationSession.pageID))
        XCTAssertTrue(session.isShown(in: window))
        XCTAssertFalse(session.isShown(in: other))
        XCTAssertTrue(SpaceCreationSession(draft: .blank(in: store), window: nil, origin: .command).isShown(in: other))
    }

    func testTheThemeFadesAsArcDoes() {
        XCTAssertLessThan(SpaceCreationSession.fadeDuration(opening: .overscroll), 0.05, "≈ 2 frames after the pull")
        XCTAssertEqual(SpaceCreationSession.fadeDuration(opening: .command), 0.25)
        XCTAssertEqual(SpaceCreationSession.fadeDuration(opening: nil), 0.4, "Cancel")
    }
}
