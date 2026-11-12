import Foundation
import SQLite3
import XCTest
@testable import SidebarModel

/// The command bar matched to Arc's (COMMAND-BAR §10): ranking and
/// de-duplication, the shortcut hint, site-search templates and their
/// encoding, earlier queries from history, keyword import, and the colours.
final class CommandBarArcTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func url(_ string: String) -> URL { URL(string: string)! }

    private let cushwake = SiteSearchEngine(keywordRowID: "imported-cwc", name: "cushwake", keyword: "cwc",
                                            template: "https://www.cushmanwakefield.ae/search?q={searchTerms}", source: .imported)!

    // MARK: Ranking and de-duplication

    func testStrongTabMatchesComeFirstAndPathOnlyMatchesWaitUntilAfterHistory() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        store.addTab(kind: .today, title: "Claude", url: url("https://claude.ai/chat/1234"))
        store.addTab(kind: .today, title: "Team chat", url: url("https://slack.com/messages"))
        let history = VisitHistory(records: [VisitRecord(url: url("https://chat.example/"), title: "Chat example", firstVisit: now)])
        let results = CommandBarSearch.results(for: "chat", in: store, history: history, now: now)
        XCTAssertEqual(results.first?.title, "Team chat", "a word of the title starts with the text")
        let kinds = results.map(\.kind)
        let claude = results.firstIndex { $0.title == "Claude" }!
        XCTAssertGreaterThan(claude, kinds.firstIndex(of: .history)!, "found only in the path: after history")
        XCTAssertLessThan(kinds.firstIndex(of: .search)!, kinds.firstIndex(of: .history)!, "the plain search before pages")
    }

    func testBookmarkImportSpacesNeitherLeadNorCrowd() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let imported = store.addSpace(name: "Brave – profile 1", profileID: store.activeProfileID)
        store.spaces[store.spaces.firstIndex { $0.id == imported.id }!].bookmarkSourceID = "brave/Profile 1"
        for index in 0 ..< 6 {
            store.addTab(kind: .pinned, title: "chatGPT notes \(index)", url: url("https://notes.test/\(index)"), in: imported.id)
        }
        store.addTab(kind: .pinned, title: "Claude", url: url("https://claude.ai/chat/9"), in: imported.id)
        store.addTab(kind: .today, title: "ChatGPT", url: url("https://chatgpt.com/"))
        let results = CommandBarSearch.results(for: "chat", in: store, now: now)
        XCTAssertEqual(results.first?.title, "ChatGPT", "the person's own tab first")
        let importedRows = results.filter { $0.spaceID == imported.id }
        XCTAssertEqual(importedRows.count, CommandBarSearch.laterTabLimit, "a bookmark-import space adds two rows at most")
        XCTAssertFalse(results.contains { $0.title == "Claude" }, "its weak matches are dropped")
        XCTAssertGreaterThan(results.firstIndex { $0.spaceID == imported.id }!, results.firstIndex { $0.kind == .search }!)
    }

    func testRowsWithTheSameTitleOnTheSameHostShowOnce() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        store.addTab(kind: .today, title: "Claude", url: url("https://claude.ai/new"))
        store.addTab(kind: .today, title: "Claude", url: url("https://claude.ai/new?x=1"))
        let history = VisitHistory(records: [
            VisitRecord(url: url("https://claude.ai/recents"), title: "Claude", firstVisit: now),
            VisitRecord(url: url("https://claude.ai/new"), title: "Claude", firstVisit: now),
            VisitRecord(url: url("https://docs.claude.com/"), title: "Claude", firstVisit: now),
        ])
        let results = CommandBarSearch.results(for: "claude", in: store, history: history, now: now)
        let claudeAI = results.filter { $0.title == "Claude" && $0.destinationURL?.host() == "claude.ai" }
        XCTAssertEqual(claudeAI.count, 1, "Arc `dedupByTitleAndHostList`, for every host")
        XCTAssertTrue(results.contains { $0.destinationURL?.host() == "docs.claude.com" }, "another host is another page")
    }

    func testTheCompletedSiteGoesAheadOfTabsOnOtherSites() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        store.addTab(kind: .today, title: "Chat with the team", url: url("https://slack.com/"))
        let results = CommandBarSearch.results(for: "chat", in: store, inlineCompletion: "chatgpt.com", now: now)
        XCTAssertEqual(results.first?.destinationURL, url("https://chatgpt.com/"), "Return goes where the field shows")
        XCTAssertEqual(results[1].title, "Chat with the team")
        let onSite = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        onSite.addTab(kind: .today, title: "ChatGPT", url: url("https://chatgpt.com/c/1"))
        let switching = CommandBarSearch.results(for: "chat", in: onSite, inlineCompletion: "chatgpt.com", now: now)
        XCTAssertEqual(switching.first?.kind, .openTab, "a tab on the completed site is that site: Switch to Tab")
        XCTAssertFalse(switching.contains { $0.id == "inline-chatgpt.com" })
    }

    func testTheActiveSpacesTabsLeadAndAnEmptyNewTabListsRecentTabs() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let other = store.addSpace(name: "Other", profileID: store.activeProfileID)
        store.addTab(kind: .today, title: "Docs elsewhere", url: url("https://docs.other/"), in: other.id)
        store.addTab(kind: .today, title: "Docs here", url: url("https://docs.here/"))
        let results = CommandBarSearch.results(for: "docs", in: store, now: now)
        XCTAssertEqual(results.prefix(2).map(\.title), ["Docs here", "Docs elsewhere"])
        let recent = CommandBarSearch.recentTabResults(in: store)
        XCTAssertFalse(recent.contains { $0.tabID == store.selectedTabID }, "not the tab on screen")
        XCTAssertTrue(recent.allSatisfy { $0.kind == .openTab })
        XCTAssertLessThanOrEqual(recent.count, 5)
    }

    // MARK: The hint

    func testAKeywordOrTheCompletedSiteOffersItsShortcut() throws {
        XCTAssertNil(SiteSearchCatalog.match("chat", in: SiteSearchCatalog.merged(imported: [cushwake]), completedHost: "chatgpt.com"),
                     "assistants are not seeded")
        let chatGPT = try XCTUnwrap(CommandBarAssistants.builtIn.first { $0.id == "chatgpt" }?.siteSearchEngine)
        let engines = SiteSearchCatalog.merged(imported: [cushwake], assistants: [chatGPT])
        XCTAssertEqual(SiteSearchCatalog.match("cwc", in: engines)?.name, "cushwake", "the keyword, exactly")
        XCTAssertEqual(SiteSearchCatalog.match("CWC", in: engines)?.hint, "Search cushwake")
        let chat = try XCTUnwrap(SiteSearchCatalog.match("chat", in: engines, completedHost: "chatgpt.com"))
        XCTAssertEqual(chat.hint, "Ask ChatGPT", "the entry's own verb")
        XCTAssertEqual(chat.placeholder, "Send a Message…")
        XCTAssertNil(SiteSearchCatalog.match("cwc please", in: engines), "a query with spaces is a search")
        let short = SiteSearchEngine(keywordRowID: "w", name: "Wiki here", keyword: "w", template: "https://w.test/?q=%s", source: .imported)!
        XCTAssertEqual(SiteSearchCatalog.match("w", in: [short])?.name, "Wiki here", "a one-letter keyword still counts")
    }

    func testMergingKeepsThePersonsEntryAndBorrowsTheSeededColour() {
        let mine = SiteSearchEngine(keywordRowID: "mine", name: "YT", keyword: "y", template: "https://www.youtube.com/results?search_query={searchTerms}",
                                    source: .imported)!
        let merged = SiteSearchCatalog.merged(imported: [mine])
        let youtube = merged.filter { $0.domain == "youtube.com" }
        XCTAssertEqual(youtube.count, 1, "one search page, one entry")
        XCTAssertEqual(youtube.first?.name, "YT", "the person's own name")
        XCTAssertEqual(youtube.first?.color, SiteSearchCatalog.seeded.first { $0.id == "youtube" }?.color)
        XCTAssertEqual(SiteSearchCatalog.match("youtube", in: merged)?.name, "YT", "the seeded name still finds it")
        let clash = SiteSearchEngine(keywordRowID: "clash", name: "Other", keyword: "y", template: "https://other.test/?q=%s", source: .engine)!
        XCTAssertEqual(SiteSearchCatalog.merged(imported: [mine], engine: [clash]).filter { $0.keyword == "y" }.map(\.name), ["YT"])
    }

    func testEngineListEntriesBecomeShortcutsAndOnlyTheDefaultCarriesSuggestions() {
        let choices = SearchEngineChoices(engines: [
            .init(id: 1, name: "Google", keyword: "google.com", searchTemplate: "https://www.google.com/search?q=%s", isDefault: true),
            .init(id: 2, name: "Bing", keyword: "bing.com", searchTemplate: "https://www.bing.com/search?q=%s"),
            .init(id: 3, name: "Broken", keyword: "x", searchTemplate: "javascript:alert(%s)"),
        ])
        let engines = choices.siteSearchEngines(defaultProvider: .google)
        XCTAssertEqual(engines.map(\.name), ["Google", "Bing"], "an invalid template never becomes a shortcut")
        XCTAssertNotNil(engines[0].suggestTemplate)
        XCTAssertNil(engines[1].suggestTemplate, "no suggest URL the engine did not give")
    }

    // MARK: Templates

    func testTemplatesAreValidatedBeforeTheyBecomeShortcuts() {
        XCTAssertEqual(SiteSearchTemplate.validated("https://x.test/s?q={searchTerms}&ie={inputEncoding}"), "https://x.test/s?q=%s&ie=UTF-8")
        XCTAssertEqual(SiteSearchTemplate.validated("http://x.test/find/%s"), "http://x.test/find/%s")
        for bad in ["javascript:alert('%s')", "data:text/html,%s", "ftp://x.test/%s", "https://x.test/search", "https://%s.evil.test/",
                    "https://x.test/?q=%s&u={google:baseURL}", "https://user:pw@x.test/?q=%s", "https://x.test/?q=%s more",
                    "file:///etc/%s", "https://x.test/?q=%s" + String(repeating: "a", count: SiteSearchTemplate.maxLength)] {
            XCTAssertNil(SiteSearchTemplate.validated(bad), bad)
        }
        XCTAssertNil(SiteSearchEngine(keywordRowID: "x", name: "", keyword: "k", template: "https://x.test/?q=%s", source: .imported))
        XCTAssertNil(SiteSearchEngine(keywordRowID: "x", name: "N", keyword: "two words", template: "https://x.test/?q=%s", source: .imported))
    }

    func testTermsAreEncodedByTheTemplatesRules() {
        XCTAssertEqual(cushwake.url(for: "L-144373")?.absoluteString, "https://www.cushmanwakefield.ae/search?q=L-144373")
        XCTAssertEqual(cushwake.url(for: "a b&c=d#e/f?")?.absoluteString,
                       "https://www.cushmanwakefield.ae/search?q=a+b%26c%3Dd%23e%2Ff%3F", "nothing the terms hold adds a parameter")
        XCTAssertEqual(cushwake.url(for: "café")?.absoluteString, "https://www.cushmanwakefield.ae/search?q=caf%C3%A9")
        let path = SiteSearchEngine(keywordRowID: "m", name: "Maps", keyword: "m", template: "https://maps.test/search/%s/@here", source: .engine)!
        XCTAssertEqual(path.url(for: "a b/c")?.absoluteString, "https://maps.test/search/a%20b%2Fc/@here", "in a path a space is %20")
        XCTAssertEqual(cushwake.url(for: " ")?.absoluteString, "https://www.cushmanwakefield.ae/", "nothing typed opens the site")
    }

    func testTermsAreReadBackFromTheTemplatesResultPagesOnly() {
        let template = cushwake.template
        XCTAssertEqual(SiteSearchTemplate.terms(in: url("https://www.cushmanwakefield.ae/search?q=L-144373&page=2"), template: template), "L-144373")
        XCTAssertEqual(SiteSearchTemplate.terms(in: url("https://cushmanwakefield.ae/search?q=a+b%26c"), template: template), "a b&c")
        XCTAssertNil(SiteSearchTemplate.terms(in: url("https://www.cushmanwakefield.ae/other?q=x"), template: template), "another path")
        XCTAssertNil(SiteSearchTemplate.terms(in: url("https://evil.test/search?q=x"), template: template), "another host")
        XCTAssertNil(SiteSearchTemplate.terms(in: url("https://www.cushmanwakefield.ae/search?p=x"), template: template))
        let path = "https://maps.test/search/%s"
        XCTAssertEqual(SiteSearchTemplate.terms(in: url("https://maps.test/search/coffee%20shops"), template: path), "coffee shops")
    }

    // MARK: Earlier queries

    private func search(_ text: String, visits: Int = 1, daysAgo: Double, profile: UUID? = nil) -> VisitRecord {
        let page = cushwake.url(for: text)!
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return VisitRecord(url: page, title: text, visitCount: visits, firstVisit: date, lastVisit: date, profileIDs: profile.map { [$0] })
    }

    func testEarlierQueriesRankByRecencyAndUseAndComplete() {
        let records = [
            search("L-144", daysAgo: 40),
            search("L-144681", visits: 2, daysAgo: 5),
            search("L-144373", visits: 3, daysAgo: 1),
            search("Dubai offices", daysAgo: 2),
            VisitRecord(url: url("https://www.cushmanwakefield.ae/about"), title: "About", firstVisit: now),
        ]
        let queries = SiteSearchQueries.collect(records, template: cushwake.template, now: now)
        XCTAssertEqual(queries.map(\.text), ["L-144373", "L-144681", "Dubai offices", "L-144"], "visits weighted by age")
        XCTAssertEqual(SiteSearchQueries.matching("L", in: queries).map(\.text), ["L-144373", "L-144681", "L-144"])
        XCTAssertEqual(SiteSearchQueries.matching("off", in: queries).map(\.text), ["Dubai offices"], "then text inside")
        XCTAssertTrue(SiteSearchQueries.matching("", in: queries).isEmpty, "nothing typed: the field alone")
        XCTAssertEqual(SiteSearchQueries.completion(for: "L-14", in: queries), "L-144373", "the best one completes inline")
        XCTAssertEqual(SiteSearchQueries.suffix(typed: "l-14", completion: "L-144373"), "4373")

        let rows = CommandBarSearch.siteSearchResults(cushwake, query: "L-14", queries: queries, completion: "L-144373")
        XCTAssertEqual(rows.map(\.title), ["L-144373", "L-144681", "L-144"], "the completed query first, as Arc lists it")
        XCTAssertTrue(rows.allSatisfy { $0.destinationURL?.host() == "www.cushmanwakefield.ae" }, "every row opens the entry's own template")
        XCTAssertEqual(rows.first?.subtitle, "cushmanwakefield.ae")
    }

    func testEarlierQueriesAreBoundedAndMergedByText() {
        var records = (0 ..< 80).map { search("query \($0)", daysAgo: Double($0)) }
        records.append(search("QUERY 1", visits: 4, daysAgo: 0))
        let queries = SiteSearchQueries.collect(records, template: cushwake.template, now: now)
        XCTAssertEqual(queries.count, SiteSearchQueries.limit)
        XCTAssertEqual(queries.first?.text, "QUERY 1", "one query, newest spelling, visits summed")
        XCTAssertEqual(queries.first?.count, 5)
    }

    func testEarlierQueriesFollowTheHistoryTheyComeFrom() {
        let personal = UUID(), container = UUID()
        var history = VisitHistory(records: [search("mine", daysAgo: 1, profile: personal), search("theirs", daysAgo: 1, profile: container)])
        let visible = history.visible(to: container, defaultProfileID: personal)
        XCTAssertEqual(SiteSearchQueries.collect(Array(visible.records.values), template: cushwake.template, now: now).map(\.text), ["theirs"],
                       "a container sees only its own (the command-bar rule)")
        history.removeAll()
        XCTAssertTrue(SiteSearchQueries.collect(Array(history.records.values), template: cushwake.template, now: now).isEmpty,
                      "clearing history clears them")
    }

    func testADefaultEngineChipAddsItsOwnSuggestionsAndOthersNever() {
        let google = SearchProvider.google.siteSearchEngine!
        let suggestions = [SearchSuggestion(text: "swift testing", destinationURL: url("https://www.google.com/search?q=swift+testing"))]
        XCTAssertEqual(CommandBarSearch.siteSearchResults(google, query: "swift", suggestions: suggestions).map(\.title), ["swift", "swift testing"])
        XCTAssertEqual(CommandBarSearch.siteSearchResults(cushwake, query: "swift", suggestions: suggestions).map(\.title), ["swift"])
    }

    // MARK: Keyword import

    private func webData(_ rows: [(name: String, keyword: String, url: String, prepopulate: Int, policy: Int, active: Int, auto: Int, starter: Int)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-webdata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(ChromiumKeywordsReader.fileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE keywords (id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL, favicon_url VARCHAR NOT NULL,
        url VARCHAR NOT NULL, safe_for_autoreplace INTEGER, usage_count INTEGER DEFAULT 0, prepopulate_id INTEGER DEFAULT 0,
        created_by_policy INTEGER DEFAULT 0, is_active INTEGER DEFAULT 0, starter_pack_id INTEGER DEFAULT 0);
        CREATE TABLE credit_cards (guid VARCHAR PRIMARY KEY, name_on_card VARCHAR);
        INSERT INTO credit_cards VALUES ('g', 'Never Read');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let sql = "INSERT INTO keywords (short_name, keyword, favicon_url, url, safe_for_autoreplace, usage_count, prepopulate_id, created_by_policy, is_active, starter_pack_id) VALUES ('\(row.name)', '\(row.keyword)', '', '\(row.url)', \(row.auto), \(10 - index), \(row.prepopulate), \(row.policy), \(row.active), \(row.starter))"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        return file
    }

    func testOnlyThePersonsOwnValidSiteSearchesAreImported() throws {
        let file = try webData([
            ("cushwake", "cwc", "https://www.cushmanwakefield.ae/search?q={searchTerms}", 0, 0, 1, 0, 0),
            ("Google", "google.com", "{google:baseURL}search?q={searchTerms}", 1, 0, 1, 0, 0),
            ("Found by Chromium", "found.test", "https://found.test/?q={searchTerms}", 0, 0, 0, 1, 0),
            ("Turned on later", "on.test", "https://on.test/?q={searchTerms}", 0, 0, 1, 1, 0),
            ("Switched off", "off", "https://off.test/?q={searchTerms}", 0, 0, 2, 0, 0),
            ("Policy", "corp", "https://corp.test/?q={searchTerms}", 0, 1, 1, 0, 0),
            ("Bookmarks", "@bookmarks", "chrome://bookmarks/?q={searchTerms}", 0, 0, 1, 0, 1),
            ("Script", "js", "javascript:alert({searchTerms})", 0, 0, 1, 0, 0),
        ])
        let rows = try ChromiumKeywordsReader.read(file)
        XCTAssertEqual(rows.map(\.keyword), ["cwc", "on.test", "js"], "prepopulated, Chromium-made, switched-off, policy and starter-pack rows stay")
        let profile = UUID()
        var imported = ImportedSiteSearches()
        XCTAssertEqual(imported.merge(rows, from: "arc/Default", into: profile), 2, "the javascript: template never passes")
        XCTAssertEqual(imported.merge(rows, from: "arc/Default", into: profile), 0, "importing twice adds nothing")
        XCTAssertEqual(imported.newCount(rows, into: UUID()), 2, "another profile has none yet")
        let engines = imported.engines(for: profile)
        XCTAssertEqual(engines.map(\.keyword), ["cwc", "on.test"])
        XCTAssertEqual(engines.first?.template, "https://www.cushmanwakefield.ae/search?q=%s")

        let saved = file.deletingLastPathComponent().appendingPathComponent(ImportedSiteSearches.fileName)
        try imported.save(to: saved)
        XCTAssertEqual(ImportedSiteSearches.load(from: saved), imported)
        let text = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertFalse(text.contains("Never Read"), "nothing but keywords is read")
    }

    func testAProfileWithoutWebDataImportsNothing() {
        XCTAssertTrue(ChromiumKeywordsReader.read(profile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).isEmpty)
    }

    // MARK: Colours

    func testSelectedFillsCarryWhiteTextAtFourPointFive() {
        let accents = ["#AE9D8D", "#579F8F", "#F5C518", "#FFFFFF", "#858AFF", "#C17C82", "#111111", "#FF9900"].map { SpaceColor(hex: $0)! }
        for accent in accents {
            let fill = CommandBarInk.selectionFill(accent)
            XCTAssertGreaterThanOrEqual(CommandBarInk.selectedText.contrast(with: fill), SidebarContrast.text, accent.hex)
            let lch = accent.oklab.lch
            if lch.c > 0.04 {
                let turn = abs(fill.oklab.lch.h - lch.h).truncatingRemainder(dividingBy: 360)
                XCTAssertLessThan(min(turn, 360 - turn), 8, "\(accent.hex): the same hue, only darker")
            }
        }
        XCTAssertEqual(CommandBarInk.selectionFill(SpaceColor(hex: "#1D4ED8")!).hex, "#1D4ED8", "a fill that already reads stays")
        for theme in [SpaceTheme.arcDefault, SpaceTheme(red: 0.95, green: 0.9, blue: 0.85), SpaceTheme(red: 0.1, green: 0.1, blue: 0.4)] {
            for dark in [false, true] {
                XCTAssertGreaterThanOrEqual(CommandBarInk.selectedText.contrast(with: CommandBarInk.accentFill(theme: theme, dark: dark)), 4.5)
            }
        }
    }

    func testTheCardsInksClearTheirFloorsInBothAppearances() {
        for dark in [false, true] {
            let card = CommandBarInk.surface(dark: dark)
            XCTAssertGreaterThanOrEqual(CommandBarInk.primaryText(dark: dark).contrast(with: card), 4.5)
            XCTAssertGreaterThanOrEqual(CommandBarInk.secondaryText(dark: dark).contrast(with: card), 4.5)
            XCTAssertGreaterThanOrEqual(CommandBarInk.glyph(dark: dark).contrast(with: card), 3)
        }
        XCTAssertEqual(CommandBarInk.surface(dark: false).hex, "#F9F9F9", "Arc's card, measured")
    }

    func testASiteFillFallsBackToTheSpaceWhereItCannotShow() {
        let accent = CommandBarInk.selectionFill(SpaceColor(hex: "#858AFF")!)
        XCTAssertEqual(CommandBarInk.siteFill(nil, accentFill: accent, dark: false), accent, "no colour: the space's")
        XCTAssertEqual(CommandBarInk.siteFill(SpaceColor(hex: "#111111")!, accentFill: accent, dark: true), accent, "black on the dark card")
        XCTAssertNotEqual(CommandBarInk.siteFill(SpaceColor(hex: "#111111")!, accentFill: accent, dark: false), accent)
    }

    func testAFaviconsDominantColourIgnoresItsBackground() {
        func icon(_ pixel: (Int) -> [UInt8]) -> [UInt8] { (0 ..< 16 * 16).flatMap(pixel) }
        // A white square with a red mark on a quarter of it.
        let red = icon { $0 % 4 == 0 ? [220, 30, 40, 255] : [255, 255, 255, 255] }
        let color = FaviconColor.dominant(rgba: red, width: 16, height: 16, bytesPerRow: 64)
        XCTAssertEqual(color.map { Int(($0.red * 255).rounded()) }, 220)
        let mono = icon { $0 % 2 == 0 ? [0, 0, 0, 255] : [255, 255, 255, 0] }
        XCTAssertNil(FaviconColor.dominant(rgba: mono, width: 16, height: 16, bytesPerRow: 64), "a black-and-white icon has no colour")
    }
}
