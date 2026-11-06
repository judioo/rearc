#if REARC_CHROMIUM
import AppKit
import Observation
import SidebarModel

/// Extension side panels on Chromium (ABI 1.47): each browser window shows at
/// most one, beside its page. A toolbar click on an action with
/// `openPanelOnActionClick` toggles it (another extension's panel is
/// replaced), sidePanel.open / close come as engine events, and the panel
/// follows the window's tab switches: a global panel stays with the same
/// page, a contextual one shows only beside its tab. The panel's own
/// `window.close()`, the close button and a tab without a panel close it.
/// Panels are registry tabs held as engines here; releasing one closes it.
final class ChromiumSidePanelHost: ExtensionSidePanelBackend {
    private let runtime: ChromiumRuntime
    private weak var model: BrowserViewModel?
    /// The space a logical extension window stands for (the window reporter's).
    var spaceForLogicalWindow: (Int32) -> UUID? = { _ in nil }
    private var windows: [SidebarWindowID: SidePanelWindowState] = [:]
    private var engines: [UInt64: ChromiumEngine] = [:]
    /// Panels the engine made, until their created event.
    private var pending: [UInt64: (window: SidebarWindowID, owner: UInt64, contextual: Bool)] = [:]

    init(runtime: ChromiumRuntime, model: BrowserViewModel) {
        self.runtime = runtime
        self.model = model
    }

    private var controller: ExtensionSidePanelController? { model?.extensions.sidePanels }

    func install() {
        guard runtime.capabilities.extensionSidePanels, let model else { return }
        model.extensions.sidePanels.backend = self
        runtime.onSidePanelEvent = { [weak self] in self?.handle($0) }
    }

    // MARK: Toolbar (run result 2)

    /// A click on `extensionID`'s action in the key window, beside `owner`.
    func toggle(_ extensionID: String, owner: ChromiumEngine) {
        guard let window = window(showing: owner.tabID) else { return }
        switch SidePanelToggle.resolve(shownExtension: windows[window]?.extensionID, clicked: extensionID) {
        case .close:
            close(window)
        case .replace:
            replace(window, with: extensionID, owner: owner.tabID)
        case .open:
            open(extensionID, in: window, owner: owner.tabID)
        }
    }

    func closeSidePanel(in window: SidebarWindowID) {
        close(window)
    }

    // MARK: Engine events

    private func handle(_ event: ChromiumSidePanelEvent) {
        switch event.kind {
        case .openRequested:
            if event.tabID != 0 {
                // A tab that is not on screen gets nothing (Chrome would open it when the tab is next shown).
                guard let window = window(showing: event.tabID) else { return }
                replace(window, with: event.extensionID, owner: event.tabID)
            } else if let window = window(forLogicalWindow: event.windowID), let owner = pageTab(in: window) {
                replace(window, with: event.extensionID, owner: owner)
            }
        case .closeRequested:
            for (window, state) in windows where state.extensionID == event.extensionID {
                // setOptions disabled a panel; sidePanel.close({tabId}) ends that tab's own
                // panel, ({windowId}) the global one, as in Chrome.
                let panel = event.panelTabID != 0 ? event.panelTabID
                    : event.tabID != 0 ? state.contextualPanels[event.tabID]
                    : spaceForLogicalWindow(event.windowID) == model?.store.focusedSpaceID(in: window) ? state.globalPanel : nil
                guard let panel, state.panels.contains(panel) else { continue }
                if event.panelTabID != 0 {
                    // The window shows what the tab has left (a global panel, or nothing).
                    release(panel, in: window)
                    reconcile(window, force: true)
                } else if state.shownPanel == panel {
                    close(window)
                } else {
                    release(panel, in: window)
                }
            }
        case .optionsChanged:
            for (window, state) in windows where state.extensionID == event.extensionID {
                reconcile(window, force: true)
            }
        }
    }

    /// A popup-disposition created event: ours if `openSidePanel` announced it.
    func adopt(_ event: ChromiumTabEvent) -> Bool {
        guard let wanted = pending.removeValue(forKey: event.tabID), var state = windows[wanted.window],
              let owner = runtime.engine(forTab: wanted.owner) else { return false }
        let url = event.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
        let engine = ChromiumEngine(runtime: runtime, adopting: event, initialURL: url, context: owner.profileContext,
                                    profileKey: runtime.profileKey(forEngineProfile: event.profileID) ?? owner.profileKey,
                                    shellID: UUID(), role: .peek)
        engines[event.tabID] = engine
        state.adopt(panel: event.tabID, contextual: wanted.contextual, owner: wanted.owner)
        windows[wanted.window] = state
        show(event.tabID, in: wanted.window, owner: wanted.owner)
        return true
    }

    /// Every tab.closed: a panel's own window.close(), or a page tab whose
    /// contextual panel goes with it.
    func tabClosed(_ tab: UInt64) {
        pending[tab] = nil
        for (window, var state) in windows {
            if state.panels.contains(tab) {
                engines[tab] = nil
                if state.shownPanel == tab {
                    // The shown page closed itself: the window's panel closes, as in Chrome.
                    close(window)
                } else {
                    state.forget(panel: tab)
                    windows[window] = state
                }
            } else if let panel = state.forget(ownerTab: tab) {
                engines[panel] = nil
                windows[window] = state
            }
        }
    }

    // MARK: Windows

