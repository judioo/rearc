import XCTest
@testable import SidebarModel

/// The prepared command-bar indexes rank exactly as the unprepared code did
/// (`LegacyCommandBarSearch`, `LegacyMenuCommandSearch`, `VisitHistory.matches`).
final class CommandBarIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Text the fast ASCII path and the String fallback both have to get right.
    private static let corpus = [
        "", "a", "Design notes release 12", "GitHub · Build software better", "news.ycombinator.com/item?id=1",
        "Über café — Résumé", "cafe\u{301} au lait", "café", "naïve façade", "日本語のページ", "emoji 🚀 launch",
        "line\r\nbreak", "tab\tseparated", "C++ reference", "foo-bar_baz", "www.example.com", "  padded  ",
        "ALL CAPS TITLE", "x.com", "i̇stanbul", "ß straße", "ﬁle ligature",
    ]

    private static let needles = [
        "", "a", "d", "de", "design", "notes", "git", "hub", "news", "1", "c++", "bar", "www", "e", "é", "e\u{301}",
        "cafe", "café", "über", "ü", "日本", "🚀", "\r", "\n", "break", "line\r", "\r\nb", "tab", "x.", "ß", "ss", "fi", "i",
    ]

    func testPreparedTextMatchesStringSemantics() {
        for raw in Self.corpus {
            let text = raw.lowercased()
            let prepared = PreparedText(text)
            for raw in Self.needles {
                let needle = raw.lowercased()
                let pin = PreparedText.Needle(needle)
                XCTAssertEqual(prepared.contains(pin), text.contains(needle), "'\(text)' contains '\(needle)'")
                XCTAssertEqual(prepared.hasPrefix(pin), text.hasPrefix(needle), "'\(text)' hasPrefix '\(needle)'")
                let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                XCTAssertEqual(prepared.hasWord(withPrefix: pin), words.contains { $0.hasPrefix(needle) }, "'\(text)' word '\(needle)'")
            }
        }
    }

    func testPreparedFuzzyMatchScoresAsTheOriginal() {
        let haystacks = Self.corpus + ["New Tab", "Switch to Personal", "Toggle Sidebar", "Reset Tab to Original URL",
                                       "Copy Current URL", "File › New Window", "View › Developer › JavaScript Console"]
        let queries = Self.needles + ["nt", "new tab", "sw per", "tsb", "copy url", "jsc", "zzz", "  New  "]
        for haystack in haystacks {
            let prepared = TypeTravelFuzzyMatch.Haystack(haystack)
            for query in queries {
                XCTAssertEqual(TypeTravelFuzzyMatch.match(TypeTravelFuzzyMatch.Needle(query), in: prepared),
                               TypeTravelFuzzyMatch.match(query: query, in: haystack), "'\(query)' in '\(haystack)'")
            }
        }
        for query in queries {
            let keywords = ["tab", "window", "new"]
            XCTAssertEqual(TypeTravelFuzzyMatch.bestScore(TypeTravelFuzzyMatch.Needle(query), title: .init("New Tab"),
                                                          keywords: keywords.map(TypeTravelFuzzyMatch.Haystack.init)),
                           TypeTravelFuzzyMatch.bestScore(query: query, title: "New Tab", keywords: keywords))
        }
    }

    // MARK: Fixtures

    /// The perf-0 500-row sidebar, plus tabs whose text exercises the fallback.
    private func store() -> SidebarStore {
        let store = BenchFixture.make(.items500, seed: 7) { URL(string: "https://tabs.test/page/\($0)")! }.store
        for (index, title) in Self.corpus.enumerated() {
            store.addTab(kind: index % 3 == 0 ? .pinned : .today, title: title,
                         url: URL(string: "https://www.Corpus\(index).example/Path/\(index)#frag")!)
        }
        store.addTab(kind: .favorite, title: "GitHub", url: URL(string: "https://github.com")!)
        store.addTab(kind: .today, title: "", url: URL(string: "https://untitled.example/")!)
        store.addTab(kind: .today, title: "Data", url: URL(string: "data:text/plain,design")!)
        return store
    }

    /// Thousands of pages: realistic hosts and titles, plus the corpus.
    private func history() -> VisitHistory {
        let hosts = ["github.com", "www.google.com", "news.ycombinator.com", "developer.apple.com", "docs.swift.org",
                     "en.wikipedia.org", "www.youtube.com", "design.example", "café.example", "x.com"]
        let words = ["Design", "notes", "release", "Swift", "GitHub", "issue", "pull", "request", "café", "Über", "C++", "build"]
        var records: [VisitRecord] = []
        for index in 0..<4_000 {
            let host = hosts[index % hosts.count]
            let title = (0..<(index % 5 + 1)).map { words[(index / 3 + $0 * 7) % words.count] }.joined(separator: index % 4 == 0 ? " · " : " ")
            records.append(VisitRecord(url: URL(string: "https://\(host)/p/\(index)?q=\(index % 13)")!,
                                       title: index % 97 == 0 ? "" : title, visitCount: index % 23 + 1,
                                       firstVisit: now.addingTimeInterval(-Double(index * 3_701 % 9_000_000))))
        }
        for (index, title) in Self.corpus.enumerated() {
            records.append(VisitRecord(url: URL(string: "https://corpus\(index).example/\(index)")!, title: title,
                                       visitCount: index + 1, firstVisit: now.addingTimeInterval(-Double(index) * 86_400)))
        }
        // Ties on score and date, decided by the URL.
        for index in 0..<20 {
            records.append(VisitRecord(url: URL(string: "https://tie.example/\(index)")!, title: "Tie page",
                                       visitCount: 3, firstVisit: now.addingTimeInterval(-3_600)))
        }
        return VisitHistory(records: records)
    }

    private static let menus: [MenuCommand] = {
        var menus: [MenuCommand] = (0..<120).map { index in
            let menu = ["File", "Edit", "View", "Spaces", "Tabs", "Window", "Help"][index % 7]
            return MenuCommand(id: "\(index):\(menu) › Item \(index)", title: "Item \(index) \(menu)…",
                               path: "\(menu) › Item \(index) \(menu)…", keyEquivalent: index % 4 == 0 ? "⌘\(index % 10)" : "",
                               isEnabled: index % 11 != 0, hasAction: index % 13 != 0)
        }
        menus += [
            MenuCommand(id: "q", title: "Quit ReArc", path: "ReArc › Quit ReArc", keyEquivalent: "⌘Q", requiresExactQuery: true),
            MenuCommand(id: "q2", title: "Quit ReArc", path: "ReArc › Quit ReArc", keyEquivalent: "⌘Q"),
            MenuCommand(id: "d1", title: "Duplicate", path: "Edit › Duplicate", keyEquivalent: "⌘D"),
            MenuCommand(id: "d2", title: "Duplicate", path: "Edit › Duplicate", keyEquivalent: "⌘D"),
            MenuCommand(id: "nt", title: "New Tab", path: "File › New Tab", keyEquivalent: "⌘T"),
            MenuCommand(id: "empty", title: "...", path: "File › ..."),
            MenuCommand(id: "u", title: "Über Fenster", path: "Window › Über Fenster"),
        ]
        return menus
    }()

    private static let queries = [
        "", " ", "d", "de", "des", "design", "design n", "design notes", "notes release", "g", "git", "github",
        "github.com", "https://github.com", "www.", "site4", "page 12", "tabs.test", "café", "cafe\u{301}", "über",
        "c++", "日本", "🚀", "x.com", "news", "ycombinator", "tie", "untitled", "1", "42", "item 3", "duplicate",
        "quit rearc", "quit", "new tab", "nt", "sw", "a b", "  Design  Notes ", "DESIGN", ">", "> ", ">tab", ">new",
        ">quit rearc", ">item 1", ">über", "e", "zzz",
    ]

    private func catalog(_ store: SidebarStore) -> [AppCommand] {
        AppCommandRegistry.all(in: CommandBarContext(
            store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack, peekURL: nil,
            focusedLittleArcID: nil, mediaByTab: [:], tabMuteModel: TabMediaMuteModel(), navigationSchemes: [],
            externalLinkDestination: .littleArc))
    }

    // MARK: Old and new ranking

    func testPreparedHistoryRanksAsTheOriginalScan() {
        let history = history()
        let excluded = Set(history.records.keys.sorted().enumerated().filter { $0.offset % 9 == 0 }.map(\.element))
        for query in Self.queries + Self.needles {
            XCTAssertEqual(history.searchIndex.matches(for: query, now: now, limit: 40, excluding: excluded),
                           history.matches(for: query, now: now, limit: 40, excluding: excluded), "'\(query)' excluding")
            XCTAssertEqual(history.searchIndex.matches(for: query, now: now, limit: 1),
                           history.matches(for: query, now: now, limit: 1), "'\(query)' limit 1")
        }
    }

    func testHistoryIndexFollowsWritesRemovalsAndEviction() {
        var history = history()
        let keys = history.records.keys.sorted()
        for (offset, key) in keys.enumerated() where offset % 5 == 0 {
            history.remove(url: history.records[key]!.url)
        }
        for index in 0..<300 {
            history.recordVisit(url: URL(string: "https://github.com/p/\(index * 7)?q=\(index * 7 % 13)")!,
                                title: index % 2 == 0 ? "Design revisited \(index)" : nil, at: now.addingTimeInterval(Double(index)))
            history.updateTitle(url: URL(string: "https://design.example/p/\(index * 10 + 7)?q=\((index * 10 + 7) % 13)")!, title: "Retitled café \(index)")
        }
        for index in 0..<1_500 {
            history.recordVisit(url: URL(string: "https://fresh\(index).example/")!, title: "Fresh design \(index)", at: now)
        }
        XCTAssertEqual(history.count, VisitHistory.capacity)
        for query in ["design", "fresh", "github", "café", "retitled", "revisited", "tie", "e", "1"] {
            XCTAssertEqual(history.searchIndex.matches(for: query, now: now, limit: 25), history.matches(for: query, now: now, limit: 25), "'\(query)'")
        }
    }

    func testMenuIndexMatchesAsTheOriginal() {
        let store = store()
        let registered = catalog(store) + [AppCommand(id: "x", title: "Item 5 Tabs…", action: .newTab)]
        let index = MenuCommandSearch.Index(Self.menus, registered: registered)
        for query in Self.queries.map({ CommandBarSearch.parseMode($0).needle }) {
            XCTAssertEqual(index.matches(query: query).map(\.id),
                           LegacyMenuCommandSearch.matches(Self.menus, query: query, registered: registered).map(\.id), "'\(query)'")
        }
    }

    func testResultsRankAsTheOriginalOnFixtures() {
        let store = store()
        let history = history()
        let catalog = catalog(store)
        store.commandBarUsageBumps = [catalog[3].id: 2, catalog[10].id: 1]
        let tabIndex = CommandBarSearch.TabIndex(store: store)
        let commandIndex = CommandBarSearch.CommandIndex(catalog: catalog)
        let menuIndex = MenuCommandSearch.Index(Self.menus, registered: catalog)
        let engineHistory = Array(history.records.values.sorted { $0.url.absoluteString < $1.url.absoluteString }.prefix(50))
        for query in Self.queries {
            let lives: [CommandBarLiveResults?] = [
                nil,
                CommandBarLiveResults(query: query, history: engineHistory),
                CommandBarLiveResults(query: query, history: [], classification: .url(URL(string: "https://github.com/")!)),
                CommandBarLiveResults(query: query, suggestions: [
                    SearchSuggestion(text: query + " docs", destinationURL: URL(string: "https://duckduckgo.com/?q=docs")!),
                    SearchSuggestion(text: query, destinationURL: URL(string: "https://duckduckgo.com/?q=same")!),
                ], classification: .search(URL(string: "https://duckduckgo.com/?q=x")!)),
                CommandBarLiveResults(query: "other text", history: engineHistory),
            ]
            for live in lives {
                for inline in live == nil ? [nil, "github.com"] : [nil] {
                    let legacy = LegacyCommandBarSearch.results(for: query, in: store, history: history, commandCatalog: catalog,
                                                                menuCommands: Self.menus, live: live, inlineCompletion: inline, now: now)
                    let prepared = CommandBarSearch.results(for: query, in: store, history: history,
                                                            liveHistory: live?.history.map { VisitHistory(records: $0) },
                                                            tabIndex: tabIndex, commandIndex: commandIndex, menuIndex: menuIndex,
                                                            live: live, inlineCompletion: inline, now: now)
                    XCTAssertEqual(prepared, legacy, "'\(query)' live \(live?.query ?? "-") inline \(inline ?? "-")")
                    guard live == nil else { continue }
                    let unprepared = CommandBarSearch.results(for: query, in: store, history: history, commandCatalog: catalog,
                                                              menuCommands: Self.menus, live: live, inlineCompletion: inline, now: now)
                    XCTAssertEqual(unprepared, legacy, "'\(query)' without indexes")
                }
            }
        }
        // The default catalog (built from the context) too.
        for query in ["d", ">tab", "github"] {
            XCTAssertEqual(CommandBarSearch.results(for: query, in: store, history: history, now: now),
                           LegacyCommandBarSearch.results(for: query, in: store, history: history, now: now))
        }
    }

    func testTabIndexKeepsSidebarRankAndHistoryKeys() {
        let store = store()
        let index = CommandBarSearch.TabIndex(store: store)
        for entry in index.entries {
            XCTAssertEqual(entry.historyKey, VisitHistory.key(for: entry.tab.url))
        }
        for query in Self.queries.map({ CommandBarSearch.parseMode($0).needle }) where !query.isEmpty {
            let legacy = LegacyCommandBarSearch.results(for: query, in: store, commandCatalog: []).filter { $0.kind == .openTab }
            XCTAssertEqual(index.results(for: query), legacy, "'\(query)'")
        }
    }
}
