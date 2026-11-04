import SidebarModel
import SwiftUI

/// WebKit-path SwiftUI app; launched by `ReArcMain`.
struct ReArcApp: App {
    @State private var model = BrowserViewModel()

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
                Picker("External Links", selection: $model.externalLinkDestination) {
                    ForEach(ExternalLinkDestination.allCases, id: \.self) { destination in
                        Text(destination.menuTitle).tag(destination)
                    }
                }
            }
            // Cmd+T — new tab, replacing File > New (window).
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t")
                Button("New Private Window") { model.openPrivateWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Cmd+S — toggle the sidebar, replacing File > Save.
            CommandGroup(replacing: .saveItem) {
                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("s")
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
                Button("Zoom In") { model.zoom(.zoomIn) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoom(.zoomOut) }
                    .keyboardShortcut("-")
                Button("Actual Size") { model.zoom(.reset) }
                    .keyboardShortcut("0")
            }
            CommandMenu("Tabs") {
                Button("Focus Location") { model.focusLocation() }
                    .keyboardShortcut("l")
                Divider()
                // Cmd+W — close the selected tab. There is no replaceable
                // placement for File > Close Window, so BrowserView strips
                // its key equivalent on launch, leaving this the sole ⌘W.
                Button("Close Tab") { model.closeSelectedTabOrPrivateWindow() }
                    .keyboardShortcut("w")
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Next Tab") { model.selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Select Next Tab") { model.selectNextTab() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Divider()
                Button("Add Split View") { model.addSplitView(orientation: .horizontal) }
                Button("Separate from Split View") {
                    if let tab = model.store.selectedTab {
                        model.unsplitTabIfInSplit(tab.id)
                    }
                }
                Divider()
                ShellMenuButtons(groups: ShellMenus.tabPositions(model))
                Divider()
                ShellMenuButtons(groups: ShellMenus.sidebarItems(model))
            }
            CommandMenu("Spaces") {
                ShellMenuButtons(groups: ShellMenus.spaces(model))
            }
        }
    }
}
