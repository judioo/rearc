import XCTest
@testable import SidebarModel

/// Wave 21 pure models: space paging physics, the swipe axis lock and the
/// window theme palette.
final class Wave21ModelTests: XCTestCase {

    // MARK: Space paging

    /// Drags `pages` over `seconds` in even steps, starting at `start`.
    private func drag(_ paging: inout SpacePaging, pages: Double, seconds: Double, start: TimeInterval = 0, steps: Int = 10) -> TimeInterval {
        paging.beginTracking(at: start)
        for step in 1...steps {
            paging.track(by: pages / Double(steps), at: start + seconds * Double(step) / Double(steps))
        }
        return start + seconds
    }

    func testSlowDragPastHalfwayLandsOnTheNextPage() {
        var paging = SpacePaging(pageCount: 3, page: 0)
        let end = drag(&paging, pages: 0.6, seconds: 1.0)
        XCTAssertEqual(paging.position(at: end), 0.6, accuracy: 1e-9, "the page follows the fingers")
        XCTAssertEqual(paging.endTracking(at: end), 1)
        XCTAssertEqual(paging.targetPage, 1)
        XCTAssertTrue(paging.isAnimating(at: end + 0.05))
        let rest = try! XCTUnwrap(paging.restTime)
        XCTAssertEqual(paging.position(at: rest), 1, accuracy: 0.001)
        XCTAssertFalse(paging.isAnimating(at: rest + 0.05))
    }

    func testShortDragSnapsBackButAFlickPages() {
        var slow = SpacePaging(pageCount: 3, page: 1)
        var end = drag(&slow, pages: 0.2, seconds: 1.0)
        XCTAssertEqual(slow.endTracking(at: end), 1, "a slow short drag springs back")

        var flick = SpacePaging(pageCount: 3, page: 1)
        end = drag(&flick, pages: -0.2, seconds: 0.08)
        XCTAssertEqual(flick.endTracking(at: end), 0, "a fast flick projects onto the previous page")
        XCTAssertLessThan(flick.velocity(at: end), 0, "the spring keeps the release velocity")
    }

    func testOneSwipeMovesAtMostOnePage() {
        var paging = SpacePaging(pageCount: 5, page: 0)
        let end = drag(&paging, pages: 2.4, seconds: 0.1)
        XCTAssertEqual(paging.endTracking(at: end), 1)
    }

    func testEdgesRubberBandAndSpringBack() {
        var paging = SpacePaging(pageCount: 2, page: 0)
        let end = drag(&paging, pages: -3, seconds: 1.0)
        let shown = paging.position(at: end)
        XCTAssertLessThan(shown, 0)
        XCTAssertGreaterThan(shown, -0.35, "the overshoot never reaches the band limit")
        XCTAssertGreaterThan(shown, -3 * 0.2, "past the edge the page moves much less than the fingers")
        XCTAssertEqual(paging.endTracking(at: end), 0)
        XCTAssertEqual(paging.position(at: paging.restTime!), 0, accuracy: 0.001)

        var single = SpacePaging(pageCount: 1, page: 0)
        let singleEnd = drag(&single, pages: 0.5, seconds: 0.5)
        XCTAssertGreaterThan(single.position(at: singleEnd), 0, "one space still rubber-bands")
        XCTAssertEqual(single.endTracking(at: singleEnd), 0)
    }

    func testANewSwipeGrabsThePageMidSpring() {
        var paging = SpacePaging(pageCount: 3, page: 0)
        let end = drag(&paging, pages: 0.7, seconds: 0.5)
        paging.endTracking(at: end)
        let mid = end + 0.08
        let before = paging.position(at: mid)
        XCTAssertGreaterThan(before, 0.7)
        XCTAssertLessThan(before, 1.05)
        paging.beginTracking(at: mid)
        XCTAssertEqual(paging.position(at: mid), before, accuracy: 1e-9, "no jump when interrupted")
        paging.track(by: -0.6, at: mid + 0.5)
        XCTAssertEqual(paging.endTracking(at: mid + 0.5), 0, "the interrupting swipe pages back from its own origin")
    }

