import SidebarModel
import SwiftUI

/// WebKit-path SwiftUI app; launched by `ReArcMain`.
struct ReArcApp: App {
    @State private var model = BrowserViewModel()

    var body: some Scene {
        WindowGroup("ReArc") {
            BrowserView(model: model)
                .onAppear {
                    // The Settings scene opens through AppKit's action (macOS 14).
                    model.presentSettings = { _ in NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    if model.appIcon != .standard { model.appIcon.apply() }
                }
        }
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Little Arc", id: "littleArc", for: LittleArcWindow.ID.self) { $windowID in
            if let windowID {
                LittleArcWindowView(model: model, windowID: windowID)
            } else {
                Text("No Little Arc window")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 420)

        WindowGroup("Private Window", id: "private", for: UUID.self) { $windowID in
            if let windowID, let window = model.privateWindows[windowID] {
                PrivateWindowView(model: model, window: window)
                    .onDisappear { model.privateWindowClosed(windowID) }
            } else {
                ClosedPrivateWindowView()
            }
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            // The rest of the old ReArc menu's switches are in Settings (wave 35).
            CommandGroup(after: .appInfo) {
                Button("Set ReArc as Default Browser…") { model.setAsDefaultBrowser() }
                Button("Air Traffic Control…") { model.showAirTrafficControl() }
            }
            // Warn before quitting: only ⌘Q asks.
            CommandGroup(replacing: .appTermination) {
                Button("Quit ReArc") {
                    let open = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }.count
                    if model.confirmQuit(browserWindows: open) { NSApp.terminate(nil) }
                }
                .keyboardShortcut("q")
            }
            // Cmd+T — new tab, replacing File > New (window).
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t")
                Button("New Private Window") { model.openPrivateWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Little Arc Window") { model.openBlankLittleArc() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Open Command Bar") { model.focusLocation() }
                    .keyboardShortcut("l")
                Divider()
                ShellMenuButtons(groups: ShellMenus.documents(model), overrides: model.shortcutOverrides)
            }
            // Arc keeps Copy URL in the Edit menu.
            CommandGroup(after: .pasteboard) {
                Divider()
                ShellMenuButtons(groups: ShellMenus.copyLink(model), overrides: model.shortcutOverrides)
            }
            // Cmd+S — toggle the sidebar, replacing File > Save.
            CommandGroup(replacing: .saveItem) {
                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("s")
            }
            CommandGroup(replacing: .importExport) {
                ShellMenuButtons(groups: ShellMenus.importing(model, chromiumImporter: false), overrides: model.shortcutOverrides)
            }
            CommandGroup(replacing: .printItem) {
                ShellMenuButtons(groups: ShellMenus.capture(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.printing(model), overrides: model.shortcutOverrides)
            }
            // Edit > Find: the page's find bar replaces the text-field finder.
            CommandGroup(replacing: .textEditing) {
                ShellMenuButtons(groups: ShellMenus.find(model), overrides: model.shortcutOverrides)
            }
            CommandGroup(after: .toolbar) {
                ShellMenuButtons(groups: ShellMenus.navigation(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.downloads(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.library(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.pictureInPicture(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.zoom(model), overrides: model.shortcutOverrides)
            }
            CommandMenu("Tabs") {
                // Cmd+W — close the selected tab. There is no replaceable
                // placement for File > Close Window, so BrowserView strips
                // its key equivalent on launch, leaving this the sole ⌘W.
                Button("Close Tab") { model.closeSelectedTabOrPrivateWindow() }
                    .keyboardShortcut("w")
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                ShellMenuButtons(groups: ShellMenus.tabNavigation(model), overrides: model.shortcutOverrides)
                ShellMenuButtons(groups: ShellMenus.tabSwitcher(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.split(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.tabPositions(model), overrides: model.shortcutOverrides)
                Divider()
                ShellMenuButtons(groups: ShellMenus.sidebarItems(model), overrides: model.shortcutOverrides)
            }
            CommandMenu("Spaces") {
                ShellMenuButtons(groups: ShellMenus.spaces(model), overrides: model.shortcutOverrides)
            }
        }

        Window("Air Traffic Control", id: "airTrafficControl") {
            AirTrafficControlView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsTabsView(model: model)
        }
    }
}
