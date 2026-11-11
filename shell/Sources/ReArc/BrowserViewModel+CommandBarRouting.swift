import AppKit
import SidebarModel
import SwiftUI

/// Wave 26 command bar: inline domain completion, result routing on
/// ⌘↩ / ⌥↩ / ⇧↩, and the Ctrl+Tab recent-tab switcher (COMMAND-BAR §3,
/// §6.3; SIDEBAR-SPEC §4.7).
extension BrowserViewModel {

    // MARK: - Inline domain completion

    /// The domain the typed text completes to (visited hosts, then the
    /// bundled list). None after a deletion, for commands, site searches and
    /// URL prompts.
    var commandBarInlineCompletion: String? {
        commandBarInlineCache.value {
            guard isCommandBarPresented, !commandBarText.isEmpty, !commandBarText.hasPrefix(">"),
                  !commandBarSuppressesInlineCompletion, commandBarSiteSearch == nil,
                  commandBarURLIntent == nil else { return nil }
            let candidates = commandBarDomainCache.value { InlineDomainCompletion.candidates(history: visitHistory(for: store.activeProfileID)) }
            return InlineDomainCompletion.complete(commandBarText, candidates: candidates)
        }
    }

    /// The grey text after the caret.
    var commandBarInlineSuffix: String? {
        commandBarInlineCompletion.flatMap { InlineDomainCompletion.suffix(typed: commandBarText, completion: $0) }
    }

    /// Right Arrow at the end of the field takes the completion into the text.
    @discardableResult
    func acceptCommandBarInlineCompletion() -> Bool {
        guard let suffix = commandBarInlineSuffix else { return false }
        commandBarText += suffix
        return true
    }

    // MARK: - Routing

    /// Opens a command-bar page where `route` says, then closes the bar.
    func routeCommandBar(to url: URL, _ route: CommandBarRoute) {
        guard NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else {
            commandBarError = "That URL scheme is not allowed"
            return
        }
        // ⌘T's own blank tab is the new tab; with ⌘L the bar's target is a real page.
        let target = commandBarTargetID.flatMap { store.tab(withID: $0) }
        let blankTarget = target.flatMap { $0.url.absoluteString == "about:blank" ? $0 : nil }
        switch route {
        case .current:
            navigateCommandBar(to: url)
        case .newTab:
            if blankTarget != nil {
                navigateCommandBar(to: url)
            } else {
                openInNewTab(url)
            }
        case .splitView:
            let anchorID = commandBarCreatesNewTab || blankTarget != nil ? commandBarSplitAnchorID : target?.id
            guard let anchorID, let anchor = store.tab(withID: anchorID), anchor.kind != .favorite else {
                if blankTarget == nil { openInNewTab(url) } else { navigateCommandBar(to: url) }
                break
            }
            let paneID: Tab.ID
            if let blankTarget {
                store.updateTab(blankTarget.id, title: url.host() ?? "New Tab", url: url)
                paneID = blankTarget.id
            } else {
                let space = store.spaceContaining(tabID: anchorID)
                paneID = store.addTab(kind: anchor.kind == .pinned ? .pinned : .today, title: url.host() ?? "New Tab", url: url, in: space).id
            }
            if store.splitTab(paneID, with: anchorID) == nil {
                if store.isSplitFull(joining: anchorID) { showSplitFullToast() }
                store.selectTab(paneID)
            } else if let split = store.splitContaining(tabID: paneID)?.split {
                store.selectSplit(split.id, focusTabID: paneID)
            }
            loadSelectedIfNeeded()
        case .littleArc:
            openLittleArc(url: url)
            if let blankTarget {
                // The bar's empty new tab has nothing to show.
                let previous = commandBarSplitAnchorID
                deleteTab(blankTarget.id)
                if let previous, store.tab(withID: previous) != nil { store.focusTab(previous) }
                loadSelectedIfNeeded()
            }
        }
        dismissCommandBar()
    }

    // MARK: - Tab switcher (Ctrl+Tab)

