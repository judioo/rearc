import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 28: the Library, gradient themes, Boosts v2, region capture, rich
/// notes and browser import.
@MainActor
final class Wave28ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w28-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w28-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w28-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-w28-\(UUID().uuidString)"))
        return model
    }

    private func titles(_ groups: [[ShellMenuItem]]) -> [String] { groups.flatMap { $0.map(\.title) } }

    // MARK: Library

    func testLibraryOpensInTheKeyWindowAndAnySidebarClickClosesIt() {
        let model = makeModel()
        let windowA = SidebarWindowID(), windowB = SidebarWindowID()
        model.store.registerWindow(windowA)
        model.store.registerWindow(windowB)
        model.windowBecameKey(windowA)
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        model.store.selectTab(tab.id)

        XCTAssertNil(model.executeCommand(.openLibrary(.easels), commandID: nil))
        XCTAssertEqual(model.librarySection(in: windowA), .easels)
        XCTAssertNil(model.librarySection(in: windowB))

        model.selectTab(tab.id)
        XCTAssertNil(model.librarySection(in: windowA), "clicking the tab under the Library shows it")

        model.toggleLibrary(in: windowA)
        XCTAssertEqual(model.librarySection(in: windowA), .easels, "the Home button reopens the last page")
        model.toggleLibrary(in: windowA)
        XCTAssertNil(model.librarySection(in: windowA))
    }

    func testViewArchiveBoostsAndMediaAreLibraryPages() {
        let model = makeModel()
        XCTAssertNil(model.executeCommand(.viewArchive, commandID: nil))
        XCTAssertTrue(model.isArchivePresented)
        XCTAssertEqual(model.librarySection(in: nil), .archive)
        XCTAssertNil(model.executeCommand(.openCapturesGallery, commandID: nil))
        XCTAssertTrue(model.isCapturesGalleryPresented)
        XCTAssertFalse(model.isArchivePresented, "one page at a time")
        model.isBoostLibraryPresented = true
        XCTAssertEqual(model.librarySection(in: nil), .boosts)
        model.isArchivePresented = false
        XCTAssertTrue(model.isBoostLibraryPresented, "closing another page leaves this one")
        model.isBoostLibraryPresented = false
        XCTAssertNil(model.librarySection(in: nil))

        let tab = model.openInNewTab(URL(string: "https://restore.test")!)
        model.openLibrary(.archive)
        model.archiveTab()
        let record = try? XCTUnwrap(model.store.archivedTabs.first { $0.tab.id == tab.id })
        model.restoreArchivedTab(record!.id)
        XCTAssertNil(model.librarySection(in: nil), "a restored tab is shown")
    }

    func testViewMenuListsLibraryPages() {
        let model = makeModel()
        XCTAssertEqual(titles(ShellMenus.library(model)),
                       ["View Library", "View Spaces", "View Downloads", "View Media", "View Easels & Notes", "View Archive", "View Boosts"])
        ShellMenus.library(model).flatMap { $0 }.first { $0.title == "View Spaces" }!.action()
        XCTAssertEqual(model.librarySection(in: nil), .spaces)
        XCTAssertFalse(titles(ShellMenus.sidebarItems(model)).contains("View Archive"), "moved to the View menu's Library group")

        let space = model.store.addSpace(name: "Second")
        model.openLibrarySpace(space.id)
        XCTAssertEqual(model.store.activeSpaceID, space.id)
        XCTAssertNil(model.librarySection(in: nil))
    }

    // MARK: Gradient themes

    func testSpacesMenuAppearanceKeepsTheGradientAndGrain() {
        let model = makeModel()
        let space = model.store.activeSpaceID
        model.store.setSpaceTheme(space, theme: SpaceTheme.gradientPresets[0].addingStop())
        ShellMenus.spaces(model).flatMap { $0 }.first { $0.title == "Appearance: Dark" }!.action()
        let theme = model.store.activeSpace.theme
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.stops.count, 3)
        XCTAssertNil(model.executeCommand(.setSpaceAppearance(.light), commandID: nil))
        XCTAssertEqual(model.store.activeSpace.theme.appearance, .light)
    }
}
