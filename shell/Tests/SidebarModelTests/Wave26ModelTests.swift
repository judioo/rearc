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

/// Wave 26: Split View flip and Expand Current Split.
final class Wave26SplitModelTests: XCTestCase {

    private func makeSplit() -> (SidebarStore, SplitViewItem) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let split = store.splitTab(b.id, with: a.id)!
        return (store, split)
    }

    func testFlipKeepsPaneSizes() {
        let (store, split) = makeSplit()
        store.resizeSplitPanes(splitID: split.id, widthFactors: [split.tabs[0].id: 0.7, split.tabs[1].id: 0.3])
        let before = store.split(withID: split.id)!
        XCTAssertEqual(store.flipSplitOrientation(splitID: split.id), before.orientation.flipped)
        let after = store.split(withID: split.id)!
        XCTAssertEqual(after.orientation, before.orientation.flipped)
        XCTAssertEqual(after.widthFactors, before.widthFactors)
        store.flipSplitOrientation(splitID: split.id)
        XCTAssertEqual(store.split(withID: split.id)?.orientation, before.orientation)
        XCTAssertNil(store.flipSplitOrientation(splitID: UUID()))
        XCTAssertEqual(SplitLayoutOrientation.horizontal.flipped, .vertical)
    }

    func testExpandCurrentSplitIsPerWindowAndFollowsFocus() {
        let (store, created) = makeSplit()
        var split = store.split(withID: created.id)!
        let window = SidebarWindowID(), other = SidebarWindowID()
        var state = SplitPaneMaximizeState()
        XCTAssertEqual(state.visibleTabs(in: split, window: window).count, 2)

        XCTAssertTrue(state.toggle(split, window: window))
        XCTAssertEqual(state.visibleTabs(in: split, window: window).map(\.id), [split.focusTabID])
        XCTAssertEqual(state.visibleTabs(in: split, window: other).count, 2, "other windows keep the split")

        let sibling = split.tabs.first { $0.id != split.focusTabID }!.id
        store.setSplitFocus(splitID: split.id, tabID: sibling)
        split = store.split(withID: split.id)!
        XCTAssertNil(state.maximizedTab(in: split, window: window), "focusing another pane restores the split")
        XCTAssertTrue(state.toggle(split, window: window), "and toggling expands the new focus")
        XCTAssertEqual(state.maximizedTab(in: split, window: window), sibling)
        XCTAssertFalse(state.toggle(split, window: window))
        XCTAssertEqual(state.visibleTabs(in: split, window: window).count, 2)

        state.toggle(split, window: window)
        state.forgetWindow(window)
        XCTAssertNil(state.maximizedTab(in: split, window: window))
        state.toggle(split, window: other)
        state.restore(split.id, window: other)
        XCTAssertTrue(state.maximized.isEmpty)
    }
}

/// Wave 26: inline domain completion, routing modifiers and the Ctrl+Tab switcher.
final class Wave26CommandBarModelTests: XCTestCase {

    func testInlineDomainCompletion() {
        let hosts = ["www.github.com", "gitlab.com", "google.com"]
        XCTAssertEqual(InlineDomainCompletion.complete("git", candidates: hosts), "github.com")
        XCTAssertEqual(InlineDomainCompletion.complete("GitL", candidates: hosts), "gitlab.com")
        XCTAssertEqual(InlineDomainCompletion.complete("https://www.goo", candidates: hosts), "google.com")
        XCTAssertNil(InlineDomainCompletion.complete("github.com", candidates: hosts), "nothing left to complete")
        XCTAssertNil(InlineDomainCompletion.complete("git hub", candidates: hosts), "a search, not a domain")
        XCTAssertNil(InlineDomainCompletion.complete("github.com/rearc", candidates: hosts), "a path is typed")
        XCTAssertNil(InlineDomainCompletion.complete(">git", candidates: hosts), "command mode")
        XCTAssertNil(InlineDomainCompletion.complete("", candidates: hosts))
        XCTAssertNil(InlineDomainCompletion.complete("zz", candidates: hosts))

        XCTAssertEqual(InlineDomainCompletion.suffix(typed: "Git", completion: "github.com"), "hub.com")
        XCTAssertEqual(InlineDomainCompletion.suffix(typed: "https://www.goo", completion: "google.com"), "gle.com")
        XCTAssertEqual(InlineDomainCompletion.suffix(typed: "www.git", completion: "github.com"), "hub.com")
        XCTAssertNil(InlineDomainCompletion.suffix(typed: "github.com", completion: "github.com"))
    }

