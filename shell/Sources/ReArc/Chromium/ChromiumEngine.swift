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
/// callbacks; commands are main-thread ABI calls. The tab is created once its
/// engine profile is open (named profiles open asynchronously); commands
/// issued earlier wait for it.
@Observable
final class ChromiumEngine: WebEngine, NavigationCommitReporting {
    let profileContext: EngineProfileContext
    @ObservationIgnored let role: EngineRole
    @ObservationIgnored let shellID: UUID
    /// Engine profile this tab lives in; fixed for the tab's lifetime (a profile
    /// change recreates the tab rather than relabeling it).
    @ObservationIgnored let profileKey: ChromiumProfileKey
    @ObservationIgnored private unowned let runtime: ChromiumRuntime

    /// Session-local engine tab ID; 0 until created or after the engine closed the tab.
    private(set) var tabID: UInt64 = 0
    /// Session-local engine profile ID of `tabID`; 0 without a tab.
    private(set) var engineProfileID: UInt64 = 0
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
    /// The engine's immutable icon_ref for the current icon (favicon event).
    private(set) var faviconRef: String?
    /// PNG for `faviconRef`, read with `ReArcFaviconGet` when the event arrives.
    private(set) var faviconData: Data?
    /// Favicon reads the engine rejected (stale ref, closed tab).
    @ObservationIgnored private(set) var faviconFetchFailures = 0
    var securityState: WebSecurityState { WebSecurityState(chromiumLevel: securityLevel) }
    private(set) var lastError: String?
    private(set) var attachmentID: UInt64?
    /// Browser page zoom from Chromium's zoom events (1.0 = 100%).
    private(set) var zoomFactor: Double = 1.0
    /// Completed boost plan installs; navigation waits for the in-flight one.
    private(set) var boostInstallCount = 0
    private(set) var navigationsDeferredForBoosts = 0
    @ObservationIgnored var onNavigationCommit: ((URL?, String?) -> Void)?
    @ObservationIgnored var linkPeekHandler: ((URL) -> Void)? {
        didSet { reconcileLinkPeek() }
    }
    /// Page messages from installed boost worlds (not the editor): untrusted data.
    @ObservationIgnored var onBoostPageMessage: ((ChromiumPageMessage) -> Void)?
    /// Editor-world messages that failed validation (wrong kind, stale document).
    @ObservationIgnored private(set) var droppedEditorMessages = 0

    @ObservationIgnored private let mediaStateSubject = CurrentValueSubject<WebMediaState, Never>(.silent)
    /// The host holding this tab's single attachment lease.
    @ObservationIgnored private weak var host: ChromiumHostView?
    /// Every host currently showing this tab (windows, panes); only `host` is attached.
    @ObservationIgnored private var displayHosts: [WeakHost] = []

    @ObservationIgnored private var tabCreationPending = false
    @ObservationIgnored private var tabWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var desiredPlan: [ChromiumBoostPlan.Entry] = []
    @ObservationIgnored private var appliedPlan: [ChromiumBoostPlan.Entry] = []
    @ObservationIgnored private var installInFlight = false
    @ObservationIgnored private var installRetryAvailable = true
    @ObservationIgnored private var reloadAfterInstall = false
    @ObservationIgnored private var pendingNavigations: [() -> Void] = []
    @ObservationIgnored private var navigationFlushScheduled = false
    @ObservationIgnored private var linkPeekApplied = false
    @ObservationIgnored private var linkPeekInFlight = false
    /// A zoom request made before the tab had a live render frame (invalid_state).
    @ObservationIgnored private var pendingZoomFactor: Double?

    @ObservationIgnored private var commitWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// The ABI allows one pending evaluation per tab; later callers queue here.
    @ObservationIgnored private var evaluationBusy = false
    @ObservationIgnored private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private(set) var evaluationInFlight = false
    /// Evaluations requested and not yet finished, including queued ones.
    @ObservationIgnored private(set) var evaluationsOutstanding = 0
    /// Results discarded because the document identity no longer matched.
    @ObservationIgnored private(set) var staleResultsDiscarded = 0

