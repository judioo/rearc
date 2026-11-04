#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Extensions (ABI 1.31–1.33, 1.36; C-ABI.md "Extension tab helpers" through
// "Extension shell windows"). Each channel is registered at `ready`, before
// any tab, only when the engine reports its minor and feature. Events carry
// borrowed strings and icons: they are copied here. A request nobody in the
// shell handles gets the conservative answer at once (cancel, decline).

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

private func data(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> Data? {
    guard let bytes, count > 0 else { return nil }
    return Data(bytes: bytes, count: count)
}

/// Owned copy of `ReArcExtensionPromptEvent`.
struct ChromiumExtensionPromptEvent {
    var profileID, tabID: UInt64
    var phase: ExtensionPromptPhase
    var request: ExtensionPromptRequest
    /// Phase 3 only.
    var error: String

    init?(_ pointer: UnsafePointer<ReArcExtensionPromptEvent>?) {
        guard let e = pointer?.pointee, let phase = ExtensionPromptPhase(rawValue: e.phase) else { return nil }
        profileID = e.profile_id
        tabID = e.tab_id
        self.phase = phase
        var permissions: [String] = []
        if let list = e.permissions {
            for index in 0..<e.permission_count { if let line = list[index] { permissions.append(String(cString: line)) } }
        }
        request = ExtensionPromptRequest(
            id: e.request_id, tabID: e.tab_id, kind: ExtensionPromptKind(rawValue: e.kind),
            extensionID: string(e.extension_id), name: string(e.name), title: string(e.title),
            acceptLabel: string(e.accept_label), cancelLabel: string(e.cancel_label), permissions: permissions,
            triggeringExtension: string(e.triggering_extension), iconPNG: data(e.icon_png, e.icon_png_size)
        )
        error = string(e.error)
    }

    var notice: ExtensionInstallNotice {
        ExtensionInstallNotice(extensionID: request.extensionID, name: request.name, succeeded: phase == .installed, error: error)
    }
}

/// Owned copy of `ReArcExtensionActionEvent`.
struct ChromiumExtensionActionEvent: Equatable {
    enum Kind: UInt32 {
        case changed = 0, added, removed, popupResized
    }

    var profileID, tabID: UInt64
    var kind: Kind
    var extensionID: String
    var popupTabID: UInt64
    var width, height: Int32
}

/// Copied action list of one tab.
struct ChromiumExtensionActions {
    var tabID: UInt64
    var contentGeneration: UInt64
    var items: [ExtensionActionItem]
}

/// Context for one `ReArcTabGetExtensionActions`; released once.
final class ExtensionActionsBox {
    static var live = 0
    let body: (ReArcStatus, ChromiumExtensionActions?) -> Void

    init(_ body: @escaping (ReArcStatus, ChromiumExtensionActions?) -> Void) {
        self.body = body
        Self.live += 1
    }

    deinit { Self.live -= 1 }
}

private let extensionActionsCompletion: ReArcExtensionActionsCallback = { context, status, list in
    guard let context else { return }
    var copied: ChromiumExtensionActions?
    if status == .rearcOK, let l = list?.pointee {
        var items: [ExtensionActionItem] = []
        if let actions = l.actions {
            for index in 0..<l.count {
                let a = actions[index]
                items.append(ExtensionActionItem(
                    id: string(a.extension_id), name: string(a.name), title: string(a.title), badgeText: string(a.badge_text),
                    badgeTextColor: a.badge_text_color, badgeBackgroundColor: a.badge_background_color,
                    isEnabled: a.visible, hasPopup: a.has_popup, wantsToRun: a.wants_to_run,
                    iconPNG: data(a.icon_png, a.icon_png_size)
                ))
            }
        }
        copied = ChromiumExtensionActions(tabID: l.tab_id, contentGeneration: l.content_generation, items: items)
    }
    let box = Unmanaged<ExtensionActionsBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, copied) }
}

private func extensionRuntime(_ context: UnsafeMutableRawPointer?) -> ChromiumRuntime {
    Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue()
}

private let extensionPromptCallback: ReArcExtensionPromptCallback = { context, event in
    guard let copied = ChromiumExtensionPromptEvent(event) else { return }
    MainActor.assumeIsolated { extensionRuntime(context).handleExtensionPrompt(copied) }
}

private let extensionActionCallback: ReArcExtensionActionCallback = { context, event in
    guard let e = event?.pointee, let kind = ChromiumExtensionActionEvent.Kind(rawValue: e.kind) else { return }
    let copied = ChromiumExtensionActionEvent(profileID: e.profile_id, tabID: e.tab_id, kind: kind, extensionID: string(e.extension_id),
                                              popupTabID: e.popup_tab_id, width: e.width, height: e.height)
    MainActor.assumeIsolated { extensionRuntime(context).handleExtensionAction(copied) }
}

