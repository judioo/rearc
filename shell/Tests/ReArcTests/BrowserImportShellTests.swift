import AppKit
import SQLite3
import XCTest
@testable import ReArc
@testable import SidebarModel

/// File › Import from Arc, Chrome or Brave…: the session over an invented
/// Application Support folder, and what an import does to the model.
final class BrowserImportShellTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-import-\(UUID().uuidString)", isDirectory: true)
        try writeFixture()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-import-model-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-import-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-import-links-\(UUID().uuidString)")!
        // The imported search engine is saved; keep it out of the shared defaults.
        model.commandBarServices = WebKitCommandBarServices(defaults: UserDefaults(suiteName: "rearc-import-search-\(UUID().uuidString)")!)
        return model
    }

    private func write(_ object: Any, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// One Arc space with a pinned tab and a favorite; one Chrome profile
    /// with a bookmark and a history page.
    private func writeFixture() throws {
        func item(_ id: String, _ children: [String], _ data: [String: Any]) -> [String: Any] {
            ["id": id, "childrenIds": children, "data": data]
        }
        let tab: (String, String) -> [String: Any] = { url, title in ["tab": ["savedURL": url, "savedTitle": title]] }
        let items: [[String: Any]] = [
            item("PIN", ["T1"], ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]]),
            item("T1", [], tab("https://notes.example.com/", "Notes")),
            item("UNPIN", [], ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]]),
            item("TOP", ["F1"], ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]]),
            item("F1", [], tab("https://chat.example.com/", "Chat")),
        ]
        try write([
            "version": 1,
            "sidebar": ["containers": [["global": [:]], [
                "items": items.flatMap { [$0["id"]!, $0] },
                "spaces": ["S1", ["id": "S1", "title": "Studio", "profile": ["default": true],
                                  "newContainerIDs": [["pinned": [:]], "PIN", ["unpinned": ["_0": ["shared": [:]]]], "UNPIN"],
                                  "customInfo": ["iconType": ["emoji_v2": "🎨", "emoji": 1]]]],
                "topAppsContainerIDs": [["default": true], "TOP"],
            ]]],
        ], "Arc/StorableSidebar.json")
        try write(["profile": ["info_cache": ["Default": ["name": "Everyday"]], "profiles_order": ["Default"]]], "Google/Chrome/Local State")
        try write(["default_search_provider_data": ["template_url_data": ["short_name": "Bing", "keyword": "bing.com", "url": "https://www.bing.com/search?q={searchTerms}"]]],
                  "Google/Chrome/Default/Preferences")
        try write(["roots": ["bookmark_bar": ["type": "folder", "children": [["type": "url", "name": "Recipes", "url": "https://recipes.example.com/"]]]]],
                  "Google/Chrome/Default/Bookmarks")
        var db: OpaquePointer?
        let history = root.appendingPathComponent("Google/Chrome/Default/History")
        XCTAssertEqual(sqlite3_open(history.path, &db), SQLITE_OK)
        let time = ChromiumHistoryReader.chromiumTime(Date())
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER NOT NULL DEFAULT 0, typed_count INTEGER NOT NULL DEFAULT 0, last_visit_time INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0);
            INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES ('https://weather.example.org/', 'Weather', 4, \(time));
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    private func discoveredSession(_ model: BrowserViewModel, defaults: [String: Any] = [:]) -> BrowserImportSession {
        let session = BrowserImportSession(model: model, applicationSupport: root, arcDefaults: { defaults })
        let done = expectation(description: "discovered")
        session.discover { done.fulfill() }
        wait(for: [done], timeout: 10)
        return session
    }

    private func waitForDetail(_ session: BrowserImportSession, _ profile: ImportSourceProfile) {
        let loaded = expectation(description: "detail")
        DispatchQueue.global().async {
            while true {
                var ready = false
                DispatchQueue.main.sync { ready = session.detail(for: profile) != nil }
                if ready { break }
                usleep(10_000)
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)
    }

    func testLookingAgainKeepsTheSelectedProfileAndReloadsItsCounts() throws {
        let session = discoveredSession(makeModel())
        guard case .profile(let profile) = try XCTUnwrap(session.sources.last) else { return XCTFail("no profile") }
        session.selection = .profile(profile)
        waitForDetail(session, profile)
        let again = expectation(description: "rediscovered")
        session.discover { again.fulfill() }
        wait(for: [again], timeout: 10)
        XCTAssertEqual(session.selection, .profile(profile))
        waitForDetail(session, profile)
        XCTAssertEqual(session.detail(for: profile)?.inventory.historyPages, 1)
    }

    func testTheMenuAndCommandBarOpenTheImportWindow() {
        let model = makeModel()
        XCTAssertEqual(ShellMenus.importing(model, chromiumImporter: false).first?.first?.title, "Import from Arc, Chrome or Brave…")
        let context = CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let command = AppCommandRegistry.all(in: context).first { $0.id == "import-from-browser" }
        XCTAssertEqual(command?.action, .importFromBrowser)
        XCTAssertEqual(command?.isEnabled(in: context), true)
    }

    /// Arc's card files beside its sidebar; the auth file with fields ReArc must not keep.
    private func writeArcCard() throws {
        try write(["title": "STATUESQUE HUNTER", "paletteNumber": 6, "shapeName": "Shape2",
                   "backgroundBlobInfo": [10, 7, 9, 14, 7, 3, 9, 7, 4, 1, 4, 12, 14, 9, 7], "version": 1],
                  "Arc/StorableMembershipCard.json")
        try write(["session": ["accessToken": "secret-token", "user": ["id": "secret-id", "email": "someone@example.invalid",
                                                                       "name": "Akilu", "createdAt": 738_929_101.8]]],
                  "Arc/StorableAuthState.json")
    }

    func testArcsMembershipCardComesWithTheSidebarAndKeepsNoSecrets() throws {
        try writeArcCard()
        let model = makeModel()
        let session = discoveredSession(model)
        let card = try XCTUnwrap(session.arcCard)
        XCTAssertEqual(card.title, "STATUESQUE HUNTER")
        session.setSpace("S1", included: false)
        session.arcChoices.includeFavorites = false
        XCTAssertTrue(session.canImport, "the card alone is worth importing")
        session.performImport()
        let imported = model.membershipCard.ensureLoaded()
        XCTAssertEqual(imported.title, "STATUESQUE HUNTER")
        XCTAssertEqual(imported.arcName, "Akilu")
        XCTAssertEqual(imported.arcPalette, 6)
        XCTAssertFalse(imported.transitionShown)
        XCTAssertTrue(session.result?.contains("membership card") == true)
        let saved = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        let file = try String(contentsOf: model.membershipCard.fileURL, encoding: .utf8)
        for secret in ["secret-token", "secret-id", "someone@example.invalid"] { XCTAssertFalse(file.contains(secret)) }
    }

    func testUntickingTheCardLeavesItAlone() throws {
        try writeArcCard()
        let model = makeModel()
        let before = model.membershipCard.ensureLoaded()
        let session = discoveredSession(model)
        session.includeArcCard = false
        session.performImport()
        XCTAssertEqual(model.membershipCard.card, before)
    }

    func testDiscoveryListsArcsSidebarThenEachProfileAndPreselectsArc() {
        let session = discoveredSession(makeModel(), defaults: ["shouldWarnBeforeQuitting": false])
        XCTAssertEqual(session.sources.count, 2)
        XCTAssertEqual(session.selection, .arcSidebar)
        XCTAssertEqual(session.arcSummary.spaces, 1)
        XCTAssertEqual(session.arcSummary.pinnedTabs, 1)
        XCTAssertEqual(session.arcSummary.favorites, 1)
        XCTAssertEqual(session.arcSettings.count, 1)
        XCTAssertTrue(session.canImport)
        session.setSpace("S1", included: false)
        session.arcChoices.includeFavorites = false
        session.includeArcSettings = false
        XCTAssertFalse(session.canImport, "nothing chosen")
    }

    func testImportingArcMakesItsSpacesAndAppliesItsSettings() {
        let model = makeModel()
        model.warnBeforeQuitting = true
        let session = discoveredSession(model, defaults: ["shouldWarnBeforeQuitting": false, "autoArchiveTimeThreshold": "sevenDays"])
        session.performImport()
        let studio = model.store.spaces.first { $0.name == "Studio" }
        XCTAssertEqual(studio?.iconName, "🎨")
        XCTAssertEqual(model.store.activeSpaceID, studio?.id)
        XCTAssertEqual(model.store.favorites.map(\.title), ["Chat"])
        XCTAssertFalse(model.warnBeforeQuitting)
        XCTAssertEqual(model.store.autoArchiveThreshold(), .sevenDays)
        XCTAssertEqual(session.result, "Imported 1 space, 1 pinned tab, 1 favorite, 2 settings")
        XCTAssertEqual(model.toast?.message, "Imported 1 space, 1 pinned tab, 1 favorite")
    }

    func testImportingAChromeProfileBringsBookmarksAndHistory() throws {
        let model = makeModel()
        let session = discoveredSession(model)
        guard case .profile(let profile) = try XCTUnwrap(session.sources.last) else { return XCTFail("no profile") }
        XCTAssertEqual(profile.name, "Everyday")
        session.selection = .profile(profile)
        waitForDetail(session, profile)
        XCTAssertEqual(session.detail(for: profile)?.inventory.bookmarks, 1)
        XCTAssertEqual(session.detail(for: profile)?.setup.searchEngine?.name, "Bing")
        let imported = expectation(description: "imported")
        session.performImport { imported.fulfill() }
        wait(for: [imported], timeout: 10)
        XCTAssertEqual(model.store.activeSpace.name, "Google Chrome – Everyday")
        XCTAssertEqual(model.store.content(for: model.store.activeSpaceID).pinnedLeaves.count, 1)
        XCTAssertNotNil(model.visitHistory.record(for: URL(string: "https://weather.example.org/")!))
        XCTAssertTrue(session.result?.hasPrefix("1 bookmark in Google Chrome – Everyday · 1 history page") == true, session.result ?? "")
        XCTAssertNil(model.pendingExtensionReinstall?.queue, "WebKit cannot reinstall extensions")
        XCTAssertEqual(model.webKitSearchPreference?.providerID, SearchProvider.bing.id, "Chrome's search engine, matched by name")
    }

    func testAReinstallStepOpensTheStorePageInTheTargetProfile() {
        let model = makeModel()
        let other = model.store.addProfile(name: "Work")
        let item = ExtensionReinstallQueue.Item(id: "abcdefghijklmnopabcdefghijklmnop", name: "Tab Notes", origin: .webStore, profileID: other.id)
        model.openExtensionForReinstall(item)
        XCTAssertEqual(model.store.activeProfileID, other.id)
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop")
    }
    func testImportedArcSourceHasNothingLeftToImport() {
        let model = makeModel()
        let session = discoveredSession(model)
        XCTAssertTrue(session.canImport)
        session.performImport()
        let count = model.store.spaces.count
        XCTAssertTrue(session.arcSummary.isEmpty)
        XCTAssertFalse(session.canImport)
        session.performImport()
        XCTAssertEqual(model.store.spaces.count, count)
    }

}
