#if REARC_CHROMIUM
import AppKit
import Observation
import SidebarModel
import SwiftUI

/// The shell's side of Chromium extensions (ABI 1.32–1.33, 1.36, 1.47): the
/// toolbar backend, action popups, side panels, install/uninstall sheets, the
/// logical window report and extension tab requests. Installed by `ChromiumShell`.
final class ChromiumExtensionHost: ExtensionToolbarBackend {
    private let runtime: ChromiumRuntime
    private weak var model: BrowserViewModel?
    let popups: ExtensionPopupPresenter
    let sidePanels: ChromiumSidePanelHost
    /// Replaced by the self-test.
    var prompts: ExtensionPromptPresenting = AlertExtensionPromptPresenter()
    private var openPrompts: [UInt64: ExtensionPromptHandle] = [:]
    private var reporter = ExtensionWindowReporter()
    private var reconcileScheduled = false
    private var safetyTimer: Timer?
    /// Engines whose actions the toolbar shows (refreshed on action events).
    private var shownEngines: [ObjectIdentifier: WeakEngine] = [:]
    private var lastScale: CGFloat = 2
    /// Shown engines without a tab yet, asked again once they have one.
    private var waitingForTab: [ObjectIdentifier: WeakEngine] = [:]

    private struct WeakEngine { weak var engine: ChromiumEngine? }

    init(runtime: ChromiumRuntime, model: BrowserViewModel) {
        self.runtime = runtime
        self.model = model
        popups = ExtensionPopupPresenter(runtime: runtime)
        sidePanels = ChromiumSidePanelHost(runtime: runtime, model: model)
    }

