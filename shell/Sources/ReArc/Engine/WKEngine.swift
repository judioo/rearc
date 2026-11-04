import AppKit
import Combine
import SidebarModel
import SwiftUI
import WebKit

private final class LinkPeekMessageHandler: NSObject, WKScriptMessageHandler {
    var onURL: ((URL) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == LinkPeekMessageHandler.handlerName,
              let href = message.body as? String,
              let url = URL(string: href) else { return }
        onURL?(url)
    }

    static let handlerName = "rearcLinkPeek"
}

private final class MediaStateMessageHandler: NSObject, WKScriptMessageHandler {
    var onState: ((WebMediaState) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == MediaStateMessageHandler.handlerName,
              let body = message.body as? [String: Any] else { return }
        let state = WebMediaState(
            isPlaying: body["isPlaying"] as? Bool ?? false,
            isPaused: body["isPaused"] as? Bool ?? false,
            isAudible: body["isAudible"] as? Bool ?? false,
            title: body["title"] as? String,
            artist: body["artist"] as? String,
            canPictureInPicture: body["canPictureInPicture"] as? Bool ?? false,
            isPictureInPicture: body["isPictureInPicture"] as? Bool ?? false
        )
        onState?(state)
    }

    static let handlerName = "rearcMediaState"
}

/// WKWebView-backed stand-in for the real Chromium engine.
@Observable
final class WKEngine: NSObject, WebEngine {
    /// Sign-in requests are numbered per process (the sheet keys on the ID).
    static var nextAuthChallengeID: UInt64 = 0
    private static let linkPeekScriptSource = """
    document.addEventListener('click', function(e) {
      if (!e.shiftKey) return;
      var link = e.target.closest('a');
      if (!link || !link.href) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      window.webkit.messageHandlers.\(LinkPeekMessageHandler.handlerName).postMessage(link.href);
    }, true);
    """

