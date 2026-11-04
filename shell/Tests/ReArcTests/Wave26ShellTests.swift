import AppKit
import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 26: sidebar polish (pinned collapse, + menu, Copy URL formats,
/// unread, loading and crashed tabs).
@MainActor
final class Wave26ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w26-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w26-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w26-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-w26-\(UUID().uuidString)"))
        return model
    }

    private func titles(_ groups: [[ShellMenuItem]]) -> [String] { groups.flatMap { $0.map(\.title) } }

    // MARK: Pinned section

    func testPinnedSectionCollapsesPerWindowFromMenuAndCommand() {
        let model = makeModel()
        let windowA = SidebarWindowID(), windowB = SidebarWindowID()
        model.store.registerWindow(windowA)
        model.store.registerWindow(windowB)
        model.windowBecameKey(windowA)
        let space = model.store.activeSpaceID
        model.store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!)

        let items = ShellMenus.sidebarItems(model).flatMap { $0 }
        items.first { $0.title == "Collapse Pinned Section" }!.action()
        XCTAssertTrue(model.isPinnedSectionCollapsed(spaceID: space, in: windowA), "the key window collapses")
        XCTAssertFalse(model.isPinnedSectionCollapsed(spaceID: space, in: windowB))

        _ = model.executeCommand(.expandPinnedSection, commandID: nil)
        XCTAssertFalse(model.isPinnedSectionCollapsed(spaceID: space, in: windowA))
        model.togglePinnedSection(spaceID: space, in: windowB)
        XCTAssertTrue(model.isPinnedSectionCollapsed(spaceID: space, in: windowB))
        XCTAssertFalse(model.isPinnedSectionCollapsed(spaceID: space, in: windowA))

        let context = CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.first { $0.action == .collapsePinnedSection }!.isEnabled(in: context))
    }

    // MARK: + menu

    func testNewBoostCreatesForThePageOrOpensTheLibrary() {
        let model = makeModel()
        model.newBoost()
        XCTAssertTrue(model.isBoostLibraryPresented, "no page: the library's New Boost")
        model.isBoostLibraryPresented = false

        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://boost.test/page")!)
        model.store.selectTab(tab.id)
        let before = model.store.boostsMatchingPage(tab.url).count
        model.newBoost()
        XCTAssertEqual(model.store.boostsMatchingPage(tab.url).count, before + 1, "a boost for the page on screen")
        XCTAssertFalse(model.isBoostLibraryPresented)
        XCTAssertTrue(titles(ShellMenus.sidebarItems(model)).contains("New Boost"))
    }

    // MARK: Copy URL

    func testCopyURLFormatsWriteThePasteboardAndToast() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Docs (v2)", url: URL(string: "https://docs.test/a")!)
        model.store.selectTab(tab.id)

        model.copyURL()
        XCTAssertEqual(model.linkPasteboard.string(forType: .string), "https://docs.test/a")
        XCTAssertEqual(model.toast?.message, "Copied URL")

        model.copyURL(format: .markdown)
        XCTAssertEqual(model.linkPasteboard.string(forType: .string), "[Docs (v2)](https://docs.test/a)")
        XCTAssertEqual(model.toast?.message, "Copied URL as Markdown")

        _ = model.executeCommand(.copyAsQuote, commandID: nil)
        XCTAssertEqual(model.linkPasteboard.string(forType: .string), "> [Docs (v2)](https://docs.test/a)",
                       "a tab without a live page quotes the link")

        let menu = ShellMenus.sidebarItems(model).flatMap { $0 }
        let markdown = menu.first { $0.title == "Copy URL as Markdown" }
        XCTAssertEqual(markdown?.menuKeyEquivalent, "c")
        XCTAssertEqual(markdown?.modifiers, [.command, .shift, .option])
        XCTAssertNotNil(menu.first { $0.title == "Copy as Quote" })
    }

    // MARK: Unread

    func testBackgroundTitleChangeMarksAPinnedTabUnread() {
        let model = makeModel()
        let pinned = model.store.addTab(kind: .pinned, title: "Inbox", url: URL(string: "https://mail.test/")!)
        let other = model.store.addTab(kind: .today, title: "Other", url: URL(string: "https://other.test/")!)
        let engine = model.engineHost.engine(for: pinned, profileID: model.profileID(for: pinned))
        model.observedPageTitles[pinned.id] = "Inbox"
        model.store.selectTab(other.id)

        model.lastNavigationAt[pinned.id] = Date()
        model.pageTitleChanged("(1) Inbox", engine: engine, tabID: pinned.id)
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.isUnread, false, "right after a load the title is settling")

        model.lastNavigationAt[pinned.id] = Date(timeIntervalSinceNow: -30)
        model.pageTitleChanged("(2) Inbox", engine: engine, tabID: pinned.id)
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.isUnread, true)

        model.selectTab(pinned.id)
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.isUnread, false, "seeing it clears the dot")
        model.pageTitleChanged("(3) Inbox", engine: engine, tabID: pinned.id)
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.isUnread, false, "a title change on screen is seen")
    }

    // MARK: Loading and crashed tabs

    func testWebKitCrashShowsTheSadTabUntilReload() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Page", url: URL(string: "about:blank")!)
        let engine = try XCTUnwrap(model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)) as? WKEngine)
        XCTAssertEqual(model.tabActivity(tab.id), .idle)
        XCTAssertEqual(model.tabActivity(UUID()), .idle, "a tab without an engine is idle")

        engine.webViewWebContentProcessDidTerminate(engine.webView)
        XCTAssertEqual(model.tabActivity(tab.id), .crashed)
        XCTAssertFalse(engine.isLoading)

        engine.webView(engine.webView, didStartProvisionalNavigation: nil)
        XCTAssertEqual(model.tabActivity(tab.id), .loading(progress: engine.loadProgress), "Reload starts a new page")
    }

    // MARK: Split View

    func testFlipAndExpandCurrentSplitFromMenuAndCommandBar() throws {
        let model = makeModel()
        let window = SidebarWindowID()
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        let a = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        model.store.selectTab(a.id)
        model.addSplitView(orientation: .horizontal)
        let split = try XCTUnwrap(model.activeSplit(in: window))
        XCTAssertEqual(split.orientation, .horizontal)

        let items = ShellMenus.sidebarItems(model).flatMap { $0 }
        items.first { $0.title == "Flip Split Orientation" }!.action()
        XCTAssertEqual(model.store.split(withID: split.id)?.orientation, .vertical)
        _ = model.executeCommand(.flipSplitOrientation, commandID: nil)
        XCTAssertEqual(model.store.split(withID: split.id)?.orientation, .horizontal)

        items.first { $0.title == "Expand Current Split" }!.action()
        let current = try XCTUnwrap(model.store.split(withID: split.id))
        XCTAssertEqual(model.expandedSplitPane(current, in: window), current.focusTabID)
        XCTAssertEqual(model.visibleSplitPanes(current, in: window).map(\.id), [current.focusTabID])
        XCTAssertEqual(model.visibleSplitPanes(current, in: SidebarWindowID()).count, 2, "another window keeps the split")
        _ = model.executeCommand(.expandSplitPane, commandID: nil)
        XCTAssertNil(model.expandedSplitPane(current, in: window))

        let context = CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.first { $0.action == .expandSplitPane }!.isEnabled(in: context))
        model.unsplit(split.id)
        XCTAssertFalse(commands.first { $0.action == .flipSplitOrientation }!.isEnabled(in: context), "no split, no flip")
    }

    // MARK: Command bar

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String = "\t") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
    }

    func testInlineCompletionAcceptsAndBackspaceSuppressesIt() {
        let model = makeModel()
        model.newTab()
        model.commandBarText = "git"
        XCTAssertEqual(model.commandBarInlineCompletion, "github.com")
        XCTAssertEqual(model.commandBarInlineSuffix, "hub.com")
        XCTAssertEqual(model.commandBarResults.first?.destinationURL, URL(string: "https://github.com/"))
        model.commandBarText = "gi"
        XCTAssertNil(model.commandBarInlineSuffix, "deleting turns the completion off")
        model.commandBarText = "gith"
        XCTAssertEqual(model.commandBarInlineSuffix, "ub.com", "typing brings it back")
        XCTAssertTrue(model.acceptCommandBarInlineCompletion())
        XCTAssertEqual(model.commandBarText, "github.com")
        XCTAssertFalse(model.acceptCommandBarInlineCompletion())
        model.commandBarText = ">git"
        XCTAssertNil(model.commandBarInlineCompletion, "commands do not complete")
    }

    func testRoutingModifiersOpenNewTabSplitAndLittleArc() throws {
        let model = makeModel()
        let page = model.store.addTab(kind: .today, title: "Page", url: URL(string: "https://page.test/")!)
        model.store.selectTab(page.id)

        // ⌘L then ⌘↩: the page stays, the result opens in a new tab.
        model.focusLocation()
        model.commandBarText = "https://one.test/"
        model.submitCommandBar(route: .newTab)
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.store.tab(withID: page.id)?.url.absoluteString, "https://page.test/")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://one.test/")
        let one = try XCTUnwrap(model.store.selectedTab)

        // ⌘T then ⌥↩: the new tab becomes a pane next to the tab shown before.
        model.newTab()
        model.commandBarText = "https://two.test/"
        model.submitCommandBar(route: .splitView)
        let split = try XCTUnwrap(model.store.splitContaining(tabID: one.id)?.split)
        XCTAssertEqual(Set(split.tabs.map(\.url.absoluteString)), ["https://one.test/", "https://two.test/"])
        XCTAssertEqual(model.store.selectedItemID, split.id)

        // ⌘T then ⇧↩: Little Arc, and the empty new tab goes away.
        model.selectTab(page.id)
        let tabsBefore = model.store.displayTabs().count
        model.newTab()
        model.commandBarText = "https://three.test/"
        model.submitCommandBar(route: .littleArc)
        XCTAssertEqual(model.store.littleArcLiveWindows.last?.url.absoluteString, "https://three.test/")
        XCTAssertEqual(model.store.displayTabs().count, tabsBefore, "no blank tab left behind")
        XCTAssertEqual(model.store.selectedTabID, page.id)
    }

    func testCtrlTabSwitcherCyclesRecentTabsAndCommitsOnRelease() {
        let model = makeModel()
        var clock = Date(timeIntervalSince1970: 5_000)
        model.store.now = { clock }
        let a = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = model.store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let c = model.store.addTab(kind: .today, title: "C", url: URL(string: "https://c.test")!)
        for tab in [a, b, c] {
            clock += 5
            model.store.selectTab(tab.id)
        }

        XCTAssertTrue(model.handleTabSwitcherEvent(key(48, .control)))
        XCTAssertEqual(model.tabSwitcher?.highlighted.id, b.id)
        XCTAssertTrue(model.handleTabSwitcherEvent(key(48, .control)))
        XCTAssertEqual(model.tabSwitcher?.highlighted.id, a.id)
        XCTAssertTrue(model.handleTabSwitcherEvent(key(48, [.control, .shift], "\u{19}")))
        XCTAssertEqual(model.tabSwitcher?.highlighted.id, b.id, "Shift steps back")
        XCTAssertFalse(model.handleTabSwitcherEvent(flags([])), "the release passes through")
        XCTAssertNil(model.tabSwitcher)
        XCTAssertEqual(model.store.selectedTabID, b.id, "releasing Control picks the highlighted tab")

        XCTAssertTrue(model.handleTabSwitcherEvent(key(48, .control)))
        XCTAssertTrue(model.handleTabSwitcherEvent(key(53, .control, "\u{1b}")))
        XCTAssertNil(model.tabSwitcher, "Escape cancels")
        XCTAssertEqual(model.store.selectedTabID, b.id)
        XCTAssertFalse(model.handleTabSwitcherEvent(key(48, [])), "plain Tab is the page's")

        // The menu item (no Control held) switches at once to the previous tab.
        model.cycleRecentTabs(forward: true, controlHeld: false)
        XCTAssertNil(model.tabSwitcher)
        XCTAssertEqual(model.store.selectedTabID, c.id)
        XCTAssertEqual(titles(ShellMenus.tabSwitcher(model)), ["Tab Switcher (Forward)", "Tab Switcher (Backward)"])
    }
}
