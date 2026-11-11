#if REARC_CHROMIUM
import AppKit

/// Synthesized input shared by the self-test and the bench.
///
/// `appKit` posts events to the app's queue, so they take AppKit's whole path
/// (local monitors, the key window's views, then the main menu). Without a key
/// window (a locked screen) AppKit drops posted keys, so `direct` makes the
/// same calls in the same order: the app's monitor, then Chromium's own
/// `keyEvent:wasKeyEquivalent:YES` on the page's view (what its
/// performKeyEquivalent: does once its key-window check passes), or the menu
/// and then the first responder for a native view (Esc in a field as its key
/// binding, cancelOperation:).
@MainActor
enum ShellInput {
    enum Delivery: String {
        case appKit = "appkit-event"
        case direct = "direct-entry"
    }

    /// Synthesized input reaches the renderer only while the app is active and the window key and visible.
    static func deliverable(_ window: NSWindow) -> Bool {
        NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    static func keyEvent(_ type: NSEvent.EventType, _ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                         in window: NSWindow, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: timestamp,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    /// Presses and releases a key; returns the key-down's timestamp.
    @discardableResult
    static func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow,
                      model: BrowserViewModel, delivery: Delivery) -> TimeInterval {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = keyEvent(.keyDown, characters, keyCode: keyCode, flags, in: window, timestamp: timestamp),
              let up = keyEvent(.keyUp, characters, keyCode: keyCode, flags, in: window, timestamp: timestamp) else { return timestamp }
        PerfSignposts.interactionEvent("InputReceived", "key \(characters) flags \(flags.rawValue) at \(timestamp)")
        switch delivery {
        case .appKit:
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        case .direct:
            if model.handleTabSwitcherEvent(down)
                || model.handlePeekEscape(down)
                || model.handleDownloadsTrayEscape(down)
                || model.handleLibraryEscape(down, pageHasFocus: model.shortcutRouter.pageHasFocus(down))
                || model.shortcutRouter.handleKeyDown(down) { return timestamp }
            if let view = window.firstResponder as? NSView, ShortcutRouter.isWebContent(view) {
                let selector = NSSelectorFromString("keyEvent:wasKeyEquivalent:")
                guard view.responds(to: selector) else {
                    view.keyDown(with: down)
                    return timestamp
                }
                typealias KeyEvent = @convention(c) (AnyObject, Selector, NSEvent, Bool) -> Void
                let send = unsafeBitCast(view.method(for: selector), to: KeyEvent.self)
                send(view, selector, down, !flags.intersection([.command, .control]).isEmpty)
                send(view, selector, up, false)
            } else if NSApp.mainMenu?.performKeyEquivalent(with: down) ?? false {
                return timestamp
            } else if keyCode == 53, let field = window.firstResponder as? NSTextView {
                // Esc's key binding, as interpretKeyEvents: sends it (the input
                // context is inactive without a key window).
                field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            } else {
                window.firstResponder?.keyDown(with: down)
            }
        }
        return timestamp
    }

    /// Releases every modifier (⌃Tab's end); returns the event's timestamp.
    @discardableResult
    static func releaseModifiers(in window: NSWindow, model: BrowserViewModel, delivery: Delivery) -> TimeInterval {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: timestamp,
                                           windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: 59) else { return timestamp }
        switch delivery {
        case .appKit: NSApp.postEvent(event, atStart: false)
        case .direct: _ = model.handleTabSwitcherEvent(event)
        }
        return timestamp
    }

    /// Posts a mouse move at a window point; returns its timestamp. A real
    /// move also shows a cursor that typing hid, and SwiftUI drops hover
    /// while the cursor is hidden; a posted move does not, so this does.
    @discardableResult
    static func moveMouse(to point: NSPoint, in window: NSWindow) -> TimeInterval {
        let timestamp = ProcessInfo.processInfo.systemUptime
        NSCursor.setHiddenUntilMouseMoves(false)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: timestamp,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            PerfSignposts.interactionEvent("InputReceived", "mouseMoved \(point.x),\(point.y) at \(timestamp)")
            NSApp.postEvent(event, atStart: false)
        }
        return timestamp
    }
}
#endif
