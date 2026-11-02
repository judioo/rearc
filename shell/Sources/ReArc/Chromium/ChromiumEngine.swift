#if REARC_CHROMIUM
import AppKit
import Combine
import ReArcEngine
import SidebarModel
import SwiftUI

enum ChromiumEngineError: LocalizedError {
    case noTab
    case rejected(String, ReArcStatus)
    case failed(String, ReArcStatus)
    case staleContent

    var errorDescription: String? {
        switch self {
        case .noTab: return "The Chromium tab is not available"
        case .rejected(let operation, let status): return "Chromium rejected \(operation): \(status.rearcName)"
        case .failed(let operation, let status): return "Chromium \(operation) failed: \(status.rearcName)"
        case .staleContent: return "The page changed while capturing"
        }
    }
}

/// Snapshot completion context; owns the continuation until the single callback.
private final class SnapshotRequest {
    let continuation: CheckedContinuation<Data, Error>
    let contentGeneration: UInt64

    init(continuation: CheckedContinuation<Data, Error>, contentGeneration: UInt64) {
        self.continuation = continuation
        self.contentGeneration = contentGeneration
    }
}

private let snapshotCallback: ReArcSnapshotCallback = { context, status, _, generation, data, size in
    let request = Unmanaged<SnapshotRequest>.fromOpaque(context!).takeRetainedValue()
    var png: Data?
    if let data {
        if status == .rearcOK, size > 0 { png = Data(bytes: data, count: size) }
        // Ownership transferred to the host even when the result is rejected.
        ReArcBufferFree(data)
    }
    if status != .rearcOK {
        request.continuation.resume(throwing: ChromiumEngineError.failed("snapshot", status))
    } else if generation != request.contentGeneration {
        request.continuation.resume(throwing: ChromiumEngineError.staleContent)
    } else if let png {
        request.continuation.resume(returning: png)
    } else {
        request.continuation.resume(throwing: ChromiumEngineError.failed("snapshot", ReArcStatus(REARC_INTERNAL)))
    }
}

/// `WebEngine` backed by one Chromium tab through the engine C ABI
/// (engine/docs/C-ABI.md). State is published from the ABI's main-thread
/// callbacks; commands are main-thread ABI calls.
@Observable
final class ChromiumEngine: WebEngine, NavigationCommitReporting {
    let profileContext: EngineProfileContext
    @ObservationIgnored let role: EngineRole
    @ObservationIgnored let shellID: UUID
    @ObservationIgnored private unowned let runtime: ChromiumRuntime

    /// Session-local engine tab ID; 0 until created or after the engine closed the tab.
    private(set) var tabID: UInt64 = 0
    private(set) var contentGeneration: UInt64 = 0
    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loadProgress: Double = 0
    private(set) var isCrashed = false
    private(set) var isMuted = false
    /// 0 secure, 1 insecure, 2 dangerous, 3 none, 4 unknown (engine security_state).
    private(set) var securityLevel: UInt32 = 4
    private(set) var faviconRef: String?
    private(set) var lastError: String?
    private(set) var attachmentID: UInt64?
    /// Completed boost plan installs; navigation waits for the in-flight one.
    private(set) var boostInstallCount = 0
    private(set) var navigationsDeferredForBoosts = 0
    @ObservationIgnored var onNavigationCommit: ((URL?, String?) -> Void)?
    @ObservationIgnored var linkPeekHandler: ((URL) -> Void)? {
        didSet { reconcileLinkPeek() }
    }

    @ObservationIgnored private let mediaStateSubject = CurrentValueSubject<WebMediaState, Never>(.silent)
    @ObservationIgnored private weak var host: ChromiumHostView?

    @ObservationIgnored private var desiredPlan: [ChromiumBoostPlan.Entry] = []
    @ObservationIgnored private var appliedPlan: [ChromiumBoostPlan.Entry] = []
    @ObservationIgnored private var installInFlight = false
    @ObservationIgnored private var installRetryAvailable = true
    @ObservationIgnored private var reloadAfterInstall = false
    @ObservationIgnored private var pendingNavigations: [() -> Void] = []
    @ObservationIgnored private var navigationFlushScheduled = false
    @ObservationIgnored private var linkPeekApplied = false
    @ObservationIgnored private var linkPeekInFlight = false

    var mediaState: WebMediaState { mediaStateSubject.value }
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { mediaStateSubject.eraseToAnyPublisher() }

    init(runtime: ChromiumRuntime, context: EngineProfileContext, role: EngineRole, shellID: UUID) {
        self.runtime = runtime
        self.profileContext = context
        self.role = role
        self.shellID = shellID
        ensureTab()
    }

