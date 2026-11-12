import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The command bar's own services with DuckDuckGo as the default, asking nothing.
private final class QuietCommandBarServices: CommandBarServices {
    var provider = SearchProvider.duckDuckGo
    var onSearchProviderChange: (() -> Void)?
    func searchProvider(for profileID: Profile.ID) -> SearchProvider { provider }
    func commandBarWillOpen(profileID: Profile.ID) {}
    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void) {}
    func cancel() {}
    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool { false }
}

/// Max › Instant Links in the command bar: ⇧↩ on a plain search opens the
/// top result; anywhere else, and with Instant Links off, ⇧↩ is Little ReArc.
@MainActor
final class InstantLinksShellTests: XCTestCase {
    private func makeModel(on: Bool) -> BrowserViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-instant-\(UUID().uuidString)")
        let model = BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main", sortRank: "a")]),
                                     persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        model.commandBarServices = QuietCommandBarServices()
        model.externalLinkDefaults = UserDefaults(suiteName: "InstantLinksShellTests.\(UUID().uuidString)")!
        model.maxPreferences = MaxPreferences(enabled: on ? [.instantLinks] : [])
        return model
    }

    func testOffShiftReturnKeepsLittleReArc() {
        let model = makeModel(on: false)
        model.newTab()
        model.commandBarText = "swift testing"
        XCTAssertNil(model.instantLinksQuery)
        model.submitCommandBar(route: .littleArc)
        XCTAssertEqual(model.store.littleArcLiveWindows.first?.url.absoluteString, "https://duckduckgo.com/?q=swift%20testing",
                       "the search, in Little ReArc, as before")
        XCTAssertEqual(CommandBarResultRow.modifierHelp(for: .search, instantLinks: false),
                       "↩ Open · ⌘↩ New Tab · ⌥↩ Split View · ⇧↩ Little ReArc")
    }

    func testOnAPlainSearchOpensItsTopResultInTheBarsTab() throws {
        let model = makeModel(on: true)
        model.newTab()
        model.commandBarText = "swift testing"
        XCTAssertEqual(model.instantLinksQuery, "swift testing")
        model.submitCommandBar(route: .littleArc)
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://duckduckgo.com/?q=%5Cswift%20testing")
        XCTAssertTrue(model.store.littleArcLiveWindows.isEmpty, "not Little ReArc")
        XCTAssertEqual(CommandBarResultRow.modifierHelp(for: .search, instantLinks: true),
                       "↩ Open · ⌘↩ New Tab · ⌥↩ Split View · ⇧↩ Top Result")
        XCTAssertEqual(CommandBarResultRow.modifierHelp(for: .openTab, instantLinks: true),
                       "↩ Open · ⌘↩ New Tab · ⌥↩ Split View · ⇧↩ Little ReArc")
    }

    func testAnAddressATabOrAChipKeepsLittleReArc() throws {
        let model = makeModel(on: true)
        model.newTab()
        model.commandBarText = "example.com"
        XCTAssertNil(model.instantLinksQuery, "an address is not a search")
        model.commandBarText = "https://example.com/a"
        XCTAssertNil(model.instantLinksQuery)
        model.commandBarText = ">pin"
        XCTAssertNil(model.instantLinksQuery, "commands")
        model.commandBarText = "youtube"
        XCTAssertTrue(model.enterCommandBarSiteSearch())
        model.commandBarText = "cats"
        XCTAssertNil(model.instantLinksQuery, "a site search chip has its own search")
    }

    func testCommaSeparatedSearchesOpenATabEachAndTheCapIsSaid() throws {
        let model = makeModel(on: true)
        let before = Set(model.store.content(for: model.store.activeSpaceID).today.map(\.id))
        model.newTab()
        model.commandBarText = "a1, b2, c3, d4, e5, f6"
        model.submitCommandBar(route: .littleArc)
        let opened = model.store.content(for: model.store.activeSpaceID).today.compactMap { entry -> Tab? in
            guard case .tab(let tab) = entry, !before.contains(tab.id) else { return nil }
            return tab
        }
        XCTAssertEqual(Set(opened.map(\.url.absoluteString)), Set(["a1", "b2", "c3", "d4", "e5"].map { "https://duckduckgo.com/?q=%5C\($0)" }),
                       "a tab each, the sixth left out")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://duckduckgo.com/?q=%5Ca1", "the first search stays in front")
        XCTAssertEqual(model.toast?.message, "Opened the first 5 searches; 1 more were left out.")
    }
}
