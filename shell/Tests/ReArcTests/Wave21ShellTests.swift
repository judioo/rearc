import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 21: space swipes and the themed window, changing a space's profile,
/// drag-to-split, tab-to-search, the boost library and external links.
final class Wave21ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w21-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    // MARK: Space pager

    private final class Clock {
        var now: TimeInterval = 100
    }

    private func makePager(_ clock: Clock, ids: [Space.ID], focused: Space.ID) -> SpacePagerController {
        let pager = SpacePagerController()
        pager.clock = { clock.now }
        pager.sync(spaceIDs: ids, focused: focused, animated: false)
        return pager
    }

    func testSwipePastHalfwayReturnsTheNextSpace() {
        let clock = Clock()
        let ids = [UUID(), UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[0])
        XCTAssertFalse(pager.isAnimating)

        pager.beginSwipe()
        XCTAssertTrue(pager.isAnimating && pager.isSwipeDriven)
        for _ in 0..<6 {
            clock.now += 0.1
            pager.swipe(byPoints: -30, pageWidth: 300)
        }
        let pages = pager.visiblePages(at: clock.now, focused: ids[0])
        XCTAssertEqual(pages.map(\.id), [ids[0], ids[1]], "both neighbours draw mid-swipe")
        XCTAssertEqual(pages[0].offset, -0.6, accuracy: 1e-9)
        XCTAssertEqual(pager.endSwipe(), ids[1])
        XCTAssertTrue(pager.isAnimating, "the spring keeps drawing after release")

        // The window then focuses that space; syncing to it does not restart anything.
        pager.sync(spaceIDs: ids, focused: ids[1], animated: true)
        XCTAssertEqual(pager.paging.targetPage, 1)
    }

    func testThemeFollowsTheSwipe() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let themes = [ids[0]: SpaceTheme.black, ids[1]: SpaceTheme.white]
        let pager = makePager(clock, ids: ids, focused: ids[0])
        XCTAssertNil(pager.palette(at: clock.now, theme: { themes[$0] }, darkAppearance: false), "no swipe, no blend")
        pager.beginSwipe()
        clock.now += 0.5
        pager.swipe(byPoints: -150, pageWidth: 300)
        let palette = try! XCTUnwrap(pager.palette(at: clock.now, theme: { themes[$0] }, darkAppearance: false))
        XCTAssertEqual(palette.accent.red, 0.5, accuracy: 1e-9, "halfway between black and white")
    }

    func testReduceMotionSwitchesOnReleaseWithoutSliding() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[0])
        pager.reduceMotion = true
        pager.beginSwipe()
        clock.now += 0.5
        pager.swipe(byPoints: -200, pageWidth: 300)
        XCTAssertEqual(pager.visiblePages(at: clock.now, focused: ids[0]).map(\.id), [ids[0]], "the page does not move")
        XCTAssertEqual(pager.endSwipe(), ids[1])
        XCTAssertFalse(pager.isAnimating)

        pager.sync(spaceIDs: ids, focused: ids[0], animated: true)
        XCTAssertFalse(pager.isAnimating, "keyboard switches do not slide either")
    }

    func testKeyboardSwitchSpringsAndAProfileChangeSnaps() {
        let clock = Clock()
        let ids = [UUID(), UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[0])
        pager.sync(spaceIDs: ids, focused: ids[2], animated: true)
        XCTAssertTrue(pager.isAnimating)
        XCTAssertFalse(pager.isSwipeDriven, "the theme crossfades for non-swipe switches")
        clock.now += 0.05
        XCTAssertGreaterThan(pager.visiblePages(at: clock.now, focused: ids[2]).count, 1)

        let other = [UUID(), UUID()]
        pager.sync(spaceIDs: other, focused: other[1], animated: true)
        XCTAssertFalse(pager.isAnimating)
        XCTAssertEqual(pager.paging.targetPage, 1)
        XCTAssertEqual(pager.paging.pageCount, 2)
    }

    func testSwipeSelectsTheSpaceThroughTheModel() {
        var second: Space!
        let model = makeModel { store in
            second = store.addSpace(name: "Second")
        }
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let clock = Clock()
        let ids = model.store.spaces(in: model.store.activeProfileID).map(\.id)
        let pager = makePager(clock, ids: ids, focused: model.space(in: window).id)
        pager.beginSwipe()
        clock.now += 0.4
        pager.swipe(byPoints: -250, pageWidth: 300)
        if let id = pager.endSwipe() { model.selectSpace(id) }
        XCTAssertEqual(model.space(in: window).id, second.id)
    }
}
