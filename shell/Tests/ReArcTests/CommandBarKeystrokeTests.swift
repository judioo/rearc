import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ReArc
@testable import SidebarModel

/// Where one command-bar keystroke spends its time, without a window on
/// screen or posted input: the model stages, the engine's answers arriving
/// for the same text, and the bar's SwiftUI update in an offscreen window.
@MainActor
struct CommandBarKeystrokeTests {
    static let queries = ["d", "de", "des", "desi", "design", "design n", "design notes", "site", "site4", "git"]

    /// The main menu's size in the app: about 150 runnable items.
    static let menuCommands: [MenuCommand] = (0..<150).map { index in
        let menus = ["File", "Edit", "View", "Spaces", "Tabs", "Archive", "Extensions", "Window", "Help"]
        let menu = menus[index % menus.count]
        return MenuCommand(id: "\(index):\(menu) › Item \(index)", title: "Menu Item \(index) \(menu)",
                           path: "\(menu) › Menu Item \(index) \(menu)", keyEquivalent: index % 3 == 0 ? "⌘\(index % 10)" : "")
    }

    static func model() -> BrowserViewModel {
        let model = Perf2PipelineTests.model()
        model.commandBarMenuSnapshot = menuCommands
        return model
    }

    static func liveHistory(for query: String) -> [VisitRecord] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<Int(ChromiumHistoryLimit.value)).map { index in
            VisitRecord(url: URL(string: "https://engine\(index).test/\(query)/\(index)")!,
                        title: "Engine \(query) page \(index)", visitCount: index % 7 + 1,
                        firstVisit: now.addingTimeInterval(-Double(index) * 900))
        }
    }

    static func ms(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    static func summary(_ name: String, _ samples: [Double]) -> String {
        String(format: "%@ p50=%.2fms p95=%.2fms max=%.2fms", name, percentile(samples, 0.5), percentile(samples, 0.95), samples.max() ?? 0)
    }

    /// Opt in with REARC_KEYSTROKE_TIMING=1 swift test -c release --filter CommandBarKeystrokeTests.
    @Test func keystrokeBreakdown() throws {
        guard ProcessInfo.processInfo.environment["REARC_KEYSTROKE_TIMING"] == "1" else { return }
        let model = Self.model()
        var stages: [String: [Double]] = [:]
        func time(_ name: String, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            stages[name, default: []].append(Self.ms(start))
        }

        // The bar in a borderless window far off screen, never ordered in.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CommandBarContainer(model: model, width: CommandBarOverlay.arcWidth)
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        for iteration in 0..<110 {
            let query = Self.queries[iteration % Self.queries.count]
            let measured = iteration >= 10
            let start = DispatchTime.now().uptimeNanoseconds
            model.commandBarText = query
            let key = Self.ms(start)
            let resultsStart = DispatchTime.now().uptimeNanoseconds
            _ = model.commandBarResults
            let local = Self.ms(resultsStart)
            let renderStart = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded()
            host.display()
            let render = Self.ms(renderStart)
            // The engine's three answers for this text, each a full pass and a render.
            var engine: Double = 0
            for update in [CommandBarLiveResults(query: query, history: Self.liveHistory(for: query)),
                           CommandBarLiveResults(query: query, history: Self.liveHistory(for: query),
                                                 classification: .search(URL(string: "https://duckduckgo.com/?q=\(query.replacingOccurrences(of: " ", with: "+"))")!)),
                           CommandBarLiveResults(query: query, history: Self.liveHistory(for: query),
                                                 suggestions: (0..<5).map { SearchSuggestion(text: "\(query) \($0)", destinationURL: URL(string: "https://duckduckgo.com/?q=s\($0)")!) },
                                                 classification: .search(URL(string: "https://duckduckgo.com/?q=\(query.replacingOccurrences(of: " ", with: "+"))")!))] {
                let engineStart = DispatchTime.now().uptimeNanoseconds
                model.commandBarLive = update
                _ = model.commandBarResults
                host.layoutSubtreeIfNeeded()
                host.display()
                engine += Self.ms(engineStart)
            }
            guard measured else { continue }
            stages["1 key: text set (live query start)", default: []].append(key)
            stages["2 key: local results", default: []].append(local)
            stages["3 key: SwiftUI update + draw", default: []].append(render)
            stages["4 key total (1+2+3)", default: []].append(key + local + render)
            stages["5 engine: 3 answers, results + render", default: []].append(engine)

            // The model stages on their own, for the same text, on the prepared indexes.
            let needle = CommandBarSearch.parseMode(query).needle
            let tabIndex = model.commandBarTabIndex
            let commandIndex = model.commandBarCommandIndex
            let menuIndex = model.commandBarMenuIndex(registered: commandIndex.catalog)
            let history = model.visitHistory
            time("s tabs") { _ = tabIndex.results(for: needle) }
            time("s history (shell, 5000)") { _ = history.searchIndex.matches(for: needle, now: Date(), limit: 5) }
            time("s commands") {
                _ = CommandBarSearch.results(for: ">" + needle, in: model.store, commandIndex: commandIndex,
                                             menuIndex: MenuCommandSearch.Index([], registered: []))
            }
            time("s menus") { _ = menuIndex.matches(query: needle) }
            time("s engine history (50) store") { _ = VisitHistory(records: Self.liveHistory(for: query)) }
            time("s inline completion") {
                let candidates = model.commandBarDomainCache.value { InlineDomainCompletion.candidates(history: history) }
                _ = InlineDomainCompletion.complete(query, candidates: candidates)
            }
        }
        for query in Self.queries {
            model.commandBarText = query
            let rows = model.commandBarResults
            print("KEYSTROKE rows '\(query)': \(rows.count) (" + Dictionary(grouping: rows, by: { "\($0.kind)" }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ") + ")")
        }
        for name in stages.keys.sorted() {
            print("KEYSTROKE " + Self.summary(name, stages[name]!))
        }
        print("KEYSTROKE rows=\(model.commandBarResults.count) visits=\(model.visitHistory.count) catalog=\(model.commandBarCommandIndex.catalog.count) tabs=\(model.commandBarTabIndex.count)")
    }
}

/// `ChromiumCommandBarServices.historyLimit`, which only exists in Chromium builds.
enum ChromiumHistoryLimit {
    static let value: UInt32 = 50
}

/// The bar's own SwiftUI cost with fixed rows: what a text change, changed
/// rows and rows with new result IDs cost (REARC_ROWS sets the row count).
@MainActor
struct CommandBarRowRenderTiming {
    final class Box: ObservableObject {
        @Published var text = ""
        @Published var results: [CommandBarSearch.Result] = []
    }
    struct Host: View {
        @ObservedObject var box: Box
        var body: some View {
            CommandBarOverlay(text: $box.text, results: box.results, highlightedIndex: 0, onMoveHighlight: { _ in },
                              onSelectResult: { _ in }, onSubmit: {}, onCancel: {})
                .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false))
        }
    }

    /// Opt in with REARC_KEYSTROKE_TIMING=1 swift test -c release --filter CommandBarRowRenderTiming.
    @Test func renderSplit() {
        guard ProcessInfo.processInfo.environment["REARC_KEYSTROKE_TIMING"] == "1" else { return }
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Host(box: box))
        window.contentView = host
        defer { window.close() }
        let rows: (String) -> [CommandBarSearch.Result] = { q in
            (0..<(Int(ProcessInfo.processInfo.environment["REARC_ROWS"] ?? "") ?? 12)).map {
                CommandBarSearch.Result(id: "r\($0)", kind: .history, title: "\(q) row \($0)", subtitle: "site\($0).test")
            }
        }
        var textOnly: [Double] = [], rowsChanged: [Double] = [], rowsSame: [Double] = [], empty: [Double] = [], newIDs: [Double] = []
        for i in 0..<60 {
            box.results = []
            host.layoutSubtreeIfNeeded(); host.display()
            var start = DispatchTime.now().uptimeNanoseconds
            box.text = "q\(i)"
            host.layoutSubtreeIfNeeded(); host.display()
            empty.append(CommandBarKeystrokeTests.ms(start))
            box.results = rows("a\(i)")
            host.layoutSubtreeIfNeeded(); host.display()
            start = DispatchTime.now().uptimeNanoseconds
            box.text = "t\(i)"
            host.layoutSubtreeIfNeeded(); host.display()
            textOnly.append(CommandBarKeystrokeTests.ms(start))
            start = DispatchTime.now().uptimeNanoseconds
            box.results = rows("b\(i)")
            host.layoutSubtreeIfNeeded(); host.display()
            rowsChanged.append(CommandBarKeystrokeTests.ms(start))
            start = DispatchTime.now().uptimeNanoseconds
            box.results = rows("b\(i)")
            host.layoutSubtreeIfNeeded(); host.display()
            rowsSame.append(CommandBarKeystrokeTests.ms(start))
            start = DispatchTime.now().uptimeNanoseconds
            box.results = rows("b\(i)").map { var r = $0; r.id += "-\(i)"; return r }
            host.layoutSubtreeIfNeeded(); host.display()
            newIDs.append(CommandBarKeystrokeTests.ms(start))
        }
        print("RENDER " + CommandBarKeystrokeTests.summary("rows, new result ids", newIDs))
        print("RENDER " + CommandBarKeystrokeTests.summary("text, no rows", empty))
        print("RENDER " + CommandBarKeystrokeTests.summary("text, rows unchanged", textOnly))
        print("RENDER " + CommandBarKeystrokeTests.summary("rows all changed", rowsChanged))
        print("RENDER " + CommandBarKeystrokeTests.summary("rows, equal array", rowsSame))
    }
}

