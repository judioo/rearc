import AppKit
import CryptoKit
import XCTest
@testable import ReArc
@testable import SidebarModel

private final class FakeFetch: SuggestFetch {
    var cancelled = false
    func cancel() { cancelled = true }
}

private final class FakeSuggestFetcher: SuggestFetching {
    var urls: [URL] = []
    var fetches: [FakeFetch] = []
    var completions: [(Data?) -> Void] = []

    func fetch(_ url: URL, completion: @escaping (Data?) -> Void) -> SuggestFetch {
        urls.append(url)
        let fetch = FakeFetch()
        fetches.append(fetch)
        completions.append(completion)
        return fetch
    }
}

/// Records the model's lookups and lets the test answer them in any order.
private final class FakeCommandBarServices: CommandBarServices {
    var provider = SearchProvider.google
    var queries: [(text: String, deliver: (CommandBarLiveResults) -> Void)] = []
    var cancels = 0
    var deleted: [URL] = []
    var deleteCompletions: [(Bool) -> Void] = []
    var onSearchProviderChange: (() -> Void)?

    func searchProvider(for profileID: Profile.ID) -> SearchProvider { provider }
    var opens = 0
    func commandBarWillOpen(profileID: Profile.ID) { opens += 1 }

    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void) {
        queries.append((text, deliver))
    }

    func cancel() { cancels += 1 }

    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool {
        deleted.append(url)
        deleteCompletions.append(completion)
        return true
    }
}

private final class DangerBackend: DownloadBackend {
    var decisions: [(DownloadDangerDecision, String)] = []
    var removes: [String] = []

    func perform(_ action: DownloadAction, id: String) -> Bool {
        if action == .remove { removes.append(id) }
        return true
    }

    func directoryChanged(_ directory: URL) {}

    func resolveDanger(_ decision: DownloadDangerDecision, id: String) -> Bool {
        decisions.append((decision, id))
        return true
    }
}