    func testVisitedHostsRankAheadOfTheBundledList() {
        let now = Date()
        func visit(_ url: String, _ count: Int) -> VisitRecord {
            VisitRecord(url: URL(string: url)!, title: "", visitCount: count, firstVisit: now, lastVisit: now)
        }
        let history = VisitHistory(records: [visit("https://gitea.example.org/x", 3), visit("https://www.gamma.test/", 9)])
        let candidates = InlineDomainCompletion.candidates(history: history)
        XCTAssertEqual(Array(candidates.prefix(2)), ["gamma.test", "gitea.example.org"], "most visits first")
        XCTAssertEqual(InlineDomainCompletion.complete("git", candidates: candidates), "gitea.example.org")
        XCTAssertEqual(InlineDomainCompletion.complete("git", candidates: InlineDomainCompletion.candidates(history: VisitHistory())), "github.com")
        XCTAssertEqual(Set(candidates).count, candidates.count, "no duplicates")
        XCTAssertGreaterThan(TopDomains.bundled.count, 150)
    }

    func testInlineCompletionIsTheFirstResult() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let results = CommandBarSearch.results(for: "git", in: store, inlineCompletion: "github.com")
        XCTAssertEqual(results.first?.destinationURL, URL(string: "https://github.com/"))
        XCTAssertEqual(results.first?.kind, .openURL)
        let typed = CommandBarSearch.results(for: "github.com", in: store, inlineCompletion: nil)
        XCTAssertEqual(typed.filter { $0.destinationURL?.host() == "github.com" && $0.kind == .openURL }.count, 1)
    }

    func testRoutingModifiers() {
        XCTAssertEqual(CommandBarRoute(command: false, option: false, shift: false), .current)
        XCTAssertEqual(CommandBarRoute(command: true, option: false, shift: false), .newTab)
        XCTAssertEqual(CommandBarRoute(command: false, option: true, shift: false), .splitView)
        XCTAssertEqual(CommandBarRoute(command: false, option: false, shift: true), .littleArc)
        XCTAssertEqual(CommandBarRoute(command: true, option: true, shift: false), .current, "combinations keep the default")
        XCTAssertEqual(Set(CommandBarRoute.allCases.map(\.hint)).count, 4)
    }

    func testRecentTabsAndSwitcherSession() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Work", sortRank: "b")])
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        let work = store.spaces[1].id
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .pinned, title: "B", url: URL(string: "https://b.test")!)
        let c = store.addTab(kind: .today, title: "C", url: URL(string: "https://c.test")!, in: work)
        let fav = store.addTab(kind: .favorite, title: "F", url: URL(string: "https://f.test")!)
        for id in [fav.id, a.id, c.id, b.id] {
            clock += 10
            _ = store.focusTab(id)
        }
        let items = store.recentTabSwitcherItems()
        XCTAssertEqual(items.map(\.id), [b.id, c.id, a.id, fav.id], "selected first, then most recent, across spaces")
        XCTAssertEqual(items[1].spaceName, "Work")
        XCTAssertNil(items[3].spaceName, "favorites have no space")

        var forward = TabSwitcherSession(items: items, forward: true)!
        XCTAssertEqual(forward.highlighted.id, c.id, "one Ctrl+Tab: the previous tab")
        forward.step(forward: true)
        forward.step(forward: true)
        forward.step(forward: true)
        XCTAssertEqual(forward.highlighted.id, b.id, "wraps around")
        let backward = TabSwitcherSession(items: items, forward: false)!
        XCTAssertEqual(backward.highlighted.id, fav.id, "Ctrl+Shift+Tab: the least recent")
        XCTAssertNil(TabSwitcherSession(items: [], forward: true))
        XCTAssertEqual(TabSwitcherSession(items: [items[0]], forward: true)?.index, 0)
    }

    func testSplitCountsOnceInRecentTabs() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
        let split = store.splitTab(b.id, with: a.id)!
        let items = store.recentTabSwitcherItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(split.tabs.map(\.id).contains(items[0].id))
        XCTAssertEqual(items[0].title, "A | B")
    }
}

