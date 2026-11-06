import XCTest
@testable import SidebarModel

final class LittleArcMenusTests: XCTestCase {
    private let profile = UUID()

    private func window(_ title: String, _ url: String) -> LittleArcWindow {
        LittleArcWindow(url: URL(string: url)!, title: title, profileID: profile)
    }

    func testDockListsLittleArcsByTitleThenNewWindows() {
        let news = window("Hacker News", "https://news.ycombinator.com/")
        let blank = window("Little Arc", "about:blank")
        let untitled = window("  ", "https://example.com/page")
        let entries = LittleArcDockMenu.entries(for: [news, blank, untitled], canOpenBrowserWindow: true)
        XCTAssertEqual(entries, [
            .littleArc(id: news.id, title: "Hacker News"),
            .littleArc(id: blank.id, title: "Little Arc"),
            .littleArc(id: untitled.id, title: "example.com"),
            .separator,
            .newLittleArc,
            .newWindow,
        ])
    }

    func testNoLittleArcsMeansNoSeparatorAndNewWindowOnlyWhereSupported() {
        XCTAssertEqual(LittleArcDockMenu.entries(for: [], canOpenBrowserWindow: true), [.newLittleArc, .newWindow])
        XCTAssertEqual(LittleArcDockMenu.entries(for: [], canOpenBrowserWindow: false), [.newLittleArc])
    }
}
