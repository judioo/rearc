import Foundation
import Observation
import os
import Testing
@testable import ReArc
@testable import SidebarModel

@MainActor
struct Perf2PipelineTests {
    @Observable final class Source { var text = "one" }

    static func model() -> BrowserViewModel {
        let fixture = BenchFixture.make(.items500, seed: 1) { URL(string: "https://tabs.test/\($0)")! }
        // No page loads, windows, focus changes or network requests in this benchmark.
        fixture.store.selectTab(fixture.store.addTab(kind: .today, title: "Blank", url: URL(string: "about:blank")!).id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-perf2-\(UUID())")
        let model = BrowserViewModel(store: fixture.store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        let defaults = UserDefaults(suiteName: "rearc-perf2-\(UUID())")!
        let services = WebKitCommandBarServices(defaults: defaults)
        services.preference.suggestionsEnabled = false
        model.commandBarServices = services
        model.visitHistory = Perf2HistoryTests.history()
        model.isCommandBarPresented = true
        return model
    }


    @Test func warmResultReadsReuseRankingAndTrackAllInputs() {
        let model = Self.model()
        model.commandBarText = "design"
        let initial = model.commandBarResults
        let builds = model.commandBarResultCache.buildCount
        let catalogBuilds = model.commandBarCatalogCache.buildCount
        let domainBuilds = model.commandBarDomainCache.buildCount
        for _ in 0..<8 { #expect(model.commandBarResults == initial) }
        model.moveCommandBarHighlight(by: 1)
        #expect(model.commandBarResultCache.buildCount == builds)
        model.commandBarText = "design n"
        _ = model.commandBarResults
        #expect(model.commandBarResultCache.buildCount == builds + 1)
        #expect(model.commandBarDomainCache.buildCount == domainBuilds)
        #expect(model.commandBarCatalogCache.buildCount == catalogBuilds, "typing does not recheck every command's enabled state")

        let page = model.store.addTab(kind: .pinned, title: "Design new tab", url: URL(string: "https://new.test")!)
        #expect(model.commandBarResults.contains { $0.tabID == page.id })
        model.store.updateTab(page.id, title: "Unrelated", url: URL(string: "https://other.test")!)
        #expect(!model.commandBarResults.contains { $0.tabID == page.id })
        model.visitHistory.removeAll()
        #expect(!model.commandBarResults.contains { $0.kind == .history })
        model.commandBarLive = CommandBarLiveResults(query: "design n", suggestions: [
            SearchSuggestion(text: "design new", destinationURL: URL(string: "https://search.test/?q=design-new")!)])
        #expect(model.commandBarResults.contains { $0.title == "design new" })
        model.commandBarText = ">sidebar"
        let beforeToggle = model.commandBarResults
        model.isSidebarVisible.toggle()
        #expect(model.commandBarResults != beforeToggle)
    }

    @Test func warmDerivedCacheNotifiesReadersAndNestedCaches() {
        let source = Source()
        let inner = ObservedCache<String>(), outer = ObservedCache<String>()
        func read() -> String { outer.value { inner.value { source.text } + "!" } }
        #expect(read() == "one!")
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = read() } onChange: { notifications.withLock { $0 += 1 } }
        source.text = "two"
        #expect(notifications.withLock { $0 } == 1)
        #expect(read() == "two!")
        #expect(inner.buildCount == 2 && outer.buildCount == 2)
    }

    @Test func commandTOpensWithoutMutatingSidebarAndCreatesOnlyOnSubmit() {
        let model = Self.model()
        let previous = model.store.selectedTabID
        let before = model.store.makeSnapshot()
        model.newTab()
        #expect(model.isCommandBarPresented)
        #expect(model.commandBarCreatesNewTab)
        #expect(model.store.makeSnapshot() == before)
        #expect(model.store.selectedTabID == previous)
        model.dismissCommandBar()
        #expect(model.store.makeSnapshot() == before)
        model.newTab()
        model.commandBarText = "https://chosen.test/"
        model.submitCommandBar()
        #expect(model.store.selectedTab?.url.host() == "chosen.test")
        #expect(model.store.selectedTabID != previous)
        #expect(!model.isCommandBarPresented)
    }

    @Test func independentSourcesMergeInAnyArrivalOrder() {
        let query = "design"
        let history = Array(Perf2HistoryTests.history().records.values.prefix(10))
        let url = URL(string: "https://search.test/?q=design")!
        let suggestions = [SearchSuggestion(text: "design notes", destinationURL: URL(string: "https://search.test/?q=notes")!)]
        let updates: [CommandBarLiveAccumulator.Update] = [.history(history), .classification(.search(url)), .suggestions(suggestions)]
        let store = SidebarStore()
        let expected = CommandBarLiveResults(query: query, history: history, suggestions: suggestions, classification: .search(url))
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var accumulator = CommandBarLiveAccumulator(query: query)
            for i in order { accumulator.merge(updates[i]) }
            #expect(accumulator.results == expected)
            #expect(CommandBarSearch.results(for: query, in: store, live: accumulator.results)
                    == CommandBarSearch.results(for: query, in: store, live: expected))
            accumulator.merge(.suggestions([]))
            #expect(accumulator.results.history == history)
            #expect(accumulator.results.classification == .search(url))
            #expect(accumulator.results.suggestions.isEmpty)
        }
    }