/// Wave 26: Little Arc chrome and entry points.
final class Wave26LittleArcModelTests: XCTestCase {

    func testAddressPlaceholderAndEditingText() {
        XCTAssertEqual(LittleArcChrome.addressText(for: URL(string: "https://www.example.com/a/b?c=1")), "example.com")
        XCTAssertEqual(LittleArcChrome.addressText(for: URL(string: "http://docs.test:8080/x")), "docs.test")
        XCTAssertEqual(LittleArcChrome.addressText(for: URL(string: "file:///tmp/a.html")), "file:///tmp/a.html")
        XCTAssertEqual(LittleArcChrome.addressText(for: URL(string: "about:blank")), "")
        XCTAssertEqual(LittleArcChrome.addressText(for: nil), "")
        XCTAssertEqual(LittleArcChrome.editingText(for: URL(string: "https://www.example.com/a")), "https://www.example.com/a")
        XCTAssertEqual(LittleArcChrome.editingText(for: URL(string: "about:blank")), "")
    }

    func testOptionCommandClickOnly() {
        XCTAssertTrue(LittleArcChrome.clickOpensLittleArc(command: true, option: true, shift: false, control: false))
        XCTAssertFalse(LittleArcChrome.clickOpensLittleArc(command: true, option: false, shift: false, control: false), "⌘-click is a background tab")
        XCTAssertFalse(LittleArcChrome.clickOpensLittleArc(command: false, option: true, shift: false, control: false), "⌥-click downloads")
        XCTAssertFalse(LittleArcChrome.clickOpensLittleArc(command: true, option: true, shift: true, control: false))
        XCTAssertFalse(LittleArcChrome.clickOpensLittleArc(command: true, option: true, shift: false, control: true))
    }

    func testHotkeyPreferenceIsOffUntilTurnedOn() {
        let defaults = UserDefaults(suiteName: "rearc-w26-hotkey-\(UUID().uuidString)")!
        XCTAssertFalse(LittleArcHotkeyPreference.load(from: defaults).isEnabled)
        LittleArcHotkeyPreference(isEnabled: true).save(to: defaults)
        XCTAssertTrue(LittleArcHotkeyPreference.load(from: defaults).isEnabled)
        XCTAssertEqual(LittleArcHotkeyPreference.display, "⌥⌘N")
    }

    func testLittleArcProfileChange() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let work = store.addProfile(name: "Work")
        let record = store.createLittleArcWindow(url: URL(string: "https://a.test")!)
        XCTAssertNotEqual(record.profileID, work.id)
        XCTAssertTrue(store.setLittleArcProfile(record.id, to: work.id))
        XCTAssertEqual(store.littleArcWindow(withID: record.id)?.profileID, work.id)
        XCTAssertFalse(store.setLittleArcProfile(record.id, to: work.id), "already there")
        XCTAssertFalse(store.setLittleArcProfile(record.id, to: UUID()), "no such profile")
        XCTAssertFalse(store.setLittleArcProfile(UUID(), to: work.id))
    }
}
