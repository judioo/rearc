import XCTest
import SidebarModel
@testable import ReArc

/// Tab stacking in the shell (ARC-RECORDING-2026-11-06 §8): drops on rows,
/// Arc's toast for a fifth pane, Add Tab to Split View and in-place rename.
@MainActor
final class TabStackingShellTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Demo", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-stack-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private func addTabs(_ model: BrowserViewModel, _ count: Int) -> [Tab] {
        (0..<count).map { model.store.addTab(kind: .today, title: "Google \($0)", url: URL(string: "https://g\($0).test")!) }
    }

    func testDropsStackUpToFourThenTheFifthShowsArcsToast() throws {
        let model = makeModel()
        let tabs = addTabs(model, 5)
        model.combineIntoSplit(tabs[1].id, onto: tabs[0].id)
        let split = try XCTUnwrap(model.store.splitContaining(tabID: tabs[0].id)?.split)
        XCTAssertEqual(model.store.selectedItemID, split.id, "the stack opens")
        model.combineIntoSplit(tabs[2].id, onto: split.id)
        model.combineIntoSplit(tabs[3].id, onto: split.id)
        XCTAssertNil(model.toast)

        model.combineIntoSplit(tabs[4].id, onto: split.id)
        XCTAssertEqual(model.toast?.message, "Cannot Add New Pane")
        XCTAssertEqual(model.toast?.systemImage, "", "Arc's toast is text only")
        XCTAssertEqual(model.store.split(withID: split.id)?.tabs.count, 4)
        XCTAssertNil(model.store.splitContaining(tabID: tabs[4].id))
    }

    func testAddTabToSplitViewAddsABlankPaneOrSaysItIsFull() throws {
        let model = makeModel()
        let tabs = addTabs(model, 2)
        let split = try XCTUnwrap(model.store.createSplit(tabIDs: tabs.map(\.id), orientation: .horizontal))
        model.addBlankPane(to: split.id)
        model.addBlankPane(to: split.id)
        XCTAssertEqual(model.store.split(withID: split.id)?.tabs.count, 4)
        XCTAssertNil(model.toast)
        model.addBlankPane(to: split.id)
        XCTAssertEqual(model.toast?.message, SplitViewItem.fullMessage)
        XCTAssertEqual(model.store.split(withID: split.id)?.tabs.count, 4)
    }

    func testRenameInPlaceNamesTheCollection() throws {
        let model = makeModel()
        let tabs = addTabs(model, 2)
        let split = try XCTUnwrap(model.store.createSplit(tabIDs: tabs.map(\.id), orientation: .horizontal))
        model.beginSplitRename(split.id)
        XCTAssertEqual(model.renamingSplitID, split.id)
        model.renameSplit(split.id, to: "the 4 amigos")
        XCTAssertNil(model.renamingSplitID)
        XCTAssertEqual(model.store.split(withID: split.id)?.displayTitle, "the 4 amigos")
    }
}
