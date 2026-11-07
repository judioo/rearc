import Foundation
import Testing
@testable import SidebarModel

struct LittleArcSplitTests {
    private func store() -> SidebarStore { SidebarStore(spaces: [Space(name: "Main")]) }
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    @Test func splitsWithTheCurrentTabAndSelectsTheLittleArcPane() throws {
        let store = store()
        let anchor = store.addTab(kind: .pinned, title: "Anchor", url: url("anchor"))
        store.selectTab(anchor.id)
        let little = store.createLittleArcWindow(url: url("little"), title: "Little")
        let split = try #require(store.splitLittleArcToCurrentTab(id: little.id))
        #expect(split.tabs.map(\.url) == [anchor.url, little.url])
        #expect(split.focusTabID == split.tabs[1].id)
        #expect(store.selectedItemID == split.id)
        #expect(store.littleArcWindow(withID: little.id) == nil)
        #expect(store.littleArcArchivedWindows.isEmpty)
        #expect(store.kind(of: anchor.id) == nil)
        #expect(store.parent(of: split.id) == .section(spaceID: store.activeSpaceID, section: .pinned))
    }

    @Test func joinsAnExistingSplitAndRefusesTheFifthWithoutSideEffects() throws {
        let store = store()
        let tabs = (0..<4).map { store.addTab(kind: .today, title: "\($0)", url: url("t\($0)")) }
        let original = try #require(store.createSplit(tabIDs: Array(tabs.prefix(3)).map(\.id), orientation: .vertical))
        let first = store.createLittleArcWindow(url: url("little"))
        let grown = try #require(store.splitLittleArcToCurrentTab(id: first.id))
        #expect(grown.id == original.id)
        #expect(grown.orientation == .vertical)
        #expect(grown.tabs.count == 4)
        let second = store.createLittleArcWindow(url: url("other"))
        let before = store.content(for: store.activeSpaceID)
        #expect(!store.canSplitLittleArcToCurrentTab(id: second.id))
        #expect(store.splitLittleArcToCurrentTab(id: second.id) == nil)
        #expect(store.content(for: store.activeSpaceID) == before)
        #expect(store.littleArcWindow(withID: second.id) == second)
    }

    @Test func favoriteAndFolderAnchorsKeepTheirSavedPlaces() throws {
        for favorite in [true, false] {
            let store = store()
            let anchor = store.addTab(kind: favorite ? .favorite : .pinned, title: "Anchor", url: url("anchor"))
            if !favorite { _ = try #require(store.createFolder(containing: [anchor.id])) }
            store.selectTab(anchor.id)
            let parent = store.parent(of: anchor.id)
            let little = store.createLittleArcWindow(url: url("little"))
            let split = try #require(store.splitLittleArcToCurrentTab(id: little.id))
            #expect(split.tabs[0].url == anchor.url)
            #expect(split.tabs[0].id != anchor.id)
            #expect(store.parent(of: anchor.id) == parent)
            #expect(store.tab(withID: anchor.id) != nil)
        }
    }

    @Test func noCurrentTabLeavesTheLittleArcAlone() {
        let store = store()
        let little = store.createLittleArcWindow(url: url("little"))
        #expect(!store.canSplitLittleArcToCurrentTab(id: little.id))
        #expect(store.splitLittleArcToCurrentTab(id: little.id) == nil)
        #expect(store.littleArcWindow(withID: little.id) == little)
        #expect(store.content(for: store.activeSpaceID).today.isEmpty)
    }
}