    @ObservationIgnored var onBoostEditorPick: ((PickedElementSnapshot) -> Void)?
    @ObservationIgnored var onBoostEditorCancel: (() -> Void)?
    @ObservationIgnored private(set) var pickerActive = false
    /// The document the picker was started on; picks from any other are dropped.
    @ObservationIgnored private var pickerDocument: ChromiumDocumentIdentity?
    @ObservationIgnored private var hoverInFlight = false
    @ObservationIgnored private var pendingHover: CGPoint?

    var mediaState: WebMediaState { mediaStateSubject.value }
    var mediaStatePublisher: AnyPublisher<WebMediaState, Never> { mediaStateSubject.eraseToAnyPublisher() }

    /// `privateSession` groups the tabs of one private window into one
    /// off-the-record profile; it applies only to ephemeral contexts.
    init(
        runtime: ChromiumRuntime,
        context: EngineProfileContext,
        role: EngineRole,
        shellID: UUID,
        privateSession: UUID? = nil
    ) {
        self.runtime = runtime
        self.profileContext = context
        self.role = role
        self.shellID = shellID
        self.profileKey = ChromiumProfileKey(context: context, privateSession: privateSession ?? shellID)
        ensureTab()
    }

    /// Wraps a tab Chromium created (popup / target=_blank); the engine already
    /// owns it, in the opener's BrowserContext (`profileKey`).
    /// `initialURL` must equal the sidebar tab's URL so selection doesn't navigate over the adopted contents.
    init(
        runtime: ChromiumRuntime,
        adopting event: ChromiumTabEvent,
        initialURL: URL,
        context: EngineProfileContext,
        profileKey: ChromiumProfileKey,
        shellID: UUID
    ) {
        self.runtime = runtime
        self.profileContext = context
        self.role = .tab
        self.shellID = shellID
        self.profileKey = profileKey
        tabID = event.tabID
        engineProfileID = event.profileID
        contentGeneration = event.contentGeneration
        currentURL = initialURL
        runtime.register(self, tabID: event.tabID)
    }

    deinit {
        runtime.releaseTab(tabID, shellID: shellID)
    }

    /// Starts tab creation if needed. True only when the tab already exists;
    /// otherwise it is created once the profile opens.
    @discardableResult
    func ensureTab() -> Bool {
        if tabID != 0 { return true }
        guard !tabCreationPending else { return false }
        tabCreationPending = true
        runtime.createTab(for: self) { [weak self] id in
            guard let self else { return }
            self.tabCreationPending = false
            if let id {
                self.tabCreated(id)
            } else {
                self.lastError = "Chromium tab unavailable (\(self.profileKey))"
                self.resumeTabWaiters(false)
            }
        }
        return tabID != 0
    }

    private func tabCreated(_ id: UInt64) {
        tabID = id
        engineProfileID = runtime.engineProfileID(for: profileKey) ?? 0
        appliedPlan = []
        linkPeekApplied = false
        submitPlanIfNeeded()
        reconcileLinkPeek()
        if !pendingNavigations.isEmpty, !navigationFlushScheduled { flushNavigations() }
        // Hosts that appeared while the profile was opening could not attach yet.
        if let next = host ?? preferredDisplayHost() { DispatchQueue.main.async { next.reconcile() } }
        resumeTabWaiters(true)
    }

    /// Waits until the tab exists (or creation failed).
    @MainActor
    func waitForTab() async -> Bool {
        if tabID != 0 { return true }
        ensureTab()
        guard tabCreationPending else { return tabID != 0 }
        return await withCheckedContinuation { tabWaiters.append($0) }
    }

    private func resumeTabWaiters(_ created: Bool) {
        let waiters = tabWaiters
        tabWaiters = []
        waiters.forEach { $0.resume(returning: created) }
    }

