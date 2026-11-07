import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Stands in for an engine's find API and records what the bar asked for.
private final class FakeFindEngine: FindInPageEngine {
    var supportsFindInPage = true
    var onFindEvent: ((FindInPageEvent) -> Void)?
    private(set) var starts: [(text: String, matchCase: Bool, session: UInt64)] = []
    private(set) var nexts: [Bool] = []
    private(set) var stops: [FindStopAction] = []
    var nextSucceeds = true
    private var nextSession: UInt64 = 1

    func startFind(_ text: String, matchCase: Bool, forward: Bool) -> UInt64? {
        let session = nextSession
        nextSession += 1
        starts.append((text, matchCase, session))
        return session
    }

    func findNext(forward: Bool) -> Bool {
        nexts.append(forward)
        return nextSucceeds
    }

    func stopFind(_ action: FindStopAction) {
        stops.append(action)
    }

    func deliver(_ session: UInt64, count: Int32, ordinal: Int32, reason: FindInPageEvent.Reason = .result) {
        onFindEvent?(FindInPageEvent(sessionID: session, matchCount: count, activeOrdinal: ordinal, finalUpdate: true, reason: reason))
    }
}

private final class FakeDownloadBackend: DownloadBackend {
    var known: Set<String> = []
    private(set) var actions: [(DownloadAction, String)] = []
    private(set) var directories: [URL] = []

    func perform(_ action: DownloadAction, id: String) -> Bool {
        actions.append((action, id))
        return known.contains(id)
    }

    func directoryChanged(_ directory: URL) {
        directories.append(directory)
    }
}