    /// Wraps a tab Chromium created (popup / target=_blank); the engine already owns it.
    /// `initialURL` must equal the sidebar tab's URL so selection doesn't navigate over the adopted contents.
    init(
        runtime: ChromiumRuntime,
        adopting event: ChromiumTabEvent,
        initialURL: URL,
        context: EngineProfileContext,
        shellID: UUID
    ) {
        self.runtime = runtime
        self.profileContext = context
        self.role = .tab
        self.shellID = shellID
        tabID = event.tabID
        contentGeneration = event.contentGeneration
        currentURL = initialURL
        runtime.register(self, tabID: event.tabID)
    }

    deinit {
        runtime.releaseTab(tabID, shellID: shellID)
    }

    @discardableResult
    func ensureTab() -> Bool {
        if tabID != 0 { return true }
        guard let id = runtime.createTab(for: self) else { return false }
        tabID = id
        appliedPlan = []
        linkPeekApplied = false
        submitPlanIfNeeded()
        reconcileLinkPeek()
        if let host { DispatchQueue.main.async { host.reconcile() } }
        return true
    }

    // MARK: Events

    func handle(_ event: ChromiumTabEvent) {
        guard event.tabID == tabID else { return }
        if event.contentGeneration != 0 { contentGeneration = event.contentGeneration }
        switch event.kind {
        case .created:
            break
        case .updated:
            let changes = event.changes
            if changes.contains(.url), let url = event.url.flatMap(URL.init(string:)) { currentURL = url }
            if changes.contains(.title) { pageTitle = event.title }
            if changes.contains(.progress) { loadProgress = event.loadProgress }
            if changes.contains(.crashed) { isCrashed = event.isCrashed }
            if changes.contains(.canGoBack) { canGoBack = event.canGoBack }
            if changes.contains(.canGoForward) { canGoForward = event.canGoForward }
            if changes.contains(.loading) {
                let finished = isLoading && !event.isLoading
                isLoading = event.isLoading
                if finished { onNavigationCommit?(currentURL, pageTitle) }
            }
        case .committed:
            guard event.isMainFrame else { return }
            if let url = event.url.flatMap(URL.init(string:)) { currentURL = url }
            lastError = nil
            if !event.isSameDocument { onNavigationCommit?(currentURL, pageTitle) }
        case .failed:
            guard event.isMainFrame, event.errorCode != ChromiumTabEvent.netErrorAborted else { return }
            lastError = "\(event.errorText ?? "net error") (\(event.errorCode))"
        case .closed:
            ChromiumLog.info("tab \(tabID) closed by engine (reason \(event.closedReason))")
            tabID = 0
            isLoading = false
            installInFlight = false
            linkPeekInFlight = false
            appliedPlan = []
            linkPeekApplied = false
        }
    }

    func handle(_ event: ChromiumServiceEvent) {
        guard event.tabID == tabID else { return }
        switch event.kind {
        case .favicon:
            faviconRef = event.faviconCleared ? nil : event.iconRef
        case .media:
            isMuted = event.muted
            var state = mediaState
            state.isPlaying = event.playback == 0
            state.isAudible = event.audible
            state.canPictureInPicture = false
            if event.hasMetadata {
                state.title = event.title.flatMap { $0.isEmpty ? nil : $0 }
                state.artist = event.artist.flatMap { $0.isEmpty ? nil : $0 }
            }
            if state != mediaState { mediaStateSubject.send(state) }
        case .security:
            securityLevel = event.security
        case .linkPeek:
            if let href = event.href, let url = URL(string: href) { linkPeekHandler?(url) }
        }
    }

    // MARK: Navigation

    func load(_ url: URL) {
        currentURL = url
        enqueueNavigation { [weak self] in self?.navigateNow(url) }
    }

    func reload() {
        enqueueNavigation { [weak self] in self?.command("reload") { ReArcTabReload($0, false) } }
    }

    func goBack() {
        enqueueNavigation { [weak self] in self?.command("back") { ReArcTabGoBack($0) } }
    }

    func goForward() {
        enqueueNavigation { [weak self] in self?.command("forward") { ReArcTabGoForward($0) } }
    }

    /// Immediate typed navigation (no boost barrier). The ABI admits http(s) and exact about:blank only.
    @discardableResult
    func navigateNow(_ url: URL) -> ReArcStatus {
        command("navigate \(url.absoluteString)") { tab in
            url.absoluteString.withCString { ReArcTabNavigate(tab, $0, 0) }
        }
    }