    private static let mediaProbeScriptSource = """
    (function() {
      var handlerName = '\(MediaStateMessageHandler.handlerName)';
      function mediaSessionMeta() {
        try {
          var ms = navigator.mediaSession;
          if (!ms || !ms.metadata) return { title: null, artist: null };
          return {
            title: ms.metadata.title || null,
            artist: ms.metadata.artist || null
          };
        } catch (e) {
          return { title: null, artist: null };
        }
      }
      function scan() {
        var media = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
        var isPlaying = false, isPaused = false, isAudible = false, canPiP = false;
        for (var i = 0; i < media.length; i++) {
          var el = media[i];
          if (!el.paused && !el.ended) {
            isPlaying = true;
            if (!el.muted && el.volume > 0) isAudible = true;
          } else if (el.paused && !el.ended && el.currentTime > 0) {
            isPaused = true;
          }
          if (el.tagName === 'VIDEO' && el.disablePictureInPicture !== true) {
            canPiP = true;
          }
        }
        var meta = mediaSessionMeta();
        var inPiP = !!document.pictureInPictureElement || media.some(function(el) {
          return el.webkitPresentationMode === 'picture-in-picture';
        });
        var payload = {
          isPlaying: isPlaying,
          isPaused: !isPlaying && isPaused,
          isAudible: isAudible,
          title: meta.title,
          artist: meta.artist,
          canPictureInPicture: canPiP,
          isPictureInPicture: inPiP
        };
        if (window.webkit && window.webkit.messageHandlers[handlerName]) {
          window.webkit.messageHandlers[handlerName].postMessage(payload);
        }
      }
      function attach(el) {
        ['play', 'pause', 'ended', 'volumechange', 'loadeddata', 'enterpictureinpicture',
         'leavepictureinpicture', 'webkitpresentationmodechanged'].forEach(function(ev) {
          el.addEventListener(ev, scan);
        });
      }
      Array.prototype.slice.call(document.querySelectorAll('video, audio')).forEach(attach);
      var mo = new MutationObserver(function(muts) {
        muts.forEach(function(m) {
          Array.prototype.forEach.call(m.addedNodes, function(n) {
            if (n && (n.tagName === 'VIDEO' || n.tagName === 'AUDIO')) attach(n);
            if (n && n.querySelectorAll) {
              Array.prototype.slice.call(n.querySelectorAll('video, audio')).forEach(attach);
            }
          });
        });
        scan();
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });
      if (navigator.mediaSession) {
        try {
          var desc = Object.getOwnPropertyDescriptor(MediaMetadata.prototype, 'title');
          if (desc && desc.set) {
            var origSet = desc.set;
            desc.set = function(v) { origSet.call(this, v); scan(); };
            Object.defineProperty(MediaMetadata.prototype, 'title', desc);
          }
        } catch (e) {}
      }
      window.__rearcMediaControl = {
        setMuted: function(m) {
          document.querySelectorAll('video, audio').forEach(function(el) { el.muted = m; });
          scan();
        },
        togglePlayPause: function() {
          var els = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
          var playing = els.some(function(el) { return !el.paused && !el.ended; });
          els.forEach(function(el) {
            if (playing) { if (!el.paused) el.pause(); }
            else { el.play().catch(function(){}); }
          });
          scan();
        },
        pauseAll: function() {
          document.querySelectorAll('video, audio').forEach(function(el) { el.pause(); });
          scan();
        },
        skipNext: function() {
          var ev = new KeyboardEvent('keydown', { key: 'MediaTrackNext', code: 'MediaTrackNext', bubbles: true });
          document.dispatchEvent(ev);
          var btn = document.querySelector(
            'button[aria-label*="Next" i], button[title*="Next" i], .ytp-next-button, [data-action="next"]'
          );
          if (btn) btn.click();
        },
        skipPrevious: function() {
          var ev = new KeyboardEvent('keydown', { key: 'MediaTrackPrevious', code: 'MediaTrackPrevious', bubbles: true });
          document.dispatchEvent(ev);
          var btn = document.querySelector(
            'button[aria-label*="Previous" i], button[title*="Previous" i], .ytp-prev-button, [data-action="previous"]'
          );
          if (btn) btn.click();
        },
        requestPiP: function() {
          var videos = Array.prototype.slice.call(document.querySelectorAll('video'))
            .filter(function(v) { return !v.paused && !v.ended; });
          if (!videos.length) return;
          videos.sort(function(a, b) {
            return (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight);
          });
          var video = videos[0];
          if (video.requestPictureInPicture) {
            video.requestPictureInPicture().catch(function(){});
          } else if (video.webkitSupportsPresentationMode &&
                     video.webkitSupportsPresentationMode('picture-in-picture')) {
            video.webkitSetPresentationMode('picture-in-picture');
          }
        },
        exitPiP: function() {
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture().catch(function(){});
          }
          document.querySelectorAll('video').forEach(function(v) {
            if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
          });
        },
        meetAutoPiP: function() {
          if (!/meet\\.google\\.com$/i.test(location.hostname) &&
              !/\\.meet\\.google\\.com$/i.test(location.hostname)) return;
          var pip = document.querySelector('[data-pip-button], [aria-label*="Picture in picture" i], button[jsname="r8qRAd"]');
          if (pip) pip.click();
        }
      };
      scan();
    })();
    """

    let profileContext: EngineProfileContext

    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var loadProgress: Double = 0
    private(set) var isCrashed = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var securityState: WebSecurityState = .unknown
    private(set) var faviconData: Data?

