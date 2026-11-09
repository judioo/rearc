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
        XCTAssertEqual(pending.title, "Install 2 extensions from Arc and Google Chrome")
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

    func testTheBrowserStartsWithoutPresentingTheImporterOrAConsentSheet() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        FirstRunOnboarding(kind: .firstRun, model: model) { [] }.onboardingFinished()
        XCTAssertNotNil(model.extensionReinstallSession)
        XCTAssertFalse(model.isExtensionReinstallPresented)
        XCTAssertNil(model.browserImportWindow)
        // The WebKit test engine exposes store links only when requested.
        model.startPendingExtensionReinstall()
        XCTAssertTrue(model.isExtensionReinstallPresented)
        XCTAssertNil(model.browserImportWindow)
    }

    func testTerminalResultsSurviveRelaunchWithoutAnotherInstall() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        var pending = try XCTUnwrap(model.pendingExtensionReinstall)
        pending.results = Dictionary(uniqueKeysWithValues: pending.queue.items.map { ($0.key, .init(status: 0, reason: "")) })
        let file = data.appendingPathComponent(PendingExtensionReinstall.fileName)
        PendingExtensionReinstall.save(pending, to: file)
        XCTAssertTrue(try XCTUnwrap(PendingExtensionReinstall.load(from: file)).outstandingItems.isEmpty)
        XCTAssertEqual(PendingExtensionReinstall.read(from: file)?.results, pending.results)
        model.queueExtensionReinstall(pending.queue, from: pending.from)
        XCTAssertTrue(try XCTUnwrap(model.pendingExtensionReinstall).outstandingItems.isEmpty)
    }

    func testTheCommandBarOffersTheQueueUntilItIsDone() throws {
        let model = makeModel()
        let context = { CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: ClosedTabStack(),
                                          pendingExtensionReinstall: model.pendingExtensionReinstall?.title) }
        XCTAssertNil(AppCommandRegistry.all(in: context()).first { $0.id == "reinstall-extensions" })
        _ = importForReal(sources(), [.extensions], model: model)
        let command = try XCTUnwrap(AppCommandRegistry.all(in: context()).first { $0.id == "reinstall-extensions" })
        XCTAssertEqual(command.title, "Install 2 extensions from Arc and Google Chrome…")
        XCTAssertEqual(command.action, .reinstallExtensions)
        XCTAssertTrue(command.isEnabled(in: context()))
        model.setPendingExtensionReinstall(nil)
        XCTAssertFalse(command.isEnabled(in: context()))
    }

    func testTheWelcomePageSaysExtensionsAreQueuedNotHere() {
        let html = WelcomePage.html(name: "", colour: MarkPalette.sun, spaces: 1,
                                    imported: ImportStats(spaces: 1, tabs: 3, extensions: 2))
        XCTAssertTrue(html.contains("1 space  ·  3 tabs came with you."))
        XCTAssertTrue(html.contains("2 extensions are installing from the Chrome Web Store."))
        XCTAssertFalse(WelcomePage.html(name: "", colour: MarkPalette.sun, spaces: 1, imported: ImportStats(extensions: 1))
            .contains("came with you"))
    }

    // MARK: Importing again (QA-483)

    /// A model on the data folder's own sidebar file (the starter when there is none), as a launch makes it.
    private func launch() -> BrowserViewModel {
        let model = BrowserViewModel(
            persistence: SidebarFilePersistence(fileURL: data.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-onboarding-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-onboarding-links-\(UUID().uuidString)")!
        return model
    }

    /// Arc's own Chromium bookmarks: its sidebar's two pinned tabs, as Arc writes them.
    private func writeArcBookmarksMirroringItsSidebar() throws {
        try write(["roots": ["bookmark_bar": ["type": "folder", "children": [
            ["type": "folder", "name": "Studio", "children": [
                ["type": "url", "name": "Notes", "url": "https://notes.example.com/"],
                ["type": "url", "name": "Plans", "url": "https://plans.example.com"],
            ]],
        ]]]], "Arc/User Data/Default/Bookmarks")
    }

    private func spaceNames(_ model: BrowserViewModel) -> [String] { model.store.spaces.map(\.name) }

    /// B1: the bookmarks space Arc's own bookmarks would make is a copy of its sidebar.
    func testArcsOwnBookmarksDoNotMakeASpaceBesideItsSidebar() throws {
        try writeArcBookmarksMirroringItsSidebar()
        let found = sources()
        XCTAssertEqual(found[0].stats.bookmarks, 0, "Act 2 does not count the copies")
        XCTAssertEqual(found[0].bookmarksWithoutSpaces, 2)
        var log = Act2Log(start: 0, sources: found, offered: ImportCategory.allCases)
        let model = makeModel()
        let outcome = importForReal(found, ImportCategory.allCases, model: model)
        XCTAssertEqual(outcome.totals, log.totals(at: 0))
        XCTAssertFalse(spaceNames(model).contains("Arc – Personal"))
        XCTAssertEqual(outcome.spaces.map(\.name), ["Studio", "Google Chrome – Everyday"])

        // Without Arc's spaces its bookmarks are its own, and come.
        log.categories = [(0, .spaces)]
        let bookmarksOnly = makeModel()
        let alone = importForReal(found, [.bookmarks, .history, .extensions], model: bookmarksOnly)
        XCTAssertEqual(alone.totals, log.totals(at: 0))
        XCTAssertTrue(spaceNames(bookmarksOnly).contains("Arc – Personal"))
    }

    /// B3: killed after the import, relaunched, the onboarding run again from the top.
    func testAResumedOnboardingReusesWhatTheInterruptedOneBrought() throws {
        try writeArcBookmarksMirroringItsSidebar()
        let first = launch()
        let starter = try XCTUnwrap(first.store.spaces.first).id
        let profile = first.store.activeProfileID
        XCTAssertEqual(FirstRunOnboarding.forLaunch(first, arguments: [], automated: false), .firstRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("sidebar.json").path),
                      "the starter is saved before anything else, so its profile (and engine folder) are the ones a relaunch uses")
        let once = importForReal(sources(), ImportCategory.allCases, model: first)
        first.persistence.flush()
        let spaces = spaceNames(first)

        let resumed = launch()
        XCTAssertTrue(resumed.isFirstRun)
        XCTAssertEqual(resumed.store.activeProfileID, profile, "no second profile")
        XCTAssertEqual(resumed.onboardingStarter.spaceIDs, [starter], "the marker still knows the starter")
        XCTAssertEqual(FirstRunOnboarding.forLaunch(resumed, arguments: [], automated: false), .firstRun)
        let again = importForReal(sources(), ImportCategory.allCases, model: resumed)
        XCTAssertEqual(spaceNames(resumed), spaces, "nothing imported twice")
        XCTAssertEqual(again.totals, once.totals, "the same counts as one uninterrupted run")
        XCTAssertEqual(again.spaces.map(\.hostID), once.spaces.map(\.hostID), "Act 3 gets every imported space")

        let result = OnboardingResult(name: "Ada", colour: MarkPalette.sun,
                                      spaces: again.spaces.map { OnboardingSpace(hostID: $0.hostID, name: $0.name, icon: $0.icon, colour: $0.colour) },
                                      removedHostIDs: [])
        let starterNow = resumed.onboardingStarter
        OnboardingApplier.apply(result, to: resumed.store, mainProfileID: profile,
                                replacing: starterNow.spaceIDs, starterFavorites: starterNow.favoriteIDs)
        XCTAssertNil(resumed.store.space(withID: starter), "the untouched starter goes")
        XCTAssertEqual(spaceNames(resumed), ["Studio", "Google Chrome – Everyday"])
        XCTAssertTrue(WelcomePage.html(name: "Ada", colour: MarkPalette.sun, spaces: result.spaces.count, imported: again.totals)
            .contains("Your profile and 2 spaces are ready."))
    }

    func testAStarterThePersonUsedIsNotReplaced() throws {
        let first = launch()
        let starter = try XCTUnwrap(first.store.spaces.first).id
        _ = FirstRunOnboarding.forLaunch(first, arguments: [], automated: false)
        // "Onboard later", then browsing.
        first.store.addTab(kind: .today, title: "Mine", url: URL(string: "https://mine.example.com/")!, in: starter)
        first.persistence.flush()
        XCTAssertEqual(launch().onboardingStarter.spaceIDs, [])
    }

    /// B2: File › Import of the same Chrome profile, twice.
    func testImportingAProfileAgainBringsNothingAndSaysImported() throws {
        let model = makeModel()
        let session = BrowserImportSession(model: model, applicationSupport: root, arcDefaults: { [:] })
        let discovered = expectation(description: "discovered")
        session.discover { discovered.fulfill() }
        wait(for: [discovered], timeout: 10)
        let chrome = try XCTUnwrap(session.sources.compactMap { source -> ImportSourceProfile? in
            if case .profile(let p) = source, p.browser == .chrome { return p }
            return nil
        }.first)
        func select() throws -> BrowserImportSession.ProfileDetail {
            session.selection = .profile(chrome)
            let deadline = Date().addingTimeInterval(10)
            while session.detail(for: chrome) == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return try XCTUnwrap(session.detail(for: chrome))
        }
        var detail = try select()
        XCTAssertTrue(session.canImport)
        XCTAssertEqual(session.bookmarkPlan(for: chrome, detail).newLinks, 2)
        XCTAssertEqual(detail.newHistoryPages, 2)
        let imported = expectation(description: "imported")
        session.performImport { imported.fulfill() }
        wait(for: [imported], timeout: 10)
        let spaces = spaceNames(model)
        let pages = model.visitHistory.records.count

        detail = try select()
        XCTAssertTrue(session.bookmarkPlan(for: chrome, detail).isEmpty)
        XCTAssertEqual(detail.newHistoryPages, 0)
        XCTAssertFalse(session.canImport, "nothing new: Import is off")
        XCTAssertTrue(session.isUpToDate, "and reads Imported")
        session.performImport()
        XCTAssertEqual(spaceNames(model), spaces)
        XCTAssertEqual(model.visitHistory.records.count, pages)
        XCTAssertEqual(spaces.filter { $0 == "Google Chrome – Everyday" }.count, 1)
    }

    /// B2: extensions installed by the first import are not queued, or counted, again.
    func testInstalledExtensionsAreNotQueuedAgain() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        var pending = try XCTUnwrap(model.pendingExtensionReinstall)
        pending.results = Dictionary(uniqueKeysWithValues: pending.queue.items.map { ($0.key, .init(status: 0, reason: "")) })
        model.setPendingExtensionReinstall(pending)
        let main = model.store.activeProfileID
        let installed = model.installedExtensionsReader()(main)
        XCTAssertEqual(installed, [Self.notesID, Self.readerID])

        let recounted = OnboardingImportPlan.counted(BrowserScanner.scan(applicationSupport: root), applicationSupport: root,
                                                     extensions: true, installedIDs: installed)
        XCTAssertEqual(recounted.map(\.stats.extensions), [0, 0])
        var read = OnboardingImportPlan(sources: sources(), categories: [.extensions]).read(applicationSupport: root, arcDefaults: { [:] })
        read.installedExtensionIDs = installed
        let outcome = OnboardingImportPlan.apply(read, model: model)
        XCTAssertEqual(outcome.totals.extensions, 0, "\"0 installing\", not 2")
        XCTAssertTrue(try XCTUnwrap(model.pendingExtensionReinstall).outstandingItems.isEmpty)
        XCTAssertEqual(Set(try XCTUnwrap(model.pendingExtensionReinstall).skipped?.filter { $0.reason == "already installed" }.map(\.id) ?? []),
                       [Self.notesID, Self.readerID])
    }

    /// B4: under the sunrise nothing installs and no install toast plays; it shows once the browser is back.
    func testInstallToastsWaitForTheBrowser() throws {
        let model = makeModel()
        _ = importForReal(sources(), [.extensions], model: model)
        let onboarding = FirstRunOnboarding(kind: .firstRun, model: model) { [] }
        onboarding.start()
        XCTAssertTrue(model.extensionFeedbackHeld)
        model.installPendingExtensions()
        XCTAssertNil(model.extensionReinstallSession, "nothing installs under the sunrise")
        model.showExtensionToast("Installing extensions… 1 of 2", duration: 3600)
        model.showExtensionToast("2 extensions installed")
        XCTAssertNil(model.toast, "held, not played unseen")

        onboarding.onboardingFinished()
        XCTAssertFalse(model.extensionFeedbackHeld)
        XCTAssertNotNil(model.extensionReinstallSession, "installs start with the browser on screen")
        XCTAssertNil(model.heldExtensionToast)
    }

    func testAHeldResultShowsWhenReleased() {
        let model = makeModel()
        model.holdExtensionFeedback()
        model.showExtensionToast("Installing extensions… 1 of 18", duration: 3600)
        model.showExtensionToast("18 extensions installed")
        XCTAssertNil(model.toast)
        model.releaseExtensionFeedback()
        XCTAssertEqual(model.toast?.message, "18 extensions installed", "the latest, the result")
        model.showExtensionToast("Installing extensions… 1 of 2", duration: 3600)
        XCTAssertEqual(model.toast?.message, "Installing extensions… 1 of 2", "not held once the browser is back")
    }

    /// B10: after Spaces & Sidebar came over, the pane says so instead of "0 spaces".
    func testSpacesAndSidebarSaysWhatCameOver() throws {
        let model = makeModel()
        let session = BrowserImportSession(model: model, applicationSupport: root, arcDefaults: { [:] })
        let discovered = expectation(description: "discovered")
        session.discover { discovered.fulfill() }
        wait(for: [discovered], timeout: 10)
        session.selection = .arcSidebar
        XCTAssertEqual(session.arcHeadline, "1 space · 2 pinned tabs · 1 favorite")
        let arcSpace = try XCTUnwrap(session.arc?.export.spaces.first)
        XCTAssertFalse(session.isImported(arcSpace))
        session.performImport()
        XCTAssertTrue(session.arcSummary.isEmpty)
        XCTAssertTrue(session.isImported(arcSpace))
        XCTAssertEqual(session.arcHeadline, "1 space · 2 pinned tabs imported")
        XCTAssertTrue(session.isUpToDate)
        XCTAssertFalse(session.canImport)
    }
}
