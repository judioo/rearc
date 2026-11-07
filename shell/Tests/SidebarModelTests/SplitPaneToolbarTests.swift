import XCTest
@testable import SidebarModel

/// Arc's per-pane split toolbars (SPLIT-VIEW §3.1): which row has the
/// controls, which corners a row touches, the focus rule and the address.
final class SplitPaneToolbarTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testOnlyTheFocusedPaneShowsTheControls() {
        let layout = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: b, orientation: .horizontal)
        XCTAssertEqual(layout.rows.map(\.tabID), [a, b, c], "a row per pane, in pane order")
        XCTAssertEqual(layout.rows.map(\.isActive), [false, true, false])
        XCTAssertEqual(layout.controlsPane, b)

        let moved = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: c, orientation: .horizontal)
        XCTAssertEqual(moved.controlsPane, c, "the controls follow the focus")
        XCTAssertEqual(moved.rows.filter(\.isActive).count, 1)
    }

    func testAnExpandedPaneIsTheOnlyRowAndHasTheControls() {
        let layout = SplitPaneToolbarLayout(visiblePanes: [b], focus: b, orientation: .horizontal)
        XCTAssertEqual(layout.rows, [.init(tabID: b, isActive: true, isAtLeadingCorner: true, isAtTrailingCorner: true)])
        let stale = SplitPaneToolbarLayout(visiblePanes: [a, b], focus: c, orientation: .horizontal)
        XCTAssertEqual(stale.controlsPane, a, "a focus that is not on screen falls back to the first pane")
    }

    func testCornersSideBySideAndStacked() {
        let side = SplitPaneToolbarLayout(visiblePanes: [a, b, c], focus: a, orientation: .horizontal)
        XCTAssertEqual(side.rows.map(\.isAtLeadingCorner), [true, false, false])
        XCTAssertEqual(side.rows.map(\.isAtTrailingCorner), [false, false, true])

        let stacked = SplitPaneToolbarLayout(visiblePanes: [a, b], focus: b, orientation: .vertical)
        XCTAssertEqual(stacked.row(for: a)?.isAtLeadingCorner, true, "the top row spans both corners")
        XCTAssertEqual(stacked.row(for: a)?.isAtTrailingCorner, true)
        XCTAssertEqual(stacked.row(for: b)?.isAtLeadingCorner, false)
        XCTAssertEqual(stacked.row(for: b)?.isAtTrailingCorner, false)
        XCTAssertNil(stacked.row(for: c))
    }

    func testClickingAnotherPaneFocusesItAndTheFocusedPaneChangesNothing() {
        let tabs = [Tab(kind: .today, title: "A", url: URL(string: "https://a.test")!), Tab(kind: .today, title: "B", url: URL(string: "https://b.test")!)]
        let split = SplitViewItem(orientation: .horizontal, focusTabID: tabs[0].id, tabs: tabs)
        XCTAssertEqual(SplitPaneToolbarLayout.focusChange(clicked: tabs[1].id, in: split), tabs[1].id)
        XCTAssertNil(SplitPaneToolbarLayout.focusChange(clicked: tabs[0].id, in: split))
        XCTAssertNil(SplitPaneToolbarLayout.focusChange(clicked: UUID(), in: split), "not a pane of this split")
    }

    func testRowsFollowTheToolbarPreferenceAndFullscreen() {
        XCTAssertTrue(SplitPaneToolbarLayout.showsRows(urlInToolbar: true, pageFullscreen: false))
        XCTAssertFalse(SplitPaneToolbarLayout.showsRows(urlInToolbar: false, pageFullscreen: false), "URL in the sidebar: no rows")
        XCTAssertFalse(SplitPaneToolbarLayout.showsRows(urlInToolbar: true, pageFullscreen: true))
    }

    func testAddressSplitsTheHostFromTheRest() throws {
        let parts = try XCTUnwrap(SplitPaneToolbarLayout.addressParts(URL(string: "https://www.google.com/search?q=test")))
        XCTAssertEqual(parts.host, "google.com")
        XCTAssertEqual(parts.rest, "/search?q=test")
        XCTAssertEqual(SplitPaneToolbarLayout.addressParts(URL(string: "https://chatgpt.com/"))?.rest, "")
        XCTAssertNil(SplitPaneToolbarLayout.addressParts(URL(string: "about:blank")))
        XCTAssertNil(SplitPaneToolbarLayout.addressParts(nil))
    }
}