    let webView: WKWebView
    /// KVO on the web view keeps the observable navigation state current
    /// (WKWebView's own properties are not @Observable).
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    /// Page URL the current `faviconData` belongs to.
    @ObservationIgnored private var faviconPageURL: URL?
    private let linkPeekBridge = LinkPeekMessageHandler()
    private let mediaBridge = MediaStateMessageHandler()
    private let boostPageshowBridge = BoostPageshowHandler()
    private let boostEditorBridge = BoostEditorMessageHandler()
    private let contextMenuBridge = ContextMenuMessageHandler()
    private let printBridge = PrintRequestMessageHandler()
    /// Dialogs, open panels, media permissions and the page menu (WKUIDelegate).
    let pagePrompts = PagePromptCenter()
    @ObservationIgnored private var lastPromptID: UInt64 = 0
    private let mediaStateSubject = CurrentValueSubject<WebMediaState, Never>(.silent)
    private var boostEntries: [BoostRuntimeEntry] = []
    private var installedScriptPackageIDs: Set<UUID> = []
    private var editorBridgeInstalled = false
    private var editorScriptInstalled = false
    private var editorPickMode = false
    private var boostEditorOpen = false
    var onBoostPageshow: (() -> Void)?
    var onNavigationCommit: ((URL?, String?) -> Void)?
    /// ⌥⌘-click on a link (`LittleArcLinkOpening`); nil follows the link.
    @ObservationIgnored var littleArcLinkHandler: ((URL) -> Void)?
    let supportsBoostEditor = true
    /// Find-in-page session numbering and counts (`FindInPage.swift`).
    @ObservationIgnored let findSession = WebKitFindSession()
    @ObservationIgnored var onFindEvent: ((FindInPageEvent) -> Void)?
    /// Receives this view's downloads (`WKDownload`); nil drops them.
    @ObservationIgnored weak var downloadCenter: WebKitDownloadCenter?

    var onBoostEditorPick: ((PickedElementSnapshot) -> Void)? {
        didSet { boostEditorBridge.onPick = onBoostEditorPick }
    }
    var onBoostEditorCancel: (() -> Void)? {
        didSet { boostEditorBridge.onCancel = onBoostEditorCancel }
    }

    var mediaState: WebMediaState { mediaStateSubject.value }
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { mediaStateSubject.eraseToAnyPublisher() }

    var linkPeekHandler: ((URL) -> Void)? {
        didSet { linkPeekBridge.onURL = linkPeekHandler }
    }

