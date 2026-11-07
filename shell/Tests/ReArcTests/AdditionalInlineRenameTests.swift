import Foundation
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct AdditionalInlineRenameTests {
    private func model() -> BrowserViewModel {
        BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main")]),
                         persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString).json")),
                         faviconStore: FaviconStore(directory: nil))
    }

    @Test func spaceHeaderUsesItsOldNameAndEscRestoresIt() throws {
        let model = model()
        let id = model.store.activeSpaceID
        model.beginRename(.space(id))
        #expect(model.pendingRename == nil)
        #expect(model.inlineRename?.previousName == "Main")
        #expect(SidebarRowRename(row: id, model: model) != nil)
        model.updateInlineRename("Half typed")
        model.endInlineRename(.cancel)
        #expect(model.store.activeSpace.name == "Main")
        model.beginRename(.space(id))
        model.updateInlineRename("  Work  ")
        model.endInlineRename(.commit)
        #expect(model.store.activeSpace.name == "Work")
        model.beginRename(.space(id))
        model.updateInlineRename("")
        model.endInlineRename(.commit)
        #expect(model.store.activeSpace.name == "Work")
    }

    @Test func favoritesAndSplitPanesCommitAndCancelInTheirOwnFields() throws {
        let model = model()
        let favorite = model.store.addTab(kind: .favorite, title: "Favorite", url: URL(string: "https://favorite.test")!)
        let a = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = model.store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let split = try #require(model.store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        model.store.setCustomIcon(.emoji("😀"), for: split.id)
        model.store.renameSplit(split.id, to: "Collection")
        for tab in [favorite, a] {
            model.beginRename(.tab(tab.id))
            #expect(model.pendingRename == nil)
            #expect(model.inlineRename?.previousName == tab.displayTitle)
            let field = try #require(SidebarRowRename(row: tab.id, model: model))
            field.onChange("Renamed")
            field.onEnd(.commit, false)
            #expect(model.store.tab(withID: tab.id)?.displayTitle == "Renamed")
            model.beginRename(.tab(tab.id))
            model.updateInlineRename("Discard")
            model.endInlineRename(.cancel)
            #expect(model.store.tab(withID: tab.id)?.displayTitle == "Renamed")
        }
        #expect(model.store.split(withID: split.id)?.title == "Collection")
        #expect(model.store.split(withID: split.id)?.tabs.map(\.displayTitle) == ["Renamed", "B"])
    }

    @Test func libraryCoveredRowsKeepAnAccessibleRenameAlert() {
        let model = model()
        model.openLibrary(.spaces)
        model.beginRename(.space(model.store.activeSpaceID))
        #expect(model.inlineRename == nil)
        #expect(model.pendingRename == .space(model.store.activeSpaceID))
    }
}
