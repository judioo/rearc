import XCTest
@testable import SidebarModel

final class NavigationURLPolicyTests: XCTestCase {
    private func allows(_ string: String, _ engine: NavigationURLPolicy.EngineSchemes = []) -> Bool {
        NavigationURLPolicy.allows(URL(string: string)!, engine: engine)
    }

    func testBaseSetForEveryEngine() {
        for url in ["https://example.com", "http://127.0.0.1:8080/a", "data:text/html,hi", "file:///tmp/a.html", "about:blank"] {
            XCTAssertTrue(allows(url), url)
        }
        for url in ["javascript:alert(1)", "blob:https://example.com/x", "about:srcdoc", "chrome-untrusted://x", "ftp://example.com"] {
            XCTAssertFalse(allows(url), url)
            XCTAssertFalse(allows(url, .chromium), url)
        }
    }

    func testTrustedWebUIOnlyWithChromiumAndAuditedHosts() {
        XCTAssertFalse(allows("chrome://settings"))
        XCTAssertTrue(allows("chrome://settings", .chromium))
        XCTAssertTrue(allows("chrome://settings/privacy", .trustedWebUI))
        XCTAssertTrue(allows("chrome://version", .chromium))
        XCTAssertFalse(allows("chrome://flags", .chromium))
        XCTAssertFalse(allows("chrome://history", .chromium))
    }

    func testDailyWebUIHostsNeedTheirFlag() {
        for host in ["history", "downloads", "password-manager", "extensions"] {
            XCTAssertFalse(allows("chrome://\(host)/", .chromium), host)
            XCTAssertFalse(allows("chrome://\(host)/", .dailyWebUI), "\(host) also needs trustedWebUI")
            XCTAssertTrue(allows("chrome://\(host)/", daily), host)
        }
        XCTAssertTrue(allows("chrome://history/syncedTabs", daily))
        XCTAssertTrue(allows("chrome://password-manager/settings", daily))
        XCTAssertTrue(allows("chrome://extensions/shortcuts", daily))
        // Exact hosts only: flags, bookmarks, lookalikes and view-source of WebUI stay rejected.
        for url in ["chrome://flags", "chrome://bookmarks", "chrome://historyx", "chrome://history.evil",
                    "chrome://restart", "chrome://quit", "view-source:chrome://history"] {
            XCTAssertFalse(allows(url, daily), url)
        }
        XCTAssertEqual(NavigationURLPolicy.webUIHosts(for: daily).count, 6)
        XCTAssertEqual(NavigationURLPolicy.webUIHosts(for: .dailyWebUI), [])
    }

    func testViewSourceWrapsOneHTTPOrFileURL() {
        XCTAssertFalse(allows("view-source:https://example.com"))
        XCTAssertTrue(allows("view-source:https://example.com", .chromium))
        XCTAssertTrue(allows("view-source:file:///tmp/a.html", .viewSource))
        XCTAssertFalse(allows("view-source:view-source:https://example.com", .chromium))
        XCTAssertFalse(allows("view-source:javascript:alert(1)", .chromium))
        XCTAssertFalse(allows("view-source:chrome://settings", .chromium))
    }

    func testViewSourceURL() {
        let page = URL(string: "https://example.com/a?b=1")!
        XCTAssertEqual(NavigationURLPolicy.viewSourceURL(for: page, engine: .chromium)?.absoluteString, "view-source:https://example.com/a?b=1")
        XCTAssertNil(NavigationURLPolicy.viewSourceURL(for: page, engine: []))
        XCTAssertNil(NavigationURLPolicy.viewSourceURL(for: URL(string: "chrome://settings")!, engine: .chromium))
    }

    func testURLEntryUsesEngineSchemes() {
        XCTAssertNil(URLEntry.resolve("chrome://settings"))
        XCTAssertEqual(URLEntry.resolve("chrome://settings", engine: .chromium)?.absoluteString, "chrome://settings")
        XCTAssertEqual(URLEntry.resolve("data:text/html,hi")?.scheme, "data")
        XCTAssertNil(URLEntry.resolve("chrome://flags", engine: .chromium))
    }

    private static let dailyPages: Set<BrowserInternalPage> = [.history, .downloads, .passwords, .extensions]
    private let daily: NavigationURLPolicy.EngineSchemes = NavigationURLPolicy.EngineSchemes.chromium.union(.dailyWebUI)

    func testBrowserPagesAreAdmittedWebUI() {
        for page in BrowserInternalPage.allCases {
            let needsDaily = Self.dailyPages.contains(page)
            XCTAssertEqual(NavigationURLPolicy.allows(page.url, engine: .chromium), !needsDaily, page.rawValue)
            XCTAssertTrue(NavigationURLPolicy.allows(page.url, engine: daily), page.rawValue)
            XCTAssertTrue(page.isAvailable(engine: daily), page.rawValue)
            XCTAssertFalse(NavigationURLPolicy.allows(page.url), page.rawValue)
            XCTAssertFalse(page.isAvailable(engine: []), page.rawValue)
        }
        XCTAssertTrue(BrowserInternalPage.settings.isShown(by: URL(string: "chrome://settings/privacy")!))
        XCTAssertFalse(BrowserInternalPage.settings.isShown(by: URL(string: "chrome://version")!))
    }

    func testSettingsCommandsRequireChromiumWebUI() {
        let store = SidebarStore.sample()
        store.addTab(kind: .today, title: "Example", url: URL(string: "https://example.com")!)
        let webKit = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        let chromium = CommandBarContext(
            store: store,
            isSidebarVisible: true,
            closedTabStack: store.closedTabStack,
            navigationSchemes: .chromium
        )
        let webKitActions = AppCommandRegistry.all(in: webKit).map(\.action)
        let chromiumActions = AppCommandRegistry.all(in: chromium).map(\.action)
        XCTAssertFalse(webKitActions.contains(.openBrowserPage(.settings)))
        XCTAssertFalse(webKitActions.contains(.viewPageSource))
        for page in BrowserInternalPage.allCases {
            XCTAssertEqual(chromiumActions.contains(.openBrowserPage(page)), !Self.dailyPages.contains(page), page.rawValue)
        }
        let dailyContext = CommandBarContext(
            store: store,
            isSidebarVisible: true,
            closedTabStack: store.closedTabStack,
            navigationSchemes: daily
        )
        let dailyActions = AppCommandRegistry.all(in: dailyContext).map(\.action)
        for page in BrowserInternalPage.allCases {
            XCTAssertTrue(dailyActions.contains(.openBrowserPage(page)), page.rawValue)
        }
        XCTAssertEqual(
            CommandBarSearch.results(for: ">downloads", in: store, navigationSchemes: daily).first?.commandAction,
            .openBrowserPage(.downloads)
        )
        if let selected = store.selectedTab, NavigationURLPolicy.viewSourceURL(for: selected.url, engine: .chromium) != nil {
            XCTAssertTrue(chromiumActions.contains(.viewPageSource))
        }
        let results = CommandBarSearch.results(for: ">settings", in: store, navigationSchemes: .chromium)
        XCTAssertEqual(results.first?.commandAction, .openBrowserPage(.settings))
    }
}
