import CoreGraphics
import XCTest
@testable import SidebarModel

/// Arc's Peek geometry, dismissal rules and motion (PeekLayout.swift), and
/// the store's half of Open in Split View.
final class PeekLayoutTests: XCTestCase {

    // The 2026-11-11 recording in window coordinates: a 1706 × 1409 pt window
    // whose sidebar ends at 306 pt; the card spans x 447…1567, y 12…1397.
    private let arcWindow = CGSize(width: 1706, height: 1409)
    private let arcSidebar = 306.0

    func testMatchesArcsRecordedProportions() throws {
        let region = PeekLayout.region(windowSize: arcWindow, sidebarWidth: arcSidebar, sidebarOnLeft: true)
        XCTAssertEqual(region, CGRect(x: 306, y: 0, width: 1400, height: 1409))
        let layout = PeekLayout(region: region)
        XCTAssertEqual(layout.card, CGRect(x: 446, y: 12, width: 1120, height: 1385))
        XCTAssertEqual(layout.buttonPlacement, .outside)
        XCTAssertEqual(layout.card.midX, region.midX, "centred beside the sidebar, not in the window")

        let close = try XCTUnwrap(layout.frame(of: .close))
        XCTAssertEqual(close, CGRect(x: 1578, y: 20, width: 34, height: 34), "12 pt off the card, 8 pt below its top")
        XCTAssertEqual(try XCTUnwrap(layout.frame(of: .expand)).minY - close.minY, 43)
        XCTAssertEqual(try XCTUnwrap(layout.frame(of: .split)).minY - close.minY, 86)

        let grabber = try XCTUnwrap(layout.grabber)
        XCTAssertEqual(grabber.midX, layout.card.midX)
        XCTAssertEqual(grabber.size, CGSize(width: 46, height: 4))
        XCTAssertEqual(grabber.maxY, layout.card.minY - 4)

        XCTAssertEqual(layout.page, CGRect(x: 446, y: 44, width: 1120, height: 1353), "a 32 pt address line, then the page")
    }

    func testHiddenOrRightSidebarCentresInItsRegion() {
        let hidden = PeekLayout(region: PeekLayout.region(windowSize: arcWindow, sidebarWidth: 0, sidebarOnLeft: true))
        XCTAssertEqual(hidden.card.midX, arcWindow.width / 2)
        XCTAssertEqual(hidden.card.width, arcWindow.width * 0.8, accuracy: 0.001)

        let right = PeekLayout.region(windowSize: arcWindow, sidebarWidth: arcSidebar, sidebarOnLeft: false)
        XCTAssertEqual(right, CGRect(x: 0, y: 0, width: 1400, height: 1409))
        XCTAssertEqual(PeekLayout(region: right).card.minX, 140)
    }

