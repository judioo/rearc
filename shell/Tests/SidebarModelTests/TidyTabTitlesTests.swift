import XCTest
@testable import SidebarModel

/// Max › Tidy Tab Titles' rules (MAX.md §2) and the automatic marker on a
/// tab's custom title.
final class TidyTabTitlesTests: XCTestCase {
    private func tidy(_ title: String, _ host: String) -> String? {
        TidyTabTitles.tidyTitle(title, host: host)
    }

    func testSiteSuffixesCountersAndAccountsGo() {
        XCTAssertEqual(tidy("Inbox (3) - you@x.com - Gmail", "mail.google.com"), "Gmail Inbox")
        XCTAssertEqual(tidy("(12) Home / X", "x.com"), "X Home")
        XCTAssertEqual(tidy("Pull requests · judioo/rearc · GitHub", "github.com"), "GitHub Pull requests")
        XCTAssertEqual(tidy("judioo/rearc: a browser · GitHub", "github.com"), "judioo/rearc: a browser")
        XCTAssertEqual(tidy("Weekly sync notes – Google Docs", "docs.google.com"), "Weekly sync notes")
        XCTAssertEqual(tidy("Why the sky is blue | The Guardian", "www.theguardian.com"), "Why the sky is blue")
        XCTAssertEqual(tidy("Dashboard | Linear", "linear.app"), "Linear Dashboard")
        XCTAssertEqual(tidy("[4] Messages • Slack", "app.slack.com"), "Slack Messages")
        XCTAssertEqual(tidy("Docs - Nytimes", "www.nytimes.com"), "Docs", "a segment that matches the host's name is the site's")
    }

    func testATitleTheRulesCannotImproveIsLeft() {
        XCTAssertNil(tidy("Gmail", "mail.google.com"))
        XCTAssertNil(tidy("Release notes", "example.com"))
        XCTAssertNil(tidy("", "example.com"))
        XCTAssertNil(tidy("   ", "example.com"))
    }

    func testAllSiteNamesLeaveTheSiteName() {
        XCTAssertEqual(tidy("GitHub - GitHub", "github.com"), "GitHub")
    }

    func testLongTitlesAreCutAtAWord() throws {
        let long = "A very long article title that goes on and on about many things - Example"
        let result = try XCTUnwrap(tidy(long, "example.com"))
        XCTAssertLessThanOrEqual(result.count, TidyTabTitles.maximumLength)
        XCTAssertFalse(result.hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(result))
    }

    func testInvisibleAndBidirectionalCharactersNeverSurvive() throws {
        let hostile = "In\u{202E}box\u{200B} (3)\n - Gmail"
        let result = try XCTUnwrap(tidy(hostile, "mail.google.com"))
        XCTAssertEqual(result, "Gmail Inbox")
        for scalar in result.unicodeScalars {
            XCTAssertFalse(TidyText.invisible.contains(scalar))
        }
    }

    func testAnAddressOrURLSegmentIsDropped() {
        XCTAssertEqual(tidy("Calendar - jane@example.org - https://calendar.google.com/x", "calendar.google.com"), "Google Calendar Calendar")
    }

    func testOnlyAPinnedTabOrFavoriteWithoutATypedTitleIsTidied() {
        let url = URL(string: "https://mail.google.com/")!
        XCTAssertFalse(TidyTabTitles.shouldTidy(Tab(kind: .today, title: "Inbox - Gmail", url: url)))
        XCTAssertTrue(TidyTabTitles.shouldTidy(Tab(kind: .pinned, title: "Inbox - Gmail", url: url)))
        XCTAssertTrue(TidyTabTitles.shouldTidy(Tab(kind: .favorite, title: "Inbox - Gmail", url: url)))
        XCTAssertFalse(TidyTabTitles.shouldTidy(Tab(kind: .pinned, title: "Inbox - Gmail", url: url, customTitle: "Mail")), "typed")
        var automatic = Tab(kind: .pinned, title: "Inbox - Gmail", url: url, customTitle: "Gmail Inbox")
        automatic.customTitleIsAutomatic = true
        XCTAssertTrue(TidyTabTitles.shouldTidy(automatic))
    }

    func testPlaceholderTitlesWaitForThePage() {
        let url = URL(string: "https://www.example.com/path")!
        XCTAssertTrue(TidyTabTitles.isPlaceholder("", url: url))
        XCTAssertTrue(TidyTabTitles.isPlaceholder("New Tab", url: url))
        XCTAssertTrue(TidyTabTitles.isPlaceholder("www.example.com", url: url))
        XCTAssertTrue(TidyTabTitles.isPlaceholder("example.com", url: url))
        XCTAssertTrue(TidyTabTitles.isPlaceholder("https://www.example.com/path", url: url))
        XCTAssertFalse(TidyTabTitles.isPlaceholder("Example Domain", url: url))
    }

    // MARK: The automatic marker

    func testRenameMarksAutomaticAndATypedRenameClearsIt() throws {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let tab = store.addTab(kind: .pinned, title: "Inbox - Gmail", url: URL(string: "https://mail.google.com/")!)
        store.renameTab(tab.id, to: "Gmail Inbox", automatic: true)
        XCTAssertEqual(store.tab(withID: tab.id)?.customTitleIsAutomatic, true)
        store.renameTab(tab.id, to: "Mail")
        XCTAssertEqual(store.tab(withID: tab.id)?.customTitleIsAutomatic, false)
        store.renameTab(tab.id, to: "Gmail Inbox", automatic: true)
        store.renameTab(tab.id, to: nil, automatic: true)
        let reset = try XCTUnwrap(store.tab(withID: tab.id))
        XCTAssertNil(reset.customTitle)
        XCTAssertFalse(reset.customTitleIsAutomatic, "no title, no marker")
    }

    func testTheMarkerIsSavedOnlyWhenSet() throws {
        var tab = Tab(kind: .pinned, title: "Inbox - Gmail", url: URL(string: "https://mail.google.com/")!, customTitle: "Gmail Inbox")
        let typed = String(decoding: try JSONEncoder().encode(tab), as: UTF8.self)
        XCTAssertFalse(typed.contains("customTitleAuto"), "files from before Max stay as they were")
        tab.customTitleIsAutomatic = true
        let data = try JSONEncoder().encode(tab)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"customTitleAuto\":true"))
        XCTAssertTrue(try JSONDecoder().decode(Tab.self, from: data).customTitleIsAutomatic)
        // A marker without a title (a hand edit) means nothing.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["customTitle"] = nil
        let edited = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(Tab.self, from: edited).customTitleIsAutomatic)
    }

    func testTheMarkerSyncsWithTheTitleAndOnlyWhenSet() throws {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let typed = store.addTab(kind: .pinned, title: "Docs", url: URL(string: "https://docs.google.com/a")!)
        let tidied = store.addTab(kind: .pinned, title: "Inbox - Gmail", url: URL(string: "https://mail.google.com/")!)
        store.renameTab(typed.id, to: "Spec")
        store.renameTab(tidied.id, to: "Gmail Inbox", automatic: true)
        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        let typedBody = try XCTUnwrap(records.values.first { $0.values["customTitle"] == .string("Spec") })
        let tidiedBody = try XCTUnwrap(records.values.first { $0.values["customTitle"] == .string("Gmail Inbox") })
        XCTAssertNil(typedBody.values["customTitleAuto"])
        XCTAssertEqual(tidiedBody.values["customTitleAuto"], .bool(true))
    }
}