    func testCancelReturnsToTheOriginAndGoSnapsOrSprings() {
        var paging = SpacePaging(pageCount: 3, page: 1)
        let end = drag(&paging, pages: 0.8, seconds: 1)
        paging.cancelTracking(at: end)
        XCTAssertEqual(paging.targetPage, 1)

        paging.go(to: 2, pageCount: 3, animated: true, at: 10)
        XCTAssertEqual(paging.targetPage, 2)
        XCTAssertEqual(paging.position(at: 10), 1, accuracy: 0.05, "an animated switch starts where the page is")
        XCTAssertTrue(paging.isAnimating(at: 10.05))

        paging.go(to: 0, pageCount: 3, animated: false, at: 11)
        XCTAssertEqual(paging.position(at: 11), 0)
        XCTAssertFalse(paging.isAnimating(at: 11))

        paging.go(to: 7, pageCount: 4, animated: true, at: 12)
        XCTAssertEqual(paging.targetPage, 3, "a new page count snaps and clamps")
        XCTAssertEqual(paging.position(at: 12), 3)
    }

    func testVisiblePagesSplitTheFractionBetweenNeighbours() {
        var paging = SpacePaging(pageCount: 3, page: 1)
        paging.beginTracking(at: 0)
        paging.track(by: 0.25, at: 0.5)
        let pages = paging.visiblePages(at: 0.5)
        XCTAssertEqual(pages.from, 1)
        XCTAssertEqual(pages.to, 2)
        XCTAssertEqual(pages.fraction, 0.25, accuracy: 1e-9)
    }

    func testAxisLockDecidesOnceFromTheFirstPoints() {
        var lock = SwipeAxisLock()
        XCTAssertEqual(lock.add(dx: -2, dy: 0.5), .undecided)
        XCTAssertEqual(lock.add(dx: -5, dy: 1), .horizontal)
        XCTAssertEqual(lock.dx, -7)
        XCTAssertEqual(lock.add(dx: 0, dy: 40), .horizontal, "the decision sticks for the gesture")

        var vertical = SwipeAxisLock()
        XCTAssertEqual(vertical.add(dx: 4, dy: 5), .vertical, "a diagonal counts as scrolling")
    }

    // MARK: Theme palette

    func testPaletteBlendsTheThemeForEachAppearance() {
        let indigo = SpaceTheme.default
        let light = SpaceThemePalette(theme: indigo, darkAppearance: false)
        let dark = SpaceThemePalette(theme: indigo, darkAppearance: true)
        XCTAssertGreaterThan(light.top.relativeLuminance, indigo.relativeLuminance)
        XCTAssertGreaterThan(light.top.relativeLuminance, light.bottom.relativeLuminance, "light themes brighten toward the top")
        XCTAssertLessThan(dark.bottom.relativeLuminance, dark.top.relativeLuminance)
        XCTAssertLessThan(dark.top.relativeLuminance, indigo.relativeLuminance)
        XCTAssertEqual(light.accent, indigo)
        XCTAssertTrue(dark.prefersLightForeground)
    }

    func testForegroundFollowsTheBackgroundBrightness() {
        let pale = SpaceTheme(red: 0.95, green: 0.95, blue: 0.96)
        let ink = SpaceTheme(red: 0.15, green: 0.15, blue: 0.17)
        XCTAssertFalse(SpaceThemePalette(theme: pale, darkAppearance: false).prefersLightForeground)
        XCTAssertTrue(SpaceThemePalette(theme: ink, darkAppearance: false).prefersLightForeground)
        XCTAssertTrue(SpaceThemePalette(theme: pale, darkAppearance: true).prefersLightForeground)
    }

    func testPalettesMixForASwipe() {
        let a = SpaceThemePalette(theme: .black, darkAppearance: false)
        let b = SpaceThemePalette(theme: .white, darkAppearance: false)
        XCTAssertEqual(a.mixed(with: b, fraction: 0), a)
        XCTAssertEqual(a.mixed(with: b, fraction: 1), b)
        let half = a.mixed(with: b, fraction: 0.5)
        XCTAssertEqual(half.accent.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SpaceTheme.black.mixed(with: .white, fraction: 2), .white, "fractions clamp")
    }

    // MARK: Changing a space's profile

    private func twoProfileStore() -> (SidebarStore, home: Profile, work: Profile, a: Space, b: Space) {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let home = store.activeProfile
        let work = store.addProfile(name: "Work")
        let spaces = store.spaces(in: home.id)
        return (store, home, work, spaces[0], spaces[1])
    }

