import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Counts the model's engine lookups; answers none unless asked.
private final class CountingCommandBarServices: CommandBarServices {
    var provider = SearchProvider.google
    var queries: [(text: String, deliver: (CommandBarLiveResults) -> Void)] = []
    var historyRequests: [String] = []
    var historyAnswer: [VisitRecord] = []
    var onSearchProviderChange: (() -> Void)?

    func searchProvider(for profileID: Profile.ID) -> SearchProvider { provider }
    func commandBarWillOpen(profileID: Profile.ID) {}
    func query(_ text: String, profileID: Profile.ID, isPrivate: Bool, deliver: @escaping (CommandBarLiveResults) -> Void) {
        queries.append((text, deliver))
    }
    func cancel() {}
    func deleteFromHistory(_ url: URL, profileID: Profile.ID, completion: @escaping (Bool) -> Void) -> Bool { false }
    func siteSearchHistory(host: String, profileID: Profile.ID, completion: @escaping ([VisitRecord]) -> Void) {
        historyRequests.append(host)
        completion(historyAnswer)
    }
}

/// Site search in the command bar, shell side (COMMAND-BAR §4.2, §10): the
/// owner's "cwc" › cushwake shortcut from Arc, ChatGPT, the collapse to the
/// field, earlier queries and where Return goes.
@MainActor
final class CommandBarSiteSearchShellTests: XCTestCase {
    private let cwc = ChromiumKeywordsReader.Row(name: "cushwake", keyword: "cwc",
                                                 template: "https://www.cushmanwakefield.ae/search?q={searchTerms}")

