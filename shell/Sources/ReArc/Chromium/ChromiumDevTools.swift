#if REARC_CHROMIUM
import AppKit
import ReArcEngine
import SidebarModel

/// Hosted DevTools (ABI 1.40), dockable since ABI 1.54, and client-certificate
/// selection (ABI 1.41). Follows "Shell adoption" in engine/docs/WAVE-18H-REPORT.md
/// and "Dockable DevTools" in engine/docs/C-ABI.md.

/// A dockable frontend's Dock side and where it put the page (`ReArcDevToolsDockEvent`).
struct ChromiumDevToolsDockEvent: Equatable {
    var frontendTabID, targetTabID: UInt64
    var layout: DevToolsDockLayout
}

private let devToolsDockCallback: ReArcDevToolsDockCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumDevToolsDockEvent(
        frontendTabID: e.frontend_tab_id, targetTabID: e.target_tab_id,
        layout: DevToolsDockLayout(
            side: DevToolsDockSide(rawValue: e.dock_side) ?? .right, inTabTabID: e.in_tab_tab_id,
            pageBounds: e.has_bounds ? CGRect(x: Int(e.x), y: Int(e.y), width: Int(e.width), height: Int(e.height)) : nil)
    )
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue().onDevToolsDock?(copied)
    }
}

struct ChromiumClientCertificateEvent {
    var identity: ChromiumPromptIdentity
    var request: ClientCertificateRequest
}

private func certificateString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

private let clientCertificateCallback: ReArcClientCertificateCallback = { context, event in
    guard let e = event?.pointee else { return }
    var identities: [ClientCertificateIdentity] = []
    if let list = e.identities {
        for index in 0 ..< min(e.identity_count, 256) {
            let item = list[index]
            identities.append(ClientCertificateIdentity(
                fingerprint: certificateString(item.fingerprint), subject: certificateString(item.subject),
                issuer: certificateString(item.issuer), expiryMicroseconds: item.expiry_us))
        }
    }
    let copied = ChromiumClientCertificateEvent(
        identity: ChromiumPromptIdentity(profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
                                         requestID: e.request_id, isCancellation: e.phase == 1),
        request: ClientCertificateRequest(id: e.request_id, origin: certificateString(e.origin), identities: identities)
    )
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue().handleClientCertificate(copied)
    }
}

extension ChromiumRuntime {
    // MARK: DevTools

    /// A new frontend for `target`; its created event goes to `onDevToolsFrontendCreated`.
    func openDevTools(target: UInt64) -> (status: ReArcStatus, frontend: UInt64) {
        guard capabilities.devTools, isReady, !isStopping else { return (ReArcStatus(REARC_UNSUPPORTED), 0) }
        var frontend: UInt64 = 0
        devToolsOpeningTarget = target
        let status = ReArcTabOpenDevTools(target, &frontend)
        devToolsOpeningTarget = 0
        if status == .rearcOK, frontend != 0, !devToolsFrontends.contains(frontend) {
            expectedDevToolsFrontends.insert(frontend)
        }
        ChromiumLog.info("devtools open target \(target) -> \(status.rearcName) frontend \(frontend)")
        return (status, frontend)
    }

    /// Frontends dock as in Chrome: the engine has the feature and its export.
    var supportsDevToolsDocking: Bool {
        capabilities.devToolsDocking && dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineSetDevToolsDockCallback") != nil
    }

    /// Registered at `ready`, before any frontend opens: only frontends opened after it can dock.
    func registerDevToolsDockChannel(context: UnsafeMutableRawPointer) {
        guard supportsDevToolsDocking else { return }
        typealias SetCallback = @convention(c) (ReArcDevToolsDockCallback?, UnsafeMutableRawPointer?) -> Void
        let set = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineSetDevToolsDockCallback")!,
                                to: SetCallback.self)
        set(devToolsDockCallback, context)
    }

    func takeExpectedDevToolsFrontend(_ event: ChromiumTabEvent) -> Bool {
        if expectedDevToolsFrontends.remove(event.tabID) != nil { return true }
        return devToolsOpeningTarget != 0 && event.openerTabID == devToolsOpeningTarget
    }

    // MARK: Client certificates

    /// Registered at `ready`, before any HTTPS page loads.
    func registerClientCertificateChannel(context: UnsafeMutableRawPointer) {
        if capabilities.clientCertificates { ReArcEngineSetClientCertificateCallback(clientCertificateCallback, context) }
    }

    fileprivate func handleClientCertificate(_ event: ChromiumClientCertificateEvent) {
        let id = event.identity
        ChromiumLog.info("client_certificate_event tab \(id.tabID) request \(id.requestID) cancel \(id.isCancellation) "
            + "origin \(event.request.origin) identities \(event.request.identities.count)")
        promptEvents["client_certificate", default: 0] += 1
        clientCertificateEvents.append(event)
        guard let engine = engine(forTab: id.tabID) else {
            if !id.isCancellation { respondClientCertificate(id.requestID, fingerprint: nil) }
            return
        }
        engine.handleClientCertificate(event)
    }

    /// nil cancels (the page shows Chromium's error; nothing is cached).
    @discardableResult
    func respondClientCertificate(_ request: UInt64, fingerprint: String?) -> ReArcStatus {
        guard capabilities.clientCertificates, isReady else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = fingerprint.map { value in value.withCString { ReArcClientCertificateRespond(request, $0) } }
            ?? ReArcClientCertificateRespond(request, nil)
        ChromiumLog.info("client certificate reply \(request) \(fingerprint == nil ? "cancel" : "select") -> \(status.rearcName)")
        promptReplies["client_certificate", default: 0] += 1
        return status
    }
}