    func testNarrowWindowKeepsTheMinimumInsetForTheButtons() throws {
        // 0.8 × 500 = 400 would leave 50 pt each side; the buttons need 58.
        let layout = PeekLayout(region: CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(layout.buttonPlacement, .outside)
        XCTAssertEqual(layout.card.minX, PeekLayout.minimumSideInset)
        XCTAssertEqual(layout.card.width, 500 - 2 * PeekLayout.minimumSideInset)
        let close = try XCTUnwrap(layout.frame(of: .close))
        XCTAssertEqual(500 - close.maxX, 12, "the buttons keep 12 pt to the window edge")
    }

    func testTooNarrowForOutsideButtonsPutsThemInsideTheCard() throws {
        let layout = PeekLayout(region: CGRect(x: 100, y: 0, width: 360, height: 600))
        XCTAssertEqual(layout.buttonPlacement, .inside)
        XCTAssertEqual(layout.card, CGRect(x: 112, y: 12, width: 336, height: 576))
        let close = try XCTUnwrap(layout.frame(of: .close))
        XCTAssertEqual(layout.card.maxX - close.maxX, 12)
        XCTAssertGreaterThanOrEqual(close.minY, layout.card.minY + PeekLayout.addressLineHeight, "never over the address line")
        XCTAssertTrue(layout.buttons.allSatisfy { layout.card.contains($0) })
    }

    func testDegenerateRegionsStayNonNegative() {
        let layout = PeekLayout(region: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertGreaterThanOrEqual(layout.card.width, 0)
        XCTAssertGreaterThanOrEqual(layout.card.height, 0)
    }

    func testFullscreenPageFillsTheWindowWithNoChrome() {
        let window = CGRect(origin: .zero, size: arcWindow)
        let layout = PeekLayout(region: window, isFullscreen: true)
        XCTAssertEqual(layout.card, window)
        XCTAssertEqual(layout.page, window)
        XCTAssertTrue(layout.buttons.isEmpty)
        XCTAssertNil(layout.grabber)
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 5, y: 5)), layout: layout), .none)
    }

    // MARK: Dismissal

    private var arcLayout: PeekLayout {
        PeekLayout(region: PeekLayout.region(windowSize: arcWindow, sidebarWidth: arcSidebar, sidebarOnLeft: true))
    }

    func testClicksInsideTheCardDoNothingAndAnywhereElseCloses() {
        let layout = arcLayout
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 900, y: 600)), layout: layout), .none, "the page")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 900, y: 20)), layout: layout), .none, "the address line")
        // The owner's click in the recording: the washed page left of the card.
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 370, y: 700)), layout: layout), .close)
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 120, y: 300)), layout: layout), .close, "the sidebar")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 1680, y: 1000)), layout: layout), .close, "right of the card")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 900, y: 1405)), layout: layout), .close, "below it")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 900, y: 5)), layout: layout), .close, "above it")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: 1, y: 1))), .none, "no Peek, no layout")
    }

    func testTheButtonsAreRoundAndEachDoesItsOwnThing() throws {
        let layout = arcLayout
        for (control, action) in [(PeekLayout.Control.close, PeekAction.close), (.expand, .expandToTab), (.split, .openInSplitView)] {
            let frame = try XCTUnwrap(layout.frame(of: control))
            XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: frame.midX, y: frame.midY)), layout: layout), action)
            XCTAssertEqual(PeekDismissal.action(for: .button(control), layout: layout), action)
            XCTAssertEqual(layout.control(at: CGPoint(x: frame.midX, y: frame.midY)), control)
        }
        let close = try XCTUnwrap(layout.frame(of: .close))
        XCTAssertNil(layout.control(at: CGPoint(x: close.minX + 1, y: close.minY + 1)), "a circle, not its square")
        XCTAssertEqual(PeekDismissal.action(for: .click(CGPoint(x: close.minX + 1, y: close.minY + 1)), layout: layout), .close)
    }

    func testEscapeClosesUnlessThePageNeedsIt() {
        XCTAssertEqual(PeekDismissal.action(for: .escape(pageFullscreen: false, promptOpen: false)), .close)
        XCTAssertEqual(PeekDismissal.action(for: .escape(pageFullscreen: true, promptOpen: false)), .none, "Esc leaves fullscreen first")
        XCTAssertEqual(PeekDismissal.action(for: .escape(pageFullscreen: false, promptOpen: true)), .none, "the prompt over the card takes it")
        XCTAssertEqual(PeekDismissal.action(for: .expandShortcut), .expandToTab)
    }

    // MARK: Motion

    func testGrowsOutOfTheClickAndElseOutOfItsCentre() {
        let layout = arcLayout
        let bounds = CGRect(origin: .zero, size: arcWindow)
        let link = CGPoint(x: 500, y: 300)
        let fromLink = PeekMotion.originRect(pointer: link, card: layout.card, bounds: bounds)
        XCTAssertEqual(fromLink.midX, link.x, accuracy: 0.001)
        XCTAssertEqual(fromLink.midY, link.y, accuracy: 0.001)
        XCTAssertEqual(fromLink.width, layout.card.width * PeekMotion.originScale, accuracy: 0.001)
        XCTAssertEqual(fromLink.width / fromLink.height, layout.card.width / layout.card.height, accuracy: 0.001)

        let none = PeekMotion.originRect(pointer: nil, card: layout.card, bounds: bounds)
        XCTAssertEqual(none.midX, layout.card.midX, accuracy: 0.001)
        XCTAssertEqual(none.midY, layout.card.midY, accuracy: 0.001)
        XCTAssertEqual(none.width, layout.card.width * PeekMotion.centreScale, accuracy: 0.001)
        XCTAssertEqual(PeekMotion.originRect(pointer: CGPoint(x: -40, y: 20), card: layout.card, bounds: bounds), none,
                       "a pointer outside the window is no origin")
    }

    func testTheOriginStaysInsideTheWindow() {
        let layout = arcLayout
        let bounds = CGRect(origin: .zero, size: arcWindow)
        let corner = PeekMotion.originRect(pointer: CGPoint(x: 1, y: 1), card: layout.card, bounds: bounds)
        XCTAssertEqual(corner.origin, .zero)
        let far = PeekMotion.originRect(pointer: CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1), card: layout.card, bounds: bounds)
        XCTAssertEqual(far.maxX, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(far.maxY, bounds.maxY, accuracy: 0.001)
    }

    func testMotionIsArcsShortGrowAndShrink() {
        XCTAssertLessThanOrEqual(PeekMotion.openDuration, 0.17)
        XCTAssertLessThan(PeekMotion.closeDuration, PeekMotion.openDuration)
        XCTAssertEqual(PeekLayout.backdropWash, 0.72)
    }

    // MARK: Store: expand and split

    func testAddTabKeepsAGivenIdentity() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let id = UUID()
        let tab = store.addTab(kind: .today, title: "Peek", url: URL(string: "https://peek.test")!, tabID: id)
        XCTAssertEqual(tab.id, id)
        XCTAssertEqual(store.tab(withID: id)?.url.host(), "peek.test")
    }

    func testSplitAnchorIsTheSourceTabWhenItCanSplit() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let today = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        let pinned = store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!)
        let favorite = store.addTab(kind: .favorite, title: "F", url: URL(string: "https://f.test")!)
        XCTAssertEqual(store.peekSplitAnchor(sourceTabID: today.id), today.id)
        XCTAssertEqual(store.peekSplitAnchor(sourceTabID: pinned.id), pinned.id)
        XCTAssertNil(store.peekSplitAnchor(sourceTabID: favorite.id), "favorites never split")
        XCTAssertNil(store.peekSplitAnchor(sourceTabID: nil), "the command bar's Peek has no tab")

        let peek = store.addTab(kind: .today, title: "Peek", url: URL(string: "https://peek.test")!, tabID: UUID())
        let split = try XCTUnwrap(store.splitTab(peek.id, with: pinned.id))
        XCTAssertEqual(Set(split.tabs.map(\.id)), [pinned.id, peek.id], "the Peek joins the pinned tab's section")
        XCTAssertEqual(store.peekSplitAnchor(sourceTabID: pinned.id), pinned.id, "a split with room takes another pane")
        for index in 0..<2 {
            let pane = store.addTab(kind: .today, title: "\(index)", url: URL(string: "https://\(index).test")!)
            XCTAssertNotNil(store.splitTab(pane.id, with: pinned.id))
        }
        XCTAssertNil(store.peekSplitAnchor(sourceTabID: pinned.id), "four panes is full")
    }

    func testAFoldersTabCannotAnchorASplit() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let a = store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .pinned, title: "B", url: URL(string: "https://b.test")!)
        _ = try XCTUnwrap(store.createFolder(containing: [a.id, b.id]))
        XCTAssertNil(store.peekSplitAnchor(sourceTabID: a.id))
    }
}
