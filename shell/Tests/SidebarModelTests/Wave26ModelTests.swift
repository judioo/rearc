import XCTest
@testable import SidebarModel

/// Wave 26: Pinned section collapse, Copy URL formats, the unread policy and
/// tab activity.
final class Wave26ModelTests: XCTestCase {

    // MARK: Pinned section

    func testPinnedCollapseIsPerWindowAndSpace() {
        let space = UUID(), other = UUID()
        let windowA = SidebarWindowID(), windowB = SidebarWindowID()
        var state = PinnedSectionCollapseState()
        state.toggle(spaceID: space, window: windowA)
        XCTAssertTrue(state.isCollapsed(spaceID: space, window: windowA))
        XCTAssertFalse(state.isCollapsed(spaceID: space, window: windowB), "another window keeps its own flag")
        XCTAssertFalse(state.isCollapsed(spaceID: other, window: windowA), "another space keeps its own flag")
        state.setCollapsed(true, spaceID: other, window: windowB)
        state.forgetWindow(windowA)
        XCTAssertFalse(state.isCollapsed(spaceID: space, window: windowA))
        XCTAssertTrue(state.isCollapsed(spaceID: other, window: windowB))
        state.toggle(spaceID: other, window: windowB)
        XCTAssertTrue(state.collapsed.isEmpty)
    }

    func testCollapsedPinnedSectionKeepsOnlyTheSelectedItem() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let a = store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .pinned, title: "B", url: URL(string: "https://b.test")!)
        let folder = store.createFolder(title: "F", containing: [b.id])!
        let pinned = store.content(for: store.activeSpaceID).pinned
        XCTAssertEqual(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: false, selectedID: a.id).map(\.id),
                       [a.id, folder.id], "expanded shows everything")
        XCTAssertEqual(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: true, selectedID: a.id).map(\.id), [a.id])
        XCTAssertEqual(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: true, selectedID: b.id).map(\.id),
                       [b.id], "a selected tab comes out of its folder")
        XCTAssertTrue(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: true, selectedID: nil).isEmpty)
        XCTAssertTrue(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: true, selectedID: folder.id).isEmpty,
                      "a folder is not a leaf")
        XCTAssertTrue(PinnedSectionCollapseState.visibleEntries(pinned, isCollapsed: true, selectedID: UUID()).isEmpty,
                      "a Today selection shows no pinned row")
    }

    // MARK: Copy URL formats

    func testCopyFormats() {
        let url = URL(string: "https://en.wikipedia.org/wiki/Arc_(browser)")!
        XCTAssertEqual(PageLinkCopyFormat.plain.text(url: url, title: "Arc"), url.absoluteString)
        XCTAssertEqual(PageLinkCopyFormat.markdown.text(url: url, title: "Arc [browser]"),
                       "[Arc \\[browser\\]](https://en.wikipedia.org/wiki/Arc_%28browser%29)")
        XCTAssertEqual(PageLinkCopyFormat.markdown.text(url: URL(string: "https://example.com/")!, title: "  "),
                       "[example.com](https://example.com/)", "an empty title uses the host")
        XCTAssertEqual(PageLinkCopyFormat.quote.text(url: URL(string: "https://a.test/")!, title: "A", selection: "  first line\n\nsecond  "),
                       "> first line\n>\n> second\n>\n> — [A](https://a.test/)")
        XCTAssertEqual(PageLinkCopyFormat.quote.text(url: URL(string: "https://a.test/")!, title: "A", selection: " \n "),
                       "> [A](https://a.test/)", "no selection quotes the link")
        XCTAssertEqual(Set(PageLinkCopyFormat.allCases.map(\.confirmation)).count, 3)
    }

    // MARK: Unread

    func testUnreadNeedsABackgroundPinnedTitleChangeAfterTheLoadSettles() {
        func mark(
            kind: Tab.Kind = .pinned, visible: Bool = false, loading: Bool = false,
            since: TimeInterval? = 60, old: String? = "Inbox", new: String? = "(1) Inbox"
        ) -> Bool {
            UnreadActivityPolicy.shouldMarkUnread(
                kind: kind, isVisible: visible, isLoading: loading,
                secondsSinceNavigation: since, previousTitle: old, newTitle: new
            )
        }
        XCTAssertTrue(mark())
        XCTAssertTrue(mark(kind: .favorite))
        XCTAssertTrue(mark(since: nil))
        XCTAssertFalse(mark(kind: .today), "Today tabs show no unread dot")
        XCTAssertFalse(mark(visible: true), "a tab on screen is seen")
        XCTAssertFalse(mark(loading: true), "titles set while loading are the page settling")
        XCTAssertFalse(mark(since: 1), "nor right after a navigation")
        XCTAssertFalse(mark(old: nil), "the first title is not activity")
        XCTAssertFalse(mark(new: " "))
        XCTAssertFalse(mark(new: " Inbox "), "the same title is no change")
    }

    func testSelectingAnUnreadTabClearsIt() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let a = store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .pinned, title: "B", url: URL(string: "https://b.test")!)
        store.selectTab(a.id)
        store.setUnread(true, for: b.id)
        XCTAssertEqual(store.tab(withID: b.id)?.isUnread, true)
        store.selectTab(b.id)
        XCTAssertEqual(store.tab(withID: b.id)?.isUnread, false)
    }

    // MARK: Tab activity

    func testTabActivity() {
        XCTAssertEqual(TabActivity(isLoading: false, progress: 0.4, isCrashed: false), .idle)
        XCTAssertEqual(TabActivity(isLoading: true, progress: 0.4, isCrashed: false), .loading(progress: 0.4))
        XCTAssertEqual(TabActivity(isLoading: true, progress: 1.7, isCrashed: false), .loading(progress: 1))
        XCTAssertEqual(TabActivity(isLoading: true, progress: 0.4, isCrashed: true), .crashed, "a crash wins over loading")
        XCTAssertEqual(TabActivity(isLoading: true, progress: 0.4, isCrashed: false, isDiscarded: true), .idle)
        XCTAssertEqual(TabActivity.loading(progress: nil).barFraction, 0.1)
        XCTAssertEqual(TabActivity.loading(progress: 0.02).barFraction, 0.1, "the bar shows at once")
        XCTAssertEqual(TabActivity.loading(progress: 0.6).barFraction, 0.6)
        XCTAssertNil(TabActivity.idle.barFraction)
        XCTAssertNil(TabActivity.crashed.barFraction)
        XCTAssertTrue(TabActivity.loading(progress: nil).isLoading)
        XCTAssertFalse(TabActivity.crashed.isLoading)
    }
}