private let extensionTabRequestCallback: ReArcExtensionTabRequestCallback = { context, event in
    guard let e = event?.pointee, let kind = ExtensionTabRequestKind(rawValue: e.kind) else { return }
    let copied = ExtensionTabRequest(
        id: e.request_id, profileID: e.profile_id, tabID: e.tab_id, openerTabID: e.opener_tab_id, windowID: e.window_id,
        kind: kind, isWithdrawal: e.phase == 1, active: e.active, url: string(e.url), extensionID: string(e.extension_id)
    )
    MainActor.assumeIsolated { extensionRuntime(context).handleExtensionTabRequest(copied) }
}

/// Owned copy of `ReArcLinkOpenEvent` (ABI 1.39).
struct ChromiumLinkOpenEvent: Equatable {
    var profileID, openerTabID, contentGeneration, requestID: UInt64
    var isWithdrawal: Bool
    var disposition: UInt32
    var userGesture: Bool
    var url: String
    /// Chromium-sanitized, display only; the engine keeps the real one.
    var referrer: String
}

private let linkOpenCallback: ReArcLinkOpenCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumLinkOpenEvent(
        profileID: e.profile_id, openerTabID: e.opener_tab_id, contentGeneration: e.content_generation, requestID: e.request_id,
        isWithdrawal: e.phase == 1, disposition: e.disposition, userGesture: e.user_gesture, url: string(e.url), referrer: string(e.referrer)
    )
    MainActor.assumeIsolated { extensionRuntime(context).handleLinkOpen(copied) }
}

extension ChromiumRuntime {
    /// Registers the adopted extension channels; called at `ready`, before any tab exists.
    func registerExtensionChannels(context: UnsafeMutableRawPointer) {
        if capabilities.extensionInstallPrompts { ReArcEngineSetExtensionPromptCallback(extensionPromptCallback, context) }
        if capabilities.extensionActions { ReArcEngineSetExtensionActionCallback(extensionActionCallback, context) }
        if capabilities.extensionWindows { ReArcEngineSetExtensionTabRequestCallback(extensionTabRequestCallback, context) }
        if capabilities.linkOpenRequests { ReArcEngineSetLinkOpenCallback(linkOpenCallback, context) }
    }

    fileprivate func handleLinkOpen(_ event: ChromiumLinkOpenEvent) {
        ChromiumLog.info("link_open \(event.requestID) withdrawn \(event.isWithdrawal) disposition \(event.disposition) "
            + "opener \(event.openerTabID) gesture \(event.userGesture) url \(event.url)")
        linkOpenEvents.append(event)
        guard !event.isWithdrawal else { return }
        if let handler = onLinkOpen {
            handler(event)
        } else {
            respondLinkOpen(event.requestID, tab: 0)
        }
    }

    @discardableResult
    func respondLinkOpen(_ request: UInt64, tab: UInt64) -> ReArcStatus {
        guard capabilities.linkOpenRequests, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcLinkOpenRespond(request, tab)
        ChromiumLog.info("link open \(request) reply tab \(tab) -> \(status.rearcName)")
        return status
    }

    // MARK: Events

    fileprivate func handleExtensionPrompt(_ event: ChromiumExtensionPromptEvent) {
        let request = event.request
        ChromiumLog.info("extension_prompt phase \(event.phase) kind \(request.kind) request \(request.id) tab \(event.tabID) "
            + "extension \(request.extensionID) '\(request.name)' permissions \(request.permissions.count)"
            + (event.error.isEmpty ? "" : " error \(event.error)"))
        extensionPromptEvents.append(event)
        if let handler = onExtensionPrompt {
            handler(event)
        } else if event.phase == .request {
            respondExtensionPrompt(request.id, .cancel)
        }
    }

    fileprivate func handleExtensionAction(_ event: ChromiumExtensionActionEvent) {
        ChromiumLog.trace("extension_action kind \(event.kind) tab \(event.tabID) extension \(event.extensionID) "
            + "popup \(event.popupTabID) \(event.width)x\(event.height)")
        extensionActionEvents.append(event)
        onExtensionActionEvent?(event)
    }

    fileprivate func handleExtensionTabRequest(_ request: ExtensionTabRequest) {
        ChromiumLog.info("extension_tab_request \(request.id) kind \(request.kind) withdrawn \(request.isWithdrawal) profile \(request.profileID) "
            + "tab \(request.tabID) opener \(request.openerTabID) window \(request.windowID) active \(request.active) url \(request.url)")
        extensionTabRequests.append(request)
        guard !request.isWithdrawal else { return }
        if let handler = onExtensionTabRequest {
            handler(request)
        } else {
            respondExtensionTabRequest(request.id, tab: 0)
        }
    }

    // MARK: Calls (main thread)

