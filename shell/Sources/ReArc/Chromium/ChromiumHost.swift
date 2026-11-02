#if REARC_CHROMIUM
import AppKit
import Foundation
import SidebarModel
import SwiftUI

/// Chromium-path process lifecycle (engine/docs/C-ABI.md "Linking and startup"):
/// configure before NSApplication exists, block in ReArcEngineRun on main,
/// build shell windows in `ready`, and exit with Run's result after shutdown.
enum ChromiumHost {
    static let userDataDirFlag = "--user-data-dir="

    /// Returns only when Chromium is unavailable (caller falls back to WebKit).
    @MainActor
    static func launch(_ options: EngineLaunchOptions) {
        guard let reason = unavailableReason() else {
            var arguments = CommandLine.arguments
            if !arguments.contains(where: { $0.hasPrefix(userDataDirFlag) }) {
                arguments.append(userDataDirFlag + defaultUserDataDir(selfTest: options.selfTest).path)
            }
            let runtime = ChromiumRuntime.shared
            if options.selfTest {
                let test = ChromiumSelfTest(runtime: runtime)
                runtime.onReady = { test.start() }
                let code = runtime.run(arguments: arguments)
                exit(test.exitCode(runResult: code))
            }
            let shell = ChromiumShell(runtime: runtime)
            runtime.onReady = { shell.start() }
            exit(runtime.run(arguments: arguments))
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

/// The normal Chromium-path UI: the same `BrowserView` in an AppKit-owned window.
final class ChromiumShell {
    private let runtime: ChromiumRuntime
    private var model: BrowserViewModel?
    private var window: NSWindow?
    private var windowObserver: NSObjectProtocol?
    private let menuTarget = ChromiumMenuTarget()

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
    }

    @MainActor
    func start() {
        NSApp.setActivationPolicy(.regular)
        let model = BrowserViewModel()
        self.model = model
        runtime.onAdoptedTab = { [weak model] event in
            model?.adoptChromiumTab(event) ?? false
        }
        runtime.onTerminateRequested = { [weak model] in
            model?.prepareForQuit()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "ReArc"
        window.contentView = NSHostingView(rootView: BrowserView(model: model))
        window.setFrameAutosaveName("ReArcChromiumMainWindow")
        if !window.setFrameUsingName("ReArcChromiumMainWindow") { window.center() }
        // There is one browser window; closing it quits through the engine's orderly shutdown.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        self.window = window

        NSApp.mainMenu = makeMainMenu(model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The engine installs an empty placeholder menu; the shell owns menu construction.
    @MainActor
    private func makeMainMenu(model: BrowserViewModel) -> NSMenu {
        let main = NSMenu(title: "ReArc")
        let target = menuTarget

        let app = NSMenu(title: "ReArc")
        app.addItem(withTitle: "Hide ReArc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        // NSApp.terminate is routed to terminate_requested -> ReArcEngineShutdown.
        app.addItem(withTitle: "Quit ReArc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addSubmenu(app, title: "ReArc")

        let file = NSMenu(title: "File")
        file.addItem(target.item("New Tab", "t") { model.newTab() })
        file.addItem(target.item("Reopen Closed Tab", "t", [.command, .shift]) { model.reopenClosedTab() })
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
        main.addSubmenu(view, title: "View")

        let tabs = NSMenu(title: "Tabs")
        tabs.addItem(target.item("Focus Location", "l") { model.focusLocation() })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Close Tab", "w") { model.closeSelectedTab() })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Next Tab", "]", [.command, .shift]) { model.selectNextTab() })
        tabs.addItem(target.item("Previous Tab", "[", [.command, .shift]) { model.selectPreviousTab() })
        tabs.addItem(target.item("Select Next Tab", "\t", [.control]) { model.selectNextTab() })
        tabs.addItem(.separator())
        tabs.addItem(target.item("Add Split View", "") { model.addSplitView(orientation: .horizontal) })
        main.addSubmenu(tabs, title: "Tabs")

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
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension BrowserViewModel {
    /// Chromium-created contents (popup, target=_blank) become a today tab in the
    /// active space; v1 opens popups as tabs, never as native windows.
    func adoptChromiumTab(_ event: ChromiumTabEvent) -> Bool {
        let blank = URL(string: "about:blank")!
        let url = event.url.flatMap(URL.init(string:)).flatMap { $0.absoluteString.isEmpty ? nil : $0 } ?? blank
        let tab = store.addTab(kind: .today, title: event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New Tab", url: url)
        let profileID = profileID(for: tab)
        let engine = ChromiumEngine(
            runtime: ChromiumRuntime.shared,
            adopting: event,
            initialURL: url,
            context: EngineProfileContext(profileID: profileID),
            shellID: tab.id
        )
        engine.onNavigationCommit = { [weak self] url, title in
            self?.handleTabNavigationCommit(tabID: tab.id, url: url, title: title)
        }
        engineHost.adopt(engine, for: tab, profileID: profileID)
        // Background-tab disposition stays unselected; the rest take focus in the sidebar.
        if event.disposition != 2 {
            selectTab(tab.id)
        }
        return true
    }
}
#endif