    // MARK: Events

    func handle(_ event: ChromiumTabEvent) {
        guard event.tabID == tabID else { return }
        if event.contentGeneration != 0 { contentGeneration = event.contentGeneration }
        if event.profileID != 0 { engineProfileID = event.profileID }
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
            if !event.isSameDocument {
                resumeCommitWaiters(throwing: nil)
                applyPendingZoom()
                onNavigationCommit?(currentURL, pageTitle)
            }
        case .failed:
            guard event.isMainFrame else { return }
            resumeCommitWaiters(throwing: nil)
            guard event.errorCode != ChromiumTabEvent.netErrorAborted else { return }
            lastError = "\(event.errorText ?? "net error") (\(event.errorCode))"
        case .closed:
            ChromiumLog.info("tab \(tabID) closed by engine (reason \(event.closedReason))")
            tabID = 0
            engineProfileID = 0
            resumeCommitWaiters(throwing: ChromiumScriptError.noTab)
            isLoading = false
            installInFlight = false
            linkPeekInFlight = false
            appliedPlan = []
            linkPeekApplied = false
            pickerDocument = nil
            // tab.closed is final: no later media event will report the session ended.
            if mediaState != .silent { mediaStateSubject.send(.silent) }
        }
    }

    func handle(_ event: ChromiumServiceEvent) {
        guard event.tabID == tabID else { return }
        switch event.kind {
        case .favicon:
            if event.faviconCleared || (event.iconRef ?? "").isEmpty {
                faviconRef = nil
                faviconData = nil
            } else if let ref = event.iconRef, ref != faviconRef {
                faviconRef = ref
                let (status, png) = fetchFavicon(ref: ref)
                if let png {
                    faviconData = png
                } else {
                    faviconFetchFailures += 1
                    ChromiumLog.info("tab \(tabID) favicon \(ref) unavailable: \(status.rearcName)")
                }
            }
        case .media:
            isMuted = event.muted
            let state = ChromiumMediaMapping.apply(event.mediaSnapshot, to: mediaState)
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

    func reload(ignoringCache: Bool) {
        let name = ignoringCache ? "reload ignoring cache" : "reload"
        enqueueNavigation { [weak self] in self?.command(name) { ReArcTabReload($0, ignoringCache) } }
    }

    /// Immediate (not queued behind boost installs): stop must not wait.
    func stopLoading() {
        guard tabID != 0 else { return }
        command("stop") { ReArcTabStop($0) }
    }

    func goBack() {
        enqueueNavigation { [weak self] in self?.command("back") { ReArcTabGoBack($0) } }
    }

    func goForward() {
        enqueueNavigation { [weak self] in self?.command("forward") { ReArcTabGoForward($0) } }
    }

    /// Immediate typed navigation (no boost barrier). ABI 1.5 admits http(s), data, file,
    /// chrome://settings, chrome://version, exact about:blank and view-source of http(s)/file;
    /// older engines admit http(s) and about:blank only. Other URLs return invalid_url.
    /// Before the tab exists this is engine_not_ready; `load` waits instead.
    @discardableResult
    func navigateNow(_ url: URL) -> ReArcStatus {
        command("navigate \(url.absoluteString)") { tab in
            url.absoluteString.withCString { ReArcTabNavigate(tab, $0, 0) }
        }
    }

    /// Navigations wait one main-loop turn so a boost install requested in the
    /// same turn (load then syncBoosts) is submitted first, then wait for its
    /// completion: C-ABI.md requires install acknowledgement before navigating.
    /// They also wait for the tab itself while its profile opens.
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
        guard ensureTab() else { return }
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

    // MARK: Favicon

    /// Reads a cached favicon PNG (C-ABI.md: +1 malloc buffer, freed here; a
    /// stale ref is not_found). Main thread, no network.
    func fetchFavicon(ref: String) -> (ReArcStatus, Data?) {
        guard tabID != 0 else { return (ReArcStatus(REARC_ENGINE_NOT_READY), nil) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        let status = ref.withCString { ReArcFaviconGet(tabID, $0, &bytes, &size) }
        defer { if let bytes { ReArcBufferFree(bytes) } }
        guard status == .rearcOK, let bytes, size > 0 else { return (status, nil) }
        return (status, Data(bytes: bytes, count: size))
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

    // MARK: Zoom (ABI 1.8)

    var supportsZoom: Bool { runtime.capabilities.pageZoom }

    /// Sets browser page zoom. Chromium applies it to every tab of this host in
    /// the profile and reports each through zoom events; `zoomFactor` follows them.
    @discardableResult
    func requestZoomFactor(_ factor: Double) -> ReArcStatus {
        guard supportsZoom else { return ReArcStatus(REARC_UNSUPPORTED) }
        guard PageZoom.isValid(factor) else { return ReArcStatus(REARC_INVALID_ARGUMENT) }
        guard tabID != 0 else {
            pendingZoomFactor = factor
            return ReArcStatus(REARC_ENGINE_NOT_READY)
        }
        let status = ReArcTabSetZoomFactor(tabID, factor)
        ChromiumLog.trace("tab \(tabID) set zoom \(factor) -> \(status.rearcName)")
        if status == ReArcStatus(REARC_INVALID_STATE) {
            // No live render frame yet: apply after the next commit.
            pendingZoomFactor = factor
        } else if status != .rearcOK {
            ChromiumLog.info("tab \(tabID) zoom \(factor) rejected: \(status.rearcName)")
        }
        return status
    }

    func setZoomFactor(_ factor: Double) {
        requestZoomFactor(factor)
    }

    /// Re-reads the factor from Chromium (on tab selection).
    @discardableResult
    func refreshZoomFactor() -> Double? {
        guard supportsZoom, tabID != 0 else { return nil }
        var factor = 0.0
        guard ReArcTabGetZoomFactor(tabID, &factor) == .rearcOK, PageZoom.isValid(factor) else { return nil }
        zoomFactor = factor
        return factor
    }

    func handleZoom(document: ChromiumDocumentIdentity, factor: Double) {
        guard document.tabID == tabID, document.contentGeneration == contentGeneration || contentGeneration == 0,
              PageZoom.isValid(factor) else { return }
        zoomFactor = factor
    }

    private func applyPendingZoom() {
        guard let factor = pendingZoomFactor else { return }
        pendingZoomFactor = nil
        requestZoomFactor(factor)
    }

    // MARK: Page messages (ABI 1.9)

    var supportsPageMessages: Bool { runtime.capabilities.isolatedPageMessages }

    /// Page messages are untrusted data. Editor-world messages must belong to
    /// the document currently shown and be a known picker kind.
    func handlePageMessage(_ message: ChromiumPageMessage) {
        guard message.document.tabID == tabID, message.document.contentGeneration == contentGeneration else { return }
        guard message.boostID == ChromiumScriptWorld.editorWorldID else {
            onBoostPageMessage?(message)
            return
        }
        if let current = runtime.documentIdentity(tab: tabID), !current.isSameDocument(as: message.document) {
            droppedEditorMessages += 1
            ChromiumLog.info("tab \(tabID) dropped editor message for an old document (\(message.document) vs \(current))")
            return
        }
        guard let decoded = BoostEditorPageMessage.decode(json: message.json) else {
            droppedEditorMessages += 1
            ChromiumLog.info("tab \(tabID) dropped an unrecognized editor message (\(message.json.utf8.count) bytes)")
            return
        }
        switch decoded {
        case .pick(let snapshot):
            guard pickerActive, pickerDocument.map({ $0.isSameDocument(as: message.document) }) ?? true else {
                droppedEditorMessages += 1
                return
            }
            onBoostEditorPick?(snapshot)
        case .cancel:
            guard pickerActive else { return }
            onBoostEditorCancel?()
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

    /// The host currently holding the lease.
    var leaseHolder: ChromiumHostView? { host }

    /// One live attachment per tab: a new host takes the lease, and the
    /// previous host detaches before the new one attaches.
    func claimLease(for newHost: ChromiumHostView) {
        hostAppeared(newHost)
        if let previous = host, previous !== newHost {
            previous.setPickerOverlay(nil)
            previous.releaseLease(detach: true)
        }
        host = newHost
        newHost.setPickerOverlay(usesPickerOverlay ? self : nil)
    }

    func leaseChanged(_ attachmentID: UInt64?, host changedHost: ChromiumHostView) {
        guard host === changedHost else { return }
        self.attachmentID = attachmentID
        for display in displayHosts.compactMap(\.value) { display.updatePlaceholder() }
    }

    func hostAppeared(_ newHost: ChromiumHostView) {
        displayHosts.removeAll { $0.value == nil }
        if !displayHosts.contains(where: { $0.value === newHost }) {
            displayHosts.append(WeakHost(value: newHost))
        }
    }

    /// A host left (dismantled or its window closed). If it held the lease,
    /// another host still showing this tab takes it, preferring the key window.
    func hostDisappeared(_ oldHost: ChromiumHostView) {
        displayHosts.removeAll { $0.value == nil || $0.value === oldHost }
        guard host === oldHost else { return }
        host = nil
        attachmentID = nil
        guard let next = preferredDisplayHost() else { return }
        DispatchQueue.main.async { next.reconcile() }
    }

    /// The showing host that should hold the lease: the key window's, else the newest.
    private func preferredDisplayHost() -> ChromiumHostView? {
        let candidates = displayHosts.compactMap(\.value).filter { $0.canAttach }
        return candidates.first(where: { $0.window?.isKeyWindow == true }) ?? candidates.last
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

    // MARK: Script evaluation (ABI 1.5, identity 1.7)

    var supportsScriptEvaluation: Bool { runtime.capabilities.scriptEvaluation }

    /// Identity of the document the tab shows now (`ReArcTabGetDocumentIdentity`).
    var currentDocumentIdentity: ChromiumDocumentIdentity? { runtime.documentIdentity(tab: tabID) }

    /// Evaluates a JavaScript expression in the current primary document and
    /// returns its JSON-decoded value (a JS string decodes to String, undefined
    /// to NSNull). Wrap statements in an IIFE. One evaluation runs at a time.
    ///
    /// The result is applied only if the document the engine evaluated in is
    /// still the tab's current document (a fresh identity query), and, when
    /// `expected` is given, is that document. `sameNavigation` also requires
    /// the same navigation ID (for results tied to one URL/navigation).
    @MainActor
    func evaluate(
        _ source: String,
        in world: ChromiumScriptWorld,
        timeoutMS: UInt32 = ChromiumScriptOutcome.defaultTimeoutMS,
        expecting expected: ChromiumDocumentIdentity? = nil,
        sameNavigation: Bool = false
    ) async throws -> Any {
        guard supportsScriptEvaluation else { throw ChromiumScriptError.unsupported }
        let range = ChromiumScriptOutcome.timeoutRangeMS
        let timeout = min(max(timeoutMS, range.lowerBound), range.upperBound)
        evaluationsOutstanding += 1
        defer { evaluationsOutstanding -= 1 }
        guard await waitForTab() else { throw ChromiumScriptError.noTab }
        await acquireEvaluationSlot()
        defer { releaseEvaluationSlot() }
        do {
            return try await evaluateOnce(source, in: world, timeoutMS: timeout, expected: expected, sameNavigation: sameNavigation)
        } catch ChromiumScriptError.rejected(let status) where status == ChromiumStatusCode.invalidState {
            // invalid_state: a primary navigation is pending. Retry once after it commits.
            try await waitForPrimaryCommit(timeoutMS: timeout)
            return try await evaluateOnce(source, in: world, timeoutMS: timeout, expected: expected, sameNavigation: sameNavigation)
        }
    }

    @MainActor
    private func evaluateOnce(
        _ source: String,
        in world: ChromiumScriptWorld,
        timeoutMS: UInt32,
        expected: ChromiumDocumentIdentity?,
        sameNavigation: Bool
    ) async throws -> Any {
        guard tabID != 0 else { throw ChromiumScriptError.noTab }
        let tab = tabID
        evaluationInFlight = true
        defer { evaluationInFlight = false }
        let result: ChromiumScriptResult = try await withCheckedThrowingContinuation { continuation in
            let status = runtime.evaluateScript(tab: tab, source: source, world: world, timeoutMS: timeoutMS) {
                continuation.resume(returning: $0)
            }
            if status != .rearcOK {
                continuation.resume(throwing: ChromiumScriptError.rejected(status))
            }
        }
        ChromiumLog.trace("tab \(tab) evaluate \(world) -> \(result.status.rearcName) document \(result.document)")
        if result.status == ReArcStatus(REARC_CANCELLED) { throw ChromiumScriptError.cancelled }
        guard result.document.tabID == tab, tabID == tab, result.document.contentGeneration == contentGeneration else {
            staleResultsDiscarded += 1
            throw ChromiumScriptError.staleDocument
        }
        if runtime.capabilities.scriptEvaluationIdentity {
            guard let current = runtime.documentIdentity(tab: tab),
                  current.isSameDocument(as: result.document, sameNavigation: sameNavigation) else {
                staleResultsDiscarded += 1
                ChromiumLog.info("tab \(tab) discarded an evaluation result: evaluated in [\(result.document)], "
                    + "tab now shows [\(runtime.documentIdentity(tab: tab).map(String.init(describing:)) ?? "unknown")]")
                throw ChromiumScriptError.staleDocument
            }
            if let expected, !expected.isSameDocument(as: result.document, sameNavigation: sameNavigation) {
                staleResultsDiscarded += 1
                ChromiumLog.info("tab \(tab) discarded an evaluation result: required [\(expected)], evaluated in [\(result.document)]")
                throw ChromiumScriptError.staleDocument
            }
        }
        return try ChromiumScriptOutcome.decode(status: result.status, json: result.json, errorJSON: result.errorJSON).get()
    }

    @MainActor
    private func acquireEvaluationSlot() async {
        guard evaluationBusy else {
            evaluationBusy = true
            return
        }
        await withCheckedContinuation { evaluationWaiters.append($0) }
    }

    private func releaseEvaluationSlot() {
        if evaluationWaiters.isEmpty {
            evaluationBusy = false
        } else {
            evaluationWaiters.removeFirst().resume()
        }
    }

    @MainActor
    private func waitForPrimaryCommit(timeoutMS: UInt32) async throws {
        let key = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commitWaiters[key] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMS))) { [weak self] in
                self?.commitWaiters.removeValue(forKey: key)?
                    .resume(throwing: ChromiumScriptError.rejected(ChromiumStatusCode.invalidState))
            }
        }
    }

    private func resumeCommitWaiters(throwing error: Error?) {
        let waiters = commitWaiters
        commitWaiters = [:]
        for waiter in waiters.values {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    // MARK: Boost picker

    /// Picking runs on the page's own input events in the editor world, which
    /// posts picks through the isolated message channel (http(s) documents
    /// only). Elsewhere, or on engines without it, a native overlay takes the
    /// input and evaluates the picker at the pointer.
    var usesPickerOverlay: Bool {
        guard pickerActive else { return false }
        let scheme = currentURL?.scheme?.lowercased()
        return !(supportsPageMessages && (scheme == "http" || scheme == "https"))
    }

    /// Overlay hover: highlights the element under the pointer; at most one
    /// hover evaluation is in flight. `point` is in view points.
    func pickerHover(at point: CGPoint) {
        guard pickerActive else { return }
        if hoverInFlight {
            pendingHover = point
            return
        }
        hoverInFlight = true
        let css = PageZoom.cssPoint(fromViewPoint: point, zoom: zoomFactor)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.evaluate(BoostEditorScripts.snapshotAt(x: css.x, y: css.y), in: .editor, timeoutMS: 1000)
            self.hoverInFlight = false
            if let next = self.pendingHover {
                self.pendingHover = nil
                self.pickerHover(at: next)
            }
        }
    }

    func pickerClick(at point: CGPoint) {
        guard pickerActive else { return }
        let tab = tabID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let snapshot = try await self.pickElement(atViewPoint: point) {
                    self.onBoostEditorPick?(snapshot)
                }
            } catch {
                ChromiumLog.info("tab \(tab) picker pick failed: \(error)")
            }
        }
    }

    func pickerCancel() {
        onBoostEditorCancel?()
    }

    /// Picker descriptor of the element at a view point (top-left origin),
    /// corrected by the page zoom factor to viewport CSS pixels.
    @MainActor
    func pickElement(atViewPoint point: CGPoint) async throws -> PickedElementSnapshot? {
        let css = PageZoom.cssPoint(fromViewPoint: point, zoom: zoomFactor)
        let value = try await evaluate(BoostEditorScripts.snapshotAt(x: css.x, y: css.y), in: .editor, expecting: pickerDocument)
        guard let object = value as? [String: Any] else { return nil }
        return BoostEditorMessageHandler.decodePick(object)
    }

    fileprivate func runEditorScript(_ source: String, _ label: String) {
        guard supportsScriptEvaluation, tabID != 0 else { return }
        let tab = tabID
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.evaluate(source, in: .editor)
            } catch ChromiumScriptError.cancelled, ChromiumScriptError.staleDocument {
                // The document went away; the editor reapplies on its next change.
            } catch {
                ChromiumLog.info("tab \(tab) editor \(label) failed: \(error)")
            }
        }
    }

    fileprivate func setPickerActive(_ active: Bool) {
        pickerActive = active
        pickerDocument = active ? currentDocumentIdentity : nil
        if !active { pendingHover = nil }
        host?.setPickerOverlay(usesPickerOverlay ? self : nil)
    }
}

