#if REARC_CHROMIUM
import AppKit
import Foundation
import ReArcEngine
import SidebarModel

enum ChromiumLog {
    /// Per-event tracing; on with REARC_CHROMIUM_TRACE=1 and in the self-test.
    static var traceEnabled = ProcessInfo.processInfo.environment["REARC_CHROMIUM_TRACE"] == "1"

    static func info(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("[ReArc/Chromium] \(message())\n".utf8))
    }

    static func trace(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        FileHandle.standardError.write(Data("[ReArc/Chromium trace] \(message())\n".utf8))
    }
}

extension ReArcStatus {
    static let rearcOK = ReArcStatus(REARC_OK)

    var rearcName: String { String(cString: ReArcStatusName(self)) }
}

/// Owned copy of `ReArcTabEvent`; the C struct and strings die with the callback.
struct ChromiumTabEvent {
    enum Kind: UInt32 {
        case created = 0, updated, closed, committed, failed
    }

    struct Changes: OptionSet {
        let rawValue: UInt32
        static let url = Changes(rawValue: 1)
        static let title = Changes(rawValue: 2)
        static let loading = Changes(rawValue: 4)
        static let progress = Changes(rawValue: 8)
        static let crashed = Changes(rawValue: 16)
        static let canGoBack = Changes(rawValue: 32)
        static let canGoForward = Changes(rawValue: 64)
    }

    static let netErrorAborted: Int32 = -3

    var kind: Kind
    var profileID, tabID, contentGeneration, spaceID, openerTabID: UInt64
    var disposition: UInt32
    var changes: Changes
    var url: String?
    var title: String?
    var isLoading, isCrashed, canGoBack, canGoForward: Bool
    var loadProgress: Double
    var closedReason: UInt32
    var navigationID: UInt64
    var isMainFrame, isSameDocument, isErrorPage: Bool
    var transition, transitionFlags: UInt32
    var errorCode: Int32
    var errorText: String?

    init?(_ pointer: UnsafePointer<ReArcTabEvent>?) {
        guard let e = pointer?.pointee, let kind = Kind(rawValue: e.kind) else { return nil }
        self.kind = kind
        profileID = e.profile_id
        tabID = e.tab_id
        contentGeneration = e.content_generation
        spaceID = e.space_id
        openerTabID = e.opener_tab_id
        disposition = e.disposition
        changes = Changes(rawValue: e.changes)
        url = e.url.map { String(cString: $0) }
        title = e.title.map { String(cString: $0) }
        isLoading = e.is_loading
        isCrashed = e.is_crashed
        canGoBack = e.can_go_back
        canGoForward = e.can_go_forward
        loadProgress = e.load_progress
        closedReason = e.closed_reason
        navigationID = e.navigation_id
        isMainFrame = e.is_main_frame
        isSameDocument = e.is_same_document
        isErrorPage = e.is_error_page
        transition = e.transition
        transitionFlags = e.transition_flags
        errorCode = e.error_code
        errorText = e.error_text.map { String(cString: $0) }
    }
}

/// Owned copy of `ReArcServiceEvent`.
struct ChromiumServiceEvent {
    enum Kind: UInt32 {
        case favicon = 0, media, security, linkPeek
    }

    var kind: Kind
    var profileID, tabID, contentGeneration: UInt64
    var pageURL, iconRef: String?
    var faviconCleared: Bool
    var playback: UInt32
    var audible, muted, hasMetadata: Bool
    var title, artist, album: String?
    var security: UInt32
    var href: String?

    init?(_ pointer: UnsafePointer<ReArcServiceEvent>?) {
        guard let e = pointer?.pointee, let kind = Kind(rawValue: e.kind) else { return nil }
        self.kind = kind
        profileID = e.profile_id
        tabID = e.tab_id
        contentGeneration = e.content_generation
        pageURL = e.page_url.map { String(cString: $0) }
        iconRef = e.icon_ref.map { String(cString: $0) }
        faviconCleared = e.favicon_cleared
        playback = e.playback
        audible = e.audible
        muted = e.muted
        hasMetadata = e.has_metadata
        title = e.title.map { String(cString: $0) }
        artist = e.artist.map { String(cString: $0) }
        album = e.album.map { String(cString: $0) }
        security = e.security
        href = e.href.map { String(cString: $0) }
    }

    var mediaSnapshot: ChromiumMediaSnapshot {
        ChromiumMediaSnapshot(
            playback: playback,
            audible: audible,
            hasMetadata: hasMetadata,
            title: title,
            artist: artist,
            album: album
        )
    }
}

/// Owned copy of one `ReArcScriptCallback` invocation.
struct ChromiumScriptResult {
    var status: ReArcStatus
    var tabID: UInt64
    var contentGeneration: UInt64
    var json: String?
    var errorJSON: String?
}

