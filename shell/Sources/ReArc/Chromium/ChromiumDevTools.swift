#if REARC_CHROMIUM
import AppKit
import ReArcEngine
import SidebarModel

/// Hosted DevTools (ABI 1.40) and client-certificate selection (ABI 1.41).
/// Follows "Shell adoption" in engine/docs/WAVE-18H-REPORT.md.

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
}
#endif
