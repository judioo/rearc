import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Break check 2026-11-08: ↓ then Return in the command bar ran the first
/// row, not the highlighted one. The field writes its unchanged text back on
/// Return, and any write moved the highlight to the top. The bar is in a
/// borderless window far off screen, never ordered in, and gets its keys
/// through the window as AppKit delivers them.
@MainActor
final class CommandBarHighlightReturnTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testReturnRunsTheHighlightedRow() throws {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let first = store.addTab(kind: .today, title: "Tea Alpha", url: URL(string: "https://alpha.test")!)
        let second = store.addTab(kind: .today, title: "Tea Beta", url: URL(string: "https://beta.test")!)
        let blank = store.addTab(kind: .today, title: "Blank", url: URL(string: "about:blank")!)
        store.selectTab(blank.id)
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        let services = WebKitCommandBarServices(defaults: UserDefaults(suiteName: "rearc-highlight-\(UUID())")!)
        services.preference.suggestionsEnabled = false
        model.commandBarServices = services
        model.isCommandBarPresented = true

        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CommandBarContainer(model: model, width: CommandBarOverlay.arcWidth)
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        let field = try XCTUnwrap(CommandBarOverlay.field(in: window, placeholder: "Search or Enter URL…"))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("tea", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin()
        XCTAssertEqual(model.commandBarText, "tea")

        let tabs = model.commandBarResults.filter { $0.kind == .openTab }.compactMap(\.tabID)
        XCTAssertEqual(Set(tabs), [first.id, second.id])
        window.sendEvent(try key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), in: window))
        spin()
        XCTAssertEqual(model.commandBarHighlightedIndex, 1)
        let highlighted = try XCTUnwrap(model.commandBarResults[1].tabID)

        window.sendEvent(try key(36, "\r", in: window))
        spin()
        XCTAssertEqual(store.selectedTabID, highlighted, "Return runs the highlighted row")
    }

    func testOnlyAnEditMovesTheHighlightToTheTop() {
        let model = Perf2PipelineTests.model()
        model.commandBarText = "design"
        model.moveCommandBarHighlight(by: 2)
        XCTAssertEqual(model.commandBarHighlightedIndex, 2)
        model.commandBarText = "design"
        XCTAssertEqual(model.commandBarHighlightedIndex, 2)
        model.commandBarText = "design n"
        XCTAssertEqual(model.commandBarHighlightedIndex, 0)
    }
}
