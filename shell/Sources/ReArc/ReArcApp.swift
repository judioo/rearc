import SidebarModel
import SwiftUI

/// WebKit-path SwiftUI app; launched by `ReArcMain`.
struct ReArcApp: App {
    @State private var model = BrowserViewModel()
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue

    var body: some Scene {
        WindowGroup("ReArc") {
            BrowserView(model: model)
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
            CommandGroup(after: .appInfo) {
                Button("Set ReArc as Default Browser…") { model.setAsDefaultBrowser() }
                Toggle("Open Off-Site Links in Peek", isOn: $model.automaticPeekEnabled)
                Toggle("Automatic Picture in Picture", isOn: $model.automaticPictureInPicture)
                Toggle("Video in Sidebar", isOn: $model.embedsVideoInSidebar)
                Toggle("Show URL in Toolbar", isOn: $urlInToolbar)
                Picker("External Links", selection: $model.externalLinkDestination) {
                    ForEach(ExternalLinkDestination.allCases, id: \.self) { destination in
                        Text(destination.menuTitle).tag(destination)
                    }
                }
                Toggle("Open Little Arc from Anywhere (\(LittleArcHotkeyPreference.display))", isOn: $model.isLittleArcHotkeyEnabled)
                Button("Air Traffic Control…") { model.showAirTrafficControl() }
                if let preference = model.webKitSearchPreference {
                    Picker("Search Engine", selection: Binding(
                        get: { preference.providerID },
                        set: { model.webKitSearchPreference?.providerID = $0 }
                    )) {
                        ForEach(SearchProvider.builtIn, id: \.id) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    Toggle("Search Suggestions", isOn: Binding(
                        get: { preference.suggestionsEnabled },
                        set: { model.webKitSearchPreference?.suggestionsEnabled = $0 }
                    ))
                }
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
                ShellMenuButtons(groups: ShellMenus.documents(model))
            }
            // Arc keeps Copy URL in the Edit menu.
            CommandGroup(after: .pasteboard) {
                Divider()
                ShellMenuButtons(groups: ShellMenus.copyLink(model))
            }
            // Cmd+S — toggle the sidebar, replacing File > Save.
            CommandGroup(replacing: .saveItem) {
                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("s")
            }
            CommandGroup(replacing: .importExport) {
                ShellMenuButtons(groups: ShellMenus.importing(model, chromiumImporter: false))
            }
            CommandGroup(replacing: .printItem) {
                ShellMenuButtons(groups: ShellMenus.capture(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.printing(model))
            }
            // Edit > Find: the page's find bar replaces the text-field finder.
            CommandGroup(replacing: .textEditing) {
                ShellMenuButtons(groups: ShellMenus.find(model))
            }
            CommandGroup(after: .toolbar) {
                ShellMenuButtons(groups: ShellMenus.navigation(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.downloads(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.library(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.pictureInPicture(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.zoom(model))
            }
            CommandMenu("Tabs") {
                // Cmd+W — close the selected tab. There is no replaceable
                // placement for File > Close Window, so BrowserView strips
                // its key equivalent on launch, leaving this the sole ⌘W.
                // Named for what it does to the selected tab ("Archive Tab" in Today).
                Button(model.closeTabMenuTitle) { model.closeSelectedTabOrPrivateWindow() }
                    .keyboardShortcut("w")
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                ShellMenuButtons(groups: ShellMenus.tabNavigation(model))
                ShellMenuButtons(groups: ShellMenus.tabSwitcher(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.split(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.tabPositions(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.sidebarItems(model))
            }
            CommandMenu("Spaces") {
                ShellMenuButtons(groups: ShellMenus.spaces(model))
            }
        }

        Window("Air Traffic Control", id: "airTrafficControl") {
            AirTrafficControlView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SyncSettingsView(model: model)
        }
    }
}
