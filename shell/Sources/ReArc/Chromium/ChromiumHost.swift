#if REARC_CHROMIUM
import AppKit
import Foundation
import QuartzCore
import SidebarModel
import SwiftUI

/// Chromium-path process lifecycle (engine/docs/C-ABI.md "Linking and startup"):
/// configure before NSApplication exists, block in ReArcEngineRun on main,
/// build shell windows in `ready`, and exit with Run's result after shutdown.
enum ChromiumHost {
    /// Returns only when Chromium is unavailable (caller falls back to WebKit).
    @MainActor
    static func launch(_ options: EngineLaunchOptions) {
        LaunchTimeline.main = ProcessInfo.processInfo.systemUptime
        guard let reason = unavailableReason() else {
            let keychain = ChromiumLaunchArguments.keychainMode(
                infoDictionary: Bundle.main.infoDictionary,
                isDebugBuild: ChromiumLaunchArguments.isDebugBuild
            )
            switch keychain {
            case .system:
                break
            case .devMock:
                ChromiumLog.info(
                    "DEVELOPMENT BUNDLE: \(ChromiumLaunchArguments.mockKeychainSwitch) is on; cookies and Safe Storage "
                        + "data are NOT protected by the macOS Keychain. Never ship this bundle."
                )
            case .devMockRefused:
                ChromiumLog.info(
                    "\(ChromiumLaunchArguments.devMockKeychainInfoKey) ignored: release builds always use the macOS Keychain"
                )
            }
            let arguments = ChromiumLaunchArguments.browserArguments(
                CommandLine.arguments,
                defaultUserDataDir: {
                    defaultUserDataDir(selfTest: options.selfTest || options.launchProbePath != nil || options.bench != nil).path
                },
                keychain: keychain
            )
            let runtime = ChromiumRuntime.shared
            if options.selfTest {
                let test = ChromiumSelfTest(runtime: runtime)
                runtime.onReady = { test.start() }
                if let dir = ChromiumLaunchArguments.userDataDir(in: arguments) {
                    ChromiumLaunchArguments.prepareSelfTestUserDataDir(URL(fileURLWithPath: dir, isDirectory: true))
                }
                let extensions = SelfTestExtensionFixture.write()
                // ABI 1.41's test-only certificate store needs the mock keychain; the real Keychain is never listed.
                var mutualTLS: [String] = []
                if keychain == .devMock {
                    let (fixture, note) = SelfTestMutualTLS.start()
                    mutualTLS = fixture?.switches ?? []
                    test.mutualTLSNote = note
                } else {
                    test.mutualTLSNote = "the real-Keychain run lists no client identities"
                }
                let code = runtime.run(arguments: ChromiumLaunchArguments.selfTestArguments(arguments, extensionDirs: extensions.map(\.path))
                                           + mutualTLS,
                                       keychain: keychain)
                exit(test.exitCode(runResult: code))
            }
            if let bench = options.bench {
                // No self-test foreground switches: pages throttle as they do for users.
                // Only loopback names resolve, as in the self-test (the fixture server is 127.0.0.1).
                ChromiumBench.prepareLaunch()
                let runner = ChromiumBench(runtime: runtime, options: bench)
                if runtime.supportsEarlyWindow { runner.prepareLaunchChild() }
                runtime.onEarlyWindow = { runner.presentEarlyWindow() }
                runtime.onReady = { runner.start() }
                if let dir = ChromiumLaunchArguments.userDataDir(in: arguments) {
                    ChromiumLaunchArguments.prepareSelfTestUserDataDir(URL(fileURLWithPath: dir, isDirectory: true))
                }
                let code = runtime.run(arguments: ChromiumLaunchArguments.benchArguments(arguments), keychain: keychain)
                exit(runner.exitCode(runResult: code))
            }
            if let path = options.launchProbePath {
                let probe = ChromiumLaunchProbe(runtime: runtime, options: options, resultPath: path)
                runtime.onReady = { probe.start() }
                exit(probe.exitCode(runResult: runtime.run(arguments: arguments, keychain: keychain)))
            }
            // Links wait for the engine: the early window's model would open them in WebKit.
            ExternalLinkRouter.shared.hold()
            let shell = ChromiumShell(runtime: runtime)
            // Overlap JSON I/O/decoding with ChromeMain. Neither path waits on
            // the main queue: whichever finishes last starts the cached shell.
            let startup = ChromiumShellStartup(runtime: runtime, shell: shell)
            startup.prepare()
            runtime.onEarlyWindow = { startup.earlyWindow() }
            runtime.onReady = { startup.engineReady() }
            exit(runtime.run(arguments: arguments, keychain: keychain))
        }
        ReArcMain.unavailableChromium(options, reason: reason)
    }

