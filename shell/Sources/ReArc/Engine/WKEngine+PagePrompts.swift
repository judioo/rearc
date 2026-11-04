import AppKit
import SidebarModel
import WebKit

/// WebKit's side of the page prompts: WKUIDelegate dialogs, open panels and
/// camera/microphone requests go through the engine's `PagePromptCenter`,
/// like Chromium's ABI channels. WebKit has no public beforeunload,
/// geolocation or notification delegate, so those keep WebKit's defaults
/// (pages can be left; location and notifications are unavailable).
extension WKEngine: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        pagePrompts.presentDialog(dialogRequest(.alert, message: message, frame: frame)) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        pagePrompts.presentDialog(dialogRequest(.confirm, message: message, frame: frame)) { completionHandler($0.accept) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let request = dialogRequest(.prompt, message: prompt, defaultText: defaultText ?? "", frame: frame)
        pagePrompts.presentDialog(request) { reply in completionHandler(reply.accept ? (reply.text ?? "") : nil) }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let mode: FileChooserMode = parameters.allowsDirectories
            ? .uploadFolder
            : (parameters.allowsMultipleSelection ? .openMultiple : .open)
        let request = FileChooserRequest(id: nextPromptID(), mode: mode, origin: Self.origin(frame.securityOrigin))
        pagePrompts.chooseFiles(request) { paths in
            completionHandler(paths?.map { URL(fileURLWithPath: $0) })
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let types: [PermissionType]
        switch type {
        case .camera: types = [.camera]
        case .microphone: types = [.microphone]
        case .cameraAndMicrophone: types = [.camera, .microphone]
        @unknown default: types = [.camera, .microphone]
        }
        let topOrigin = currentURL.flatMap(PageOrigin.of) ?? ""
        let request = PermissionPromptRequest(id: nextPromptID(), origin: Self.origin(origin), embeddingOrigin: topOrigin, types: types)
        // WebKit keeps no site permissions: remembered answers are the shell's.
        if let remembered = pagePrompts.sitePermissions?.rememberedDecision(for: request, scope: pagePrompts.permissionScope) {
            return decisionHandler(remembered == .allow ? .grant : .deny)
        }
        pagePrompts.presentPermission(request) { decision, _ in
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }

    private func dialogRequest(_ kind: JavaScriptDialogKind, message: String, defaultText: String = "", frame: WKFrameInfo) -> JavaScriptDialogRequest {
        JavaScriptDialogRequest(id: nextPromptID(), kind: kind, message: message, defaultText: defaultText, origin: Self.origin(frame.securityOrigin))
    }

    static func origin(_ origin: WKSecurityOrigin) -> String {
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return "" }
        return origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
    }
}

// MARK: - Page menu

/// What the page's `contextmenu` event saw, posted just before WebKit builds its menu.
final class ContextMenuMessageHandler: NSObject, WKScriptMessageHandler {
    static let handlerName = "rearcContextMenu"
    var latest: PageContextMenuParams?

    static let scriptSource = """
    document.addEventListener('contextmenu', function(e) {
      var t = e.target && e.target.nodeType === 1 ? e.target : (e.target && e.target.parentElement);
      var a = t && t.closest ? t.closest('a[href]') : null;
      var img = t && t.closest ? t.closest('img') : null;
      var editable = !!(t && (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName)));
      var sel = window.getSelection ? String(window.getSelection()) : '';
      window.webkit.messageHandlers.\(handlerName).postMessage({
        link: a ? a.href : '', src: img ? (img.currentSrc || img.src) : '',
        selection: sel.slice(0, 4096), editable: editable, page: location.href
      });
    }, true);
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let src = body["src"] as? String ?? ""
        latest = PageContextMenuParams(
            linkURL: body["link"] as? String ?? "",
            srcURL: src,
            selectionText: body["selection"] as? String ?? "",
            pageURL: body["page"] as? String ?? "",
            mediaType: src.isEmpty ? .none : .image,
            isEditable: body["editable"] as? Bool ?? false,
            hasImageContents: !src.isEmpty
        )
    }
}

/// WKWebView with Arc's page menu: WebKit's own menu (it already has the
/// link, image, selection, editable and page variants, and runs their
/// commands), with "Open … in New Window" opening a tab instead, the web
/// search item replaced by "Search for …", and Little Arc and split added.
final class ReArcWebView: WKWebView {
    weak var prompts: PagePromptCenter?
    var contextInfo: ContextMenuMessageHandler?
    private var menuParams = PageContextMenuParams()
    private var menuItems: [PageContextMenuItem] = []

    static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
    static let openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
    static let searchWeb = "WKMenuItemIdentifierSearchWeb"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let prompts else { return }
        let params = contextInfo?.latest ?? PageContextMenuParams()
        contextInfo?.latest = nil
        menuParams = params
        menuItems = []
        let options = prompts.contextMenuOptions(canGoBack: canGoBack, canGoForward: canGoForward, canViewSource: false, canInspect: false)
        Self.customize(menu, params: params, options: options) { [weak self] item in self?.makeItem(item) }
    }

    /// Rewrites WebKit's menu in place (pure enough to unit-test with a plain NSMenu).
    static func customize(
        _ menu: NSMenu,
        params: PageContextMenuParams,
        options: PageContextMenuPlan.Options,
        makeItem: (PageContextMenuItem) -> NSMenuItem?
    ) {
        func index(_ identifier: String) -> Int? {
            menu.items.firstIndex { $0.identifier?.rawValue == identifier }
        }
        if params.openableLink != nil, let open = index(openLinkInNewWindow) {
            if let item = makeItem(.openLinkInNewTab) { menu.items[open] = item }
            var insert = open + 1
            if options.canOpenLittleArc, let item = makeItem(.openLinkInLittleArc) {
                menu.insertItem(item, at: insert)
                insert += 1
            }
            if options.canOpenSplit, let item = makeItem(.openLinkInNewSplit) {
                menu.insertItem(item, at: insert)
            }
        }
        if params.openableImage != nil, let open = index(openImageInNewWindow), let item = makeItem(.openImageInNewTab) {
            menu.items[open] = item
        }
        let selection = params.trimmedSelection
        if !selection.isEmpty, let search = index(searchWeb), let item = makeItem(.searchFor(selection)) {
            menu.items[search] = item
        }
    }

    private func makeItem(_ item: PageContextMenuItem) -> NSMenuItem? {
        let menuItem = NSMenuItem(title: item.title, action: #selector(runShellItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = menuItems.count
        if let symbol = NSMenuContextMenuPresenter.symbol(for: item) {
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menuItems.append(item)
        return menuItem
    }

    @objc private func runShellItem(_ sender: NSMenuItem) {
        guard menuItems.indices.contains(sender.tag) else { return }
        prompts?.performShellItem(menuItems[sender.tag], params: menuParams)
    }
}