    @MainActor
    func install() {
        guard let model else { return }
        let capabilities = runtime.capabilities
        model.extensions.backend = self
        model.extensions.isAvailable = capabilities.extensionToolbar
        popups.onChange = { [weak model, weak popups] in model?.extensions.openPopupExtensionID = popups?.extensionID }
        if capabilities.extensionActions {
            runtime.onExtensionActionEvent = { [weak self] in self?.handleActionEvent($0) }
            runtime.onExtensionPopupCreated = { [weak self] in
                guard let self else { return false }
                return self.popups.adopt($0) || self.sidePanels.adopt($0)
            }
        }
        sidePanels.spaceForLogicalWindow = { [weak self] in self?.reporter.key(forWindowID: $0) }
        sidePanels.install()
        if capabilities.extensionInstallPrompts {
            runtime.onExtensionPrompt = { [weak self] event in MainActor.assumeIsolated { self?.handlePrompt(event) } }
        }
        runtime.onTabClosed = { [weak self] event in
            self?.popups.tabClosed(event.tabID)
            self?.sidePanels.tabClosed(event.tabID)
            self?.reporter.forget(tab: event.tabID)
        }
        if capabilities.linkOpenRequests {
            runtime.onLinkOpen = { [weak self] event in MainActor.assumeIsolated { self?.handleLinkOpen(event) } }
        }
        if capabilities.extensionWindows {
            runtime.onExtensionTabRequest = { [weak self] request in MainActor.assumeIsolated { self?.handleTabRequest(request) } }
            observeWindows()
            // Engines made without a store change (an adopted popup tab) are caught here.
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileWindows() }
            }
        }
    }

    // MARK: Toolbar (ABI 1.33)

    func refreshActions(for engine: any WebEngine, scale: CGFloat) {
        guard let chromium = engine as? ChromiumEngine else { return }
        lastScale = scale
        shownEngines = shownEngines.filter { $0.value.engine != nil }
        shownEngines[ObjectIdentifier(chromium)] = WeakEngine(engine: chromium)
        guard chromium.tabID != 0 else { return refreshWhenTabExists(chromium) }
        let tab = chromium.tabID
        runtime.extensionActions(tab: tab, scale: Double(scale)) { [weak self, weak chromium] status, actions in
            guard let self, let chromium, status == .rearcOK, let actions, actions.tabID == chromium.tabID else { return }
            self.model?.extensions.setActions(actions.items, for: chromium)
        }
    }

    /// A restored tab's toolbar asks before its engine has a tab (the profile
    /// is still opening). It was never asked again, so an extension loaded
    /// meanwhile stayed out of its site controls (QA 2026-11-08 #20).
    private func refreshWhenTabExists(_ chromium: ChromiumEngine) {
        let key = ObjectIdentifier(chromium)
        waitingForTab = waitingForTab.filter { $0.value.engine != nil }
        guard waitingForTab[key] == nil else { return }
        waitingForTab[key] = WeakEngine(engine: chromium)
        withObservationTracking { _ = chromium.tabID } onChange: { [weak self, weak chromium] in
            DispatchQueue.main.async {
                self?.waitingForTab[key] = nil
                guard let self, let chromium else { return }
                self.refreshActions(for: chromium, scale: self.lastScale)
            }
        }
    }

    func runAction(_ extensionID: String, for engine: any WebEngine, anchor: NSView?) {
        guard let chromium = engine as? ChromiumEngine, chromium.tabID != 0 else { return }
        if popups.extensionID == extensionID, popups.ownerTabID == chromium.tabID {
            // A second click on the open popup's button closes it, as in Chrome.
            return popups.dismiss()
        }
        popups.dismiss()
        let (status, result, popup) = runtime.runExtensionAction(tab: chromium.tabID, extensionID: extensionID)
        switch result {
        case .popup:
            popups.expect(popupTab: popup, owner: chromium, extensionID: extensionID, anchor: anchor)
        case .sidePanel where runtime.capabilities.extensionSidePanels:
            sidePanels.toggle(extensionID, owner: chromium)
        case .sidePanel:
            model?.showToast("Side panel extensions need a newer engine", systemImage: "sidebar.right")
        case .handled:
            break
        case nil:
            ChromiumLog.info("extension action \(extensionID) refused: \(status.rearcName)")
            NSSound.beep()
        }
        refreshActions(for: chromium, scale: lastScale)
    }

    func selectedEngineChanged(_ engine: (any WebEngine)?) {
        // Chromium's ExtensionPopup closes on tab switch; so does this one.
        if let owner = popups.ownerTabID, (engine as? ChromiumEngine)?.tabID != owner { popups.dismiss() }
    }

    private func handleActionEvent(_ event: ChromiumExtensionActionEvent) {
        if event.kind == .popupResized {
            return popups.resize(popupTab: event.popupTabID, width: event.width, height: event.height)
        }
        // Events carry no state: ask again for the tabs on screen.
        for entry in shownEngines.values {
            guard let engine = entry.engine, engine.tabID != 0, event.tabID == 0 || event.tabID == engine.tabID || event.kind != .changed else { continue }
            refreshActions(for: engine, scale: lastScale)
        }
    }

    // MARK: Prompts (ABI 1.32)

    @MainActor
    private func handlePrompt(_ event: ChromiumExtensionPromptEvent) {
        let request = event.request
        switch event.phase {
        case .request:
            let window = runtime.engine(forTab: event.tabID)?.leaseHolder?.window ?? keyBrowserWindow
            let handle = prompts.present(request, in: window) { [weak self] action in
                self?.openPrompts[request.id] = nil
                self?.runtime.respondExtensionPrompt(request.id, action)
            }
            if let handle { openPrompts[request.id] = handle } else { runtime.respondExtensionPrompt(request.id, .cancel) }
        case .cancelled:
            // Withdrawn by the engine: close without a reply.
            openPrompts.removeValue(forKey: request.id)?.close()
        case .installed, .failed:
            let notice = event.notice
            model?.showToast(notice.message, systemImage: notice.succeeded ? "puzzlepiece.extension.fill" : "exclamationmark.triangle")
            for entry in shownEngines.values { if let engine = entry.engine { refreshActions(for: engine, scale: lastScale) } }
        }
    }

    private var keyBrowserWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    // MARK: Logical windows (ABI 1.36)

    /// Spaces are windows to extensions; so is each Little Arc window. The
    /// key window's space is focused, unless a Little Arc window is key.
    @MainActor
    func logicalWindows() -> [ExtensionLogicalWindow] {
        guard let model else { return [] }
        let store = model.store
        let active = store.activeSpaceID
        let littleArcKey = model.keyLittleArcID
        func bridgeTab(_ tab: Tab) -> UInt64? {
            guard let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) as? ChromiumEngine,
                  engine.tabID != 0 else { return nil }
            return engine.tabID
        }
        var windows: [ExtensionLogicalWindow] = []
        for space in [active] + store.spaces.map(\.id).filter({ $0 != active }) {
            let tabs = store.displayTabs(in: space).compactMap(bridgeTab)
            let selected = store.selectedTab(inSpace: space).flatMap(bridgeTab)
            windows.append(ExtensionLogicalWindow(key: space, tabs: tabs, activeTab: selected,
                                                  focused: space == active && littleArcKey == nil))
        }
        for record in store.littleArcLiveWindows {
            guard let engine = model.engineHost.existingLittleArcEngine(record.id, profileID: record.profileID) as? ChromiumEngine,
                  engine.tabID != 0 else { continue }
            windows.append(ExtensionLogicalWindow(key: record.id, tabs: [engine.tabID], activeTab: engine.tabID,
                                                  focused: littleArcKey == record.id))
        }
        return windows
    }

    /// Reports what changed; a refused call is retried next time.
    @MainActor
    func reconcileWindows() {
        guard runtime.capabilities.extensionWindows, runtime.isReady, !runtime.isStopping else { return }
        for call in reporter.plan(logicalWindows()) where runtime.setExtensionWindow(tab: call.tab, call.state) != .rearcOK {
            reporter.forget(tab: call.tab)
        }
    }

    var reportedWindows: [UInt64: ExtensionWindowState] { reporter.reported }

    func windowID(forSpace space: UUID) -> Int32 { reporter.windowID(for: space) }

    @MainActor
    private func observeWindows() {
        withObservationTracking { _ = logicalWindows() } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reconcileWindows()
                    self.observeWindows()
                }
            }
        }
        reconcileWindows()
    }

    // MARK: Tab requests (ABI 1.36)

    @MainActor
    private func handleTabRequest(_ request: ExtensionTabRequest) {
        guard let model else { return decline(request, "no browser model") }
        let store = model.store
        reconcileWindows()
        let windowSpace = request.windowID > 0 ? reporter.key(forWindowID: request.windowID).flatMap { store.space(withID: $0)?.id } : nil
        let active = store.activeSpaceID
        let order = [active] + store.spaces.map(\.id).filter { $0 != active }
        let placement = ExtensionTabPlacement.resolve(
            request, currentSpace: active, windowSpace: windowSpace, spaces: order
        ) { [runtime] space in
            guard let profile = store.space(withID: space)?.profileID else { return false }
            return runtime.engineProfileID(for: .persistent(profile)) == request.profileID
        }
        switch placement {
        case .decline(let reason):
            decline(request, reason)
        case .activate(let tab):
            guard let engine = runtime.engine(forTab: tab) else { return decline(request, "tab \(tab) is not open") }
            if engine.role == .littleArc, let record = store.littleArcLiveWindows.first(where: {
                model.engineHost.existingLittleArcEngine($0.id, profileID: $0.profileID) === engine
            }) {
                model.requestLittleArcWindow(record.id)
            } else {
                model.revealTab(showing: engine)
            }
            reconcileWindows()
            runtime.respondExtensionTabRequest(request.id, tab: tab)
        case .newTab(let space):
            guard let (tabID, tab) = adoptBlankTab(profile: request.profileID, in: space, model: model) else {
                return decline(request, "tab creation failed")
            }
            if request.active {
                if space != store.activeSpaceID { store.selectSpace(space) }
                model.selectTab(tab.id)
            }
            reconcileWindows()
            runtime.respondExtensionTabRequest(request.id, tab: tabID)
        case .littleArc:
            guard let tabID = runtime.createBlankTab(profile: request.profileID, role: .littleArc) else { return decline(request, "tab creation failed") }
            let event = ChromiumTabEvent.created(profileID: request.profileID, tabID: tabID, url: "about:blank")
            _ = model.adoptChromiumLittleArc(event, profileKey: runtime.profileKey(forEngineProfile: request.profileID),
                                             url: URL(string: "about:blank")!)
            reconcileWindows()
            runtime.respondExtensionTabRequest(request.id, tab: tabID)
        }
    }

    /// A blank registry tab in `profile`, adopted as a today tab of `space`
    /// (about:blank in the sidebar too, so selecting it loads nothing over
    /// the navigation the engine starts when the request is answered).
    @MainActor
    private func adoptBlankTab(profile: UInt64, in space: UUID, model: BrowserViewModel, title: String = "New Tab") -> (UInt64, Tab)? {
        guard let tabID = runtime.createBlankTab(profile: profile, role: .tab) else { return nil }
        let event = ChromiumTabEvent.created(profileID: profile, tabID: tabID, url: "about:blank")
        let blank = URL(string: "about:blank")!
        let tab = model.store.addTab(kind: .today, title: title, url: blank, in: space)
        let profileID = model.profileID(for: tab)
        let engine = ChromiumEngine(runtime: runtime, adopting: event, initialURL: blank,
                                    context: EngineProfileContext(profileID: profileID),
                                    profileKey: runtime.profileKey(forEngineProfile: profile) ?? .persistent(profileID),
                                    shellID: tab.id)
        engine.onNavigationCommit = { [weak model] url, title in model?.handleTabNavigationCommit(tabID: tab.id, url: url, title: title) }
        model.engineHost.adopt(engine, for: tab, profileID: profileID)
        model.observeFavicon(of: engine, tabID: tab.id)
        return (tabID, tab)
    }

    // MARK: Modified link opens (ABI 1.39)

    /// ⌘-click and middle-click: a background tab; ⇧⌘-click: a new tab;
    /// ⇧-click: Little Arc; a split disposition: a pane next to the source.
    /// ⌥⌘ held at the click stays Little Arc (wave 26). The engine navigates
    /// the new tab with the original request once it is answered.
    @MainActor
    private func handleLinkOpen(_ event: ChromiumLinkOpenEvent) {
        guard let model else { return declineLink(event, "no browser model") }
        let store = model.store
        let source = runtime.engine(forTab: event.openerTabID)
        let sourceTab = source.flatMap { engine in model.engineHost.allTabEngines().first { ($0.2 as AnyObject) === engine }?.0 }
        let placement = LinkOpenPlacement.resolve(disposition: event.disposition, littleArcKeysHeld: model.takeLittleArcClick(),
                                                  sourceTab: sourceTab)
        func inProfile(_ space: UUID) -> Bool {
            guard let profile = store.space(withID: space)?.profileID else { return false }
            return runtime.engineProfileID(for: .persistent(profile)) == event.profileID
        }
        let active = store.activeSpaceID
        let space = sourceTab.flatMap(store.spaceContaining(tabID:)).flatMap { inProfile($0) ? $0 : nil }
            ?? ([active] + store.spaces.map(\.id)).first(where: inProfile)
        ChromiumLog.info("link open \(event.requestID): disposition \(event.disposition) -> \(placement)")
        switch placement {
        case .decline(let reason):
            declineLink(event, reason)
        case .littleArc:
            guard let tabID = runtime.createBlankTab(profile: event.profileID, role: .littleArc) else { return declineLink(event, "tab creation failed") }
            _ = model.adoptChromiumLittleArc(ChromiumTabEvent.created(profileID: event.profileID, tabID: tabID, url: "about:blank"),
                                             profileKey: runtime.profileKey(forEngineProfile: event.profileID), url: URL(string: "about:blank")!)
            reconcileWindows()
            runtime.respondLinkOpen(event.requestID, tab: tabID)
        case .backgroundTab, .foregroundTab, .split:
            guard let space else { return declineLink(event, "no space in the link's profile") }
            guard let (tabID, tab) = adoptBlankTab(profile: event.profileID, in: space, model: model,
                                                   title: URL(string: event.url)?.host() ?? "New Tab") else {
                return declineLink(event, "tab creation failed")
            }
            if placement.isActive, space != store.activeSpaceID { store.selectSpace(space) }
            if case .split(let anchor) = placement, let split = store.splitTab(tab.id, with: anchor) {
                store.selectSplit(split.id, focusTabID: tab.id)
                model.loadSelectedIfNeeded()
            } else if placement.isActive {
                model.selectTab(tab.id)
            }
            reconcileWindows()
            runtime.respondLinkOpen(event.requestID, tab: tabID)
        }
    }

    private func declineLink(_ event: ChromiumLinkOpenEvent, _ reason: String) {
        ChromiumLog.info("link open \(event.requestID) declined: \(reason)")
        runtime.respondLinkOpen(event.requestID, tab: 0)
    }

    private func decline(_ request: ExtensionTabRequest, _ reason: String) {
        ChromiumLog.info("extension tab request \(request.id) declined: \(reason)")
        runtime.respondExtensionTabRequest(request.id, tab: 0)
    }
}

