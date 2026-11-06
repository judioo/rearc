import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The Library in the sidebar (arc-recordings/2026-11-06-library-in-sidebar.md):
/// per-window widths, a hidden sidebar coming back for it, and Esc.
@MainActor
final class LibrarySidebarShellTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-library-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-library-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-library-links-\(UUID().uuidString)")!
        return model
    }

    private func escape(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
    }

    func testTheLibraryWidensOnlyItsWindowsSidebar() {
        let model = makeModel()
        model.sidebarWidth = 228
        let a = SidebarWindowID(), b = SidebarWindowID()
        model.store.registerWindow(a)
        model.store.registerWindow(b)
        model.windowBecameKey(a)

        model.openLibrary(.downloads, in: a)
        XCTAssertEqual(model.sidebarWidth(in: a), 416)
        XCTAssertEqual(model.sidebarWidth(in: b), 228, "the other window keeps its sidebar")

        model.openLibrary(.spaces, in: a)
        XCTAssertEqual(model.sidebarWidth(in: a), 111)
        XCTAssertNil(model.sidebarGrowth(in: a), "narrowing to the rail is a cut")

        model.closeLibrary(in: a)
        XCTAssertEqual(model.sidebarWidth(in: a), 228)
        XCTAssertNil(model.sidebarGrowth(in: a))
        XCTAssertTrue(model.libraryGrowth.isEmpty)
    }

    func testOpeningTheLibraryBringsBackAHiddenSidebar() {
        let model = makeModel()
        model.isSidebarVisible = false
        model.isSidebarLaidOut = false
        model.sidebarReveal = 0
        model.openLibrary(.media)
        XCTAssertTrue(model.isSidebarVisible, "the Library lives in the sidebar")

        model.closeLibrary()
        model.isSidebarVisible = false
        model.isSidebarPeeking = true
        model.toggleLibrary(in: nil)
        XCTAssertEqual(model.librarySection(in: nil), .media)
        XCTAssertFalse(model.isSidebarVisible, "the floating sidebar shows it without pinning")
    }

    func testEscapeLeavesTheLibraryUnlessThePageHasFocus() {
        let model = makeModel()
        XCTAssertFalse(model.handleLibraryEscape(escape(), pageHasFocus: false), "no Library, nothing to leave")

        model.openLibrary(.archive)
        XCTAssertFalse(model.handleLibraryEscape(escape(), pageHasFocus: true), "the page keeps its Esc")
        XCTAssertFalse(model.handleLibraryEscape(escape(.command), pageHasFocus: false))
        XCTAssertEqual(model.librarySection(in: nil), .archive)

        model.isCommandBarPresented = true
        XCTAssertFalse(model.handleLibraryEscape(escape(), pageHasFocus: false), "the command bar's Esc")
        model.isCommandBarPresented = false

        XCTAssertTrue(model.handleLibraryEscape(escape(), pageHasFocus: false))
        XCTAssertNil(model.librarySection(in: nil))
    }
}
