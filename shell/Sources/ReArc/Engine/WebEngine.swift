import Combine
import SidebarModel
import SwiftUI

/// Connection security shown by the sidebar URL field (Arc command-bar
/// placeholder lock icons). Chromium reports it through `security_state`
/// events; WebKit derives it from the URL scheme and `hasOnlySecureContent`.
enum WebSecurityState: Equatable {
    case secure
    /// http, or https with mixed content.
    case insecure
    /// Safe Browsing or certificate trouble (Chromium only).
    case dangerous
    /// Not a network page (about:, data:, file:, WebUI).
    case none
    case unknown

    /// Engine security_state level: 0 secure, 1 insecure, 2 dangerous, 3 none, 4 unknown.
    init(chromiumLevel level: UInt32) {
        switch level {
        case 0: self = .secure
        case 1: self = .insecure
        case 2: self = .dangerous
        case 3: self = .none
        default: self = .unknown
        }
    }

    static func webKit(url: URL?, hasOnlySecureContent: Bool) -> WebSecurityState {
        switch url?.scheme?.lowercased() {
        case nil: return .unknown
        case "https": return hasOnlySecureContent ? .secure : .insecure
        case "http": return .insecure
        default: return .none
        }
    }
}

/// Abstraction over the web content engine: `WKEngine` (WKWebView, the
/// default `swift run` path) or `ChromiumEngine` (the engine C ABI, in the
/// `REARC_CHROMIUM` bundle). `EngineHost` picks one at runtime.
///
/// One engine instance exists per tab, so navigation state survives tab
/// switches. Navigation state is observable on both engines so the sidebar's
/// back/forward/reload controls follow it.
protocol WebEngine: AnyObject {
    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var isLoading: Bool { get }
    /// Main-frame load progress 0…1 while loading (Chromium `load_progress`,
    /// WebKit `estimatedProgress`).
    var loadProgress: Double { get }
    /// The page's renderer is gone (Chromium `is_crashed`, WebKit web content
    /// process terminated). The tab stays; Reload brings the page back.
    var isCrashed: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var securityState: WebSecurityState { get }
    /// Site icon image bytes (Chromium: PNG from `ReArcFaviconGet`; WebKit:
    /// the page's `<link rel=icon>` or /favicon.ico). Nil until one arrives.
    var faviconData: Data? { get }
    /// The page's colour for the card toolbar and a split pane's row (its
    /// theme colour, else its top edge); nil keeps the toolbar's own look.
    /// Changes only when the colour does.
    var pageColor: PageColor? { get }

    /// Latest media snapshot from the in-page probe.
    var mediaState: WebMediaState { get }
    /// Poll-free media updates (MutationObserver + media element events).
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { get }

    /// Shift-click on in-page links posts the anchor href (nil disables delivery).
    var linkPeekHandler: ((URL) -> Void)? { get set }
    var automaticPeekSourceURL: URL? { get set }

    func load(_ url: URL)
    /// A page-sourced context-menu navigation, never a typed visit.
    func loadPageLink(_ url: URL)
    /// `ignoringCache` is the hard reload (Shift+Cmd+R).
    func reload(ignoringCache: Bool)
    func stopLoading()
    func goBack()
    func goForward()

    func setMuted(_ muted: Bool)
    func togglePlayPause()
    func skipToNextTrack()
    func skipToPreviousTrack()
    func pauseAllMedia()
    /// Puts the page's playing video in Picture in Picture (true) or brings
    /// it back (false). Chromium (ABI 1.30) uses its media session and its own
    /// floating window; WKWebView the standard PiP API, which may want a
    /// recent user gesture (WK-LIMIT).
    func setPictureInPicture(_ active: Bool)

    /// Browser page zoom, 1.0 = 100% (`PageZoom.range`).
    var zoomFactor: Double { get }
    /// Requests a zoom factor; `zoomFactor` follows when the engine applies it.
    func setZoomFactor(_ factor: Double)

    /// The SwiftUI view rendering this engine's web content, with its page prompts over it.
    func makeView() -> AnyView