// MARK: - Action popups

/// The popup of an extension action: its registry tab (view type popup)
/// attached in a borderless panel under the button, sized by the renderer's
/// resize events. It closes on focus loss, Escape, tab switch, a second click
/// and the page's own `window.close()`, as Chromium's ExtensionPopup does.
/// The panel is never closed (only ordered out), so its engine window
/// registration stays valid for the next popup.
final class ExtensionPopupPresenter {
    private struct Pending {
        var popupTab: UInt64
        weak var owner: ChromiumEngine?
        var extensionID: String
        weak var anchor: NSView?
    }

    private let runtime: ChromiumRuntime
    private var pending: Pending?
    private(set) var engine: ChromiumEngine?
    private(set) var popupTabID: UInt64?
    private(set) var ownerTabID: UInt64?
    private(set) var extensionID: String?
    private(set) var size = ExtensionPopupGeometry.initial
    private(set) var resizes = 0
    private weak var anchor: NSView?
    private weak var parent: NSWindow?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var onChange: (() -> Void)?
    private lazy var panel = ExtensionPopupPanel()

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
    }

    var window: NSWindow? { engine == nil ? nil : panel }

    func expect(popupTab: UInt64, owner: ChromiumEngine, extensionID: String, anchor: NSView?) {
        pending = Pending(popupTab: popupTab, owner: owner, extensionID: extensionID, anchor: anchor)
    }

    /// The popup tab's created event (registered by `runExtensionAction`).
    func adopt(_ event: ChromiumTabEvent) -> Bool {
        guard let wanted = pending, wanted.popupTab == event.tabID, let owner = wanted.owner else { return false }
        pending = nil
        let url = event.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
        let engine = ChromiumEngine(runtime: runtime, adopting: event, initialURL: url, context: owner.profileContext,
                                    profileKey: runtime.profileKey(forEngineProfile: event.profileID) ?? owner.profileKey,
                                    shellID: UUID(), role: .peek)
        self.engine = engine
        popupTabID = event.tabID
        ownerTabID = owner.tabID
        extensionID = wanted.extensionID
        anchor = wanted.anchor
        size = ExtensionPopupGeometry.initial
        resizes = 0
        present(engine, near: wanted.anchor ?? owner.leaseHolder)
        onChange?()
        return true
    }

    func resize(popupTab: UInt64, width: Int32, height: Int32) {
        guard popupTab == popupTabID else { return }
        size = ExtensionPopupGeometry.clamped(width: width, height: height)
        resizes += 1
        position()
    }

    func tabClosed(_ tab: UInt64) {
        if pending?.popupTab == tab { pending = nil }
        // window.close() in the popup (reason 1), or the engine closed it.
        if tab == popupTabID { dismiss() }
    }

    func dismiss() {
        pending = nil
        guard engine != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        // Detach first: the host leaves the panel and ends its lease.
        ChromiumHostView.dismantleAll(in: panel)
        panel.contentView = NSView()
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
        // Releasing the engine force-closes the popup tab (a no-op once the page closed it).
        engine = nil
        popupTabID = nil
        ownerTabID = nil
        extensionID = nil
        onChange?()
    }

    private func present(_ engine: ChromiumEngine, near anchorView: NSView?) {
        let host = NSHostingView(rootView: engine.makeView())
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        if let window = anchorView?.window {
            if parent !== window {
                parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
                parent = window
            }
        }
        position()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.dismiss()
        }
    }

    /// Below the anchor's leading edge, kept on its screen.
    private func position() {
        let screen = (anchor?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY)
        if let anchor, let window = anchor.window {
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            origin = CGPoint(x: rect.minX, y: rect.minY - 6 - size.height)
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = max(origin.y, screen.minY)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

final class ExtensionPopupPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: ExtensionPopupGeometry.initial), styleMask: [.borderless],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        title = "Extension popup"
    }

    // The popup's page takes typing (search boxes, forms).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Install, re-enable, permission and uninstall sheets

