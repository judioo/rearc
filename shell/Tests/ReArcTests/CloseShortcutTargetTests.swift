import AppKit
import XCTest
@testable import ReArc

/// ⌘W closes the key auxiliary window, never the tab behind it (QA-483 B8).
@MainActor
final class CloseShortcutTargetTests: XCTestCase {
    private func window(_ style: NSWindow.StyleMask, panel: Bool = false) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = panel ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
            : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testABrowserWindowClosesItsSelectedTab() {
        let browser = window([.titled, .closable, .resizable])
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: browser) { $0 === browser }, .selectedTab)
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: nil) { _ in false }, .selectedTab, "no key window")
    }

    func testAuxiliaryWindowsCloseThemselves() {
        // About (titled, closable, full-size content), Settings, Import, DevTools.
        for style: NSWindow.StyleMask in [[.titled, .closable, .fullSizeContentView], [.titled, .closable],
                                          [.titled, .closable, .miniaturizable, .resizable]] {
            XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: window(style)) { _ in false }, .keyWindow, "\(style)")
        }
    }

    func testPanelsSheetsAndBorderlessWindowsLeaveItToTheTab() {
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: window([.titled, .closable], panel: true)) { _ in false }, .selectedTab,
                       "an extension popup panel")
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: window([.borderless])) { _ in false }, .selectedTab, "the sunrise")
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: window([.titled])) { _ in false }, .selectedTab, "not closable")
        let parent = window([.titled, .closable]), sheet = window([.titled, .closable])
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }
        XCTAssertEqual(CloseShortcutTarget.resolve(keyWindow: sheet) { $0 === parent }, .selectedTab, "a sheet")
    }
}
