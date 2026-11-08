import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// No screen input: events go directly through the switcher's monitor handler,
/// then (for the hosted cases) to an unordered window far off screen.
@MainActor
final class TabSwitcherRecoveryTests: XCTestCase {
    private func model() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let a = store.addTab(kind: .today, title: "Alpha", url: URL(string: "about:blank")!)
        let b = store.addTab(kind: .today, title: "Beta", url: URL(string: "about:blank")!)
        store.selectTab(a.id)
        store.selectTab(b.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-switcher-\(UUID())")
        let model = BrowserViewModel(store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        let services = WebKitCommandBarServices(defaults: UserDefaults(suiteName: "rearc-switcher-\(UUID())")!)
        services.preference.suggestionsEnabled = false
        model.commandBarServices = services
        return model
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
                     in window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func openSwitcher(_ model: BrowserViewModel) {
        XCTAssertTrue(model.handleTabSwitcherEvent(key(48, "\t", .control)))
        XCTAssertNotNil(model.tabSwitcher)
        // Deliberately never send Control's flagsChanged / key-up.
    }

    func testMissingControlReleaseDoesNotTakeTheNextUnmodifiedKey() {
        for (code, characters) in [(UInt16(36), "\r"), (53, "\u{1b}"), (51, "\u{7f}"), (0, "a"), (48, "\t")] {
            let model = model()
            let selected = model.store.selectedTabID
            openSwitcher(model)
            XCTAssertFalse(model.handleTabSwitcherEvent(key(code, characters)), "key \(code) must pass through")
            XCTAssertNil(model.tabSwitcher, "key \(code) ends the abandoned switcher")
            XCTAssertEqual(model.store.selectedTabID, selected, "an interrupted switch is cancelled")
        }
    }

    func testUnrelatedShortcutCancelsEvenIfControlIsStillHeld() {
        let model = model()
        openSwitcher(model)
        XCTAssertFalse(model.handleTabSwitcherEvent(key(37, "l", [.command, .control])))
        XCTAssertNil(model.tabSwitcher)
    }

    func testOpeningEitherCommandBarCancelsWithoutWaitingForAKey() {
        for location in [false, true] {
            let model = model()
            let selected = model.store.selectedTabID
            openSwitcher(model)
            if location { model.focusLocation() } else { model.newTab() }
            XCTAssertTrue(model.isCommandBarPresented)
            XCTAssertNil(model.tabSwitcher)
            XCTAssertEqual(model.store.selectedTabID, selected)
            for (code, characters) in [(UInt16(36), "\r"), (53, "\u{1b}"), (51, "\u{7f}")] {
                XCTAssertFalse(model.handleTabSwitcherEvent(key(code, characters)))
            }
        }
    }

    func testChangingBrowserWindowCancelsTheSwitch() {
        let model = model()
        let first = SidebarWindowID(), second = SidebarWindowID()
        model.store.registerWindow(first)
        model.store.registerWindow(second)
        model.windowBecameKey(first)
        openSwitcher(model)
        model.windowBecameKey(second)
        XCTAssertNil(model.tabSwitcher)
    }

    func testFocusLossAndWindowNotificationsCancelWithoutControlRelease() {
        let model = model()
        model.installTabSwitcherMonitor()
        let monitor = model.tabSwitcherMonitor
        model.installTabSwitcherMonitor()
        XCTAssertTrue((monitor as AnyObject?) === (model.tabSwitcherMonitor as AnyObject?))
        defer {
            // The app-wide monitor also routes downloads/Library/menu keys;
            // closing a switcher must keep that routing installed.
            model.tabSwitcherMonitor = nil
        }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            openSwitcher(model)
            NotificationCenter.default.post(name: name, object: name == NSApplication.didResignActiveNotification ? NSApp : window)
            XCTAssertNil(model.tabSwitcher, "\(name.rawValue) cancels the abandoned switcher")
        }
    }

    func testMenuSwitchCommitsAnExistingSessionWithoutControl() {
        let model = model()
        openSwitcher(model)
        model.cycleRecentTabs(forward: true, controlHeld: false)
        XCTAssertNil(model.tabSwitcher)
    }

    func testLiveSwitcherReturnStillCommitsAndEscapeStillCancels() {
        let model = model()
        let selected = model.store.selectedTabID
        openSwitcher(model)
        let highlighted = model.tabSwitcher?.highlighted.id
        XCTAssertTrue(model.handleTabSwitcherEvent(key(36, "\r", .control)))
        XCTAssertNil(model.tabSwitcher)
        XCTAssertEqual(model.store.selectedTabID, highlighted)
        openSwitcher(model)
        XCTAssertTrue(model.handleTabSwitcherEvent(key(53, "\u{1b}", .control)))
        XCTAssertNil(model.tabSwitcher)
        XCTAssertEqual(model.store.selectedTabID, highlighted)
        XCTAssertNotEqual(selected, highlighted)
        // No hidden session can take a second Return/Esc, even with Control.
        XCTAssertFalse(model.handleTabSwitcherEvent(key(36, "\r", .control)))
        XCTAssertFalse(model.handleTabSwitcherEvent(key(53, "\u{1b}", .control)))
    }

    func testReleasingMonitorRemovesItsEventAndNotificationRegistrations() {
        var keys = 0, interruptions = 0
        var monitor: ShellKeyMonitor? = ShellKeyMonitor(handle: { event in
            keys += 1
            return nil // Keep these process-local events out of normal AppKit dispatch.
        }, onInterrupt: { interruptions += 1 })
        withExtendedLifetime(monitor) {
            NSApp.sendEvent(key(0, "a"))
            XCTAssertEqual(keys, 1)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            XCTAssertEqual(interruptions, 1)
        }
        monitor = nil
        // A remaining observer would call the strongly captured test closure.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(interruptions, 1)
        NSApp.sendEvent(key(0, "a"))
        XCTAssertEqual(keys, 1)
    }

    private func hostedCommandBar() throws -> (BrowserViewModel, NSWindow, NSTextView) {
        let model = model()
        openSwitcher(model)
        model.newTab()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CommandBarContainer(model: model, width: CommandBarOverlay.arcWidth)
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let field = try XCTUnwrap(CommandBarOverlay.field(in: window, placeholder: "Search or Enter URL…"))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (model, window, editor)
    }

    func testHostedCommandBarDeleteAndReturnAfterMissingControlRelease() throws {
        let (model, window, editor) = try hostedCommandBar()
        defer { window.close() }
        let selected = model.store.selectedTabID
        editor.insertText("alphax", replacementRange: NSRange(location: NSNotFound, length: 0))
        func send(_ event: NSEvent) {
            if !model.handleTabSwitcherEvent(event) { window.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        send(key(51, "\u{7f}", in: window))
        XCTAssertEqual(model.commandBarText, "alpha", "Delete edits the actual field")
        let target = try XCTUnwrap(model.commandBarResults.first { $0.kind == .openTab }?.tabID)
        send(key(36, "\r", in: window))
        XCTAssertFalse(model.isCommandBarPresented, "the first Return submits")
        XCTAssertEqual(model.store.selectedTabID, target)
        XCTAssertNotEqual(target, selected)
    }

    func testHostedCommandBarEscapeAfterMissingControlRelease() throws {
        let (model, window, _) = try hostedCommandBar()
        defer { window.close() }
        let selected = model.store.selectedTabID
        let escape = key(53, "\u{1b}", in: window)
        if !model.handleTabSwitcherEvent(escape), !window.performKeyEquivalent(with: escape) {
            window.sendEvent(escape)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.isCommandBarPresented, "the first Esc dismisses the actual bar")
        XCTAssertEqual(model.store.selectedTabID, selected)
    }
}
