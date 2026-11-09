import XCTest
@testable import SidebarModel

/// Importing twice brings nothing twice (QA-483 B1, B2): Arc's bookmarks
/// that mirror its sidebar make no space, a profile's bookmarks come into one
/// space once and then only what is new, its history only from where the
/// last import left off; and an import's new extensions open their pages in
/// the background (B5).
final class ImportLedgerTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    /// An Arc space as `importArcSidebar` leaves it: its source ID, and the
    /// links as pinned tabs, the first two in a folder.
    private func storeWithArcSpace(_ links: [String], directory: String = "Default") -> SidebarStore {
        let store = SidebarStore()
        let space = store.addSpace(name: "Personal")
        store.spaces[store.spaces.firstIndex { $0.id == space.id }!].arcSourceID = "\(directory):S1"
        let tabs = links.map { store.addTab(kind: .pinned, title: $0, url: url($0), in: space.id) }
        if tabs.count > 2 { _ = store.createFolder(in: space.id, containing: [tabs[0].id, tabs[1].id]) }
        return store
    }

    private func links(_ n: Int, host: String = "a.example.com") -> [String] {
        (0 ..< n).map { "https://\(host)/page\($0)" }
    }

    // MARK: B1

    func testArcBookmarksThatMirrorItsSidebarMakeNoSpace() {
        let sidebar = links(20)
        let store = storeWithArcSpace(sidebar)
        let spaces = store.spaces.count
        // Arc's bookmarks: the same links in another shape, spelled a little
        // differently (host case, fragment, a lone slash), plus one new link.
        let bookmarks: [BookmarkNode] = [
            .folder(title: "Imported From Brave", children: sidebar.prefix(19).map { .link(title: "x", url: url($0.replacingOccurrences(of: "a.example.com", with: "A.Example.com") + "#top")) }),
            .link(title: "Last", url: url(sidebar[19])),
            .link(title: "New", url: url("https://new.example.com/")),
        ]
        let plan = store.bookmarkImportPlan(bookmarks, sourceID: "arc/Default", arcProfileDirectory: "Default")
        XCTAssertTrue(plan.mirrorsArcSidebar)
        XCTAssertEqual(plan.total, 21)
        XCTAssertTrue(plan.isEmpty, "1 new link in 21 is under one in ten: no space")
        XCTAssertNil(store.importBookmarks(bookmarks, spaceName: "Arc – AKILU Profile", sourceID: "arc/Default", arcProfileDirectory: "Default"))
        XCTAssertEqual(store.spaces.count, spaces)
        XCTAssertEqual(BookmarkImportPlan.key(url("https://A.Example.com/#x")), BookmarkImportPlan.key(url("https://a.example.com")))
    }

    func testArcBookmarksWithEnoughNewComeAsOnlyTheNewOnes() throws {
        let store = storeWithArcSpace(links(8))
        let bookmarks: [BookmarkNode] = links(8).map { .link(title: "x", url: url($0)) }
            + [.folder(title: "Reading", children: [.link(title: "R", url: url("https://read.example.com/")),
                                                   .link(title: "Old", url: url(links(8)[0]))]),
               .link(title: "S", url: url("https://shop.example.com/"))]
        let result = try XCTUnwrap(store.importBookmarks(bookmarks, spaceName: "Arc – Personal", sourceID: "arc/Default", arcProfileDirectory: "Default"))
        XCTAssertEqual(result.tabs, 2, "2 of 10 are new: they come, the copies do not")
        let leaves = SidebarTree.tabs(store.content(for: result.space.id).pinnedLeaves).map { $0.url.host() }
        XCTAssertEqual(leaves, ["read.example.com", "shop.example.com"])
    }

    func testArcBookmarksWithoutItsSpacesComeWhole() throws {
        // Spaces & Sidebar not imported (or from another Arc profile): nothing to mirror.
        let store = storeWithArcSpace(links(5), directory: "Profile 1")
        let bookmarks: [BookmarkNode] = links(5).map { .link(title: "x", url: url($0)) }
        let plan = store.bookmarkImportPlan(bookmarks, sourceID: "arc/Default", arcProfileDirectory: "Default")
        XCTAssertFalse(plan.mirrorsArcSidebar)
        XCTAssertEqual(plan.newLinks, 5)
    }

    func testTheSameRuleCountsArcsSourceForActTwo() {
        let sidebar = links(30)
        let known = Set(sidebar.map { BookmarkImportPlan.key(url($0)) })
        let copies: [BookmarkNode] = sidebar.map { .link(title: "x", url: url($0)) } + [.link(title: "n", url: url("https://n.example.com/"))]
        XCTAssertEqual(BookmarkImportPlan.make(copies, known: known, mirrorsArcSidebar: true).newLinks, 0)
        XCTAssertEqual(BookmarkImportPlan.make(copies, known: known).newLinks, 1, "without the mirror rule the new link stays")
    }

    // MARK: B2

    func testAProfilesBookmarksMakeOneSpaceThenAddOnlyWhatIsNew() throws {
        let store = SidebarStore()
        let first: [BookmarkNode] = [.link(title: "Recipes", url: url("https://recipes.example.com/")),
                                     .folder(title: "Trips", children: [.link(title: "Maps", url: url("https://maps.example.org/"))])]
        let made = try XCTUnwrap(store.importBookmarks(first, spaceName: "Chrome – Everyday", sourceID: "chrome/Default"))
        XCTAssertEqual(made.space.bookmarkSourceID, "chrome/Default")
        let spaces = store.spaces.count
        XCTAssertNil(store.importBookmarks(first, spaceName: "Chrome – Everyday", sourceID: "chrome/Default"), "nothing new: nothing happens")
        XCTAssertTrue(store.bookmarkImportPlan(first, sourceID: "chrome/Default").isEmpty)
        XCTAssertEqual(store.bookmarkImportPlan(first, sourceID: "chrome/Default").existingSpaceID, made.space.id)

        let more = first + [.folder(title: "Trips", children: [.link(title: "Trains", url: url("https://trains.example.org/"))])]
        let added = try XCTUnwrap(store.importBookmarks(more, spaceName: "Chrome – Everyday", sourceID: "chrome/Default"))
        XCTAssertEqual(added.space.id, made.space.id)
        XCTAssertEqual(added.tabs, 1)
        XCTAssertEqual(store.spaces.count, spaces)
        let pinned = store.content(for: made.space.id).pinned
        XCTAssertEqual(pinned.count, 2, "the new link joins the Trips folder already there")
        guard case .folder(let trips) = pinned[1] else { return XCTFail("no folder") }
        XCTAssertEqual(SidebarTree.tabs(trips.children).map(\.title), ["Maps", "Trains"])
        XCTAssertLessThan(store.rank(of: trips.children[0]), store.rank(of: trips.children[1]))
    }

    func testTheBookmarkLedgerSurvivesSaving() throws {
        let store = SidebarStore()
        _ = store.importBookmarks([.link(title: "R", url: url("https://r.example.com/"))], spaceName: "Brave – Default", sourceID: "brave/Default")
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(store.makeSnapshot())))
        XCTAssertNil(restored.importBookmarks([.link(title: "R", url: url("https://r.example.com/"))], spaceName: "Brave – Default", sourceID: "brave/Default"))
    }

    func testHistoryComesOnceThenFromWhereTheLastImportLeftOff() throws {
        let day: TimeInterval = 86_400
        let old = Date(timeIntervalSince1970: 1_000_000)
        let records = (0 ..< 3).map { VisitRecord(url: url("https://h\($0).example.com/"), title: "", firstVisit: old.addingTimeInterval(Double($0) * day)) }
        var ledger = ImportLedger()
        XCTAssertEqual(ledger.newHistory(records, from: "chrome/Default").count, 3)
        ledger.recordHistory(records, from: "chrome/Default")
        XCTAssertTrue(ledger.newHistory(records, from: "chrome/Default").isEmpty)
        XCTAssertEqual(ledger.newHistory(records, from: "brave/Default").count, 3, "per source")
        let later = VisitRecord(url: url("https://h9.example.com/"), title: "", firstVisit: old.addingTimeInterval(9 * day))
        XCTAssertEqual(ledger.newHistory(records + [later], from: "chrome/Default"), [later])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        ledger.save(to: file)
        XCTAssertEqual(ImportLedger.load(from: file), ledger)
    }

    func testInstalledExtensionsAreNotQueuedAgain() {
        let sources = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"].map {
            SourceExtension(id: $0, name: $0, version: "1", isEnabled: true, isPinned: false, isTheme: false, origin: .webStore)
        }
        let queue = ExtensionReinstallQueue(sources, into: UUID(), installedIDs: [sources[0].id])
        XCTAssertEqual(queue.items.map(\.id), [sources[1].id])
        XCTAssertTrue(ExtensionReinstallQueue(sources, into: UUID(), installedIDs: Set(sources.map(\.id))).isFinished)
        XCTAssertEqual(ExtensionConsolidation(sources, installedIDs: [sources[0].id]).skipped.map(\.reason), ["already installed"])
    }

    // MARK: B3

    func testTheOnboardingMarkerRemembersTheStarter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = SidebarFilePersistence(fileURL: dir.appendingPathComponent("sidebar.json"))
        let starter = SidebarFilePersistence.OnboardingStarter(spaceIDs: [UUID()], itemIDs: [UUID()])
        persistence.beginOnboarding(starter: starter)
        XCTAssertEqual(persistence.onboardingStarter, starter)
        persistence.beginOnboarding(starter: SidebarFilePersistence.OnboardingStarter())
        XCTAssertEqual(persistence.onboardingStarter, starter, "a resumed onboarding keeps the first run's starter")
        // An older build's marker is empty.
        try Data().write(to: persistence.onboardingMarkerURL)
        XCTAssertNil(persistence.onboardingStarter)
        persistence.finishOnboarding()
        XCTAssertNil(persistence.onboardingStarter)
    }

    // MARK: B5

    func testAnImportsExtensionsOpenTheirPagesInTheBackground() {
        let now = Date(timeIntervalSince1970: 5_000)
        var quiet = QuietExtensionInstalls()
        XCTAssertFalse(quiet.isQuiet("x", at: now))
        quiet.begin(["x", "y"], at: now)
        XCTAssertTrue(quiet.isQuiet("x", at: now.addingTimeInterval(600)), "while it installs")
        quiet.finished("x", at: now.addingTimeInterval(10))
        XCTAssertTrue(quiet.isQuiet("x", at: now.addingTimeInterval(10 + QuietExtensionInstalls.grace - 1)), "its onInstalled pages")
        XCTAssertFalse(quiet.isQuiet("x", at: now.addingTimeInterval(10 + QuietExtensionInstalls.grace + 1)), "later tabs are the person's")
        XCTAssertFalse(quiet.isQuiet("", at: now))

        let space = UUID()
        let create = ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab, active: true, url: "https://welcome.example.com/", extensionID: "x")
        func place(_ request: ExtensionTabRequest, quiet: Bool) -> ExtensionTabPlacement {
            .resolve(request, currentSpace: space, windowSpace: nil, spaces: [space], quiet: quiet) { _ in true }
        }
        XCTAssertEqual(place(create, quiet: false), .newTab(space: space))
        XCTAssertEqual(place(create, quiet: true), .backgroundTab(space: space))
        var options = create
        options.kind = .optionsPage
        XCTAssertEqual(place(options, quiet: true), .backgroundTab(space: space))
        var window = create
        window.kind = .createWindow
        XCTAssertEqual(place(window, quiet: true), .littleArc)
    }

    func testBackgroundTabsCollectAtTheBottomOfTodayUnselected() {
        let store = SidebarStore()
        let mine = store.addTab(kind: .today, title: "Welcome", url: url("https://welcome.example.com/"))
        store.selectTab(mine.id)
        let first = store.appendTodayTab(title: "Getting started", url: url("https://a.example.com/"))
        let second = store.appendTodayTab(title: "Installed", url: url("https://b.example.com/"))
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.map(\.id), [mine.id, first.id, second.id])
        XCTAssertEqual(store.selectedItemID, mine.id)
    }
}
