import Combine
import SidebarModel
import SwiftUI

/// Abstraction over the web content engine. Today this is backed by
/// WKWebView; when `engine/` lands, a Chromium-backed implementation can
/// conform to this protocol and drop in without touching the chrome.
///
/// One engine instance exists per tab, so navigation state survives tab
/// switches.
protocol WebEngine: AnyObject {
    var currentURL: URL? { get }
    var pageTitle: String? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    /// Latest media snapshot from the in-page probe.
    var mediaState: WebMediaState { get }
    /// Poll-free media updates (MutationObserver + media element events).
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { get }

    /// Shift-click on in-page links posts the anchor href (nil disables delivery).
    var linkPeekHandler: ((URL) -> Void)? { get set }

    func load(_ url: URL)
    func reload()
    func goBack()
    func goForward()

    func setMuted(_ muted: Bool)
    func togglePlayPause()
    func skipToNextTrack()
    func skipToPreviousTrack()
    func pauseAllMedia()
    /// Best-effort PiP; WKWebView may reject without a user gesture (WK-LIMIT).
    func pictureInPicture()

    /// Browser page zoom, 1.0 = 100% (`PageZoom.range`).
    var zoomFactor: Double { get }
    /// Requests a zoom factor; `zoomFactor` follows when the engine applies it.
    func setZoomFactor(_ factor: Double)

    /// The SwiftUI view rendering this engine's web content.
    func makeView() -> AnyView

    /// Replace installed boost scripts/CSS plan for this tab's web view.
    func installBoosts(_ entries: [BoostRuntimeEntry])
    /// Re-apply boost CSS on the open document (SPA / pageshow path).
    func refreshBoostsOnPage()

    /// Page screenshot for capture (visible viewport or full scrollable page).
    func captureSnapshot(scope: CaptureScope) async throws -> Data
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
}
