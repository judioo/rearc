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
}