extension ChromiumEngine: PageZoomRefreshing {}

private struct WeakHost {
    weak var value: ChromiumHostView?
}

/// The boost editor and picker on Chromium: editor-world evaluation, page
/// input picked up in the editor world and posted back through the isolated
/// page-message channel (WebKit message handlers do not exist here).
extension ChromiumEngine: BoostEditorEngine {
    var supportsBoostEditor: Bool { supportsScriptEvaluation }

    func setBoostEditorOpen(_ open: Bool) {
        if open {
            runEditorScript(BoostEditorScripts.withPicker("null"), "bootstrap")
        } else {
            setBoostPickerMode(false)
        }
    }

    func setBoostPickerMode(_ active: Bool) {
        setPickerActive(active)
        runEditorScript(BoostEditorScripts.setPickMode(active), "pick mode")
    }

    func highlightBoostSelector(_ css: String) {
        runEditorScript(BoostEditorScripts.highlight(selector: css), "highlight")
    }

    func applyEditorLiveCSS(_ css: String) {
        guard let source = BoostEditorScripts.liveStylesheet(css) else { return }
        runEditorScript(source, "live CSS")
    }

    func clearEditorLiveCSS() {
        applyEditorLiveCSS("")
        runEditorScript(BoostEditorScripts.hideOverlay, "hide overlay")
    }

    func fetchRepairScan(completion: @escaping ([PickedElementSnapshot]) -> Void) {
        Task { @MainActor [weak self] in
            let value = try? await self?.evaluate(BoostEditorScripts.scanRepairCandidates, in: .editor)
            let objects = value as? [[String: Any]] ?? []
            completion(objects.compactMap(BoostEditorMessageHandler.decodePick))
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
