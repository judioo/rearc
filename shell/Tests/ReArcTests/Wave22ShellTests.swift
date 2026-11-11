import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ReArc
@testable import SidebarModel

private final class FakeRouter: PageLinkRouting {
    var opened: [(String, URL)] = []
    var revealed = 0
    var navigationSchemes: NavigationURLPolicy.EngineSchemes = .chromium

    func openLinkInNewTab(_ url: URL, from prompts: PagePromptCenter) { opened.append(("tab", url)) }
    func openLinkInLittleArc(_ url: URL, from prompts: PagePromptCenter) { opened.append(("littleArc", url)) }
    func openLinkInNewSplit(_ url: URL, from prompts: PagePromptCenter) { opened.append(("split", url)) }
    func searchWeb(for text: String, from prompts: PagePromptCenter) { opened.append(("search", URL(string: "search:\(text.count)")!)) }
    func revealPage(of prompts: PagePromptCenter) { revealed += 1 }
    func openSiteSettings(origin: String, from prompts: PagePromptCenter) { opened.append(("settings", URL(string: origin)!)) }
}

private final class FakePanelHandle: FilePanelHandle {
    var closed = false
    var onClose: (() -> Void)?
    func close() {
        closed = true
        onClose?()
    }
}

private final class FakeFilePanels: FilePanelPresenting {
    var requests: [FileChooserRequest] = []
    var handles: [FakePanelHandle] = []
    var completions: [([URL]?) -> Void] = []

    func present(_ request: FileChooserRequest, in window: NSWindow?, completion: @escaping ([URL]?) -> Void) -> FilePanelHandle? {
        requests.append(request)
        let handle = FakePanelHandle()
        // Like NSOpenPanel: closing the panel completes it as cancelled.
        handle.onClose = { completion(nil) }
        handles.append(handle)
        completions.append(completion)
        return handle
    }
}

private final class FakeMenus: PageContextMenuPresenting {
    var plans: [PageContextMenuPlan] = []
    var choice: PageContextMenuItem?

    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void) {
        plans.append(plan)
        completion(choice)
    }
}