    /// Navigations wait one main-loop turn so a boost install requested in the
    /// same turn (load then syncBoosts) is submitted first, then wait for its
    /// completion: C-ABI.md requires install acknowledgement before navigating.
    private func enqueueNavigation(_ operation: @escaping () -> Void) {
        pendingNavigations.append(operation)
        guard !navigationFlushScheduled else { return }
        navigationFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.navigationFlushScheduled = false
            self.flushNavigations()
        }
    }

    private func flushNavigations() {
        guard !pendingNavigations.isEmpty else { return }
        if installInFlight {
            navigationsDeferredForBoosts += 1
            return
        }
        let operations = pendingNavigations
        pendingNavigations = []
        operations.forEach { $0() }
    }

    @discardableResult
    private func command(_ name: String, _ call: (UInt64) -> ReArcStatus) -> ReArcStatus {
        guard ensureTab() else { return ReArcStatus(REARC_ENGINE_NOT_READY) }
        let status = call(tabID)
        ChromiumLog.trace("tab \(tabID) \(name) -> \(status.rearcName)")
        if status != .rearcOK {
            lastError = "\(name): \(status.rearcName)"
            ChromiumLog.info("tab \(tabID) \(name) rejected: \(status.rearcName)")
        }
        return status
    }

    // MARK: Media

    func setMuted(_ muted: Bool) {
        command("mute") { ReArcTabSetMuted($0, muted) }
    }

    func togglePlayPause() { mediaAction(2) }
    func skipToNextTrack() { mediaAction(3) }
    func skipToPreviousTrack() { mediaAction(4) }
    func pauseAllMedia() { mediaAction(5) }

    private func mediaAction(_ action: UInt32) {
        guard ensureTab() else { return }
        let status = ReArcTabMediaAction(tabID, action)
        // invalid_state = no controllable session; unsupported = action not advertised.
        if status != .rearcOK, status != ReArcStatus(REARC_INVALID_STATE), status != ReArcStatus(REARC_UNSUPPORTED) {
            ChromiumLog.info("tab \(tabID) media action \(action) rejected: \(status.rearcName)")
        }
    }

    /// PiP is not advertised by ABI 1 (`pip_control` absent); the call reports unsupported.
    @discardableResult
    func requestPictureInPicture() -> ReArcStatus {
        guard ensureTab() else { return ReArcStatus(REARC_ENGINE_NOT_READY) }
        return ReArcTabSetPictureInPicture(tabID, true)
    }

    func pictureInPicture() {
        let status = requestPictureInPicture()
        if status != .rearcOK {
            lastError = "Picture in Picture: \(status.rearcName)"
        }
    }

    // MARK: Boosts

    func installBoosts(_ entries: [BoostRuntimeEntry]) {
        let plan = ChromiumBoostPlan.entries(from: entries)
        let removedScripts = !ChromiumBoostPlan.scriptIDs(in: desiredPlan)
            .subtracting(ChromiumBoostPlan.scriptIDs(in: plan)).isEmpty
        // Removed JS is never undone in the current document; reload like WKEngine.
        if removedScripts, currentURL != nil { reloadAfterInstall = true }
        desiredPlan = plan
        submitPlanIfNeeded()
    }

    func refreshBoostsOnPage() {
        guard tabID != 0, !installInFlight else { return }
        let status = ReArcTabRefreshStyles(tabID)
        if status != .rearcOK, status != ReArcStatus(REARC_BUSY) {
            ChromiumLog.info("tab \(tabID) refresh styles rejected: \(status.rearcName)")
        }
    }

    private func submitPlanIfNeeded(force: Bool = false) {
        guard tabID != 0, !installInFlight else { return }
        guard force || desiredPlan != appliedPlan else {
            finishInstallCycle()
            return
        }
        let plan = desiredPlan
        let tab = tabID
        installInFlight = true
        let status = ChromiumBoostPlan.withCScripts(plan) { scripts, count in
            runtime.callAsync({ [weak self] status, _ in
                self?.planInstalled(plan, tab: tab, status: status)
            }) { ReArcTabSetScripts(tab, scripts, count, $1, $0) }
        }
        if status != .rearcOK {
            installInFlight = false
            lastError = "boosts: \(status.rearcName)"
            ChromiumLog.info("tab \(tab) boost plan rejected: \(status.rearcName)")
            // Invalid input changes nothing; don't resubmit the same plan.
            appliedPlan = plan
            finishInstallCycle()
        }
    }

    private func planInstalled(_ plan: [ChromiumBoostPlan.Entry], tab: UInt64, status: ReArcStatus) {
        guard tab == tabID else { return }
        installInFlight = false
        if status == .rearcOK {
            appliedPlan = plan
            boostInstallCount += 1
            installRetryAvailable = true
            submitPlanIfNeeded()
            return
        }
        lastError = "boosts: \(status.rearcName)"
        ChromiumLog.info("tab \(tab) boost install failed: \(status.rearcName)")
        // A failed acknowledged replacement can leave a partial plan: retry the
        // complete replacement once, then stop so a persistent failure can't loop.
        if installRetryAvailable {
            installRetryAvailable = false
            submitPlanIfNeeded(force: true)
        } else {
            appliedPlan = plan
            submitPlanIfNeeded()
        }
    }

    /// Runs once no install is in flight: optional reload, deferred navigations, CSS refresh.
    private func finishInstallCycle() {
        if reloadAfterInstall, pendingNavigations.isEmpty, tabID != 0 {
            reloadAfterInstall = false
            command("reload") { ReArcTabReload($0, false) }
            return
        }
        reloadAfterInstall = false
        if pendingNavigations.isEmpty {
            refreshBoostsOnPage()
        } else {
            flushNavigations()
        }
    }

    // MARK: Link peek

    private func reconcileLinkPeek() {
        let desired = linkPeekHandler != nil
        guard tabID != 0, !linkPeekInFlight, desired != linkPeekApplied else { return }
        let tab = tabID
        linkPeekInFlight = true
        let status = runtime.callAsync({ [weak self] status, _ in
            guard let self, self.tabID == tab else { return }
            self.linkPeekInFlight = false
            if status == .rearcOK {
                self.linkPeekApplied = desired
                self.reconcileLinkPeek()
            } else {
                ChromiumLog.info("tab \(tab) link peek failed: \(status.rearcName)")
            }
        }) { ReArcTabSetLinkPeek(tab, desired, $1, $0) }
        if status != .rearcOK {
            linkPeekInFlight = false
            ChromiumLog.info("tab \(tab) link peek rejected: \(status.rearcName)")
        }
    }

    // MARK: View

    func makeView() -> AnyView {
        AnyView(ChromiumWebView(engine: self))
    }

    /// One attachment per tab: a new host takes the lease from the previous one.
    func claimLease(for newHost: ChromiumHostView) {
        if let previous = host, previous !== newHost {
            previous.releaseLease(detach: true)
        }
        host = newHost
    }

    func leaseChanged(_ attachmentID: UInt64?, host changedHost: ChromiumHostView) {
        guard host === changedHost else { return }
        self.attachmentID = attachmentID
    }

    // MARK: Capture

    func captureSnapshot(scope: CaptureScope) async throws -> Data {
        try await captureSnapshotOnMainActor(scope: scope)
    }

    @MainActor
    private func captureSnapshotOnMainActor(scope: CaptureScope) async throws -> Data {
        guard tabID != 0 else { throw ChromiumEngineError.noTab }
        let tab = tabID
        let generation = contentGeneration
        return try await withCheckedThrowingContinuation { continuation in
            let request = SnapshotRequest(continuation: continuation, contentGeneration: generation)
            let context = Unmanaged.passRetained(request).toOpaque()
            let status = ReArcTabCaptureSnapshot(tab, scope == .visible ? 0 : 1, snapshotCallback, context)
            if status != .rearcOK {
                Unmanaged<SnapshotRequest>.fromOpaque(context).release()
                continuation.resume(throwing: ChromiumEngineError.rejected("snapshot", status))
            }
        }
    }
}

