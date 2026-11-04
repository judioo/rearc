import Foundation
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
    func pageEnteredFullscreen(tabID: Tab.ID?, engineTabID: UInt64, windowIsFullscreen: Bool) -> [HTMLFullscreenSession.Step] {
        if let current = htmlFullscreen, current.engineTabID == engineTabID { return [] }
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
        return session.pageExitSteps
    }

    /// The user left native fullscreen while the page was still fullscreen.
    func windowExitedFullscreen() -> [HTMLFullscreenSession.Step] {
        guard let session = htmlFullscreen else { return [] }
        htmlFullscreen = nil
        return session.windowExitSteps
    }
}