    private func makeModel() -> (BrowserViewModel, CountingCommandBarServices) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-sitesearch-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        let services = CountingCommandBarServices()
        model.commandBarServices = services
        model.commandBarCollapseHold = 0
        return (model, services)
    }

    private func visit(_ model: BrowserViewModel, _ query: String, times: Int = 1, daysAgo: Double = 1, profile: Profile.ID? = nil) {
        let page = URL(string: "https://www.cushmanwakefield.ae/search?q=\(query)")!
        for _ in 0 ..< times {
            model.visitHistory.recordVisit(url: page, title: query, at: Date().addingTimeInterval(-daysAgo * 86_400),
                                           profileID: profile ?? model.store.activeProfileID)
        }
    }

    func testTheImportedKeywordOffersItsSiteAndTabCollapsesToTheField() throws {
        let (model, services) = makeModel()
        XCTAssertEqual(model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID), 1)
        model.newTab()
        model.commandBarText = "cwc"
        let hint = try XCTUnwrap(model.commandBarSiteSearchSuggestion)
        XCTAssertEqual(hint.hint, "Search cushwake", "the entry's own name, never a page's")
        XCTAssertFalse(model.commandBarResults.isEmpty)

        XCTAssertTrue(model.enterCommandBarSiteSearch())
        XCTAssertEqual(model.commandBarSiteSearch?.name, "cushwake")
        XCTAssertEqual(model.commandBarSiteSearch?.placeholder, "Search…")
        XCTAssertEqual(model.commandBarText, "")
        XCTAssertTrue(model.isCommandBarCollapsed, "the options are gone; only the field is left")
        XCTAssertEqual(model.commandBarCollapseCount, 1, "the collapse plays once")
        XCTAssertNil(model.commandBarSiteSearchSuggestion, "no second hint inside the chip")
        XCTAssertEqual(services.historyRequests, ["cushmanwakefield.ae"], "the engine's history at the site is read, nothing else")
        XCTAssertTrue(services.queries.isEmpty, "a site that is not the default engine is never asked anything")

        model.commandBarText = "L-1"
        XCTAssertTrue(services.queries.isEmpty, "typing in the chip sends nothing")
        XCTAssertTrue(model.exitCommandBarSiteSearch() == false, "Delete edits the query while it has text")
        model.commandBarText = ""
        XCTAssertTrue(model.exitCommandBarSiteSearch(), "Delete on an empty field leaves the mode")
        XCTAssertNil(model.commandBarSiteSearch)
        XCTAssertEqual(model.commandBarText, "cwc", "the typed text comes back")
    }

    func testTheRecolouredRowsHoldABeatThenGo() {
        let (model, _) = makeModel()
        model.commandBarCollapseHold = 60
        model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID)
        model.newTab()
        model.commandBarText = "cwc"
        let before = model.commandBarResults
        XCTAssertTrue(model.enterCommandBarSiteSearch())
        XCTAssertEqual(model.commandBarResults, before, "the old rows stay, now in the site's colour")
        XCTAssertFalse(model.isCommandBarCollapsed)
        model.collapseCommandBarSiteSearchRows()
        XCTAssertTrue(model.isCommandBarCollapsed)
        XCTAssertEqual(model.commandBarCollapseCount, 1)

        model.commandBarText = ""
        model.exitCommandBarSiteSearch()
        model.commandBarText = "cwc"
        model.enterCommandBarSiteSearch()
        model.commandBarText = "L"
        XCTAssertNil(model.commandBarSiteSearchHeldRows, "typing ends the beat")
        XCTAssertNotEqual(model.commandBarResults, before)
    }

    func testEarlierQueriesCompleteAndReturnOpensTheTemplate() throws {
        let (model, _) = makeModel()
        model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID)
        visit(model, "L-144", daysAgo: 40)
        visit(model, "L-144681", times: 2, daysAgo: 3)
        visit(model, "L-144373", times: 3, daysAgo: 1)
        model.newTab()
        model.commandBarText = "cwc"
        model.enterCommandBarSiteSearch()
        model.commandBarText = "L"
        XCTAssertEqual(model.commandBarResults.map(\.title), ["L-144373", "L-144681", "L-144"], "only this shortcut's queries, best first")
        XCTAssertEqual(model.commandBarInlineSuffix, "-144373", "the best one completes inline")
        XCTAssertTrue(model.commandBarResults.allSatisfy { $0.siteSearchID == model.commandBarSiteSearch?.id })

        model.commandBarText = "L-14"
        model.commandBarText = "L-1"
        XCTAssertNil(model.commandBarInlineSuffix, "a deletion turns completion off until the next character")
        XCTAssertEqual(model.commandBarResults.first?.title, "L-1")

        model.commandBarText = "L-144 x"
        let previous = model.store.selectedTabID
        model.submitCommandBar()
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNotEqual(model.store.selectedTabID, previous, "where a ⌘T search opens: a new tab")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://www.cushmanwakefield.ae/search?q=L-144+x")
    }

    func testEarlierQueriesStayInTheirContainerAndGoWithHistory() {
        let (model, services) = makeModel()
        model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID)
        visit(model, "elsewhere", profile: UUID())
        visit(model, "here")
        services.historyAnswer = [VisitRecord(url: URL(string: "https://cushmanwakefield.ae/search?q=engine+side")!, title: "",
                                              firstVisit: Date().addingTimeInterval(-3600))]
        model.newTab()
        model.commandBarText = "cwc"
        model.enterCommandBarSiteSearch()
        let texts = model.commandBarSiteSearchQueries.map(\.text)
        XCTAssertEqual(Set(texts), ["here", "engine side"], "the shell's own (this container) and the engine's history")
        XCTAssertFalse(texts.contains("elsewhere"), "another container's queries never show")
        let before = model.visitHistory
        model.commandBarText = "h"
        XCTAssertEqual(model.visitHistory, before, "the mode writes nothing of its own")

        model.dismissCommandBar()
        model.clearVisitHistory()
        services.historyAnswer = []
        model.newTab()
        model.commandBarText = "cwc"
        model.enterCommandBarSiteSearch()
        XCTAssertTrue(model.commandBarSiteSearchQueries.isEmpty, "clearing history clears them")
    }

    /// Assistants come from Settings › Max (`CommandBarAssistants`), off until switched on.
    private func switchOnAssistants(_ ids: [String], in model: BrowserViewModel) {
        model.externalLinkDefaults = UserDefaults(suiteName: "CommandBarSiteSearchShellTests.\(UUID().uuidString)")!
        model.maxPreferences = MaxPreferences(enabled: [.assistants])
        for id in ids { model.setAssistant(id, enabled: true) }
    }

    func testChatGPTIsOfferedOnlyOnceSwitchedOnInMax() throws {
        let (model, _) = makeModel()
        model.externalLinkDefaults = UserDefaults(suiteName: "CommandBarSiteSearchShellTests.\(UUID().uuidString)")!
        model.maxPreferences = MaxPreferences()
        model.newTab()
        model.commandBarText = "chatgpt"
        XCTAssertNil(model.commandBarSiteSearchSuggestion, "nothing seeded: someone updating from 677 had no assistant")
        model.setAssistant("chatgpt", enabled: true)
        XCTAssertNil(model.commandBarSiteSearchSuggestion, "the assistants row itself is still off")
        model.setMaxFeature(.assistants, on: true)
        XCTAssertEqual(model.commandBarSiteSearchSuggestion?.hint, "Ask ChatGPT")
        model.setAssistant("chatgpt", enabled: false)
        XCTAssertNil(model.commandBarSiteSearchSuggestion)
    }

    func testAnAssistantWithoutAPromptAddressOpensItsPageAndCopiesTheText() throws {
        let (model, _) = makeModel()
        switchOnAssistants(["deepseek"], in: model)
        model.newTab()
        model.commandBarText = "deepseek"
        XCTAssertTrue(model.enterCommandBarSiteSearch())
        model.commandBarText = "summarise this"
        XCTAssertTrue(model.commandBarResults.isEmpty, "no address carries the text, so no row pretends to")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        model.submitCommandBar()
        XCTAssertEqual(pasteboard.string(forType: .string), "summarise this")
        XCTAssertEqual(model.store.selectedTab?.url.absoluteString, "https://chat.deepseek.com/")
        XCTAssertEqual(model.toast?.message, "Copied: press ⌘V in DeepSeek")
    }

    func testChatCompletesToChatGPTWhichOffersAsk() throws {
        let (model, services) = makeModel()
        switchOnAssistants(["chatgpt"], in: model)
        model.newTab()
        model.commandBarText = "chat"
        XCTAssertEqual(model.commandBarInlineCompletion, "chatgpt.com")
        let hint = try XCTUnwrap(model.commandBarSiteSearchSuggestion)
        XCTAssertEqual(hint.hint, "Ask ChatGPT")
        model.enterCommandBarSiteSearch()
        XCTAssertEqual(model.commandBarSiteSearch?.placeholder, "Send a Message…")
        let fill = model.commandBarSiteFill(hint, accentFill: .white, dark: false)
        XCTAssertGreaterThanOrEqual(CommandBarInk.selectedText.contrast(with: fill), 4.5)
        model.commandBarText = "what is arc"
        XCTAssertTrue(services.queries.allSatisfy { $0.text == "chat" }, "nothing typed in the chip is sent")
        XCTAssertEqual(model.commandBarResults.first?.destinationURL?.absoluteString, "https://chatgpt.com/?q=what+is+arc")
    }

    func testTheDefaultEnginesChipKeepsItsOwnSuggestions() throws {
        let (model, services) = makeModel()
        model.newTab()
        model.commandBarText = "google.com"
        let google = try XCTUnwrap(model.commandBarSiteSearchSuggestion)
        XCTAssertNotNil(google.suggestTemplate, "the default engine has its suggest URL")
        model.enterCommandBarSiteSearch()
        let asked = services.queries.count
        model.commandBarText = "swift"
        model.commandBarAfterCommit.flush()
        XCTAssertEqual(services.queries.count, asked + 1, "the same lookup the plain bar makes for this text")
        services.queries.last?.deliver(CommandBarLiveResults(query: "swift", suggestions: [
            SearchSuggestion(text: "swift testing", destinationURL: URL(string: "https://www.google.com/search?q=swift+testing")!),
        ]))
        XCTAssertEqual(model.commandBarResults.map(\.title), ["swift", "swift testing"])
    }

    func testEscapeClosesAndAnEmptyNewTabListsRecentTabs() {
        let (model, _) = makeModel()
        let a = model.store.addTab(kind: .today, title: "Alpha", url: URL(string: "https://alpha.test/")!)
        model.store.addTab(kind: .today, title: "Beta", url: URL(string: "https://beta.test/")!)
        model.store.selectTab(a.id)
        model.newTab()
        XCTAssertTrue(model.commandBarResults.contains { $0.title == "Beta" }, "Arc's ⌘T lists recent tabs")
        XCTAssertFalse(model.commandBarResults.contains { $0.tabID == a.id }, "not the one on screen")
        model.importSiteSearches([cwc], from: "arc/Default", into: model.store.activeProfileID)
        model.commandBarText = "cwc"
        model.enterCommandBarSiteSearch()
        model.dismissCommandBar()
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarSiteSearch)
        XCTAssertTrue(model.commandBarSiteSearchQueries.isEmpty)
    }

    func testTypingKeepsEarlierRowsWhileTheNextAnswerIsPending() {
        let (model, services) = makeModel()
        model.newTab()
        model.commandBarText = "pan"
        model.commandBarAfterCommit.flush()
        let page = VisitRecord(url: URL(string: "https://pandas.test/")!, title: "Pandas", firstVisit: Date())
        services.queries.last?.deliver(CommandBarLiveResults(query: "pan", history: [page]))
        XCTAssertTrue(model.commandBarResults.contains { $0.title == "Pandas" })
        model.commandBarText = "pand"
        XCTAssertNil(model.commandBarLive)
        XCTAssertTrue(model.commandBarResults.contains { $0.title == "Pandas" }, "the row stays instead of flickering away")
        model.commandBarText = "panx"
        XCTAssertFalse(model.commandBarResults.contains { $0.title == "Pandas" }, "a row the text no longer matches goes")
    }
}