    /// Chromium needs the app bundle layout with the embedded framework loaded.
    static func unavailableReason() -> String? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app" else {
            return "the executable is not running from an app bundle"
        }
        guard let frameworks = bundle.privateFrameworksURL,
              FileManager.default.fileExists(
                atPath: frameworks.appendingPathComponent("Chromium Framework.framework").path
              ) else {
            return "the bundle does not embed Chromium Framework.framework"
        }
        // Weak-linked: absent symbols mean the framework or its dylib closure failed to load.
        guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineConfigure") != nil else {
            return "Chromium Framework did not load (check the dylib closure next to the .app)"
        }
        return nil
    }

    static func defaultUserDataDir(selfTest: Bool) -> URL {
        let url: URL
        if selfTest {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rearc-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            url = ShellDataLocation.root.appendingPathComponent("Chromium", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Main-thread rendezvous: cached state and ABI readiness arrive independently.
/// With early_window (ABI 1.45) the cached window goes up before ready, from
/// inside ReArcEngineRun, where no main-queue turn runs: there the decode is
/// awaited on a semaphore (it takes 10–15 ms warm), never the main queue.
@MainActor
private final class ChromiumShellStartup {
    /// How long the early window waits for the sidebar decode; past it the
    /// window goes up at ready, as before.
    static let earlyWindowWait: TimeInterval = 0.25

    private let runtime: ChromiumRuntime
    private let shell: ChromiumShell
    private let loaded = PreparedStartupSlot()
    /// The model whose window went up early.
    private var earlyModel: BrowserViewModel?
    private var ready = false
    private var started = false

    init(runtime: ChromiumRuntime, shell: ChromiumShell) {
        self.runtime = runtime
        self.shell = shell
    }

    func prepare() {
        let file = SidebarFilePersistence.defaultFileURL
        let loaded = self.loaded
        DispatchQueue.global(qos: .userInitiated).async {
            loaded.fill(PreparedBrowserStartup.load(from: file))
            DispatchQueue.main.async { self.startIfReady() }
        }
    }

    func earlyWindow() {
        guard let prepared = loaded.wait(timeout: Self.earlyWindowWait) else {
            ChromiumLog.info("early window: sidebar not decoded within \(Int(Self.earlyWindowWait * 1000)) ms; the window waits for ready")
            return
        }
        // A first run opens on the sunrise, not on the browser.
        if FirstRunOnboarding.kind(isFirstRun: prepared.sidebar.outcome == .missingFile) != nil { return }
        let model = ChromiumShell.makeModel(runtime: runtime, prepared: prepared)
        earlyModel = model
        shell.presentCachedWindow(model: model)
    }

    func engineReady() {
        ready = true
        startIfReady()
    }

    private func startIfReady() {
        guard ready, !started else { return }
        if let earlyModel {
            started = true
            shell.start(model: earlyModel)
        } else if let prepared = loaded.value {
            started = true
            shell.start(model: ChromiumShell.makeModel(runtime: runtime, prepared: prepared))
        }
    }
}

/// The worker's decode, readable from the main thread with or without a run loop.
private final class PreparedStartupSlot: @unchecked Sendable {
    private let lock = NSLock()
    private let filled = DispatchSemaphore(value: 0)
    private var stored: PreparedBrowserStartup?

    var value: PreparedBrowserStartup? { lock.withLock { stored } }

    func fill(_ prepared: PreparedBrowserStartup) {
        lock.withLock { stored = prepared }
        filled.signal()
    }

    func wait(timeout: TimeInterval) -> PreparedBrowserStartup? {
        if let value { return value }
        _ = filled.wait(timeout: .now() + timeout)
        return value
    }
}

/// The normal Chromium-path UI. There are no SwiftUI scenes on this path, so
/// the shell owns its NSWindows: any number of browser windows sharing one
/// `BrowserViewModel` (as the WebKit path's WindowGroup does), Little Arc
/// and private windows through `BrowserWindowPresenting` (the same
/// `LittleArcWindowView` / `PrivateWindowView` the WebKit scenes show).
/// Closing a window never quits; Quit does.
///
/// Window teardown order (C-ABI.md "Core callbacks and ownership"): every
/// Chromium host in a closing window detaches first, so a tab shown in several
/// windows hands its one live attachment to a surviving window before the
/// engine invalidates the closing one.
final class ChromiumShell: NSObject, BrowserWindowPresenting, NSWindowDelegate {
    private enum WindowRole {
        case browser(SidebarWindowID)
        case littleArc(LittleArcWindow.ID)
        case privateBrowsing(PrivateWindowModel)
        case devTools(Tab.ID)
    }

    private let runtime: ChromiumRuntime
    private var model: BrowserViewModel?
    private var windows: [ObjectIdentifier: (window: NSWindow, role: WindowRole)] = [:]
    /// Settings… (⌘,): ReArc's own window; Chromium's pages sit behind its buttons.
    private var settingsWindow: SettingsWindowController?
    private let menuKeyEquivalents = MenuKeyEquivalents()
    private var airTrafficControlWindow: NSWindow?
    private var aboutWindow: AboutWindowController?
    /// One never-shown window, with no page or user state. Consumed once.
    private var preparedLittleArcWindow: NSWindow?
    private var terminating = false
    /// The cached window is up (`presentCachedWindow`) and `ready` has not run.
    private var awaitingReady = false
    private var onboarding: FirstRunOnboarding?
    private let menuTarget = ChromiumMenuTarget()
    /// The tray's Chromium side; the controller only holds it weakly.
    private var downloadBackend: ChromiumDownloadBackend?
    /// Toolbar actions, popups, extension prompts, windows and tab requests (wave 27).
    private(set) var extensionHost: ChromiumExtensionHost?
    private(set) var devToolsHost: ChromiumDevToolsHost?
    /// The window showing the HTML-fullscreen page, the native state the
    /// shell wants for it (nil: leave it as the user has it), and the
    /// transition in progress.
    private weak var fullscreenWindow: NSWindow?
    private var wantsNativeFullscreen: Bool?
    private var fullscreenTransitioning = false
    private var userLeavingFullscreen = false
    /// The self-test and benches run this shell on a throwaway sidebar and
    /// must neither restore nor save the user's window session.
    private let autosavesFrames: Bool
    /// `start` brings ReArc forward; a background bench turns it off.
    var activatesOnStart = true
    /// Where the browser-window session is kept (nil: not kept).
    private let sessionFileURL: URL?
    private var sessionRecorder: WindowSessionRecorder?
    /// The session read at launch, until its windows are open.
    private var launchSession: WindowSessionSnapshot?
    private var launchSessionLoaded = false
    /// The browser window closed last: a window opened with none left goes there.
    private var lastClosedBrowserWindow: SavedBrowserWindow?

    /// AppKit's frame autosave name before the window session (read once, to
    /// migrate). A launch on `REARC_DATA_DIR` had its own.
    static let mainWindowFrameName = ShellDataLocation.isOverridden
        ? "ReArcChromiumMainWindow.isolated" : "ReArcChromiumMainWindow"

    /// `sessionFile` overrides where the window session lives; by default it is
    /// `WindowSessionFile.defaultFileURL`, and nothing when `autosavesFrames` is off.
    init(runtime: ChromiumRuntime, autosavesFrames: Bool = true, sessionFile: URL? = nil) {
        self.runtime = runtime
        self.autosavesFrames = autosavesFrames
        self.sessionFileURL = sessionFile ?? (autosavesFrames ? WindowSessionFile.defaultFileURL : nil)
    }

    /// Loads the sidebar and names its first profile the owner of the startup
    /// Default directory (ABI 1.13; decided once, then persisted) before any
    /// tab exists. The model defers page/profile creation until the cached
    /// window chrome has committed.
    @MainActor
    static func makeModel(runtime: ChromiumRuntime, prepared: PreparedBrowserStartup? = nil) -> BrowserViewModel {
        let persistence = SidebarFilePersistence()
        let store = prepared.map { persistence.restoreStore(from: $0.sidebar) }
            ?? SidebarFilePersistence.loadStore(persistence: persistence)
        runtime.legacyDefaultOwner = store.profiles.first?.id
        let model = BrowserViewModel(store: store, persistence: persistence, preparedStartup: prepared, deferStartup: true)
        // Profile opens complete asynchronously; each gets this policy before its first tab.
        runtime.downloadDirectory = model.downloads.directory
        PerfSignposts.launchEvent("ModelLoaded")
        return model
    }

    /// early_window (ABI 1.45), from inside `ReArcEngineRun` before `ready`:
    /// orders front the browser window with the cached sidebar and commits it.
    /// No engine call is made, and services wait for `start(model:)` at ready.
    @MainActor
    func presentCachedWindow(model: BrowserViewModel) {
        precondition(self.model == nil)
        adopt(model)
        awaitingReady = true
        openBrowserWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func adopt(_ model: BrowserViewModel) {
        NSApp.setActivationPolicy(.regular)
        self.model = model
        model.windowPresenter = self
        if runtime.capabilities.searchEngines {
            model.searchEngineSettings = ChromiumSearchEngineSettings(runtime: runtime)
        }
    }

    /// At ready. `model` must come from `makeModel` (or name the Default owner
    /// itself first); after `presentCachedWindow` it must be the same model.
    @MainActor
    func start(model: BrowserViewModel) {
        if let early = self.model {
            precondition(early === model)
        } else {
            adopt(model)
        }
        model.presentAirTrafficControl = { [weak self] in self?.presentAirTrafficControl() }
        model.presentSettings = { [weak self] pane in MainActor.assumeIsolated { self?.presentSettings(pane) } }
        model.onShortcutOverridesChanged = { [weak self, weak model] in
            guard let self, let model, let menu = NSApp.mainMenu else { return }
            self.menuKeyEquivalents.apply(model.shortcutOverrides, to: menu)
        }
        if model.appIcon != .standard { model.appIcon.apply() }
        model.onProfileDeleted = { [weak self, runtime] id in
            // EngineHost already dropped the profile's engines. Its private windows
            // close first (their off-the-record children must go before the parent).
            self?.closePrivateWindows(parent: id)
            runtime.closeProfile(.persistent(id), force: true) { status, cancelled in
                ChromiumLog.info("deleted profile \(id): engine close \(status.rearcName) cancelled=\(cancelled)")
            }
        }
        model.onPrivateSessionEnded = { [runtime] last in
            guard let engine = last.engine as? ChromiumEngine else { return }
            // The session's last window keeps its engine (tab, lease, contexts) alive
            // until the off-the-record profile close has completed.
            runtime.closeProfile(engine.profileKey, force: true) { status, cancelled in
                ChromiumLog.info("private session ended: \(engine.profileKey) closed \(status.rearcName) "
                    + "cancelled=\(cancelled) (window \(last.id))")
            }
        }
        runtime.onAdoptedTab = { [weak self] event in
            self?.adopt(event) ?? false
        }
        if runtime.capabilities.downloads {
            let backend = ChromiumDownloadBackend(runtime: runtime, controller: model.downloads)
            backend.install()
            downloadBackend = backend
            // Keep and Discard are native from ABI 1.24; older engines review on chrome://downloads.
            if !runtime.capabilities.dangerousDownloads {
                model.downloads.canReviewDangerous = runtime.capabilities.webUIDailyPages
                model.downloads.reviewDangerousPage = { [weak model] in model?.openBrowserPage(.downloads) }
            }
        }
        model.commandBarServices = ChromiumCommandBarServices(runtime: runtime)
        let extensionHost = ChromiumExtensionHost(runtime: runtime, model: model)
        extensionHost.install()
        self.extensionHost = extensionHost
        let devToolsHost = ChromiumDevToolsHost(runtime: runtime, model: model)
        devToolsHost.install()
        self.devToolsHost = devToolsHost
        if runtime.capabilities.autofillSuggestions {
            // "Manage…" in the suggestions: Chromium's settings page for the product, as a tab.
            runtime.onAutofillSettings = { [weak model] url, _ in model?.openPageInNewTab(url, title: "Settings") }
        }
        if runtime.capabilities.passwordLeakDetection {
            // The self-test sets its own choice first (off: no sign-in reaches Google's leak service).
            if runtime.leakDetectionPreference.explicitChoice == nil { runtime.leakDetectionPreference = .load(from: .standard) }
            runtime.openPersistentEngineProfiles.forEach(runtime.applyLeakDetectionPreference(profile:))
        }
        if runtime.capabilities.pictureInPicture {
            runtime.onPictureInPictureBackToTab = { [weak self, weak model] engine in
                MainActor.assumeIsolated {
                    model?.revealTab(showing: engine)
                    let window = engine.leaseHolder?.window ?? self?.browserWindows.first
                    window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        if runtime.capabilities.htmlFullscreen {
            runtime.onFullscreenEvent = { [weak self] event in
                MainActor.assumeIsolated { self?.handleFullscreen(event) }
            }
        }
        if runtime.capabilities.keyEquivalentEvents {
            // A key the page did not take runs the menu's shortcut (ShortcutRouter).
            model.shortcutRouter.awaitsPageVerdicts = true
            runtime.onKeyEquivalent = { [weak model] event in
                model?.shortcutRouter.pageVerdict(
                    keyCode: event.keyCode, modifiers: ShortcutRouter.modifiers(of: event.modifiers), consumed: event.consumed)
            }
        }
        runtime.onTerminateRequested = { [weak self, weak model] in
            // Saved before any window closes, so quitting keeps them all.
            MainActor.assumeIsolated { self?.finishWindowSession() }
            self?.terminating = true
            model?.prepareForQuit()
        }
        let mainMenu = makeMainMenu(model: model)
        menuKeyEquivalents.apply(model.shortcutOverrides, to: mainMenu)
        NSApp.mainMenu = mainMenu
        ApplicationDockMenuHook.install { [weak self, weak model] in
            model?.dockMenu(newWindow: { self?.openBrowserWindow() })
        }
        if awaitingReady {
            // The cached window is up; the services it deferred start now.
            awaitingReady = false
            DispatchQueue.main.async { [weak model] in model?.finishStartup() }
        } else {
            openBrowserWindow()
        }
        // The launch window's saved siblings open behind it once the engine is up.
        DispatchQueue.main.async { [weak self] in self?.restoreOtherSessionWindows() }
        // In this same turn, so the first window is put away before it is ever drawn.
        if let kind = FirstRunOnboarding.kind(isFirstRun: model.isFirstRun) { runOnboarding(kind) }
        ExternalLinkRouter.shared.attach(model)
        ExternalLinkRouter.shared.release()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        if activatesOnStart { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.main.async { [weak self] in self?.prepareLittleArcWindow() }
    }

    /// The sunrise: on a first run, or Help › Watch the Sunrise Again.
    @MainActor
    func runOnboarding(_ kind: FirstRunOnboarding.Kind) {
        guard let model, onboarding == nil, !terminating else { return }
        let onboarding = FirstRunOnboarding(kind: kind, model: model) { [weak self] in self?.browserWindows ?? [] }
        self.onboarding = onboarding
        onboarding.start { [weak self] in self?.onboarding = nil }
    }

    @MainActor
    private func prepareLittleArcWindow() {
        guard model != nil, !terminating, preparedLittleArcWindow == nil else { return }
        preparedLittleArcWindow = makeWindow(
            size: NSSize(width: 520, height: 420), title: "Little Arc",
            content: NSHostingView(rootView: AnyView(Color.clear))
        )
        preparedLittleArcWindow?.isExcludedFromWindowsMenu = true
    }

    /// Dock click / app switch with no windows left: reopen a browser window.
    @MainActor
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        reopenIfNoWindows()
    }

    @MainActor
    func reopenIfNoWindows() {
        // The onboarding hides the browser windows and shows its own, untracked one;
        // coming back to the app mid-onboarding is not "no windows left".
        guard !terminating, onboarding == nil, !windows.values.contains(where: { $0.window.isVisible }) else { return }
        openBrowserWindow()
    }

    var browserWindows: [NSWindow] {
        windows.values.compactMap { if case .browser = $0.role { return $0.window } else { return nil } }
    }

    var browserWindowCount: Int { browserWindows.count }

    /// The per-window sidebar identity of a browser window.
    func sidebarWindowID(of window: NSWindow) -> SidebarWindowID? {
        if case .browser(let id) = windows[ObjectIdentifier(window)]?.role { return id } else { return nil }
    }

    var windowCount: Int { windows.count }

    // MARK: Windows

    /// A browser window. The first one with none open goes where the saved
    /// session's key window was (or the last closed one); New Window cascades.
    /// `saved` places it explicitly, with its ReArc space and macOS desktop;
    /// `below` orders it in behind that window instead of making it key.
    @MainActor
    @discardableResult
    func openBrowserWindow(restoring saved: SavedBrowserWindow? = nil, below: NSWindow? = nil) -> NSWindow? {
        guard let model, !terminating else { return nil }
        let first = browserWindowCount == 0
        let saved = saved ?? (first ? firstWindowPlacement() : nil)
        let windowID = SidebarWindowID()
        let spaceID = saved.flatMap { model.store.restoredSpaceID(saved: $0.spaceID, profileID: $0.profileID) }
        // Registered before the view exists, so its first frame shows its own space.
        if let spaceID { model.store.registerWindow(windowID, spaceID: spaceID) }
        let hosting = NSHostingView(rootView: BrowserView(model: model, windowID: windowID, initialSpaceID: spaceID))
        // The window's limits are fixed: with the default sizing options every
        // SwiftUI update measured the whole tree for its minimum size, the
        // Library's rows included (~40 ms per update at 39,413 downloads).
        hosting.sizingOptions = []
        let window = makeWindow(size: NSSize(width: 1280, height: 820), title: "ReArc", content: hosting)
        window.contentMinSize = BrowserView.minimumSize
        if let saved {
            // Placed before the first order-in: the early window goes up where it was, with no jump.
            window.applySavedPlacement(saved)
        } else if first {
            window.center()
        } else {
            cascade(window, offset: 0)
        }
        track(window, .browser(windowID))
        if let below {
            window.order(.below, relativeTo: below.windowNumber)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        if let saved { window.traceRestoredOrder(saved, below: below) }
        sessionRecorderIfNeeded()?.observe(window)
        if saved?.isFullScreen == true { restoreFullScreen(window) }
        if first {
            PerfSignposts.launchEvent("WindowOrderedFront")
            // Commit the cached chrome before services create any page engines.
            // Either ABI ready has run (named profiles/pages may still be cold),
            // or this is the early window and Chromium is still starting.
            window.displayIfNeeded()
            CATransaction.flush()
            LaunchTimeline.cachedChromeCommitted = ProcessInfo.processInfo.systemUptime
            PerfSignposts.launchEvent("CachedChromeCommitted")
            if awaitingReady {
                // The probe's display link needs the main run loop, which Chromium holds until ready.
                if PresentationProbe.shared.isEnabled, let committed = LaunchTimeline.cachedChromeCommitted {
                    LaunchTimeline.earlyFrameClock.start(after: committed, screen: window.screen ?? NSScreen.main)
                }
            } else {
                DispatchQueue.main.async { [weak model] in model?.finishStartup() }
            }
        }
        return window
    }

    /// A private window (`BrowserViewModel.openPrivateWindow`): one page whose
    /// engine is on the session's off-the-record profile.
    func presentPrivateWindow(_ privateWindow: PrivateWindowModel) {
        MainActor.assumeIsolated {
            guard let model, !terminating else { return }
            let window = makeWindow(
                size: NSSize(width: 1100, height: 760),
                title: "Private Window",
                content: NSHostingView(rootView: PrivateWindowView(model: model, window: privateWindow))
            )
            // PrivateWindowView has its own header below a standard title bar.
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            cascade(window, offset: 30)
            track(window, .privateBrowsing(privateWindow))
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func closePrivateWindows(parent: Profile.ID) {
        for entry in windows.values {
            if case .privateBrowsing(let privateWindow) = entry.role, privateWindow.parentProfileID == parent {
                closeWindow(entry.window)
            }
        }
    }

    private func cascade(_ window: NSWindow, offset: CGFloat) {
        if let key = NSApp.keyWindow {
            // The new window's own cascade, not the key window's: cascadeTopLeft
            // moves its receiver, so `key.cascadeTopLeft` shifted the browser
            // window under every new Little Arc.
            let from = NSPoint(x: key.frame.minX + offset, y: key.frame.maxY - offset)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: from))
        } else {
            window.center()
        }
    }

    func presentLittleArcWindow(_ id: LittleArcWindow.ID) {
        MainActor.assumeIsolated {
            if let existing = window(forLittleArc: id) {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            guard let model, !terminating else { return }
            let window: NSWindow
            if let prepared = preparedLittleArcWindow,
               let host = prepared.contentView as? NSHostingView<AnyView> {
                preparedLittleArcWindow = nil
                host.rootView = AnyView(LittleArcWindowView(model: model, windowID: id).id(id))
                window = prepared
                window.isExcludedFromWindowsMenu = false
            } else {
                window = makeWindow(
                    size: NSSize(width: 520, height: 420), title: "Little Arc",
                    content: NSHostingView(rootView: LittleArcWindowView(model: model, windowID: id))
                )
            }
            cascade(window, offset: 40)
            track(window, .littleArc(id))
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in self?.prepareLittleArcWindow() }
        }
    }

    @MainActor
    func presentAirTrafficControl() {
        guard let model, !terminating else { return }
        if let window = airTrafficControlWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Air Traffic Control"
        window.contentView = NSHostingView(rootView: AirTrafficControlView(model: model))
        window.center()
        airTrafficControlWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// ReArc › About ReArc. Its links open in a new tab of the frontmost browser window.
    @MainActor
    func presentAbout() {
        guard let model, !terminating else { return }
        if aboutWindow == nil {
            aboutWindow = AboutWindowController { [weak self] url in
                if BrowserInternalPage.credits.isShown(by: url) {
                    if BrowserInternalPage.credits.isAvailable(engine: model.engineHost.navigationSchemes) {
                        model.openBrowserPage(.credits)
                    } else {
                        model.openInNewTab(URL(string: "https://github.com/judioo/rearc")!)
                    }
                } else {
                    model.openInNewTab(url)
                }
                self?.browserWindows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
            }
        }
        aboutWindow?.present()
    }

    @MainActor
    func presentSettings(_ pane: SettingsPane?) {
        guard let model, !terminating else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model) { [weak self] in self?.settingsCapabilities() ?? SettingsCapabilities() }
        }
        settingsWindow?.show(pane)
    }

    /// The Settings window (the self-test walks it).
    var settingsWindowForTesting: NSWindow? { settingsWindow?.window }

    /// Rows the engine backs: automatic PiP and Chrome's password leak check.
    func settingsCapabilities() -> SettingsCapabilities {
        let runtime = runtime
        return SettingsCapabilities(
            pictureInPicture: runtime.capabilities.pictureInPicture,
            passwordLeakCheck: runtime.capabilities.passwordLeakDetection ? Binding(
                get: { runtime.leakDetectionEnabled },
                set: { runtime.setLeakDetectionForAllProfiles($0) }
            ) : nil
        )
    }

    func presentDevToolsWindow(for tabID: Tab.ID) {
        MainActor.assumeIsolated {
            if let existing = window(forDevTools: tabID) {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            guard let model, !terminating else { return }
            let title = model.store.tab(withID: tabID).map { "Developer Tools – \($0.displayTitle)" } ?? "Developer Tools"
            let window = makeWindow(
                size: NSSize(width: 900, height: 620),
                title: title,
                content: NSHostingView(rootView: DevToolsWindowView(model: model, tabID: tabID))
            )
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            cascade(window, offset: 30)
            track(window, .devTools(tabID))
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismissDevToolsWindow(for tabID: Tab.ID) {
        guard let window = window(forDevTools: tabID) else { return }
        // Docking back: the window goes without closing the frontend.
        windows[ObjectIdentifier(window)] = nil
        closeWindow(window)
    }

    func window(forDevTools tabID: Tab.ID) -> NSWindow? {
        windows.values.first { if case .devTools(tabID) = $0.role { return true } else { return false } }?.window
    }

    func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {
        window(forLittleArc: id).map(closeWindow)
    }

    func focusBrowserWindow(_ id: SidebarWindowID) {
        let match = windows.values.first { if case .browser(id) = $0.role { return true } else { return false } }
        guard let window = match?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func window(forLittleArc id: LittleArcWindow.ID) -> NSWindow? {
        windows.values.first { if case .littleArc(id) = $0.role { return true } else { return false } }?.window
    }

    /// Programmatic close: detach first, then close (no shouldClose round trip).
    func closeWindow(_ window: NSWindow) {
        ChromiumHostView.dismantleAll(in: window)
        window.close()
    }

    private func makeWindow(size: NSSize, title: String, content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = title
        window.tabbingMode = .disallowed
        window.contentView = content
        window.delegate = self
        return window
    }

    private func track(_ window: NSWindow, _ role: WindowRole) {
        windows[ObjectIdentifier(window)] = (window, role)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Detach before the close begins, ahead of the engine's own will-close observer.
        ChromiumHostView.dismantleAll(in: sender)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows[ObjectIdentifier(window)] else { return }
        if case .browser(let windowID) = entry.role, !terminating {
            MainActor.assumeIsolated {
                lastClosedBrowserWindow = sessionRecorder?.record(window, isKey: false, space: model?.store.focusedSpace(in: windowID))
            }
        }
        windows[ObjectIdentifier(window)] = nil
        MainActor.assumeIsolated {
            sessionRecorder?.forget(window)
            if !terminating { sessionRecorder?.changed() }
        }
        ChromiumHostView.dismantleAll(in: window)
        // Quitting keeps Little Arc records for restore, and engine shutdown owns
        // every profile; a user close archives the record or ends the private session.
        guard !terminating else { return }
        if case .privateBrowsing(let privateWindow) = entry.role {
            model?.privateWindowClosed(privateWindow.id)
        }
        if case .devTools(let tabID) = entry.role {
            model?.devToolsWindowClosed(for: tabID)
        }
        DispatchQueue.main.async {
            // Tears down the SwiftUI hierarchy (onDisappear runs, engines drop).
            window.contentView = nil
        }
    }

    // MARK: Window session (docs/WINDOW-RESTORE.md)

    @MainActor
    private func sessionRecorderIfNeeded() -> WindowSessionRecorder? {
        guard let sessionFileURL else { return nil }
        if let sessionRecorder { return sessionRecorder }
        let recorder = WindowSessionRecorder(fileURL: sessionFileURL) { [weak self] in
            MainActor.assumeIsolated {
                // Until the launch's other windows are open, a save would drop them.
                guard let self, self.launchSession == nil else { return nil }
                return self.windowSession()
            }
        }
        sessionRecorder = recorder
        return recorder
    }

    /// The saved session, read once per launch: the window file, else the
    /// frame AppKit autosaved before it existed.
    @MainActor
    private func loadLaunchSession() -> WindowSessionSnapshot? {
        guard !launchSessionLoaded else { return launchSession }
        launchSessionLoaded = true
        guard let sessionFileURL else { return nil }
        if let saved = WindowSessionFile.load(from: sessionFileURL) {
            launchSession = saved
        } else if sessionFileURL == WindowSessionFile.defaultFileURL,
                  let string = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.mainWindowFrameName)"),
                  let legacy = SavedBrowserWindow(appKitFrameString: string) {
            launchSession = WindowSessionSnapshot(windows: [legacy])
        }
        if model?.restoresWindows == false { launchSession = launchSession?.launchWindowOnly }
        return launchSession
    }

    /// Where the first window with none open goes: at launch the session's key
    /// window, later the one closed last.
    @MainActor
    private func firstWindowPlacement() -> SavedBrowserWindow? {
        if !launchSessionLoaded { return loadLaunchSession()?.launchWindow }
        return lastClosedBrowserWindow
    }

    /// At ready: the other saved windows, each behind the one before it, so the
    /// launch window stays key and the z-order comes back.
    @MainActor
    private func restoreOtherSessionWindows() {
        guard let session = launchSession, !terminating else { return }
        launchSession = nil
        var above = browserWindows.first
        for saved in session.otherWindows {
            guard let window = openBrowserWindow(restoring: saved, below: above) else { break }
            above = window
        }
    }

    /// Re-enters full screen once the window is up, unless AppKit's restored
    /// state already did.
    @MainActor
    private func restoreFullScreen(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, window.isVisible, !self.terminating,
                      !window.styleMask.contains(.fullScreen),
                      self.sessionRecorder?.transitioning.contains(ObjectIdentifier(window)) != true else { return }
                window.toggleFullScreen(nil)
            }
        }
    }

    /// The browser windows now, front to back; the key one is the store's key window.
    @MainActor
    func windowSession() -> WindowSessionSnapshot {
        let order = NSApp.orderedWindows.enumerated().reduce(into: [ObjectIdentifier: Int]()) { $0[ObjectIdentifier($1.element)] = $1.offset }
        let entries = windows.values.compactMap { entry -> (NSWindow, SidebarWindowID)? in
            if case .browser(let id) = entry.role { return (entry.window, id) } else { return nil }
        }.sorted { (order[ObjectIdentifier($0.0)] ?? .max) < (order[ObjectIdentifier($1.0)] ?? .max) }
        let keyID = model?.store.keyWindowID
        let hasKey = entries.contains { $0.1 == keyID }
        let saved = entries.enumerated().compactMap { index, entry in
            sessionRecorder?.record(entry.0, isKey: hasKey ? entry.1 == keyID : index == 0,
                                    space: model?.store.focusedSpace(in: entry.1))
        }
        return WindowSessionSnapshot(windows: saved, lastClosed: lastClosedBrowserWindow)
    }

    /// Writes the session now (quit, and the self-test's save path).
    @MainActor
    func saveWindowSession() {
        sessionRecorderIfNeeded()?.saveNow()
    }

    @MainActor
    private func finishWindowSession() {
        guard !terminating else { return }
        sessionRecorder?.finish()
        sessionRecorder = nil
    }

    /// The self-test's restore path: opens every window of the saved session as
    /// a launch would (key window first and key, the rest behind it).
    @MainActor
    @discardableResult
    func restoreWindowSession() -> [NSWindow] {
        launchSessionLoaded = false
        launchSession = nil
        guard let session = loadLaunchSession(), let launch = session.launchWindow,
              let first = openBrowserWindow(restoring: launch) else { return [] }
        var opened = [first]
        for saved in session.otherWindows {
            guard let window = openBrowserWindow(restoring: saved, below: opened.last) else { break }
            opened.append(window)
        }
        launchSession = nil
        return opened
    }

    // MARK: HTML fullscreen (ABI 1.27)

    /// The page's window goes native fullscreen with its chrome hidden, and
    /// comes back as it was when the page leaves (Esc, page, navigation).
    @MainActor
    private func handleFullscreen(_ event: ChromiumFullscreenEvent) {
        guard let model, let engine = runtime.engine(forTab: event.tabID) else { return }
        if event.entered {
            guard let window = engine.leaseHolder?.window ?? NSApp.keyWindow else { return }
            if let previous = fullscreenWindow, previous !== window { return }
            let tabID = engine.role == .tab ? engine.shellID : nil
            let steps = model.pageEnteredFullscreen(
                tabID: tabID,
                engineTabID: event.tabID,
                windowIsFullscreen: window.styleMask.contains(.fullScreen) && wantsNativeFullscreen == nil
            )
            fullscreenWindow = window
            apply(steps, window: window, engine: engine)
        } else if let window = fullscreenWindow {
            apply(model.pageExitedFullscreen(engineTabID: event.tabID), window: window, engine: engine)
            if wantsNativeFullscreen == nil, model.htmlFullscreen == nil { fullscreenWindow = nil }
        }
    }

    @MainActor
    private func apply(_ steps: [HTMLFullscreenSession.Step], window: NSWindow, engine: ChromiumEngine) {
        for step in steps {
            switch step {
            case .enterNativeFullscreen:
                wantsNativeFullscreen = true
                reconcileNativeFullscreen(window)
            case .exitNativeFullscreen:
                wantsNativeFullscreen = false
                reconcileNativeFullscreen(window)
            case .exitPageFullscreen:
                engine.exitPageFullscreen()
            case .hideChrome, .restoreChrome:
                // BrowserView follows BrowserViewModel.htmlFullscreen.
                break
            }
        }
    }

    /// AppKit ignores a toggle during a fullscreen transition, so the shell
    /// keeps the state it wants and toggles once the window is settled.
    private func reconcileNativeFullscreen(_ window: NSWindow) {
        ChromiumLog.trace("native fullscreen: wants \(wantsNativeFullscreen.map { "\($0)" } ?? "-") "
            + "is \(window.styleMask.contains(.fullScreen)) transitioning \(fullscreenTransitioning)")
        guard !fullscreenTransitioning, let wants = wantsNativeFullscreen else { return }
        if window.styleMask.contains(.fullScreen) != wants {
            fullscreenTransitioning = true
            window.toggleFullScreen(nil)
        } else if !wants {
            // Back where the page found the window.
            wantsNativeFullscreen = nil
            if model?.htmlFullscreen == nil { fullscreenWindow = nil }
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        ChromiumLog.trace("window will enter fullscreen (tracked \((notification.object as? NSWindow) === fullscreenWindow))")
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else { return }
        fullscreenTransitioning = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        ChromiumLog.trace("window will exit fullscreen (tracked \((notification.object as? NSWindow) === fullscreenWindow))")
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else { return }
        // Not the shell's own toggle: the user is leaving (green button, ⌃⌘F).
        if !fullscreenTransitioning, MainActor.assumeIsolated({ model?.htmlFullscreen != nil }) { userLeavingFullscreen = true }
        fullscreenTransitioning = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenTransitionEnded(notification)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        ChromiumLog.info("window failed to enter fullscreen")
        guard window === fullscreenWindow else { return }
        fullscreenTransitioning = false
        wantsNativeFullscreen = nil
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransitionEnded(notification)
    }

    private func fullscreenTransitionEnded(_ notification: Notification) {
        ChromiumLog.trace("window fullscreen transition ended: \(notification.name.rawValue) "
            + "(tracked \((notification.object as? NSWindow) === fullscreenWindow))")
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else { return }
        fullscreenTransitioning = false
        MainActor.assumeIsolated {
            if userLeavingFullscreen {
                userLeavingFullscreen = false
                wantsNativeFullscreen = nil
                if let model, let session = model.htmlFullscreen, let engine = runtime.engine(forTab: session.engineTabID) {
                    apply(model.windowExitedFullscreen(), window: window, engine: engine)
                }
                fullscreenWindow = nil
                return
            }
        }
        // A toggle from inside the transition's own notification is dropped.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.fullscreenWindow else { return }
            self.reconcileNativeFullscreen(window)
        }
    }

    /// The window holding the HTML-fullscreen page, if any (self-test).
    var htmlFullscreenWindow: NSWindow? { fullscreenWindow }
    /// No fullscreen transition is running for that window (self-test).
    var isNativeFullscreenSettled: Bool { !fullscreenTransitioning }

    // MARK: Adopted (Chromium-created) tabs

    /// Popups and target=_blank contents stay in the opener's BrowserContext:
    /// a private opener's popup becomes another private window of the same
    /// session; anything else becomes a today tab in the active space.
    @MainActor
    private func adopt(_ event: ChromiumTabEvent) -> Bool {
        guard let model, !terminating else { return false }
        let key = runtime.profileKey(forEngineProfile: event.profileID)
        if runtime.capabilities.profiles, key == nil, event.profileID != runtime.defaultProfileID {
            // A profile that is closing (or unknown): relabeling the contents would mix storage.
            ChromiumLog.info("not adopting tab \(event.tabID): engine profile \(event.profileID) is not open")
            return false
        }
        if let key, case .offTheRecord(let session, let parent) = key {
            let url = event.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
            let engine = ChromiumEngine(
                runtime: runtime,
                adopting: event,
                initialURL: url,
                context: EngineProfileContext(profileID: parent, isEphemeral: true),
                profileKey: key,
                shellID: UUID()
            )
            model.openPrivateWindow(session: session, parentProfileID: parent, engine: engine)
            return true
        }
        return model.adoptChromiumTab(event, profileKey: key)
    }

    // MARK: Menus

    /// The engine installs an empty placeholder menu; the shell owns menu construction.
    @MainActor
    private func makeMainMenu(model: BrowserViewModel) -> NSMenu {
        let main = NSMenu(title: "ReArc")
        let target = menuTarget

        let app = NSMenu(title: "ReArc")
        // Arc's order: About, then Settings.
        app.addItem(target.item("About ReArc", "") { [weak self] in self?.presentAbout() })
        if let updates = AppUpdater.shared.makeMenuItem() { app.addItem(updates) }
        app.addItem(.separator())
        // ReArc's own window; Chromium's settings pages open from its buttons.
        app.addItem(target.item("Settings…", ",") { model.showSettings() })
        if runtime.capabilities.navigationExtended {
            app.addItem(target.item("Clear Browsing Data…", "\u{8}", [.command, .shift]) {
                model.openBrowserPage(.clearBrowsingData)
            })
            app.addItem(target.item("About Chromium Engine", "") { model.openBrowserPage(.version) })
            app.addItem(.separator())
        }
        app.addItem(target.item("Set ReArc as Default Browser…", "") { model.setAsDefaultBrowser() })
        // Picture in Picture, password leak checks, external links and the
        // Little Arc hotkey moved to Settings (wave 35).
        app.addItem(target.item("Air Traffic Control…", "") { [weak self] in self?.presentAirTrafficControl() })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ReArc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        // NSApp.terminate is routed to terminate_requested -> ReArcEngineShutdown.
        // Only ⌘Q asks (Warn before quitting); the Dock's Quit and logout do not.
        app.addItem(target.item("Quit ReArc", "q") { [weak self] in
            let open = self?.browserWindows.filter(\.isVisible).count ?? 0
            if MainActor.assumeIsolated({ model.confirmQuit(browserWindows: open) }) { NSApp.terminate(nil) }
        })
        main.addSubmenu(app, title: "ReArc")

        let file = NSMenu(title: "File")
        file.addItem(target.item("New Tab", "t") { model.newTab() })
        file.addItem(target.item("New Window", "n") { [weak self] in self?.openBrowserWindow() })
        // Arc's Blank Window (⌃⌘N): a ReArc window always shows a space, so it is a new window.
        file.addItem(target.item("New Blank Window", "n", [.command, .control]) { [weak self] in self?.openBrowserWindow() })
        file.addItem(target.item("New Little Arc Window", "n", [.command, .option]) { model.openBlankLittleArc() })
        if runtime.capabilities.profileOffTheRecord {
            file.addItem(target.item("New Private Window", "n", [.command, .shift]) {
                model.openPrivateWindow()
            })
        }
        file.addItem(target.item("Reopen Closed Tab", "t", [.command, .shift]) { model.reopenClosedTab() })
        file.addItem(target.item("Open Command Bar", "l") { model.focusLocation() })
        file.addItem(.separator())
        target.add(ShellMenus.documents(model), to: file)
        file.addItem(.separator())
        file.addItem(target.item("Close Window", "w", [.command, .shift]) { [weak self] in
            if let window = NSApp.keyWindow { self?.closeWindow(window) }
        })
        file.addItem(.separator())
        target.add(ShellMenus.importing(model, chromiumImporter: runtime.capabilities.navigationExtended), to: file)
        // snapshot_viewport and snapshot_full_page are ABI 1.0 features.
        file.addItem(.separator())
        target.add(ShellMenus.capture(model), to: file)
        if runtime.capabilities.printing {
            file.addItem(.separator())
            target.add(ShellMenus.printing(model), to: file)
        }
        main.addSubmenu(file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // Chrome's selector, which RenderWidgetHostViewCocoa answers (Arc: ⇧⌘V).
        edit.addItem(withTitle: "Paste and Match Style", action: Selector(("pasteAndMatchStyle:")), keyEquivalent: "V")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        target.add(ShellMenus.copyLink(model), to: edit)
        if runtime.capabilities.findInPage {
            edit.addItem(.separator())
            target.add(ShellMenus.find(model), to: edit)
        }
        edit.addItem(.separator())
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        edit.addSubmenu(spelling, title: "Spelling and Grammar")
        main.addSubmenu(edit, title: "Edit")

        let view = NSMenu(title: "View")
        // Arc's title flips with the sidebar.
        target.add([[ShellMenuItem("Hide Sidebar", "s", liveTitle: { model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar" }) {
            model.toggleSidebar()
        }]], to: view)
        view.addItem(.separator())
        target.add(ShellMenus.navigation(model), to: view)
        if runtime.capabilities.downloads {
            view.addItem(.separator())
            target.add(ShellMenus.downloads(model), to: view)
        }
        view.addItem(.separator())
        target.add(ShellMenus.library(model), to: view)
        if runtime.capabilities.pictureInPicture {
            view.addItem(.separator())
            target.add(ShellMenus.pictureInPicture(model), to: view)
        }
        if runtime.capabilities.pageZoom {
            view.addItem(.separator())
            target.add(ShellMenus.zoom(model), to: view)
        }
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        if runtime.capabilities.navigationExtended {
            view.addItem(.separator())
            view.addItem(target.item("View Page Source", "u", [.command, .option]) { model.viewSelectedPageSource() })
        }
        if runtime.capabilities.devTools {
            let developer = NSMenu(title: "Developer")
            target.add(ShellMenus.developer(model), to: developer)
            view.addSubmenu(developer, title: "Developer")
        }
        if runtime.capabilities.webUIDailyPages {
            view.addItem(.separator())
            target.add(ShellMenus.browserPages(model), to: view)
            if runtime.capabilities.extensionToolbar {
                view.addItem(target.item("Chrome Web Store", "") { model.openChromeWebStore() })
            }
        }
        main.addSubmenu(view, title: "View")

        let tabs = NSMenu(title: "Tabs")
        let close = target.item("Close Tab", "w") { [weak self] in
            // A private or Little Arc window has one page: Cmd+W closes the window.
            if let window = NSApp.keyWindow, let entry = self?.windows[ObjectIdentifier(window)] {
                if case .browser = entry.role {} else { return self?.closeWindow(window) ?? () }
            }
            // Settings and Air Traffic Control: Cmd+W closes them, never a tab behind them.
            if let window = NSApp.keyWindow, window === self?.settingsWindow?.window || window === self?.airTrafficControlWindow {
                return window.performClose(nil)
            }
            model.closeSelectedTab()
        }
        // Named for what it does to the selected tab ("Archive Tab" in Today).
        target.setLiveTitle(of: close) { [weak self] in
            if let window = NSApp.keyWindow, let entry = self?.windows[ObjectIdentifier(window)] {
                if case .browser = entry.role {} else { return "Close Tab" }
            }
            return model.closeTabMenuTitle
        }
        tabs.addItem(close)
        tabs.addItem(.separator())
        target.add(ShellMenus.tabNavigation(model), to: tabs)
        target.add(ShellMenus.tabSwitcher(model), to: tabs)
        tabs.addItem(.separator())
        target.add(ShellMenus.split(model), to: tabs)
        tabs.addItem(.separator())
        target.add(ShellMenus.tabPositions(model), to: tabs)
        tabs.addItem(.separator())
        target.add(ShellMenus.sidebarItems(model), to: tabs)
        main.addSubmenu(tabs, title: "Tabs")

        let spaces = NSMenu(title: "Spaces")
        target.add(ShellMenus.spaces(model), to: spaces)
        main.addSubmenu(spaces, title: "Spaces")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(.separator())
        target.add(ShellMenus.littleArcs(model), to: windowMenu)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addSubmenu(windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(target.item("Watch the Sunrise Again", "") { [weak self] in
            MainActor.assumeIsolated { self?.runOnboarding(.replay) }
        })
        main.addSubmenu(help, title: "Help")
        NSApp.helpMenu = help
        return main
    }
}

final class ChromiumMenuTarget: NSObject, NSMenuItemValidation {
    private var actions: [Int: () -> Void] = [:]
    /// Checkmark state, read each time the menu opens.
    private var checks: [Int: () -> Bool] = [:]
    /// Live titles (`ShellMenuItem.liveTitle`); nil hides the item.
    private var titles: [Int: () -> String?] = [:]

    func checkItem(_ title: String, isOn: @escaping () -> Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = item(title, "", [], action: action)
        checks[item.tag] = isOn
        return item
    }

    /// A title read each time the menu opens; it never hides the item.
    func setLiveTitle(of item: NSMenuItem, _ title: @escaping () -> String) {
        titles[item.tag] = title
        item.title = title()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let isOn = checks[menuItem.tag] { menuItem.state = isOn() ? .on : .off }
        if let title = titles[menuItem.tag] {
            let current = title()
            menuItem.isHidden = current == nil
            if let current { menuItem.title = current }
            return current != nil
        }
        return true
    }

    func item(
        _ title: String,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let equivalent = ShellMenuItem.appKitKeyEquivalent(key, modifiers)
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: equivalent.key)
        item.keyEquivalentModifierMask = equivalent.mask
        item.target = self
        item.tag = actions.count + 1
        actions[item.tag] = action
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }

    /// Appends shared menu groups (`ShellMenus`) with separators between them.
    func add(_ groups: [[ShellMenuItem]], to menu: NSMenu) {
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in group {
                let menuItem = item(entry.title, entry.menuKeyEquivalent, entry.modifiers, action: entry.action)
                // Arc's alternates (⌘← Back, F12): hidden, their keys still work.
                menuItem.isHidden = entry.isAlternate
                menuItem.allowsKeyEquivalentWhenHidden = entry.isAlternate
                if let live = entry.liveTitle {
                    titles[menuItem.tag] = live
                    menuItem.title = live() ?? entry.title
                    menuItem.isHidden = live() == nil
                    // A space made later still has ⌃n before the menu next opens;
                    // validation disables an item with nothing behind it.
                    menuItem.allowsKeyEquivalentWhenHidden = true
                }
                menu.addItem(menuItem)
            }
        }
    }
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension BrowserViewModel {
    /// Chromium-created contents (popup, target=_blank) from a persistent
    /// profile become a today tab in the active space; popups open as tabs,
    /// never as native windows.
    func adoptChromiumTab(_ event: ChromiumTabEvent, profileKey: ChromiumProfileKey?) -> Bool {
        let blank = URL(string: "about:blank")!
        let url = event.url.flatMap(URL.init(string:)).flatMap { $0.absoluteString.isEmpty ? nil : $0 } ?? blank
        // ⌥⌘-click: Chromium makes a background tab (as for ⌘-click); the keys
        // held at that click send it to Little Arc instead, in the opener's profile.
        if event.disposition == 1 || event.disposition == 2, takeLittleArcClick() {
            return adoptChromiumLittleArc(event, profileKey: profileKey, url: url)
        }
        let tab = store.addTab(kind: .today, title: event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New Tab", url: url)
        let profileID = profileID(for: tab)
        // The contents already live in the opener's BrowserContext; keep it.
        let engine = ChromiumEngine(
            runtime: ChromiumRuntime.shared,
            adopting: event,
            initialURL: url,
            context: EngineProfileContext(profileID: profileID),
            profileKey: profileKey ?? .persistent(profileID),
            shellID: tab.id
        )
        engine.onNavigationCommit = { [weak self] url, title in
            self?.handleTabNavigationCommit(tabID: tab.id, url: url, title: title)
        }
        engineHost.adopt(engine, for: tab, profileID: profileID)
        observeFavicon(of: engine, tabID: tab.id)
        // Background-tab disposition stays unselected; the rest take focus in the sidebar.
        if event.disposition != 2 {
            selectTab(tab.id)
        }
        return true
    }

    /// The contents keep their BrowserContext, so the Little Arc takes the opener's profile.
    func adoptChromiumLittleArc(_ event: ChromiumTabEvent, profileKey: ChromiumProfileKey?, url: URL) -> Bool {
        var profileID = store.activeProfileID
        if case .persistent(let owner) = profileKey { profileID = owner }
        let record = store.createLittleArcWindow(url: url, title: event.title.flatMap { $0.isEmpty ? nil : $0 }, profileID: profileID)
        let engine = ChromiumEngine(
            runtime: ChromiumRuntime.shared,
            adopting: event,
            initialURL: url,
            context: EngineProfileContext(profileID: profileID),
            profileKey: profileKey ?? .persistent(profileID),
            shellID: record.id,
            role: .littleArc
        )
        engineHost.adoptLittleArc(engine, id: record.id, profileID: profileID)
        requestLittleArcWindow(record.id)
        loadLittleArcIfNeeded(record.id)
        littleArcAdoptions += 1
        return true
    }
}
#endif