protocol ExtensionPromptHandle: AnyObject {
    /// The engine withdrew the request: close without a reply.
    func close()
}

protocol ExtensionPromptPresenting: AnyObject {
    /// nil when it cannot be shown (the request is then cancelled).
    func present(_ request: ExtensionPromptRequest, in window: NSWindow?,
                 completion: @escaping (ExtensionPromptAction) -> Void) -> ExtensionPromptHandle?
}

/// An NSAlert sheet on the page's window (the key window for prompts that
/// belong to no tab), with Chromium's localized title, buttons, permission
/// lines and the extension's icon.
final class AlertExtensionPromptPresenter: ExtensionPromptPresenting {
    private final class Handle: ExtensionPromptHandle {
        weak var alert: NSAlert?
        weak var window: NSWindow?
        var withdrawn = false

        func close() {
            withdrawn = true
            guard let sheet = alert?.window, let window else { return }
            window.endSheet(sheet, returnCode: .abort)
        }
    }

    func present(_ request: ExtensionPromptRequest, in window: NSWindow?,
                 completion: @escaping (ExtensionPromptAction) -> Void) -> ExtensionPromptHandle? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = request.displayTitle
        alert.informativeText = request.informativeText
        alert.alertStyle = request.isDestructive ? .warning : .informational
        if let data = request.iconPNG, let icon = NSImage(data: data) { alert.icon = icon }
        let accept = alert.addButton(withTitle: request.displayAcceptLabel)
        if request.isDestructive { accept.hasDestructiveAction = true }
        alert.addButton(withTitle: request.displayCancelLabel)
        let handle = Handle()
        handle.alert = alert
        handle.window = window
        alert.beginSheetModal(for: window) { response in
            guard !handle.withdrawn else { return }
            completion(response == .alertFirstButtonReturn ? .accept : .cancel)
        }
        return handle
    }
}
#endif
