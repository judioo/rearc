import AppKit
import SidebarModel
import WebKit

/// Wave 30: Arc's shortcut rule while a web page has keyboard focus
/// (`ShortcutRouting`, docs/SHORTCUTS.md "Routing").
///
/// Chromium's RenderWidgetHostViewCocoa answers `performKeyEquivalent:` with
/// YES for every Command key while it is first responder, and AppKit asks the
/// key window's views before the main menu, so the menu never saw ⌘L, ⌘S or
/// ⇧⌘C; the page's unhandled keys were dropped. The app-wide key monitor
/// (installed with the tab switcher's) runs before that dispatch:
/// - an Arc-wins key goes straight to the main menu and never reaches the page;
/// - every other key goes to the page, and with ABI 1.42 the engine reports
///   whether the page consumed it (`pageVerdict`): an unconsumed key runs the
///   menu's shortcut; a consumed website-first key shows Arc's "again" prompt,
///   and pressing it again within the prompt runs Arc's action.
/// WebKit hands unconsumed keys back to the menu itself, so it needs no verdicts.
final class ShortcutRouter {
    struct PendingKey {
        let event: NSEvent
        let shortcut: ArcShortcut?
        let at: Date
    }

    var arming = ShortcutPromptArming()
    /// Chromium reports page verdicts (`key_equivalent_events`); without them an
    /// unconsumed key stays lost, as before ABI 1.42.
    var awaitsPageVerdicts = false
    /// Off: AppKit's own dispatch (the self-test's before-fix check).
    var isEnabled = true
    /// The prompt for a consumed website-first key.
    var onPrompt: ((ArcShortcut) -> Void)?
    /// Runs a key's menu item; tests replace it.
    var performMenuKey: (NSEvent) -> Bool = { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false }
    /// Whether a page has keyboard focus in the event's window; tests replace it.
    var pageHasFocus: (NSEvent) -> Bool = { event in
        guard let window = event.window, !(window is NSPanel) else { return false }
        return ShortcutRouter.isWebContent(window.firstResponder)
    }
    private(set) var pending: [PendingKey] = []
    /// Recent decisions, newest last (the self-test reads them).
    private(set) var history: [String] = []

    /// A verdict arrives within milliseconds; older keys were never forwarded.
    static let pendingLifetime: TimeInterval = 2

    /// True when it took the key away from the page.
    func handleKeyDown(_ event: NSEvent, now: Date = Date()) -> Bool {
        guard isEnabled, event.type == .keyDown, let (key, modifiers) = Self.combination(for: event),
              modifiers.contains(.command) || modifiers.contains(.control), pageHasFocus(event) else { return false }
        let shortcut = ArcShortcuts.binding(for: key, modifiers: modifiers)
        let armed = shortcut.map { arming.isArmed($0.id, now: now) } ?? false
        switch ShortcutRouting.route(shortcut, armed: armed) {
        case .browser:
            arming.disarm()
            let taken = performMenuKey(event)
            note("\(modifiers.display + key.display) browser\(armed ? " (second press)" : "") \(taken ? "ran" : "no menu item")")
            return taken
        case .page:
            guard awaitsPageVerdicts else { return false }
            pending.removeAll { now.timeIntervalSince($0.at) > Self.pendingLifetime }
            pending.append(PendingKey(event: event, shortcut: shortcut, at: now))
            return false
        }
    }

    /// The page's verdict on a key it was given (Chromium, ABI 1.42).
    func pageVerdict(keyCode: UInt16, modifiers: ShortcutModifiers, consumed: Bool) {
        guard let index = pending.firstIndex(where: {
            $0.event.keyCode == keyCode && Self.modifiers(of: $0.event.modifierFlags) == modifiers
        }) else { return }
        let key = pending[index]
        pending.removeSubrange(0 ... index)
        let label = Self.modifiers(of: key.event.modifierFlags).display + (Self.combination(for: key.event)?.0.display ?? "?")
        switch ShortcutRouting.verdict(key.shortcut, consumedByPage: consumed) {
        case .perform:
            let taken = performMenuKey(key.event)
            note("\(label) page passed, \(taken ? "ran" : "no menu item")")
        case .prompt:
            guard let shortcut = key.shortcut else { return }
            arming.arm(shortcut.id)
            onPrompt?(shortcut)
            note("\(label) page consumed, prompt")
        case .none:
            note("\(label) page consumed")
        }
    }

    private func note(_ entry: String) {
        history.append(entry)
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    // MARK: Keys

    static func modifiers(of flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// The key as Arc's table names it: special keys by key code, others by
    /// the current layout's unmodified character.
    static func combination(for event: NSEvent) -> (ShortcutKey, ShortcutModifiers)? {
        let modifiers = modifiers(of: event.modifierFlags)
        switch event.keyCode {
        case 123: return (.leftArrow, modifiers)
        case 124: return (.rightArrow, modifiers)
        case 125: return (.downArrow, modifiers)
        case 126: return (.upArrow, modifiers)
        case 48: return (.tab, modifiers)
        case 53: return (.escape, modifiers)
        case 49: return (.space, modifiers)
        case 111: return (.function(12), modifiers)
        default: break
        }
        guard let base = event.characters(byApplyingModifiers: [])?.lowercased(), let character = base.first,
              base.count == 1 else { return nil }
        return (.character(character), modifiers)
    }

    /// Page content: Chromium's render widget view (pages, DevTools) or a WKWebView.
    static func isWebContent(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate is WKWebView { return true }
            if NSStringFromClass(type(of: candidate)).contains("RenderWidgetHostViewCocoa") { return true }
            current = candidate.superview
        }
        return false
    }
}

extension BrowserViewModel {
    /// Arc's "again" prompt; the second press must come while it shows.
    func showShortcutPrompt(_ shortcut: ArcShortcut) {
        showToast(ShortcutRouting.promptMessage(for: shortcut), systemImage: "keyboard", duration: ShortcutPromptArming.window)
    }
}
