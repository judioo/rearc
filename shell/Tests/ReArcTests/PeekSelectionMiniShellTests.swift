import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Peek, the sidebar's ⇧/⌘-click selection and the mini sidebar together:
/// a sidebar click while a Peek is open, at either width; one order for
/// Esc, ⌘O, ⇧⌘S and the selection's keys; and the Peek's card beside the
/// mini column and its morph.
@MainActor
final class PeekSelectionMiniShellTests: XCTestCase {
    private struct Fixture {
        let model: BrowserViewModel
        let window: SidebarWindowID
        /// Three Today tabs, top to bottom; the top one shown.
        let google: [Tab]
    }

    private func makeFixture() -> Fixture {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-psm-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-psm-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-psm-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-psm-\(UUID().uuidString)"))
        let window = SidebarWindowID()
        model.openSidebarMode(for: window)
        model.store.registerWindow(window)
        model.windowBecameKey(window)
        var google = (1 ... 3).map { model.store.addTab(kind: .today, title: "Google \($0)", url: URL(string: "https://www.google.com/?n=\($0)")!) }
        let order = model.store.outlineOrder(in: model.store.activeSpaceID)
        google.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        model.selectTab(google[0].id)
        return Fixture(model: model, window: window, google: google)
    }

    private let link = URL(string: "https://peek.test/page")!

