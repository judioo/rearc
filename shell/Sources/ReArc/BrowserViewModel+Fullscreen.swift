import AppKit
import SidebarModel

/// HTML fullscreen on the shell's window (Chromium `html_fullscreen`, ABI
/// 1.27). The page's window goes native fullscreen, and the window showing
/// the page hides its sidebar and the page card's inset; leaving restores
/// both. The window host (`ChromiumShell`) runs the native steps this
/// returns. WebKit pages use WKWebView's own fullscreen window instead.
extension BrowserViewModel {
    var htmlFullscreenTabID: Tab.ID? { htmlFullscreen?.tabID }

    /// The window shows the fullscreen page: no sidebar, no inset.
    func isHTMLFullscreen(in window: SidebarWindowID?) -> Bool {
        guard let id = htmlFullscreen?.tabID else { return false }
        if let split = activeSplit(in: window) { return split.tabs.contains { $0.id == id } }
        return selectedTab(in: window)?.id == id
    }

    /// A page entered fullscreen. `tabID` is its sidebar tab (nil for a
    /// private or Little Arc window, which only goes native fullscreen).
    /// `origin` (engine ABI 1.59) is the requesting frame's: every entry then
    /// names the site, since the hidden sidebar is where ReArc shows the URL.
    func pageEnteredFullscreen(tabID: Tab.ID?, engineTabID: UInt64, windowIsFullscreen: Bool,
                               origin: String? = nil) -> [HTMLFullscreenSession.Step] {
        if let current = htmlFullscreen, current.engineTabID == engineTabID { return [] }
        if let origin { showFullscreenHint(site: Self.displaySite(origin)) }
        let session = HTMLFullscreenSession(
            tabID: tabID,
            engineTabID: engineTabID,
            windowWasFullscreen: windowIsFullscreen,
            sidebarWasVisible: isSidebarVisible
        )
        htmlFullscreen = session
        isSidebarPeeking = false
        return session.enterSteps
    }

    /// The page left fullscreen (page, Esc, navigation, hidden, closed).
    func pageExitedFullscreen(engineTabID: UInt64) -> [HTMLFullscreenSession.Step] {
        guard let session = htmlFullscreen, session.engineTabID == engineTabID else { return [] }
        htmlFullscreen = nil
        if toast?.id == fullscreenHintID { toast = nil }
        return session.pageExitSteps
    }

    /// The user left native fullscreen while the page was still fullscreen.
    func windowExitedFullscreen() -> [HTMLFullscreenSession.Step] {
        guard let session = htmlFullscreen else { return [] }
        htmlFullscreen = nil
        return session.windowExitSteps
    }
}

extension BrowserViewModel {
    func nativeFullscreenChanged(_ fullscreen: Bool, window: NSWindow) {
        let action = fullscreenEscapes[window.windowNumber, default: FullscreenEscape()].setFullscreen(fullscreen)
        // A page's entry already showed the hint naming its site.
        let siteHintShowing = htmlFullscreen != nil && toast?.id == fullscreenHintID && toast != nil
        if action == .showHint, !siteHintShowing { showFullscreenHint() }
        if !fullscreen, toast?.id == fullscreenHintID { toast = nil }
    }

    private func showFullscreenHint(site: String? = nil) {
        let message = site.map { "\($0) is full screen. To exit, press esc" } ?? "To exit full screen, press esc"
        showToast(message, systemImage: "", keycaps: ["esc"], placement: .belowToolbar, duration: site == nil ? 2.5 : 4)
        fullscreenHintID = toast?.id
    }

    /// "bank.example" from "https://bank.example", the scheme kept for
    /// anything but https; an opaque origin ("null") is "This page". A long
    /// host is cut from the left, never losing its registrable domain (N-06).
    nonisolated static func displaySite(_ origin: String) -> String {
        guard let url = URL(string: origin), let host = url.host, !host.isEmpty else { return "This page" }
        let port = url.port.map { ":\($0)" } ?? ""
        let scheme = url.scheme == "https" ? "" : "\(url.scheme ?? "")://"
        return scheme + PageOrigin.shortenedHost(host + port, limit: 36 - scheme.count)
    }

    /// Observes the first press without taking it away from the page or a field.
    func handleFullscreenEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, !event.isARepeat,
              let window = event.window else { return false }
        let focus: FullscreenEscape.Focus = shortcutRouter.pageHasFocus(event) ? .page
            : window.firstResponder is NSText ? .text : .other
        let consumed = isCommandBarPresented || peekSession != nil || tabSwitcher != nil
            || keyLittleArcID != nil || keyPrivateWindow != nil || window is NSPanel
            || window.attachedSheet != nil || inlineRename != nil || pendingRename != nil
            || renamingSplitID != nil || themePopoverSpaceID != nil || itemIconEditorID != nil
            || spaceEditorID != nil || profileEditorRequest != nil || isAirTrafficControlPresented
            || downloads.isTrayPresented || librarySection(in: store.keyWindowID) != nil
            || (focus == .text && !findBar.isPresented)
        let fullscreen = window.styleMask.contains(.fullScreen)
        _ = fullscreenEscapes[window.windowNumber, default: FullscreenEscape()].setFullscreen(fullscreen)
        let action = fullscreenEscapes[window.windowNumber, default: FullscreenEscape()]
            .press(at: event.timestamp, consumed: consumed)
        switch action {
        case .none: return false
        case .showHint:
            showFullscreenHint()
            return !focus.takesFirstPress
        case .exit:
            if let engine = focusedEngine as? PageFullscreenControlling, engine.isPageFullscreen {
                engine.exitPageFullscreen()
            } else {
                window.toggleFullScreen(nil)
            }
            return true
        }
    }
}
