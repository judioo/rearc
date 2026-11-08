import Onboarding
@testable import ReArc
import SQLite3
@testable import SidebarModel
import XCTest

/// The onboarding's import over an invented Application Support folder: Act
/// 2's counts, the rehearsal and the real import agree for every category,
/// and extensions are queued for after the sunrise, never opened during it.
@MainActor
final class OnboardingImportTests: XCTestCase {
    private var root: URL!
    private var data: URL!

    static let notesID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let readerID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let componentID = "cccccccccccccccccccccccccccccccc"
    static let unpackedID = "dddddddddddddddddddddddddddddddd"
    static let externalID = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-onboarding-\(UUID().uuidString)", isDirectory: true)
        data = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-onboarding-data-\(UUID().uuidString)", isDirectory: true)
        try writeFixture()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: data)
    }

    private func makeModel(_ store: SidebarStore = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])) -> BrowserViewModel {
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: data.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-onboarding-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-onboarding-links-\(UUID().uuidString)")!
        return model
    }

    private func write(_ object: Any, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func sqlite(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent(path).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func extensionEntry(_ name: String, location: Int, webStore: Bool, path: String) -> [String: Any] {
        ["location": location, "from_webstore": webStore, "path": path, "manifest": ["name": name, "version": "1.0"]]
    }

    /// Arc: one space with two pinned tabs and a Today tab, a favorite listed
    /// twice, one extension. Chrome: two web bookmarks and a script one, two
    /// visible history pages and a hidden one, a saved login, and the same
    /// extension as Arc's plus one more that reinstalls and three that do not.
    private func writeArcSidebar(favorite: String = "https://chat.example.com/") throws {
        func item(_ id: String, _ children: [String], _ data: [String: Any]) -> [String: Any] {
            ["id": id, "childrenIds": children, "data": data]
        }
        let tab: (String, String) -> [String: Any] = { url, title in ["tab": ["savedURL": url, "savedTitle": title]] }
        let items: [[String: Any]] = [
            item("PIN", ["T1", "T2"], ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]]),
            item("T1", [], tab("https://notes.example.com/", "Notes")),
            item("T2", [], tab("https://plans.example.com/", "Plans")),
            item("UNPIN", ["T3"], ["itemContainer": ["containerType": ["spaceItems": ["_0": "S1"]]]]),
            item("T3", [], tab("https://news.example.com/", "News")),
            item("TOP", ["F1", "F2"], ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]]),
            item("F1", [], tab(favorite, "Chat")),
            item("F2", [], tab(favorite, "Chat again")),
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
    }

    private func writeFixture() throws {
        try writeArcSidebar()
        try write(["profile": ["info_cache": ["Default": ["name": "Personal"]], "profiles_order": ["Default"]]], "Arc/User Data/Local State")
        try write([:], "Arc/User Data/Default/Preferences")
        try write(["extensions": ["settings": [
            Self.notesID: extensionEntry("Tab Notes", location: 1, webStore: true, path: "\(Self.notesID)/1.0_0"),
        ]]], "Arc/User Data/Default/Secure Preferences")

        try write(["profile": ["info_cache": ["Default": ["name": "Everyday"]], "profiles_order": ["Default"]]], "Google/Chrome/Local State")
        try write([:], "Google/Chrome/Default/Preferences")
        try write(["roots": ["bookmark_bar": ["type": "folder", "children": [
            ["type": "url", "name": "Recipes", "url": "https://recipes.example.com/"],
            ["type": "url", "name": "Script", "url": "javascript:void(0)"],
            ["type": "folder", "name": "Trips", "children": [["type": "url", "name": "Maps", "url": "https://maps.example.org/"]]],
        ]]]], "Google/Chrome/Default/Bookmarks")
        try write(["extensions": ["settings": [
            Self.notesID: extensionEntry("Tab Notes", location: 1, webStore: true, path: "\(Self.notesID)/1.0_0"),
            Self.readerID: extensionEntry("Reader", location: 1, webStore: true, path: "\(Self.readerID)/2.0_0"),
            Self.componentID: extensionEntry("Built In", location: 5, webStore: false, path: "/component"),
            Self.unpackedID: extensionEntry("Gone Tool", location: 4, webStore: false, path: root.appendingPathComponent("nowhere").path),
            Self.externalID: extensionEntry("Bundled", location: 2, webStore: false, path: "\(Self.externalID)/1.0_0"),
        ]]], "Google/Chrome/Default/Secure Preferences")
        let time = ChromiumHistoryReader.chromiumTime(Date())
        try sqlite("Google/Chrome/Default/History", """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER NOT NULL DEFAULT 0, typed_count INTEGER NOT NULL DEFAULT 0, last_visit_time INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0);
            INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES ('https://weather.example.org/', 'Weather', 4, \(time));
            INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES ('https://tides.example.org/', 'Tides', 2, \(time - 1_000_000));
            INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('https://frame.example.org/', '', 1, \(time), 1);
            """)
        // Counted from a copy, never read: no real login and no password.
        try sqlite("Google/Chrome/Default/Login Data", """
            CREATE TABLE logins(origin_url VARCHAR NOT NULL, blacklisted_by_user INTEGER NOT NULL);
            INSERT INTO logins VALUES ('https://shop.example.com/', 0);
            """)
    }

    private func sources() -> [ImportSource] {
        OnboardingImportPlan.counted(BrowserScanner.scan(applicationSupport: root), applicationSupport: root, extensions: true)
    }

    private func rehearse(_ sources: [ImportSource], _ categories: [ImportCategory], model: BrowserViewModel) -> OnboardingImportOutcome? {
        var outcome: OnboardingImportOutcome?
        FirstRunOnboarding(kind: .rehearsal, model: model) { [] }.bring(sources, categories: categories) { outcome = $0 }
        return outcome
    }

    private func importForReal(_ sources: [ImportSource], _ categories: [ImportCategory], model: BrowserViewModel,
                               replacingFavorites sample: [Tab.ID] = []) -> OnboardingImportOutcome {
        let read = OnboardingImportPlan(sources: sources, categories: categories).read(applicationSupport: root, arcDefaults: { [:] })
        return OnboardingImportPlan.apply(read, model: model, replacingFavorites: sample)
    }

    // MARK: Counts

    func testActTwoCountsWhatTheImportWillBring() throws {
        let found = sources()
        XCTAssertEqual(found.map(\.browser), ["Arc", "Chrome"])
        XCTAssertEqual(found[0].stats, ImportStats(spaces: 1, tabs: 3, extensions: 1),
                       "two pinned tabs and the favorite once; Today tabs stay in Arc")
        XCTAssertEqual(found[0].extensionIDs, [Self.notesID])
        XCTAssertEqual(found[1].stats, ImportStats(bookmarks: 2, pages: 2, passwords: 1, extensions: 2),
                       "web bookmarks, visible pages, and only the extensions that reinstall")
        XCTAssertEqual(Set(found[1].extensionIDs), [Self.notesID, Self.readerID])
        let log = Act2Log(start: 0, sources: found, offered: ImportCategory.allCases)
        XCTAssertEqual(log.totals(at: 0).extensions, 2, "Tab Notes is in both and reinstalls once")
        XCTAssertEqual(log.passwordsLeftBehind(at: 0), "Chrome")
        XCTAssertEqual(log.totals(at: 0).passwords, 0)
    }

    func testActTwoTheRehearsalAndTheImportAgreeForEveryCategory() throws {
        let found = sources()
        let choices: [[ImportCategory]] = [ImportCategory.allCases, [.spaces], [.bookmarks], [.history], [.extensions],
                                           [.spaces, .extensions], [.bookmarks, .history], []]
        for categories in choices {
            var log = Act2Log(start: 0, sources: found, offered: ImportCategory.allCases)
            log.categories = ImportCategory.allCases.filter { !categories.contains($0) }.map { (0, $0) }
            let act2 = log.totals(at: 0)
            let rehearsal = try XCTUnwrap(rehearse(found, categories, model: makeModel()))
            let outcome = importForReal(found, categories, model: makeModel())
            XCTAssertEqual(rehearsal.totals, act2, "rehearsal, \(categories)")
            XCTAssertEqual(outcome.totals, act2, "import, \(categories)")
        }
        // Leaving Chrome behind.
        let arcOnly = [found[0]]
        let outcome = importForReal(arcOnly, ImportCategory.allCases, model: makeModel())
        XCTAssertEqual(outcome.totals, ImportSource.totals(arcOnly, categories: ImportCategory.allCases))
        XCTAssertEqual(outcome.totals.extensions, 1)
    }

    func testArcsFavoritesReplaceTheSamplesRatherThanBeingSkipped() throws {
        let store = SidebarStore.sample()
        let main = store.activeProfileID
        let sample = store.profiles.flatMap { store.favorites(in: $0.id).map(\.id) }
        let shared = try XCTUnwrap(store.favorites(in: main).first?.url)
        try writeArcSidebar(favorite: shared.absoluteString)
        let found = sources()
        let outcome = importForReal(found, [.spaces], model: makeModel(store), replacingFavorites: sample)
        XCTAssertEqual(outcome.totals.tabs, found[0].stats.tabs)
        XCTAssertEqual(store.favorites(in: main).map(\.url), [shared], "Arc's own, not the sample's")
        XCTAssertFalse(sample.contains { store.tab(withID: $0) != nil })
    }

    // MARK: Membership card

    func testArcsCardComesWithArcsSpacesAndActOnesNameGoesOnIt() throws {
        try write(["title": "STATUESQUE HUNTER", "paletteNumber": 3, "shapeName": "Shape4"], "Arc/StorableMembershipCard.json")
        try write(["session": ["user": ["name": "Akilu", "email": "x@example.invalid", "createdAt": 738_929_101.8]]], "Arc/StorableAuthState.json")
        let skipped = makeModel()
        _ = importForReal(sources(), [.bookmarks], model: skipped)
        XCTAssertFalse(skipped.membershipCard.ensureLoaded().hasArcHistory, "no Arc spaces asked for, no card")
        let model = makeModel()
        _ = importForReal(sources(), [.spaces], model: model)
        let card = model.membershipCard.ensureLoaded()
        XCTAssertEqual(card.title, "STATUESQUE HUNTER")
        XCTAssertEqual(card.shape, 4)
        XCTAssertTrue(card.hasArcHistory)
        XCTAssertEqual(model.membershipCardName, "Akilu", "Arc's name until Act 1 gives one")
        model.recordOnboardingName("  Ada ")
        XCTAssertEqual(model.membershipCardName, "Ada")
    }

    // MARK: Extensions

    func testExtensionsAreQueuedForAfterTheSunriseAndSurviveARelaunch() throws {
        let model = makeModel()
        let outcome = importForReal(sources(), ImportCategory.allCases, model: model)
        let pending = try XCTUnwrap(model.pendingExtensionReinstall)
        XCTAssertEqual(pending.queue.items.map(\.name), ["Tab Notes", "Reader"])
        XCTAssertEqual(Set(pending.queue.items.map(\.profileID)), [model.store.activeProfileID])
        XCTAssertEqual(pending.title, "Reinstall 2 extensions from Arc and Google Chrome")
        XCTAssertEqual(outcome.totals.extensions, pending.queue.items.count)
        let tabs = model.store.spaces.flatMap { SidebarTree.tabs(model.store.content(for: $0.id).allLeaves) }
        XCTAssertFalse(tabs.contains { $0.url.host() == "chromewebstore.google.com" }, "no store page opens under the sunrise")
        XCTAssertNil(model.toast)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.pendingExtensionReinstall, pending, "Later survives a relaunch")
    }

    func testTheRehearsalQueuesNothing() throws {
        let model = makeModel()
        let outcome = try XCTUnwrap(rehearse(sources(), ImportCategory.allCases, model: model))
        XCTAssertEqual(outcome.totals.extensions, 2)
        XCTAssertNil(model.pendingExtensionReinstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent(PendingExtensionReinstall.fileName).path))
    }

    func testTheBrowserOffersStartOrLaterOnceTheSunriseIsOver() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        let onboarding = FirstRunOnboarding(kind: .firstRun, model: model) { [] }
        onboarding.onboardingFinished()
        XCTAssertEqual(model.toast?.message, "Reinstall 2 extensions from Arc and Google Chrome")
        XCTAssertEqual(model.toast?.action, .reinstallExtensions)
        model.postponePendingExtensionReinstall()
        XCTAssertNil(model.toast)
        XCTAssertNotNil(model.pendingExtensionReinstall, "Later keeps it")

        let quiet = makeModel()
        quiet.setPendingExtensionReinstall(nil)
        FirstRunOnboarding(kind: .firstRun, model: quiet) { [] }.onboardingFinished()
        XCTAssertNil(quiet.toast, "nothing queued, nothing offered")
    }

    func testStartStepsThroughTheQueueAndSavesEachStep() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        let file = data.appendingPathComponent(PendingExtensionReinstall.fileName)
        let session = BrowserImportSession(model: model, applicationSupport: root, arcDefaults: { [:] })
        session.resumeReinstall(try XCTUnwrap(model.pendingExtensionReinstall).queue)
        XCTAssertEqual(session.reinstall?.progressText, "1 of 2")
        session.nextExtension()
        XCTAssertEqual(PendingExtensionReinstall.load(from: file)?.queue.current?.name, "Reader")
        XCTAssertEqual(model.pendingExtensionReinstall?.title, "Reinstall 1 extension from Arc and Google Chrome")
        session.stopReinstall()
        XCTAssertNil(session.reinstall)
        XCTAssertNil(model.pendingExtensionReinstall, "Stop is done with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheCommandBarOffersTheQueueUntilItIsDone() throws {
        let model = makeModel()
        let context = { CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack(),
                                          pendingExtensionReinstall: model.pendingExtensionReinstall?.title) }
        XCTAssertNil(AppCommandRegistry.all(in: context()).first { $0.id == "reinstall-extensions" })
        _ = importForReal(sources(), [.extensions], model: model)
        let command = try XCTUnwrap(AppCommandRegistry.all(in: context()).first { $0.id == "reinstall-extensions" })
        XCTAssertEqual(command.title, "Reinstall 2 extensions from Arc and Google Chrome…")
        XCTAssertEqual(command.action, .reinstallExtensions)
        XCTAssertTrue(command.isEnabled(in: context()))
        model.setPendingExtensionReinstall(nil)
        XCTAssertFalse(command.isEnabled(in: context()))
    }

    func testTheWelcomePageSaysExtensionsAreQueuedNotHere() {
        let html = WelcomePage.html(name: "", colour: MarkPalette.sun, spaces: 1,
                                    imported: ImportStats(spaces: 1, tabs: 3, extensions: 2))
        XCTAssertTrue(html.contains("1 space  ·  3 tabs came with you."))
        XCTAssertTrue(html.contains("2 extensions are queued to reinstall from the Chrome Web Store."))
        XCTAssertFalse(WelcomePage.html(name: "", colour: MarkPalette.sun, spaces: 1, imported: ImportStats(extensions: 1))
            .contains("came with you"))
    }
}
