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

/// Owned copy of one evaluation completion (`ReArcScriptCallback2`, or the
/// ABI 1.5 callback on engines without `script_evaluation_identity`).
struct ChromiumScriptResult {
    var status: ReArcStatus
    /// Identity the engine captured when it accepted the evaluation. The ABI 1.5
    /// callback reports only tab and content generation (the rest are 0).
    var document: ChromiumDocumentIdentity
    var json: String?
    var errorJSON: String?
}

/// Owned copy of one `ReArcPageMessage`: untrusted page data, never a command.
struct ChromiumPageMessage {
    var document: ChromiumDocumentIdentity
    /// `editor`, or the lowercased package UUID of the posting boost world.
    var boostID: String
    var json: String
}

extension ChromiumDocumentIdentity {
    init(_ identity: ReArcDocumentIdentity) {
        self.init(
            profileID: identity.profile_id,
            tabID: identity.tab_id,
            contentGeneration: identity.content_generation,
            documentGeneration: identity.document_generation,
            navigationID: identity.navigation_id
        )
    }
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

/// Context for one accepted script evaluation. Retained (+1) across the C
/// call; released exactly once, by the callback or on synchronous rejection.
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
        document: ChromiumDocumentIdentity(profileID: 0, tabID: tab, contentGeneration: generation, documentGeneration: 0, navigationID: 0),
        json: json.map { String(cString: $0) },
        errorJSON: errorJSON.map { String(cString: $0) }
    )
    let box = Unmanaged<ScriptEvaluationBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(result) }
}

private let scriptCallback2: ReArcScriptCallback2 = { context, result in
    guard let context else { return }
    // The result struct and its strings are borrowed for this call only.
    let copied: ChromiumScriptResult
    if let r = result?.pointee {
        copied = ChromiumScriptResult(
            status: r.status,
            document: ChromiumDocumentIdentity(r.document),
            json: r.json.map { String(cString: $0) },
            errorJSON: r.error_json.map { String(cString: $0) }
        )
    } else {
        copied = ChromiumScriptResult(
            status: ReArcStatus(REARC_INTERNAL),
            document: ChromiumDocumentIdentity(profileID: 0, tabID: 0, contentGeneration: 0, documentGeneration: 0, navigationID: 0),
            json: nil,
            errorJSON: nil
        )
    }
    let box = Unmanaged<ScriptEvaluationBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(copied) }
}

/// Context for one accepted `ReArcProfileOpen` / `ReArcProfileCreateOffTheRecord`.
/// Retained until its one deferred callback, which also reports shutdown cancellation.
private final class ProfileRequestBox {
    static var live = 0

    let body: (ReArcStatus, UInt64, Bool) -> Void

    init(_ body: @escaping (ReArcStatus, UInt64, Bool) -> Void) {
        self.body = body
        Self.live += 1
    }

    deinit {
        Self.live -= 1
    }
}

private let profileCallback: ReArcProfileCallback = { context, status, profile, offTheRecord in
    guard let context else { return }
    let box = Unmanaged<ProfileRequestBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, profile, offTheRecord) }
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

private let zoomCallback: ReArcZoomCallback = { context, event in
    guard let e = event?.pointee else { return }
    let document = ChromiumDocumentIdentity(e.document), factor = e.factor
    MainActor.assumeIsolated { runtime(from: context).handleZoom(document: document, factor: factor) }
}

