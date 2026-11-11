import AppKit
import SidebarModel

/// The Peek's buttons, keys and outside clicks (`PeekDismissal`).
extension BrowserViewModel {
    /// The Peek shows in this window: the one it opened in, else the key window.
    func showsPeek(in window: SidebarWindowID?) -> Bool {
        guard let session = peekSession else { return false }
        return session.windowID == nil ? isKeyBrowserWindow(window) : session.windowID == window
    }

    /// The Peek's page is fullscreen: the card fills the window, with no chrome.
    var isPeekPageFullscreen: Bool {
        (peekEngine as? PageFullscreenControlling)?.isPageFullscreen ?? false
    }

    /// Runs what `PeekDismissal` decided; false when nothing happened.
    @discardableResult
    func performPeekAction(_ action: PeekAction) -> Bool {
        guard peekSession != nil else { return false }
        switch action {
        case .none:
            return false
        case .close:
            dismissPeek()
        case .expandToTab:
            peekOpenInFullTab()
        case .openInSplitView:
            guard peekSplitAnchor != nil else { return false }
            peekOpenInSplitView()
        }
        return true
    }

    /// Esc closes the Peek wherever the keys are in its window, its own page
    /// included, as in Arc. The page keeps Esc while it is fullscreen or shows
    /// a prompt; the command bar, sheets, panels and shell text fields keep theirs.
    func handlePeekEscape(_ event: NSEvent) -> Bool {
        guard peekSession != nil, event.type == .keyDown, event.keyCode == 53, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !isCommandBarPresented, showsPeek(in: store.keyWindowID) else { return false }
        if let window = event.window {
            // Another window's Esc (a Little ReArc, Settings) is its own.
            if let host = peekHostWindow, window !== host { return false }
            if window is NSPanel || window.attachedSheet != nil || window.firstResponder is NSText { return false }
        }
        let input = PeekInput.escape(pageFullscreen: isPeekPageFullscreen,
                                     promptOpen: peekEngine?.pagePrompts.hasPendingPrompt ?? false)
        return performPeekAction(PeekDismissal.action(for: input))
    }

    /// ⌘O, Arc's "Open Little Arc or Peek in…": the Peek, else the key Little ReArc, moves into a tab.
    func openLittleArcOrPeekInSpace() {
        if showsPeek(in: store.keyWindowID) {
            performPeekAction(PeekDismissal.action(for: .expandShortcut))
        } else if let id = keyLittleArcID {
            promoteLittleArcWindow(id)
        }
    }
}