    func testChangingAProfileMovesTheSpaceWithItsTabs() throws {
        let (store, home, work, a, b) = twoProfileStore()
        store.selectSpace(b.id)
        let tab = store.addTab(kind: .pinned, title: "Docs", url: URL(string: "https://docs.test")!)
        let before = store.mutationJournal.allEntries().count

        XCTAssertNil(store.changeProfile(ofSpace: b.id, to: work.id))
        XCTAssertEqual(store.space(withID: b.id)?.profileID, work.id)
        XCTAssertEqual(store.spaces(in: home.id).map(\.id), [a.id])
        XCTAssertEqual(store.spaces(in: work.id).last?.id, b.id, "it lands after the profile's spaces")
        XCTAssertEqual(store.activeSpaceID, b.id, "the space on screen stays on screen")
        XCTAssertEqual(store.activeProfileID, work.id, "and the active profile follows it")
        XCTAssertEqual(store.spaceContaining(tabID: tab.id), b.id, "tabs stay in the space")
        let journal = store.mutationJournal.allEntries().dropFirst(before).map(\.mutation)
        XCTAssertTrue(journal.contains { if case .moveSpace(id: b.id, _) = $0 { return true }; return false })
        XCTAssertTrue(journal.contains(.upsertSpace(id: b.id)))

        // Switching back to the old profile lands on a space it still has.
        store.selectProfile(home.id)
        XCTAssertEqual(store.activeSpaceID, a.id)

        let data = try JSONEncoder().encode(store.makeSnapshot())
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        XCTAssertEqual(restored.space(withID: b.id)?.profileID, work.id, "the new profile persists")
    }

    func testProfileChangeBlockers() {
        let (store, home, work, a, _) = twoProfileStore()
        XCTAssertEqual(store.changeProfile(ofSpace: a.id, to: home.id), .sameProfile)
        XCTAssertEqual(store.changeProfile(ofSpace: a.id, to: UUID()), .profileNotFound)
        XCTAssertEqual(store.changeProfile(ofSpace: UUID(), to: work.id), .spaceNotFound)
        let workSpace = store.spaces(in: work.id)[0]
        XCTAssertEqual(store.changeProfile(ofSpace: workSpace.id, to: home.id), .lastSpaceInProfile)
        XCTAssertEqual(store.profileChoices(forSpace: a.id).map(\.id), [work.id])
        XCTAssertTrue(store.profileChoices(forSpace: workSpace.id).isEmpty)
        XCTAssertEqual(store.space(withID: workSpace.id)?.profileID, work.id, "a refused change changes nothing")
    }