    /// JavaScript dialogs, file choosers, permission and password prompts and
    /// the page menu this page raised (shown over this page only).
    var pagePrompts: PagePromptCenter { get }

    /// Replace installed boost scripts/CSS plan for this tab's web view.
    func installBoosts(_ entries: [BoostRuntimeEntry])
    /// Re-apply boost CSS on the open document (SPA / pageshow path).
    func refreshBoostsOnPage()

    /// Page screenshot for capture (visible viewport or full scrollable page).
    func captureSnapshot(scope: CaptureScope) async throws -> Data
}

extension WebEngine {
    func loadPageLink(_ url: URL) { load(url) }
    func reload() { reload(ignoringCache: false) }

    /// Loading or crashed, for the sidebar row and the content bar.
    var activity: TabActivity {
        TabActivity(
            isLoading: isLoading,
            progress: loadProgress,
            isCrashed: isCrashed,
            isDiscarded: (self as? TabDiscarding)?.isDiscarded ?? false
        )
    }
    func pictureInPicture() { setPictureInPicture(true) }
}

/// Engines that close a page through its beforeunload handler ("Leave
/// site?") before the shell drops the tab.
protocol PageClosing: AnyObject {
    /// Starts a normal close. False when the engine cannot (the shell then
    /// closes right away); otherwise `completion` runs once: true when the
    /// page closed, false when the user chose to stay.
    func requestPageClose(_ completion: @escaping (Bool) -> Void) -> Bool
}

/// Engines whose zoom can change outside the shell (Chromium shares zoom per
/// host within a profile) re-read it when their tab is selected.
protocol PageZoomRefreshing: AnyObject {
    @discardableResult
    func refreshZoomFactor() -> Double?
}

/// Opens and closes Little Arc and private windows on behalf of the view
/// model when the app runs without SwiftUI scenes (the Chromium path owns its
/// NSWindows).
protocol BrowserWindowPresenting: AnyObject {
    func presentLittleArcWindow(_ id: LittleArcWindow.ID)
    func dismissLittleArcWindow(_ id: LittleArcWindow.ID)
    func presentPrivateWindow(_ window: PrivateWindowModel)
    /// A tab's DevTools in their own window (popped out from the docked pane).
    func presentDevToolsWindow(for tabID: Tab.ID)
    func dismissDevToolsWindow(for tabID: Tab.ID)
    /// Brings a browser window forward and makes it key (Little Arc's Open in
    /// <Space> lands in the last focused browser window, not whichever comes next).
    func focusBrowserWindow(_ id: SidebarWindowID)
    /// File › New Window: another browser window, key, on the key window's space.
    func presentBrowserWindow()
    /// A page asks "Leave site?": windows a quit hid come back to show it.
    func revealForPagePrompt()
}

extension BrowserWindowPresenting {
    func presentDevToolsWindow(for tabID: Tab.ID) {}
    func dismissDevToolsWindow(for tabID: Tab.ID) {}
    func focusBrowserWindow(_ id: SidebarWindowID) {}
    func presentBrowserWindow() {}
    func revealForPagePrompt() {}
}

/// What an unload request did.
enum DiscardOutcome: Equatable {
    case discarded
    /// The page is visible, loading, playing or guarded; it can be tried again later.
    case refusedForNow
    /// The engine cannot discard this page (no `tab_discard`, no tab).
    case unsupported
}

/// Engines that can unload a hidden page and keep its tab, history and
/// scripts (Chromium `tab_discard`, ABI 1.25). The page reloads when it is
/// shown again. WebKit has no such call: the shell drops its engine instead.
protocol TabDiscarding: AnyObject {
    var isDiscarded: Bool { get }
    func discard() -> DiscardOutcome
}

/// Engines whose pages can ask for fullscreen through the shell window
/// (Chromium `html_fullscreen`, ABI 1.27; WKWebView runs its own fullscreen window).
protocol PageFullscreenControlling: AnyObject {
    var isPageFullscreen: Bool { get }
    /// The host left fullscreen: ask the page to leave too.
    func exitPageFullscreen()
}