extension ChromiumBoostPlan {
    /// Borrowed C view of a plan for the duration of `body` (the ABI copies inputs).
    static func withCScripts<R>(_ plan: [Entry], _ body: (UnsafePointer<ReArcScript>?, Int) -> R) -> R {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var scopeBuffers: [UnsafeMutablePointer<ReArcScriptScope>] = []
        defer {
            strings.forEach { free($0) }
            scopeBuffers.forEach { $0.deallocate() }
        }
        func borrow(_ value: String) -> UnsafePointer<CChar> {
            let copy = strdup(value)!
            strings.append(copy)
            return UnsafePointer(copy)
        }
        let scripts: [ReArcScript] = plan.map { entry in
            let scopes = UnsafeMutablePointer<ReArcScriptScope>.allocate(capacity: max(entry.scopes.count, 1))
            scopeBuffers.append(scopes)
            for (index, scope) in entry.scopes.enumerated() {
                scopes[index] = ReArcScriptScope(
                    host: borrow(scope.host),
                    path_prefix: borrow(scope.pathPrefix),
                    include_subdomains: scope.includeSubdomains,
                    scheme_mask: scope.schemeMask
                )
            }
            return ReArcScript(
                id: borrow(entry.id),
                scopes: UnsafePointer(scopes),
                scope_count: entry.scopes.count,
                run_at: entry.runAt,
                source: borrow(entry.source),
                css: borrow(entry.css)
            )
        }
        return scripts.withUnsafeBufferPointer { body($0.isEmpty ? nil : $0.baseAddress, $0.count) }
    }
}
#endif