/// The model's prepared indexes and memos give the results the unprepared
/// search gives, through typing, sidebar changes and engine answers.
@MainActor
struct CommandBarPreparedModelTests {
    static func unprepared(_ model: BrowserViewModel) -> [CommandBarSearch.Result] {
        if model.commandBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return CommandBarSearch.results(
            for: model.commandBarText, in: model.store, isSidebarVisible: model.isSidebarVisible,
            history: model.visitHistory,
            commandCatalog: AppCommandRegistry.all(in: CommandBarContext(
                store: model.store, isSidebarVisible: model.isSidebarVisible, closedTabStack: model.store.closedTabStack,
                peekURL: nil, focusedLittleArcID: nil, mediaByTab: [:], tabMuteModel: model.tabMuteModel,
                navigationSchemes: model.engineHost.navigationSchemes, externalLinkDestination: model.externalLinkDestination)),
            menuCommands: model.commandBarMenuCommands, externalLinkDestination: model.externalLinkDestination,
            live: model.commandBarLive, searchProvider: model.searchProvider, inlineCompletion: model.commandBarInlineCompletion)
    }

    @Test func typingSidebarChangesAndEngineAnswersMatchTheUnpreparedSearch() {
        let model = CommandBarKeystrokeTests.model()
        model.newTab()
        model.commandBarAfterCommit.flush()
        for text in ["d", "de", "des", "design", "design n", "site4", ">tab", ">sid", "git"] {
            model.commandBarText = text
            #expect(model.commandBarResults == Self.unprepared(model), "'\(text)'")
        }
        model.commandBarText = "zebra"
        #expect(!model.commandBarResults.contains { $0.kind == .openTab })
        let tab = model.store.addTab(kind: .today, title: "Zebra crossing", url: URL(string: "https://zebra.test/")!)
        #expect(model.commandBarResults.first { $0.kind == .openTab }?.tabID == tab.id, "a new tab rebuilds the tab index")
        model.store.updateTab(tab.id, title: "Unrelated", url: URL(string: "https://other.test/")!)
        #expect(!model.commandBarResults.contains { $0.tabID == tab.id })
        #expect(model.commandBarResults == Self.unprepared(model))

        model.commandBarText = ">sidebar"
        let before = model.commandBarResults
        model.isSidebarVisible.toggle()
        #expect(model.commandBarResults != before, "the catalog and the menu index follow the sidebar")
        #expect(model.commandBarResults == Self.unprepared(model))

        model.commandBarText = "design"
        let engine = CommandBarKeystrokeTests.liveHistory(for: "design")
        model.commandBarLive = CommandBarLiveResults(query: "design", history: engine)
        #expect(model.commandBarResults == Self.unprepared(model))
        let memo = model.commandBarLiveHistoryMemo?.history
        model.commandBarLive = CommandBarLiveResults(query: "design", history: engine,
                                                     classification: .search(URL(string: "https://duckduckgo.com/?q=design")!))
        #expect(model.commandBarResults == Self.unprepared(model))
        #expect(model.commandBarLiveHistoryMemo?.history == memo, "another source's answer reuses the prepared engine history")
        model.commandBarLive = CommandBarLiveResults(query: "design", history: Array(engine.prefix(3)))
        #expect(model.commandBarResults == Self.unprepared(model))
        #expect(model.commandBarResults.filter { $0.kind == .history }.count == 3)
    }