/// Wave 22: ABI 1.18–1.22 gating, the page prompt center (dialogs and the
/// dialog limit, permissions, passwords, file panels, the page menu),
/// native panel and menu configuration, Ask where to save and the Arc link
/// destinations.
final class Wave22ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> (BrowserViewModel, URL) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w22-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        return (model, directory)
    }

    // MARK: Capabilities

    func testPromptChannelsNeedTheirMinorAndFlag() {
        let all: (String) -> Bool = { _ in true }
        let at22 = ChromiumCapabilities(abiMinorVersion: 22, hasFeature: all)
        XCTAssertTrue(at22.javascriptDialogs && at22.fileChooser && at22.permissionPrompts && at22.contextMenu && at22.passwordPrompts)
        XCTAssertTrue(at22.downloadSavePrompt)
        XCTAssertFalse(at22.canInspect)
        XCTAssertTrue(at22.summary.contains("javascript_dialogs=1"))
        XCTAssertTrue(at22.summary.contains("password_prompts=1"))
        XCTAssertTrue(at22.summary.contains("devtools=0"))

        for (minor, adopted) in [(18, "javascript_dialogs"), (19, "file_chooser"), (20, "permission_prompts"), (21, "context_menu"), (22, "password_prompts")] {
            let before = ChromiumCapabilities(abiMinorVersion: UInt32(minor - 1), hasFeature: all)
            let at = ChromiumCapabilities(abiMinorVersion: UInt32(minor), hasFeature: all)
            XCTAssertTrue(before.summary.contains("\(adopted)=0"), "\(adopted) waits for 1.\(minor)")
            XCTAssertTrue(at.summary.contains("\(adopted)=1"), "\(adopted) at 1.\(minor)")
        }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 18, hasFeature: all).downloadSavePrompt, "Ask where to save needs the 1.19 chooser")

        let noFlag = ChromiumCapabilities(abiMinorVersion: 24) { $0 != "context_menu" && $0 != "password_autofill" }
        XCTAssertFalse(noFlag.contextMenu)
        XCTAssertFalse(noFlag.passwordPrompts, "save offers need the 1.15 password client too")
        XCTAssertTrue(noFlag.javascriptDialogs)

        // Wave 18h (ABI 1.40) hosts the DevTools frontend; before it Inspect stays disabled.
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 999) { _ in true }.canInspect)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 39) { _ in true }.canInspect)
    }

    func testContextMenuItemsMapToEngineCommands() {
        XCTAssertEqual(ChromiumContextCommand(.copyLink), .copyLink)
        XCTAssertEqual(ChromiumContextCommand(.saveImage)?.rawValue, 6)
        XCTAssertEqual(ChromiumContextCommand(.copyImage)?.rawValue, 7)
        XCTAssertEqual(ChromiumContextCommand(.inspect)?.rawValue, 8)
        XCTAssertEqual(ChromiumContextCommand(.reload)?.rawValue, 11)
        XCTAssertEqual(ChromiumContextCommand.dismiss.rawValue, 12)
        for shellItem: PageContextMenuItem in [.searchFor("x"), .copyImageAddress, .viewSource] {
            XCTAssertNil(ChromiumContextCommand(shellItem), "\(shellItem) is the shell's")
        }
        // Engine ABI 1.58: opens keep the page as initiator (link-open dispositions 2, 4, 5).
        XCTAssertEqual(ChromiumContextCommand(.openLinkInNewTab)?.rawValue, 13)
        XCTAssertEqual(ChromiumContextCommand(.openLinkInLittleArc)?.rawValue, 15)
        XCTAssertEqual(ChromiumContextCommand(.openLinkInNewSplit)?.rawValue, 16)
        XCTAssertEqual(ChromiumContextCommand(.openImageInNewTab)?.rawValue, 17)
    }

    // MARK: Dialogs

    private func dialog(_ id: UInt64, _ kind: JavaScriptDialogKind, defaultText: String = "") -> JavaScriptDialogRequest {
        JavaScriptDialogRequest(id: id, kind: kind, message: "m\(id)", defaultText: defaultText, origin: "https://a.test")
    }

    func testDialogsQueueAndAnswerOnce() {
        let prompts = PagePromptCenter()
        var replies: [(UInt64, JavaScriptDialogReply)] = []
        prompts.presentDialog(dialog(1, .prompt, defaultText: "default")) { replies.append((1, $0)) }
        prompts.presentDialog(dialog(2, .confirm)) { replies.append((2, $0)) }
        XCTAssertEqual(prompts.dialog?.id, 1)
        XCTAssertEqual(prompts.dialogText, "default")
        XCTAssertFalse(prompts.dialog?.offersSuppression ?? true)
        prompts.dialogText = "typed"
        prompts.answerDialog(accept: true)
        XCTAssertEqual(replies.map(\.0), [1])
        XCTAssertEqual(replies.first?.1, JavaScriptDialogReply(accept: true, text: "typed"))
        XCTAssertEqual(prompts.dialog?.id, 2)
        XCTAssertTrue(prompts.dialog?.offersSuppression ?? false, "the second dialog offers the limit")
        prompts.answerDialog(accept: false)
        prompts.answerDialog(accept: true)
        XCTAssertEqual(replies.count, 2, "answered once")
        XCTAssertEqual(replies.last?.1, JavaScriptDialogReply(accept: false))
        XCTAssertNil(prompts.dialog)
    }

    func testSuppressingDialogsAnswersTheRestWithoutUI() {
        let prompts = PagePromptCenter()
        var replies: [UInt64: JavaScriptDialogReply] = [:]
        prompts.presentDialog(dialog(1, .alert)) { replies[1] = $0 }
        prompts.answerDialog(accept: true)
        prompts.presentDialog(dialog(2, .alert)) { replies[2] = $0 }
        prompts.presentDialog(dialog(3, .confirm)) { replies[3] = $0 }
        prompts.suppressDialogs = true
        prompts.answerDialog(accept: true)
        XCTAssertEqual(replies[3], JavaScriptDialogReply(accept: false), "the queued confirm is cancelled at once")
        XCTAssertNil(prompts.dialog)
        prompts.presentDialog(dialog(4, .prompt)) { replies[4] = $0 }
        XCTAssertNil(prompts.dialog)
        XCTAssertEqual(replies[4], JavaScriptDialogReply(accept: false))
        prompts.documentChanged()
        prompts.presentDialog(dialog(5, .alert)) { replies[5] = $0 }
        XCTAssertEqual(prompts.dialog?.id, 5, "a new document may show dialogs again")
    }

    func testEngineCancellationDropsWithoutReplyAndLeaveSiteRevealsTheTab() {
        let prompts = PagePromptCenter()
        let router = FakeRouter()
        prompts.router = router
        var replies = 0
        prompts.presentDialog(dialog(1, .alert)) { _ in replies += 1 }
        prompts.presentDialog(dialog(2, .confirm)) { _ in replies += 1 }
        prompts.cancelDialog(id: 2)
        prompts.cancelDialog(id: 1)
        XCTAssertNil(prompts.dialog)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(prompts.cancelled["dialog"], 2)
        prompts.presentDialog(dialog(3, .beforeUnload)) { _ in replies += 1 }
        XCTAssertEqual(router.revealed, 1, "a leave-site prompt shows its tab")
        prompts.answerAllConservatively()
        XCTAssertEqual(replies, 1, "teardown answers what is still open")
    }

    // MARK: Permissions and passwords

    func testPermissionAnswersCarryPersistAndAreRecorded() {
        var now: TimeInterval = 100
        let prompts = PagePromptCenter(permissionClock: { now })
        let sites = SitePermissionsController(fileURL: nil)
        prompts.sitePermissions = sites
        prompts.profileID = UUID()
        var replies: [(PermissionDecision, Bool)] = []
        let camera = PermissionPromptRequest(id: 1, origin: "https://meet.test", types: [.camera, .microphone])
        let location = PermissionPromptRequest(id: 2, origin: "https://meet.test", types: [.geolocation])
        prompts.presentPermission(camera) { replies.append(($0, $1)) }
        prompts.presentPermission(location) { replies.append(($0, $1)) }
        XCTAssertEqual(prompts.permission?.id, 1)
        XCTAssertFalse(prompts.rememberPermission)
        prompts.answerPermission(.allow)
        XCTAssertTrue(replies.isEmpty, "ignore early input")
        now += 0.5
        prompts.rememberPermission = true
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies.last?.0, .allow)
        XCTAssertEqual(replies.last?.1, true)
        XCTAssertEqual(prompts.permission?.id, 2)
        XCTAssertFalse(prompts.rememberPermission, "each prompt starts with remember off")
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies.count, 1, "double click cannot answer the next prompt")
        now += 0.5
        prompts.rearmPermissionInteractionDelay()
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies.count, 1, "focus re-arms the guard")
        now += 0.5
        prompts.answerPermission(.deny)
        XCTAssertEqual(replies.last?.1, false)
        XCTAssertEqual(sites.rememberedDecision(for: camera, scope: prompts.permissionScope), .allow)
        XCTAssertNil(sites.rememberedDecision(for: location, scope: prompts.permissionScope))
        XCTAssertEqual(sites.entries(origin: "https://meet.test", scope: prompts.permissionScope).count, 3)

        prompts.presentPermission(PermissionPromptRequest(id: 3, origin: "https://n.test", types: [.notifications])) { replies.append(($0, $1)) }
        now += 0.5
        prompts.answerPermission(.dismiss)
        XCTAssertEqual(replies.last?.0, .dismiss)
        XCTAssertEqual(replies.last?.1, false, "dismiss never persists")
        XCTAssertTrue(sites.entries(origin: "https://n.test", scope: prompts.permissionScope).isEmpty)

        prompts.presentPermission(PermissionPromptRequest(id: 4, origin: "https://n.test", types: [.notifications])) { _, _ in XCTFail("cancelled") }
        prompts.cancelPermission(id: 4)
        XCTAssertNil(prompts.permission)
    }

    func testPrivatePagesUseTheirSessionScope() {
        let prompts = PagePromptCenter()
        prompts.profileID = UUID()
        XCTAssertEqual(prompts.permissionScope, prompts.profileID?.uuidString)
        let session = UUID()
        prompts.privateSession = session
        XCTAssertTrue(prompts.permissionScope.hasPrefix(SitePermissionStore.ephemeralPrefix))
        XCTAssertFalse(prompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: false, canInspect: false).canOpenLittleArc)
    }

    func testANewerPasswordOfferReplacesTheOldOne() {
        let prompts = PagePromptCenter()
        var actions: [(UInt64, PasswordPromptAction)] = []
        prompts.presentPassword(PasswordSavePrompt(id: 1, origin: "https://l.test", username: "a", isUpdate: false)) { actions.append((1, $0)) }
        prompts.presentPassword(PasswordSavePrompt(id: 2, origin: "https://l.test", username: "b", isUpdate: true)) { actions.append((2, $0)) }
        XCTAssertEqual(actions.first?.1, .notNow)
        XCTAssertEqual(prompts.password?.id, 2)
        prompts.answerPassword(.save)
        XCTAssertEqual(actions.last?.0, 2)
        XCTAssertEqual(actions.last?.1, .save)
        prompts.presentPassword(PasswordSavePrompt(id: 3, origin: "https://l.test", username: "c", isUpdate: false)) { _ in XCTFail("cancelled") }
        prompts.cancelPassword(id: 3)
        XCTAssertNil(prompts.password)
    }

    // MARK: File chooser

    func testFileChooserRepliesValidPathsOnceAndEngineCancelClosesThePanel() {
        let prompts = PagePromptCenter()
        let panels = FakeFilePanels()
        prompts.filePanels = panels
        var replies: [[String]?] = []
        prompts.chooseFiles(FileChooserRequest(id: 1, mode: .openMultiple)) { replies.append($0) }
        prompts.chooseFiles(FileChooserRequest(id: 2, mode: .open)) { replies.append($0) }
        XCTAssertEqual(replies.count, 1, "one panel per page")
        XCTAssertNil(replies.first!)
        XCTAssertEqual(prompts.fileChooserRequest?.id, 1)
        panels.completions[0]([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")])
        XCTAssertEqual(replies.last!, ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertNil(prompts.fileChooserRequest)

        prompts.chooseFiles(FileChooserRequest(id: 3, mode: .open)) { replies.append($0) }
        prompts.cancelFileChooser(id: 3)
        XCTAssertTrue(panels.handles.last?.closed ?? false)
        XCTAssertEqual(replies.count, 2, "an engine-cancelled chooser gets no reply")

        prompts.chooseFiles(FileChooserRequest(id: 4, mode: .open)) { replies.append($0) }
        prompts.answerAllConservatively()
        XCTAssertEqual(replies.count, 3)
        XCTAssertNil(replies.last!)
    }

    func testPanelsFollowTheChooserMode() throws {
        let multiple = try XCTUnwrap(SystemFilePanelPresenter.makePanel(for: FileChooserRequest(id: 1, mode: .openMultiple, acceptTypes: [".png", "image/*"])) as? NSOpenPanel)
        XCTAssertTrue(multiple.allowsMultipleSelection)
        XCTAssertTrue(multiple.canChooseFiles)
        XCTAssertFalse(multiple.canChooseDirectories)
        XCTAssertEqual(Set(multiple.allowedContentTypes), [UTType.png, UTType.image])
        let folder = try XCTUnwrap(SystemFilePanelPresenter.makePanel(for: FileChooserRequest(id: 2, mode: .uploadFolder)) as? NSOpenPanel)
        XCTAssertTrue(folder.canChooseDirectories)
        XCTAssertFalse(folder.canChooseFiles)
        XCTAssertEqual(folder.prompt, "Upload")
        let save = SystemFilePanelPresenter.makePanel(for: FileChooserRequest(id: 3, mode: .save, defaultPath: "/tmp/w22/report.pdf"))
        XCTAssertFalse(save is NSOpenPanel)
        XCTAssertEqual(save.nameFieldStringValue, "report.pdf")
        XCTAssertEqual(save.directoryURL?.path, "/tmp/w22")
        XCTAssertNil(SystemFilePanelPresenter.contentTypes(for: FileTypeFilter(acceptTypes: ["application/x-rearc-unknown-\(UUID().uuidString)"])),
                     "an unknown type lifts the advisory filter")
        XCTAssertNil(SystemFilePanelPresenter.contentTypes(for: FileTypeFilter(acceptTypes: [])))
    }

    // MARK: Context menu

    func testContextMenuRunsArcItemsInTheShellAndPassesEngineItemsOn() {
        let prompts = PagePromptCenter()
        let router = FakeRouter()
        let menus = FakeMenus()
        prompts.router = router
        prompts.contextMenus = menus
        prompts.ownerTabID = UUID()
        let params = PageContextMenuParams(linkURL: "https://a.test/next", pageURL: "https://a.test/")
        let options = prompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: true, canInspect: false)
        XCTAssertTrue(options.canOpenSplit && options.canOpenLittleArc)
        let plan = PageContextMenuPlan.plan(for: params, options: options)

        var performed: [PageContextMenuItem?] = []
        menus.choice = .openLinkInNewSplit
        prompts.showContextMenu(plan, params: params, at: .zero) { performed.append($0) }
        XCTAssertEqual(router.opened.map(\.0), ["split"])
        XCTAssertEqual(performed, [nil], "an Arc item leaves only a dismiss for the engine")
        menus.choice = .copyLink
        prompts.showContextMenu(plan, params: params, at: .zero) { performed.append($0) }
        XCTAssertEqual(performed.last, .copyLink)
        menus.choice = nil
        prompts.showContextMenu(plan, params: params, at: .zero) { performed.append($0) }
        XCTAssertEqual(performed.count, 3)
        XCTAssertNil(performed.last!)

        XCTAssertTrue(prompts.performShellItem(.viewSource, params: params))
        XCTAssertEqual(router.opened.last?.1.absoluteString, "view-source:https://a.test/")
        XCTAssertTrue(prompts.performShellItem(.searchFor("pandas"), params: params))
        XCTAssertEqual(router.opened.last?.0, "search")

        // Engine ABI 1.58: the engine opens the link with the page as initiator;
        // the shell opens it only when the engine declines.
        prompts.engineOpensLinks = true
        let count = router.opened.count
        menus.choice = .openLinkInNewSplit
        prompts.showContextMenu(plan, params: params, at: .zero) { performed.append($0) }
        XCTAssertEqual(performed.last, .openLinkInNewSplit, "the engine performs the open")
        XCTAssertEqual(router.opened.count, count)
        XCTAssertTrue(prompts.performShellItem(.openLinkInNewSplit, params: params, engineDeclined: true))
        XCTAssertEqual(router.opened.last?.0, "split")
        // RC-0.1.0-544 F-06: a private window's link goes through the engine too.
        prompts.privateSession = UUID()
        XCTAssertFalse(prompts.performShellItem(.openLinkInNewTab, params: params), "the engine opens it, with an initiator")
        XCTAssertTrue(prompts.performShellItem(.openLinkInNewTab, params: params, engineDeclined: true))
    }

    func testNativeMenuShowsThePlan() {
        let presenter = NSMenuContextMenuPresenter()
        let plan = PageContextMenuPlan.plan(
            for: PageContextMenuParams(linkURL: "https://a.test/x"),
            options: PageContextMenuPlan.Options()
        )
        let menu = presenter.makeMenu(plan)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Open Link in New Tab", "Open Link in Little ReArc", "Open Link in New Split", "Copy Link", "Inspect"])
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 2)
        XCTAssertFalse(menu.items.last?.isEnabled ?? true, "Inspect is disabled")
    }

    func testWebKitMenuIsRewrittenForArc() {
        func item(_ title: String, _ id: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        }
        let menu = NSMenu()
        menu.addItem(item("Open Link in New Window", ReArcWebView.openLinkInNewWindow))
        menu.addItem(item("Download Linked File", "WKMenuItemIdentifierDownloadLinkedFile"))
        menu.addItem(item("Copy Link", "WKMenuItemIdentifierCopyLink"))
        menu.addItem(item("Search with Google", ReArcWebView.searchWeb))
        let params = PageContextMenuParams(linkURL: "https://a.test/x", selectionText: "red pandas")
        ReArcWebView.customize(menu, params: params, options: PageContextMenuPlan.Options()) { item in
            NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        }
        XCTAssertEqual(menu.items.map(\.title), [
            "Open Link in New Tab", "Open Link in Little ReArc", "Open Link in New Split",
            "Download Linked File", "Copy Link", "Search for “red pandas”",
        ])
    }

    // MARK: Shell routing

    func testEnginesKnowWhichPageTheyAre() throws {
        let (model, _) = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        XCTAssertEqual(engine.pagePrompts.ownerTabID, tab.id)
        XCTAssertEqual(engine.pagePrompts.role, .tab)
        XCTAssertTrue(engine.pagePrompts.router === model)
        XCTAssertTrue(engine.pagePrompts.sitePermissions === model.sitePermissions)
        let window = model.openPrivateWindow(url: nil)
        XCTAssertEqual(window.engine.pagePrompts.privateSession, window.session)
        XCTAssertNil(window.engine.pagePrompts.ownerTabID)
        let little = model.littleArcEngine(for: model.openLittleArc(url: URL(string: "https://b.test/")!).id)
        XCTAssertEqual(little.pagePrompts.role, .littleArc)
        XCTAssertFalse(little.pagePrompts.contextMenuOptions(canGoBack: false, canGoForward: false, canViewSource: false, canInspect: false).canOpenSplit)
    }

    func testArcLinkDestinations() throws {
        let (model, _) = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        model.selectTab(tab.id)
        let prompts = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)).pagePrompts
        let before = model.store.displayTabs().count

        model.openLinkInNewTab(URL(string: "https://a.test/bg")!, from: prompts)
        XCTAssertEqual(model.store.displayTabs().count, before + 1)
        XCTAssertEqual(model.store.selectedTabID, tab.id, "Open Link in New Tab stays in the background")
        let background = try XCTUnwrap(model.store.displayTabs().first { $0.url.path == "/bg" })
        XCTAssertNotNil(model.engineHost.engine(forTabID: background.id, profileID: model.profileID(for: background)), "and starts loading")

        model.openLinkInNewSplit(URL(string: "https://a.test/pane")!, from: prompts)
        let split = try XCTUnwrap(model.store.splitContaining(tabID: tab.id)?.split)
        XCTAssertEqual(split.tabs.count, 2)
        XCTAssertEqual(split.tabs.last?.url.path, "/pane")

        model.searchWeb(for: "red pandas", from: prompts)
        XCTAssertEqual(model.store.selectedTab?.url.host(), "duckduckgo.com")

        model.openLinkInLittleArc(URL(string: "https://a.test/little")!, from: prompts)
        XCTAssertEqual(model.store.littleArcLiveWindows.last?.url.path, "/little")
    }

    func testWebKitClosesTabsAtOnce() {
        let (model, _) = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test/")!)
        model.selectTab(tab.id)
        model.loadSelectedIfNeeded()
        model.closeTab(tab.id)
        XCTAssertNil(model.store.tab(withID: tab.id), "WebKit has no beforeunload close, so the tab goes now")
    }

    func testSitePermissionSummaryFollowsThePage() throws {
        let (model, _) = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Meet", url: URL(string: "https://meet.test/room")!)
        model.selectTab(tab.id)
        model.loadSelectedIfNeeded()
        let engine = try XCTUnwrap(model.focusedEngine)
        XCTAssertNil(model.sitePermissionSummary(for: engine))
        let request = PermissionPromptRequest(id: 1, origin: "https://meet.test", types: [.camera])
        model.sitePermissions.record(.deny, remembered: true, request: request, scope: engine.pagePrompts.permissionScope)
        let summary = try XCTUnwrap(model.sitePermissionSummary(for: engine))
        XCTAssertEqual(summary.host, "meet.test")
        XCTAssertTrue(summary.anyBlocked)
        XCTAssertEqual(summary.symbol, "video.fill")
        XCTAssertFalse(model.sitePermissionsLiveInEngine, "WebKit answers reset in place")
        model.sitePermissions.reset(origin: summary.origin, scope: summary.scope)
        XCTAssertNil(model.sitePermissionSummary(for: engine))
    }

    // MARK: Downloads

    func testAskWhereToSavePersistsAndReachesTheEngine() {
        final class Backend: DownloadBackend {
            var asks: [Bool] = []
            func perform(_ action: DownloadAction, id: String) -> Bool { false }
            func directoryChanged(_ directory: URL) {}
            func askWhereToSaveChanged(_ ask: Bool) { asks.append(ask) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("w22-\(UUID().uuidString)/Downloads.json")
        let controller = DownloadsController(fileURL: file)
        XCTAssertFalse(controller.askWhereToSave)
        let backend = Backend()
        controller.chromium = backend
        XCTAssertEqual(backend.asks, [false], "the engine learns the setting on install")
        controller.askWhereToSave = true
        XCTAssertEqual(backend.asks, [false, true])
        controller.save()
        XCTAssertTrue(DownloadsController(fileURL: file).askWhereToSave)
    }
}
