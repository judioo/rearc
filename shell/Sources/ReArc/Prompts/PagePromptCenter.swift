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

    struct AutofillSave: Identifiable {
        let offer: AutofillSaveOffer
        fileprivate let reply: (AutofillSaveAction) -> Void
        var id: UInt64 { offer.id }
    }

    struct HTTPAuth: Identifiable {
        let challenge: HTTPAuthChallenge
        /// nil cancels.
        fileprivate let reply: ((username: String, password: String)?) -> Void
        var id: UInt64 { challenge.id }
    }

    struct ClientCertificate: Identifiable {
        let request: ClientCertificateRequest
        /// nil cancels.
        fileprivate let reply: (String?) -> Void
        var id: UInt64 { request.id }
    }

    /// What the suggestion list does with the engine (Chromium ABI 1.34).
    struct AutofillActions {
        enum AcceptOutcome { case accepted, busy, gone }
        var accept: (_ request: UInt64, _ row: Int) -> AcceptOutcome
        var select: (_ request: UInt64, _ row: Int?) -> Void
        var dismiss: (_ request: UInt64) -> Void
    }

    // MARK: Identity (set by EngineHost when the engine is made)

    /// The sidebar tab this page belongs to; nil for peeks, Little Arc and private windows.
    @ObservationIgnored var ownerTabID: UUID?
    @ObservationIgnored var profileID: Profile.ID?
    /// A private window's session; its permission answers are never saved.
    @ObservationIgnored var privateSession: UUID?
    /// The engine opens the menu's links itself, keeping the page as
    /// initiator (Chromium ABI 1.58); the shell opens them otherwise.
    @ObservationIgnored var engineOpensLinks = false
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
    private(set) var autofillSave: AutofillSave?
    private(set) var httpAuth: HTTPAuth?
    /// The sign-in sheet's fields; cleared as soon as it is answered.
    var authUsername = ""
    var authPassword = ""
    /// The suggestion list drawn for the focused field (Chromium only).
    private(set) var autofill: AutofillPopup?
    /// The row under the pointer (previewed in the page).
    var autofillHover: Int?
    @ObservationIgnored private var autofillShownAt = Date.distantPast
    @ObservationIgnored private var autofillActions: AutofillActions?
    @ObservationIgnored private var authQueue: [HTTPAuth] = []
    private(set) var clientCertificate: ClientCertificate?
    /// The identity selected in the certificate sheet.
    var selectedCertificate: String?
    @ObservationIgnored private var certificateQueue: [ClientCertificate] = []

    @ObservationIgnored private var dialogQueue: [Dialog] = []
    @ObservationIgnored private var permissionQueue: [Permission] = []
    @ObservationIgnored private(set) var dialogGuard = JavaScriptDialogGuard()
    /// Requests answered by the shell, per channel, for logs and the self-test.
    @ObservationIgnored private(set) var answered: [String: Int] = [:]
    @ObservationIgnored private(set) var cancelled: [String: Int] = [:]

    // MARK: Native presenters (replaceable for tests and the self-test)

    @ObservationIgnored var filePanels: FilePanelPresenting = SystemFilePanelPresenter()
    @ObservationIgnored var contextMenus: PageContextMenuPresenting = NSMenuContextMenuPresenter()
    @ObservationIgnored var autofillPanels: AutofillPanelPresenting = AutofillPanelPresenter()
    @ObservationIgnored private var fileChooser: (id: UInt64, request: FileChooserRequest, handle: FilePanelHandle?, reply: ([String]?) -> Void)?
    /// The view under the page (the overlay's anchor): window for sheets, coordinates for menus.
    @ObservationIgnored weak var anchorView: NSView?
    /// Who had the keyboard when a run of dialogs began; it gets it back after the last one.
    @ObservationIgnored weak var keyboardOwnerBeforeDialog: NSResponder?

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

    // MARK: Card and address save offers (Chromium ABI 1.37)

    func presentAutofillSave(_ offer: AutofillSaveOffer, reply: @escaping (AutofillSaveAction) -> Void) {
        // One offer per page (Chromium withdraws the old one too).
        if let previous = autofillSave {
            autofillSave = nil
            previous.reply(.ignore)
        }
        autofillSave = AutofillSave(offer: offer, reply: reply)
    }

    func answerAutofillSave(_ action: AutofillSaveAction) {
        guard let current = autofillSave else { return }
        autofillSave = nil
        count(&answered, "autofill_save")
        current.reply(action)
    }

    func cancelAutofillSave(id: UInt64) {
        guard autofillSave?.id == id else { return }
        count(&cancelled, "autofill_save")
        autofillSave = nil
    }

    // MARK: HTTP authentication (Chromium ABI 1.38, WebKit challenges)

    func presentHTTPAuth(_ challenge: HTTPAuthChallenge, reply: @escaping ((username: String, password: String)?) -> Void) {
        let entry = HTTPAuth(challenge: challenge, reply: reply)
        if httpAuth == nil {
            showHTTPAuth(entry)
        } else {
            authQueue.append(entry)
        }
        router?.revealPage(of: self)
    }

    /// Log In (true) or Cancel. Over-long credentials are refused by the sheet.
    func answerHTTPAuth(signIn: Bool) {
        guard let current = httpAuth else { return }
        let credentials = signIn ? (username: authUsername, password: authPassword) : nil
        if let credentials, !HTTPAuthChallenge.isValidCredential(credentials.username) || !HTTPAuthChallenge.isValidCredential(credentials.password) {
            return
        }
        count(&answered, "http_auth")
        advanceHTTPAuth()
        current.reply(credentials)
    }

    func cancelHTTPAuth(id: UInt64) {
        if httpAuth?.id == id {
            count(&cancelled, "http_auth")
            advanceHTTPAuth()
        } else if let index = authQueue.firstIndex(where: { $0.id == id }) {
            count(&cancelled, "http_auth")
            authQueue.remove(at: index)
        }
    }

    private func showHTTPAuth(_ entry: HTTPAuth) {
        authUsername = ""
        authPassword = ""
        httpAuth = entry
    }

    private func advanceHTTPAuth() {
        httpAuth = nil
        authUsername = ""
        authPassword = ""
        if !authQueue.isEmpty { showHTTPAuth(authQueue.removeFirst()) }
    }

    // MARK: Client certificates (Chromium ABI 1.41)

    func presentClientCertificate(_ request: ClientCertificateRequest, reply: @escaping (String?) -> Void) {
        let entry = ClientCertificate(request: request, reply: reply)
        if clientCertificate == nil {
            showClientCertificate(entry)
        } else {
            certificateQueue.append(entry)
        }
        router?.revealPage(of: self)
    }

    /// OK with the selected identity, or Cancel (nil).
    func answerClientCertificate(_ fingerprint: String?) {
        guard let current = clientCertificate else { return }
        if let fingerprint, !current.request.identities.contains(where: { $0.fingerprint == fingerprint }) { return }
        count(&answered, "client_certificate")
        advanceClientCertificate()
        current.reply(fingerprint)
    }

    func cancelClientCertificate(id: UInt64) {
        if clientCertificate?.id == id {
            count(&cancelled, "client_certificate")
            advanceClientCertificate()
        } else if let index = certificateQueue.firstIndex(where: { $0.id == id }) {
            count(&cancelled, "client_certificate")
            certificateQueue.remove(at: index)
        }
    }

    private func showClientCertificate(_ entry: ClientCertificate) {
        selectedCertificate = entry.request.sortedIdentities().first?.fingerprint
        clientCertificate = entry
    }

    private func advanceClientCertificate() {
        clientCertificate = nil
        selectedCertificate = nil
        if !certificateQueue.isEmpty { showClientCertificate(certificateQueue.removeFirst()) }
    }

    // MARK: Autofill suggestions (Chromium ABI 1.34)

    /// Shows or updates the list. Chromium decides when it shows and hides,
    /// and routes the field's arrow keys, Return, Tab and Escape itself.
    func showAutofill(_ popup: AutofillPopup, actions: AutofillActions) {
        if autofill?.requestID != popup.requestID {
            autofillShownAt = Date()
            autofillHover = nil
        }
        autofillActions = actions
        autofill = popup
        autofillPanels.show(popup, for: self)
    }

    /// Keyboard selection in the field (phase 2).
    func selectAutofillRow(requestID: UInt64, row: Int?) {
        guard var popup = autofill, popup.requestID == requestID else { return }
        popup.selected = row
        autofill = popup
        autofillPanels.show(popup, for: self)
    }

    /// The engine hid the list (phase 1), or the page went away.
    func hideAutofill(requestID: UInt64? = nil) {
        guard let popup = autofill, requestID == nil || popup.requestID == requestID else { return }
        autofill = nil
        autofillHover = nil
        autofillPanels.hide(for: self)
    }

    /// A click on a row. Within Chromium's early-accept guard the engine
    /// answers busy, and the accept is retried once the guard has passed.
    func acceptAutofillRow(_ row: Int) {
        guard let popup = autofill, let actions = autofillActions,
              popup.rows.contains(where: { $0.id == row && $0.isAcceptable && $0.kind != .separator }) else { return }
        switch actions.accept(popup.requestID, row) {
        case .accepted:
            count(&answered, "autofill")
        case .gone:
            hideAutofill(requestID: popup.requestID)
        case .busy:
            let delay = AutofillAcceptPolicy.retryDelay(shownAt: autofillShownAt)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.autofill?.requestID == popup.requestID else { return }
                if actions.accept(popup.requestID, row) == .accepted { self.count(&self.answered, "autofill") }
            }
        }
    }

    /// Pointer over a fill row previews it in the page; nil clears the preview.
    func previewAutofillRow(_ row: Int?) {
        guard let popup = autofill else { return }
        autofillHover = row
        let previewable = row.flatMap { id in popup.rows.first { $0.id == id && $0.kind == .fill } } != nil
        autofillActions?.select(popup.requestID, previewable ? row : nil)
    }

    func dismissAutofill() {
        guard let popup = autofill else { return }
        autofillActions?.dismiss(popup.requestID)
        hideAutofill(requestID: popup.requestID)
    }

    /// Seconds the current list has been shown (the self-test waits out the guard).
    var autofillShownFor: TimeInterval { Date().timeIntervalSince(autofillShownAt) }

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
    func performShellItem(_ item: PageContextMenuItem, params: PageContextMenuParams, engineDeclined: Bool = false) -> Bool {
        let opensPage = ([.openLinkInNewTab, .openLinkInLittleArc, .openLinkInNewSplit, .openImageInNewTab] as [PageContextMenuItem]).contains(item)
        if opensPage, engineOpensLinks, privateSession == nil, !engineDeclined { return false }
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
        if let save = autofillSave {
            autofillSave = nil
            save.reply(.ignore)
        }
        let auths = [httpAuth].compactMap { $0 } + authQueue
        httpAuth = nil
        authQueue = []
        authUsername = ""
        authPassword = ""
        auths.forEach { $0.reply(nil) }
        let certificates = [clientCertificate].compactMap { $0 } + certificateQueue
        clientCertificate = nil
        certificateQueue = []
        selectedCertificate = nil
        certificates.forEach { $0.reply(nil) }
        hideAutofill()
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
                                   ("password", password == nil ? 0 : 1),
                                   ("autofill_save", autofillSave == nil ? 0 : 1),
                                   ("http_auth", (httpAuth == nil ? 0 : 1) + authQueue.count),
                                   ("client_certificate", (clientCertificate == nil ? 0 : 1) + certificateQueue.count)] where pending > 0 {
            cancelled[channel, default: 0] += pending
        }
        dialog = nil
        dialogQueue = []
        permission = nil
        permissionQueue = []
        password = nil
        autofillSave = nil
        httpAuth = nil
        authQueue = []
        authUsername = ""
        authPassword = ""
        clientCertificate = nil
        certificateQueue = []
        selectedCertificate = nil
        hideAutofill()
        if let chooser = fileChooser {
            fileChooser = nil
            count(&cancelled, "file")
            chooser.handle?.close()
        }
    }

    var hasPendingPrompt: Bool {
        dialog != nil || permission != nil || password != nil || fileChooser != nil || autofillSave != nil || httpAuth != nil
            || clientCertificate != nil
    }

    private func count(_ counter: inout [String: Int], _ channel: String) {
        counter[channel, default: 0] += 1
    }

    private func copyToPasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
