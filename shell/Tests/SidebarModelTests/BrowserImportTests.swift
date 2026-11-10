import XCTest
@testable import SidebarModel

/// Importing from Arc, Chrome and Brave by reading their files
/// (PROFILE-IMPORT.md). Every input is the invented `BrowserImportFixture`.
final class BrowserImportTests: XCTestCase {
    private var fixture: BrowserImportFixture!

    override func setUpWithError() throws {
        fixture = try BrowserImportFixture()
    }

    override func tearDown() {
        fixture.remove()
    }

    private func arcExport() throws -> ArcSidebarExport {
        try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar()))
    }

    // MARK: Arc sidebar reader

    func testArcSpacesFollowTheSyncOrderThatCoversTheMostSpaces() throws {
        let export = try arcExport()
        XCTAssertEqual(export.spaces.map(\.name), ["Side", "Work", "Plain"])
        XCTAssertEqual(export.spaces.map(\.profile), [.custom(directory: "Profile 1"), .default, .default])
        XCTAssertEqual(export.profiles, [.custom(directory: "Profile 1"), .default])
    }

    func testArcPinnedTreeKeepsFoldersSplitsRenamesAndIcons() throws {
        let work = try XCTUnwrap(arcExport().spaces.first { $0.name == "Work" })
        XCTAssertEqual(work.icon, "🧪")
        XCTAssertEqual(work.pinnedTabCount, 5)
        XCTAssertEqual(work.folderCount, 2)
        XCTAssertEqual(work.todayTabCount, 1)
        guard work.pinned.count == 3,
              case .tab(let first) = work.pinned[0],
              case .folder("Projects", _, let projects, _) = work.pinned[1],
              case .split(nil, .horizontal, let panes, _) = work.pinned[2] else {
            return XCTFail("unexpected tree \(work.pinned)")
        }
        XCTAssertEqual(first.title, "Start Here")
        XCTAssertEqual(first.customTitle, "Handbook")
        XCTAssertEqual(first.icon, .emoji("📘"))
        XCTAssertTrue(first.isUnread)
        XCTAssertEqual(first.url.absoluteString, "https://docs.example.com/start")
        guard projects.count == 2, case .folder("Archive", _, let archive, _) = projects[1] else { return XCTFail("\(projects)") }
        XCTAssertEqual(archive.count, 1)
        XCTAssertEqual(panes.map(\.title), ["Mail", "Calendar"])
    }

    func testArcReaderCountsWhatReArcCannotHold() throws {
        let dropped = try arcExport().dropped
        XCTAssertEqual(dropped.easels, 1)
        XCTAssertEqual(dropped.nonWebTabs, 1)
        XCTAssertEqual(dropped.unknownItems, 0)
    }

    func testArcThemesMapGradientThirdColourIntensityGrainAndTexture() throws {
        let export = try arcExport()
        let work = try XCTUnwrap(export.spaces.first { $0.name == "Work" }?.theme)
        XCTAssertEqual(work.red, 0.4, accuracy: 1e-9)
        XCTAssertEqual(work.gradientColors, [SpaceColor(red: 0.5, green: 0.5, blue: 0.86), SpaceColor(red: 0.36, green: 0.85, blue: 0.72)])
        XCTAssertEqual(work.intensity, 0.7, accuracy: 1e-9)
        XCTAssertEqual(work.noise, 0.25, accuracy: 1e-9)
        XCTAssertEqual(work.texture, .sand)
        let side = try XCTUnwrap(export.spaces.first { $0.name == "Side" })
        XCTAssertEqual(side.theme?.gradientColors, [])
        XCTAssertEqual(side.icon, "star.fill")
        XCTAssertNil(export.spaces.first { $0.name == "Plain" }?.theme)
    }

    func testArcFavoritesArePerProfile() throws {
        let favorites = try arcExport().favorites
        XCTAssertEqual(favorites[.default]?.map(\.title), ["Chat", "Music"])
        XCTAssertEqual(favorites[.custom(directory: "Profile 1")]?.map(\.title), ["Recipes"])
    }

    func testANonArcFileIsRefused() {
        XCTAssertThrowsError(try ArcSidebarReader.parse(Data("{\"version\":1}".utf8)))
        XCTAssertThrowsError(try ArcSidebarReader.parse(Data("not json".utf8)))
    }

    // MARK: Arc sidebar import

    private func arcSource() throws -> ArcSidebarImport {
        ArcSidebarImport(export: try arcExport(), profileNames: ["Default": "Home", "Profile 1": "Studio"])
    }

    func testDefaultChoicesTakeEverySpaceAndNewProfilesForOtherArcProfiles() throws {
        let store = SidebarStore()
        let source = try arcSource()
        let choices = source.defaultChoices(for: store)
        XCTAssertEqual(choices.spaceIDs.count, 3)
        XCTAssertEqual(choices.profileTargets[.default], .existing(store.activeProfileID))
        XCTAssertEqual(choices.profileTargets[.custom(directory: "Profile 1")], .newProfile)
        XCTAssertFalse(choices.includeToday)
        let summary = source.summary(for: choices)
        XCTAssertEqual(summary.spaces, 3)
        XCTAssertEqual(summary.pinnedTabs, 6)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertEqual(summary.todayTabs, 0)
        XCTAssertEqual(summary.favorites, 3)
        XCTAssertEqual(summary.newProfiles, 1)
    }

    func testAnArcProfileGoesToTheReArcProfileOfTheSameName() throws {
        let store = SidebarStore()
        let studio = store.addProfile(name: "studio")
        XCTAssertEqual(try arcSource().defaultChoices(for: store).profileTargets[.custom(directory: "Profile 1")], .existing(studio.id))
    }

    func testImportBuildsSpacesWithTheirTreeThemeAndIcon() throws {
        let store = SidebarStore()
        let existing = store.spaces.map(\.id)
        let source = try arcSource()
        let summary = store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        XCTAssertEqual(summary.spaces, 3)
        XCTAssertEqual(summary.pinnedTabs, 6)
        XCTAssertEqual(summary.newProfiles, 1)
        XCTAssertTrue(existing.allSatisfy { store.space(withID: $0) != nil }, "existing spaces stay")

        let work = try XCTUnwrap(store.spaces.first { $0.name == "Work" })
        XCTAssertEqual(work.iconName, "🧪")
        XCTAssertEqual(work.theme.texture, .sand)
        XCTAssertEqual(work.profileID, existing.first.flatMap { store.space(withID: $0)?.profileID })
        let pinned = store.content(for: work.id).pinned
        guard pinned.count == 3, case .tab(let handbook) = pinned[0], case .folder(let projects) = pinned[1],
              case .split(let split) = pinned[2] else { return XCTFail("\(pinned)") }
        XCTAssertEqual(handbook.kind, .pinned)
        XCTAssertEqual(handbook.displayTitle, "Handbook")
        XCTAssertEqual(handbook.savedURL?.absoluteString, "https://docs.example.com/start")
        XCTAssertEqual(handbook.customIcon, .emoji("📘"))
        XCTAssertEqual(projects.title, "Projects")
        XCTAssertEqual(projects.children.count, 2)
        XCTAssertFalse(store.expandedFolderIDs.contains(projects.id), "imported folders start closed")
        XCTAssertEqual(split.tabs.map(\.title), ["Mail", "Calendar"])
        XCTAssertTrue(store.content(for: work.id).today.isEmpty, "Today stays behind unless chosen")
        XCTAssertEqual(store.folder(withID: projects.id)?.title, "Projects", "the index sees imported folders")
        XCTAssertEqual(store.tab(withID: handbook.id)?.url, handbook.url)
    }

    func testImportPutsOtherArcProfilesInANewProfileWithItsFavorites() throws {
        let store = SidebarStore()
        let source = try arcSource()
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        let studio = try XCTUnwrap(store.profiles.first { $0.name == "Studio" })
        XCTAssertEqual(store.spaces(in: studio.id).map(\.name), ["Side"], "the new profile's empty first space goes")
        XCTAssertEqual(store.favorites(in: studio.id).map(\.title), ["Recipes"])
        XCTAssertEqual(store.favorites(in: store.profiles[0].id).map(\.title), ["Chat", "Music"])
    }

    func testImportHonoursTheChoices() throws {
        let store = SidebarStore()
        let source = try arcSource()
        var choices = source.defaultChoices(for: store)
        choices.spaceIDs = [BrowserImportFixture.work]
        choices.includeToday = true
        choices.includeFavorites = false
        XCTAssertEqual(source.summary(for: choices).newProfiles, 0)
        let summary = store.importArcSidebar(source, choices: choices)
        XCTAssertEqual(summary.spaces, 1)
        XCTAssertEqual(summary.todayTabs, 1)
        XCTAssertEqual(summary.favorites, 0)
        XCTAssertEqual(store.profiles.count, 1)
        let work = try XCTUnwrap(store.spaces.first { $0.name == "Work" })
        XCTAssertEqual(store.content(for: work.id).today.count, 1)
        XCTAssertEqual(store.activeSpaceID, work.id, "the first imported space is shown")
    }

    func testImportingFavoritesTwiceSkipsTheOnesAlreadyThere() throws {
        let store = SidebarStore()
        let source = try arcSource()
        var choices = source.defaultChoices(for: store)
        choices.spaceIDs = []
        XCTAssertEqual(store.importArcSidebar(source, choices: choices).favorites, 2)
        XCTAssertEqual(store.importArcSidebar(source, choices: choices).favorites, 0)
        XCTAssertEqual(store.favorites.count, 2)
    }

    func testImportedRowsAreJournaledForSync() throws {
        let store = SidebarStore()
        let source = try arcSource()
        var choices = source.defaultChoices(for: store)
        choices.spaceIDs = [BrowserImportFixture.work]
        choices.includeFavorites = false
        store.importArcSidebar(source, choices: choices)
        let mutations = store.mutationJournal.allEntries().map(\.mutation)
        let inserts = mutations.filter { if case .insertItem = $0 { return true }; return false }
        let placed = mutations.filter { if case .placeItemInFolder = $0 { return true }; return false }
        XCTAssertEqual(inserts.count, 3)
        XCTAssertEqual(placed.count, 3)
    }

    func testImportedSpacesSurviveASnapshotRoundTrip() throws {
        let store = SidebarStore()
        let source = try arcSource()
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        XCTAssertEqual(Set(restored.spaces.map(\.name)), Set(store.spaces.map(\.name)))
        let work = try XCTUnwrap(restored.spaces.first { $0.name == "Work" })
        func describe(_ e: [SidebarEntry]) -> String { e.map { entry -> String in
            switch entry { case .tab(let t): return t.title; case .folder(let f): return "[\(f.title): \(describe(f.children))]"
            case .split(let s): return "{\(s.tabs.map(\.title))}"; case .easel: return "easel" } }.joined(separator: ", ") }
        XCTAssertEqual(describe(restored.content(for: work.id).pinned), describe(store.content(for: work.id).pinned))
        XCTAssertEqual(restored.content(for: work.id).pinnedLeaves.count, 4, "a split is one row")
    }

    // MARK: Discovery

    func testDiscoveryLeavesOutArcsInternalProfile() throws {
        try fixture.installBrowsers()
        try fixture.write(BrowserImportFixture.localState([("Default", "Home"), ("Profile 1", "Studio"), ("Profile 3", "__ARC_SYSTEM_PROFILE")]),
                          to: "Arc/User Data/Local State")
        try fixture.write([:] as [String: Any], to: "Arc/User Data/Profile 3/Preferences")
        let arc = try XCTUnwrap(BrowserImportDiscovery.discover(in: fixture.root).first { $0.browser == .arc })
        XCTAssertEqual(arc.profiles.map(\.directory), ["Default", "Profile 1"])
    }

    func testDiscoveryFindsInstalledBrowsersAndTheirProfiles() throws {
        try fixture.installBrowsers()
        let found = BrowserImportDiscovery.discover(in: fixture.root)
        XCTAssertEqual(found.map(\.browser), [.arc, .chrome])
        let arc = try XCTUnwrap(found.first { $0.browser == .arc })
        XCTAssertNotNil(arc.sidebarFile)
        XCTAssertEqual(arc.profiles.map(\.name), ["Home", "Studio"])
        let chrome = try XCTUnwrap(found.first { $0.browser == .chrome })
        XCTAssertEqual(chrome.profiles.map(\.directory), ["Profile 2", "Default"], "Local State order; folders without Preferences skipped")
        XCTAssertEqual(chrome.profiles.map(\.name), ["Weekend", "Everyday"])
        XCTAssertNil(chrome.sidebarFile)
    }

    func testInventoryCountsWithoutOpeningSecrets() throws {
        try fixture.installBrowsers()
        let chrome = try XCTUnwrap(BrowserImportDiscovery.discover(.chrome, in: fixture.root))
        let profile = try XCTUnwrap(chrome.profiles.first { $0.directory == "Default" })
        // A Login Data that is not even SQLite: inventory only notes it exists.
        try Data("secret".utf8).write(to: profile.url.appendingPathComponent("Login Data"))
        let inventory = BrowserImportDiscovery.inventory(of: profile)
        XCTAssertEqual(inventory.bookmarks, 3)
        XCTAssertEqual(inventory.historyPages, 3)
        XCTAssertEqual(inventory.extensions, 3)
        XCTAssertTrue(inventory.hasPasswords)
        XCTAssertFalse(inventory.hasCookies)
        let empty = try XCTUnwrap(chrome.profiles.first { $0.directory == "Profile 2" })
        XCTAssertNil(BrowserImportDiscovery.inventory(of: empty).historyPages)
    }

    func testArcSidebarAloneIsStillASource() throws {
        try fixture.write(BrowserImportFixture.arcSidebar(), to: "Arc/StorableSidebar.json")
        let arc = try XCTUnwrap(BrowserImportDiscovery.discover(.arc, in: fixture.root))
        XCTAssertTrue(arc.profiles.isEmpty)
        XCTAssertNotNil(arc.sidebarFile)
        XCTAssertNil(BrowserImportDiscovery.discover(.brave, in: fixture.root))
    }

    func testArcImportLoadsProfileNamesFromLocalState() throws {
        try fixture.installBrowsers()
        let source = try ArcSidebarImport.load(from: fixture.root)
        XCTAssertEqual(source.name(of: .default), "Home")
        XCTAssertEqual(source.name(of: .custom(directory: "Profile 1")), "Studio")
        XCTAssertEqual(source.name(of: .custom(directory: "Profile 7")), "Profile 7")
    }

    func testSnapshotsAreCopiesInTheirOwnFolder() throws {
        let source = fixture.root.appendingPathComponent("History")
        try BrowserImportFixture.writeHistory(to: source, now: Date())
        let snapshot = try SQLiteSnapshot(copying: source)
        XCTAssertNotEqual(snapshot.url, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.path))
        snapshot.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source is untouched")
    }

    // MARK: Bookmarks and history

    func testBookmarkAndArcTabImportsRejectCredentialsInURLs() throws {
        for href in ["https://user:pass@example.org/", "https://user@example.org/", "https://:pass@example.org/", "https://@example.org/"] {
            let bookmarks: [String: Any] = ["roots": ["bookmark_bar": ["children": [["type": "url", "url": href]]]]]
            XCTAssertTrue(try ChromiumBookmarksReader.parse(JSONSerialization.data(withJSONObject: bookmarks)).isEmpty, href)
            // Replace a known web tab wherever the fixture stores it, including
            // inside Arc's alternating ID/value arrays.
            let original = try JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar(), options: [.withoutEscapingSlashes])
            let json = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "https://docs.example.com/start", with: href)
            let arc = try ArcSidebarReader.parse(Data(json.utf8))
            XCTAssertEqual(arc.dropped.nonWebTabs, 2, href)
        }
    }

    func testExtensionLocaleNamesCannotEscapeTheLocalesDirectory() throws {
        for locale in ["en", "en_US", "es_419", "zh_Hant_TW", "pt-BR"] { XCTAssertTrue(ExtensionInventoryReader.isLocaleName(locale), locale) }
        for locale in ["", "..", "../../outside", "/en", "en/US", "en_US/..", "en@US", "en_US\n"] {
            XCTAssertFalse(ExtensionInventoryReader.isLocaleName(locale), locale)
        }
        let extensionFolder = try fixture.folder("Extension/_locales").deletingLastPathComponent()
        try fixture.write(["name": ["message": "Outside"]], to: "outside/messages.json")
        XCTAssertNil(ExtensionInventoryReader.localized("__MSG_name__", defaultLocale: "../../outside", folder: extensionFolder))
        try fixture.write(["name": ["message": "Fallback"]], to: "Extension/_locales/en/messages.json")
        XCTAssertEqual(ExtensionInventoryReader.localized("__MSG_name__", defaultLocale: "../../outside", folder: extensionFolder), "Fallback")
    }

    func testChromiumBookmarksBecomeTheBarThenOtherBookmarks() throws {
        let nodes = try ChromiumBookmarksReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.bookmarks))
        XCTAssertEqual(nodes, [
            .link(title: "Reading List", url: URL(string: "https://read.example.com/")!),
            .folder(title: "Tools", children: [.link(title: "Converter", url: URL(string: "https://convert.example.org/")!)]),
            .folder(title: "Other Bookmarks", children: [.link(title: "untitled.example.net", url: URL(string: "https://untitled.example.net/page")!)]),
        ])
        XCTAssertThrowsError(try ChromiumBookmarksReader.parse(Data("[]".utf8)))
    }

    func testChromiumBookmarksImportIntoASpaceOfTheChosenProfile() throws {
        let store = SidebarStore()
        let other = store.addProfile(name: "Weekend")
        let nodes = try ChromiumBookmarksReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.bookmarks))
        let result = try XCTUnwrap(store.importBookmarks(nodes, spaceName: "Chrome", profileID: other.id))
        XCTAssertEqual(result.tabs, 3)
        XCTAssertEqual(result.space.profileID, other.id)
    }

    func testHistoryReadsVisibleWebPagesNewestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = fixture.root.appendingPathComponent("History")
        try BrowserImportFixture.writeHistory(to: url, now: now)
        let records = try ChromiumHistoryReader.read(url)
        XCTAssertEqual(records.map(\.url.host), ["read.example.com", "weather.example.org"])
        XCTAssertEqual(records[0].visitCount, 12)
        XCTAssertEqual(records[0].lastVisit.timeIntervalSince1970, now.timeIntervalSince1970 - 60, accuracy: 0.001)
        XCTAssertEqual(try ChromiumHistoryReader.read(url, limit: 1).count, 1)
        XCTAssertEqual(ChromiumHistoryReader.pageCount(url), 3)
        XCTAssertThrowsError(try ChromiumHistoryReader.read(fixture.root.appendingPathComponent("Missing")))
    }

    func testChromiumTimeIsMicrosecondsSince1601() {
        XCTAssertEqual(ChromiumHistoryReader.date(chromiumTime: 11_644_473_600_000_000).timeIntervalSince1970, 0)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ChromiumHistoryReader.date(chromiumTime: ChromiumHistoryReader.chromiumTime(date)), date)
    }

    func testMergingHistoryTwiceChangesNothing() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var history = VisitHistory(records: [VisitRecord(url: URL(string: "https://read.example.com")!, title: "", visitCount: 2,
                                                         firstVisit: day.addingTimeInterval(-86_400), lastVisit: day.addingTimeInterval(-86_400))])
        let imported = [
            VisitRecord(url: URL(string: "https://read.example.com/")!, title: "Reading List", visitCount: 12, firstVisit: day, lastVisit: day),
            VisitRecord(url: URL(string: "https://weather.example.org/today")!, title: "Weather", visitCount: 3, firstVisit: day, lastVisit: day),
        ]
        XCTAssertEqual(history.merge(imported), 1)
        let merged = history
        XCTAssertEqual(history.merge(imported), 0)
        XCTAssertEqual(history, merged)
        let read = try? XCTUnwrap(history.record(for: URL(string: "https://read.example.com")!))
        XCTAssertEqual(read?.visitCount, 12)
        XCTAssertEqual(read?.title, "Reading List")
        XCTAssertEqual(read?.firstVisit, day.addingTimeInterval(-86_400))
        XCTAssertEqual(history.matches(for: "weather", now: day).first?.record.title, "Weather", "merged pages are searchable")
    }

    // MARK: Extensions

    func testExtensionInventoryReadsNamesStateAndOrigin() throws {
        try fixture.installBrowsers()
        let profile = fixture.root.appendingPathComponent("Google/Chrome/Default")
        let extensions = ExtensionInventoryReader.read(profile: profile)
        XCTAssertEqual(extensions.filter { !$0.isComponent }.map(\.name), ["My Dev Tool", "Quiet Mode", "Tab Notes"])
        let notes = try XCTUnwrap(extensions.first { $0.id == BrowserImportFixture.webStoreID })
        XCTAssertEqual(notes.origin, .webStore)
        XCTAssertTrue(notes.isEnabled)
        XCTAssertTrue(notes.isPinned)
        XCTAssertEqual(notes.version, "1.2.0")
        let quiet = try XCTUnwrap(extensions.first { $0.id == BrowserImportFixture.disabledID })
        XCTAssertFalse(quiet.isEnabled)
        XCTAssertEqual(quiet.origin, .webStore, "a Web Store update URL counts")
        let dev = try XCTUnwrap(extensions.first { $0.id == BrowserImportFixture.unpackedID })
        guard case .unpacked(let path) = dev.origin else { return XCTFail("\(dev.origin)") }
        XCTAssertTrue(path.hasSuffix("Developer/my-dev-tool"))
        XCTAssertFalse(dev.canReinstall, "unpacked extensions always require a manual load")
    }

    func testAnExistingUnpackedFolderNeverEntersTheInstallQueue() throws {
        try fixture.installBrowsers()
        let inventory = ExtensionInventoryReader.read(profile: fixture.root.appendingPathComponent("Google/Chrome/Default"))
        let dev = try XCTUnwrap(inventory.first { $0.id == BrowserImportFixture.unpackedID })
        let consolidation = ExtensionConsolidation([dev])
        XCTAssertTrue(consolidation.candidates.isEmpty)
        XCTAssertTrue(consolidation.skipped.first?.reason.hasPrefix("load manually: ") == true)
        XCTAssertTrue(ExtensionReinstallQueue([dev], into: UUID()).isFinished)
    }

    func testPersistedQueuesRejectUnpackedItemsAndKeepStoreProgress() throws {
        let source = SourceExtension(id: BrowserImportFixture.webStoreID, name: "Notes", version: "1", isEnabled: true,
                                     isPinned: false, isTheme: false, origin: .webStore)
        let queue = ExtensionReinstallQueue([source], into: UUID())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        let store = try XCTUnwrap((raw["items"] as? [[String: Any]])?.first)
        var unpacked = store
        unpacked["id"] = BrowserImportFixture.unpackedID
        unpacked["origin"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SourceExtension.Origin.unpacked(path: fixture.root.path)))
        raw["items"] = [unpacked, store]
        raw["position"] = 1
        let decoded = try JSONDecoder().decode(ExtensionReinstallQueue.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(decoded.items.map(\.id), [source.id])
        XCTAssertEqual(decoded.position, 0, "only the discarded unpacked item was completed")
        XCTAssertEqual(decoded.current?.origin, .webStore)
    }

    func testOlderProfilesKeepTheEnabledStateInState() {
        XCTAssertTrue(ExtensionInventoryReader.isEnabled([:]))
        XCTAssertTrue(ExtensionInventoryReader.isEnabled(["state": 1]))
        XCTAssertFalse(ExtensionInventoryReader.isEnabled(["state": 0]))
        XCTAssertFalse(ExtensionInventoryReader.isEnabled(["disable_reasons": [8192]]))
        XCTAssertTrue(ExtensionInventoryReader.isEnabled(["disable_reasons": []]))
        XCTAssertFalse(ExtensionInventoryReader.isExtensionID("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP"))
    }

    func testReinstallQueueWalksTheReinstallableExtensionsInOrder() {
        let profile = UUID()
        let extensions = [
            SourceExtension(id: BrowserImportFixture.webStoreID, name: "Tab Notes", version: "1", isEnabled: true, isPinned: true, isTheme: false, origin: .webStore),
            SourceExtension(id: BrowserImportFixture.componentID, name: "Policy", version: "1", isEnabled: true, isPinned: false, isTheme: false, origin: .other),
            SourceExtension(id: BrowserImportFixture.unpackedID, name: "Gone", version: "1", isEnabled: true, isPinned: false, isTheme: false,
                            origin: .unpacked(path: "/nonexistent/folder")),
            SourceExtension(id: BrowserImportFixture.disabledID, name: "Quiet Mode", version: "1", isEnabled: false, isPinned: false, isTheme: false, origin: .webStore),
        ]
        var queue = ExtensionReinstallQueue(extensions, into: profile)
        XCTAssertEqual(queue.items.map(\.name), ["Tab Notes"])
        XCTAssertEqual(queue.progressText, "1 of 1")
        XCTAssertEqual(queue.current?.profileID, profile)
        queue.advance()
        XCTAssertNil(queue.current)
        queue.advance()
        XCTAssertTrue(queue.isFinished)
        XCTAssertNil(queue.progressText)
        queue.advance()
        XCTAssertEqual(queue.remaining, 0)
        XCTAssertEqual(ExtensionReinstallQueue.storeURL(for: BrowserImportFixture.webStoreID).absoluteString,
                       "https://chromewebstore.google.com/detail/\(BrowserImportFixture.webStoreID)")
    }

    func testTheQueueTakesAnExtensionOnceAndSurvivesARelaunch() throws {
        let profile = UUID()
        let notes = SourceExtension(id: BrowserImportFixture.webStoreID, name: "Tab Notes", version: "1", isEnabled: true,
                                    isPinned: false, isTheme: false, origin: .webStore)
        let quiet = SourceExtension(id: BrowserImportFixture.disabledID, name: "Quiet Mode", version: "1", isEnabled: false,
                                    isPinned: false, isTheme: false, origin: .webStore)
        // From Arc, then the same one again from Chrome.
        var queue = ExtensionReinstallQueue([notes, quiet, notes], into: profile)
        XCTAssertEqual(queue.items.map(\.id), [BrowserImportFixture.webStoreID])
        queue.advance()
        let saved = try JSONDecoder().decode(ExtensionReinstallQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(saved, queue)
        XCTAssertNil(saved.current, "disabled extensions are excluded")
    }

    func testOnlyTheChosenArcProfilesComeOver() throws {
        let arc = ArcSidebarImport(export: try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar())))
        XCTAssertEqual(arc.favoritesToImport(), 3)
        let side = arc.only(directories: ["Profile 1"])
        XCTAssertEqual(side.export.spaces.map(\.name), ["Side"])
        XCTAssertEqual(side.export.profiles, [.custom(directory: "Profile 1")])
        XCTAssertEqual(side.favoritesToImport(), 1, "the default profile's favorites stay behind")
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let summary = store.importArcSidebar(side, choices: side.defaultChoices(for: store))
        XCTAssertEqual(summary.spaces, 1)
        XCTAssertEqual(summary.favorites, side.favoritesToImport())
        XCTAssertEqual(arc.only(directories: []).favoritesToImport(), 0)
    }

    // MARK: Setup

    func testProfileSetupReadsSearchEngineStartupAndTheme() throws {
        let setup = ChromiumProfileSetup.parse(try JSONSerialization.data(withJSONObject: BrowserImportFixture.preferences()))
        XCTAssertEqual(setup.searchEngine?.name, "DuckDuckGo")
        XCTAssertEqual(setup.searchEngine?.keyword, "duckduckgo.com")
        XCTAssertEqual(setup.startup, .openURLs)
        XCTAssertEqual(setup.startupPageCount, 2)
        XCTAssertEqual(setup.themeExtensionID, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
        XCTAssertEqual(ChromiumProfileSetup.parse(Data("{}".utf8)), ChromiumProfileSetup())
    }

    func testArcSettingsMapOntoReArcsOwn() {
        let settings = ArcSettingsImport.read([
            "shouldWarnBeforeQuitting": false,
            "arc_quitAlwaysKeepsWindows": true,
            "openExternalLinksInLittleBrowserEnabled": false,
            "autoArchiveTimeThreshold": "sevenDays",
            "autoArchiveLittleArcTimeThreshold": "unknownValue",
            "machineID": "ignored",
        ])
        XCTAssertEqual(settings.warnBeforeQuitting, false)
        XCTAssertEqual(settings.restoreWindows, true)
        XCTAssertEqual(settings.externalLinkDestination, .activeSpace)
        XCTAssertEqual(settings.autoArchive, .sevenDays)
        XCTAssertNil(settings.littleArcArchive)
        XCTAssertEqual(settings.count, 4)
        XCTAssertEqual(ArcSettingsImport.read([:]).count, 0)
    }

    // MARK: Passwords (fixtures only; no Keychain)

    func testSafeStorageKeyMatchesChromiumsKnownAnswer() throws {
        // Chromium keychain_key_provider_unittest: PBKDF2-HMAC-SHA1("mock_password", "saltysalt", 1003).
        let key = try XCTUnwrap(ChromiumSafeStorage.key(password: "mock_password"))
        XCTAssertEqual(Array(key), [0xAF, 0x0F, 0x76, 0x2A, 0xAF, 0x6D, 0x7D, 0x11, 0x58, 0x1B, 0x7A, 0xA8, 0xCE, 0x72, 0x18, 0xDE])
    }

    func testSafeStorageRoundTripsAndRefusesOtherBlobs() throws {
        let key = try XCTUnwrap(ChromiumSafeStorage.key(password: "invented-fixture-secret"))
        let blob = try XCTUnwrap(ChromiumSafeStorage.encrypt(Data("hunter2".utf8), key: key))
        XCTAssertEqual(blob.prefix(3), Data("v10".utf8))
        XCTAssertEqual(ChromiumSafeStorage.decrypt(blob, key: key), Data("hunter2".utf8))
        XCTAssertNil(ChromiumSafeStorage.decrypt(Data("v11abc".utf8), key: key))
        let wrong = try XCTUnwrap(ChromiumSafeStorage.key(password: "other"))
        XCTAssertNotEqual(ChromiumSafeStorage.decrypt(blob, key: wrong), Data("hunter2".utf8))
    }

    func testLoginReaderDecryptsAFixtureAndWritesChromiumsCSV() throws {
        let key = try XCTUnwrap(ChromiumSafeStorage.key(password: "invented-fixture-secret"))
        let blob = try XCTUnwrap(ChromiumSafeStorage.encrypt(Data("p,ss\"word".utf8), key: key))
        let url = fixture.root.appendingPathComponent("Login Data")
        try BrowserImportFixture.sqlite(url, [
            "CREATE TABLE logins (origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB, signon_realm VARCHAR NOT NULL, blacklisted_by_user INTEGER NOT NULL)",
            "INSERT INTO logins VALUES ('https://login.example.com/', 'sam@example.com', ?, 'https://login.example.com/', 0)",
        ], bind: blob)
        try BrowserImportFixture.sqlite(url, [
            "INSERT INTO logins VALUES ('https://never.example.com/', '', ?, 'https://never.example.com/', 1)",
        ], bind: Data())
        let logins = try ChromiumLoginReader.read(url, key: key)
        XCTAssertEqual(logins, [ImportedLogin(url: "https://login.example.com/", username: "sam@example.com", password: "p,ss\"word")])
        XCTAssertEqual(ChromiumLoginReader.csv(logins),
                       "name,url,username,password,note\nlogin.example.com,https://login.example.com/,sam@example.com,\"p,ss\"\"word\",\n")
    }

    func testConsentNamesTheKeychainItemOfThatBrowserOnly() {
        XCTAssertEqual(ImportBrowser.arc.safeStorageService, "Arc Safe Storage")
        XCTAssertEqual(ImportBrowser.brave.safeStorageService, "Brave Safe Storage")
        let consent = SecretImportConsent(browser: .chrome, kinds: [.passwords])
        XCTAssertTrue(consent.explanation.contains("\u{201C}Chrome Safe Storage\u{201D}"))
        XCTAssertFalse(consent.explanation.contains("Brave"))
    }
    func testExtensionConsolidationAcrossBrowsersAndProfiles() {
        let enabled = SourceExtension(id: BrowserImportFixture.webStoreID, name: "Notes", version: "1", isEnabled: true,
                                      isPinned: false, isTheme: false, origin: .webStore)
        var disabled = enabled
        disabled.isEnabled = false
        let duplicates = ExtensionConsolidation([disabled, enabled, disabled])
        XCTAssertEqual(duplicates.totalFound, 3)
        XCTAssertEqual(duplicates.uniqueCount, 1)
        XCTAssertEqual(duplicates.candidates, [enabled])
        XCTAssertEqual(duplicates.skipped.map(\.reason), ["duplicate", "duplicate"])
        XCTAssertEqual(ExtensionConsolidation([disabled, disabled]).candidates, [])
        XCTAssertEqual(ExtensionConsolidation([disabled]).skipped.first?.reason, "disabled")
        XCTAssertTrue(ExtensionConsolidation([enabled], installedIDs: [enabled.id]).candidates.isEmpty)
        XCTAssertTrue(ExtensionConsolidation.unavailable(status: 2), "removed from store is unavailable")
        XCTAssertFalse(ExtensionConsolidation.unavailable(status: 3), "network failure remains a failure")
        var retired = enabled
        retired.manifestVersion = 2
        XCTAssertEqual(ExtensionConsolidation([retired]).skipped.first?.reason, "retired (Manifest V2)")
        retired.manifestVersion = 3
        retired.isBlocklisted = true
        XCTAssertEqual(ExtensionConsolidation([retired]).skipped.first?.reason, "blocklisted")
    }

    func testRepeatedArcImportKeepsStableSpacesAndAddsOnlyNewItems() throws {
        var source = ArcSidebarImport(export: try arcExport())
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let choices = source.defaultChoices(for: store)
        store.importArcSidebar(source, choices: choices)
        let snapshot = store.makeSnapshot()
        let count = store.spaces.count
        XCTAssertTrue(store.importArcSidebar(source, choices: choices).isEmpty)
        XCTAssertEqual(store.spaces.count, count)
        XCTAssertEqual(store.makeSnapshot().tabsByID.count, snapshot.tabsByID.count)
        XCTAssertTrue(store.remainingArcImport(source, choices: choices).isEmpty)
        // Ledger survives persistence; a new source ID appends to its old space.
        let restored = SidebarStore(spaces: store.spaces)
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertTrue(restored.importArcSidebar(source, choices: choices).isEmpty)
        source.export.spaces[0].pinned.append(.tab(ArcSidebarTab(sourceID: "NEW-TAB", title: "New", url: URL(string: "https://new.example/")!, isUnread: false)))
        XCTAssertEqual(restored.importArcSidebar(source, choices: choices).pinnedTabs, 1)
        XCTAssertEqual(restored.spaces.count, count)
        XCTAssertTrue(restored.importArcSidebar(source, choices: choices).isEmpty)
    }

    func testAnExactLegacyArcSpaceIsAdoptedWithoutDuplicatingIt() throws {
        var export = try arcExport()
        var space = export.spaces[0]
        guard case .tab(let tab) = space.pinned[0] else { return XCTFail("fixture") }
        space.pinned = [.tab(tab)]
        export.spaces = [space]
        export.favorites = [:]
        export.profiles = [space.profile]
        let source = ArcSidebarImport(export: export)
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let old = store.addSpace(name: space.name)
        let oldTab = store.addTab(kind: .pinned, title: tab.title, url: tab.url, in: old.id)
        if let title = tab.customTitle { store.renameTab(oldTab.id, to: title) }
        var choices = source.defaultChoices(for: store)
        choices.profileTargets[space.profile] = .existing(store.activeProfileID)
        choices.includeFavorites = false
        let count = store.spaces.count
        XCTAssertTrue(store.importArcSidebar(source, choices: choices).isEmpty)
        XCTAssertEqual(store.spaces.count, count)
        XCTAssertEqual(store.content(for: old.id).pinned.first?.id, oldTab.id)
        XCTAssertNotNil(store.space(withID: old.id)?.arcSourceID)
        XCTAssertTrue(store.importArcSidebar(source, choices: choices).isEmpty)
    }

    func testLegacyQueueNeverChangesAnOriginAfterConsent() throws {
        let source = SourceExtension(id: BrowserImportFixture.webStoreID, name: "Notes", version: "1", isEnabled: true,
                                     isPinned: false, isTheme: false, origin: .webStore)
        let queue = ExtensionReinstallQueue([source], into: UUID())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        var rows = try XCTUnwrap(raw["items"] as? [[String: Any]])
        rows[0].removeValue(forKey: "enabledByDefault")
        raw["items"] = rows
        var legacy = try JSONDecoder().decode(ExtensionReinstallQueue.self, from: JSONSerialization.data(withJSONObject: raw))
        var changed = source
        changed.origin = .unpacked(path: fixture.root.path)
        _ = legacy.reconcileLegacyInventory([changed])
        XCTAssertTrue(legacy.isFinished)
        XCTAssertTrue(ExtensionInventoryReader.consented([changed], snapshot: [source.id: source.origin]).isEmpty)
    }

    func testLegacyQueuesRecheckDisabledCopiesBeforeInstalling() throws {
        let source = SourceExtension(id: BrowserImportFixture.webStoreID, name: "Notes", version: "1", isEnabled: true,
                                     isPinned: false, isTheme: false, origin: .webStore)
        let queue = ExtensionReinstallQueue([source], into: UUID())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        var rows = try XCTUnwrap(raw["items"] as? [[String: Any]])
        rows[0].removeValue(forKey: "enabledByDefault")
        raw["items"] = rows
        var legacy = try JSONDecoder().decode(ExtensionReinstallQueue.self, from: JSONSerialization.data(withJSONObject: raw))
        var disabled = source
        disabled.isEnabled = false
        let reasons = legacy.reconcileLegacyInventory([disabled, disabled])
        XCTAssertTrue(legacy.isFinished)
        XCTAssertTrue(reasons.contains { $0.reason == "disabled" })
    }

}