    init(context: EngineProfileContext) {
        profileContext = context
        let configuration = WKWebViewConfiguration()
        if context.isEphemeral {
            configuration.websiteDataStore = .nonPersistent()
        } else {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: context.websiteDataStoreIdentifier)
        }
        // Element.requestFullscreen(): WebKit runs its own fullscreen window over
        // the browser window and restores the page when it exits (Esc included).
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = ReArcWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.prompts = pagePrompts
        webView.contextInfo = contextMenuBridge
        let controller = webView.configuration.userContentController
        controller.add(linkPeekBridge, name: LinkPeekMessageHandler.handlerName)
        controller.add(contextMenuBridge, name: ContextMenuMessageHandler.handlerName)
        controller.add(mediaBridge, name: MediaStateMessageHandler.handlerName)
        controller.add(boostPageshowBridge, name: BoostInjectionScriptBuilder.pageshowHandler)
        controller.add(printBridge, name: PrintRequestMessageHandler.handlerName)
        reinstallBaseScripts(on: controller)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        mediaBridge.onState = { [weak self] state in
            self?.mediaStateSubject.send(state)
        }
        boostPageshowBridge.onPageshow = { [weak self] in
            self?.onBoostPageshow?()
        }
        printBridge.onRequest = { [weak self] in
            guard let self else { return }
            PagePrinter.shared.print(self)
        }
        observeNavigationState()
    }

    deinit {
        faviconTask?.cancel()
        // WebKit requires every delegate completion handler to be called.
        pagePrompts.answerAllConservatively()
    }

    func nextPromptID() -> UInt64 {
        lastPromptID += 1
        return lastPromptID
    }

    private func observeNavigationState() {
        let refresh: (WKWebView) -> Void = { [weak self] webView in
            DispatchQueue.main.async { self?.syncNavigationState(from: webView) }
        }
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { webView, _ in refresh(webView) },
            webView.observe(\.canGoForward, options: [.new]) { webView, _ in refresh(webView) },
            webView.observe(\.isLoading, options: [.new]) { webView, _ in refresh(webView) },
            webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in refresh(webView) },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { webView, _ in refresh(webView) },
            webView.observe(\.url, options: [.new]) { webView, _ in refresh(webView) },
        ]
    }

    private func syncNavigationState(from webView: WKWebView) {
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if loadProgress != webView.estimatedProgress { loadProgress = webView.estimatedProgress }
        let security = WebSecurityState.webKit(url: webView.url ?? currentURL, hasOnlySecureContent: webView.hasOnlySecureContent)
        if securityState != security { securityState = security }
    }

    private func reinstallBaseScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.linkPeekScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: Self.mediaProbeScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: ContextMenuMessageHandler.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: PrintRequestMessageHandler.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func load(_ url: URL) {
        currentURL = url
        if url.isFileURL {
            // A file dropped on the sidebar: WebKit reads local files only through loadFileURL.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload(ignoringCache: Bool) {
        if ignoringCache {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func stopLoading() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func setMuted(_ muted: Bool) {
        evaluateMedia("setMuted(\(muted))")
    }

    func togglePlayPause() {
        evaluateMedia("togglePlayPause()")
    }

    func skipToNextTrack() {
        evaluateMedia("skipNext()")
    }

    func skipToPreviousTrack() {
        evaluateMedia("skipPrevious()")
    }

    func pauseAllMedia() {
        evaluateMedia("pauseAll()")
    }

    func setPictureInPicture(_ active: Bool) {
        guard active else { return evaluateMedia("exitPiP()") }
        // WK-LIMIT: PiP often requires a recent user gesture; Chromium enters through its media session.
        evaluateMedia("requestPiP()")
        evaluateMedia("meetAutoPiP()")
    }

    /// WKWebView page zoom applies per web view (WebKit keeps no per-host map).
    private(set) var zoomFactor: Double = 1.0

    func setZoomFactor(_ factor: Double) {
        guard PageZoom.isValid(factor) else { return }
        webView.pageZoom = factor
        zoomFactor = factor
    }

    private func evaluateMedia(_ call: String) {
        webView.evaluateJavaScript("window.__rearcMediaControl && window.__rearcMediaControl.\(call)", completionHandler: nil)
    }

    func makeView() -> AnyView {
        AnyView(WebViewRepresentable(webView: webView).pagePrompts(pagePrompts))
    }

    func installBoosts(_ entries: [BoostRuntimeEntry]) {
        let previousScriptIDs = installedScriptPackageIDs
        let nextScriptIDs = Set(entries.filter(\.scriptUserEnabled).map(\.packageID))
        let disabledJSRemoved = !previousScriptIDs.subtracting(nextScriptIDs).isEmpty
        boostEntries = entries
        installedScriptPackageIDs = nextScriptIDs
        let controller = webView.configuration.userContentController
        editorScriptInstalled = false
        reinstallBaseScripts(on: controller)
        let hostWorld = BoostInjectionScriptBuilder.hostWorld()
        controller.addUserScript(WKUserScript(
            source: BoostInjectionScriptBuilder.coordinatorSource(entries: entries),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: hostWorld
        ))
        for entry in entries {
            guard entry.scriptUserEnabled, let js = entry.js, !js.isEmpty else { continue }
            let world = BoostInjectionScriptBuilder.scriptWorld(for: entry.packageID)
            controller.addUserScript(WKUserScript(
                source: BoostInjectionScriptBuilder.scriptSource(
                    js: js,
                    packageID: entry.packageID,
                    hostScope: entry.hostScope
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: world
            ))
        }
        if disabledJSRemoved, webView.url != nil {
            webView.reload()
        } else {
            pushLiveBoostPlan(entries)
        }
        if boostEditorOpen {
            installEditorScriptsIfNeeded(on: controller)
            bootstrapEditorPickerOnCurrentPage()
        }
    }

    func refreshBoostsOnPage() {
        pushLiveBoostPlan(boostEntries)
    }

    private func pushLiveBoostPlan(_ entries: [BoostRuntimeEntry]) {
        let hostWorld = BoostInjectionScriptBuilder.hostWorld()
        let planJSON = BoostInjectionScriptBuilder.livePlanPayloadJSON(entries: entries)
        webView.evaluateJavaScript(
            """
            (function(){
              var plan = \(planJSON);
              if (window.__rearcBoostCoordinator && window.__rearcBoostCoordinator.setPlan) {
                window.__rearcBoostCoordinator.setPlan(plan);
              } else if (window.__rearcBoostCoordinator) {
                window.__rearcBoostPlan = plan;
                window.__rearcBoostCoordinator.apply();
              }
            })();
            """,
            in: nil,
            in: hostWorld,
            completionHandler: nil
        )
    }

    func setBoostEditorOpen(_ open: Bool) {
        boostEditorOpen = open
        let controller = webView.configuration.userContentController
        let editorWorld = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        if open {
            installEditorScriptsIfNeeded(on: controller)
            if !editorBridgeInstalled {
                controller.add(boostEditorBridge, contentWorld: editorWorld, name: BoostPickerScript.messageHandler)
                editorBridgeInstalled = true
            }
            bootstrapEditorPickerOnCurrentPage()
        } else {
            setBoostPickerMode(false)
            if editorBridgeInstalled {
                controller.removeScriptMessageHandler(forName: BoostPickerScript.messageHandler, contentWorld: editorWorld)
                editorBridgeInstalled = false
            }
        }
    }

    private func installEditorScriptsIfNeeded(on controller: WKUserContentController) {
        guard !editorScriptInstalled else { return }
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        controller.addUserScript(WKUserScript(
            source: BoostPickerScript.bridgeSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
        editorScriptInstalled = true
    }

    private func bootstrapEditorPickerOnCurrentPage() {
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        webView.evaluateJavaScript(BoostPickerScript.bridgeSource, in: nil, in: world, completionHandler: nil)
    }

    func setBoostPickerMode(_ active: Bool) {
        editorPickMode = active
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        webView.evaluateJavaScript(
            "window.__rearcBoostPicker && window.__rearcBoostPicker.setPickMode(\(active))",
            in: nil,
            in: world,
            completionHandler: nil
        )
    }

    func fetchRepairScan(completion: @escaping ([PickedElementSnapshot]) -> Void) {
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        webView.evaluateJavaScript(
            """
            (function(){
              if (!window.__rearcBoostPicker || !window.__rearcBoostPicker.scanRepairCandidates) return '[]';
              return JSON.stringify(window.__rearcBoostPicker.scanRepairCandidates(24));
            })();
            """,
            in: nil,
            in: world
        ) { outcome in
            guard case .success(let value) = outcome,
                  let json = value as? String,
                  let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion([])
                return
            }
            let snapshots = array.compactMap { BoostEditorMessageHandler.decodePick($0) }
            completion(snapshots)
        }
    }

    func highlightBoostSelector(_ css: String) {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        webView.evaluateJavaScript(
            "window.__rearcBoostPicker && window.__rearcBoostPicker.highlightSelector('\(escaped)')",
            in: nil,
            in: world,
            completionHandler: nil
        )
    }

    func applyEditorLiveCSS(_ css: String) {
        guard let source = BoostEditorScripts.liveStylesheet(css) else { return }
        webView.evaluateJavaScript(
            source,
            in: nil,
            in: BoostInjectionScriptBuilder.hostWorld(),
            completionHandler: nil
        )
    }

    func clearEditorLiveCSS() {
        applyEditorLiveCSS("")
        let world = WKContentWorld.world(name: BoostPickerScript.editorWorldName)
        webView.evaluateJavaScript(
            "window.__rearcBoostPicker && window.__rearcBoostPicker.hideOverlay()",
            in: nil,
            in: world,
            completionHandler: nil
        )
    }

    func clearBoostSessionOnNavigation() {
        // Session-apply map is owned by BrowserViewModel; engine clears live overlay.
        clearEditorLiveCSS()
    }

    func captureSnapshot(scope: CaptureScope) async throws -> Data {
        try await captureSnapshotOnMainActor(scope: scope)
    }

    @MainActor
    private func captureSnapshotOnMainActor(scope: CaptureScope) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        switch scope {
        case .visible:
            configuration.rect = webView.bounds
        case .fullPage:
            let contentSize = try await measureScrollableContentSize()
            configuration.rect = CGRect(origin: .zero, size: contentSize)
        }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: CaptureSnapshotError.encodingFailed)
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureSnapshotError.encodingFailed
        }
        return png
    }

    @MainActor
    private func measureScrollableContentSize() async throws -> CGSize {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(
                """
                JSON.stringify({
                  width: Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0),
                  height: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)
                })
                """
            ) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                      let width = object["width"],
                      let height = object["height"] else {
                    continuation.resume(throwing: CaptureSnapshotError.measurementFailed)
                    return
                }
                let size = CGSize(
                    width: max(width, self.webView.bounds.width),
                    height: max(height, self.webView.bounds.height)
                )
                continuation.resume(returning: size)
            }
        }
    }
}

