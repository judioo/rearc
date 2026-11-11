import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Arc's Peek in the shell: expand and split keep the Peek's page (the same
/// engine, nothing reloads), the close shrinks back, Esc and ⌘O.
final class PeekShellTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-peek-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private let link = URL(string: "https://peek.test/page?q=1")!

    /// A selected tab whose page opens `link` in a Peek, as a click on it would.
    private func peekFromTab(_ model: BrowserViewModel, kind: Tab.Kind = .today) throws -> (source: Tab, peek: any WebEngine) {
        let source = model.store.addTab(kind: kind, title: "Source", url: URL(string: "https://source.test")!)
        model.selectTab(source.id)
        let engine = try XCTUnwrap(model.engineHost.engine(forTabID: source.id, profileID: model.profileID(for: source)))
        engine.linkPeekHandler?(link)
        let peek = try XCTUnwrap(model.peekEngine)
        XCTAssertEqual(model.peekSession?.sourceTabID, source.id)
        return (source, peek)
    }

    func testExpandMovesThePeeksPageIntoATabWithoutReloading() throws {
        let model = makeModel()
        let (_, peek) = try peekFromTab(model)
        let session = try XCTUnwrap(model.peekSession)

        XCTAssertTrue(model.performPeekAction(.expandToTab))

        XCTAssertNil(model.peekSession)
        XCTAssertNil(model.peekClosing, "the page carries on in the tab: nothing shrinks back")
        let tab = try XCTUnwrap(model.store.selectedTab)
        XCTAssertEqual(tab.id, session.engineID, "the tab takes the Peek's shell identity")
        XCTAssertEqual(tab.kind, .today)
        XCTAssertEqual(tab.url, link)
        XCTAssertEqual(model.store.spaceContaining(tabID: tab.id), model.store.activeSpaceID)
        let tabEngine = try XCTUnwrap(model.engineHost.engine(forTabID: tab.id, profileID: session.profileID))
        XCTAssertTrue(tabEngine === peek, "the same engine, so its history and state stay")
        XCTAssertEqual(tabEngine.pagePrompts.role, .tab)
        XCTAssertEqual(tabEngine.pagePrompts.ownerTabID, tab.id)
        XCTAssertNotNil(tabEngine.linkPeekHandler, "it now Peeks links like any tab")
        XCTAssertNil(model.engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID))
    }

    func testCommandOExpandsThePeek() throws {
        let model = makeModel()
        let (_, peek) = try peekFromTab(model)
        model.openLittleArcOrPeekInSpace()
        XCTAssertNil(model.peekSession)
        let tab = try XCTUnwrap(model.store.selectedTab)
        XCTAssertTrue(model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) === peek)
    }

    func testSplitPutsThePeekBesideItsSourceTab() throws {
        let model = makeModel()
        let (source, peek) = try peekFromTab(model, kind: .pinned)
        let session = try XCTUnwrap(model.peekSession)
        XCTAssertEqual(model.peekSplitAnchor, source.id)

        XCTAssertTrue(model.performPeekAction(.openInSplitView))

        XCTAssertNil(model.peekSession)
        let split = try XCTUnwrap(model.store.splitContaining(tabID: source.id)?.split)
        XCTAssertEqual(split.tabs.map(\.id), [source.id, session.engineID])
        XCTAssertEqual(model.store.split(withID: split.id)?.focusTabID, session.engineID, "the Peek's pane takes the focus")
        XCTAssertTrue(model.engineHost.engine(forTabID: session.engineID, profileID: session.profileID) === peek)
    }

    func testSplitFromAFavoriteIsUnavailableAndLeavesThePeekOpen() throws {
        let model = makeModel()
        _ = try peekFromTab(model, kind: .favorite)
        XCTAssertNil(model.peekSplitAnchor)
        XCTAssertFalse(model.performPeekAction(.openInSplitView))
        XCTAssertNotNil(model.peekSession)
    }

    func testCloseDropsThePageAndShrinksBack() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        let session = try XCTUnwrap(model.peekSession)
        XCTAssertTrue(model.performPeekAction(PeekDismissal.action(for: .button(.close))))
        XCTAssertNil(model.peekSession)
        XCTAssertNil(model.engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID))
        let closing = try XCTUnwrap(model.peekClosing)
        XCTAssertEqual(closing.windowID, session.windowID)
        XCTAssertEqual(closing.origin, session.origin)
        XCTAssertFalse(model.performPeekAction(.close), "nothing left to close")
    }

    func testANewPeekReplacesTheOldOneWithoutAClose() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        let first = try XCTUnwrap(model.peekSession)
        model.showPeek(url: URL(string: "https://second.test")!)
        XCTAssertNil(model.peekClosing)
        XCTAssertNotEqual(model.peekSession?.engineID, first.engineID)
        XCTAssertNil(model.engineHost.ephemeralEngine(withID: first.engineID, profileID: first.profileID))
        XCTAssertNil(model.peekSession?.sourceTabID, "the command bar's Peek has no source tab")
    }

    func testThePeekShowsOnlyInItsWindow() {
        let model = makeModel()
        let first = SidebarWindowID(), second = SidebarWindowID()
        model.store.registerWindow(first)
        model.store.registerWindow(second)
        model.windowBecameKey(first)
        model.showPeek(url: link)
        XCTAssertEqual(model.peekSession?.windowID, first)
        XCTAssertTrue(model.showsPeek(in: first))
        XCTAssertFalse(model.showsPeek(in: second))
    }

    private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: isARepeat, keyCode: keyCode)!
    }

    func testEscapeClosesThePeek() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        XCTAssertFalse(model.handlePeekEscape(key(53, .shift)), "⇧Esc is not Esc")
        XCTAssertFalse(model.handlePeekEscape(key(53, repeat: true)))
        XCTAssertFalse(model.handlePeekEscape(key(12)))
        XCTAssertNotNil(model.peekSession)
        XCTAssertTrue(model.handlePeekEscape(key(53)))
        XCTAssertNil(model.peekSession)
        XCTAssertFalse(model.handlePeekEscape(key(53)), "with no Peek the key goes on")
    }

    func testEscapeBelongsToTheCommandBarWhileItIsOpen() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        model.isCommandBarPresented = true
        XCTAssertFalse(model.handlePeekEscape(key(53)))
        XCTAssertNotNil(model.peekSession)
    }

    func testTheAddressLineLeadsWithTheRealHost() {
        XCTAssertEqual(PeekAddress.parts(of: link).host, "peek.test")
        XCTAssertEqual(PeekAddress.parts(of: link).rest, "/page?q=1")
        XCTAssertEqual(PeekAddress.parts(of: URL(string: "http://plain.test:8080/a")!).host, "http://plain.test:8080")
        XCTAssertEqual(PeekAddress.parts(of: URL(string: "https://www.example.com/")!).host, "www.example.com", "nothing trimmed")
        let long = URL(string: "https://login.accounts.example.com.\(String(repeating: "a", count: 80)).evil.test/x")!
        XCTAssertTrue(PeekAddress.parts(of: long).host.hasSuffix("evil.test"), "a long host keeps its registrable end")
    }

    // MARK: The outside click, from the mouse-down

    private func browserWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Window base coordinates (bottom-left) for a top-left content point.
    private func location(_ point: CGPoint, in window: NSWindow) -> CGPoint {
        let content = window.contentView!
        let local = CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
        return content.convert(local, to: nil)
    }

    func testAMouseDownOnTheWashClosesThePeekAndTakesItsMouseUp() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        let window = browserWindow()
        model.peekHostWindow = window
        let size = window.contentView!.bounds.size
        let layout = model.peekLayout(in: model.peekSession?.windowID, windowSize: size)
        let wash = location(CGPoint(x: layout.card.minX - 30, y: layout.card.midY), in: window)

        XCTAssertTrue(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: wash, window: window))
        XCTAssertNil(model.peekSession)
        XCTAssertTrue(model.handlePeekMouse(type: .leftMouseUp, locationInWindow: wash, window: window), "its mouse-up goes too")
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseUp, locationInWindow: wash, window: window), "only that one")
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: wash, window: window), "no Peek, the click is the page's")
        XCTAssertFalse(model.performPeekAction(.close), "a second close does nothing")
    }

    func testARightClickOnTheWashAlsoCloses() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        let window = browserWindow()
        model.peekHostWindow = window
        let layout = model.peekLayout(in: model.peekSession?.windowID, windowSize: window.contentView!.bounds.size)
        let wash = location(CGPoint(x: layout.card.maxX + 80, y: layout.card.midY + 200), in: window)
        XCTAssertTrue(model.handlePeekMouse(type: .rightMouseDown, locationInWindow: wash, window: window))
        XCTAssertNil(model.peekSession)
        XCTAssertTrue(model.handlePeekMouse(type: .rightMouseUp, locationInWindow: wash, window: window))
    }

    func testClicksOnTheCardInAnotherWindowOrUnderTheCommandBarAreNotTheMonitors() throws {
        let model = makeModel()
        _ = try peekFromTab(model)
        let window = browserWindow()
        model.peekHostWindow = window
        let layout = model.peekLayout(in: model.peekSession?.windowID, windowSize: window.contentView!.bounds.size)
        let card = location(CGPoint(x: layout.card.midX, y: layout.card.midY), in: window)
        let wash = location(CGPoint(x: layout.card.minX - 30, y: layout.card.midY), in: window)
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: card, window: window), "inside the card")
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: wash, window: browserWindow()), "another window")
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: wash, window: nil))
        model.isCommandBarPresented = true
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseDown, locationInWindow: wash, window: window), "the command bar's click")
        model.isCommandBarPresented = false
        XCTAssertNotNil(model.peekSession, "still open")
        XCTAssertFalse(model.handlePeekMouse(type: .leftMouseUp, locationInWindow: card, window: window), "a mouse-up it did not take")
    }
}