    func testMoveSpaceToProfileCommand() {
        let (store, _, work, _, _) = twoProfileStore()
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.contains { $0.action == .moveSpaceToProfile(work.id) && $0.title == "Move Space to Work" })
        XCTAssertFalse(commands.contains { $0.action == .moveSpaceToProfile(store.activeProfileID) })
    }

    // MARK: Drag to split

    func testDropEdgeIsTheNearestSideAsAFraction() {
        XCTAssertEqual(SplitDropEdge.nearest(x: 10, y: 300, width: 1000, height: 600), .leading)
        XCTAssertEqual(SplitDropEdge.nearest(x: 990, y: 300, width: 1000, height: 600), .trailing)
        XCTAssertEqual(SplitDropEdge.nearest(x: 500, y: 20, width: 1000, height: 600), .top)
        XCTAssertEqual(SplitDropEdge.nearest(x: 500, y: 590, width: 1000, height: 600), .bottom)
        XCTAssertEqual(SplitDropEdge.nearest(x: 300, y: 250, width: 1000, height: 600), .leading,
                       "30% across beats 42% down: sides are compared as fractions")
        XCTAssertNil(SplitDropEdge.nearest(x: 1, y: 1, width: 0, height: 10))
        XCTAssertEqual(SplitDropEdge.top.orientation, .vertical)
        XCTAssertEqual(SplitDropEdge.trailing.orientation, .horizontal)
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testDroppingATabOnAnEdgeMakesASplitOnThatSide() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let anchor = store.addTab(kind: .today, title: "Anchor", url: url("https://a.test"))
        let dropped = store.addTab(kind: .pinned, title: "Dropped", url: url("https://b.test"))
        store.selectTab(anchor.id)
        XCTAssertTrue(store.canSplit(dropped.id, onto: anchor.id))

        let split = try XCTUnwrap(store.splitTab(dropped.id, onto: anchor.id, edge: .leading))
        XCTAssertEqual(split.tabs.map(\.id), [dropped.id, anchor.id], "a left drop puts the tab first")
        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertEqual(store.selectedItemID, split.id)
        XCTAssertEqual(store.split(withID: split.id)?.focusTabID, dropped.id, "the dropped pane has focus")
        XCTAssertEqual(store.locateSplit(split.id)?.section, .unpinned, "the pinned tab joined the anchor's section")
    }

    func testDroppingOnAnExistingSplitAddsAPaneAndTurnsToTheEdgeAxis() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        let c = store.addTab(kind: .today, title: "C", url: url("https://c.test"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        let grown = try XCTUnwrap(store.splitTab(c.id, onto: b.id, edge: .bottom))
        XCTAssertEqual(grown.id, split.id)
        XCTAssertEqual(grown.tabs.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(grown.orientation, .vertical)

        let d = store.addTab(kind: .today, title: "D", url: url("https://d.test"))
        let top = try XCTUnwrap(store.splitTab(d.id, onto: a.id, edge: .top))
        XCTAssertEqual(top.tabs.first?.id, d.id)
        let e = store.addTab(kind: .today, title: "E", url: url("https://e.test"))
        XCTAssertFalse(store.canSplit(e.id, onto: a.id), "four panes is the limit")
        XCTAssertNil(store.splitTab(e.id, onto: a.id, edge: .trailing))
    }

    func testDragToSplitRefusals() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let spaces = store.spaces(in: store.activeProfileID)
        let anchor = store.addTab(kind: .today, title: "Anchor", url: url("https://a.test"))
        let favorite = store.addTab(kind: .favorite, title: "Fav", url: url("https://f.test"))
        XCTAssertFalse(store.canSplit(anchor.id, onto: anchor.id))
        XCTAssertFalse(store.canSplit(favorite.id, onto: anchor.id), "favorites do not split")
        XCTAssertFalse(store.canSplit(anchor.id, onto: favorite.id))
        store.selectSpace(spaces[1].id)
        let elsewhere = store.addTab(kind: .today, title: "Other", url: url("https://o.test"))
        XCTAssertFalse(store.canSplit(elsewhere.id, onto: anchor.id), "tabs of another space do not split")
        XCTAssertFalse(store.canSplit(UUID(), onto: anchor.id))
    }

    // MARK: Site search

    func testSiteNamesMatchByPrefixAliasOrDomain() {
        XCTAssertEqual(SiteSearchCatalog.match("you")?.id, "youtube")
        XCTAssertEqual(SiteSearchCatalog.match("YT")?.id, "youtube", "aliases match, case-insensitively")
        XCTAssertEqual(SiteSearchCatalog.match("github.com")?.id, "github")
        XCTAssertEqual(SiteSearchCatalog.match("www.wiki")?.id, "wikipedia")
        XCTAssertEqual(SiteSearchCatalog.match("maps")?.id, "maps", "an exact alias beats a longer prefix match")
        XCTAssertEqual(SiteSearchCatalog.match("go")?.id, "google", "the shortest name wins a shared prefix")
        XCTAssertNil(SiteSearchCatalog.match("y"), "one letter is too little")
        XCTAssertNil(SiteSearchCatalog.match("youtube cats"), "a query with spaces is a search, not a trigger")
        XCTAssertNil(SiteSearchCatalog.match("https://youtube.com"))
        XCTAssertNil(SiteSearchCatalog.match("zzqx"))
    }

    func testSiteSearchURLsEncodeTheQuery() throws {
        let youtube = try XCTUnwrap(SiteSearchCatalog.match("youtube"))
        XCTAssertEqual(youtube.url(for: "cats & dogs")?.absoluteString,
                       "https://www.youtube.com/results?search_query=cats%20%26%20dogs")
        XCTAssertEqual(youtube.url(for: "  ")?.absoluteString, "https://youtube.com/", "no query opens the site")
        let maps = try XCTUnwrap(SiteSearchCatalog.match("maps"))
        XCTAssertEqual(maps.url(for: "a/b")?.absoluteString, "https://www.google.com/maps/search/a%2Fb")

        let rows = CommandBarSearch.siteSearchResults(youtube, query: "cats")
        XCTAssertEqual(rows.map(\.title), ["Search YouTube for “cats”"])
        XCTAssertEqual(rows.first?.kind, .search)
        XCTAssertEqual(CommandBarSearch.siteSearchResults(youtube, query: "").first?.title, "Open YouTube")
    }

    // MARK: Boost library

    func testLibraryRowsFollowInstallOrderAndDescribeEachBoost() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let style = try XCTUnwrap(store.createBoostForCurrentSite(name: "Quiet GitHub", css: "a{}", pageURL: url("https://github.com/x")))
        var script = BoostPackage.newScript(name: "Script", hostScope: [BoostHostRule(host: "example.com"), BoostHostRule(host: "example.org")], js: "1")
        script.metadata.colorHex = "#FF0000"
        XCTAssertNil(store.addBoost(script))

        let rows = BoostLibraryListing.rows(store.boostLibrary(), currentPage: url("https://github.com/rearc"))
        XCTAssertEqual(rows.map(\.name), ["Quiet GitHub", "Script"])
        XCTAssertEqual(rows[0].sites, "github.com")
        XCTAssertTrue(rows[0].enabled && rows[0].hasStyle && !rows[0].hasScript)
        XCTAssertTrue(rows[0].matchesCurrentPage)
        XCTAssertEqual(rows[0].siteURL, url("https://github.com/"))
        XCTAssertEqual(rows[1].sites, "example.com and 1 more")
        XCTAssertFalse(rows[1].enabled, "script boosts start off")
        XCTAssertFalse(rows[1].scriptAllowed)
        XCTAssertFalse(rows[1].matchesCurrentPage)

        XCTAssertEqual(BoostLibraryListing.rows(store.boostLibrary(), filter: "example.org").map(\.id), [script.manifest.id])
        XCTAssertEqual(BoostLibraryListing.rows(store.boostLibrary(), filter: "quiet").map(\.id), [style.manifest.id])
    }

    func testRenameBoostAndSiteParsing() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let boost = try XCTUnwrap(store.createBoostForCurrentSite(name: "Old", css: "", pageURL: url("https://news.test")))
        XCTAssertTrue(store.renameBoost(packageID: boost.manifest.id, to: "  New  "))
        XCTAssertEqual(store.boostLibrary().package(id: boost.manifest.id)?.manifest.name, "New")
        XCTAssertFalse(store.renameBoost(packageID: boost.manifest.id, to: " "))
        XCTAssertFalse(store.renameBoost(packageID: UUID(), to: "X"))

        XCTAssertEqual(BoostLibraryListing.siteURL(from: "GitHub.com"), url("https://github.com/"))
        XCTAssertEqual(BoostLibraryListing.siteURL(from: "https://www.x.com/home"), url("https://www.x.com/"))
        XCTAssertNil(BoostLibraryListing.siteURL(from: "not a site"))
        XCTAssertNil(BoostLibraryListing.siteURL(from: "localhost"))
        XCTAssertNil(BoostLibraryListing.siteURL(from: ""))
    }

    // MARK: External links

    func testExternalLinksRouteByPreferenceAndReuseOpenTabs() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let b = store.spaces(in: store.activeProfileID)[1]
        store.selectSpace(b.id)
        let page = url("https://example.com/a")
        XCTAssertEqual(ExternalLinkRouting.route(page, destination: .littleArc, in: store),
                       .littleArc(page, profileID: store.activeProfileID))
        XCTAssertEqual(ExternalLinkRouting.route(page, destination: .activeSpace, in: store),
                       .newTab(page, spaceID: b.id), "a new tab lands in the space in front")

        let open = store.addTab(kind: .today, title: "A", url: page)
        XCTAssertEqual(ExternalLinkRouting.route(page, destination: .littleArc, in: store), .focusTab(open.id),
                       "a page already open is focused, not opened twice")

        XCTAssertEqual(ExternalLinkRouting.route(url("javascript:alert(1)"), destination: .activeSpace, in: store), .rejected)
        XCTAssertEqual(ExternalLinkRouting.route(url("mailto:a@b.c"), destination: .activeSpace, in: store), .rejected)
        XCTAssertEqual(ExternalLinkRouting.route(url("chrome://settings"), destination: .activeSpace, in: store), .rejected)
    }

    func testExternalLinkPreferencePersistsAndHasACommand() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-w21-\(UUID().uuidString)"))
        XCTAssertEqual(ExternalLinkDestination.load(from: defaults), .littleArc, "Arc's default")
        ExternalLinkDestination.activeSpace.save(to: defaults)
        XCTAssertEqual(ExternalLinkDestination.load(from: defaults), .activeSpace)

        let store = SidebarStore()
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack(),
                                        externalLinkDestination: .littleArc)
        let actions = AppCommandRegistry.all(in: context).map(\.action)
        XCTAssertTrue(actions.contains(.setAsDefaultBrowser))
        XCTAssertTrue(actions.contains(.setExternalLinkDestination(.activeSpace)))
        XCTAssertFalse(actions.contains(.setExternalLinkDestination(.littleArc)), "the current choice is hidden")
    }
}