    @discardableResult
    func respondExtensionPrompt(_ request: UInt64, _ action: ExtensionPromptAction) -> ReArcStatus {
        guard capabilities.extensionInstallPrompts, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcExtensionPromptRespond(request, action.rawValue)
        ChromiumLog.info("extension prompt reply \(request) \(action) -> \(status.rearcName)")
        return status
    }

    /// The tab's actions at `scale`, delivered deferred; a synchronous rejection never calls `completion`.
    @discardableResult
    func extensionActions(tab: UInt64, scale: Double, completion: @escaping (ReArcStatus, ChromiumExtensionActions?) -> Void) -> ReArcStatus {
        guard capabilities.extensionActions, isReady, !isStopping, tab != 0 else { return ReArcStatus(REARC_UNSUPPORTED) }
        let box = Unmanaged.passRetained(ExtensionActionsBox(completion)).toOpaque()
        let status = ReArcTabGetExtensionActions(tab, min(max(scale, 1), 4), extensionActionsCompletion, box)
        if status != .rearcOK { Unmanaged<ExtensionActionsBox>.fromOpaque(box).release() }
        return status
    }

    var liveExtensionActionContexts: Int { ExtensionActionsBox.live }

    /// A toolbar click. A popup result registers the popup tab before its
    /// created event arrives, so it is adopted as a popup, never as a tab.
    func runExtensionAction(tab: UInt64, extensionID: String) -> (ReArcStatus, ExtensionActionRunResult?, UInt64) {
        guard capabilities.extensionActions, isReady, !isStopping else { return (ReArcStatus(REARC_UNSUPPORTED), nil, 0) }
        var result: UInt32 = 0
        var popup: UInt64 = 0
        let status = extensionID.withCString { ReArcTabRunExtensionAction(tab, $0, &result, &popup) }
        let run = status == .rearcOK ? ExtensionActionRunResult(rawValue: result) : nil
        if run == .popup, popup != 0 { expectedExtensionPopups.insert(popup) }
        ChromiumLog.info("run extension action \(extensionID) on tab \(tab) -> \(status.rearcName) result \(run.map { "\($0)" } ?? "-") popup \(popup)")
        return (status, run, popup)
    }

    /// Consumes the expectation for a popup tab's created event.
    func takeExpectedExtensionPopup(_ tab: UInt64) -> Bool {
        expectedExtensionPopups.remove(tab) != nil
    }

    @discardableResult
    func respondExtensionTabRequest(_ request: UInt64, tab: UInt64) -> ReArcStatus {
        guard capabilities.extensionWindows, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcExtensionTabRequestRespond(request, tab)
        ChromiumLog.info("extension tab request \(request) reply tab \(tab) -> \(status.rearcName)")
        return status
    }

    /// `ReArcTabSetExtensionWindow`; logged only when refused.
    @discardableResult
    func setExtensionWindow(tab: UInt64, _ state: ExtensionWindowState) -> ReArcStatus {
        guard capabilities.extensionWindows, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcTabSetExtensionWindow(tab, state.windowID, state.active, state.focused)
        if status == .rearcOK {
            ChromiumLog.trace("extension window tab \(tab) -> window \(state.windowID) active \(state.active) focused \(state.focused)")
        } else {
            ChromiumLog.info("extension window tab \(tab) -> window \(state.windowID) refused: \(status.rearcName)")
        }
        return status
    }

    func extensionState(tab: UInt64) -> (ReArcStatus, ReArcExtensionTabState) {
        var state = ReArcExtensionTabState()
        guard capabilities.extensionWindows else { return (ReArcStatus(REARC_UNSUPPORTED), state) }
        let status = ReArcTabGetExtensionState(tab, &state)
        return (status, state)
    }

    /// A tab created in `profile` for an extension request (about:blank; the
    /// engine loads the extension's URL when the request is answered).
    func createBlankTab(profile: UInt64, role: EngineRole) -> UInt64? {
        guard isReady, !isStopping else { return nil }
        var tab: UInt64 = 0
        let status = "about:blank".withCString { ReArcTabCreate(profile, role.rawValue, $0, &tab) }
        guard status == .rearcOK, tab != 0 else {
            ChromiumLog.info("ReArcTabCreate(profile \(profile), about:blank) for an extension failed: \(status.rearcName)")
            return nil
        }
        return tab
    }
}

extension ChromiumTabEvent {
    /// The created event of a tab the shell made itself (its real event follows).
    static func created(profileID: UInt64, tabID: UInt64, url: String) -> ChromiumTabEvent {
        var event = ReArcTabEvent()
        event.kind = Kind.created.rawValue
        event.profile_id = profileID
        event.tab_id = tabID
        return url.withCString { pointer in
            event.url = pointer
            return withUnsafePointer(to: event) { ChromiumTabEvent($0)! }
        }
    }
}
#endif