private let pageMessageCallback: ReArcPageMessageCallback = { context, message in
    guard let m = message?.pointee, let json = m.json else { return }
    let copied = ChromiumPageMessage(
        document: ChromiumDocumentIdentity(m.document),
        boostID: m.boost_id.map { String(cString: $0) } ?? "",
        json: String(cString: json)
    )
    MainActor.assumeIsolated { runtime(from: context).handlePageMessage(copied) }
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
    /// Optional ABI features in use; probed when the engine is ready.
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
    /// Profile lifecycle transitions, for logs and the self-test.
    var onProfileEvent: ((String) -> Void)?

    private var engines: [UInt64: WeakRef<ChromiumEngine>] = [:]
    private var leaseHosts: [UInt64: WeakRef<ChromiumHostView>] = [:]
    private var windowIDs: [ObjectIdentifier: UInt64] = [:]
    private var windowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Closed windows must never be registered again (hosts can outlive the close).
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    private var nextWindowID: UInt64 = 1
    /// Shell Tab/peek/Little Arc UUIDs to session-local engine tab IDs.
    private(set) var engineTabIDs: [UUID: UInt64] = [:]

    // Profile registry (C-ABI.md "Profiles"). Engine profile IDs are session-local.
    private enum ProfileState {
        /// Open accepted or queued; waiters receive the engine ID, or nil on failure.
        case opening([(UInt64?) -> Void])
        case open(UInt64)
        /// Close accepted; waiters reopen (with a new engine ID) once it completes.
        case closing(UInt64, reopenWaiters: [(UInt64?) -> Void])
    }

    private enum LifecycleOperation {
        case open(ChromiumProfileKey)
        case close(ChromiumProfileKey, force: Bool, attempt: Int, completion: (ReArcStatus, Bool) -> Void)
    }

    private var profileStates: [ChromiumProfileKey: ProfileState] = [:]
    /// Open profiles in open order (teardown closes children in this order).
    private var profileOrder: [ChromiumProfileKey] = []
    /// The engine serializes profile lifecycle: a close needs no open or close in
    /// flight, and opens are refused during a close. The shell queues instead.
    private var lifecycleQueue: [LifecycleOperation] = []
    private var opensInFlight = 0
    private var closeInFlight = false
    private var tabClosesInFlight = 0
    private var deferredShutdown: (force: Bool, completion: (ReArcStatus, Bool) -> Void)?
    private static let busyRetryLimit = 50

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
        // Both callbacks must be registered before any tab exists or editor code runs.
        if capabilities.pageZoom {
            ReArcEngineSetZoomCallback(zoomCallback, context)
        }
        if capabilities.isolatedPageMessages {
            ReArcEngineSetPageMessageCallback(pageMessageCallback, context)
        }
        onReady?()
    }

    /// The wave-11 engine (ABI 1.0) has no `ReArcEngineABIMinorVersion` export,
    /// and the framework is weak-linked, so probe the symbol before calling it.
    /// Every newer entry point is called only behind its capability flag.
    private static func probeCapabilities() -> ChromiumCapabilities {
        let hasMinorExport = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineABIMinorVersion") != nil
        let minor = hasMinorExport ? ReArcEngineABIMinorVersion() : nil
        return ChromiumCapabilities(abiMinorVersion: minor) { name in
            name.withCString { ReArcEngineHasFeature($0) }
        }
    }

    // MARK: Profiles

    /// Resolves the engine profile for `key`, opening it on first use. `body`
    /// runs synchronously when the profile is already open, otherwise after the
    /// engine's deferred completion; nil means it could not be opened.
    func withEngineProfile(_ key: ChromiumProfileKey, _ body: @escaping (UInt64?) -> Void) {
        guard isReady, !isStopping else { return body(nil) }
        guard capabilities.profiles else {
            // Pre-1.6 engines admit only the startup profile: no storage isolation.
            return body(key.isOffTheRecord ? nil : defaultProfileID)
        }
        if key.isOffTheRecord, !capabilities.profileOffTheRecord {
            ChromiumLog.info("\(key): engine lacks profile_off_the_record")
            return body(nil)
        }
        switch profileStates[key] {
        case .open(let id):
            body(id)
        case .opening(let waiters):
            profileStates[key] = .opening(waiters + [body])
        case .closing(let id, let waiters):
            profileStates[key] = .closing(id, reopenWaiters: waiters + [body])
        case nil:
            profileStates[key] = .opening([body])
            lifecycleQueue.append(.open(key))
            pumpLifecycle()
        }
    }

    /// The engine ID of an open profile.
    func engineProfileID(for key: ChromiumProfileKey) -> UInt64? {
        guard capabilities.profiles else { return key.isOffTheRecord ? nil : defaultProfileID }
        if case .open(let id) = profileStates[key] { return id }
        return nil
    }

    /// The shell key of an open engine profile: Chromium-created tabs (popups)
    /// inherit their opener's BrowserContext. nil while that profile closes.
    func profileKey(forEngineProfile engineID: UInt64) -> ChromiumProfileKey? {
        guard engineID != 0 else { return nil }
        return profileStates.first { _, state in
            if case .open(let id) = state { return id == engineID }
            return false
        }?.key
    }

    /// Closes the engine profile behind `key` and its tabs. A persistent
    /// profile's private children close first, one at a time; the completion
    /// reports the last close (or the first failure, which stops the sequence).
    /// The default profile is never closed: engine shutdown owns it.
    func closeProfile(_ key: ChromiumProfileKey, force: Bool, completion: @escaping (ReArcStatus, Bool) -> Void) {
        guard capabilities.profiles, isReady, !isStopping else { return completion(.rearcOK, false) }
        let order = ChromiumProfileTeardown.closeOrder(for: key, among: profileOrder + pendingKeys)
        closeSequentially(order[...], force: force, completion: completion)
    }

    private var pendingKeys: [ChromiumProfileKey] {
        profileStates.compactMap { key, state in
            if case .opening = state, !profileOrder.contains(key) { return key }
            return nil
        }
    }

    private func closeSequentially(
        _ keys: ArraySlice<ChromiumProfileKey>,
        force: Bool,
        completion: @escaping (ReArcStatus, Bool) -> Void
    ) {
        guard let key = keys.first else { return completion(.rearcOK, false) }
        let rest = keys.dropFirst()
        lifecycleQueue.append(.close(key, force: force, attempt: 0) { [weak self] status, cancelled in
            guard let self, status == .rearcOK, !cancelled, !rest.isEmpty else { return completion(status, cancelled) }
            self.closeSequentially(rest, force: force, completion: completion)
        })
        pumpLifecycle()
    }

    private func pumpLifecycle() {
        while let next = lifecycleQueue.first {
            switch next {
            case .open(let key):
                guard !closeInFlight else { return }
                lifecycleQueue.removeFirst()
                startOpen(key)
            case .close(let key, let force, let attempt, let completion):
                guard !closeInFlight, opensInFlight == 0 else { return }
                lifecycleQueue.removeFirst()
                startClose(key, force: force, attempt: attempt, completion: completion)
            }
        }
    }

    private func startOpen(_ key: ChromiumProfileKey) {
        guard case .opening = profileStates[key] else { return }
        opensInFlight += 1
        let finish: (ReArcStatus, UInt64, Bool) -> Void = { [self] status, id, offTheRecord in
            opensInFlight -= 1
            completeOpen(key, status: status, engineID: id, offTheRecord: offTheRecord)
            pumpLifecycle()
            startDeferredShutdownIfIdle()
        }
        switch key {
        case .persistent:
            let name = key.storageKey ?? ""
            guard ChromiumProfileKey.isValidStorageKey(name) else {
                return finish(ReArcStatus(REARC_INVALID_ARGUMENT), 0, false)
            }
            let status = callProfile(finish) { context, callback in
                name.withCString { ReArcProfileOpen($0, callback, context) }
            }
            if status != .rearcOK { finish(status, 0, false) }
        case .offTheRecord(_, let parent):
            withEngineProfile(.persistent(parent)) { [self] parentID in
                guard let parentID, isReady, !isStopping else {
                    return finish(ReArcStatus(REARC_PROFILE_NOT_FOUND), 0, true)
                }
                let status = callProfile(finish) { context, callback in
                    ReArcProfileCreateOffTheRecord(parentID, callback, context)
                }
                if status != .rearcOK { finish(status, 0, true) }
            }
        }
    }

    /// Runs a profile-creation call with a retained context; a synchronous
    /// rejection invokes no callback, so the context is released here.
    private func callProfile(
        _ completion: @escaping (ReArcStatus, UInt64, Bool) -> Void,
        _ start: (UnsafeMutableRawPointer, ReArcProfileCallback) -> ReArcStatus
    ) -> ReArcStatus {
        let box = Unmanaged.passRetained(ProfileRequestBox(completion)).toOpaque()
        let status = start(box, profileCallback)
        if status != .rearcOK {
            Unmanaged<ProfileRequestBox>.fromOpaque(box).release()
        }
        return status
    }

    private func completeOpen(_ key: ChromiumProfileKey, status: ReArcStatus, engineID: UInt64, offTheRecord: Bool) {
        guard case .opening(let waiters) = profileStates[key] else { return }
        if status == .rearcOK, engineID != 0 {
            profileStates[key] = .open(engineID)
            profileOrder.removeAll { $0 == key }
            profileOrder.append(key)
            profileEvent("opened \(key) -> engine profile \(engineID)\(offTheRecord ? " (off the record)" : "")")
            waiters.forEach { $0(engineID) }
        } else {
            profileStates[key] = nil
            profileEvent("open \(key) failed: \(status.rearcName)")
            waiters.forEach { $0(nil) }
        }
    }

    private func startClose(
        _ key: ChromiumProfileKey,
        force: Bool,
        attempt: Int,
        completion: @escaping (ReArcStatus, Bool) -> Void
    ) {
        switch profileStates[key] {
        case nil:
            completion(.rearcOK, false)
        case .opening(let waiters):
            // Close what is being opened once it exists.
            profileStates[key] = .opening(waiters + [{ [weak self] id in
                guard let self, id != nil else { return completion(.rearcOK, false) }
                self.lifecycleQueue.append(.close(key, force: force, attempt: 0, completion: completion))
                self.pumpLifecycle()
            }])
        case .closing:
            completion(ReArcStatus(REARC_BUSY), false)
        case .open(let id):
            if !capabilities.profiles || id == defaultProfileID {
                return completion(ReArcStatus(REARC_INVALID_STATE), false)
            }
            closeInFlight = true
            profileStates[key] = .closing(id, reopenWaiters: [])
            profileEvent("closing \(key) (engine profile \(id), force \(force))")
            let status = callAsync({ [self] status, cancelled in
                closeInFlight = false
                finishClose(key, engineID: id, status: status, cancelled: cancelled)
                completion(status, cancelled)
                pumpLifecycle()
                startDeferredShutdownIfIdle()
            }) { ReArcProfileClose(id, force, $1, $0) }
            guard status != .rearcOK else { return }
            closeInFlight = false
            profileStates[key] = .open(id)
            if status == ReArcStatus(REARC_BUSY), attempt < Self.busyRetryLimit {
                // Tab closes still in flight; retry shortly, ahead of later work.
                lifecycleQueue.insert(.close(key, force: force, attempt: attempt + 1, completion: completion), at: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in self?.pumpLifecycle() }
                return
            }
            profileEvent("close \(key) rejected: \(status.rearcName)")
            completion(status, false)
        }
    }

    private func finishClose(_ key: ChromiumProfileKey, engineID: UInt64, status: ReArcStatus, cancelled: Bool) {
        guard case .closing(_, let waiters) = profileStates[key] else { return }
        if status == .rearcOK, !cancelled {
            profileStates[key] = nil
            profileOrder.removeAll { $0 == key }
            profileEvent("closed \(key) (engine profile \(engineID) released)")
            if !waiters.isEmpty, !isStopping {
                profileStates[key] = .opening(waiters)
                lifecycleQueue.append(.open(key))
            } else {
                waiters.forEach { $0(nil) }
            }
        } else {
            // A beforeunload veto (or failure) keeps the profile, and its ID, available.
            profileStates[key] = .open(engineID)
            profileEvent("close \(key) \(cancelled ? "vetoed" : "failed: \(status.rearcName)"); profile stays open")
            waiters.forEach { $0(engineID) }
        }
    }

    private func profileEvent(_ message: String) {
        ChromiumLog.info("profile: \(message)")
        onProfileEvent?(message)
    }

    /// Profile request contexts still awaiting their callback.
    var liveProfileContexts: Int { ProfileRequestBox.live }

    // MARK: Tabs

    /// Creates the engine tab once its profile is open. `completion` gets the
    /// new tab ID (already registered), or nil.
    func createTab(for engine: ChromiumEngine, completion: @escaping (UInt64?) -> Void) {
        withEngineProfile(engine.profileKey) { [weak self, weak engine] profileID in
            guard let self, let engine, let profileID, self.isReady, !self.isStopping else { return completion(nil) }
            var tabID: UInt64 = 0
            let status = ReArcTabCreate(profileID, engine.role.rawValue, nil, &tabID)
            guard status == .rearcOK, tabID != 0 else {
                ChromiumLog.info("ReArcTabCreate(profile \(profileID)) failed: \(status.rearcName)")
                return completion(nil)
            }
            self.register(engine, tabID: tabID)
            completion(tabID)
        }
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
        forceCloseTab(tabID)
    }

    /// Force-closes a tab the shell no longer shows. Shutdown is busy while any
    /// tab close is pending, so it waits for these completions.
    private func forceCloseTab(_ tabID: UInt64) {
        let status = callAsync({ [self] _, _ in
            tabClosesInFlight -= 1
            startDeferredShutdownIfIdle()
        }) { ReArcTabClose(tabID, true, $1, $0) }
        if status == .rearcOK {
            tabClosesInFlight += 1
        } else if status != ReArcStatus(REARC_TAB_NOT_FOUND) {
            ChromiumLog.info("ReArcTabClose(\(tabID)) rejected: \(status.rearcName)")
        }
    }

    /// Fresh identity of the tab's current primary document; nil without
    /// `script_evaluation_identity` or when the query fails.
    func documentIdentity(tab: UInt64) -> ChromiumDocumentIdentity? {
        guard capabilities.scriptEvaluationIdentity, tab != 0 else { return nil }
        var identity = ReArcDocumentIdentity()
        guard ReArcTabGetDocumentIdentity(tab, &identity) == .rearcOK else { return nil }
        return ChromiumDocumentIdentity(identity)
    }

    // MARK: Windows and leases

    /// Registers a window on first use. 0 means registration failed.
    func windowID(for window: NSWindow) -> UInt64 {
        let key = ObjectIdentifier(window)
        if let id = windowIDs[key] { return id }
        guard isReady, !isStopping, !closedWindows.contains(window) else { return 0 }
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
        ) { [weak self, weak window] _ in
            guard let self else { return }
            if let window { self.closedWindows.add(window) }
            self.windowIDs[key] = nil
            if let observer = self.windowObservers.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        return id
    }

    var registeredWindowCount: Int { windowIDs.count }

    /// Live leases on one tab; the ABI allows one attachment per tab.
    func liveLeaseCount(forTab tab: UInt64) -> Int {
        leaseHosts.values.compactMap(\.value).filter { $0.engine.tabID == tab && $0.leaseAttachmentID != nil }.count
    }

    func isClosed(_ window: NSWindow) -> Bool { closedWindows.contains(window) }

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
            "tab_event \(event.kind) profile \(event.profileID) tab \(event.tabID) gen \(event.contentGeneration) "
                + "changes \(event.changes.rawValue) url \(event.url ?? "-") title \(event.title ?? "-") "
                + "loading \(event.isLoading) main \(event.isMainFrame) err \(event.errorCode) \(event.errorText ?? "")"
        )
        if event.kind == .created, engines[event.tabID] == nil {
            let adopted = onAdoptedTab?(event) ?? false
            if !adopted {
                ChromiumLog.info("closing unadopted Chromium-created tab \(event.tabID)")
                forceCloseTab(event.tabID)
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

    fileprivate func handleZoom(document: ChromiumDocumentIdentity, factor: Double) {
        ChromiumLog.trace("zoom_event \(document) factor \(factor)")
        engines[document.tabID]?.value?.handleZoom(document: document, factor: factor)
    }

    fileprivate func handlePageMessage(_ message: ChromiumPageMessage) {
        ChromiumLog.trace("page_message \(message.document) boost \(message.boostID) \(message.json.utf8.count) bytes")
        engines[message.document.tabID]?.value?.handlePageMessage(message)
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

    /// Script evaluation with a retained context: `ReArcTabEvaluateScript2`
    /// when the engine reports document identity, else the ABI 1.5 call. An
    /// accepted call completes exactly once on main; a rejected one never
    /// calls `completion`.
    func evaluateScript(
        tab: UInt64,
        source: String,
        world: ChromiumScriptWorld,
        timeoutMS: UInt32,
        completion: @escaping (ChromiumScriptResult) -> Void
    ) -> ReArcStatus {
        guard capabilities.scriptEvaluation else { return ReArcStatus(REARC_UNSUPPORTED) }
        let withIdentity = capabilities.scriptEvaluationIdentity
        let box = Unmanaged.passRetained(ScriptEvaluationBox(completion)).toOpaque()
        let status = source.withCString { sourcePointer in
            func start(_ boostID: UnsafePointer<CChar>?) -> ReArcStatus {
                withIdentity
                    ? ReArcTabEvaluateScript2(tab, sourcePointer, world.abiWorld, boostID, timeoutMS, scriptCallback2, box)
                    : ReArcTabEvaluateScript(tab, sourcePointer, world.abiWorld, boostID, timeoutMS, scriptCallback, box)
            }
            if let boostID = world.boostID {
                return boostID.withCString { start($0) }
            }
            return start(nil)
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

    /// Orderly engine shutdown; `ReArcEngineRun` returns after the final
    /// completion. The engine closes every profile's tabs and destroys private
    /// profiles before their parents. A profile or tab close in flight makes
    /// shutdown busy, so shutdown then waits for it; a rejection after waiting
    /// is reported through `completion`.
    @discardableResult
    func requestShutdown(force: Bool, completion: @escaping (ReArcStatus, Bool) -> Void) -> ReArcStatus {
        guard isReady, !isStopping else { return ReArcStatus(REARC_BUSY) }
        isStopping = true
        cancelQueuedLifecycle()
        // Pending opens are the engine's to cancel; closes in flight make shutdown busy.
        if closeInFlight || tabClosesInFlight > 0 {
            ChromiumLog.info("shutdown waits for closes in flight (profile \(closeInFlight), tabs \(tabClosesInFlight))")
            deferredShutdown = (force, completion)
            return .rearcOK
        }
        return startShutdown(force: force, completion: completion)
    }

    private func cancelQueuedLifecycle() {
        let queued = lifecycleQueue
        lifecycleQueue = []
        for operation in queued {
            switch operation {
            case .open(let key):
                if case .opening(let waiters) = profileStates[key] {
                    profileStates[key] = nil
                    waiters.forEach { $0(nil) }
                }
            case .close(_, _, _, let completion):
                completion(ReArcStatus(REARC_CANCELLED), false)
            }
        }
    }

    private func startDeferredShutdownIfIdle() {
        guard let deferred = deferredShutdown, !closeInFlight, tabClosesInFlight == 0 else { return }
        deferredShutdown = nil
        let status = startShutdown(force: deferred.force, completion: deferred.completion)
        if status != .rearcOK {
            deferred.completion(status, false)
        }
    }

    private func startShutdown(force: Bool, completion: @escaping (ReArcStatus, Bool) -> Void) -> ReArcStatus {
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