private final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Context for one accepted async ABI operation; retained until its single completion.
private final class CompletionBox {
    let body: (ReArcStatus, Bool) -> Void
    init(_ body: @escaping (ReArcStatus, Bool) -> Void) { self.body = body }
}

private let completionTrampoline: ReArcCompletion = { context, status, cancelled in
    guard let context else { return }
    Unmanaged<CompletionBox>.fromOpaque(context).takeRetainedValue().body(status, cancelled)
}

/// Context for one accepted `ReArcTabEvaluateScript`. Retained (+1) across the
/// C call; released exactly once, by the callback or on synchronous rejection.
private final class ScriptEvaluationBox {
    /// Contexts not yet released; the self-test asserts this returns to zero.
    static var live = 0

    let body: (ChromiumScriptResult) -> Void

    init(_ body: @escaping (ChromiumScriptResult) -> Void) {
        self.body = body
        Self.live += 1
    }

    deinit {
        Self.live -= 1
    }
}

private let scriptCallback: ReArcScriptCallback = { context, status, tab, generation, json, errorJSON in
    guard let context else { return }
    // Both strings are borrowed for this call only and are never ReArcBufferFree storage.
    let result = ChromiumScriptResult(
        status: status,
        tabID: tab,
        contentGeneration: generation,
        json: json.map { String(cString: $0) },
        errorJSON: errorJSON.map { String(cString: $0) }
    )
    let box = Unmanaged<ScriptEvaluationBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(result) }
}

private func runtime(from context: UnsafeMutableRawPointer?) -> ChromiumRuntime {
    Unmanaged<ChromiumRuntime>.fromOpaque(context!).takeUnretainedValue()
}

private let readyCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void = { context, profile in
    MainActor.assumeIsolated { runtime(from: context).handleReady(defaultProfileID: profile) }
}

private let tabEventCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<ReArcTabEvent>?) -> Void = {
    context, event in
    guard let copied = ChromiumTabEvent(event) else { return }
    MainActor.assumeIsolated { runtime(from: context).handleTabEvent(copied) }
}

private let viewInvalidatedCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<ReArcViewEvent>?) -> Void = {
    context, event in
    guard let e = event?.pointee else { return }
    let attachment = e.attachment_id, reason = e.reason
    MainActor.assumeIsolated { runtime(from: context).handleViewInvalidated(attachmentID: attachment, reason: reason) }
}

private let terminateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    MainActor.assumeIsolated { runtime(from: context).handleTerminateRequested() }
}

private let serviceCallback: ReArcServiceCallback = { context, event in
    guard let copied = ChromiumServiceEvent(event) else { return }
    MainActor.assumeIsolated { runtime(from: context).handleServiceEvent(copied) }
}

/// Process-wide host side of the engine C ABI. Immortal: callback contexts must
/// outlive `ReArcEngineRun`. Every entry point runs on the main thread.
final class ChromiumRuntime {
    static let shared = ChromiumRuntime()

    /// Non-nil once the engine is running with a ready profile; `EngineHost` uses it to pick Chromium.
    static var active: ChromiumRuntime? {
        shared.isReady && !shared.isStopping ? shared : nil
    }

    private(set) var isConfigured = false
    private(set) var isReady = false
    private(set) var isStopping = false
    private(set) var defaultProfileID: UInt64 = 0
    private(set) var shutdownCompleted = false
    /// ABI 1.5 features in use; probed when the engine is ready.
    private(set) var capabilities = ChromiumCapabilities.none
    private(set) var keychainMode = ChromiumLaunchArguments.KeychainMode.system
    /// After a beforeunload veto, the next quit request forces shutdown.
    private var shutdownVetoed = false

    var onReady: (() -> Void)?
    /// Runs before shutdown starts for an AppKit quit request (persist shell state here).
    var onTerminateRequested: (() -> Void)?
    /// Chromium-created contents (popups, target=_blank). Return true to adopt;
    /// unadopted tabs are force-closed.
    var onAdoptedTab: ((ChromiumTabEvent) -> Bool)?

    private var engines: [UInt64: WeakRef<ChromiumEngine>] = [:]
    private var leaseHosts: [UInt64: WeakRef<ChromiumHostView>] = [:]
    private var windowIDs: [ObjectIdentifier: UInt64] = [:]
    private var windowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var nextWindowID: UInt64 = 1
    /// Shell Tab/peek/Little Arc UUIDs to session-local engine tab IDs.
    private(set) var engineTabIDs: [UUID: UInt64] = [:]
    /// Shell profiles to engine profile IDs. v1: all map to `defaultProfileID`.
    private(set) var engineProfileIDs: [Profile.ID: UInt64] = [:]

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private init() {}

    // MARK: Startup

