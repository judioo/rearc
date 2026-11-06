import XCTest
@testable import SidebarModel

/// The Library in the sidebar (arc-recordings/2026-11-06-library-in-sidebar.md):
/// Arc's rail, the column's widths and search fields, and the widening.
final class LibrarySidebarTests: XCTestCase {

    func testRailFollowsArcsOrderAndLabels() {
        XCTAssertEqual(LibrarySection.railOrder.map(\.railTitle),
                       ["Media", "Downloads", "Easels", "Spaces", "Boosts", "Archived Tabs"])
        XCTAssertEqual(Set(LibrarySection.railOrder), Set(LibrarySection.allCases), "every page is on the rail")
        XCTAssertEqual(LibrarySection.archive.title, "Archive", "the menus keep their names")
    }

    func testEachColumnHasArcsSearchPromptAndSpacesHasNoColumn() {
        XCTAssertEqual(LibrarySection.media.searchPrompt, "Search Media…")
        XCTAssertEqual(LibrarySection.downloads.searchPrompt, "Search Downloads…")
        XCTAssertEqual(LibrarySection.easels.searchPrompt, "Search Easels…")
        XCTAssertEqual(LibrarySection.boosts.searchPrompt, "Search Boosts…")
        XCTAssertEqual(LibrarySection.archive.searchPrompt, "Search Archive…")
        XCTAssertNil(LibrarySection.spaces.searchPrompt)
        XCTAssertEqual(LibrarySection.allCases.filter(\.coversPage), [.spaces])
    }

    func testTheLibraryWidensTheSidebarToArcsRailAndColumn() {
        XCTAssertEqual(LibrarySidebarLayout.width(for: nil, sidebarWidth: 228), 228)
        XCTAssertEqual(LibrarySidebarLayout.width(for: .media, sidebarWidth: 228), 416, "as measured")
        XCTAssertEqual(LibrarySidebarLayout.width(for: .archive, sidebarWidth: 180), 416)
        XCTAssertEqual(LibrarySidebarLayout.width(for: .boosts, sidebarWidth: 500), 500, "never narrower than the sidebar")
        XCTAssertEqual(LibrarySidebarLayout.width(for: .spaces, sidebarWidth: 228), 111, "Spaces is the rail alone")
    }

    func testTheHomeButtonFirstOpensTheRailsTopPage() {
        XCTAssertEqual(LibraryPresentation().lastSection, .media)
    }

    func testOnlyAWiderSidebarGrowsAndThePageMovesWithIt() {
        XCTAssertNil(LibrarySidebarGrowth.start(from: 416, to: 228), "leaving is a cut")
        XCTAssertNil(LibrarySidebarGrowth.start(from: 416, to: 111), "Spaces is a cut")
        var growth = try! XCTUnwrap(LibrarySidebarGrowth.start(from: 228, to: 416))
        XCTAssertEqual(growth, LibrarySidebarGrowth(from: 228, shown: 228))
        XCTAssertEqual(growth.pageOffset, 0)
        XCTAssertEqual(growth.sidebarOffset(width: 416), -188, "the rail starts beyond the window's edge")

        growth.shown = 322
        XCTAssertEqual(growth.pageOffset, 94, "the page is still laid out beside 228")
        XCTAssertEqual(growth.sidebarOffset(width: 416), -94)

        XCTAssertEqual(LibrarySidebarGrowth.start(from: 111, to: 416, current: growth), growth, "a change mid-way carries on")
        XCTAssertNil(LibrarySidebarGrowth.start(from: 322, to: 111, current: growth))
    }

    func testDownloadsSearchMatchesFileNameOrSite() {
        let records = [
            DownloadRecord(id: "a", source: .chromium, url: "https://files.example.com/a", targetPath: "/tmp/Report Final.pdf", state: .complete,
                           startedAt: Date(timeIntervalSince1970: 0)),
            DownloadRecord(id: "b", source: .chromium, url: "https://cdn.test/b", targetPath: "/tmp/photo.png", state: .complete,
                           startedAt: Date(timeIntervalSince1970: 0)),
        ]
        XCTAssertEqual(LibraryDownloads.matching(records, query: "").map(\.id), ["a", "b"])
        XCTAssertEqual(LibraryDownloads.matching(records, query: " report ").map(\.id), ["a"])
        XCTAssertEqual(LibraryDownloads.matching(records, query: "CDN").map(\.id), ["b"], "by site")
        XCTAssertTrue(LibraryDownloads.matching(records, query: "zip").isEmpty)
    }
}