    private func esc(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    /// The top tab shown, the two below it ⇧-clicked into the selection.
    private func select(_ f: Fixture) {
        XCTAssertTrue(f.model.handleSelectionClick(on: f.google[2].id, in: f.window, modifiers: .shift))
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id))
    }

    // MARK: A sidebar click while a Peek is open

    /// The Peek's rule: a click on the sidebar closes the Peek and does
    /// nothing else. Not a ⇧- or ⌘-click either: no selection starts or
    /// changes, and the page stays. The mini rows take the same handler.
    func testASidebarClickWithAPeekOpenOnlyClosesIt() {
        for mini in [false, true] {
            let f = makeFixture()
            if mini { f.model.sidebarModes.set(.mini, in: f.window) }
            XCTAssertEqual(f.model.isMiniSidebar(in: f.window), mini)
            for modifiers in [NSEvent.ModifierFlags.shift, .command, []] {
                f.model.showPeek(url: link, sourceTabID: f.google[0].id)
                XCTAssertTrue(f.model.showsPeek(in: f.window))
                var ran = false
                f.model.handleRowClick(f.google[1].id, in: f.window, modifiers: modifiers) { ran = true }
                XCTAssertNil(f.model.peekSession, "mini \(mini), \(modifiers): the click closes the Peek")
                XCTAssertFalse(ran, "mini \(mini), \(modifiers): and does not reach the row")
                XCTAssertNil(f.model.store.multiSelection(in: f.window), "mini \(mini), \(modifiers): no selection")
                XCTAssertEqual(f.model.store.selectedTabID, f.google[0].id)
            }
        }
    }

    /// Nor does it end a selection made before the Peek opened.
    func testASidebarClickWithAPeekOpenKeepsTheSelectionAsItWas() {
        let f = makeFixture()
        select(f)
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)
        f.model.handleRowClick(f.google[1].id, in: f.window, modifiers: .command) {}
        XCTAssertNil(f.model.peekSession)
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id), "the ⌘-click did not toggle the middle tab")
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)
        f.model.handleRowClick(f.google[1].id, in: f.window, modifiers: []) { f.model.selectTab(f.google[1].id) }
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id), "the plain click did not drop it")
        XCTAssertEqual(f.model.store.selectedTabID, f.google[0].id)
    }

    /// With no Peek, the click is the row's, full or mini.
    func testWithoutAPeekTheRowClickSelectsOrRuns() {
        let f = makeFixture()
        f.model.sidebarModes.set(.mini, in: f.window)
        var ran = false
        f.model.handleRowClick(f.google[2].id, in: f.window, modifiers: .shift) { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id))
        f.model.handleRowClick(f.google[1].id, in: f.window, modifiers: []) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertNil(f.model.keySelectionIDs, "a plain click drops the selection")
    }

    // MARK: Esc, ⌘O, ⇧⌘S and the selection's keys

    /// Esc closes the Peek first (its monitor runs before the responders),
    /// and the selection behind it stays; the next Esc, which reaches the
    /// sidebar's key view, clears the selection; then Esc goes on.
    func testEscClosesThePeekBeforeItClearsTheSelection() {
        let f = makeFixture()
        select(f)
        let keys = SidebarSelectionKeyView()
        keys.bind(to: f.model) { f.window }
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)

        XCTAssertTrue(f.model.handlePeekEscape(esc()))
        XCTAssertNil(f.model.peekSession)
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id), "the selection waits behind the Peek")

        XCTAssertFalse(f.model.handlePeekEscape(esc()), "no Peek: Esc goes on to the responders")
        keys.keyDown(with: esc())
        XCTAssertNil(f.model.store.multiSelection(in: f.window), "the sidebar's Esc clears the selection")
        XCTAssertFalse(keys.onCancel(), "nothing left for Esc in the sidebar")
    }

    /// Esc stays the command bar's while it is open, over a Peek and a selection.
    func testEscIsTheCommandBarsFirst() {
        let f = makeFixture()
        select(f)
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)
        f.model.isCommandBarPresented = true
        XCTAssertFalse(f.model.handlePeekEscape(esc()))
        XCTAssertNotNil(f.model.peekSession)
        XCTAssertNotNil(f.model.store.multiSelection(in: f.window))
    }

    /// While a Peek is open the selection is set aside: ⇧⌘C, ⌘C and ⌘W
    /// act as they do without one (the shown tab), and on the selection
    /// again once the Peek has closed.
    func testTheSelectionsKeysWaitBehindAPeek() {
        let f = makeFixture()
        select(f)
        let keys = SidebarSelectionKeyView()
        keys.bind(to: f.model) { f.window }
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)

        XCTAssertNil(f.model.keySelectionIDs)
        XCTAssertFalse(keys.hasSelection(), "Edit › Copy is not the selection's")
        XCTAssertFalse(keys.onCopy())
        XCTAssertEqual(f.model.closeTabMenuTitle, "Archive Tab", "⌘W names one tab")
        f.model.copyURL()
        XCTAssertEqual(f.model.linkPasteboard.string(forType: .string), f.google[0].url.absoluteString, "⇧⌘C copies the shown tab")
        XCTAssertNotNil(f.model.store.multiSelection(in: f.window), "and the selection is still drawn")

        f.model.dismissPeek(animated: false)
        XCTAssertEqual(f.model.closeTabMenuTitle, "Archive Tabs")
        XCTAssertTrue(keys.hasSelection())
        XCTAssertTrue(keys.onCopy(), "⌘C copies the selection's links")
        XCTAssertEqual(f.model.linkPasteboard.string(forType: .string)?.components(separatedBy: "\n").count, 3)
        f.model.copyURL(format: .markdown)
        XCTAssertEqual(f.model.linkPasteboard.string(forType: .string)?.components(separatedBy: "\n").count, 3, "⌥⇧⌘C too")
    }

    /// ⌘O expands the Peek into a tab, whatever is selected; the new tab is
    /// the shown item, so the selection ends as any change of tab ends it.
    func testCommandOExpandsThePeekOverASelection() {
        let f = makeFixture()
        select(f)
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)
        let peekID = f.model.peekSession?.engineID
        f.model.openLittleArcOrPeekInSpace()
        XCTAssertNil(f.model.peekSession)
        XCTAssertEqual(f.model.store.selectedTabID, peekID)
        XCTAssertNil(f.model.store.multiSelection(in: f.window))
    }

    /// ⇧⌘S with a Peek open: the sidebar turns mini, the Peek stays, and
    /// the selection with it.
    func testCommandShiftSLeavesThePeekAndTheSelection() {
        let f = makeFixture()
        select(f)
        f.model.showPeek(url: link, sourceTabID: f.google[0].id)
        f.model.toggleMiniSidebar(in: f.window)
        XCTAssertTrue(f.model.isMiniSidebar(in: f.window))
        XCTAssertNotNil(f.model.peekSession)
        XCTAssertNotNil(f.model.store.multiSelection(in: f.window))
        XCTAssertTrue(f.model.handlePeekEscape(esc()))
        XCTAssertEqual(f.model.keySelectionIDs, f.google.map(\.id))
    }

    // MARK: The Peek's card beside the mini sidebar

    /// The card is 80 % of the area beside the sidebar as it is now: the
    /// 52 pt mini column, the full width, and through ⇧⌘S the edge as drawn.
    func testThePeekCardUsesTheSidebarsCurrentWidth() {
        let f = makeFixture()
        f.model.sidebarWidth = 300
        let size = CGSize(width: 1400, height: 900)
        func card() -> CGRect {
            PeekLayout(region: PeekLayout.region(windowSize: size, sidebarWidth: f.model.peekSidebarWidth(in: f.window), sidebarOnLeft: true)).card
        }
        XCTAssertEqual(f.model.peekSidebarWidth(in: f.window), 300)
        XCTAssertEqual(card().width, (1400 - 300) * 0.8, accuracy: 0.01)
        XCTAssertEqual(card().midX, 300 + (1400 - 300) / 2, accuracy: 0.01)

        f.model.sidebarModes.set(.mini, in: f.window)
        XCTAssertEqual(f.model.peekSidebarWidth(in: f.window), MiniSidebarLayout.width)
        XCTAssertEqual(MiniSidebarLayout.width, 52)
        XCTAssertEqual(card().width, (1400 - 52) * 0.8, accuracy: 0.01)
        XCTAssertEqual(card().midX, 52 + (1400 - 52) / 2, accuracy: 0.01)

        // Mid-morph the card follows the edge as drawn, not the end width.
        var morph = SidebarWidthMorph(from: 300, to: 52)!
        f.model.sidebarMorphs[f.window] = morph
        XCTAssertEqual(f.model.peekSidebarWidth(in: f.window), 300)
        morph.shown = 176
        f.model.sidebarMorphs[f.window] = morph
        XCTAssertEqual(card().width, (1400 - 176) * 0.8, accuracy: 0.01)
        f.model.sidebarMorphs[f.window] = nil
        XCTAssertEqual(f.model.peekSidebarWidth(in: f.window), 52)
    }
}

/// Esc in a full-screen window: a sidebar selection holding the keyboard
/// takes it before the "press Esc again" hint does.
@MainActor
final class SelectionFullscreenEscapeTests: XCTestCase {
    func testTheSidebarSelectionsKeyViewTakesEscBeforeTheFullscreenHint() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let keys = SidebarSelectionKeyView()
        window.contentView?.addSubview(keys)
        var selected = true
        keys.hasSelection = { selected }
        XCTAssertFalse(BrowserViewModel.sidebarSelectionTakesEscape(in: window), "not first responder")
        XCTAssertTrue(window.makeFirstResponder(keys))
        XCTAssertTrue(BrowserViewModel.sidebarSelectionTakesEscape(in: window))
        selected = false
        XCTAssertFalse(BrowserViewModel.sidebarSelectionTakesEscape(in: window), "no selection left: the hint's again")
    }
}
