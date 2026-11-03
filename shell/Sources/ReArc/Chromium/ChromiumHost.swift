#if REARC_CHROMIUM
import AppKit
import Foundation
import SidebarModel
import SwiftUI

/// Chromium-path process lifecycle (engine/docs/C-ABI.md "Linking and startup"):
/// configure before NSApplication exists, block in ReArcEngineRun on main,
/// build shell windows in `ready`, and exit with Run's result after shutdown.
enum ChromiumHost {
    /// Returns only when Chromium is unavailable (caller falls back to WebKit).
    @MainActor
    static func launch(_ options: EngineLaunchOptions) {
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
                defaultUserDataDir: { defaultUserDataDir(selfTest: options.selfTest).path },
                keychain: keychain
            )
            let runtime = ChromiumRuntime.shared
            if options.selfTest {
                let test = ChromiumSelfTest(runtime: runtime)
                runtime.onReady = { test.start() }
                let code = runtime.run(arguments: arguments, keychain: keychain)
                exit(test.exitCode(runResult: code))
            }
            let shell = ChromiumShell(runtime: runtime)
            runtime.onReady = { shell.start() }
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
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ReArc/Chromium", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        case browser
        case littleArc(LittleArcWindow.ID)
        case privateBrowsing(PrivateWindowModel)
    }

    private let runtime: ChromiumRuntime
    private var model: BrowserViewModel?
    private var windows: [ObjectIdentifier: (window: NSWindow, role: WindowRole)] = [:]
    private var terminating = false
    private let menuTarget = ChromiumMenuTarget()
    /// The self-test runs this shell on a throwaway sidebar and must not move
    /// the user's saved window frame.
    private let autosavesFrames: Bool

    init(runtime: ChromiumRuntime, autosavesFrames: Bool = true) {
        self.runtime = runtime
        self.autosavesFrames = autosavesFrames
    }

    @MainActor
    func start(model: BrowserViewModel = BrowserViewModel()) {
        NSApp.setActivationPolicy(.regular)
        self.model = model
        model.windowPresenter = self
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
        runtime.onTerminateRequested = { [weak self, weak model] in
            self?.terminating = true
            model?.prepareForQuit()
        }
        NSApp.mainMenu = makeMainMenu(model: model)
        openBrowserWindow()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock click / app switch with no windows left: reopen a browser window.
    @MainActor
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        reopenIfNoWindows()
    }

    @MainActor
    func reopenIfNoWindows() {
        guard !terminating, !windows.values.contains(where: { $0.window.isVisible }) else { return }
        openBrowserWindow()
    }

    var browserWindows: [NSWindow] {
        windows.values.compactMap { if case .browser = $0.role { return $0.window } else { return nil } }
    }

    var browserWindowCount: Int { browserWindows.count }

    var windowCount: Int { windows.count }

    // MARK: Windows

    @MainActor
    @discardableResult
    func openBrowserWindow() -> NSWindow? {
        guard let model, !terminating else { return nil }
        let first = browserWindowCount == 0
        let window = makeWindow(
            size: NSSize(width: 1280, height: 820),
            title: "ReArc",
            content: NSHostingView(rootView: BrowserView(model: model))
        )
        if first, autosavesFrames {
            window.setFrameAutosaveName("ReArcChromiumMainWindow")
            if !window.setFrameUsingName("ReArcChromiumMainWindow") { window.center() }
        } else {
            cascade(window, offset: 0)
        }
        track(window, .browser)
        window.makeKeyAndOrderFront(nil)
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
            window.setFrameTopLeftPoint(key.cascadeTopLeft(from: NSPoint(x: key.frame.minX + offset, y: key.frame.maxY - offset)))
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
            let window = makeWindow(
                size: NSSize(width: 520, height: 420),
                title: "Little Arc",
                content: NSHostingView(rootView: LittleArcWindowView(model: model, windowID: id))
            )
            cascade(window, offset: 40)
            track(window, .littleArc(id))
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {
        window(forLittleArc: id).map(closeWindow)
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
              let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        ChromiumHostView.dismantleAll(in: window)
        // Quitting keeps Little Arc records for restore, and engine shutdown owns
        // every profile; a user close archives the record or ends the private session.
        guard !terminating else { return }
        if case .privateBrowsing(let privateWindow) = entry.role {
            model?.privateWindowClosed(privateWindow.id)
        }
        DispatchQueue.main.async {
            // Tears down the SwiftUI hierarchy (onDisappear runs, engines drop).
            window.contentView = nil
        }
    }

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
        // Chromium owns settings (chrome://settings WebUI); the shell does not duplicate them.
        if runtime.capabilities.navigationExtended {
            app.addItem(target.item("Settings…", ",") { model.openBrowserPage(.settings) })
            app.addItem(target.item("Clear Browsing Data…", "\u{8}", [.command, .shift]) {
                model.openBrowserPage(.clearBrowsingData)
            })
            app.addItem(target.item("About Chromium Engine", "") { model.openBrowserPage(.version) })
            app.addItem(.separator())
        }
        app.addItem(withTitle: "Hide ReArc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        // NSApp.terminate is routed to terminate_requested -> ReArcEngineShutdown.
        app.addItem(withTitle: "Quit ReArc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addSubmenu(app, title: "ReArc")

        let file = NSMenu(title: "File")
        file.addItem(target.item("New Tab", "t") { model.newTab() })
        file.addItem(target.item("New Window", "n") { [weak self] in self?.openBrowserWindow() })
        if runtime.capabilities.profileOffTheRecord {
            file.addItem(target.item("New Private Window", "n", [.command, .shift]) {
                model.openPrivateWindow()
            })
        }
        file.addItem(target.item("Reopen Closed Tab", "t", [.command, .shift]) { model.reopenClosedTab() })
        file.addItem(.separator())
        file.addItem(target.item("Close Window", "w", [.command, .shift]) { [weak self] in
            if let window = NSApp.keyWindow { self?.closeWindow(window) }
        })
        main.addSubmenu(file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addSubmenu(edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(target.item("Toggle Sidebar", "s") { model.toggleSidebar() })
        view.addItem(.separator())
        target.add(ShellMenus.navigation(model), to: view)
        if runtime.capabilities.pageZoom {
            view.addItem(.separator())
            view.addItem(target.item("Zoom In", "=") { model.zoom(.zoomIn) })
            view.addItem(target.item("Zoom Out", "-") { model.zoom(.zoomOut) })
            view.addItem(target.item("Actual Size", "0") { model.zoom(.reset) })
        }
        if runtime.capabilities.navigationExtended {
            view.addItem(.separator())
            view.addItem(target.item("View Page Source", "u", [.command, .option]) { model.viewSelectedPageSource() })
        }
        main.addSubmenu(view, title: "View")

        let tabs = NSMenu(title: "Tabs")
        tabs.addItem(target.item("Focus Location", "l") { model.focusLocation() })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Close Tab", "w") { [weak self] in
            // A private or Little Arc window has one page: Cmd+W closes the window.
            if let window = NSApp.keyWindow, let entry = self?.windows[ObjectIdentifier(window)] {
                if case .browser = entry.role {} else { return self?.closeWindow(window) ?? () }
            }
            model.closeSelectedTab()
        })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Next Tab", "]", [.command, .shift]) { model.selectNextTab() })
        tabs.addItem(target.item("Previous Tab", "[", [.command, .shift]) { model.selectPreviousTab() })
        tabs.addItem(target.item("Select Next Tab", "\t", [.control]) { model.selectNextTab() })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Add Split View", "") { model.addSplitView(orientation: .horizontal) })
        tabs.addItem(target.item("Separate from Split View", "") {
            if let tab = model.store.selectedTab { model.unsplitTabIfInSplit(tab.id) }
        })
        tabs.addItem(.separator())
        target.add(ShellMenus.sidebarItems(model), to: tabs)
        main.addSubmenu(tabs, title: "Tabs")

        let spaces = NSMenu(title: "Spaces")
        target.add(ShellMenus.spaces(model), to: spaces)
        main.addSubmenu(spaces, title: "Spaces")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addSubmenu(windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu
        return main
    }
}

final class ChromiumMenuTarget: NSObject {
    private var actions: [Int: () -> Void] = [:]

    func item(
        _ title: String,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
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
                menu.addItem(item(entry.title, entry.menuKeyEquivalent, entry.modifiers, action: entry.action))
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
}
#endif
