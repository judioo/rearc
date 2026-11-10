import XCTest
import SidebarModel
@testable import ReArc

/// Split view's per-pane toolbar rows in the shell (SPLIT-VIEW §3.1): a click
/// focuses a pane and moves the controls, ⌘L and a pane's address aim at it,
/// and the row's ✕ closes or separates its pane.
@MainActor
final class SplitPaneToolbarShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Demo", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-pane-rows-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private func makeSplit(_ model: BrowserViewModel, panes: Int = 2) throws -> (SplitViewItem, [Tab]) {
        let tabs = (0..<panes).map { model.store.addTab(kind: .today, title: "Pane \($0)", url: URL(string: "https://pane\($0).test/page")!) }
        let split = try XCTUnwrap(model.store.createSplit(tabIDs: tabs.map(\.id), orientation: .horizontal))
        model.selectSplit(split.id, focusTabID: tabs[0].id)
        return (split, tabs)
    }

    private func layout(_ model: BrowserViewModel, _ splitID: SplitViewItem.ID) throws -> SplitPaneToolbarLayout {
        model.splitPaneToolbarLayout(try XCTUnwrap(model.store.split(withID: splitID)), in: nil)
    }

    func testClickingAPaneMovesTheControlsAndCommandLThere() throws {
        let model = makeModel()
        let (split, tabs) = try makeSplit(model)
        XCTAssertEqual(try layout(model, split.id).controlsPane, tabs[0].id)

        model.focusSplitPane(tabs[1].id, in: split.id)
        XCTAssertEqual(model.store.split(withID: split.id)?.focusTabID, tabs[1].id)
        XCTAssertEqual(try layout(model, split.id).controlsPane, tabs[1].id, "the controls move to the clicked pane")
        XCTAssertEqual(try layout(model, split.id).rows.count, 2, "every pane keeps its row")

        model.focusLocation()
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarTargetID, tabs[1].id, "⌘L edits the focused pane")
        XCTAssertEqual(model.commandBarText, "https://pane1.test/page")
        XCTAssertTrue(model.addressBarHasKeyboardFocus(for: tabs[1].id, in: nil))
        XCTAssertFalse(model.addressBarHasKeyboardFocus(for: tabs[0].id, in: nil), "only the edited pane reveals")

        model.dismissCommandBar()
        XCTAssertFalse(model.addressBarHasKeyboardFocus(for: tabs[1].id, in: nil), "dismissal releases the toolbar")
    }

    func testAPanesAddressEditsThatPane() throws {
        let model = makeModel()
        let (split, tabs) = try makeSplit(model)

        model.editAddress(ofPane: tabs[1].id, in: split.id)
        XCTAssertEqual(model.store.split(withID: split.id)?.focusTabID, tabs[1].id, "the pane takes focus")
        XCTAssertEqual(model.commandBarTargetID, tabs[1].id)

        model.editAddress(ofPane: tabs[0].id, in: split.id)
        XCTAssertTrue(model.isCommandBarPresented, "another pane's address retargets the open bar")
        XCTAssertEqual(model.commandBarTargetID, tabs[0].id)
        XCTAssertEqual(model.commandBarText, "https://pane0.test/page")
        XCTAssertTrue(model.addressBarHasKeyboardFocus(for: tabs[0].id, in: nil))
        XCTAssertFalse(model.addressBarHasKeyboardFocus(for: tabs[1].id, in: nil))

        model.editAddress(ofPane: tabs[0].id, in: split.id)
        XCTAssertFalse(model.isCommandBarPresented, "the same address again closes it, as ⌘L does")
        XCTAssertFalse(model.addressBarHasKeyboardFocus(for: tabs[0].id, in: nil))
    }

    func testAddressEditingRevealsOnlyTheKeyWindowsToolbar() throws {
        let model = makeModel()
        let first = SidebarWindowID(), second = SidebarWindowID()
        model.store.registerWindow(first)
        model.store.registerWindow(second)
        model.store.windowBecameKey(first)
        let (_, tabs) = try makeSplit(model)
        model.focusLocation()
        XCTAssertTrue(model.addressBarHasKeyboardFocus(for: tabs[0].id, in: first))
        XCTAssertFalse(model.addressBarHasKeyboardFocus(for: tabs[0].id, in: second))
    }

    func testTheRowsCloseButtonClosesOrSeparatesItsPane() throws {
        let model = makeModel()
        let (split, tabs) = try makeSplit(model, panes: 3)

        model.closeSplitPaneFromToolbar(tabs[2].id, separating: true)
        XCTAssertNotNil(model.store.tab(withID: tabs[2].id), "⌥ keeps the tab")
        XCTAssertNil(model.store.splitContaining(tabID: tabs[2].id), "outside the split")
        XCTAssertEqual(model.store.split(withID: split.id)?.tabs.count, 2)

        model.closeSplitPaneFromToolbar(tabs[1].id, separating: false)
        XCTAssertNil(model.store.splitContaining(tabID: tabs[1].id))
        XCTAssertNil(model.store.split(withID: split.id), "the second-to-last pane closing dissolves the split")
    }

    func testAnExpandedPaneHasTheOnlyRow() throws {
        let model = makeModel()
        let (split, tabs) = try makeSplit(model)
        model.focusSplitPane(tabs[1].id, in: split.id)
        model.toggleExpandedSplitPane(split.id)
        XCTAssertTrue(model.isSplitExpanded(split.id, in: nil))
        XCTAssertEqual(try layout(model, split.id).rows.map(\.tabID), [tabs[1].id])
        XCTAssertEqual(try layout(model, split.id).controlsPane, tabs[1].id)
    }
}