    /// Ctrl+Tab / Ctrl+Shift+Tab: opens the switcher one step from the
    /// current tab, or steps it while it is open. Without Control held (the
    /// menu) it switches at once.
    func cycleRecentTabs(forward: Bool, controlHeld: Bool = NSEvent.modifierFlags.contains(.control)) {
        guard keyBrowserWindowIsFront, !isCommandBarPresented else {
            cancelTabSwitcher()
            return
        }
        PerfSignposts.interaction(.tabSwitcher, tabSwitcher == nil ? "open" : "step")
        if tabSwitcher != nil {
            tabSwitcher?.step(forward: forward)
            if !controlHeld { commitTabSwitcher() }
            return
        }
        guard let session = TabSwitcherSession(items: store.recentTabSwitcherItems(), forward: forward),
              session.items.count > 1 else { return }
        tabSwitcher = session
        if !controlHeld { commitTabSwitcher() }
    }

    /// Control released: show the highlighted tab.
    func commitTabSwitcher() {
        guard let session = tabSwitcher else { return }
        tabSwitcher = nil
        if store.focusTab(session.highlighted.id) { loadSelectedIfNeeded() }
    }

    func cancelTabSwitcher() { tabSwitcher = nil }

    func selectTabSwitcherItem(_ id: Tab.ID) {
        guard let session = tabSwitcher, session.items.contains(where: { $0.id == id }) else { return }
        tabSwitcher = nil
        if store.focusTab(id) { loadSelectedIfNeeded() }
    }

    /// One app-wide monitor sees Ctrl+Tab before the page or a menu does,
    /// and Control's release ends the switcher. It also notes each click's keys,
    /// takes Esc for the downloads tray and the Library and routes shortcuts
    /// pressed while a page has focus (`ShortcutRouter`).
    func installTabSwitcherMonitor() {
        guard tabSwitcherMonitor == nil else { return }
        tabSwitcherMonitor = ShellKeyMonitor(handle: { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                // ⌥⌘-click routing on Chromium reads this (BrowserViewModel+LittleArcChrome).
                self.noteMouseDown(modifiers: event.modifierFlags)
                return event
            }
            if self.handleFullscreenEscape(event) { return nil }
            if self.handlePeekEscape(event) { return nil }
            if self.handleTabSwitcherEvent(event) { return nil }
            if self.handleDownloadsTrayEscape(event) { return nil }
            if self.handleLibraryEscape(event, pageHasFocus: self.shortcutRouter.pageHasFocus(event)) { return nil }
            return self.shortcutRouter.handleKeyDown(event) ? nil : event
        }, onInterrupt: { [weak self] in self?.cancelTabSwitcher() })
        shortcutRouter.onPrompt = { [weak self] in self?.showShortcutPrompt($0) }
    }

    /// True when the event was the switcher's.
    func handleTabSwitcherEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A missed Control release (synthetic input, or focus lost mid-switch)
        // must not let an abandoned session take the next field's Return/Esc.
        // Use this event's flags, never the process-wide physical key state.
        guard keyBrowserWindowIsFront, !isCommandBarPresented,
              !(event.window is NSPanel), event.window?.attachedSheet == nil else {
            cancelTabSwitcher()
            return false
        }
        if event.type == .keyDown, !flags.contains(.control) {
            cancelTabSwitcher()
            return false
        }
        switch event.type {
        case .keyDown where event.keyCode == 48 && flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option):
            cycleRecentTabs(forward: !flags.contains(.shift), controlHeld: true)
            return true
        case .keyDown where event.keyCode == 53 && tabSwitcher != nil:
            cancelTabSwitcher()
            return true
        case .keyDown where event.keyCode == 36 && tabSwitcher != nil:
            commitTabSwitcher()
            return true
        case .flagsChanged where tabSwitcher != nil && !flags.contains(.control):
            commitTabSwitcher()
            return false
        case .keyDown:
            // Any other shortcut or edit belongs to its normal destination.
            cancelTabSwitcher()
            return false
        default:
            return false
        }
    }

    /// Ctrl+Tab belongs to browser windows, not private windows.
    private var keyBrowserWindowIsFront: Bool {
        keyPrivateWindow == nil && keyLittleArcID == nil
    }
}

/// App-wide shell routing outlives each switcher: it also handles the downloads
/// tray, Library and page shortcuts. Its owner removes all registrations when
/// released; focus changes cancel the session even if Control's release is lost.
final class ShellKeyMonitor {
    private let monitor: Any?
    private let observers: [NSObjectProtocol]

    init(handle: @escaping (NSEvent) -> NSEvent?, onInterrupt: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown], handler: handle)
        observers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in onInterrupt() }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