    /// Configures the ABI and blocks in `ReArcEngineRun` (which calls ChromeMain).
    /// Must run before any NSApplication exists.
    func run(arguments: [String], keychain: ChromiumLaunchArguments.KeychainMode) -> Int32 {
        precondition(Thread.isMainThread && !isConfigured)
        keychainMode = keychain
        var callbacks = ReArcCallbacks(
            ready: readyCallback,
            tab_event: tabEventCallback,
            view_invalidated: viewInvalidatedCallback,
            terminate_requested: terminateCallback
        )
        ReArcEngineSetServiceCallback(serviceCallback, context)
        let status = ReArcEngineConfigure(UInt32(REARC_ABI_VERSION), &callbacks, context)
        guard status == .rearcOK else {
            ChromiumLog.info("ReArcEngineConfigure failed: \(status.rearcName)")
            return -status
        }
        isConfigured = true
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        argv.append(nil)
        let code = argv.withUnsafeBufferPointer { ReArcEngineRun(Int32(arguments.count), $0.baseAddress) }
        isReady = false
        ChromiumLog.info("ReArcEngineRun returned \(code)")
        return code
    }

    fileprivate func handleReady(defaultProfileID profile: UInt64) {
        defaultProfileID = profile
        capabilities = Self.probeCapabilities()
        isReady = true
        ChromiumLog.info(
            "ready: ABI \(ReArcEngineABIVersion()), bridge \(String(cString: ReArcEngineBridgeVersion())), "
                + "Chromium \(String(cString: ReArcEngineVersion())), default profile \(profile)"
        )
        ChromiumLog.info("capabilities: \(capabilities.summary)")
        onReady?()
    }

    /// The wave-11 engine (ABI 1.0) has no `ReArcEngineABIMinorVersion` export,
    /// and the framework is weak-linked, so probe the symbol before calling it.
    private static func probeCapabilities() -> ChromiumCapabilities {
        let hasMinorExport = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineABIMinorVersion") != nil
        let minor = hasMinorExport ? ReArcEngineABIMinorVersion() : nil
        return ChromiumCapabilities(abiMinorVersion: minor) { name in
            name.withCString { ReArcEngineHasFeature($0) }
        }
    }

    // MARK: ID mapping

    func engineProfileID(for profile: Profile.ID) -> UInt64 {
        engineProfileIDs[profile] = defaultProfileID
        return defaultProfileID
    }

    func createTab(for engine: ChromiumEngine) -> UInt64? {
        guard isReady, !isStopping else { return nil }
        var tabID: UInt64 = 0
        let profile = engineProfileID(for: engine.profileContext.profileID)
        let status = ReArcTabCreate(profile, engine.role.rawValue, nil, &tabID)
        guard status == .rearcOK, tabID != 0 else {
            ChromiumLog.info("ReArcTabCreate failed: \(status.rearcName)")
            return nil
        }
        register(engine, tabID: tabID)
        return tabID
    }

    func register(_ engine: ChromiumEngine, tabID: UInt64) {
        engines[tabID] = WeakRef(engine)
        engineTabIDs[engine.shellID] = tabID
    }

    /// Force-closes a tab whose shell engine went away (shell closes skip the beforeunload veto).
    func releaseTab(_ tabID: UInt64, shellID: UUID) {
        engines[tabID] = nil
        if engineTabIDs[shellID] == tabID { engineTabIDs[shellID] = nil }
        guard tabID != 0, isReady, !isStopping else { return }
        let status = callAsync({ _, _ in }) { ReArcTabClose(tabID, true, $1, $0) }
        if status != .rearcOK {
            ChromiumLog.info("ReArcTabClose(\(tabID)) rejected: \(status.rearcName)")
        }
    }

    // MARK: Windows and leases

    /// Registers a window on first use. 0 means registration failed.
    func windowID(for window: NSWindow) -> UInt64 {
        let key = ObjectIdentifier(window)
        if let id = windowIDs[key] { return id }
        guard isReady, !isStopping else { return 0 }
        let id = nextWindowID
        nextWindowID += 1
        let status = ReArcWindowRegister(id, Unmanaged.passUnretained(window).toOpaque())
        guard status == .rearcOK else {
            ChromiumLog.info("ReArcWindowRegister failed: \(status.rearcName)")
            return 0
        }
        windowIDs[key] = id
        // The engine observes will-close itself and invalidates this window's leases.
        windowObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.windowIDs[key] = nil
            if let observer = self.windowObservers.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        return id
    }

    func registerLease(_ attachmentID: UInt64, host: ChromiumHostView) {
        leaseHosts[attachmentID] = WeakRef(host)
    }

    func unregisterLease(_ attachmentID: UInt64) {
        leaseHosts[attachmentID] = nil
    }

