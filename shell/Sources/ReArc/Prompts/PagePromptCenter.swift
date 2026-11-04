import AppKit
import SidebarModel

/// Where the page menu's Arc items and the prompts' links go (the browser view model).
protocol PageLinkRouting: AnyObject {
    func openLinkInNewTab(_ url: URL, from prompts: PagePromptCenter)
    func openLinkInLittleArc(_ url: URL, from prompts: PagePromptCenter)
    func openLinkInNewSplit(_ url: URL, from prompts: PagePromptCenter)
    func searchWeb(for text: String, from prompts: PagePromptCenter)
    /// Shows the tab a prompt belongs to (a leave-site prompt on a tab being closed).
    func revealPage(of prompts: PagePromptCenter)
    /// Chromium's site details page for `origin`.
    func openSiteSettings(origin: String, from prompts: PagePromptCenter)
    var navigationSchemes: NavigationURLPolicy.EngineSchemes { get }
}

/// One page's prompts, shown over that page only (`PagePromptOverlay`) so
/// other tabs and windows stay usable: the JavaScript dialog, permission
/// and password prompts, the file panel and the page menu. Each engine owns
/// one; the engine forwards requests and cancellations, the overlay shows
/// them, and answers go back through the reply closure exactly once. A
/// cancelled request is dropped without a reply.
@Observable
final class PagePromptCenter {
    struct Dialog: Identifiable {
        let request: JavaScriptDialogRequest
        let offersSuppression: Bool
        fileprivate let reply: (JavaScriptDialogReply) -> Void
        var id: UInt64 { request.id }
    }

    struct Permission: Identifiable {
        let request: PermissionPromptRequest
        fileprivate let reply: (PermissionDecision, Bool) -> Void
        var id: UInt64 { request.id }
    }

    struct Password: Identifiable {
        let prompt: PasswordSavePrompt
        fileprivate let reply: (PasswordPromptAction) -> Void
        var id: UInt64 { prompt.id }
    }

    // MARK: Identity (set by EngineHost when the engine is made)

    /// The sidebar tab this page belongs to; nil for peeks, Little Arc and private windows.
    @ObservationIgnored var ownerTabID: UUID?
    @ObservationIgnored var profileID: Profile.ID?
    /// A private window's session; its permission answers are never saved.
    @ObservationIgnored var privateSession: UUID?
    @ObservationIgnored var role: EngineRole = .tab
    @ObservationIgnored weak var router: PageLinkRouting?
    @ObservationIgnored weak var sitePermissions: SitePermissionsController?

    /// `SitePermissionStore` scope: the profile, or the private session.
    var permissionScope: String {
        if let privateSession { return SitePermissionStore.ephemeralPrefix + privateSession.uuidString }
        return profileID?.uuidString ?? "default"
    }

    // MARK: Presented state

    private(set) var dialog: Dialog?
    /// The prompt's text field.
    var dialogText = ""
    /// "Don't allow this page to create more dialogs".
    var suppressDialogs = false
    private(set) var permission: Permission?
    /// "Remember this decision" (sends persist).
    var rememberPermission = true
    private(set) var password: Password?

    @ObservationIgnored private var dialogQueue: [Dialog] = []
    @ObservationIgnored private var permissionQueue: [Permission] = []
    @ObservationIgnored private(set) var dialogGuard = JavaScriptDialogGuard()
    /// Requests answered by the shell, per channel, for logs and the self-test.
    @ObservationIgnored private(set) var answered: [String: Int] = [:]
    @ObservationIgnored private(set) var cancelled: [String: Int] = [:]

    // MARK: Native presenters (replaceable for tests and the self-test)

    @ObservationIgnored var filePanels: FilePanelPresenting = SystemFilePanelPresenter()
    @ObservationIgnored var contextMenus: PageContextMenuPresenting = NSMenuContextMenuPresenter()
    @ObservationIgnored private var fileChooser: (id: UInt64, request: FileChooserRequest, handle: FilePanelHandle?, reply: ([String]?) -> Void)?
    /// The view under the page (the overlay's anchor): window for sheets, coordinates for menus.
    @ObservationIgnored weak var anchorView: NSView?

    init() {}

    var hostWindow: NSWindow? { anchorView?.window }

    // MARK: JavaScript dialogs

    /// Shows `request`, or answers it at once when the page's dialogs are suppressed.
    func presentDialog(_ request: JavaScriptDialogRequest, reply: @escaping (JavaScriptDialogReply) -> Void) {
        switch dialogGuard.admit(request.kind) {
        case .suppress(let answer):
            count(&answered, "dialog")
            reply(answer)
        case .present(let offers):
            let dialog = Dialog(request: request, offersSuppression: offers, reply: reply)
            if self.dialog == nil {
                show(dialog)
            } else {
                dialogQueue.append(dialog)
            }
            if request.kind == .beforeUnload { router?.revealPage(of: self) }
        }
    }