/// Opens frontends for the shell model and places them (`ChromiumShell` installs it).
final class ChromiumDevToolsHost: DevToolsOpening {
    private let runtime: ChromiumRuntime
    private weak var model: BrowserViewModel?
    /// Frontend tab → the sidebar tab it inspects, until its created event arrives.
    private var targets: [UInt64: Tab.ID] = [:]

    init(runtime: ChromiumRuntime, model: BrowserViewModel) {
        self.runtime = runtime
        self.model = model
    }

    func install() {
        guard runtime.capabilities.devTools, let model else { return }
        model.devToolsOpener = self
        model.devToolsDockable = runtime.supportsDevToolsDocking
        runtime.onDevToolsDock = { [weak model] event in
            ChromiumLog.info("devtools dock frontend \(event.frontendTabID) side \(event.layout.side) in-tab \(event.layout.inTabTabID) "
                + "page \(event.layout.pageBounds.map { "\($0)" } ?? "full")")
            model?.devToolsDockChanged(frontendTabID: event.frontendTabID, layout: event.layout)
        }
        runtime.onDevToolsToolboxCreated = { [weak self] event in self?.adoptToolbox(event) ?? false }
        runtime.onDevToolsToolboxClosed = { [weak model] toolbox in model?.devToolsToolboxClosed(toolbox) }
        runtime.onDevToolsFrontendCreated = { [weak self] event in self?.adopt(event) ?? false }
        runtime.onDevToolsFrontendClosed = { [weak model] frontend in model?.devToolsFrontendClosed(frontend) }
        runtime.onInspectRequested = { [weak model] page in
            guard let model, page.role == .tab, model.store.tab(withID: page.shellID) != nil else { return }
            _ = model.openDevTools(for: page.shellID)
        }
    }

    func openDevTools(for tab: Tab, engine: any WebEngine) -> String? {
        guard let page = engine as? ChromiumEngine, page.tabID != 0 else { return "The page is not loaded yet" }
        // The created event can arrive inside the call: note the target first.
        pendingTarget = (page.tabID, tab.id)
        defer { pendingTarget = nil }
        let (status, frontend) = runtime.openDevTools(target: page.tabID)
        guard status == .rearcOK, frontend != 0 else {
            return status == ReArcStatus(REARC_UNSUPPORTED) ? "Developer Tools are not available for this page"
                : "Developer Tools could not open (\(status.rearcName))"
        }
        if model?.devToolsEngine(for: tab.id) == nil { targets[frontend] = tab.id }
        return nil
    }

    private var pendingTarget: (engineTab: UInt64, tab: Tab.ID)?

    func closeDevTools(frontendTabID: UInt64) {
        guard runtime.isReady, !runtime.isStopping, runtime.devToolsFrontends.contains(frontendTabID) else { return }
        runtime.forceCloseTab(frontendTabID)
    }

    private func adopt(_ event: ChromiumTabEvent) -> Bool {
        let tabID = targets.removeValue(forKey: event.tabID)
            ?? (pendingTarget?.engineTab == event.openerTabID ? pendingTarget?.tab : nil)
        guard let model, let tabID, let target = runtime.engine(forTab: event.openerTabID) else { return false }
        let url = event.url.flatMap(URL.init(string:))
            ?? URL(string: "devtools://devtools/bundled/devtools_app.html")!
        let frontend = ChromiumEngine(runtime: runtime, adopting: event, initialURL: url, context: target.profileContext,
                                      profileKey: target.profileKey, shellID: UUID(), role: .peek)
        model.attachDevTools(frontend, frontendTabID: event.tabID, for: tabID)
        return model.devToolsEngine(for: tabID) === frontend
    }

    /// The device-mode toolbox an undocked frontend opened, in its frontend's profile.
    private func adoptToolbox(_ event: ChromiumTabEvent) -> Bool {
        guard let model, let tabID = model.devTools.tab(forFrontend: event.openerTabID),
              let frontend = model.devToolsEngine(for: tabID) as? ChromiumEngine else { return false }
        let url = event.url.flatMap(URL.init(string:))
            ?? URL(string: "devtools://devtools/bundled/device_mode_emulation_frame.html")!
        let toolbox = ChromiumEngine(runtime: runtime, adopting: event, initialURL: url, context: frontend.profileContext,
                                     profileKey: frontend.profileKey, shellID: UUID(), role: .peek)
        model.attachDevToolsToolbox(toolbox, toolboxTabID: event.tabID, for: tabID)
        return true
    }
}
#endif
