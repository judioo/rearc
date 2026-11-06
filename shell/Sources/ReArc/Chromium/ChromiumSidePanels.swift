#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Extension side panels (ABI 1.47 `extension_side_panels`, C-ABI.md
// "Extension side panels (1.47)"): chrome.sidePanel pages as hosted registry
// tabs. The callback is registered at ready, before any tab; a panel tab's
// created event is announced like an action popup's, so it is never adopted
// as a sidebar tab.

/// Owned copy of `ReArcSidePanelEvent`.
struct ChromiumSidePanelEvent: Equatable {
    enum Kind: UInt32 {
        /// sidePanel.open (a user gesture in the extension).
        case openRequested = 0
        /// sidePanel.close, or `panelTabID` was disabled by setOptions.
        case closeRequested
        /// setOptions changed (`tabID` 0: the global options).
        case optionsChanged
    }

    var profileID, tabID, panelTabID: UInt64
    var windowID: Int32
    var kind: Kind
    var extensionID: String
}

/// `ReArcSidePanelInfo` for one tab and extension.
struct ChromiumSidePanelInfo: Equatable {
    var isAvailable: Bool
    var isContextual: Bool
    var opensOnActionClick: Bool
}

private let sidePanelCallback: ReArcSidePanelCallback = { context, event in
    guard let context, let e = event?.pointee, let kind = ChromiumSidePanelEvent.Kind(rawValue: e.kind) else { return }
    let copied = ChromiumSidePanelEvent(profileID: e.profile_id, tabID: e.tab_id, panelTabID: e.panel_tab_id,
                                        windowID: e.window_id, kind: kind,
                                        extensionID: e.extension_id.map { String(cString: $0) } ?? "")
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().handleSidePanel(copied)
    }
}

extension ChromiumRuntime {
    /// Registered at `ready`, before any tab exists.
    func registerSidePanelChannel(context: UnsafeMutableRawPointer) {
        if capabilities.extensionSidePanels { ReArcEngineSetSidePanelCallback(sidePanelCallback, context) }
    }

    fileprivate func handleSidePanel(_ event: ChromiumSidePanelEvent) {
        ChromiumLog.info("side_panel \(event.kind) extension \(event.extensionID) tab \(event.tabID) "
            + "window \(event.windowID) panel \(event.panelTabID)")
        onSidePanelEvent?(event)
    }

    /// nil when unsupported or refused (logged).
    func sidePanelInfo(tab: UInt64, extensionID: String) -> ChromiumSidePanelInfo? {
        guard capabilities.extensionSidePanels, isReady, !isStopping, tab != 0 else { return nil }
        var info = ReArcSidePanelInfo()
        let status = extensionID.withCString { ReArcTabGetSidePanel(tab, $0, &info) }
        guard status == .rearcOK else {
            ChromiumLog.info("side panel info \(extensionID) on tab \(tab) refused: \(status.rearcName)")
            return nil
        }
        return ChromiumSidePanelInfo(isAvailable: info.available, isContextual: info.contextual,
                                     opensOnActionClick: info.open_on_action_click)
    }

    /// A new panel tab for `tab`'s options. Like an action popup, its created
    /// event is expected before it arrives, so it is adopted as a panel.
    func openSidePanel(tab: UInt64, extensionID: String) -> (status: ReArcStatus, contextual: Bool, panelTab: UInt64) {
        guard capabilities.extensionSidePanels, isReady, !isStopping else { return (ReArcStatus(REARC_UNSUPPORTED), false, 0) }
        var contextual = false
        var panel: UInt64 = 0
        let status = extensionID.withCString { ReArcTabOpenSidePanel(tab, $0, &contextual, &panel) }
        if status == .rearcOK, panel != 0 { expectedExtensionPopups.insert(panel) }
        ChromiumLog.info("open side panel \(extensionID) for tab \(tab) -> \(status.rearcName) panel \(panel) contextual \(contextual)")
        return (status, contextual, panel)
    }

    /// sidePanel.onOpened / onClosed; logged only when refused.
    @discardableResult
    func setSidePanelShown(panel: UInt64, owner: UInt64, shown: Bool) -> ReArcStatus {
        guard capabilities.extensionSidePanels, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcSidePanelSetShown(panel, owner, shown)
        if status != .rearcOK { ChromiumLog.info("side panel \(panel) shown \(shown) beside \(owner) refused: \(status.rearcName)") }
        return status
    }
}

#endif