private enum CaptureSnapshotError: Error {
    case encodingFailed
    case measurementFailed
}

extension WKEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        isCrashed = false
    }

    /// The web content process died (crash, jetsam): keep the tab and show
    /// the crashed page until Reload starts a new process.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isCrashed = true
        isLoading = false
        syncNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url ?? currentURL
        if faviconPageURL?.host() != currentURL?.host() {
            faviconTask?.cancel()
            faviconData = nil
            faviconPageURL = nil
        }
        clearBoostSessionOnNavigation()
        endFindOnNavigation()
        pagePrompts.documentChanged()
        refreshBoostsOnPage()
        onNavigationCommit?(currentURL, pageTitle)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title
        refreshBoostsOnPage()
        onNavigationCommit?(currentURL, pageTitle)
        syncNavigationState(from: webView)
        loadFavicon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState(from: webView)
    }

    // MARK: Downloads (WKDownload)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           let littleArcLinkHandler,
           LittleArcChrome.clickOpensLittleArc(
               command: flags.contains(.command), option: flags.contains(.option),
               shift: flags.contains(.shift), control: flags.contains(.control)
           ) {
            // ⌥⌘-click: the link opens in Little Arc, the page stays.
            decisionHandler(.cancel)
            littleArcLinkHandler(url)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload && downloadCenter != nil ? .download : .allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let download = downloadCenter != nil && WebKitDownloadCenter.shouldDownload(
            response: navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            isForMainFrame: navigationResponse.isForMainFrame
        )
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadCenter?.adopt(download, sourceURL: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadCenter?.adopt(download, sourceURL: navigationResponse.response.url)
    }

    /// HTTP Basic/Digest sign-in through the page's sign-in sheet (the
    /// Chromium path's ABI 1.38 sheet); other challenges keep WebKit's handling.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod) else {
            return completionHandler(.performDefaultHandling, nil)
        }
        Self.nextAuthChallengeID += 1
        let scheme = space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ? "digest" : "basic"
        let request = HTTPAuthChallenge(
            id: Self.nextAuthChallengeID,
            challenger: "\(space.protocol ?? "http")://\(space.host):\(space.port)",
            scheme: scheme,
            realm: space.realm ?? "",
            isProxy: space.isProxy()
        )
        pagePrompts.presentHTTPAuth(request) { credentials in
            guard let credentials else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            completionHandler(.useCredential, URLCredential(user: credentials.username, password: credentials.password, persistence: .forSession))
        }
    }
}

