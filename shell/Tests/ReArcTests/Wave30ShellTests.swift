import AppKit
import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 30: shortcut routing while a page has focus, ReArc's menus on Arc's
/// keys, and the shortcut side effects (Copy URL toasts, ⌘T/⌘L, ⌘D, Cycle Tab).
final class Wave30ShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w30-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w30-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w30-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-w30-\(UUID().uuidString)"))
        return model
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// A router whose page always has focus and whose menu records the keys it runs.
    private func makeRouter(verdicts: Bool = true) -> (ShortcutRouter, () -> [UInt16], () -> [String]) {
        let router = ShortcutRouter()
        router.pageHasFocus = { _ in true }
        router.awaitsPageVerdicts = verdicts
        var ran: [UInt16] = []
        var prompts: [String] = []
        router.performMenuKey = { ran.append($0.keyCode); return true }
        router.onPrompt = { prompts.append($0.id) }
        return (router, { ran }, { prompts })
    }

    // MARK: Routing

    func testArcWinsShortcutsRunBeforeThePageSeesThem() {
        let (router, ran, _) = makeRouter()
        XCTAssertTrue(router.handleKeyDown(key("c", [.command, .shift], keyCode: 8)), "⇧⌘C is taken from the page")
        XCTAssertTrue(router.handleKeyDown(key("l", .command, keyCode: 37)), "⌘L is taken from the page")
        XCTAssertTrue(router.handleKeyDown(key("1", .control, keyCode: 18)), "⌃1 is taken from the page")
        XCTAssertEqual(ran(), [8, 37, 18])
        XCTAssertTrue(router.pending.isEmpty)
    }

    func testAKeyThePageIgnoresRunsTheMenuShortcut() {
        let (router, ran, prompts) = makeRouter()
        XCTAssertFalse(router.handleKeyDown(key("s", .command, keyCode: 1)), "⌘S goes to the page first")
        XCTAssertFalse(router.handleKeyDown(key("r", .command, keyCode: 15)))
        XCTAssertEqual(router.pending.count, 2)
        router.pageVerdict(keyCode: 1, modifiers: .command, consumed: false)
        router.pageVerdict(keyCode: 15, modifiers: .command, consumed: false)
        XCTAssertEqual(ran(), [1, 15])
        XCTAssertTrue(prompts().isEmpty)
        XCTAssertTrue(router.pending.isEmpty)
    }

    func testAWebsiteFirstKeyThePageTakesPromptsThenRunsOnTheSecondPress() {
        let (router, ran, prompts) = makeRouter()
        let start = Date()
        XCTAssertFalse(router.handleKeyDown(key("s", .command, keyCode: 1), now: start))
        router.pageVerdict(keyCode: 1, modifiers: .command, consumed: true)
        XCTAssertEqual(prompts(), ["showSidebar"])
        XCTAssertTrue(ran().isEmpty, "the page kept the first press")
        XCTAssertTrue(router.handleKeyDown(key("s", .command, keyCode: 1), now: start.addingTimeInterval(1)), "the second press is Arc's")
        XCTAssertEqual(ran(), [1])
        XCTAssertFalse(router.arming.isArmed("showSidebar"), "one second press per prompt")
    }

    func testAWebsiteWinsKeyThePageTakesStaysWithThePage() {
        let (router, ran, prompts) = makeRouter()
        XCTAssertFalse(router.handleKeyDown(key("f", .command, keyCode: 3)))
        router.pageVerdict(keyCode: 3, modifiers: .command, consumed: true)
        XCTAssertTrue(ran().isEmpty && prompts().isEmpty)
        XCTAssertFalse(router.handleKeyDown(key("f", .command, keyCode: 3)), "never armed")
    }

    func testKeysWithoutPageFocusOrModifiersAreLeftToAppKit() {
        let (router, ran, _) = makeRouter()
        router.pageHasFocus = { _ in false }
        XCTAssertFalse(router.handleKeyDown(key("c", [.command, .shift], keyCode: 8)), "the command bar's field keeps its keys")
        router.pageHasFocus = { _ in true }
        XCTAssertFalse(router.handleKeyDown(key("s", [], keyCode: 1)), "typing is not a shortcut")
        router.isEnabled = false
        XCTAssertFalse(router.handleKeyDown(key("l", .command, keyCode: 37)))
        XCTAssertTrue(ran().isEmpty && router.pending.isEmpty)
    }

    func testWithoutEngineVerdictsNothingWaits() {
        let (router, ran, _) = makeRouter(verdicts: false)
        XCTAssertFalse(router.handleKeyDown(key("s", .command, keyCode: 1)))
        XCTAssertTrue(router.pending.isEmpty)
        router.pageVerdict(keyCode: 1, modifiers: .command, consumed: false)
        XCTAssertTrue(ran().isEmpty, "a verdict without a forwarded key is ignored")
    }

    func testStaleKeysAreDroppedAndVerdictsMatchTheirKey() {
        let (router, ran, _) = makeRouter()
        let start = Date()
        _ = router.handleKeyDown(key("r", .command, keyCode: 15), now: start)
        _ = router.handleKeyDown(key("s", .command, keyCode: 1), now: start.addingTimeInterval(ShortcutRouter.pendingLifetime + 1))
        XCTAssertEqual(router.pending.map(\.event.keyCode), [1], "the old ⌘R never came back")
        router.pageVerdict(keyCode: 15, modifiers: .command, consumed: false)
        XCTAssertTrue(ran().isEmpty)
        router.pageVerdict(keyCode: 1, modifiers: [.command, .shift], consumed: false)
        XCTAssertTrue(ran().isEmpty, "modifiers must match")
    }

    func testPageContentIsChromiumsWidgetViewOrAWebView() {
        XCTAssertTrue(ShortcutRouter.isWebContent(WKWebView(frame: .zero)))
        XCTAssertFalse(ShortcutRouter.isWebContent(NSTextView(frame: .zero)))
        XCTAssertFalse(ShortcutRouter.isWebContent(nil))
        let event = key("c", [.command, .shift], keyCode: 8)
        let combination = ShortcutRouter.combination(for: event)
        XCTAssertEqual(combination?.0, .character("c"))
        XCTAssertEqual(combination?.1, [.shift, .command])
        XCTAssertEqual(ShortcutRouter.combination(for: key("\u{F701}", [.command, .option], keyCode: 125))?.0, .downArrow)
    }

    func testCapabilitiesGateKeyEquivalentEventsOnABI142() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 41, hasFeature: all).keyEquivalentEvents)
        let current = ChromiumCapabilities(abiMinorVersion: 42, hasFeature: all)
        XCTAssertTrue(current.keyEquivalentEvents)
        XCTAssertTrue(current.summary.contains("key_equivalent_events=1"))
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 42, hasFeature: { $0 != "key_equivalent_events" }).keyEquivalentEvents)
    }

    // MARK: Menus on Arc's keys

    func testShellMenusUseArcsKeys() {
        let model = makeModel()
        let groups = ShellMenus.navigation(model) + ShellMenus.find(model) + ShellMenus.copyLink(model) + ShellMenus.zoom(model)
            + ShellMenus.tabNavigation(model) + ShellMenus.split(model) + ShellMenus.documents(model) + ShellMenus.tabSwitcher(model)
            + ShellMenus.tabPositions(model) + ShellMenus.spaces(model) + ShellMenus.sidebarItems(model) + ShellMenus.library(model)
            + ShellMenus.developer(model) + ShellMenus.capture(model) + ShellMenus.printing(model)
        let items = groups.flatMap { $0 }
        let expected: [String: String] = [
            "Back": "goBack", "Forward": "goForward", "Reload Page": "reloadPage", "Reload Ignoring Cache": "forceReloadPage",
            "Stop Loading": "stopLoading", "Find…": "find", "Find Next": "findNext", "Find Previous": "findPrevious",
            "Jump to Selection": "jumpToSelection", "Copy URL": "copyCurrentURL", "Copy URL as Markdown": "copyCurrentURLMarkdown",
            "Copy URL as Quote": "copyCurrentURLAsQuote", "Zoom In": "zoomIn", "Zoom Out": "zoomOut", "Actual Size": "resetZoom",
            "Next Tab": "selectNextTab", "Previous Tab": "selectPreviousTab", "Cycle Tab Backward": "cycleTabBackward",
            "Cycle Tab Forward": "cycleTabForward", "Add Split View": "addSplitView", "Close this Split Pane": "removeSplitView",
            "New Note": "newNote", "New Easel": "newEasel", "Open Little ReArc in Space": "openTabIn", "Tab Switcher (Forward)": "cycleNextTab",
            "Tab Switcher (Backward)": "cyclePreviousTab", "Tab 1": "goToSidebarItem1", "Last Tab": "goToSidebarItem9",
            "Next Space": "focusNextSpace", "Previous Space": "focusPreviousSpace", "Space 1": "goToSpace1",
            "Pin/Unpin Tab": "pinTab", "Clear Unpinned Tabs": "clearExplore", "View Library": "viewLibrary",
            "Developer Tools": "developerTools", "Inspect Elements": "inspectElements", "JavaScript Console": "javaScriptConsole",
            "Capture": "capturePage", "Print…": "printPage",
        ]
        for (title, id) in expected {
            let item = items.first { $0.title == title && !$0.isAlternate }
            XCTAssertEqual(item?.arcShortcut?.id, id, "\(title)")
        }
        let alternates = items.filter(\.isAlternate).compactMap(\.arcShortcut?.id)
        XCTAssertEqual(Set(alternates), ["goBack_Alternate", "goForward_Alternate", "zoomIn_Plus", "zoomOut_Shift", "developerTools_Alternate"])
        // No two visible items share keys.
        let keys = items.filter { $0.key != nil }.map { "\($0.menuKeyEquivalent)|\($0.modifiers.rawValue)" }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    /// The Chromium path's NSMenu matches real key presses: a shifted
    /// shortcut is stored as its shifted character without Shift in the mask.
    func testAppKitMenusMatchShiftedShortcutsAsRealKeysSendThem() {
        final class Target: NSObject {
            var hits: [String] = []
            @objc func run(_ sender: NSMenuItem) { hits.append(sender.title) }
        }
        _ = NSApplication.shared  // the menu sends its actions through NSApp
        let model = makeModel()
        let target = Target()
        let menu = NSMenu(title: "Main")
        let groups = ShellMenus.copyLink(model) + ShellMenus.navigation(model) + ShellMenus.find(model) + ShellMenus.split(model)
            + ShellMenus.capture(model) + ShellMenus.tabNavigation(model) + ShellMenus.sidebarItems(model) + ShellMenus.library(model)
            + ShellMenus.zoom(model)
        for item in groups.flatMap({ $0 }) where item.key != nil {
            let equivalent = item.appKitKeyEquivalent
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run(_:)), keyEquivalent: equivalent.key)
            menuItem.keyEquivalentModifierMask = equivalent.mask
            menuItem.isHidden = item.isAlternate
            menuItem.allowsKeyEquivalentWhenHidden = item.isAlternate
            menuItem.target = target
            menu.addItem(menuItem)
        }
        // As a US keyboard reports them: charactersIgnoringModifiers keeps Shift.
        let presses: [(String, String, NSEvent.ModifierFlags, UInt16, String)] = [
            ("C", "C", [.command, .shift], 8, "Copy URL"),
            ("Ç", "C", [.command, .shift, .option], 8, "Copy URL as Markdown"),
            ("\u{3}", "C", [.command, .shift, .control], 8, "Copy URL as Quote"),
            ("R", "R", [.command, .shift], 15, "Reload Ignoring Cache"),
            ("G", "G", [.command, .shift], 5, "Find Previous"),
            ("+", "+", [.control, .shift], 24, "Add Split View"),
            ("_", "_", [.control, .shift], 27, "Close this Split Pane"),
            ("@", "@", [.command, .shift], 19, "Capture"),
            ("K", "K", [.command, .shift], 40, "Clear Unpinned Tabs"),
            ("L", "L", [.command, .shift], 37, "View Library"),
            ("+", "+", [.command, .shift], 24, "Zoom In"),
            ("\u{F701}", "\u{F701}", [.command, .option, .numericPad, .function], 125, "Next Tab"),
            ("\u{F702}", "\u{F702}", [.command, .numericPad, .function], 123, "Back"),
        ]
        for (characters, ignoring, flags, code, title) in presses {
            target.hits = []
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!
            XCTAssertTrue(menu.performKeyEquivalent(with: event), title)
            XCTAssertEqual(target.hits, [title])
        }
        XCTAssertEqual(ShellMenuItem.appKitKeyEquivalent("c", [.command, .shift]).key, "C")
        XCTAssertEqual(ShellMenuItem.appKitKeyEquivalent("c", [.command, .shift]).mask, .command)
        XCTAssertEqual(ShellMenuItem.appKitKeyEquivalent("\u{8}", [.command, .shift]).mask, [.command, .shift], "Delete keeps Shift")
    }

    // MARK: Side effects

    func testCopyURLCleansTrackersWithArcsToasts() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Arc", url: URL(string: "https://arc.test/a?utm_source=news&id=7")!)
        model.store.selectTab(tab.id)
        model.copyURL()
        XCTAssertEqual(model.linkPasteboard.string(forType: .string), "https://arc.test/a?id=7")
        XCTAssertEqual(model.toast?.message, "Copied a clean link without trackers")
        model.copyURL(format: .markdown)
        XCTAssertEqual(model.linkPasteboard.string(forType: .string), "[Arc](https://arc.test/a?id=7)")
        model.store.updateTab(tab.id, title: "Arc", url: URL(string: "https://arc.test/a")!)
        model.copyURL()
        XCTAssertEqual(model.toast?.message, "Copied Current URL")
    }

    func testCommandTThenEscapeLeavesNoTabAndCommandLToggles() {
        let model = makeModel()
        let page = model.store.addTab(kind: .today, title: "Page", url: URL(string: "https://page.test/")!)
        model.store.selectTab(page.id)
        let count = model.store.displayTabs().count

        model.newTab()
        XCTAssertTrue(model.isCommandBarPresented)
        model.dismissCommandBar()
        XCTAssertEqual(model.store.displayTabs().count, count, "Arc's ⌘T makes no tab until a result is chosen")
        XCTAssertEqual(model.store.selectedTabID, page.id)

        model.focusLocation()
        XCTAssertEqual(model.commandBarText, "https://page.test/", "⌘L shows the page's URL")
        model.focusLocation()
        XCTAssertFalse(model.isCommandBarPresented, "⌘L again closes the bar")

        model.newTab()
        model.commandBarText = "https://next.test/"
        model.submitCommandBar()
        XCTAssertEqual(model.store.displayTabs().count, count + 1, "a chosen result keeps ⌘T's tab")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://next.test/")
    }

    func testPinToastsNameTheSpace() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Docs", url: URL(string: "https://docs.test/")!)
        model.store.selectTab(tab.id)
        model.togglePin()
        XCTAssertEqual(model.toast?.message, "Pinned Tab to “Main”")
        model.togglePin()
        XCTAssertEqual(model.toast?.message, "Un-Pinned Tab from “Main”")
    }

    func testCycleTabGoesBackThroughVisitsAndForwardAgain() {
        let model = makeModel()
        let a = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        let b = model.store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test/")!)
        let c = model.store.addTab(kind: .today, title: "C", url: URL(string: "https://c.test/")!)
        for tab in [a, b, c] {
            model.selectTab(tab.id)
            Thread.sleep(forTimeInterval: 0.01)
        }
        model.cycleTabHistory(forward: false)
        XCTAssertEqual(model.store.selectedTabID, b.id)
        model.cycleTabHistory(forward: false)
        XCTAssertEqual(model.store.selectedTabID, a.id, "the order was fixed when the cycle began")
        model.cycleTabHistory(forward: true)
        XCTAssertEqual(model.store.selectedTabID, b.id)
        model.selectTab(c.id)
        model.cycleTabHistory(forward: false)
        XCTAssertEqual(model.store.selectedTabID, b.id, "a new visit starts a new cycle")
    }

    func testCloseThisSplitPaneClosesOnlyAPaneOfASplit() throws {
        let model = makeModel()
        let left = model.store.addTab(kind: .today, title: "L", url: URL(string: "https://l.test/")!)
        let right = model.store.addTab(kind: .today, title: "R", url: URL(string: "https://r.test/")!)
        model.selectTab(left.id)
        model.closeFocusedSplitPane()
        XCTAssertNotNil(model.store.tab(withID: left.id), "not in a split: nothing closes")
        _ = try XCTUnwrap(model.store.splitTab(right.id, with: left.id))
        model.store.selectTab(right.id)
        model.closeFocusedSplitPane()
        XCTAssertNil(model.store.tab(withID: right.id))
        XCTAssertNotNil(model.store.tab(withID: left.id))
    }
}
