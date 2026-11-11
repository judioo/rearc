import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Views show engines and only the model makes them (BrowserViewModel+ShownEngines).
final class ShownEngineTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-shown-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private func engine(_ model: BrowserViewModel, _ tab: SidebarModel.Tab) -> (any WebEngine)? {
        model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab))
    }

    /// The self-test's stray page: a split's view evaluated once more after its
    /// pane closed made a blank engine for the closed pane and attached it.
    func testAStaleSplitViewMakesNoPageForItsClosedPane() throws {
        let model = makeModel()
        let store = model.store
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        model.loadSelectedIfNeeded()
        XCTAssertNotNil(engine(model, b))

        model.deleteTab(b.id)
        XCTAssertNil(store.split(withID: split.id), "closing a pane of two ends the split")
        XCTAssertNil(engine(model, b))

        let host = NSHostingView(rootView: SplitContentView(split: split, model: model, accent: .blue)
            .frame(width: 800, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertNil(engine(model, b), "no page for the closed pane")
        XCTAssertEqual(model.engineHost.allTabEngines().map(\.0), [a.id])
    }

    func testShownEngineOnlyLooksUp() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Cold", url: URL(string: "https://cold.test")!)
        XCTAssertNil(model.shownEngine(for: tab))
        XCTAssertTrue(model.engineHost.allTabEngines().isEmpty)
    }

    func testOnlyALiveShownTabIsLoadedForAView() throws {
        let model = makeModel()
        let store = model.store
        let shown = store.addTab(kind: .today, title: "Shown", url: URL(string: "https://shown.test")!)
        let hidden = store.addTab(kind: .today, title: "Hidden", url: URL(string: "https://hidden.test")!)
        // Selected in the store without the model loading it (another window's space, a restored pane).
        store.selectTab(shown.id)
        XCTAssertNil(engine(model, shown))

        model.loadShownTab(hidden.id)
        XCTAssertNil(engine(model, hidden), "a tab no window shows gets no engine")

        model.loadShownTab(shown.id)
        let loaded = try XCTUnwrap(engine(model, shown))
        XCTAssertEqual(loaded.currentURL, shown.url)
        XCTAssertNotNil(loaded.linkPeekHandler, "configured like any tab engine")
        model.loadShownTab(shown.id)
        XCTAssertTrue(engine(model, shown) === loaded, "made once")

        let closed = store.addTab(kind: .today, title: "Closed", url: URL(string: "https://closed.test")!)
        model.deleteTab(closed.id)
        model.loadShownTab(closed.id)
        XCTAssertNil(engine(model, closed), "a closed tab gets no engine")
    }
}
