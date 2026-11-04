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

    // MARK: Boosts v2

    func testVisualEditorZapsOnPickAndSavesIntoTheStylesheet() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://boost.test/page")!)
        model.store.selectTab(tab.id)
        model.newBoost()
        let draft = try XCTUnwrap(model.boostEditorDraft)
        model.startBoostPicker(zap: true)
        XCTAssertTrue(model.boostEditorDraft?.zapOnPick == true)
        let descriptor = ElementDescriptor(tag: "div", id: "promo", classes: [], attrs: [:], structuralPath: ["body"])
        model.handleBoostPick(PickedElementSnapshot(descriptor: descriptor, bounds: ElementBounds(x: 0, y: 0, width: 10, height: 10),
                                                    viewportWidth: 100, viewportHeight: 100))
        XCTAssertEqual(model.boostEditorDraft?.visual.zaps.count, 1, "the pick zapped the element")
        XCTAssertFalse(model.boostEditorDraft?.zapOnPick ?? true)
        model.updateBoostVisual { $0.tint = BoostTint(hue: 0.3) }
        model.boostEditorCSSChanged("h1 { color: red; }")
        model.saveBoostEditor()
        let css = try XCTUnwrap(model.store.boostLibrary().package(id: draft.packageID)?.styleBoost?.css)
        let parsed = BoostVisualStyle.parse(css)
        XCTAssertEqual(parsed.style.tint?.hue ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(parsed.style.zaps.count, 1)
        XCTAssertEqual(parsed.customCSS, "h1 { color: red; }")
    }

    func testLegacyBoostAndBoostFiles() throws {
        let model = makeModel()
        XCTAssertEqual(model.newLegacyBoost(), "Open a website to boost first")
        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://legacy.test/")!)
        model.store.selectTab(tab.id)
        XCTAssertNil(model.executeCommand(.newLegacyBoost, commandID: nil))
        let id = try XCTUnwrap(model.legacyBoostEditorID)
        XCTAssertNil(model.saveLegacyBoost(id, css: "body { margin: 0 }", js: "document.body.dataset.boosted = '1'"))
        XCTAssertEqual(model.saveLegacyBoost(id, css: "@import url(https://x.test/a.css);", js: "1"), "Boosts cannot load files from the web.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w28-boosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.rearcboost"), bad = directory.appendingPathComponent("bad.rearcboost")
        try XCTUnwrap(model.boostFileData(id)).write(to: good)
        try Data("{}".utf8).write(to: bad)
        let before = model.store.boostLibrary().packages.count
        let problems = model.importBoostFiles([good, bad])
        XCTAssertEqual(problems, ["bad.rearcboost: This file could not be read as a boost."])
        XCTAssertEqual(model.store.boostLibrary().packages.count, before + 1)
        let imported = try XCTUnwrap(model.store.boostLibrary().packages.last)
        XCTAssertEqual(model.store.boostLibrary().installation(for: imported.manifest.id)?.enabled, false, "script boosts arrive off")

        model.legacyBoostEditorID = nil
        model.editBoost(imported.manifest.id)
        XCTAssertEqual(model.legacyBoostEditorID, imported.manifest.id, "Edit opens the code editor for a script boost")
    }
}
