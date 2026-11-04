import XCTest
@testable import SidebarModel

/// Wave 32 task 0: Arc lists Today newest first. A new tab goes on top, a
/// user's reorder is kept, and a snapshot round trip keeps the order.
final class Wave32TodayOrderTests: XCTestCase {
    private func titles(_ store: SidebarStore) -> [String] {
        store.sectionEntries(for: .unpinned, spaceID: store.activeSpaceID).compactMap { entry in
            if case .tab(let tab) = entry { return tab.title }
            return nil
        }
    }

    func testTodayListsNewestFirstAndKeepsAUserReorder() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let space = store.activeSpaceID
        for title in ["Oldest", "Middle", "Newest"] {
            _ = store.addTab(kind: .today, title: title, url: URL(string: "https://\(title.lowercased()).test")!)
        }
        XCTAssertEqual(titles(store), ["Newest", "Middle", "Oldest"])

        let oldest = try XCTUnwrap(store.sectionEntries(for: .unpinned, spaceID: space).last?.id)
        XCTAssertTrue(store.moveEntry(oldest, to: 0, in: space, section: .unpinned))
        XCTAssertEqual(titles(store), ["Oldest", "Newest", "Middle"])

        _ = store.addTab(kind: .today, title: "Latest", url: URL(string: "https://latest.test")!)
        XCTAssertEqual(titles(store), ["Latest", "Oldest", "Newest", "Middle"], "a new tab goes on top; the reorder below it stays")

        let data = try JSONEncoder().encode(store.makeSnapshot())
        let restored = SidebarStore(spaces: [Space(name: "Other")])
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        XCTAssertEqual(titles(restored), ["Latest", "Oldest", "Newest", "Middle"])
    }
}
