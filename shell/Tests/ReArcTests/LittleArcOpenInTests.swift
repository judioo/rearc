import XCTest
import SidebarModel
@testable import ReArc

/// Little Arc's Open in <Space> lands in the last focused browser window and
/// brings that window forward, so another window can't take the key on close.
@MainActor
final class LittleArcOpenInTests: XCTestCase {
    private final class Presenter: BrowserWindowPresenting {
        var focused: [SidebarWindowID] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
        func focusBrowserWindow(_ id: SidebarWindowID) { focused.append(id) }
    }

    func testOpenInFocusesTheLastKeyBrowserWindowOnItsSpace() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file))
        let presenter = Presenter()
        model.windowPresenter = presenter

        let first = SidebarWindowID(), second = SidebarWindowID()
        store.registerWindow(first)
        store.registerWindow(second, spaceID: two.id)
        store.windowBecameKey(first)
        store.windowBecameKey(second)
        XCTAssertEqual(store.activeSpaceID, two.id)

        let little = store.createLittleArcWindow(url: URL(string: "https://little.test")!, title: "Little")
        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, two.id)
        model.promoteLittleArcWindow(little.id)

        XCTAssertEqual(presenter.focused, [second])
        XCTAssertEqual(store.selectedTab?.url.absoluteString, "https://little.test")
        XCTAssertEqual(store.focusedSpaceID(in: second), two.id)
        // The other window keeps its own space.
        XCTAssertNotEqual(store.focusedSpaceID(in: first), two.id)
    }
}
