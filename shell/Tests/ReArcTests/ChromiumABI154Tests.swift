import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// ABI 1.54: dockable DevTools frontends choose their Dock side and lay out
/// the page; the shell follows (engine/docs/C-ABI.md "Dockable DevTools").
@MainActor
final class ChromiumABI154Tests: XCTestCase {
    private final class Opener: DevToolsOpening {
        var closed: [UInt64] = []
        func openDevTools(for tab: Tab, engine: any WebEngine) -> String? { nil }
        func closeDevTools(frontendTabID: UInt64) { closed.append(frontendTabID) }
    }

    private final class Presenter: BrowserWindowPresenting {
        var devTools: [String] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
        func presentDevToolsWindow(for tabID: Tab.ID) { devTools.append("present") }
        func dismissDevToolsWindow(for tabID: Tab.ID) { devTools.append("dismiss") }
        func focusBrowserWindow(_ id: SidebarWindowID) {}
    }

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-a154-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-a154-\(UUID().uuidString)")!
        return model
    }

    func testDockingNeedsMinor54TheFeatureAndDevTools() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 53, hasFeature: { _ in true }).devToolsDocking)
        let current = ChromiumCapabilities(abiMinorVersion: 54, hasFeature: { _ in true })
        XCTAssertTrue(current.devToolsDocking)
        XCTAssertTrue(current.summary.hasSuffix("page_theme_color=1 devtools_docking=1"))
        for missing in ["devtools_docking", "devtools"] {
            XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 54, hasFeature: { $0 != missing }).devToolsDocking)
        }
        XCTAssertFalse(ChromiumCapabilities.none.devToolsDocking)
    }

    /// Chrome's ApplyDevToolsContentsResizingStrategy, case by case.
    func testPageFrameFollowsChromesResizingStrategy() {
        let area = CGSize(width: 1000, height: 500)
        XCTAssertEqual(DevToolsDockLayout(side: .right, inTabTabID: 1).pageFrame(in: area), CGRect(x: 0, y: 0, width: 1000, height: 500),
                       "no bounds yet: the page fills the area")
        XCTAssertEqual(DevToolsDockLayout(side: .right, inTabTabID: 1, pageBounds: CGRect(x: 0, y: 0, width: 445, height: 500))
            .pageFrame(in: area), CGRect(x: 0, y: 0, width: 445, height: 500))
        XCTAssertEqual(DevToolsDockLayout(side: .left, inTabTabID: 1, pageBounds: CGRect(x: 555, y: 0, width: 445, height: 500))
            .pageFrame(in: area), CGRect(x: 555, y: 0, width: 445, height: 500))
        XCTAssertEqual(DevToolsDockLayout(side: .right, inTabTabID: 1, pageBounds: CGRect(x: 0, y: 0, width: 990, height: 500))
            .pageFrame(in: area).width, 750, "right dock keeps DevTools 250 wide")
        XCTAssertEqual(DevToolsDockLayout(side: .bottom, inTabTabID: 1, pageBounds: CGRect(x: 0, y: 0, width: 1000, height: 480))
            .pageFrame(in: area).height, 428, "bottom dock keeps DevTools 72 high")
        XCTAssertEqual(DevToolsDockLayout(side: .undocked, inTabTabID: 2, pageBounds: CGRect(x: 313, y: 67, width: 375, height: 133))
            .pageFrame(in: area), CGRect(x: 313, y: 67, width: 375, height: 133), "device mode in the toolbox")
        XCTAssertEqual(DevToolsDockLayout(side: .right, inTabTabID: 1, pageBounds: CGRect(x: 4, y: 4, width: 0, height: 0))
            .pageFrame(in: area), CGRect(x: 0, y: 0, width: 1000, height: 500), "empty off the origin: full")
        XCTAssertTrue(DevToolsDockLayout(side: .right, inTabTabID: 1, pageBounds: .zero).pageFrame(in: area).isEmpty,
                      "empty at the origin hides the page")
        XCTAssertEqual(DevToolsDockLayout(side: .left, inTabTabID: 1, pageBounds: CGRect(x: 1200, y: 0, width: 400, height: 900))
            .pageFrame(in: CGSize(width: 800, height: 400)), CGRect(x: 800, y: 0, width: 400, height: 400), "clamped to the area")
    }

    func testTheFrontendsDockSideMovesItBetweenTheTabAndItsWindow() {
        let model = makeModel()
        let opener = Opener(), presenter = Presenter()
        model.devToolsOpener = opener
        model.windowPresenter = presenter
        model.devToolsDockable = true
        let tab = model.openInNewTab(URL(string: "https://inspect.test/")!)
        let frontend = model.engineHost.engine(for: model.store.addTab(kind: .today, title: "F", url: URL(string: "about:blank")!),
                                               profileID: model.store.activeProfileID)
        model.store.selectTab(tab.id)
        model.attachDevTools(frontend, frontendTabID: 7, for: tab.id)
        XCTAssertNil(model.dockedDevTools(for: tab.id), "no shell pane for a dockable frontend")
        let initial = model.devToolsInTab(for: tab.id)
        XCTAssertTrue(initial?.view === frontend && initial?.layout.pageBounds == nil,
                      "before its first report the frontend sits behind the full page")

        model.devToolsDockChanged(frontendTabID: 7, layout: DevToolsDockLayout(
            side: .left, inTabTabID: 7, pageBounds: CGRect(x: 555, y: 0, width: 445, height: 500)))
        XCTAssertEqual(model.devToolsInTab(for: tab.id)?.layout.side, .left)
        XCTAssertTrue(presenter.devTools.isEmpty, "docked sides stay in the tab")

        model.devToolsDockChanged(frontendTabID: 7, layout: DevToolsDockLayout(
            side: .undocked, inTabTabID: 0, pageBounds: CGRect(x: 555, y: 0, width: 445, height: 500)))
        XCTAssertEqual(model.devTools.session(for: tab.id)?.placement, .window)
        XCTAssertEqual(presenter.devTools, ["present"])
        let alone = model.devToolsInTab(for: tab.id)
        XCTAssertTrue(alone?.view == nil && alone?.layout.pageBounds == nil, "undocked without a toolbox: the page fills the area")

        let toolbox = model.engineHost.engine(for: model.store.addTab(kind: .today, title: "T", url: URL(string: "about:blank")!),
                                              profileID: model.store.activeProfileID)
        model.attachDevToolsToolbox(toolbox, toolboxTabID: 8, for: tab.id)
        model.devToolsDockChanged(frontendTabID: 7, layout: DevToolsDockLayout(
            side: .undocked, inTabTabID: 8, pageBounds: CGRect(x: 313, y: 67, width: 375, height: 133)))
        XCTAssertTrue(model.devToolsInTab(for: tab.id)?.view === toolbox, "device mode: the toolbox behind the page")
        XCTAssertEqual(presenter.devTools, ["present"], "a bounds change keeps the window")

        model.devToolsDockChanged(frontendTabID: 7, layout: DevToolsDockLayout(side: .bottom, inTabTabID: 7))
        XCTAssertEqual(presenter.devTools, ["present", "dismiss"], "⇧⌘D docks it back")
        XCTAssertTrue(model.devToolsInTab(for: tab.id)?.view === frontend)
        model.devToolsDockChanged(frontendTabID: 99, layout: DevToolsDockLayout(side: .undocked, inTabTabID: 0))
        XCTAssertEqual(presenter.devTools.count, 2, "another frontend's report changes nothing")

        model.devToolsToolboxClosed(8)
        XCTAssertNil(model.devToolsToolboxes[tab.id])
        model.closeDevTools(for: tab.id)
        XCTAssertEqual(opener.closed, [7])
        XCTAssertNil(model.devToolsInTab(for: tab.id))
    }

    func testDockableFrontendsHaveNoShellDockMenuItems() {
        let model = makeModel()
        XCTAssertTrue(ShellMenus.developer(model).flatMap { $0 }.contains { $0.title == "Dock Developer Tools" })
        model.devToolsDockable = true
        let titles = ShellMenus.developer(model).flatMap { $0 }.map(\.title)
        XCTAssertFalse(titles.contains("Dock Developer Tools") || titles.contains("Open Developer Tools in a Window"),
                       "the frontend's ⋮ menu has Dock side, as in Chrome")
        XCTAssertEqual(titles.first, "Developer Tools")
    }

    func testAKeyADevToolsFrontendTakesNeverPrompts() {
        let router = ShortcutRouter()
        router.pageHasFocus = { _ in true }
        router.awaitsPageVerdicts = true
        var prompts: [String] = []
        router.performMenuKey = { _ in true }
        router.onPrompt = { prompts.append($0.id) }
        // ⇧⌘D is Arc's website-first Show/Hide Toolbar and DevTools' toggle dock.
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        XCTAssertFalse(router.handleKeyDown(key))
        router.pageVerdict(keyCode: 2, modifiers: [.command, .shift], consumed: true, promptsAgain: false)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertFalse(router.arming.isArmed("toggleToolbar"))
        XCTAssertFalse(router.handleKeyDown(key))
        router.pageVerdict(keyCode: 2, modifiers: [.command, .shift], consumed: true)
        XCTAssertEqual(prompts, ["toggleToolbar"], "a page that takes it still prompts")
    }
}
