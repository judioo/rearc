import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Records default-browser requests; never touches LaunchServices.
private final class FakeDefaultBrowser: DefaultBrowserSetting {
    var canBecomeDefault = true
    var isDefault = false
    var result: Error?
    private(set) var requests = 0

    func makeDefault(_ completion: @escaping (Error?) -> Void) {
        requests += 1
        if result == nil { isDefault = true }
        completion(result)
    }
}

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

    func testASoleSpaceCanChooseAnotherProfile() {
        let model = makeModel()
        let work = model.store.addProfile(name: "Work")
        model.requestSpaceProfileChange(model.store.activeSpaceID, to: work.id)
        XCTAssertNotNil(model.pendingSpaceProfileChange)
        model.confirmSpaceProfileChange()
        XCTAssertEqual(model.store.activeSpace.profileID, work.id)
    }

    func testSpaceCreationUsesSettingAndAllowsPerSpaceOverride() throws {
        let model = makeModel()
        let suite = "rearc-container-policy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        model.externalLinkDefaults = defaults
        model.newSpaceContainerPolicy = .ownContainer
        XCTAssertEqual(NewSpaceContainerPolicy.load(from: defaults), .ownContainer)
        model.beginSpaceCreation()
        XCTAssertEqual(model.spaceCreation?.draft.createsOwnContainer, true)
        model.cancelSpaceCreation()
        XCTAssertEqual(model.store.profiles.count, 1)
        let own = model.addSpace()
        XCTAssertNotEqual(own.profileID, model.store.profiles[0].id)
        model.newSpaceContainerPolicy = .sharedDefault
        model.beginSpaceCreation()
        XCTAssertEqual(model.spaceCreation?.draft.createsOwnContainer, false)
        XCTAssertEqual(model.spaceCreation?.draft.profileID, model.store.profiles[0].id)
        var draft = try XCTUnwrap(model.spaceCreation?.draft)
        draft.name = "Override"
        draft.createsOwnContainer = true
        let space = try XCTUnwrap(model.createSpace(from: draft))
        XCTAssertNotEqual(space.profileID, model.store.profiles[0].id)
        XCTAssertNotEqual(space.profileID, own.profileID)
    }

    func testNewContainerReloadsBackgroundTabsAndEverySplitPane() throws {
        let model = makeModel()
        let store = model.store
        let original = store.activeProfileID
        let space = store.activeSpaceID
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let background = store.addTab(kind: .pinned, title: "Background", url: URL(string: "https://background.test")!)
        let split = try XCTUnwrap(store.splitTab(a.id, with: b.id))
        store.selectTab(a.id)
        model.loadSelectedIfNeeded()
        _ = model.engineHost.engine(for: background, profileID: original)
        model.createContainerForSpace(space)
        let container = store.activeProfileID
        XCTAssertNotEqual(container, original)
        XCTAssertEqual(store.split(withID: split.id)?.tabs.map(\.id), split.tabs.map(\.id))
        for tab in [a, b, background] {
            XCTAssertNil(model.engineHost.engine(forTabID: tab.id, profileID: original))
            let engine = try XCTUnwrap(model.engineHost.engine(forTabID: tab.id, profileID: container))
            XCTAssertEqual(engine.pagePrompts.profileID, container)
            XCTAssertEqual((engine as? WKEngine)?.profileContext.profileID, container)
        }
    }

    func testSpaceLinkPeekLittleArcAndSplitKeepOriginContainerWhenAnotherSpaceIsActive() throws {
        let model = makeModel()
        let store = model.store
        let suite = "rearc-container-links-\(UUID())"
        model.externalLinkDefaults = UserDefaults(suiteName: suite)!
        defer { model.externalLinkDefaults.removePersistentDomain(forName: suite) }
        model.littleArcOnModifiedClick = true
        let originSpace = store.activeSpaceID
        model.createContainerForSpace(originSpace)
        let originProfile = store.activeProfileID
        let tab = store.addTab(kind: .today, title: "Origin", url: URL(string: "https://origin.test")!)
        model.selectTab(tab.id)
        let engine = try XCTUnwrap(model.engineHost.engine(forTabID: tab.id, profileID: originProfile))
        let prompts = engine.pagePrompts
        let other = store.addSpace(name: "Other", profileID: store.profiles[0].id)
        model.selectSpace(other.id)
        let link = URL(string: "https://account.test")!
        engine.linkPeekHandler?(link)
        XCTAssertEqual(model.peekSession?.profileID, originProfile)
        model.dismissPeek()
        (engine as? LittleArcLinkOpening)?.littleArcLinkHandler?(link)
        let little = try XCTUnwrap(store.littleArcWindows.last)
        XCTAssertEqual(little.profileID, originProfile)
        XCTAssertEqual(model.littleArcEngine(for: little.id).pagePrompts.profileID, originProfile)
        model.openLinkInNewSplit(link, from: prompts)
        let split = try XCTUnwrap(store.splitContaining(tabID: tab.id)?.split)
        for pane in split.tabs {
            XCTAssertEqual(store.spaceContaining(tabID: pane.id), originSpace)
            XCTAssertEqual(model.profileID(for: pane), originProfile)
            XCTAssertEqual(model.engineHost.engine(forTabID: pane.id, profileID: originProfile)?.pagePrompts.profileID, originProfile)
        }
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
        let previousTabID = model.store.selectedTabID
        model.submitCommandBar()
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarSiteSearch, "dismissing clears the pill")
        XCTAssertNotEqual(model.store.selectedTabID, previousTabID, "⌘T creates the result's tab on submit")
        XCTAssertEqual(model.store.selectedTab?.url.host(), "www.youtube.com")
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

    // MARK: Default browser and external links

    func testSetAsDefaultBrowserAsksOnceAndExplainsRefusals() {
        let model = makeModel()
        let fake = FakeDefaultBrowser()
        model.defaultBrowser = fake

        fake.canBecomeDefault = false
        model.setAsDefaultBrowser()
        XCTAssertEqual(fake.requests, 0)
        XCTAssertEqual(model.defaultBrowserMessage, "Run ReArc from its app bundle to make it your default browser.")

        fake.canBecomeDefault = true
        model.defaultBrowserMessage = nil
        XCTAssertNil(model.executeCommand(.setAsDefaultBrowser, commandID: nil))
        XCTAssertEqual(fake.requests, 1)
        XCTAssertTrue(model.isDefaultBrowser)
        XCTAssertNil(model.defaultBrowserMessage)

        model.setAsDefaultBrowser()
        XCTAssertEqual(fake.requests, 1, "already the default: nothing to ask")
        XCTAssertEqual(model.defaultBrowserMessage, "ReArc is already your default browser.")

        let refused = FakeDefaultBrowser()
        refused.result = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "declined"])
        model.defaultBrowser = refused
        model.setAsDefaultBrowser()
        XCTAssertEqual(model.defaultBrowserMessage, "ReArc could not become the default browser: declined")
    }

    func testSystemDefaultBrowserIsNeverSetFromATestProcess() {
        // The test runner is no app bundle, so the real service refuses before LaunchServices.
        XCTAssertFalse(SystemDefaultBrowser().canBecomeDefault)
        XCTAssertFalse(SystemDefaultBrowser().isDefault)
    }

    func testExternalLinksOpenInLittleArcOrTheCurrentSpace() throws {
        let model = makeModel()
        model.externalLinkDefaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-w21-\(UUID().uuidString)"))
        model.externalLinkDestination = .littleArc
        let page = URL(string: "https://example.com/news")!
        model.openExternalURL(page)
        XCTAssertEqual(model.store.littleArcLiveWindows.last?.url, page)
        let tabCount = model.store.displayTabs().count

        model.externalLinkDestination = .activeSpace
        let other = URL(string: "https://example.org/")!
        model.openExternalURL(other)
        XCTAssertEqual(model.store.selectedTab?.url, other)
        XCTAssertEqual(model.store.displayTabs().count, tabCount + 1)

        model.openExternalURL(other)
        XCTAssertEqual(model.store.displayTabs().count, tabCount + 1, "the open tab is focused again")
        model.openExternalURL(URL(string: "javascript:alert(1)")!)
        XCTAssertEqual(model.store.displayTabs().count, tabCount + 1)
        XCTAssertNil(model.executeCommand(.setExternalLinkDestination(.littleArc), commandID: nil))
        XCTAssertEqual(model.externalLinkDestination, .littleArc)
    }

    func testLinksBeforeTheModelWaitForIt() {
        let router = ExternalLinkRouter()
        let page = URL(string: "https://example.net/")!
        router.receive(page)
        let model = makeModel()
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w21-\(UUID().uuidString)")!
        model.externalLinkDestination = .activeSpace
        router.attach(model)
        XCTAssertEqual(model.store.selectedTab?.url, page)
    }

    /// Chromium's early window attaches its model before the engine is ready:
    /// held links wait for `release`, then open in that model.
    func testHeldLinksWaitForReleaseEvenWithAModel() {
        let router = ExternalLinkRouter()
        router.hold()
        let first = URL(string: "https://example.net/first")!
        let second = URL(string: "https://example.net/second")!
        router.receive(first)
        let model = makeModel()
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w21-\(UUID().uuidString)")!
        model.externalLinkDestination = .activeSpace
        let before = model.store.selectedTab?.url
        router.attach(model)
        router.receive(second)
        XCTAssertEqual(model.store.selectedTab?.url, before)
        XCTAssertEqual(router.pendingURLs, [first, second])
        router.release()
        XCTAssertEqual(router.pendingURLs, [])
        XCTAssertEqual(model.store.selectedTab?.url, second)
        let third = URL(string: "https://example.net/third")!
        router.receive(third)
        XCTAssertEqual(model.store.selectedTab?.url, third)
    }
}
