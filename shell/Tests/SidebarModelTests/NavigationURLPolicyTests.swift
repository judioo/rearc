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

    func testBrowserPagesAreAdmittedWebUI() {
        for page in BrowserInternalPage.allCases {
            XCTAssertTrue(NavigationURLPolicy.allows(page.url, engine: .chromium), page.rawValue)
            XCTAssertFalse(NavigationURLPolicy.allows(page.url), page.rawValue)
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
            XCTAssertTrue(chromiumActions.contains(.openBrowserPage(page)), page.rawValue)
        }
        if let selected = store.selectedTab, NavigationURLPolicy.viewSourceURL(for: selected.url, engine: .chromium) != nil {
            XCTAssertTrue(chromiumActions.contains(.viewPageSource))
        }
        let results = CommandBarSearch.results(for: ">settings", in: store, navigationSchemes: .chromium)
        XCTAssertEqual(results.first?.commandAction, .openBrowserPage(.settings))
    }
}