    fileprivate func handleViewInvalidated(attachmentID: UInt64, reason: UInt32) {
        ChromiumLog.trace("view_invalidated attachment \(attachmentID) reason \(reason)")
        leaseHosts.removeValue(forKey: attachmentID)?.value?.leaseInvalidated(reason: reason)
    }

    // MARK: Events

    fileprivate func handleTabEvent(_ event: ChromiumTabEvent) {
        ChromiumLog.trace(
            "tab_event \(event.kind) tab \(event.tabID) gen \(event.contentGeneration) changes \(event.changes.rawValue) "
                + "url \(event.url ?? "-") title \(event.title ?? "-") loading \(event.isLoading) "
                + "main \(event.isMainFrame) err \(event.errorCode) \(event.errorText ?? "")"
        )
        if event.kind == .created, engines[event.tabID] == nil {
            let adopted = onAdoptedTab?(event) ?? false
            if !adopted {
                ChromiumLog.info("closing unadopted Chromium-created tab \(event.tabID)")
                _ = callAsync({ _, _ in }) { ReArcTabClose(event.tabID, true, $1, $0) }
                return
            }
        }
        guard let engine = engines[event.tabID]?.value else { return }
        engine.handle(event)
        if event.kind == .closed {
            engines[event.tabID] = nil
        }
    }

    fileprivate func handleServiceEvent(_ event: ChromiumServiceEvent) {
        ChromiumLog.trace(
            "service_event \(event.kind) tab \(event.tabID) gen \(event.contentGeneration) playback \(event.playback) "
                + "muted \(event.muted) security \(event.security) icon \(event.iconRef ?? "-") href \(event.href ?? "-")"
        )
        engines[event.tabID]?.value?.handle(event)
    }

    // MARK: Async operations

    /// Runs an async ABI call with a retained completion context; a synchronous
    /// rejection invokes no completion, so the context is released here.
    @discardableResult
    func callAsync(
        _ completion: @escaping (ReArcStatus, Bool) -> Void,
        _ start: (UnsafeMutableRawPointer, ReArcCompletion) -> ReArcStatus
    ) -> ReArcStatus {
        let box = Unmanaged.passRetained(CompletionBox(completion)).toOpaque()
        let status = start(box, completionTrampoline)
        if status != .rearcOK {
            Unmanaged<CompletionBox>.fromOpaque(box).release()
        }
        return status
    }

    /// Evaluation contexts still awaiting their callback.
    var liveScriptContexts: Int { ScriptEvaluationBox.live }

    /// `ReArcTabEvaluateScript` with a retained context. An accepted call
    /// completes exactly once on main; a rejected one never calls `completion`.
    func evaluateScript(
        tab: UInt64,
        source: String,
        world: ChromiumScriptWorld,
        timeoutMS: UInt32,
        completion: @escaping (ChromiumScriptResult) -> Void
    ) -> ReArcStatus {
        guard capabilities.scriptEvaluation else { return ReArcStatus(REARC_UNSUPPORTED) }
        let box = Unmanaged.passRetained(ScriptEvaluationBox(completion)).toOpaque()
        let status = source.withCString { sourcePointer in
            if let boostID = world.boostID {
                return boostID.withCString {
                    ReArcTabEvaluateScript(tab, sourcePointer, world.abiWorld, $0, timeoutMS, scriptCallback, box)
                }
            }
            return ReArcTabEvaluateScript(tab, sourcePointer, world.abiWorld, nil, timeoutMS, scriptCallback, box)
        }
        if status != .rearcOK {
            Unmanaged<ScriptEvaluationBox>.fromOpaque(box).release()
        }
        return status
    }

    // MARK: Shutdown

    fileprivate func handleTerminateRequested() {
        onTerminateRequested?()
        requestShutdown(force: shutdownVetoed) { _, _ in }
    }

    /// Orderly engine shutdown; `ReArcEngineRun` returns after the final completion.
    @discardableResult
    func requestShutdown(force: Bool, completion: @escaping (ReArcStatus, Bool) -> Void) -> ReArcStatus {
        guard isReady, !isStopping else { return ReArcStatus(REARC_BUSY) }
        isStopping = true
        let status = callAsync({ [self] status, cancelled in
            if cancelled {
                isStopping = false
                shutdownVetoed = true
                ChromiumLog.info("shutdown vetoed by beforeunload; the next quit forces it")
            } else {
                shutdownCompleted = status == .rearcOK
                ChromiumLog.info("shutdown completion: \(status.rearcName)")
            }
            completion(status, cancelled)
        }) { ReArcEngineShutdown(force, $1, $0) }
        if status != .rearcOK {
            isStopping = false
            ChromiumLog.info("ReArcEngineShutdown rejected: \(status.rearcName)")
        }
        return status
    }
}
#endif
