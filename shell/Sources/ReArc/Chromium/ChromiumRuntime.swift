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
        /// ABI 1.25 `tab_discard`: logically discarded / restored (also on state refresh).
        case discarded, discardCleared
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
    /// Meaningful only with the ABI 1.30 PiP callback registered.
    var pipAvailable, pipActive: Bool
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
        pipAvailable = e.pip_available
        pipActive = e.pip_active
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
            album: album,
            pipAvailable: pipAvailable,
            pipActive: pipActive
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

/// `ReArcProfileOpenDirectory` (ABI 1.13), resolved with dlsym: the framework is
/// weak-linked and an older one does not export it (WAVE-16-REPORT.md step 5).
private typealias ProfileDirectoryOpen = @convention(c) (
    UnsafePointer<CChar>?, ReArcProfileCallback?, UnsafeMutableRawPointer?
) -> ReArcStatus

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

private let earlyWindowCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    MainActor.assumeIsolated { runtime(from: context).handleEarlyWindow() }
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

private let themeColorCallback: ReArcThemeColorCallback = { context, event in
    guard let e = event?.pointee else { return }
    let document = ChromiumDocumentIdentity(e.document), color = e.has_color ? PageColor(argb: e.argb) : nil
    MainActor.assumeIsolated { runtime(from: context).handleThemeColor(document: document, color: color) }
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

private let findCallback: ReArcFindCallback = { context, event in
    guard let e = event?.pointee else { return }
    let tab = e.tab_id, generation = e.content_generation
    let copied = FindInPageEvent(
        sessionID: e.session_id,
        matchCount: e.match_count,
        activeOrdinal: e.active_ordinal,
        finalUpdate: e.final_update,
        rawReason: e.reason
    )
    MainActor.assumeIsolated { runtime(from: context).handleFind(tab: tab, contentGeneration: generation, event: copied) }
}

/// Owned copy of `ReArcFullscreenEvent` (ABI 1.27).
struct ChromiumFullscreenEvent: Equatable {
    enum Reason: UInt32 {
        case page = 0, host, escape, closed, hidden
    }

    var profileID, tabID, contentGeneration: UInt64
    /// Phase 0 entered, 1 exited.
    var entered: Bool
    /// Exit only.
    var reason: Reason?
    /// Chromium display ID the page asked for, -1 for none.
    var displayID: Int64
}

private let fullscreenCallback: ReArcFullscreenCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumFullscreenEvent(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation,
        entered: e.phase == 0, reason: e.phase == 0 ? nil : ChromiumFullscreenEvent.Reason(rawValue: e.reason),
        displayID: e.display_id
    )
    MainActor.assumeIsolated { runtime(from: context).handleFullscreen(copied) }
}

/// Owned copy of `ReArcKeyEquivalentEvent` (ABI 1.42): the page's verdict on
/// a Command or Control key it was given.
struct ChromiumKeyEquivalentEvent: Equatable {
    var profileID, tabID: UInt64
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var consumed: Bool
    var characters: String
}

private let keyEquivalentCallback: ReArcKeyEquivalentCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumKeyEquivalentEvent(
        profileID: e.profile_id, tabID: e.tab_id, keyCode: UInt16(truncatingIfNeeded: e.key_code),
        modifiers: NSEvent.ModifierFlags(rawValue: UInt(e.modifiers)), consumed: e.consumed,
        characters: e.characters.map { String(cString: $0) } ?? ""
    )
    MainActor.assumeIsolated { runtime(from: context).handleKeyEquivalent(copied) }
}

/// Owned copy of `ReArcPrintRequestEvent` (ABI 1.28): the page asked to print.
struct ChromiumPrintRequestEvent: Equatable {
    var profileID, tabID, contentGeneration: UInt64
    /// 0 window.print(), 1 another page request.
    var source: UInt32
}

private let printCallback: ReArcPrintCallback = { context, event in
    guard let e = event?.pointee else { return }
    let copied = ChromiumPrintRequestEvent(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation, source: e.source
    )
    MainActor.assumeIsolated { runtime(from: context).handlePrintRequest(copied) }
}

/// Owned copy of `ReArcPictureInPictureEvent` (ABI 1.30).
struct ChromiumPictureInPictureEvent: Equatable {
    enum Phase: UInt32 {
        case entered = 0, exited, backToTab
    }

    var profileID, tabID, contentGeneration: UInt64
    var phase: Phase
}

private let pictureInPictureCallback: ReArcPictureInPictureCallback = { context, event in
    guard let e = event?.pointee, let phase = ChromiumPictureInPictureEvent.Phase(rawValue: e.phase) else { return }
    let copied = ChromiumPictureInPictureEvent(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation, phase: phase
    )
    MainActor.assumeIsolated { runtime(from: context).handlePictureInPicture(copied) }
}

