import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 38: Create a Space in the sidebar, opened from the pull past the
/// last space or from New Space, and the pager pages it in
/// (docs/arc-recordings/2026-11-06-space-swipe-feel-and-new-space.md).
final class Wave38ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w38-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private final class Clock {
        var now: TimeInterval = 100
    }

    private func makePager(_ clock: Clock, ids: [Space.ID], focused: Space.ID) -> SpacePagerController {
        let pager = SpacePagerController()
        pager.clock = { clock.now }
        pager.sync(spaceIDs: ids, focused: focused, animated: false)
        return pager
    }

    // MARK: The pull

    func testAFullPullPastTheLastSpaceAsksForANewSpace() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[1])
        pager.beginSwipe()
        clock.now += 0.2
        pager.swipe(byPoints: -0.15 * 228, pageWidth: 228)
        let pull = try! XCTUnwrap(pager.overscroll(at: clock.now))
        XCTAssertTrue(pull.isVisible)
        XCTAssertFalse(pull.isArmed)
        clock.now += 0.4
        pager.swipe(byPoints: -0.2 * 228, pageWidth: 228)
        XCTAssertTrue(try XCTUnwrap(pager.overscroll(at: clock.now)).isArmed)
        XCTAssertEqual(pager.endSwipe(), SpaceCreationSession.pageID)
    }

    func testAShortPullSpringsBack() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[1])
        pager.beginSwipe()
        clock.now += 0.3
        pager.swipe(byPoints: -0.15 * 228, pageWidth: 228)
        XCTAssertEqual(pager.endSwipe(), ids[1])
        XCTAssertNil(pager.overscroll(at: clock.now + 2), "the icon leaves with the page")
    }

    func testNoPullOnCreateASpacesOwnPage() {
        let clock = Clock()
        let ids = [UUID(), SpaceCreationSession.pageID]
        let pager = makePager(clock, ids: ids, focused: ids[1])
        pager.beginSwipe()
        clock.now += 0.5
        pager.swipe(byPoints: -100, pageWidth: 228)
        XCTAssertNil(pager.overscroll(at: clock.now))
        XCTAssertEqual(pager.endSwipe(), SpaceCreationSession.pageID, "it springs back onto the page")
    }

    // MARK: Paging the page in

    func testOpeningThePageFadesTheThemeInsteadOfSliding() {
        let clock = Clock()
        let ids = [UUID(), UUID(), UUID()]
        let pager = makePager(clock, ids: ids, focused: ids[0])
        let pages = SpaceCreationSession.pages(spaces: ids)
        pager.sync(spaceIDs: pages, focused: SpaceCreationSession.pageID, animated: true, fade: 0.25)
        XCTAssertEqual(pager.paging.targetPage, 3)
        XCTAssertFalse(pager.isAnimating, "no slide across the spaces in between")
        XCTAssertTrue(pager.drivesTheme)
        let start = try! XCTUnwrap(pager.transition(at: clock.now))
        XCTAssertEqual(start.from, ids[0])
        XCTAssertEqual(start.to, SpaceCreationSession.pageID)
        XCTAssertEqual(start.fraction, 0, accuracy: 1e-9)
        let middle = try! XCTUnwrap(pager.transition(at: clock.now + 0.125))
        XCTAssertGreaterThan(middle.fraction, 0.5, "eased out")
        XCTAssertLessThan(middle.fraction, 1)
        XCTAssertEqual(pager.visiblePages(at: clock.now, focused: SpaceCreationSession.pageID).map(\.id), [SpaceCreationSession.pageID])
    }

    func testCancelFadesBackToTheLastSpace() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let pager = makePager(clock, ids: SpaceCreationSession.pages(spaces: ids), focused: SpaceCreationSession.pageID)
        pager.sync(spaceIDs: ids, focused: ids[1], animated: true, fade: 0.4)
        XCTAssertEqual(pager.paging.pageCount, 2)
        XCTAssertEqual(pager.paging.targetPage, 1)
        let fade = try! XCTUnwrap(pager.transition(at: clock.now + 0.2))
        XCTAssertEqual(fade.from, SpaceCreationSession.pageID)
        XCTAssertEqual(fade.to, ids[1])
    }

    func testASwipeBackFromThePageClosesItOnlyOnceItRests() {
        let clock = Clock()
        let ids = [UUID(), UUID()]
        let pager = makePager(clock, ids: SpaceCreationSession.pages(spaces: ids), focused: SpaceCreationSession.pageID)
        pager.beginSwipe()
        clock.now += 0.4
        pager.swipe(byPoints: 160, pageWidth: 228)
        XCTAssertEqual(pager.endSwipe(), ids[1])
        var closed = false
        pager.whenSettled { closed = !pager.restsOnCreationPage }
        XCTAssertFalse(closed, "the page is still sliding out")
        XCTAssertTrue(pager.isAnimating)
    }

    // MARK: The model

    func testNewSpaceOpensInTheSidebarNotASheet() {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let main = model.space(in: window)
        model.store.setSpaceTheme(main.id, theme: .black)
        XCTAssertNil(model.executeCommand(.createSpace, commandID: nil))
        let session = try! XCTUnwrap(model.spaceCreation)
        XCTAssertEqual(session.window, window)
        XCTAssertEqual(session.origin, .command)
        XCTAssertEqual(session.draft.name, "")
        XCTAssertTrue(model.isCreatingSpace(in: window))
        XCTAssertFalse(model.isCreatingSpace(in: SidebarWindowID()))
        XCTAssertEqual(model.space(in: window).id, main.id, "the window keeps its space underneath")
        XCTAssertEqual(model.shownTheme(in: window), .arcDefault, "the window wears the draft's theme")
        model.spaceCreation?.draft.theme = .white
        XCTAssertEqual(model.pageTheme(SpaceCreationSession.pageID), .white)
        XCTAssertEqual(model.shownTheme(in: window), .white)
        XCTAssertEqual(model.pageTheme(main.id), .black)
    }

    func testTypingANameDoesNotRedrawTheWindow() {
        let model = makeModel()
        model.beginSpaceCreation()
        var changed = false
        withObservationTracking {
            _ = model.isCreatingSpace(in: nil)
            _ = model.shownTheme(in: nil)
            _ = model.pageTheme(SpaceCreationSession.pageID)
        } onChange: { changed = true }
        model.spaceCreation?.draft.name = "Rea"
        model.spaceCreation?.draft.iconName = "book.fill"
        XCTAssertFalse(changed, "only the page reads the name and icon")
        XCTAssertEqual(model.spaceCreation?.draft.name, "Rea")
        model.spaceCreation?.draft.theme = .white
        XCTAssertTrue(changed, "a theme edit recolours the window")
    }

    func testCancelLeavesTheSidebarAsItWas() {
        let model = makeModel()
        let before = model.store.spaces.map(\.id)
        model.beginSpaceCreation()
        model.spaceCreation?.draft.name = "Unsaved"
        model.cancelSpaceCreation()
        XCTAssertNil(model.spaceCreation)
        XCTAssertEqual(model.store.spaces.map(\.id), before)
    }

    func testCreateMakesTheSpaceFromThePage() {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        model.beginSpaceCreation(in: window, origin: .overscroll)
        XCTAssertEqual(model.spaceCreation?.origin, .overscroll)
        var draft = try! XCTUnwrap(model.spaceCreationDraft)
        draft.name = "Reading"
        draft.iconName = "book.fill"
        model.spaceCreationDraft = draft
        let space = try! XCTUnwrap(model.createSpace(from: try! XCTUnwrap(model.spaceCreationDraft)))
        XCTAssertNil(model.spaceCreation)
        XCTAssertEqual(model.space(in: window).id, space.id)
        XCTAssertEqual(model.store.spaces(in: space.profileID).last?.id, space.id, "where the page was")
    }

    func testNewSpaceFromTheLibraryLeavesTheLibrary() {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        model.toggleLibrary(in: window)
        XCTAssertNotNil(model.librarySection(in: window))
        model.beginSpaceCreation(in: window)
        XCTAssertNil(model.librarySection(in: window), "the page shows in the sidebar the Library covered")
        XCTAssertTrue(model.isCreatingSpace(in: window))
    }
}