// MARK: - Favicons

extension WKEngine {
    /// Collects `<link rel~=icon>` candidates in the page's main world.
    private static let faviconProbeSource = """
    (function() {
      var links = Array.prototype.slice.call(document.querySelectorAll('link[rel]'));
      return links.filter(function(l) {
        return /(^|\\s)(icon|apple-touch-icon)(\\s|$)/i.test(l.rel) && l.href;
      }).map(function(l) { return [l.href, l.rel.toLowerCase(), l.sizes ? String(l.sizes) : '']; });
    })();
    """

    /// The page's icon: a declared `<link rel=icon>` (a 32px-ish one when sizes
    /// are given), else /favicon.ico. Ephemeral (private) engines skip it so
    /// no request leaves their data store's session.
    fileprivate func loadFavicon() {
        guard !profileContext.isEphemeral,
              let pageURL = webView.url,
              let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if faviconPageURL?.host() == pageURL.host(), faviconData != nil { return }
        webView.evaluateJavaScript(Self.faviconProbeSource) { [weak self] result, _ in
            guard let self else { return }
            let declared = (result as? [[String]] ?? []).compactMap { entry -> FaviconCandidate? in
                guard let href = entry.first, let url = URL(string: href) else { return nil }
                return FaviconCandidate(url: url, rel: entry.count > 1 ? entry[1] : "icon", sizes: entry.count > 2 ? entry[2] : "")
            }
            let urls = FaviconCandidate.ordered(declared, pageURL: pageURL)
            self.faviconTask?.cancel()
            self.faviconTask = Task { [weak self] in
                guard let data = await FaviconCandidate.fetchFirst(urls) else { return }
                await MainActor.run {
                    guard let self, self.webView.url?.host() == pageURL.host() else { return }
                    self.faviconPageURL = pageURL
                    self.faviconData = data
                }
            }
        }
    }
}

