import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// ⌘T and + New Tab always open in Today, whatever tab is selected.
@MainActor
final class NewTabPlacementTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-ntp-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-ntp-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-ntp-links-\(UUID().uuidString)")!
        return model
    }

    func testNewTabFromAPinnedFolderTabOpensInToday() throws {
        let model = makeModel()
        let pinned = model.store.addTab(kind: .pinned, title: "SwiftUI", url: URL(string: "https://developer.apple.com/swiftui/")!)
        let folder = try XCTUnwrap(model.store.createFolder(containing: [pinned.id]))
        model.store.selectTab(pinned.id)

        for text in ["zebra facts", "https://example.com/"] {
            model.newTab()
            model.commandBarText = text
            model.submitCommandBar()
            let selected = try XCTUnwrap(model.store.selectedTab)
            XCTAssertNotEqual(selected.id, pinned.id, "\(text): the pinned tab is not reused")
            XCTAssertEqual(model.store.kind(of: selected.id), .today, "\(text): new tab is in Today")
            XCTAssertEqual(model.store.tab(withID: pinned.id)?.url.absoluteString, "https://developer.apple.com/swiftui/")
            XCTAssertEqual(model.store.folder(withID: folder.id)?.children.count, 1, "\(text): nothing added to the folder")
            model.store.selectTab(pinned.id)
        }
    }
}
