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

    // MARK: Changing a space's profile

    func testChangingASpaceProfileReloadsItsTabsInTheNewProfile() {
        let model = makeModel()
        let home = model.store.activeProfile
        let keep = model.store.activeSpace
        let moving = model.store.addSpace(name: "Moving")
        let work = model.store.addProfile(name: "Work")
        model.selectSpace(moving.id)
        let tab = model.store.addTab(kind: .today, title: "Mail", url: URL(string: "https://mail.test")!)
        model.selectTab(tab.id)
        XCTAssertNotNil(model.engineHost.engine(forTabID: tab.id, profileID: home.id))

        model.requestSpaceProfileChange(moving.id, to: work.id)
        let text = model.spaceProfileChangeMessage(model.pendingSpaceProfileChange!)
        XCTAssertEqual(text.title, "Move “Moving” to Work?")
        XCTAssertTrue(text.message.contains("1 tab reload in Work"))
        XCTAssertTrue(text.message.contains("stay in \(home.name)"))
        model.confirmSpaceProfileChange()
        XCTAssertNil(model.pendingSpaceProfileChange)

        XCTAssertEqual(model.store.space(withID: moving.id)?.profileID, work.id)
        XCTAssertNil(model.engineHost.engine(forTabID: tab.id, profileID: home.id), "the old profile's engine is closed")
        XCTAssertNotNil(model.engineHost.engine(forTabID: tab.id, profileID: work.id), "the selected tab reloads on the new profile")
        XCTAssertEqual(model.profileID(for: model.store.tab(withID: tab.id)!), work.id)
        XCTAssertEqual(model.store.spaces(in: home.id).map(\.id), [keep.id])
    }

    func testAProfileKeepsItsLastSpace() {
        let model = makeModel()
        let work = model.store.addProfile(name: "Work")
        model.requestSpaceProfileChange(model.store.activeSpaceID, to: work.id)
        XCTAssertNil(model.pendingSpaceProfileChange, "nothing to confirm when the move is refused")
        XCTAssertEqual(model.changeSpaceProfile(model.store.activeSpaceID, to: work.id), .lastSpaceInProfile)
    }

    // MARK: Drag to split

    func testDropToSplitUsesTheWindowsSelectionAsAnchor() {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let anchor = model.store.addTab(kind: .today, title: "Anchor", url: URL(string: "https://a.test")!)
        let dropped = model.store.addTab(kind: .today, title: "Dropped", url: URL(string: "https://b.test")!)
        model.selectTab(anchor.id)
        XCTAssertEqual(model.splitDropAnchor(in: window), anchor.id)
        XCTAssertTrue(model.canDropToSplit(dropped.id, in: window))
        XCTAssertTrue(model.dropToSplit(dropped.id, edge: .trailing, in: window))
        let split = model.activeSplit(in: window)
        XCTAssertEqual(split?.tabs.map(\.id), [anchor.id, dropped.id])
        XCTAssertEqual(model.splitDropAnchor(in: window), dropped.id, "the new pane is focused")
        XCTAssertNotNil(model.engineHost.engine(forTabID: dropped.id, profileID: model.store.activeProfileID))
        XCTAssertEqual(ContentSplitDropZone.frame(for: .trailing, in: CGSize(width: 800, height: 600)),
                       CGRect(x: 406, y: 6, width: 388, height: 588))
    }

    // MARK: Site search

    func testTabToSearchScopesTheCommandBarAndDeleteRestoresTheText() {
        let model = makeModel()
        model.newTab()
        model.commandBarText = "youtube cats"
        XCTAssertNil(model.commandBarSiteSearchSuggestion)
        XCTAssertFalse(model.enterCommandBarSiteSearch(), "Tab does nothing without a site name")

        model.commandBarText = "yout"
        XCTAssertEqual(model.commandBarSiteSearchSuggestion?.id, "youtube")
        XCTAssertTrue(model.enterCommandBarSiteSearch())
        XCTAssertEqual(model.commandBarSiteSearch?.id, "youtube")
        XCTAssertEqual(model.commandBarText, "")
        XCTAssertNil(model.commandBarSiteSearchSuggestion, "no second hint inside the pill")

        XCTAssertTrue(model.exitCommandBarSiteSearch())
        XCTAssertNil(model.commandBarSiteSearch)
        XCTAssertEqual(model.commandBarText, "yout", "the typed text comes back")

        model.enterCommandBarSiteSearch()
        model.commandBarText = "lofi beats"
        XCTAssertFalse(model.exitCommandBarSiteSearch(), "Delete edits the query while it has text")
        XCTAssertEqual(model.commandBarResults.first?.destinationURL?.absoluteString,
                       "https://www.youtube.com/results?search_query=lofi%20beats")
        let tabID = model.store.selectedTabID!
        model.submitCommandBar()
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarSiteSearch, "dismissing clears the pill")
        XCTAssertEqual(model.store.tab(withID: tabID)?.url.host(), "www.youtube.com")
    }

    func testCommandModeAndURLIntentsNeverOfferSiteSearch() {
        let model = makeModel()
        model.newTab()
        model.commandBarText = ">yo"
        XCTAssertNil(model.commandBarSiteSearchSuggestion)
        model.commandBarURLIntent = .peek
        model.commandBarText = "youtube"
        XCTAssertNil(model.commandBarSiteSearchSuggestion)
    }

    // MARK: Boost library

    func testBoostLibraryCreatesTogglesDuplicatesAndDeletes() throws {
        let model = makeModel()
        XCTAssertNil(model.executeCommand(.manageBoosts, commandID: nil))
        XCTAssertTrue(model.isBoostLibraryPresented, "View Boosts opens the library")

        XCTAssertEqual(model.createBoost(name: "", site: ""), "Enter a site to boost", "no page on screen and no site typed")
        XCTAssertNotNil(model.createBoost(name: "X", site: "nope"))
        XCTAssertNil(model.createBoost(name: "", site: "github.com"))
        var rows = model.boostLibraryRows()
        XCTAssertEqual(rows.map(\.name), ["Boost for github.com"])
        let id = rows[0].id

        model.setBoostEnabled(id, enabled: false)
        XCTAssertFalse(model.boostLibraryRows()[0].enabled)
        model.setBoostsMasterEnabled(false)
        XCTAssertFalse(model.boostsMasterEnabled)
        model.setBoostsMasterEnabled(true)

        let copy = try XCTUnwrap(model.duplicateBoost(id))
        XCTAssertTrue(model.renameBoost(copy, to: "Second"))
        rows = model.boostLibraryRows()
        XCTAssertEqual(rows.map(\.name), ["Boost for github.com", "Second"])

        model.deleteBoost(id)
        XCTAssertEqual(model.boostLibraryRows().map(\.id), [copy])

        let tab = model.store.addTab(kind: .today, title: "News", url: URL(string: "https://news.test/a")!)
        model.selectTab(tab.id)
        XCTAssertNil(model.createBoost(name: "Mine", site: ""), "an empty site boosts the page on screen")
        XCTAssertTrue(model.boostLibraryRows().contains { $0.name == "Mine" && $0.matchesCurrentPage })

        model.openBoostSite(copy)
        XCTAssertFalse(model.isBoostLibraryPresented)
        XCTAssertEqual(model.store.selectedTab?.url, URL(string: "https://github.com/"))
    }
}
