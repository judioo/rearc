import XCTest
@testable import SidebarModel

/// Wave 21 pure models: space paging physics, the swipe axis lock and the
/// window theme palette.
final class Wave21ModelTests: XCTestCase {

    // MARK: Space paging

    /// Drags `pages` over `seconds` in even steps, starting at `start`.
    private func drag(_ paging: inout SpacePaging, pages: Double, seconds: Double, start: TimeInterval = 0, steps: Int = 10) -> TimeInterval {
        paging.beginTracking(at: start)
        for step in 1...steps {
            paging.track(by: pages / Double(steps), at: start + seconds * Double(step) / Double(steps))
        }
        return start + seconds
    }

    func testSlowDragPastHalfwayLandsOnTheNextPage() {
        var paging = SpacePaging(pageCount: 3, page: 0)
        let end = drag(&paging, pages: 0.6, seconds: 1.0)
        XCTAssertEqual(paging.position(at: end), 0.6, accuracy: 1e-9, "the page follows the fingers")
        XCTAssertEqual(paging.endTracking(at: end), 1)
        XCTAssertEqual(paging.targetPage, 1)
        XCTAssertTrue(paging.isAnimating(at: end + 0.05))
        let rest = try! XCTUnwrap(paging.restTime)
        XCTAssertEqual(paging.position(at: rest), 1, accuracy: 0.001)
        XCTAssertFalse(paging.isAnimating(at: rest + 0.05))
    }

    func testShortDragSnapsBackButAFlickPages() {
        var slow = SpacePaging(pageCount: 3, page: 1)
        var end = drag(&slow, pages: 0.2, seconds: 1.0)
        XCTAssertEqual(slow.endTracking(at: end), 1, "a slow short drag springs back")

        var flick = SpacePaging(pageCount: 3, page: 1)
        end = drag(&flick, pages: -0.2, seconds: 0.08)
        XCTAssertEqual(flick.endTracking(at: end), 0, "a fast flick projects onto the previous page")
        XCTAssertLessThan(flick.velocity(at: end), 0, "the spring keeps the release velocity")
    }

    func testOneSwipeMovesAtMostOnePage() {
        var paging = SpacePaging(pageCount: 5, page: 0)
        let end = drag(&paging, pages: 2.4, seconds: 0.1)
        XCTAssertEqual(paging.endTracking(at: end), 1)
    }

    func testEdgesRubberBandAndSpringBack() {
        var paging = SpacePaging(pageCount: 2, page: 0)
        let end = drag(&paging, pages: -3, seconds: 1.0)
        let shown = paging.position(at: end)
        XCTAssertLessThan(shown, 0)
        XCTAssertGreaterThan(shown, -0.35, "the overshoot never reaches the band limit")
        XCTAssertGreaterThan(shown, -3 * 0.2, "past the edge the page moves much less than the fingers")
        XCTAssertEqual(paging.endTracking(at: end), 0)
        XCTAssertEqual(paging.position(at: paging.restTime!), 0, accuracy: 0.001)

        var single = SpacePaging(pageCount: 1, page: 0)
        let singleEnd = drag(&single, pages: 0.5, seconds: 0.5)
        XCTAssertGreaterThan(single.position(at: singleEnd), 0, "one space still rubber-bands")
        XCTAssertEqual(single.endTracking(at: singleEnd), 0)
    }

    func testANewSwipeGrabsThePageMidSpring() {
        var paging = SpacePaging(pageCount: 3, page: 0)
        let end = drag(&paging, pages: 0.7, seconds: 0.5)
        paging.endTracking(at: end)
        let mid = end + 0.08
        let before = paging.position(at: mid)
        XCTAssertGreaterThan(before, 0.7)
        XCTAssertLessThan(before, 1.05)
        paging.beginTracking(at: mid)
        XCTAssertEqual(paging.position(at: mid), before, accuracy: 1e-9, "no jump when interrupted")
        paging.track(by: -0.6, at: mid + 0.5)
        XCTAssertEqual(paging.endTracking(at: mid + 0.5), 0, "the interrupting swipe pages back from its own origin")
    }