/// Wave 20: ABI 1.15–1.17 gating, the find bar, the downloads tray model and
/// command-bar visit recording.
final class Wave20ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> (BrowserViewModel, URL) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w20-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        return (model, directory)
    }

    // MARK: Capabilities

    func testABI15To17FeaturesNeedTheirMinorAndFlag() {
        let all: (String) -> Bool = { _ in true }
        let at17 = ChromiumCapabilities(abiMinorVersion: 17, hasFeature: all)
        XCTAssertTrue(at17.browserlessHelpers && at17.findInPage && at17.downloads)
        XCTAssertTrue(at17.summary.contains("find_in_page=1"))
        XCTAssertTrue(at17.summary.contains("downloads=1"))

        let at16 = ChromiumCapabilities(abiMinorVersion: 16, hasFeature: all)
        XCTAssertTrue(at16.findInPage)
        XCTAssertFalse(at16.downloads, "downloads arrived in 1.17")

        let at15 = ChromiumCapabilities(abiMinorVersion: 15, hasFeature: all)
        XCTAssertTrue(at15.browserlessHelpers)
        XCTAssertFalse(at15.findInPage)

        let unadvertised = ChromiumCapabilities(abiMinorVersion: 17) { $0 != "find_in_page" && $0 != "password_autofill" }
        XCTAssertFalse(unadvertised.findInPage)
        XCTAssertFalse(unadvertised.browserlessHelpers, "concern A needs both helper features")
        XCTAssertTrue(unadvertised.downloads)
        XCTAssertFalse(ChromiumCapabilities.none.downloads)
    }

    func testSelfTestKeepsRenderersForegroundAndTheProductDoesNot() {
        let product = ChromiumLaunchArguments.browserArguments(["ReArc"], defaultUserDataDir: { "/tmp/p" }, keychain: .system)
        XCTAssertTrue(Set(product).isDisjoint(with: ChromiumLaunchArguments.selfTestForegroundSwitches))
        let selfTest = ChromiumLaunchArguments.selfTestArguments(product + ["--disable-renderer-backgrounding"])
        XCTAssertEqual(selfTest.filter { $0 == "--disable-renderer-backgrounding" }.count, 1, "no duplicates")
        XCTAssertTrue(selfTest.contains("--disable-backgrounding-occluded-windows"))
        XCTAssertEqual(Array(selfTest.prefix(product.count)), product)
    }

    // MARK: Find bar

    func testFindBarRestartsOnEveryKeystrokeAndShowsTheCurrentSession() {
        let find = FindBarModel()
        let engine = FakeFindEngine()
        find.present(on: engine)
        XCTAssertTrue(find.isPresented)
        find.setQuery("n")
        find.setQuery("ne")
        XCTAssertEqual(engine.starts.map(\.text), ["n", "ne"])
        engine.deliver(1, count: 9, ordinal: 1)
        XCTAssertEqual(find.statusText, "", "the replaced session's result is ignored")
        engine.deliver(2, count: 4, ordinal: 1)
        XCTAssertEqual(find.statusText, "1 of 4")
        find.next(forward: true)
        XCTAssertEqual(engine.nexts, [true])
        engine.deliver(2, count: 4, ordinal: 2)
        XCTAssertEqual(find.statusText, "2 of 4")
        find.setMatchCase(true)
        XCTAssertEqual(engine.starts.last?.matchCase, true)
        find.setQuery("")
        XCTAssertEqual(engine.stops.last, .clearSelection)
        XCTAssertEqual(find.statusText, "")
    }

    func testFindBarSearchesAgainAfterTheSessionEnded() {
        let find = FindBarModel()
        let engine = FakeFindEngine()
        find.present(on: engine)
        find.setQuery("needle")
        engine.deliver(1, count: 2, ordinal: 1)
        engine.deliver(1, count: -1, ordinal: -1, reason: .navigated)
        XCTAssertEqual(find.statusText, "", "a navigation hides the count")
        find.next(forward: true)
        XCTAssertEqual(engine.starts.count, 2, "Return on the new document starts a new session")
        XCTAssertTrue(engine.nexts.isEmpty)
    }

    func testFindBarCloseKeepsSelectionAndReopenRepeatsTheQuery() {
        let find = FindBarModel()
        let first = FakeFindEngine()
        find.present(on: first)
        find.setQuery("needle")
        find.close()
        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(first.stops, [.keepSelection], "Esc keeps the found selection, as in Chrome")
        XCTAssertNil(first.onFindEvent)

        let second = FakeFindEngine()
        find.present(on: second)
        XCTAssertEqual(second.starts.map(\.text), ["needle"], "the last query is searched on the new page")
        XCTAssertEqual(find.query, "needle")
        let other = FakeFindEngine()
        find.present(on: other)
        XCTAssertEqual(second.stops, [.keepSelection], "moving to another page ends the old session")
        XCTAssertNil(second.onFindEvent)
    }

    func testFindBarIgnoresEnginesWithoutFind() {
        let find = FindBarModel()
        let engine = FakeFindEngine()
        engine.supportsFindInPage = false
        find.present(on: engine)
        XCTAssertFalse(find.isPresented)
    }

    func testFindCommandsTargetTheFocusedTabOnWebKit() throws {
        var tab: Tab!
        let (model, _) = makeModel { store in
            tab = store.addTab(kind: .today, title: "A", url: URL(string: "about:blank")!)
            store.selectTab(tab.id)
        }
        model.loadSelectedIfNeeded()
        let engine = try XCTUnwrap(model.focusedEngine)
        XCTAssertTrue(model.findTargetEngine is WKEngine)
        model.showFindBar()
        XCTAssertTrue(model.findBar.isShown(for: engine))
        model.closeFindBar()
        XCTAssertFalse(model.findBar.isPresented)
        model.findNext(forward: true)
        XCTAssertTrue(model.findBar.isShown(for: engine), "Cmd+G opens the bar when it is closed")
    }

    func testWebKitFindSessionCountsAndSteps() {
        let session = WebKitFindSession()
        let (first, replaced) = session.begin("x", matchCase: false)
        XCTAssertNil(replaced)
        session.counted(3, matchFound: true)
        XCTAssertEqual(session.ordinal, 1)
        session.stepped(forward: false, matchFound: true)
        XCTAssertEqual(session.ordinal, 3, "previous from the first match wraps to the last")
        let (_, replacedNow) = session.begin("xy", matchCase: false)
        XCTAssertEqual(replacedNow, first)
        session.counted(0, matchFound: true)
        XCTAssertEqual(session.count, 1, "WebKit found a match innerText missed")
        session.counted(5, matchFound: false)
        XCTAssertEqual(session.count, 0)
        XCTAssertNotNil(session.end())
        XCTAssertNil(session.end())
    }

    // MARK: Downloads

    private func download(_ kind: DownloadEvent.Kind, _ guid: String, state: DownloadState = .inProgress) -> DownloadEvent {
        DownloadEvent(kind: kind, guid: guid, url: "https://files.test/\(guid).zip", targetPath: "/tmp/\(guid).zip",
                      receivedBytes: 10, totalBytes: 100, state: state)
    }

    func testDownloadsControllerRoutesActionsAndPersists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("w20-\(UUID().uuidString)/Downloads.json")
        let controller = DownloadsController(fileURL: file)
        XCTAssertEqual(controller.directory, DownloadsController.defaultDirectory)
        let backend = FakeDownloadBackend()
        controller.chromium = backend
        XCTAssertEqual(backend.directories, [DownloadsController.defaultDirectory], "the engine learns the directory on install")

        controller.apply(download(.created, "a"), source: .chromium)
        XCTAssertFalse(controller.isTrayPresented, "a new download pulses the button; only a click opens the tray")
        XCTAssertEqual(controller.startCount, 1)
        controller.apply(download(.created, "old", state: .complete), source: .chromium)
        XCTAssertEqual(controller.startCount, 1, "restored history does not count as a start")

        backend.known = ["a"]
        controller.perform(.pause, on: "a")
        XCTAssertEqual(backend.actions.last?.0, .pause)
        controller.perform(.remove, on: "a")
        XCTAssertNotNil(controller.list.record(withID: "a"), "Chromium confirms removal with an event")
        controller.apply(download(.removed, "a"), source: .chromium)
        XCTAssertNil(controller.list.record(withID: "a"))
        controller.perform(.remove, on: "old")
        XCTAssertNil(controller.list.record(withID: "old"), "an item the engine no longer knows goes at once")

        controller.apply(download(.created, "b"), source: .chromium)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("w20-dl", isDirectory: true)
        controller.setDirectory(folder)
        XCTAssertEqual(backend.directories.last, folder.standardizedFileURL)
        controller.save()
        let reloaded = DownloadsController(fileURL: file)
        XCTAssertEqual(reloaded.directory.path, folder.standardizedFileURL.path)
        XCTAssertEqual(reloaded.list.record(withID: "b")?.state, .interrupted, "a relaunch interrupts what was transferring")
    }

    func testWebKitDownloadCenterRemovesItemsItNeverSaw() {
        let controller = DownloadsController(fileURL: nil)
        controller.apply(download(.created, "w", state: .complete), source: .webKit)
        controller.perform(.remove, on: "w")
        XCTAssertTrue(controller.records.isEmpty)
        XCTAssertFalse(controller.webKit.perform(.open, id: "w"), "open and reveal fall back to Finder")
    }

    func testWebKitDownloadDecision() throws {
        let url = URL(string: "https://files.test/a.bin")!
        let attachment = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                       headerFields: ["Content-Disposition": "attachment; filename=a.bin"]))
        XCTAssertTrue(WebKitDownloadCenter.shouldDownload(response: attachment, canShowMIMEType: true, isForMainFrame: true))
        let page = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        XCTAssertFalse(WebKitDownloadCenter.shouldDownload(response: page, canShowMIMEType: true, isForMainFrame: true))
        XCTAssertTrue(WebKitDownloadCenter.shouldDownload(response: page, canShowMIMEType: false, isForMainFrame: true))
        XCTAssertFalse(WebKitDownloadCenter.shouldDownload(response: page, canShowMIMEType: false, isForMainFrame: false),
                       "a subframe resource WebKit cannot show is not a download")
    }

    func testModelKeepsDownloadsAndHistoryNextToTheSidebarFile() {
        let (model, directory) = makeModel()
        XCTAssertEqual(model.historyFileURL, directory.appendingPathComponent("History.json"))
        XCTAssertEqual(BrowserViewModel.siblingFile("History.json", of: URL(fileURLWithPath: "/tmp/test-1.json")).lastPathComponent,
                       "test-1-History.json")
        XCTAssertTrue(model.engineHost.downloadCenter === model.downloads.webKit)
    }

    // MARK: Command-bar history

    func testTabCommitsRecordOneVisitPerNavigation() {
        var tab: Tab!
        let (model, directory) = makeModel { store in
            tab = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        }
        let url = URL(string: "https://example.test/page")!
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: nil)
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: "Example Page")
        XCTAssertEqual(model.visitHistory.record(for: url)?.visitCount, 1, "commit and load stop are one visit")
        XCTAssertEqual(model.visitHistory.record(for: url)?.title, "Example Page")
        model.handleTabNavigationCommit(tabID: tab.id, url: URL(string: "https://example.test/other")!, title: "Other")
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: "Example Page")
        XCTAssertEqual(model.visitHistory.record(for: url)?.visitCount, 2)
        model.handleTabNavigationCommit(tabID: tab.id, url: URL(string: "about:blank")!, title: nil)
        XCTAssertEqual(model.visitHistory.count, 2, "about:blank is not history")

        model.commandBarText = "other"
        XCTAssertTrue(model.commandBarResults.contains { $0.kind == .history && $0.title == "Other" })

        model.saveVisitHistory()
        XCTAssertEqual(VisitHistoryFile.load(from: directory.appendingPathComponent("History.json")).count, 2)
        model.clearVisitHistory()
        XCTAssertTrue(model.visitHistory.isEmpty)
    }

    /// Break check 426: a favorite double-clicked as it first loaded offered
    /// "about:blank" as its old name, and a tab archived mid-load kept it.
    /// A new Chromium engine commits an empty about:blank (no title, then
    /// "about:blank" at its load stop), then the tab's page with that title.
    func testANewEnginesBlankDocumentLeavesTheTabsURLAndTitle() {
        var tab: Tab!
        var blankTab: Tab!
        let (model, _) = makeModel { store in
            tab = store.addTab(kind: .pinned, title: "Swift Package Index", url: URL(string: "https://swiftpackageindex.com/")!)
            blankTab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!)
        }
        let url = URL(string: "https://swiftpackageindex.com/")!
        let blank = URL(string: "about:blank")!
        model.handleTabNavigationCommit(tabID: tab.id, url: blank, title: "")
        model.handleTabNavigationCommit(tabID: tab.id, url: blank, title: "about:blank")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.url, url)
        XCTAssertEqual(model.store.tab(withID: tab.id)?.title, "Swift Package Index")
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: "about:blank")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.title, "Swift Package Index")
        XCTAssertNotEqual(model.visitHistory.record(for: url)?.title, "about:blank")
        model.handleTabNavigationCommit(tabID: tab.id, url: url, title: "Swift Package Index – Home")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.title, "Swift Package Index – Home")
        model.handleTabNavigationCommit(tabID: blankTab.id, url: blank, title: "about:blank")
        XCTAssertEqual(model.store.tab(withID: blankTab.id)?.title, "about:blank", "a tab on about:blank keeps that title")
    }

    func testChoosingAHistoryRowNavigatesTheTargetTab() {
        var tab: Tab!
        let (model, _) = makeModel { store in
            tab = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
            store.selectTab(tab.id)
        }
        let url = URL(string: "https://history.test/article")!
        model.recordVisit(tabID: UUID(), url: url, title: "Saved Article")
        model.focusLocation()
        model.commandBarText = "saved art"
        let index = model.commandBarResults.firstIndex { $0.kind == .history }
        XCTAssertNotNil(index)
        model.commandBarHighlightedIndex = index ?? 0
        model.submitCommandBar()
        XCTAssertEqual(model.store.tab(withID: tab.id)?.url, url)
        XCTAssertFalse(model.isCommandBarPresented)
    }
}