private let videoOverlayCallback: ReArcVideoOverlayCallback = { context, event in
    guard let e = event?.pointee, let kind = ChromiumVideoOverlayEvent.Kind(rawValue: e.kind) else { return }
    // `created` hands over a +1 view; take that reference here.
    let view = e.view.map { Unmanaged<NSView>.fromOpaque($0).takeRetainedValue() }
    let copied = ChromiumVideoOverlayEvent(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation, overlayID: e.overlay_id,
        kind: kind, view: view, width: e.width, height: e.height, playback: e.playback, buttons: e.buttons,
        muted: e.muted, duration: e.duration, position: e.position, rate: e.rate,
        title: e.title.map { String(cString: $0) } ?? ""
    )
    MainActor.assumeIsolated { runtime(from: context).handleVideoOverlay(copied) }
}
/// Context for one `ReArcTabPrintToPDF`. Retained (+1) across the C call;
/// released once, by the completion or on synchronous rejection.
final class PrintToPDFBox {
    static var live = 0

    let body: (ReArcStatus, UInt64, Data?) -> Void

    init(_ body: @escaping (ReArcStatus, UInt64, Data?) -> Void) {
        self.body = body
        Self.live += 1
    }

    deinit {
        Self.live -= 1
    }
}

let printToPDFCallback: ReArcPdfCallback = { context, status, _, generation, data, size in
    guard let context else {
        if let data { ReArcBufferFree(data) }
        return
    }
    var pdf: Data?
    if let data {
        if status == .rearcOK, size > 0 { pdf = Data(bytes: data, count: size) }
        // The host owns the bytes even when the result is stale or rejected.
        ReArcBufferFree(data)
    }
    let box = Unmanaged<PrintToPDFBox>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { box.body(status, generation, pdf) }
}

/// Owned copy of `ReArcDownloadEvent`; its strings die with the callback.
struct ChromiumDownloadEvent {
    var profileID: UInt64
    var downloadID: UInt32
    var tabID: UInt64
    var event: DownloadEvent
    /// The item's own start and end (ABI 1.49 batches carry them); nil: ask `downloadTimes`.
    var times: (started: Date, ended: Date?)?

    init?(_ pointer: UnsafePointer<ReArcDownloadEvent>?, times: ReArcDownloadTimes? = nil) {
        guard let e = pointer?.pointee, let kind = DownloadEvent.Kind(rawValue: e.kind) else { return nil }
        profileID = e.profile_id
        downloadID = e.download_id
        tabID = e.tab_id
        event = DownloadEvent(
            kind: kind,
            guid: e.guid.map { String(cString: $0) } ?? "",
            url: e.url.map { String(cString: $0) } ?? "",
            targetPath: e.target_path.map { String(cString: $0) } ?? "",
            mimeType: e.mime_type.map { String(cString: $0) } ?? "",
            receivedBytes: e.received_bytes,
            totalBytes: e.total_bytes,
            state: DownloadState(engineState: e.state),
            dangerType: e.danger_type,
            interruptReason: e.interrupt_reason,
            isPaused: e.paused,
            canResume: e.can_resume
        )
        if let times, times.start_time_us > 0 {
            func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
            self.times = (date(times.start_time_us), times.end_time_us > 0 ? date(times.end_time_us) : nil)
        }
    }
}

private let downloadCallback: ReArcDownloadCallback = { context, event in
    guard let copied = ChromiumDownloadEvent(event) else { return }
    MainActor.assumeIsolated { runtime(from: context).handleDownload(copied) }
}