    func testCancelReturnsToTheOriginAndGoSnapsOrSprings() {
        var paging = SpacePaging(pageCount: 3, page: 1)
        let end = drag(&paging, pages: 0.8, seconds: 1)
        paging.cancelTracking(at: end)
        XCTAssertEqual(paging.targetPage, 1)

        paging.go(to: 2, pageCount: 3, animated: true, at: 10)
        XCTAssertEqual(paging.targetPage, 2)
        XCTAssertEqual(paging.position(at: 10), 1, accuracy: 0.05, "an animated switch starts where the page is")
        XCTAssertTrue(paging.isAnimating(at: 10.05))

        paging.go(to: 0, pageCount: 3, animated: false, at: 11)
        XCTAssertEqual(paging.position(at: 11), 0)
        XCTAssertFalse(paging.isAnimating(at: 11))

        paging.go(to: 7, pageCount: 4, animated: true, at: 12)
        XCTAssertEqual(paging.targetPage, 3, "a new page count snaps and clamps")
        XCTAssertEqual(paging.position(at: 12), 3)
    }

    func testVisiblePagesSplitTheFractionBetweenNeighbours() {
        var paging = SpacePaging(pageCount: 3, page: 1)
        paging.beginTracking(at: 0)
        paging.track(by: 0.25, at: 0.5)
        let pages = paging.visiblePages(at: 0.5)
        XCTAssertEqual(pages.from, 1)
        XCTAssertEqual(pages.to, 2)
        XCTAssertEqual(pages.fraction, 0.25, accuracy: 1e-9)
    }

    func testAxisLockDecidesOnceFromTheFirstPoints() {
        var lock = SwipeAxisLock()
        XCTAssertEqual(lock.add(dx: -2, dy: 0.5), .undecided)
        XCTAssertEqual(lock.add(dx: -5, dy: 1), .horizontal)
        XCTAssertEqual(lock.dx, -7)
        XCTAssertEqual(lock.add(dx: 0, dy: 40), .horizontal, "the decision sticks for the gesture")

        var vertical = SwipeAxisLock()
        XCTAssertEqual(vertical.add(dx: 4, dy: 5), .vertical, "a diagonal counts as scrolling")
    }

    // MARK: Theme palette

    func testPaletteBlendsTheThemeForEachAppearance() {
        let indigo = SpaceTheme.default
        let light = SpaceThemePalette(theme: indigo, darkAppearance: false)
        let dark = SpaceThemePalette(theme: indigo, darkAppearance: true)
        XCTAssertGreaterThan(light.top.relativeLuminance, indigo.relativeLuminance)
        XCTAssertGreaterThan(light.top.relativeLuminance, light.bottom.relativeLuminance, "light themes brighten toward the top")
        XCTAssertLessThan(dark.bottom.relativeLuminance, dark.top.relativeLuminance)
        XCTAssertLessThan(dark.top.relativeLuminance, indigo.relativeLuminance)
        XCTAssertEqual(light.accent, indigo)
        XCTAssertTrue(dark.prefersLightForeground)
    }

    func testForegroundFollowsTheBackgroundBrightness() {
        let pale = SpaceTheme(red: 0.95, green: 0.95, blue: 0.96)
        let ink = SpaceTheme(red: 0.15, green: 0.15, blue: 0.17)
        XCTAssertFalse(SpaceThemePalette(theme: pale, darkAppearance: false).prefersLightForeground)
        XCTAssertTrue(SpaceThemePalette(theme: ink, darkAppearance: false).prefersLightForeground)
        XCTAssertTrue(SpaceThemePalette(theme: pale, darkAppearance: true).prefersLightForeground)
    }

    func testPalettesMixForASwipe() {
        let a = SpaceThemePalette(theme: .black, darkAppearance: false)
        let b = SpaceThemePalette(theme: .white, darkAppearance: false)
        XCTAssertEqual(a.mixed(with: b, fraction: 0), a)
        XCTAssertEqual(a.mixed(with: b, fraction: 1), b)
        let half = a.mixed(with: b, fraction: 0.5)
        XCTAssertEqual(half.accent.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SpaceTheme.black.mixed(with: .white, fraction: 2), .white, "fractions clamp")
    }
}