    @Test func menuIndexFollowsTheSnapshotAndTheCatalog() {
        let model = CommandBarKeystrokeTests.model()
        let catalog = model.commandBarCommandIndex.catalog
        let first = model.commandBarMenuIndex(registered: catalog)
        #expect(model.commandBarMenuIndex(registered: catalog).commands == first.commands)
        let registered = catalog + [AppCommand(id: "x", title: CommandBarKeystrokeTests.menuCommands[0].title, action: .newTab)]
        let hidden = CommandBarKeystrokeTests.menuCommands[0].id
        #expect(model.commandBarMenuIndex(registered: catalog).matches(query: "menu item 0 file").contains { $0.id == hidden })
        #expect(!model.commandBarMenuIndex(registered: registered).matches(query: "menu item 0 file").contains { $0.id == hidden },
                "a command's own row hides its menu item")
        model.commandBarMenuSnapshot = Array(CommandBarKeystrokeTests.menuCommands.prefix(3))
        #expect(model.commandBarMenuIndex(registered: catalog).commands.count == 3)
    }

    @Test func afterCommitRunsOnceTheRunLoopWaitsInOrder() {
        let afterCommit = AfterCommit()
        afterCommit.fallbackDelay = 10
        var ran: [Int] = []
        afterCommit.schedule { ran.append(1) }
        afterCommit.schedule { ran.append(2) }
        #expect(ran.isEmpty, "nothing runs before the run loop turns")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(ran == [1, 2])
        afterCommit.schedule { ran.append(3) }
        afterCommit.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(ran == [1, 2])
        afterCommit.fallbackDelay = 0.01
        afterCommit.schedule { ran.append(4) }
        afterCommit.flush()
        afterCommit.flush()
        #expect(ran == [1, 2, 4], "flushed work runs once")
    }

    @Test func closingTheBarDropsAWaitingQuery() {
        let model = CommandBarKeystrokeTests.model()
        model.newTab()
        model.commandBarText = "pending"
        #expect(model.pendingCommandBarQuery?.text == "pending")
        model.dismissCommandBar()
        #expect(model.pendingCommandBarQuery == nil)
        model.commandBarAfterCommit.flush()
        #expect(model.commandBarLive == nil)
    }
}