    /// The overlay's OK / Leave (`accept`) or Cancel / Stay.
    func answerDialog(accept: Bool) {
        guard let dialog else { return }
        let reply: JavaScriptDialogReply
        if accept, dialog.request.kind == .prompt {
            reply = .prompt(dialogText)
        } else {
            reply = JavaScriptDialogReply(accept: accept)
        }
        if dialog.offersSuppression, suppressDialogs { dialogGuard.suppress() }
        count(&answered, "dialog")
        advanceDialog()
        dialog.reply(reply)
        // Dialogs queued behind a newly suppressed page are answered now.
        if dialogGuard.isSuppressed { drainSuppressedDialogs() }
    }

    /// The engine withdrew the request (navigation, close, frame gone).
    func cancelDialog(id: UInt64) {
        if dialog?.id == id {
            count(&cancelled, "dialog")
            advanceDialog()
        } else if let index = dialogQueue.firstIndex(where: { $0.id == id }) {
            count(&cancelled, "dialog")
            dialogQueue.remove(at: index)
        }
    }

    private func show(_ dialog: Dialog) {
        dialogText = dialog.request.defaultText
        suppressDialogs = false
        self.dialog = dialog
    }

    private func advanceDialog() {
        dialog = nil
        if !dialogQueue.isEmpty { show(dialogQueue.removeFirst()) }
    }

    private func drainSuppressedDialogs() {
        let pending = ([dialog].compactMap { $0 } + dialogQueue).filter { $0.request.kind != .beforeUnload }
        guard !pending.isEmpty else { return }
        dialogQueue.removeAll { queued in pending.contains { $0.id == queued.id } }
        if let current = dialog, pending.contains(where: { $0.id == current.id }) { advanceDialog() }
        for dialog in pending {
            count(&answered, "dialog")
            dialog.reply(JavaScriptDialogGuard.suppressedReply(for: dialog.request.kind))
        }
    }

    /// A new primary document: the dialog limit starts over.
    func documentChanged() {
        dialogGuard.reset()
    }

    // MARK: Permissions

    func presentPermission(_ request: PermissionPromptRequest, reply: @escaping (PermissionDecision, Bool) -> Void) {
        let entry = Permission(request: request, reply: reply)
        if permission == nil {
            rememberPermission = true
            permission = entry
        } else {
            permissionQueue.append(entry)
        }
    }

    /// Allow / Block (with "Remember" as persist) or the close button (dismiss).
    func answerPermission(_ decision: PermissionDecision) {
        guard let current = permission else { return }
        let persist = decision != .dismiss && rememberPermission
        sitePermissions?.record(decision, remembered: persist, request: current.request, scope: permissionScope)
        count(&answered, "permission")
        advancePermission()
        current.reply(decision, persist)
    }

    func cancelPermission(id: UInt64) {
        if permission?.id == id {
            count(&cancelled, "permission")
            advancePermission()
        } else if let index = permissionQueue.firstIndex(where: { $0.id == id }) {
            count(&cancelled, "permission")
            permissionQueue.remove(at: index)
        }
    }

    private func advancePermission() {
        permission = nil
        if !permissionQueue.isEmpty {
            rememberPermission = true
            permission = permissionQueue.removeFirst()
        }
    }

    // MARK: Password offers

    func presentPassword(_ prompt: PasswordSavePrompt, reply: @escaping (PasswordPromptAction) -> Void) {
        // A newer offer replaces an unanswered one (Chromium cancels the old one too).
        if let previous = password {
            password = nil
            previous.reply(.notNow)
        }
        password = Password(prompt: prompt, reply: reply)
    }

    func answerPassword(_ action: PasswordPromptAction) {
        guard let current = password else { return }
        password = nil
        count(&answered, "password")
        current.reply(action)
    }

    func cancelPassword(id: UInt64) {
        guard password?.id == id else { return }
        count(&cancelled, "password")
        password = nil
    }

    // MARK: File chooser

    /// Shows the open or save panel as a sheet on the page's window. `reply`
    /// gets ABI-valid paths, or nil for cancel; never both, never twice.
    func chooseFiles(_ request: FileChooserRequest, reply: @escaping ([String]?) -> Void) {
        guard fileChooser == nil else {
            // One panel per page; Chromium serializes choosers, so this is a stale request.
            return reply(nil)
        }
        fileChooser = (request.id, request, nil, reply)
        let handle = filePanels.present(request, in: hostWindow) { [weak self] urls in
            guard let self, self.fileChooser?.id == request.id else { return }
            self.fileChooser = nil
            self.count(&self.answered, "file")
            let paths = urls.flatMap { FileChooserReply.validPaths($0.map(\.path), mode: request.mode) }
            reply(paths)
        }
        if fileChooser?.id == request.id { fileChooser?.handle = handle }
    }