    /// Observes what each window with a panel shows, to follow tab switches.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.store.focusedSpaceByWindow.count
            for window in windows.keys { _ = (model.focusedEngine(in: window) as? ChromiumEngine)?.tabID }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for window in self.windows.keys { self.reconcile(window, force: false) }
                    if !self.windows.isEmpty { self.observe() }
                }
            }
        }
    }

    /// Opens `extensionID`'s panel; another extension's pane stays on screen
    /// until the new page replaces it, as in the recording (no close and reopen).
    private func replace(_ window: SidebarWindowID, with extensionID: String, owner: UInt64) {
        if let shown = windows[window]?.extensionID, shown != extensionID { close(window, keepingPane: true) }
        open(extensionID, in: window, owner: owner)
    }

    private func open(_ extensionID: String, in window: SidebarWindowID, owner: UInt64) {
        let wasEmpty = windows.isEmpty
        if windows[window] == nil { windows[window] = SidePanelWindowState(extensionID: extensionID, ownerTab: owner) }
        reconcile(window, force: true, owner: owner)
        if wasEmpty, !windows.isEmpty { observe() }
    }

    /// Shows what the window's page tab should have beside it.
    private func reconcile(_ window: SidebarWindowID, force: Bool, owner: UInt64? = nil) {
        guard var state = windows[window] else { return }
        // A closed browser window releases its panels.
        guard model?.store.focusedSpaceByWindow[window] != nil else { return close(window) }
        guard let tab = owner ?? pageTab(in: window) else { return }  // An easel or the Library: the panel stays.
        if !force, tab == state.ownerTab, state.shownPanel != nil { return }
        guard let info = runtime.sidePanelInfo(tab: tab, extensionID: state.extensionID) else { return close(window) }
        switch state.decision(for: tab, available: info.isAvailable, contextual: info.isContextual) {
        case .close:
            close(window)
        case .show(let panel):
            show(panel, in: window, owner: tab)
        case .create(let contextual):
            guard !pending.values.contains(where: { $0.window == window && $0.owner == tab }) else { return }
            let (status, made, panel) = runtime.openSidePanel(tab: tab, extensionID: state.extensionID)
            guard status == .rearcOK, panel != 0 else {
                if state.shownPanel == nil { close(window) }
                return
            }
            if made != contextual { ChromiumLog.info("side panel scope changed under the open call: contextual \(made)") }
            state.ownerTab = tab
            windows[window] = state
            pending[panel] = (window, tab, made)
        }
    }

    private func show(_ panel: UInt64, in window: SidebarWindowID, owner: UInt64) {
        guard var state = windows[window], let engine = engines[panel] else { return }
        if let previous = state.shownPanel, previous != panel {
            runtime.setSidePanelShown(panel: previous, owner: 0, shown: false)
        }
        state.shownPanel = panel
        state.ownerTab = owner
        windows[window] = state
        runtime.setSidePanelShown(panel: panel, owner: owner, shown: true)
        let item = runtime.engine(forTab: owner).flatMap { model?.extensions.actions(for: $0).first { $0.id == state.extensionID } }
        let previous = controller?.panel(in: window)
        controller?.setShown(ExtensionSidePanelController.Shown(
            extensionID: state.extensionID,
            title: item?.name ?? previous?.title ?? "Extension",
            iconPNG: item?.iconPNG ?? previous?.iconPNG,
            engine: engine, panelID: panel), in: window)
    }

    /// Hides and releases every panel of the window. `keepingPane` leaves the
    /// pane showing the old page (it holds its engine) until a new one is shown.
    private func close(_ window: SidebarWindowID, keepingPane: Bool = false) {
        pending = pending.filter { $0.value.window != window }
        if !keepingPane { controller?.setShown(nil, in: window) }
        guard let state = windows.removeValue(forKey: window) else { return }
        if let shown = state.shownPanel { runtime.setSidePanelShown(panel: shown, owner: 0, shown: false) }
        // Releasing an engine force-closes its panel tab.
        for panel in state.panels { engines[panel] = nil }
    }

    private func release(_ panel: UInt64, in window: SidebarWindowID) {
        guard var state = windows[window] else { return }
        if state.shownPanel == panel {
            runtime.setSidePanelShown(panel: panel, owner: 0, shown: false)
            controller?.setShown(nil, in: window)
        }
        state.forget(panel: panel)
        windows[window] = state
        engines[panel] = nil
    }

    /// The page tab a window shows (nil for an easel, a note or the Library).
    private func pageTab(in window: SidebarWindowID) -> UInt64? {
        guard let engine = model?.focusedEngine(in: window) as? ChromiumEngine, engine.tabID != 0,
              engine.role == .tab else { return nil }
        return engine.tabID
    }

    /// The window showing `tab`, the key window first.
    private func window(showing tab: UInt64) -> SidebarWindowID? {
        guard let store = model?.store else { return nil }
        let candidates = (store.keyWindowID.map { [$0] } ?? []) + store.focusedSpaceByWindow.keys.filter { $0 != store.keyWindowID }
        return candidates.first { pageTab(in: $0) == tab }
    }

    /// A browser window showing the logical window's space, the key window first.
    private func window(forLogicalWindow id: Int32) -> SidebarWindowID? {
        guard let store = model?.store, let space = spaceForLogicalWindow(id) else { return nil }
        let candidates = (store.keyWindowID.map { [$0] } ?? []) + store.focusedSpaceByWindow.keys.filter { $0 != store.keyWindowID }
        return candidates.first { store.focusedSpaceID(in: $0) == space }
    }
}
#endif