/// ABI 1.49: a history slice's created events in one call, with their times.
private let downloadBatchCallback: ReArcDownloadBatchCallback = { context, events, times, count in
    guard let events, count > 0 else { return }
    var copied: [ChromiumDownloadEvent] = []
    copied.reserveCapacity(Int(count))
    for i in 0 ..< Int(count) {
        if let event = ChromiumDownloadEvent(events + i, times: times?[i]) { copied.append(event) }
    }
    MainActor.assumeIsolated { runtime(from: context).handleDownloads(copied) }
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
    /// early_window (ABI 1.45): runs once inside `ReArcEngineRun`, when the
    /// application exists and before browser threads, profiles and `ready`.
    /// AppKit windows only; the main queue is not serviced until after it.
    var onEarlyWindow: (() -> Void)?
    /// The engine has ABI 1.45 `early_window` (static; callable before `run`).
    var supportsEarlyWindow: Bool { Self.probeCapabilities().earlyWindow }
    /// When the early-window callback ran and when ready arrived (uptime clock).
    private(set) var earlyWindowAt: TimeInterval?
    private(set) var readyAt: TimeInterval?
    /// Runs before shutdown starts for an AppKit quit request (persist shell state here).
    var onTerminateRequested: (() -> Void)?
    /// Chromium-created contents (popups, target=_blank). Return true to adopt;
    /// unadopted tabs are force-closed.
    var onAdoptedTab: ((ChromiumTabEvent) -> Bool)?
    /// Profile lifecycle transitions, for logs and the self-test.
    var onProfileEvent: ((String) -> Void)?
    /// Download events (ABI 1.17), for the shell's tray.
    var onDownloadEvent: ((ChromiumDownloadEvent) -> Void)?
    /// A batch of download events (ABI 1.49), in order; without it each goes to `onDownloadEvent`.
    var onDownloadEvents: (([ChromiumDownloadEvent]) -> Void)?
    /// A profile's download history finished loading (ABI 1.48), after its live items' events.
    var onDownloadHistoryLoaded: ((ChromiumDownloadHistoryInfo) -> Void)?
    /// Page fullscreen requests and exits (ABI 1.27); without a handler the engine refuses requests.
    var onFullscreenEvent: ((ChromiumFullscreenEvent) -> Void)?
    /// Page verdicts on Command/Control keys (ABI 1.42), for `ShortcutRouter`.
    var onKeyEquivalent: ((ChromiumKeyEquivalentEvent) -> Void)?
    /// The last verdicts received (self-test).
    var keyEquivalentEvents: [ChromiumKeyEquivalentEvent] = []
    /// PiP's back-to-tab button (ABI 1.30 phase 2): present and focus the tab.
    var onPictureInPictureBackToTab: ((ChromiumEngine) -> Void)?
    /// Print requests received and PiP events, per kind (logs, self-test).
    private(set) var printRequests = 0
    private(set) var pictureInPictureEvents: [ChromiumPictureInPictureEvent] = []
    /// Live engine video overlays by overlay ID (ABI 1.43), until `closed`.
    private(set) var videoOverlays: [UInt64: ChromiumVideoOverlay] = [:]
    /// Overlay event kinds received, in order (logs, self-test).
    private(set) var videoOverlayEvents: [(overlayID: UInt64, kind: ChromiumVideoOverlayEvent.Kind)] = []
    /// The drop policy the engine accepted at `ready` (nil: drops into pages stay aborted).
    private(set) var dropPolicy: PageDropPolicy?
    /// Default download directory, written to every open profile's Chromium
    /// download prefs (`ReArcDownloadSetPolicy`, save without asking).
    var downloadDirectory: URL? {
        didSet { if downloadDirectory != oldValue { applyDownloadPolicyToOpenProfiles() } }
    }
    /// "Ask where to save" (ABI 1.19 policy prompt 1): Chromium asks through the file chooser.
    var asksWhereToSaveDownloads = false {
        didSet { if asksWhereToSaveDownloads != oldValue { applyDownloadPolicyToOpenProfiles() } }
    }
    /// A download save-path request with no live tab to show it (presents its own panel).
    var onDownloadSaveRequest: ((ChromiumFileChooserEvent) -> Void)?
    /// The engine withdrew a file chooser request (any tab), for that panel.
    var onDownloadSaveCancelled: ((UInt64) -> Void)?
    /// Prompt channel events received and replies sent, per channel (logs, self-test).
    var promptEvents: [String: Int] = [:]
    var promptReplies: [String: Int] = [:]

    // Wave 27 (ABI 1.31–1.38): extensions, autofill, save offers, HTTP auth.
    /// Install/uninstall prompts and notices; without it requests are cancelled.
    var onExtensionPrompt: ((ChromiumExtensionPromptEvent) -> Void)?
    var onExtensionActionEvent: ((ChromiumExtensionActionEvent) -> Void)?
    /// tabs.create / windows.create / options / activate; without it requests are declined.
    var onExtensionTabRequest: ((ExtensionTabRequest) -> Void)?
    /// The created event of a popup tab `runExtensionAction` announced; false closes it.
    /// Side panel tabs (`openSidePanel`, ABI 1.47) come through here too.
    var onExtensionPopupCreated: ((ChromiumTabEvent) -> Bool)?
    /// sidePanel.open / close requests and options changes (ABI 1.47).
    var onSidePanelEvent: ((ChromiumSidePanelEvent) -> Void)?
    /// Every tab.closed, after the engine saw it.
    var onTabClosed: ((ChromiumTabEvent) -> Void)?
    /// "Manage…" in the suggestions: Chromium's settings page for the product.
    var onAutofillSettings: ((URL, ChromiumEngine?) -> Void)?
    /// ReArc > Check Passwords for Leaks; applied to each persistent profile as it opens.
    var leakDetectionPreference = PasswordLeakDetectionPreference()
    var expectedExtensionPopups: Set<UInt64> = []
    /// DevTools frontends (ABI 1.40): announced by `openDevTools`, then open until closed.
    var expectedDevToolsFrontends: Set<UInt64> = []
    var devToolsFrontends: Set<UInt64> = []
    /// The target of an `openDevTools` call in progress (its frontend's created event may come inside it).
    var devToolsOpeningTarget: UInt64 = 0
    /// A frontend's created event; false closes it.
    var onDevToolsFrontendCreated: ((ChromiumTabEvent) -> Bool)?
    var onDevToolsFrontendClosed: ((UInt64) -> Void)?
    /// Dockable frontends (ABI 1.54): their device-mode toolboxes (opener = the frontend), open until closed.
    var devToolsToolboxes: Set<UInt64> = []
    /// A toolbox's created event; false closes it.
    var onDevToolsToolboxCreated: ((ChromiumTabEvent) -> Bool)?
    var onDevToolsToolboxClosed: ((UInt64) -> Void)?
    /// A dockable frontend's Dock side and page bounds.
    var onDevToolsDock: ((ChromiumDevToolsDockEvent) -> Void)?
    /// The page menu's Inspect on this page.
    var onInspectRequested: ((ChromiumEngine) -> Void)?
    /// Client-certificate requests seen and replies sent, for logs and the self-test.
    var clientCertificateEvents: [ChromiumClientCertificateEvent] = []
    /// Recorded for the self-test.
    var extensionPromptEvents: [ChromiumExtensionPromptEvent] = []
    var extensionActionEvents: [ChromiumExtensionActionEvent] = []
    var extensionTabRequests: [ExtensionTabRequest] = []
    /// ⌘/⇧⌘/⇧/⌥⌘/middle-click link opens (ABI 1.39); without it they are refused.
    var onLinkOpen: ((ChromiumLinkOpenEvent) -> Void)?
    var linkOpenEvents: [ChromiumLinkOpenEvent] = []
    /// The shell profile that may take over the startup `Default` directory
    /// (the first profile); set before any of its tabs are created.
    var legacyDefaultOwner: Profile.ID?

    /// `--user-data-dir` and `--profile-directory` the engine runs with.
    private(set) var userDataDir: URL?
    private(set) var startupDirectory = ChromiumProfileStorageMap.defaultDirectory
    /// Directory mappings and the Default decision, persisted in the user-data-dir.
    private(set) var storageMap = ChromiumProfileStorageMap()

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
        userDataDir = ChromiumLaunchArguments.userDataDir(in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        startupDirectory = ChromiumLaunchArguments.startupProfileDirectory(in: arguments)
        if let url = storageMapURL { storageMap = ChromiumProfileStorageMap.load(from: url) }
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
        // Registered whenever the engine has it, so the self-test sees the stage ran.
        if supportsEarlyWindow {
            ReArcEngineSetEarlyWindowCallback(earlyWindowCallback, context)
        }
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        argv.append(nil)
        PerfSignposts.launchEvent("EngineRunCalled")
        let code = argv.withUnsafeBufferPointer { ReArcEngineRun(Int32(arguments.count), $0.baseAddress) }
        isReady = false
        ChromiumLog.info("ReArcEngineRun returned \(code)")
        return code
    }

    fileprivate func handleEarlyWindow() {
        earlyWindowAt = ProcessInfo.processInfo.systemUptime
        LaunchTimeline.earlyWindow = earlyWindowAt
        PerfSignposts.launchEvent("EarlyWindow")
        onEarlyWindow?()
    }

    fileprivate func handleReady(defaultProfileID profile: UInt64) {
        readyAt = ProcessInfo.processInfo.systemUptime
        defaultProfileID = profile
        capabilities = Self.probeCapabilities()
        isReady = true
        PerfSignposts.launchEvent("EngineReady")
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
        if capabilities.pageThemeColor {
            ReArcEngineSetThemeColorCallback(themeColorCallback, context)
        }
        if capabilities.findInPage {
            ReArcEngineSetFindCallback(findCallback, context)
        }
        // Prompt channels (ABI 1.18–1.22) before any tab, so no request falls to the no-host default.
        registerPromptChannels(context: context)
        // Wave 27 (ABI 1.32–1.38), before any tab.
        registerExtensionChannels(context: context)
        registerAutofillChannels(context: context)
        registerClientCertificateChannel(context: context)
        // ABI 1.54: before any frontend opens, so every frontend can dock.
        registerDevToolsDockChannel(context: context)
        // ABI 1.46: camera and microphone use for the call card, before any tab.
        registerMediaCaptureChannel(context: context)
        // ABI 1.47: extension side panel requests, before any tab.
        registerSidePanelChannel(context: context)
        if capabilities.htmlFullscreen {
            ReArcEngineSetFullscreenCallback(fullscreenCallback, context)
        }
        // Wave 30 (ABI 1.42): unconsumed page keys come back to the shell's menu.
        if capabilities.keyEquivalentEvents {
            ReArcEngineSetKeyEquivalentCallback(keyEquivalentCallback, context)
        }
        // Wave 24 (ABI 1.28–1.30), before any tab.
        if capabilities.printing {
            ReArcEngineSetPrintCallback(printCallback, context)
        }
        if capabilities.pageDrops {
            applyDropPolicy(.shell)
        }
        if capabilities.pictureInPicture {
            ReArcEngineSetPictureInPictureCallback(pictureInPictureCallback, context)
        }
        // Wave 32 (ABI 1.43): PiP video renders into shell views (sidebar card, floating panel).
        if capabilities.pipEmbedded {
            ReArcEngineSetVideoOverlayCallback(videoOverlayCallback, context)
        }
        if capabilities.downloads {
            // Before any tab exists; each profile gets its policy when it opens.
            ReArcEngineSetDownloadCallback(downloadCallback, context)
            if capabilities.downloadEventBatches { ReArcEngineSetDownloadBatchCallback(downloadBatchCallback, context) }
            registerDownloadHistoryChannel(context: context)
            applyDownloadPolicy(profile: defaultProfileID)
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
    /// Profiles whose open completed.
    var openProfileKeys: [ChromiumProfileKey] {
        profileStates.compactMap { key, state in
            if case .open = state { return key }
            return nil
        }
    }

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
        case .persistent(let profileID):
            startPersistentOpen(profileID, finish: finish)
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

    /// Opens a persistent profile by its storage plan (WAVE-16-REPORT.md steps
    /// 4–6): named key, recorded directory, or the one-time Default adoption.
    private func startPersistentOpen(_ profileID: Profile.ID, finish: @escaping (ReArcStatus, UInt64, Bool) -> Void) {
        ChromiumProfileStorageIO.plan(
            for: profileID, map: storageMap, legacyOwner: legacyDefaultOwner,
            engine: .init(canOpenDirectory: capabilities.profileDirectory, startupDirectory: startupDirectory),
            userDataDir: userDataDir
        ) { [self] plan in
            guard isReady, !isStopping else { return finish(ReArcStatus(REARC_INVALID_STATE), 0, false) }
            applyPersistentOpenPlan(plan, profileID: profileID, finish: finish)
        }
    }

    private func applyPersistentOpenPlan(_ plan: ChromiumProfileStoragePlan, profileID: Profile.ID,
                                         finish: @escaping (ReArcStatus, UInt64, Bool) -> Void) {
        let key = ChromiumProfileKey.persistent(profileID)
        switch plan {
        case .named(let name):
            openNamed(name, finish: finish)
        case .keepNamed(let name):
            profileEvent("\(key) keeps its named data; startup Default left in place")
            storageMap.legacyDefault = .keptNamed
            saveStorageMap { [self] in openNamed(name, finish: finish) }
        case .directory(let token):
            openDirectory(token, finish: finish)
        case .startupProfile:
            profileEvent("\(key) maps to \(startupDirectory); engine lacks profile_directory, using the startup profile")
            finish(.rearcOK, defaultProfileID, false)
        case .unsupported(let token):
            profileEvent("\(key) maps to directory \(token), which this engine cannot open")
            finish(ReArcStatus(REARC_UNSUPPORTED), 0, false)
        case .adoptDefault:
            let token = ChromiumProfileStorageMap.defaultDirectory
            openDirectory(token) { [self] status, id, offTheRecord in
                guard status == .rearcOK, id != 0 else {
                    // Nothing is recorded, so a later launch decides again.
                    profileEvent("adopting \(token) for \(key) failed: \(status.rearcName); opening named")
                    return openNamed(ChromiumProfileKey.storageKey(for: profileID), finish: finish)
                }
                storageMap.recordDirectory(token, for: profileID)
                saveStorageMap { [self] in
                    profileEvent("adopted \(token) in place for \(key)\(id == defaultProfileID ? " (startup profile)" : "")")
                    finish(status, id, offTheRecord)
                }
            }
        }
    }

    private func openNamed(_ name: String, finish: @escaping (ReArcStatus, UInt64, Bool) -> Void) {
        guard ChromiumProfileKey.isValidStorageKey(name) else {
            return finish(ReArcStatus(REARC_INVALID_ARGUMENT), 0, false)
        }
        let interval = PerfSignposts.beginEngineCall("ProfileOpen")
        let status = callProfile({ status, id, otr in interval.end(); finish(status, id, otr) }) { context, callback in
            name.withCString { ReArcProfileOpen($0, callback, context) }
        }
        if status != .rearcOK { finish(status, 0, false) }
    }

    /// `ReArcProfileOpenDirectory` through the same retained one-shot callback as
    /// ProfileOpen. Unsupported when the engine or its export is missing.
    func openDirectory(_ token: String, finish: @escaping (ReArcStatus, UInt64, Bool) -> Void) {
        guard capabilities.profileDirectory,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcProfileOpenDirectory") else {
            return finish(ReArcStatus(REARC_UNSUPPORTED), 0, false)
        }
        let open = unsafeBitCast(symbol, to: ProfileDirectoryOpen.self)
        let interval = PerfSignposts.beginEngineCall("ProfileOpen")
        let status = callProfile({ status, id, otr in interval.end(); finish(status, id, otr) }) { context, callback in
            token.withCString { open($0, callback, context) }
        }
        if status != .rearcOK { finish(status, 0, false) }
    }

    private var storageMapURL: URL? {
        userDataDir?.appendingPathComponent(ChromiumProfileStorageMap.fileName)
    }

    private func saveStorageMap(completion: @escaping () -> Void) {
        guard let url = storageMapURL else { return completion() }
        ChromiumProfileStorageIO.save(storageMap, to: url) { error in
            if let error { ChromiumLog.info("could not save \(url.lastPathComponent): \(error.localizedDescription)") }
            completion()
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
            // Before the waiters create tabs; OTR profiles too (Chromium would otherwise ask where to save).
            applyDownloadPolicy(profile: engineID)
            if !offTheRecord { applyLeakDetectionPreference(profile: engineID) }
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
                // The startup profile (adopted Default included) lives until engine
                // shutdown: its private children closed first, its tabs closed when
                // the shell dropped their engines. ProfileClose would be invalid_state.
                profileEvent("\(key) is the startup profile (engine profile \(id)); it stays open until shutdown")
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
            let status = PerfSignposts.engineCall("TabCreate") { ReArcTabCreate(profileID, engine.role.rawValue, nil, &tabID) }
            guard status == .rearcOK, tabID != 0 else {
                ChromiumLog.info("ReArcTabCreate(profile \(profileID)) failed: \(status.rearcName)")
                return completion(nil)
            }
            self.register(engine, tabID: tabID)
            completion(tabID)
        }
    }

    /// The live shell engine of an engine tab.
    func engine(forTab tabID: UInt64) -> ChromiumEngine? {
        engines[tabID]?.value
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

    /// Force-closes a tab the shell no longer shows. Each completion arrives
    /// once; engines before ABI 1.12 make shutdown wait for them (`mustDeferShutdown`).
    func forceCloseTab(_ tabID: UInt64) {
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
        if event.kind == .created, engines[event.tabID] == nil, takeExpectedExtensionPopup(event.tabID) {
            // An extension action popup (disposition 3, opener = the clicked tab): never a sidebar tab.
            if onExtensionPopupCreated?(event) != true {
                ChromiumLog.info("closing extension popup tab \(event.tabID): no popup host")
                forceCloseTab(event.tabID)
            }
            return
        }
        if event.kind == .created, engines[event.tabID] == nil, takeExpectedDevToolsFrontend(event) {
            // A DevTools frontend (opener = the inspected tab): docked or in its own window, never a sidebar tab.
            devToolsFrontends.insert(event.tabID)
            if onDevToolsFrontendCreated?(event) != true {
                ChromiumLog.info("closing DevTools frontend \(event.tabID): no host")
                devToolsFrontends.remove(event.tabID)
                forceCloseTab(event.tabID)
            }
            return
        }
        if event.kind == .created, engines[event.tabID] == nil, devToolsFrontends.contains(event.openerTabID) {
            // A frontend's device-mode toolbox: behind the page while the frontend is undocked.
            devToolsToolboxes.insert(event.tabID)
            if onDevToolsToolboxCreated?(event) != true {
                ChromiumLog.info("closing DevTools toolbox \(event.tabID): no host")
                devToolsToolboxes.remove(event.tabID)
                forceCloseTab(event.tabID)
            }
            return
        }
        if event.kind == .closed, devToolsFrontends.remove(event.tabID) != nil {
            onDevToolsFrontendClosed?(event.tabID)
        }
        if event.kind == .closed, devToolsToolboxes.remove(event.tabID) != nil {
            onDevToolsToolboxClosed?(event.tabID)
        }
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
            if engineTabIDs[engine.shellID] == event.tabID { engineTabIDs[engine.shellID] = nil }
            onTabClosed?(event)
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

    fileprivate func handleThemeColor(document: ChromiumDocumentIdentity, color: PageColor?) {
        engines[document.tabID]?.value?.handleThemeColor(document: document, color: color)
    }

    fileprivate func handleFind(tab: UInt64, contentGeneration: UInt64, event: FindInPageEvent) {
        ChromiumLog.trace(
            "find_event tab \(tab) gen \(contentGeneration) session \(event.sessionID) matches \(event.matchCount) "
                + "active \(event.activeOrdinal) final \(event.finalUpdate) reason \(event.reason)"
        )
        engines[tab]?.value?.handleFind(event)
    }

    fileprivate func handleDownload(_ download: ChromiumDownloadEvent) {
        traceDownload(download)
        onDownloadEvent?(download)
    }

    fileprivate func handleDownloads(_ downloads: [ChromiumDownloadEvent]) {
        guard let onDownloadEvents else { return downloads.forEach(handleDownload) }
        if ChromiumLog.traceEnabled { downloads.forEach(traceDownload) }
        onDownloadEvents(downloads)
    }

    private func traceDownload(_ download: ChromiumDownloadEvent) {
        let e = download.event
        ChromiumLog.trace(
            "download_event \(e.kind) profile \(download.profileID) id \(download.downloadID) tab \(download.tabID) "
                + "state \(e.state) \(e.receivedBytes)/\(e.totalBytes) paused \(e.isPaused) resumable \(e.canResume) "
                + "danger \(e.dangerType) interrupt \(e.interruptReason) path \(e.targetPath.isEmpty ? "-" : e.targetPath)"
        )
    }

    // MARK: Downloads (ABI 1.17)

    /// `ReArcDownloadSetPolicy(profile, directory, prompt)`: prompt 0 saves without a
    /// picker; 1 ("Ask where to save", ABI 1.19) asks through the host file chooser.
    @discardableResult
    func applyDownloadPolicy(profile: UInt64) -> ReArcStatus {
        guard capabilities.downloads, profile != 0, isReady, !isStopping, let directory = downloadDirectory else {
            return ReArcStatus(REARC_UNSUPPORTED)
        }
        let prompt: UInt32 = asksWhereToSaveDownloads && capabilities.downloadSavePrompt ? 1 : 0
        let status = directory.path.withCString { ReArcDownloadSetPolicy(profile, $0, prompt) }
        if status != .rearcOK {
            ChromiumLog.info("ReArcDownloadSetPolicy(profile \(profile), \(directory.path), \(prompt)) rejected: \(status.rearcName)")
        } else {
            ChromiumLog.trace("download policy: profile \(profile) saves to \(directory.path) \(prompt == 1 ? "asking where" : "without asking")")
        }
        applyDownloadHistoryPolicy(profile: profile)
        return status
    }

    /// The default profile and every open one.
    var openEngineProfileIDs: Set<UInt64> {
        var profiles: Set<UInt64> = [defaultProfileID]
        for state in profileStates.values {
            if case .open(let id) = state { profiles.insert(id) }
        }
        return profiles
    }

    private func applyDownloadPolicyToOpenProfiles() {
        guard capabilities.downloads, isReady else { return }
        openEngineProfileIDs.forEach { applyDownloadPolicy(profile: $0) }
    }

    /// `ReArcDownloadAction`: 0 pause, 1 resume, 2 cancel, 3 open, 4 reveal, 5 remove.
    func downloadAction(profile: UInt64, id: UInt32, action: UInt32) -> ReArcStatus {
        guard capabilities.downloads, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcDownloadAction(profile, id, action)
        ChromiumLog.trace("download action \(action) profile \(profile) id \(id) -> \(status.rearcName)")
        return status
    }

    /// `ReArcDownloadGetWarning` (ABI 1.24): the item's current warning, nil when rejected.
    func downloadWarning(profile: UInt64, id: UInt32) -> (ReArcStatus, DownloadWarning?) {
        guard capabilities.dangerousDownloads, isReady, !isStopping else { return (ReArcStatus(REARC_UNSUPPORTED), nil) }
        var warning = ReArcDownloadWarning()
        let status = ReArcDownloadGetWarning(profile, id, &warning)
        guard status == .rearcOK else { return (status, nil) }
        return (status, DownloadWarning(dangerType: warning.danger_type, insecureStatus: warning.insecure_status,
                                        isDangerous: warning.is_dangerous, isInsecure: warning.is_insecure))
    }

    /// `ReArcDownloadResolveDanger`: keep (validate) or discard (remove item and file).
    func resolveDownloadDanger(profile: UInt64, id: UInt32, decision: DownloadDangerDecision) -> ReArcStatus {
        guard capabilities.dangerousDownloads, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = ReArcDownloadResolveDanger(profile, id, decision.rawValue)
        ChromiumLog.info("download \(id) danger \(decision) -> \(status.rearcName)")
        return status
    }

    fileprivate func handleFullscreen(_ event: ChromiumFullscreenEvent) {
        ChromiumLog.info("fullscreen_event tab \(event.tabID) gen \(event.contentGeneration) "
            + "\(event.entered ? "entered" : "exited reason \(event.reason.map { "\($0)" } ?? "?")") display \(event.displayID)")
        engines[event.tabID]?.value?.handleFullscreen(event)
        onFullscreenEvent?(event)
    }

    fileprivate func handleKeyEquivalent(_ event: ChromiumKeyEquivalentEvent) {
        ChromiumLog.trace("key_equivalent tab \(event.tabID) key \(event.keyCode) '\(event.characters)' "
            + "flags 0x\(String(event.modifiers.rawValue, radix: 16)) consumed \(event.consumed)")
        keyEquivalentEvents.append(event)
        if keyEquivalentEvents.count > 40 { keyEquivalentEvents.removeFirst(keyEquivalentEvents.count - 40) }
        onKeyEquivalent?(event)
    }

    fileprivate func handlePrintRequest(_ event: ChromiumPrintRequestEvent) {
        printRequests += 1
        ChromiumLog.info("print_request tab \(event.tabID) gen \(event.contentGeneration) source \(event.source)")
        engines[event.tabID]?.value?.handlePrintRequest(event)
    }

    fileprivate func handlePictureInPicture(_ event: ChromiumPictureInPictureEvent) {
        pictureInPictureEvents.append(event)
        ChromiumLog.info("pip_event tab \(event.tabID) gen \(event.contentGeneration) phase \(event.phase)")
        guard let engine = engines[event.tabID]?.value else { return }
        engine.handlePictureInPicture(event)
        if event.phase == .backToTab { onPictureInPictureBackToTab?(engine) }
    }

    fileprivate func handleVideoOverlay(_ event: ChromiumVideoOverlayEvent) {
        videoOverlayEvents.append((event.overlayID, event.kind))
        if videoOverlayEvents.count > 200 { videoOverlayEvents.removeFirst(videoOverlayEvents.count - 200) }
        if event.kind != .position {
            ChromiumLog.info("video_overlay \(event.overlayID) tab \(event.tabID) \(event.kind)")
        }
        switch event.kind {
        case .created:
            guard let view = event.view else { return }
            videoOverlays[event.overlayID] = ChromiumVideoOverlay(overlayID: event.overlayID, tabID: event.tabID, view: view)
        case .closed:
            guard let overlay = videoOverlays.removeValue(forKey: event.overlayID) else { return }
            engines[overlay.tabID]?.value?.videoOverlayChanged(nil)
        default:
            guard let overlay = videoOverlays[event.overlayID] else { return }
            overlay.apply(event)
            engines[overlay.tabID]?.value?.videoOverlayChanged(overlay)
        }
    }

    /// `ReArcEngineSetDropPolicy` (ABI 1.29). Each call replaces the whole policy.
    @discardableResult
    func applyDropPolicy(_ policy: PageDropPolicy) -> ReArcStatus {
        guard capabilities.pageDrops else { return ReArcStatus(REARC_UNSUPPORTED) }
        guard policy.isValid else { return ReArcStatus(REARC_INVALID_ARGUMENT) }
        let owned = policy.blockedTypes.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        let status = pointers.withUnsafeBufferPointer {
            ReArcEngineSetDropPolicy(policy.accept.rawValue, $0.baseAddress, $0.count)
        }
        ChromiumLog.info("drop policy accept \(policy.accept.rawValue) blocked \(policy.blockedTypes) -> \(status.rearcName)")
        if status == .rearcOK { dropPolicy = policy }
        return status
    }

    var livePrintContexts: Int { PrintToPDFBox.live }

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
    /// profiles before their parents. A profile close in flight makes shutdown
    /// busy, so shutdown waits for it. With `shutdown_pending_closes` (ABI 1.12)
    /// the engine joins tab closes still in flight, whose callbacks still
    /// arrive once before shutdown completes; older engines are busy then too.
    /// A rejection after waiting is reported through `completion`.
    @discardableResult
    func requestShutdown(force: Bool, completion: @escaping (ReArcStatus, Bool) -> Void) -> ReArcStatus {
        guard isReady, !isStopping else { return ReArcStatus(REARC_BUSY) }
        isStopping = true
        cancelQueuedLifecycle()
        // Pending opens are the engine's to cancel; closes in flight make shutdown busy.
        if mustDeferShutdown {
            ChromiumLog.info("shutdown waits for closes in flight (profile \(closeInFlight), tabs \(tabClosesInFlight))")
            deferredShutdown = (force, completion)
            return .rearcOK
        }
        if tabClosesInFlight > 0 {
            ChromiumLog.info("shutdown joins \(tabClosesInFlight) tab close(s) in flight (shutdown_pending_closes)")
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
        guard let deferred = deferredShutdown, !mustDeferShutdown else { return }
        deferredShutdown = nil
        let status = startShutdown(force: deferred.force, completion: deferred.completion)
        if status != .rearcOK {
            deferred.completion(status, false)
        }
    }

    private var mustDeferShutdown: Bool {
        ChromiumShutdownGate.mustDefer(
            profileCloseInFlight: closeInFlight,
            tabClosesInFlight: tabClosesInFlight,
            engineJoinsTabCloses: capabilities.shutdownPendingCloses
        )
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