    /// The engine withdrew the chooser: close the panel without replying.
    func cancelFileChooser(id: UInt64) {
        guard let current = fileChooser, current.id == id else { return }
        fileChooser = nil
        count(&cancelled, "file")
        current.handle?.close()
    }

    var fileChooserRequest: FileChooserRequest? { fileChooser?.request }

    // MARK: Page context menu

    /// Shows `plan` at `point` (top-left page coordinates) and reports the
    /// chosen item, or nil when the menu closed without a choice. Arc items
    /// are performed here; the caller performs engine items.
    func showContextMenu(
        _ plan: PageContextMenuPlan,
        params: PageContextMenuParams,
        at point: CGPoint,
        perform: @escaping (PageContextMenuItem?) -> Void
    ) {
        contextMenus.present(plan, at: point, in: anchorView) { [weak self] item in
            guard let self else { return perform(nil) }
            self.count(&self.answered, "context")
            if let item, self.performShellItem(item, params: params) {
                perform(nil)
            } else {
                perform(item)
            }
        }
    }

    /// Runs the items the shell owns. True when `item` was one of them.
    @discardableResult
    func performShellItem(_ item: PageContextMenuItem, params: PageContextMenuParams) -> Bool {
        switch item {
        case .openLinkInNewTab:
            if let url = params.openableLink { router?.openLinkInNewTab(url, from: self) }
        case .openLinkInLittleArc:
            if let url = params.openableLink { router?.openLinkInLittleArc(url, from: self) }
        case .openLinkInNewSplit:
            if let url = params.openableLink { router?.openLinkInNewSplit(url, from: self) }
        case .openImageInNewTab:
            if let url = params.openableImage { router?.openLinkInNewTab(url, from: self) }
        case .copyImageAddress:
            copyToPasteboard(params.srcURL)
        case .searchFor(let text):
            router?.searchWeb(for: text, from: self)
        case .viewSource:
            if let page = URL(string: params.pageURL),
               let source = NavigationURLPolicy.viewSourceURL(for: page, engine: router?.navigationSchemes ?? []) {
                router?.openLinkInNewTab(source, from: self)
            }
        case .copyLink, .saveImage, .copyImage, .cut, .copy, .paste, .selectAll, .back, .forward, .reload, .inspect:
            return false
        }
        return true
    }

    /// Arc page options for this page: Little Arc and split only for sidebar tabs.
    func contextMenuOptions(canGoBack: Bool, canGoForward: Bool, canViewSource: Bool, canInspect: Bool) -> PageContextMenuPlan.Options {
        PageContextMenuPlan.Options(
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canOpenLittleArc: privateSession == nil,
            canOpenSplit: ownerTabID != nil && role == .tab,
            canViewSource: canViewSource,
            canInspect: canInspect,
            showsDisabledInspect: true
        )
    }

    // MARK: Teardown

    /// The page is going away without the engine answering for it (WebKit
    /// completion handlers must still be called): every open request gets
    /// its conservative answer.
    func answerAllConservatively() {
        let dialogs = [dialog].compactMap { $0 } + dialogQueue
        dialog = nil
        dialogQueue = []
        dialogs.forEach { $0.reply(JavaScriptDialogReply(accept: $0.request.kind == .alert)) }
        let permissions = [permission].compactMap { $0 } + permissionQueue
        permission = nil
        permissionQueue = []
        permissions.forEach { $0.reply(.dismiss, false) }
        if let password {
            self.password = nil
            password.reply(.notNow)
        }
        if let chooser = fileChooser {
            fileChooser = nil
            chooser.handle?.close()
            chooser.reply(nil)
        }
    }

    /// The engine retired every request (tab closed): clear without replying.
    func withdrawAll() {
        for (channel, pending) in [("dialog", (dialog == nil ? 0 : 1) + dialogQueue.count),
                                   ("permission", (permission == nil ? 0 : 1) + permissionQueue.count),
                                   ("password", password == nil ? 0 : 1)] where pending > 0 {
            cancelled[channel, default: 0] += pending
        }
        dialog = nil
        dialogQueue = []
        permission = nil
        permissionQueue = []
        password = nil
        if let chooser = fileChooser {
            fileChooser = nil
            count(&cancelled, "file")
            chooser.handle?.close()
        }
    }

    var hasPendingPrompt: Bool { dialog != nil || permission != nil || password != nil || fileChooser != nil }

    private func count(_ counter: inout [String: Int], _ channel: String) {
        counter[channel, default: 0] += 1
    }

    private func copyToPasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
