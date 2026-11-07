import Foundation
import Testing
@testable import SidebarModel

struct LibrarySpacesColumnsTests {
    @Test func columnsFollowProfileAndSpaceOrderAndCountFolderContents() throws {
        let store = SidebarStore(spaces: [Space(name: "One", sortRank: "a"), Space(name: "Two", sortRank: "b")])
        let tab = store.addTab(kind: .pinned, title: "Nested", url: URL(string: "https://example.test")!)
        _ = try #require(store.createFolder(containing: [tab.id]))
        let groups = LibrarySpaces.groups(in: store)
        #expect(groups.count == 1)
        #expect(groups[0].rows.map(\.space.name) == ["One", "Two"])
        #expect(groups[0].rows.map(\.pinnedCount) == [1, 0])
        #expect(LibrarySpacesMotion.duration(opening: true) == 0.08)
        #expect(LibrarySpacesMotion.duration(opening: false) == 0.17)
    }
}
