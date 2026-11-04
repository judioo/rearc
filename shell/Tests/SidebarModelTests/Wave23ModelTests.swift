import XCTest
@testable import SidebarModel

/// Wave 23 pure models: search providers and suggestions, live command-bar
/// results (engine history, URL-vs-search, suggestions, row actions), the
/// per-keystroke gate, the tab unload policy, HTML fullscreen steps and
/// download warnings.
final class Wave23ModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Search providers

    func testProvidersFillTheirTemplates() {
        XCTAssertEqual(SearchProvider.google.searchURL(for: "red pandas")?.absoluteString, "https://www.google.com/search?q=red%20pandas")
        XCTAssertEqual(SearchProvider.duckDuckGo.suggestURL(for: "a&b")?.absoluteString, "https://duckduckgo.com/ac/?q=a%26b&type=list")
        XCTAssertEqual(SearchProvider.bing.searchURL(for: "c++ 1+1")?.absoluteString, "https://www.bing.com/search?q=c%2B%2B%201%2B1")
        XCTAssertNil(SearchProvider.google.searchURL(for: "   "), "no search for blank terms")
        XCTAssertTrue(SearchProvider.isValidTemplate("https://example.com/s?q=%s"))
        XCTAssertFalse(SearchProvider.isValidTemplate("https://example.com/s"), "a template needs %s")
        XCTAssertFalse(SearchProvider.isValidTemplate("javascript:%s"), "only http(s)")
        XCTAssertNil(SearchProvider(id: "x", name: "X", keyword: "x", searchTemplate: "https://x/?q=%s", suggestTemplate: "").suggestTemplate)
    }

    func testURLEntryUsesTheProviderForSearchesOnly() {
        XCTAssertEqual(URLEntry.resolve("red pandas", provider: .google)?.host(), "www.google.com")
        XCTAssertEqual(URLEntry.resolve("example.com", provider: .google)?.absoluteString, "https://example.com")
        XCTAssertEqual(URLEntry.resolve("red pandas")?.host(), "duckduckgo.com", "DuckDuckGo stays the default")
        XCTAssertEqual(URLEntry.searchURL(for: "x", provider: .ecosia)?.host(), "www.ecosia.org")
    }

    func testPreferenceRoundTripsAndFallsBackToDuckDuckGo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-w23-\(UUID().uuidString)"))
        XCTAssertEqual(SearchProviderPreference.load(from: defaults), SearchProviderPreference())
        SearchProviderPreference(providerID: "bing", suggestionsEnabled: false).save(to: defaults)
        let loaded = SearchProviderPreference.load(from: defaults)
        XCTAssertEqual(loaded.provider, .bing)
        XCTAssertFalse(loaded.suggestionsEnabled)
        XCTAssertEqual(SearchProviderPreference(providerID: "gone").provider, .duckDuckGo)
    }

    func testOpenSearchSuggestionsParse() {
        let body = Data(#"["red", ["red pandas", "Red Pandas", "", "reddit", 4], [], {}]"#.utf8)
        XCTAssertEqual(SearchSuggestionParser.parse(body), ["red pandas", "reddit"], "blank, duplicate and non-string items are dropped")
        XCTAssertEqual(SearchSuggestionParser.parse(Data("{}".utf8)), [])
        XCTAssertEqual(SearchSuggestionParser.parse(Data(#"["q", ["a", "b", "c"]]"#.utf8), limit: 2), ["a", "b"])
    }

    // MARK: Live command-bar results

    private func storeWithTab() -> SidebarStore {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        store.addTab(kind: .today, title: "Pandas Wiki", url: URL(string: "https://pandas.example/wiki")!)
        return store
    }

    private func visit(_ url: String, _ title: String, count: Int = 1, daysAgo: Double = 0) -> VisitRecord {
        VisitRecord(url: URL(string: url)!, title: title, visitCount: count, firstVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testEngineHistoryReplacesTheShellStoreForItsQueryOnly() {
        let store = storeWithTab()
        let local = VisitHistory(records: [visit("https://local.example/pandas", "Local pandas")])
        let live = CommandBarLiveResults(query: "pandas", history: [visit("https://engine.example/pandas", "Engine pandas", count: 3)])
        let engine = CommandBarSearch.results(for: "pandas", in: store, history: local, live: live, now: now)
        XCTAssertEqual(engine.filter { $0.kind == .history }.map(\.title), ["Engine pandas"])
        let other = CommandBarSearch.results(for: "panda", in: store, history: local, live: live, now: now)
        XCTAssertEqual(other.filter { $0.kind == .history }.map(\.title), ["Local pandas"], "results for other text are ignored")
        XCTAssertEqual(engine.first?.kind, .openTab, "open tabs still rank first")
    }

    func testClassificationDecidesAddressOrSearch() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let intranet = URL(string: "http://wiki/")!
        let asURL = CommandBarSearch.results(for: "wiki", in: store, live: CommandBarLiveResults(query: "wiki", classification: .url(intranet)), now: now)
        XCTAssertEqual(asURL.first?.kind, .openURL)
        XCTAssertEqual(asURL.first?.destinationURL, intranet)
        XCTAssertFalse(asURL.contains { $0.kind == .search }, "an address has no search fallback")

        let engineSearch = URL(string: "https://www.google.com/search?q=example.com+x")!
        let asSearch = CommandBarSearch.results(
            for: "example.com", in: store,
            live: CommandBarLiveResults(query: "example.com", classification: .search(engineSearch)), now: now
        )
        XCTAssertFalse(asSearch.contains { $0.kind == .openURL })
        XCTAssertEqual(asSearch.last?.destinationURL, engineSearch)

        let guessed = CommandBarSearch.results(for: "red pandas", in: store, searchProvider: .google, now: now)
        XCTAssertEqual(guessed.last?.destinationURL?.host(), "www.google.com", "without the engine, the provider builds the search")
    }

    func testSuggestionsRankAfterHistoryAndDropTheTypedText() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let history = VisitHistory(records: [visit("https://red.example/", "Red site")])
        let suggestions = ["red", "red pandas", "RED PANDAS", "red dwarf", "red fox", "red wine", "red sea"].map {
            SearchSuggestion(text: $0, destinationURL: SearchProvider.duckDuckGo.searchURL(for: $0)!)
        }
        let results = CommandBarSearch.results(for: "red", in: store, history: history,
                                               live: CommandBarLiveResults(query: "red", suggestions: suggestions), now: now)
        let kinds = results.map(\.kind)
        let firstSuggestion = try? XCTUnwrap(kinds.firstIndex(of: .suggestion))
        XCTAssertLessThan(kinds.firstIndex(of: .history)!, firstSuggestion ?? 0)
        XCTAssertEqual(results.filter { $0.kind == .suggestion }.map(\.title), ["red pandas", "red dwarf", "red fox", "red wine"],
                       "the typed text and duplicates are dropped; four at most")
        XCTAssertEqual(results.last?.kind, .search, "the search fallback stays last")
    }

    func testRowActionsFollowTheResultKind() {
        let url = URL(string: "https://a.example/")!
        func row(_ kind: CommandBarSearch.ResultKind, _ destination: URL? = url) -> CommandBarSearch.Result {
            CommandBarSearch.Result(id: "x", kind: kind, title: "x", destinationURL: destination)
        }
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.history)), [.copyURL, .deleteFromHistory])
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.openTab)), [.copyURL])
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.suggestion)), [.copyURL])
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.openURL, nil)), [])
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.command, nil)), [])
        XCTAssertEqual(CommandBarSearch.rowActions(for: row(.search)), [])
    }

    func testQueryGateKeepsOnlyTheNewestKeystroke() {
        var gate = CommandBarQueryGate()
        let first = gate.begin("r")
        let second = gate.begin("re")
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertEqual(gate.query, "re")
        gate.cancel()
        XCTAssertFalse(gate.isCurrent(second), "closing the bar makes every request stale")
        XCTAssertTrue(CommandBarLiveResults(query: " Red ").applies(to: "red"))
        XCTAssertFalse(CommandBarLiveResults(query: "red").applies(to: "redd"))
    }

    // MARK: Tab unload

    func testUnloadPicksHiddenIdleTabsOldestFirst() {
        let ids = (0..<6).map { _ in UUID() }
        let candidates = [
            TabUnloadCandidate(tabID: ids[0], lastActive: now.addingTimeInterval(-5 * 3600)),
            TabUnloadCandidate(tabID: ids[1], lastActive: now.addingTimeInterval(-9 * 3600)),
            TabUnloadCandidate(tabID: ids[2], lastActive: now.addingTimeInterval(-9 * 3600), isVisible: true),
            TabUnloadCandidate(tabID: ids[3], lastActive: now.addingTimeInterval(-9 * 3600), isAudible: true),
            TabUnloadCandidate(tabID: ids[4], lastActive: now.addingTimeInterval(-9 * 3600), isUnloaded: true),
            TabUnloadCandidate(tabID: ids[5], lastActive: now.addingTimeInterval(-9 * 3600), hasPendingPrompt: true),
        ]
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(candidates, threshold: .fourHours, now: now), [ids[1], ids[0]])
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(candidates, threshold: .twelveHours, now: now), [])
        XCTAssertEqual(TabUnloadPolicy.tabsToUnload(candidates, threshold: .never, now: now), [])
        XCTAssertEqual(TabUnloadThreshold.thirtyMinutes.interval, 1800)
    }

    func testUnloadThresholdIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-w23-\(UUID().uuidString)"))
        XCTAssertEqual(TabUnloadThreshold.load(from: defaults), .fourHours)
        TabUnloadThreshold.oneHour.save(to: defaults)
        XCTAssertEqual(TabUnloadThreshold.load(from: defaults), .oneHour)
    }

    // MARK: HTML fullscreen

    func testFullscreenRestoresTheWindowAsItWas() {
        let windowed = HTMLFullscreenSession(tabID: UUID(), engineTabID: 7, windowWasFullscreen: false, sidebarWasVisible: true)
        XCTAssertEqual(windowed.enterSteps, [.hideChrome, .enterNativeFullscreen])
        XCTAssertEqual(windowed.pageExitSteps, [.restoreChrome(sidebarVisible: true), .exitNativeFullscreen])
        XCTAssertEqual(windowed.windowExitSteps, [.restoreChrome(sidebarVisible: true), .exitPageFullscreen])

        let already = HTMLFullscreenSession(tabID: nil, engineTabID: 8, windowWasFullscreen: true, sidebarWasVisible: false)
        XCTAssertEqual(already.enterSteps, [.hideChrome], "a window already fullscreen stays so")
        XCTAssertEqual(already.pageExitSteps, [.restoreChrome(sidebarVisible: false)])
    }

    // MARK: Download warnings

    func testWarningBooleansDecideKeepAndDiscard() {
        let dangerous = DownloadWarning(dangerType: 3, insecureStatus: 1, isDangerous: true, isInsecure: false)
        XCTAssertTrue(dangerous.offersDecision)
        XCTAssertEqual(dangerous.message, "This file is dangerous")
        let insecure = DownloadWarning(dangerType: 0, insecureStatus: 3, isDangerous: false, isInsecure: true)
        XCTAssertTrue(insecure.offersDecision)
        XCTAssertEqual(insecure.message, "This file can't be downloaded securely")
        XCTAssertFalse(DownloadWarning(dangerType: 4, insecureStatus: 0, isDangerous: false, isInsecure: false).offersDecision,
                       "a pending check (4) is not a decision")
        XCTAssertFalse(DownloadWarning(dangerType: 6, insecureStatus: 2, isDangerous: false, isInsecure: false).offersDecision,
                       "validated items need nothing")
        XCTAssertEqual(DownloadDangerDecision.keep.rawValue, 0)
        XCTAssertEqual(DownloadDangerDecision.discard.rawValue, 1)
    }
}
