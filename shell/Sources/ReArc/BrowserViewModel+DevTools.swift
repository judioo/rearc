import SwiftUI
import SidebarModel

/// Engines that host a DevTools frontend for a page (Chromium ABI 1.40).
protocol DevToolsOpening: AnyObject {
    /// Asks for a frontend on `engine`'s page; it arrives through
    /// `BrowserViewModel.attachDevTools`. Returns why it cannot, or nil.
    func openDevTools(for tab: Tab, engine: any WebEngine) -> String?
    /// Closes the registry tab even while a view or caller retains its engine.
    func closeDevTools(frontendTabID: UInt64)
}

/// DevTools (Arc: View > Developer > Developer Tools, ⌥⌘I; the page menu's
/// Inspect). The frontend is a tab the engine makes. It shows docked beside
/// its page, Arc's default, or in its own window, and closes with its page.
extension BrowserViewModel {

    var canOpenDevTools: Bool { devToolsOpener != nil }

    /// ⌥⌘I: opens the selected tab's DevTools, or closes them when open.
    @discardableResult
    func toggleDevTools(tabID: Tab.ID? = nil) -> String? {
        guard let id = tabID ?? store.selectedTabID else { return "No page to inspect" }
        if devTools.session(for: id) != nil {
            closeDevTools(for: id)
            return nil
        }
        return openDevTools(for: id)
    }

    /// Inspect: opens them, or shows the ones already open.
    @discardableResult
    func openDevTools(for tabID: Tab.ID) -> String? {
        if let session = devTools.session(for: tabID) {
            if session.placement == .window { windowPresenter?.presentDevToolsWindow(for: tabID) }
            return nil
        }
        guard let opener = devToolsOpener else { return "Developer Tools need the Chromium engine" }
        guard let tab = store.tab(withID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)) else { return "No page to inspect" }
        guard !devToolsPending.contains(tabID) else { return nil }
        devToolsPending.insert(tabID)
        if let error = opener.openDevTools(for: tab, engine: engine) {
            devToolsPending.remove(tabID)
            return error
        }
        return nil
    }

    /// The engine's frontend for `tabID` arrived.
    func attachDevTools(_ engine: any WebEngine, frontendTabID: UInt64, for tabID: Tab.ID) {
        devToolsPending.remove(tabID)
        guard store.tab(withID: tabID) != nil, devTools.session(for: tabID) == nil else { return }
        devToolsEngines[tabID] = engine
        devTools.opened(frontendTabID, for: tabID)
    }

    /// The engine closed a frontend (its page closed, or the frontend itself).
    func devToolsFrontendClosed(_ frontendTabID: UInt64) {
        guard let tabID = devTools.tab(forFrontend: frontendTabID) else { return }
        removeDevTools(for: tabID)
    }

    /// Closes the frontend explicitly; engine lifetime is independent of the UI.
    func closeDevTools(for tabID: Tab.ID) {
        guard let session = removeDevTools(for: tabID) else { return }
        devToolsOpener?.closeDevTools(frontendTabID: session.frontendTabID)
    }

    @discardableResult
    private func removeDevTools(for tabID: Tab.ID) -> DevToolsSession? {
        devToolsPending.remove(tabID)
        guard let session = devTools.close(for: tabID) else { return nil }
        if session.placement == .window { windowPresenter?.dismissDevToolsWindow(for: tabID) }
        devToolsEngines[tabID] = nil
        return session
    }

    /// Pops the selected tab's DevTools out to a window, or docks them back.
    func setDevToolsPlacement(_ placement: DevToolsPlacement, for tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID, let session = devTools.session(for: id), session.placement != placement else { return }
        devTools.setPlacement(placement, for: id)
        if placement == .window {
            windowPresenter?.presentDevToolsWindow(for: id)
        } else {
            windowPresenter?.dismissDevToolsWindow(for: id)
        }
    }

    /// The DevTools window was closed by the user: the frontend goes too.
    func devToolsWindowClosed(for tabID: Tab.ID) {
        guard devTools.session(for: tabID)?.placement == .window else { return }
        devTools.setPlacement(.docked, for: tabID)
        closeDevTools(for: tabID)
    }

    /// The docked frontend shown beside `tabID`'s page, if any.
    func dockedDevTools(for tabID: Tab.ID) -> (any WebEngine)? {
        guard devTools.session(for: tabID)?.placement == .docked else { return nil }
        return devToolsEngines[tabID]
    }

    func devToolsEngine(for tabID: Tab.ID) -> (any WebEngine)? { devToolsEngines[tabID] }
}

/// The page with its DevTools docked on the right (Arc's default), a
/// draggable divider, and buttons to open them in a window or close them.
struct DevToolsDockedLayout<Page: View>: View {
    let model: BrowserViewModel
    let tabID: Tab.ID
    let frontend: any WebEngine
    @ViewBuilder var page: Page
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let toolsWidth = max(240, width * model.devTools.dockFraction)
            HStack(spacing: 0) {
                page
                    .frame(width: max(width - toolsWidth - 1, 0))
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1)
                    .overlay(
                        Color.clear
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                                let start = dragStart ?? model.devTools.dockFraction
                                dragStart = start
                                model.devTools.setDockFraction(start - drag.translation.width / max(width, 1))
                            }.onEnded { _ in dragStart = nil })
                    )
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Developer Tools").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.setDevToolsPlacement(.window, for: tabID) } label: {
                            Image(systemName: "macwindow.on.rectangle")
                        }
                        .buttonStyle(.borderless)
                        .help("Open Developer Tools in a Window")
                        Button { model.closeDevTools(for: tabID) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Close Developer Tools (⌥⌘I)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    Divider()
                    frontend.makeView()
                }
                .frame(width: toolsWidth)
            }
        }
    }
}

/// A popped-out DevTools window's content.
struct DevToolsWindowView: View {
    let model: BrowserViewModel
    let tabID: Tab.ID

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.store.tab(withID: tabID)?.displayTitle ?? "Developer Tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Dock to Page") { model.setDevToolsPlacement(.docked, for: tabID) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            if let engine = model.devToolsEngine(for: tabID), model.devTools.session(for: tabID)?.placement == .window {
                engine.makeView()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
