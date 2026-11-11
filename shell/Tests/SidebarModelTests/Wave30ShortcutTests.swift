import XCTest
@testable import SidebarModel

/// Wave 30: Arc's shortcut table, its routing rule while a page has focus,
/// Copy URL's tracker cleaning and Cycle Tab's visit order.
final class Wave30ShortcutTests: XCTestCase {
    // MARK: Table

    func testTheTableHoldsArcsBindingsWithTheirPriorities() {
        let ids = ArcShortcuts.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "binding IDs are unique, as Arc's KeyBindingMenuManager requires")
        // 83 distinct key-bound nib items (its duplicate Zoom In and New Tab… rows
        // dropped) less Save Page As, whose ⇧⌘S went to ReArc's Toggle Mini
        // Sidebar, and the 18 code-defined ⌃1…9 / ⌘1…9 bindings.
        XCTAssertEqual(ArcShortcuts.all.count, 83 - 1 + 1 + 18)

        func check(_ key: ShortcutKey, _ modifiers: ShortcutModifiers, _ id: String, _ priority: ShortcutPriority,
                   file: StaticString = #filePath, line: UInt = #line) {
            let binding = ArcShortcuts.binding(for: key, modifiers: modifiers)
            XCTAssertEqual(binding?.id, id, file: file, line: line)
            XCTAssertEqual(binding?.priority, priority, file: file, line: line)
        }
        check(.character("l"), .command, "addressBar", .arcWins)
        check(.character("c"), [.shift, .command], "copyCurrentURL", .arcWins)
        check(.character("c"), [.option, .shift, .command], "copyCurrentURLMarkdown", .arcWins)
        check(.character("c"), [.control, .shift, .command], "copyCurrentURLAsQuote", .arcWins)
        check(.character("s"), .command, "showSidebar", .websiteFirst)
        check(.character("d"), .command, "pinTab", .websiteFirst)
        check(.character("t"), .command, "newTab", .arcWins)
        check(.character("w"), .command, "archiveTab", .arcWins)
        check(.character("r"), .command, "reloadPage", .websiteWins)
        check(.character("f"), .command, "find", .websiteWins)
        check(.character("c"), .command, "copy", .websiteWins)
        check(.character("i"), [.option, .command], "developerTools", .websiteFirst)
        check(.tab, .control, "cycleNextTab", .arcWins)
        check(.downArrow, [.option, .command], "selectNextTab", .arcWins)
        check(.leftArrow, [.control, .command], "cycleTabBackward", .arcWins)
        check(.rightArrow, [.option, .command], "focusNextSpace", .websiteWins)
        check(.character("1"), .control, "goToSpace1", .arcWins)
        check(.character("9"), .command, "goToSidebarItem9", .arcWins)
        check(.character("="), [.control, .shift], "addSplitView", .websiteFirst)
        XCTAssertNil(ArcShortcuts.binding(for: .character("e"), modifiers: .command), "⌘E is not an Arc shortcut")
        XCTAssertNil(ArcShortcuts.binding(for: .character("\\"), modifiers: .command), "⌘\\ is not an Arc shortcut")
    }

    func testTheMenuBarOrderDecidesASharedKey() {
        // Arc's nib gives ⇧⌘N to both; File (New Incognito Window) comes before Tabs (New Folder…).
        XCTAssertEqual(ArcShortcuts.binding(for: .character("n"), modifiers: [.shift, .command])?.id, "newIncognitoWindow")
        XCTAssertEqual(ArcShortcuts.shadowed.map(\.id), ["newFolder"])
    }

    func testDisplayNamesFollowTheMacOSModifierOrder() {
        XCTAssertEqual(ArcShortcuts.binding(id: "copyCurrentURLMarkdown")?.display, "⌥⇧⌘C")
        XCTAssertEqual(ArcShortcuts.binding(id: "copyCurrentURLAsQuote")?.display, "⌃⇧⌘C")
        XCTAssertEqual(ArcShortcuts.binding(id: "showSidebar")?.display, "⌘S")
        XCTAssertEqual(ArcShortcuts.binding(id: "selectPreviousTab")?.display, "⌥⌘↑")
        XCTAssertEqual(ArcShortcuts.binding(id: "developerTools_Alternate")?.display, "F12")
    }

    // MARK: Routing

    func testArcWinsKeysNeverReachThePage() {
        let copy = ArcShortcuts.binding(id: "copyCurrentURL")
        XCTAssertEqual(ShortcutRouting.route(copy, armed: false), .browser)
        XCTAssertEqual(ShortcutRouting.route(ArcShortcuts.binding(id: "addressBar"), armed: false), .browser)
    }

    func testWebsiteFirstKeysGoToThePageUntilTheSecondPress() {
        let sidebar = ArcShortcuts.binding(id: "showSidebar")!
        XCTAssertEqual(ShortcutRouting.route(sidebar, armed: false), .page)
        XCTAssertEqual(ShortcutRouting.verdict(sidebar, consumedByPage: false), .perform, "a page that ignores ⌘S toggles the sidebar")
        XCTAssertEqual(ShortcutRouting.verdict(sidebar, consumedByPage: true), .prompt)
        XCTAssertEqual(ShortcutRouting.route(sidebar, armed: true), .browser)
        XCTAssertEqual(ShortcutRouting.promptMessage(for: sidebar), "Press ⌘S again to Show/Hide Sidebar")
    }

    func testWebsiteWinsKeysAndUnknownKeysFallBackWhenThePageIgnoresThem() {
        let reload = ArcShortcuts.binding(id: "reloadPage")
        XCTAssertEqual(ShortcutRouting.route(reload, armed: true), .page, "only website-first keys arm")
        XCTAssertEqual(ShortcutRouting.verdict(reload, consumedByPage: false), .perform)
        XCTAssertEqual(ShortcutRouting.verdict(reload, consumedByPage: true), .none)
        XCTAssertEqual(ShortcutRouting.route(nil, armed: false), .page)
        XCTAssertEqual(ShortcutRouting.verdict(nil, consumedByPage: false), .perform)
        XCTAssertEqual(ShortcutRouting.verdict(nil, consumedByPage: true), .none)
    }

    func testThePromptArmsOnlyItsOwnShortcutAndExpires() {
        var arming = ShortcutPromptArming()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(arming.isArmed("showSidebar", now: start))
        arming.arm("showSidebar", now: start)
        XCTAssertTrue(arming.isArmed("showSidebar", now: start.addingTimeInterval(2)))
        XCTAssertFalse(arming.isArmed("pinTab", now: start.addingTimeInterval(1)))
        XCTAssertFalse(arming.isArmed("showSidebar", now: start.addingTimeInterval(ShortcutPromptArming.window)))
        arming.arm("pinTab", now: start)
        arming.disarm()
        XCTAssertFalse(arming.isArmed("pinTab", now: start))
    }

    // MARK: Copy URL without trackers

    func testCopyURLDropsArcsTrackingParameters() {
        func clean(_ string: String) -> (String, Bool) {
            let result = LinkCleaner.clean(URL(string: string)!)
            return (result.url.absoluteString, result.removedTrackers)
        }
        XCTAssertTrue(clean("https://a.test/p?utm_source=x&utm_campaign=y&id=4") == ("https://a.test/p?id=4", true))
        XCTAssertTrue(clean("https://a.test/p?fbclid=1&gclid=2") == ("https://a.test/p", true))
        XCTAssertTrue(clean("https://a.test/p?mc_eid=1&q=arc#top") == ("https://a.test/p?q=arc#top", true), "mc_ is a prefix")
        XCTAssertTrue(clean("https://a.test/p?q=arc&page=2") == ("https://a.test/p?q=arc&page=2", false))
        XCTAssertTrue(clean("https://a.test/p") == ("https://a.test/p", false))
        XCTAssertTrue(clean("https://x.com/arc/status/1?s=20&t=abc") == ("https://x.com/arc/status/1", true))
        XCTAssertTrue(clean("https://a.test/p?s=20&t=abc") == ("https://a.test/p?s=20&t=abc", false), "s and t are X's alone")
        XCTAssertTrue(clean("https://www.amazon.com/dp/B0?tag=aff-20&pd_rd_w=9&th=1") == ("https://www.amazon.com/dp/B0", true))
        XCTAssertTrue(clean("https://www.youtube.com/watch?v=1&feature=share") == ("https://www.youtube.com/watch?v=1", true))
    }

    // MARK: Cycle Tab

    func testCycleTabRetracesTheVisitOrderBothWays() throws {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertNil(TabVisitCycle(order: [a]), "nothing to cycle to")
        var cycle = try XCTUnwrap(TabVisitCycle(order: [a, b, c]))
        XCTAssertNil(cycle.step(forward: true), "already at the newest visit")
        XCTAssertEqual(cycle.step(forward: false), b)
        XCTAssertEqual(cycle.step(forward: false), c)
        XCTAssertNil(cycle.step(forward: false))
        XCTAssertEqual(cycle.current, c)
        XCTAssertEqual(cycle.step(forward: true), b)
        XCTAssertEqual(cycle.step(forward: true), a)
    }
}
