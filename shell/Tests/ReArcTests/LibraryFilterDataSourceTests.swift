import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

@MainActor
struct LibraryFilterDataSourceTests {
    @Test func modelFiltersSurviveLibraryPageChanges() {
        let model = BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main")]),
                                     persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString).json")))
        model.archiveFilter.spaceID = model.store.activeSpaceID
        model.archiveFilter.date = .lastSevenDays
        model.downloads.libraryFilter.state = .failed
        model.openLibrary(.archive)
        model.openLibrary(.downloads)
        model.closeLibrary()
        model.openLibrary(.archive)
        #expect(model.archiveFilter.spaceID == model.store.activeSpaceID)
        #expect(model.archiveFilter.date == .lastSevenDays)
        #expect(model.downloads.libraryFilter.state == .failed)
    }

    @Test func filterUpdatesTheExistingDownloadsDataSource() async {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply([
            DownloadEvent(kind: .created, guid: "pdf", url: "https://files.test/a.pdf", state: .complete),
            DownloadEvent(kind: .created, guid: "png", url: "https://files.test/a.png", state: .inProgress),
        ], source: .chromium)
        let state = DownloadsTableState()
        let controller = DownloadsTableController(downloads: downloads, state: state)
        let scroll = controller.makeScrollView()
        defer { controller.invalidate(); _ = scroll }
        #expect(controller.rows.count == 2)
        downloads.libraryFilter.type = .documents
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.rows.records.map(\.id) == ["pdf"])
        controller.setQuery("png")
        #expect(controller.rows.count == 0)
        #expect(state.isEmpty)
        #expect(!state.hasNoDownloads)
        downloads.libraryFilter = LibraryDownloadFilter()
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.rows.records.map(\.id) == ["png"])
        downloads.libraryFilter.state = .dangerous
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.rows.count == 0)
        downloads.updateWarning(DownloadWarning(dangerType: 2, insecureStatus: 0, isDangerous: true, isInsecure: false), for: "png")
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.rows.records.map(\.id) == ["png"])
        #expect(downloads.records.count == 2, "filtering leaves the tray's records alone")
    }
}
