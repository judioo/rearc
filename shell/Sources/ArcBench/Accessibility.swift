import AppKit
import ApplicationServices
import Foundation

/// Accessibility reads (menus, the focused window) and the few writes the
/// harness needs: bring the target forward, press a menu item, size ReArc's
/// window. Menus are read without opening them; nothing walks into web content.
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func app(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 2)
        return element
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute, as: [AXUIElement].self) ?? []
    }

    static func title(_ element: AXUIElement) -> String? { value(element, kAXTitleAttribute, as: String.self) }

    /// `_AXUIElementGetWindow`: the CGWindowID behind an AX window (private, stable since 10.x).
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func windows(_ pid: pid_t) -> [AXUIElement] { value(app(pid), kAXWindowsAttribute, as: [AXUIElement].self) ?? [] }

    static func window(_ pid: pid_t, id: CGWindowID) -> AXUIElement? { windows(pid).first { windowID($0) == id } }

    static func focusedWindowID(_ pid: pid_t) -> CGWindowID? {
        value(app(pid), kAXFocusedWindowAttribute, as: AXUIElement.self).flatMap(windowID)
    }

    /// Frontmost app is `pid` and its key window is `windowID`.
    static func isKey(_ pid: pid_t, windowID: CGWindowID) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && focusedWindowID(pid) == windowID
    }

    /// Makes `pid` frontmost and `windowID` its main, key window.
    @discardableResult
    static func activate(_ pid: pid_t, windowID: CGWindowID) -> Bool {
        let application = app(pid)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = window(pid, id: windowID) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        for _ in 0 ..< 20 where !isKey(pid, windowID: windowID) { Thread.sleep(forTimeInterval: 0.05) }
        return isKey(pid, windowID: windowID)
    }

    // MARK: Menus

    static func menu(_ pid: pid_t, _ name: String) -> [AXUIElement] {
        guard let bar = value(app(pid), kAXMenuBarAttribute, as: AXUIElement.self),
              let item = children(bar).first(where: { title($0) == name }),
              let menu = children(item).first else { return [] }
        return children(menu)
    }

    static func menuTitles(_ pid: pid_t, _ name: String) -> [String] { menu(pid, name).compactMap(title).filter { !$0.isEmpty } }

    static func menuItem(_ pid: pid_t, _ name: String, _ itemTitle: String) -> AXUIElement? {
        menu(pid, name).first { title($0) == itemTitle }
    }

    /// The marked (✓) items of a menu.
    static func markedItems(_ pid: pid_t, _ name: String) -> [String] {
        menu(pid, name).compactMap { item in
            guard let mark = value(item, kAXMenuItemMarkCharAttribute, as: String.self), !mark.isEmpty else { return nil }
            return title(item)
        }
    }

    static func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

    enum SidebarState: String { case visible, hidden, unknown }

    /// From the View menu's Show/Hide Sidebar item, whose title flips (Arc and ReArc).
    static func sidebarState(_ pid: pid_t) -> SidebarState {
        let titles = menuTitles(pid, "View")
        if titles.contains("Hide Sidebar") { return .visible }
        if titles.contains("Show Sidebar") { return .hidden }
        return .unknown
    }

    // MARK: Window geometry

    static func setFrame(_ pid: pid_t, windowID: CGWindowID, _ frame: CGRect) -> Bool {
        guard let window = window(pid, id: windowID) else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        let a = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let b = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        return a == .success && b == .success
    }

    /// The window's close button (a fallback when ⌘W must not be posted).
    static func closeWindow(_ pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let window = window(pid, id: windowID),
              let button = value(window, kAXCloseButtonAttribute, as: AXUIElement.self) else { return false }
        return press(button)
    }
}
