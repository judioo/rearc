import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Break check 2026-11-07 night, issue 11: typing straight after New Space
/// went nowhere until the name field was clicked. The page now hands the
/// field the keyboard once it is in its window. The window here is
/// borderless, far off screen and never ordered in.
@MainActor
final class SpaceCreationFocusTests: XCTestCase {
    private func openPage() throws -> (BrowserViewModel, NSWindow, NSTextField) {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        model.beginSpaceCreation()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 260, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpaceCreationPage(model: model)
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        let field = try XCTUnwrap(CommandBarOverlay.field(in: window, placeholder: SpaceCreationPage.namePlaceholder))
        return (model, window, field)
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testTypingGoesStraightToTheNameAndReturnCreates() throws {
        let (model, window, field) = try openPage()
        defer { window.close() }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field has the keyboard without a click")
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText("Work", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin()
        XCTAssertEqual(model.spaceCreation?.draft.name, "Work")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin()
        XCTAssertNil(model.spaceCreation, "Return creates the space")
        XCTAssertTrue(model.store.spaces.contains { $0.name == "Work" })
    }

    private func esc(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    /// As NSApp delivers it: Cancel's shortcut first, then the field.
    func testEscCancels() throws {
        let (model, window, field) = try openPage()
        defer { window.close() }
        XCTAssertNotNil(field.currentEditor())
        let esc = try esc(in: window)
        if !window.performKeyEquivalent(with: esc) { window.sendEvent(esc) }
        spin()
        XCTAssertNil(model.spaceCreation, "Esc cancels")
        XCTAssertEqual(model.store.spaces.map(\.name), ["Main"])
    }

    /// New Space from the command bar: the bar closing gave the keyboard
    /// back to the page, after the name field had it.
    func testTheClosingCommandBarLeavesTheNameFieldFocused() {
        let model = BrowserViewModel(store: SidebarStore(spaces: [Space(name: "Main")]), persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        XCTAssertFalse(model.sidebarFieldKeepsFocus)
        model.beginSpaceCreation()
        XCTAssertTrue(model.sidebarFieldKeepsFocus)
        model.cancelSpaceCreation()
        XCTAssertFalse(model.sidebarFieldKeepsFocus)
    }

    /// Esc that reaches the focused field itself cancels too.
    func testEscInTheFieldCancels() throws {
        let (model, window, field) = try openPage()
        defer { window.close() }
        XCTAssertNotNil(field.currentEditor())
        window.sendEvent(try esc(in: window))
        spin()
        XCTAssertNil(model.spaceCreation, "Esc cancels")
    }
}