/// Wave 23: ABI 1.23–1.27 gating, the command bar's engine history,
/// suggestions and row actions, the WebKit suggest fetcher, tab unload,
/// HTML fullscreen on the window and native Keep / Discard downloads.
final class Wave23ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w23-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w23-\(UUID().uuidString)")!
        return model
    }

    // MARK: Capabilities

    func testWave23FeaturesNeedTheirMinorAndFlag() {
        let all: (String) -> Bool = { _ in true }
        for (minor, feature) in [(23, "history_query"), (24, "dangerous_downloads"), (25, "tab_discard"),
                                 (26, "search_autocomplete"), (27, "html_fullscreen")] {
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: UInt32(minor - 1), hasFeature: all).summary.contains("\(feature)=0"),
                          "\(feature) waits for 1.\(minor)")
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: UInt32(minor), hasFeature: all).summary.contains("\(feature)=1"))
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 99) { $0 != feature }.summary.contains("\(feature)=0"),
                          "\(feature) needs its feature string")
        }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 27) { $0 != "downloads" }.dangerousDownloads,
                       "Keep and Discard need the download events too")
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 27, hasFeature: all).canInspect, "no DevTools frontend before ABI 1.40")
    }

    func testOnlyTheSelfTestBlocklistsItsInertDownload() {
        let product = ChromiumLaunchArguments.browserArguments(["ReArc"], defaultUserDataDir: { "/tmp/p" }, keychain: .system)
        XCTAssertFalse(product.contains { $0.hasPrefix("--safebrowsing-manual-download-blacklist") })
        XCTAssertTrue(ChromiumLaunchArguments.selfTestArguments(product).contains(ChromiumLaunchArguments.selfTestDangerSwitch))
        let bytes = Data(repeating: UInt8(ascii: "a"), count: ChromiumLaunchArguments.selfTestDangerousDownloadSize)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, ChromiumLaunchArguments.selfTestDangerousDownloadSHA256)
    }

    // MARK: Chromium mapping

    func testHistoryRowsBecomeVisitRecords() throws {
        let row = ChromiumHistoryRow(title: "A", url: "https://a.example/x", visitTimeUS: 1_700_000_000_000_000, visitCount: 3)
        let record = try XCTUnwrap(row.record)
        XCTAssertEqual(record.visitCount, 3)
        XCTAssertEqual(record.lastVisit.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertNil(ChromiumHistoryRow(title: "", url: "chrome://history", visitTimeUS: 0, visitCount: 1).record, "WebUI is never suggested")
        XCTAssertEqual(ChromiumHistoryRow(title: "", url: "https://b.example", visitTimeUS: 0, visitCount: 0).record?.visitCount, 1)
    }

    func testSearchProviderClassificationAndSuggestionsMap() throws {
        let provider = try XCTUnwrap(ChromiumSearchMapping.provider(
            name: "Google", keyword: "google.com",
            searchURL: "https://www.google.com/search?q=%s", suggestURL: "https://www.google.com/complete/search?q=%s"
        ))
        XCTAssertEqual(provider.searchURL(for: "x")?.absoluteString, "https://www.google.com/search?q=x")
        XCTAssertNotNil(provider.suggestTemplate)
        XCTAssertNil(ChromiumSearchMapping.provider(name: "Bad", keyword: "b", searchURL: "https://b/", suggestURL: ""))
        XCTAssertNil(ChromiumSearchMapping.provider(name: "S", keyword: "s", searchURL: "https://s/?q=%s", suggestURL: "")?.suggestTemplate)

        XCTAssertEqual(ChromiumSearchMapping.classification(kind: 1, destination: "http://wiki/"), .url(URL(string: "http://wiki/")!))
        XCTAssertEqual(ChromiumSearchMapping.classification(kind: 2, destination: "https://s/?q=a"), .search(URL(string: "https://s/?q=a")!))
        XCTAssertNil(ChromiumSearchMapping.classification(kind: 0, destination: "https://s/"))

        func match(_ kind: UInt32, _ contents: String, fill: String = "") -> ChromiumAutocompleteMatch {
            ChromiumAutocompleteMatch(kind: kind, matchType: 0, relevance: 1, allowedToBeDefault: false, deletable: false,
                                      contents: contents, description: "", destinationURL: "https://s/?q=\(contents.count)",
                                      fillIntoEdit: fill)
        }
        let suggestions = ChromiumSearchMapping.suggestions([match(1, "a.example"), match(2, "red pandas", fill: "kw red pandas"),
                                                             match(2, "", fill: "red fox"), match(2, " ")])
        XCTAssertEqual(suggestions.map(\.text), ["red pandas", "red fox"], "URL matches and blank text are left out")
    }

    // MARK: WebKit suggestions

    func testWebKitSuggestionsAreCancelledPerKeystrokeAndNeverPrivate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rearc-w23-\(UUID().uuidString)"))
        let fetcher = FakeSuggestFetcher()
        let services = WebKitCommandBarServices(defaults: defaults, fetcher: fetcher, debounce: 0)
        var delivered: [CommandBarLiveResults] = []
        services.query("re", profileID: UUID(), isPrivate: false) { delivered.append($0) }
        services.query("red", profileID: UUID(), isPrivate: false) { delivered.append($0) }
        XCTAssertEqual(fetcher.urls.map(\.absoluteString), ["https://duckduckgo.com/ac/?q=re&type=list", "https://duckduckgo.com/ac/?q=red&type=list"])
        XCTAssertTrue(fetcher.fetches[0].cancelled, "the next keystroke cancels the request in flight")
        fetcher.completions[0](Data(#"["re", ["react"]]"#.utf8))
        XCTAssertTrue(delivered.isEmpty, "a cancelled request's late answer is dropped")
        fetcher.completions[1](Data(#"["red", ["red pandas"]]"#.utf8))
        XCTAssertEqual(delivered.map(\.query), ["red"])
        XCTAssertEqual(delivered.first?.suggestions.first?.destinationURL.absoluteString, "https://duckduckgo.com/?q=red%20pandas")

        services.query("secret", profileID: UUID(), isPrivate: true) { _ in XCTFail("private text was sent") }
        services.preference.suggestionsEnabled = false
        services.query("anything", profileID: UUID(), isPrivate: false) { _ in XCTFail("suggestions are off") }
        XCTAssertEqual(fetcher.urls.count, 2)
        services.preference = SearchProviderPreference(providerID: "bing")
        XCTAssertEqual(SearchProviderPreference.load(from: defaults).provider, .bing, "the preference is remembered")
    }

    // MARK: Command bar

    func testTypingStartsLookupsAndOnlyTheNewestAnswerShows() {
        let model = makeModel()
        let services = FakeCommandBarServices()
        model.commandBarServices = services
        model.newTab()
        XCTAssertEqual(services.opens, 1, "opening the bar re-reads the default search")
        model.commandBarText = "pa"
        model.commandBarText = "pan"
        XCTAssertTrue(services.queries.isEmpty, "a keystroke's lookups wait for its frame to be committed")
        model.commandBarAfterCommit.flush()
        XCTAssertEqual(services.queries.map(\.text), ["pan"], "keys typed within one frame ask once, for the newest text")
        model.commandBarText = "panda"
        model.commandBarAfterCommit.flush()
        XCTAssertEqual(services.queries.map(\.text), ["pan", "panda"])
        services.queries[0].deliver(CommandBarLiveResults(query: "pan", suggestions: [
            SearchSuggestion(text: "pancakes", destinationURL: URL(string: "https://www.google.com/search?q=pancakes")!),
        ]))
        XCTAssertNil(model.commandBarLive, "an older keystroke's answer is ignored")
        services.queries[1].deliver(CommandBarLiveResults(query: "panda", suggestions: [
            SearchSuggestion(text: "panda facts", destinationURL: URL(string: "https://www.google.com/search?q=panda%20facts")!),
        ]))
        XCTAssertEqual(model.commandBarResults.filter { $0.kind == .suggestion }.map(\.title), ["panda facts"])
        XCTAssertEqual(model.commandBarResults.last?.destinationURL?.host(), "www.google.com", "the engine's provider searches")

        model.commandBarText = ">rel"
        XCTAssertEqual(services.queries.count, 2, "command mode asks nothing")
        XCTAssertNil(model.commandBarLive)
        let cancels = services.cancels
        model.dismissCommandBar()
        XCTAssertGreaterThan(services.cancels, cancels, "closing the bar cancels lookups")
    }

    func testRemoveFromHistoryReachesTheShellStoreAndTheEngine() throws {
        let model = makeModel()
        let services = FakeCommandBarServices()
        model.commandBarServices = services
        let url = URL(string: "https://pandas.example/facts")!
        model.visitHistory.recordVisit(url: url, title: "Panda facts", at: Date())
        model.newTab()
        model.commandBarText = "panda"
        model.commandBarAfterCommit.flush()
        services.queries[0].deliver(CommandBarLiveResults(query: "panda", history: [
            VisitRecord(url: url, title: "Panda facts", firstVisit: Date()),
        ]))
        let index = try XCTUnwrap(model.commandBarResults.firstIndex { $0.kind == .history })
        model.commandBarHighlightedIndex = index
        XCTAssertTrue(model.deleteHighlightedCommandBarHistoryRow())
        XCTAssertNil(model.visitHistory.record(for: url), "gone from History.json")
        XCTAssertEqual(services.deleted, [url], "and from the engine's history")
        XCTAssertFalse(model.commandBarResults.contains { $0.kind == .history }, "the row goes at once")
        services.deleteCompletions[0](true)
        model.commandBarAfterCommit.flush()
        XCTAssertEqual(services.queries.last?.text, "panda", "the bar asks again after the deletion")

        model.commandBarHighlightedIndex = 0
        XCTAssertFalse(model.deleteHighlightedCommandBarHistoryRow(), "Shift+Delete on a non-history row does nothing")
    }

    // MARK: Tab unload

    func testUnloadTabDropsAWebKitEngineAndShowingItReloads() throws {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
            b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
            store.selectTab(b.id)
        }
        model.loadSelectedIfNeeded()
        model.selectTab(a.id)
        XCTAssertTrue(model.canUnloadTab(b.id))
        model.unloadTab(b.id)
        XCTAssertNil(model.engineHost.engine(forTabID: b.id, profileID: model.profileID(for: b)), "WebKit unload drops the engine")
        XCTAssertTrue(model.isTabUnloaded(b.id), "the row dims")
        XCTAssertFalse(model.canUnloadTab(b.id))
        model.selectTab(b.id)
        XCTAssertFalse(model.isTabUnloaded(b.id), "showing the tab loads it again")
        XCTAssertEqual(model.engineHost.engine(forTabID: b.id, profileID: model.profileID(for: b))?.currentURL, URL(string: "https://b.test"))

        // Unloading the tab on screen moves the selection first.
        model.unloadTab(b.id)
        XCTAssertNotEqual(model.store.selectedTabID, b.id)
        XCTAssertTrue(model.isTabUnloaded(b.id))
    }

    func testAutomaticUnloadSkipsTheVisibleTabAndHonoursTheThreshold() {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
            b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
            store.selectTab(b.id)
        }
        model.loadSelectedIfNeeded()
        model.selectTab(a.id)
        let now = Date()
        model.tabLastShown[b.id] = now.addingTimeInterval(-5 * 3600)
        model.tabUnloadThreshold = .twelveHours
        XCTAssertEqual(model.runAutoUnload(now: now), [])
        model.tabUnloadThreshold = .fourHours
        XCTAssertEqual(model.runAutoUnload(now: now), [b.id])
        XCTAssertTrue(model.isTabUnloaded(b.id))
        XCTAssertFalse(model.isTabUnloaded(a.id), "the selected tab stays loaded")
        XCTAssertEqual(TabUnloadThreshold.load(from: model.tabUnloadDefaults), .fourHours)
    }

    func testCmdWOnAPinnedTabMarksItUnloaded() {
        var pinned: Tab!
        let model = makeModel { store in
            pinned = store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test/inbox")!)
            store.addTab(kind: .today, title: "T", url: URL(string: "https://t.test")!)
            store.selectTab(pinned.id)
        }
        model.loadSelectedIfNeeded()
        model.closeSelectedTab()
        XCTAssertTrue(model.isTabUnloaded(pinned.id))
    }

    // MARK: HTML fullscreen

    func testPageFullscreenHidesTheChromeOfItsWindowOnly() {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
            b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
            store.selectTab(a.id)
        }
        XCTAssertEqual(model.pageEnteredFullscreen(tabID: a.id, engineTabID: 5, windowIsFullscreen: false),
                       [.hideChrome, .enterNativeFullscreen])
        XCTAssertTrue(model.isHTMLFullscreen(in: nil))
        XCTAssertEqual(model.pageEnteredFullscreen(tabID: a.id, engineTabID: 5, windowIsFullscreen: true), [], "a repeat enter is ignored")
        XCTAssertEqual(model.pageExitedFullscreen(engineTabID: 6), [], "another tab's exit is ignored")
        model.store.selectTab(b.id)
        XCTAssertFalse(model.isHTMLFullscreen(in: nil), "a window showing another tab keeps its chrome")
        model.store.selectTab(a.id)
        XCTAssertEqual(model.pageExitedFullscreen(engineTabID: 5), [.restoreChrome(sidebarVisible: true), .exitNativeFullscreen])
        XCTAssertFalse(model.isHTMLFullscreen(in: nil))

        _ = model.pageEnteredFullscreen(tabID: a.id, engineTabID: 5, windowIsFullscreen: false)
        XCTAssertEqual(model.windowExitedFullscreen(), [.restoreChrome(sidebarVisible: true), .exitPageFullscreen],
                       "leaving native fullscreen ends the page's")
        XCTAssertNil(model.htmlFullscreen)
    }

    // MARK: Dangerous downloads

    func testKeepAndDiscardUseTheEngineWarning() {
        let controller = DownloadsController(fileURL: nil)
        let backend = DangerBackend()
        controller.chromium = backend
        controller.apply(DownloadEvent(kind: .created, guid: "d", url: "https://f.test/x.sh", targetPath: "/tmp/x.sh",
                                       receivedBytes: 10, totalBytes: 100, state: .inProgress, dangerType: 3), source: .chromium)
        let record = controller.records[0]
        XCTAssertTrue(controller.needsDecision(record), "the danger code warns before the engine's answer")
        XCTAssertFalse(controller.canKeep(record), "Keep needs the engine's warning")
        XCTAssertFalse(controller.keep("d"))

        controller.updateWarning(DownloadWarning(dangerType: 3, insecureStatus: 1, isDangerous: true, isInsecure: false), for: "d")
        XCTAssertTrue(controller.canKeep(record))
        XCTAssertEqual(controller.warningText(for: record), "This file is dangerous")
        XCTAssertTrue(controller.hasDangerous)
        XCTAssertTrue(controller.keep("d"))
        XCTAssertEqual(backend.decisions.last?.0, .keep)

        controller.discard("d")
        XCTAssertEqual(backend.decisions.last?.0, .discard, "Discard removes it through the engine")
        XCTAssertTrue(backend.removes.isEmpty)

        controller.apply(DownloadEvent(kind: .completed, guid: "d", url: "https://f.test/x.sh", targetPath: "/tmp/x.sh",
                                       receivedBytes: 100, totalBytes: 100, state: .complete, dangerType: 6), source: .chromium)
        XCTAssertFalse(controller.needsDecision(controller.records[0]))
        XCTAssertNil(controller.warnings["d"], "finished items drop their warning")
    }
}