    @Test func partialSuggestionsFilterOldTextAndTerminalPreservesProviderOrder() {
        func match(_ text: String) -> ChromiumAutocompleteMatch {
            ChromiumAutocompleteMatch(kind: 2, matchType: 0, relevance: 100, allowedToBeDefault: false,
                deletable: false, contents: text, description: "", destinationURL: "https://search.test/?q=\(text.replacingOccurrences(of: " ", with: "+"))", fillIntoEdit: text)
        }
        let rows = [match("react docs"), match("red panda"), match("RED fox"), match("panda red")]
        #expect(ChromiumSearchMapping.suggestions(rows, partialQuery: "red").map(\.text) == ["red panda", "RED fox"])
        #expect(ChromiumSearchMapping.suggestions(rows).map(\.text) == rows.map(\.contents))
        var stream = CommandBarLiveAccumulator(query: "red")
        stream.merge(.suggestions(ChromiumSearchMapping.suggestions(rows, partialQuery: "red")))
        #expect(stream.results.suggestions.count == 2, "partial rows are available before done")
        stream.merge(.suggestions(ChromiumSearchMapping.suggestions(Array(rows.suffix(2)))))
        #expect(stream.results.suggestions.map(\.text) == ["RED fox", "panda red"], "final snapshot replaces partial order")
    }


    /// Opt in with REARC_PERF2_TIMING=1 swift test -c release --filter Perf2PipelineTests.
    /// This measures model work only; it never posts input or opens a window.
    @Test func pipelineTiming() {
        guard ProcessInfo.processInfo.environment["REARC_PERF2_TIMING"] == "1" else { return }
        let model = Self.model()
        let queries = ["d", "de", "des", "desi", "design", "design n", "design notes", "site", "site4", ">tab"]
        var samples: [Double] = []
        var cold = 0.0
        var rowCount = 0
        for iteration in 0..<110 {
            let query = queries[iteration % queries.count]
            let start = DispatchTime.now().uptimeNanoseconds
            model.commandBarText = query
            // Rendering, the inline field and keyboard selection all read these.
            rowCount += model.commandBarResults.count
            _ = model.commandBarInlineSuffix
            rowCount += model.commandBarResults.count
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if iteration == 0 { cold = elapsed }
            if iteration >= 10 { samples.append(elapsed) }
        }
        samples.sort()
        print("PERF2 pipeline 500-item sidebar + 5000 visits n=\(samples.count) p50=\(samples[49])ms p95=\(samples[94])ms max=\(samples.last!)ms cold=\(cold)ms rows=\(rowCount)")
        #expect(rowCount > 0)
    }
}
