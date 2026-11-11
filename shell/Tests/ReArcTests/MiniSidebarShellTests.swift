import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The mini sidebar (⇧⌘S) in the shell: the key window's mode, ⌘S leaving
/// it alone, a hidden sidebar coming back for it, new windows, widths, the
/// traffic lights' placement, the menu item and the inline rename.
@MainActor
final class MiniSidebarShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-mini-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-mini-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-mini-links-\(UUID().uuidString)")!
        return model
    }

    private func keyWindow(_ model: BrowserViewModel) -> SidebarWindowID {
        let window = SidebarWindowID()
        model.openSidebarMode(for: window)
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        return window
    }

    func testCommandShiftSTogglesTheKeyWindowAndCommandSKeepsTheMode() {
        let model = makeModel()
        model.sidebarWidth = 300
        let window = keyWindow(model)
        XCTAssertEqual(model.sidebarWidth(in: window), 300)
        XCTAssertEqual(model.miniSidebarMenuTitle, "Show Mini Sidebar")

        model.toggleMiniSidebar()
        XCTAssertTrue(model.isMiniSidebar(in: window))
        XCTAssertEqual(model.sidebarWidth(in: window), CGFloat(MiniSidebarLayout.width))
        XCTAssertEqual(model.sidebarWidth, 300, "the user's width is kept for the full sidebar")
        XCTAssertEqual(model.miniSidebarMenuTitle, "Show Full Sidebar")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(model.sidebarMorph(in: window)?.from, 300, "the edge starts where it was")
            XCTAssertEqual(model.sidebarMorph(in: window)?.to, Double(MiniSidebarLayout.width))
        }

        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        XCTAssertTrue(model.isMiniSidebar(in: window), "⌘S hides the mini sidebar")
        model.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertTrue(model.isMiniSidebar(in: window), "and shows it again as it was")

        _ = model.executeCommand(.toggleMiniSidebar, commandID: nil)
        XCTAssertFalse(model.isMiniSidebar(in: window))
        XCTAssertEqual(model.sidebarWidth(in: window), 300)
    }

    func testCommandShiftSBringsAHiddenSidebarBackInTheNewMode() {
        let model = makeModel()
        let window = keyWindow(model)
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        model.toggleMiniSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertTrue(model.isMiniSidebar(in: window))
        XCTAssertNil(model.sidebarMorph(in: window), "⌘S's slide brings it in; no width morph")
    }

    func testAWindowOpenedFromAMiniWindowIsMiniAndAClosedOneIsForgotten() {
        let model = makeModel()
        let first = keyWindow(model)
        model.toggleMiniSidebar()
        let second = SidebarWindowID()
        model.openSidebarMode(for: second)
        XCTAssertTrue(model.isMiniSidebar(in: second))
        let restored = SidebarWindowID()
        model.openSidebarMode(for: restored, restoring: .full)
        XCTAssertFalse(model.isMiniSidebar(in: restored))
        model.forgetSidebarMode(for: first)
        XCTAssertFalse(model.sidebarModes.isRegistered(first))
    }

    func testTheTrafficLightsLeaveTheMiniColumn() {
        let model = makeModel()
        let window = keyWindow(model)
        XCTAssertTrue(model.sidebarPlacement(in: window).trafficLightsInSidebar)
        model.toggleMiniSidebar()
        XCTAssertFalse(model.sidebarPlacement(in: window).trafficLightsInSidebar)
        XCTAssertEqual(model.sidebarPlacement(in: window).side, model.sidebarSide)
    }

    func testTheLibraryIsAsWideInEitherMode() {
        let model = makeModel()
        let window = keyWindow(model)
        model.openLibrary(.archive, in: window)
        let full = model.sidebarWidth(in: window)
        model.toggleMiniSidebar(in: window)
        XCTAssertEqual(model.sidebarWidth(in: window), full)
        XCTAssertNil(model.sidebarMorph(in: window), "no width change, no morph")
    }

    func testTheViewMenuOffersItBesideTheSidebarToggle() throws {
        let model = makeModel()
        _ = keyWindow(model)
        let item = try XCTUnwrap(ShellMenus.miniSidebar(model).first)
        XCTAssertEqual(item.shownTitle, "Show Mini Sidebar")
        XCTAssertEqual(item.arcShortcut?.id, "toggleMiniSidebar")
        XCTAssertEqual(item.appKitKeyEquivalent.key, "S")
        XCTAssertEqual(item.appKitKeyEquivalent.mask, .command)
        item.action()
        XCTAssertEqual(item.shownTitle, "Show Full Sidebar")
    }

    func testRenameInAMiniSidebarAsksInsteadOfEditingInPlace() {
        let model = makeModel()
        _ = keyWindow(model)
        let tab = model.store.addTab(kind: .today, title: "Example", url: URL(string: "https://example.com")!)
        model.toggleMiniSidebar()
        model.beginRename(.tab(tab.id))
        XCTAssertNil(model.inlineRename)
        XCTAssertEqual(model.pendingRename, .tab(tab.id))
    }
}