/// One `<link rel=icon>` candidate on a WebKit page.
struct FaviconCandidate: Equatable {
    var url: URL
    var rel: String
    var sizes: String

    /// http(s) candidates, best first (rel=icon nearest 32px, then
    /// apple-touch-icon), followed by the site's /favicon.ico.
    static func ordered(_ candidates: [FaviconCandidate], pageURL: URL) -> [URL] {
        func score(_ candidate: FaviconCandidate) -> Int {
            let touch = candidate.rel.contains("apple-touch-icon") ? 1000 : 0
            let size = candidate.sizes.split(separator: "x").first.flatMap { Int($0) } ?? 32
            return touch + abs(size - 32)
        }
        var urls = candidates
            .filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
            .sorted { score($0) < score($1) }
            .map(\.url)
        if var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            if let fallback = components.url, !urls.contains(fallback) { urls.append(fallback) }
        }
        return urls
    }

    /// First candidate that downloads as a decodable image under 256 KiB.
    /// Uses an ephemeral session: icon fetches share no cookies with pages.
    static func fetchFirst(_ urls: [URL]) async -> Data? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for url in urls.prefix(4) {
            guard !Task.isCancelled else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty, data.count <= 256 * 1024,
                  NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }
}

/// Wraps the engine's WKWebView. The web view instance is owned by the
/// engine, so tab switches just re-parent the same view.
private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

extension WKEngine: LittleArcLinkOpening {}

/// Site Control Center: the site's records in this view's data store.
@MainActor
extension WKEngine: SiteDataManaging {
    private func records(for host: String) async -> [WKWebsiteDataRecord] {
        let store = webView.configuration.websiteDataStore
        let all = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return all.filter { SiteControlCenter.siteDataRecord($0.displayName, belongsTo: host) }
    }

    func siteDataKindCount(host: String) async -> Int {
        await records(for: host).reduce(into: Set<String>()) { $0.formUnion($1.dataTypes) }.count
    }

    func clearSiteData(host: String) async {
        let matching = await records(for: host)
        guard !matching.isEmpty else { return }
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }
}

extension WKEngine: PageElementLocating {
    /// Measured in ReArc's own content world, out of reach of page script.
    @MainActor
    func captureElementBounds(atFractionX x: Double, y: Double) async -> PageElementRect? {
        let value = try? await webView.evaluateJavaScript(PageCaptureScripts.elementRect(fractionX: x, y: y), in: nil, contentWorld: .defaultClient)
        return PageElementRect(value)
    }
}

extension WKEngine: PageSelectionReading {
    func selectedText() async -> String? {
        try? await webView.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')") as? String
    }

    @MainActor
    func scrollSelectionIntoView() async -> Bool {
        (try? await webView.evaluateJavaScript(PageSelectionScripts.scrollIntoView, in: nil, contentWorld: .defaultClient) as? Bool) ?? false
    }
}

extension WKEngine: PageFocusing {
    @discardableResult
    func focusPage() -> Bool {
        webView.window?.makeFirstResponder(webView) ?? false
    }
}
