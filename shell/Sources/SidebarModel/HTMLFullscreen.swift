import Foundation

/// HTML (element) fullscreen around one page (Chromium `html_fullscreen`,
/// ABI 1.27): the window goes native fullscreen with the sidebar and the
/// page card's inset hidden, and both come back as they were when the page
/// leaves fullscreen.
public struct HTMLFullscreenSession: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case enterNativeFullscreen
        case exitNativeFullscreen
        case hideChrome
        /// Show the chrome again; `sidebarVisible` is the sidebar state before fullscreen.
        case restoreChrome(sidebarVisible: Bool)
        /// Tell the engine the host left fullscreen (`ReArcTabExitFullscreen`).
        case exitPageFullscreen
    }

    public var tabID: Tab.ID?
    /// The engine tab (Chromium tab ID, or 0 on WebKit).
    public var engineTabID: UInt64
    public var windowWasFullscreen: Bool
    public var sidebarWasVisible: Bool

    public init(tabID: Tab.ID?, engineTabID: UInt64, windowWasFullscreen: Bool, sidebarWasVisible: Bool) {
        self.tabID = tabID
        self.engineTabID = engineTabID
        self.windowWasFullscreen = windowWasFullscreen
        self.sidebarWasVisible = sidebarWasVisible
    }

    public var enterSteps: [Step] {
        windowWasFullscreen ? [.hideChrome] : [.hideChrome, .enterNativeFullscreen]
    }

    /// The page (or the engine: Esc, navigation, hiding) left fullscreen.
    public var pageExitSteps: [Step] {
        let restore = Step.restoreChrome(sidebarVisible: sidebarWasVisible)
        return windowWasFullscreen ? [restore] : [restore, .exitNativeFullscreen]
    }

    /// The user left native fullscreen (green button, ⌃⌘F) while the page was fullscreen.
    public var windowExitSteps: [Step] {
        [.restoreChrome(sidebarVisible: sidebarWasVisible), .exitPageFullscreen]
    }
}
