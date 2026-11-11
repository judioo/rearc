import AppKit
import SidebarModel

/// The Peek's buttons, keys and outside clicks (`PeekDismissal`).
extension BrowserViewModel {
    /// The Peek shows in this window: the one it opened in, else the key window.
    func showsPeek(in window: SidebarWindowID?) -> Bool {
        guard let session = peekSession else { return false }
        return session.windowID == nil ? isKeyBrowserWindow(window) : session.windowID == window
    }

    /// The sidebar width the Peek is centred beside in `window`: the mini
    /// column or the full width, and while ⇧⌘S moves the edge, the edge as
    /// drawn, so the card moves with it (`SidebarWidthMorph`).
    func peekSidebarWidth(in window: SidebarWindowID?) -> Double {
        sidebarMorph(in: window)?.shown ?? Double(sidebarWidth(in: window))
    }

    /// The Peek's card and buttons in `window` (window content coordinates,
    /// top-left): centred beside a laid-out sidebar, else in the whole window;
    /// a fullscreen Peek page fills it. The overlay and the click monitor both use it.
    func peekLayout(in window: SidebarWindowID?, windowSize: CGSize) -> PeekLayout {
        let bounds = CGRect(origin: .zero, size: windowSize)
        if isPeekPageFullscreen { return PeekLayout(region: bounds, isFullscreen: true) }
        let besideSidebar = isSidebarVisible && isSidebarLaidOut && !isHTMLFullscreen(in: window)
        return PeekLayout(region: PeekLayout.region(
            windowSize: windowSize,
            sidebarWidth: besideSidebar ? peekSidebarWidth(in: window) : 0,
            sidebarOnLeft: sidebarPlacement(in: window).side == .left
        ))
    }

    /// The app's event monitor, before anything else sees a mouse-down: one
    /// outside the Peek's card in the Peek's window closes it
    /// (`PeekOutsideClick`), and that click and its mouse-up go no further.
    /// True when the event is taken.
    func handlePeekMouse(_ event: NSEvent) -> Bool {
        handlePeekMouse(type: event.type, locationInWindow: event.locationInWindow, window: event.window)
    }

    func handlePeekMouse(type: NSEvent.EventType, locationInWindow: CGPoint, window: NSWindow?) -> Bool {
        switch type {
        case .leftMouseUp, .rightMouseUp:
            guard peekSwallowsMouseUp == type else { return false }
            peekSwallowsMouseUp = nil
            return true
        case .leftMouseDown, .rightMouseDown:
            break
        default:
            return false
        }
        peekSwallowsMouseUp = nil
        // The command bar and the tab switcher sit above the Peek in its window.
        guard let session = peekSession, !isCommandBarPresented, tabSwitcher == nil,
              let window, window === peekHostWindow, let content = window.contentView else { return false }
        let local = content.convert(locationInWindow, from: nil)
        let size = content.bounds.size
        let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : size.height - local.y)
        let controls = TrafficLightPositioner.titlebarFrame(windowSize: size)
        let outcome = PeekOutsideClick.outcome(
            at: point, windowSize: size, layout: peekLayout(in: session.windowID, windowSize: size),
            sheetAttached: window.attachedSheet != nil,
            windowControls: CGRect(x: controls.minX, y: 0, width: controls.width, height: controls.height)
        )
        switch outcome {
        case .pass:
            return false
        case .closeAndPass:
            performPeekAction(.close)
            return false
        case .closeAndSwallow:
            performPeekAction(.close)
            peekSwallowsMouseUp = type == .leftMouseDown ? .leftMouseUp : .rightMouseUp
            return true
        }
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
