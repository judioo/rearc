import SwiftUI
import SidebarModel

extension EnvironmentValues {
    /// The browser window a sidebar or content view belongs to (per-window focused space).
    @Entry var sidebarWindow: SidebarWindowID?
    /// The window's Library is drawn over its sidebar (`SidebarView`).
    @Entry var sidebarCoveredByLibrary = false
}

/// Per-window focused space (wave 19): each browser window shows its own
/// space. The key window's space is the store's active space, so commands
/// act on it; these helpers give any window its own view of the sidebar.
extension BrowserViewModel {

    /// A browser window became key: bring back its space and selection, and
    /// load what it shows (the key window's host also takes the tab's lease).
    func windowBecameKey(_ window: SidebarWindowID) {
        if store.keyWindowID != window { cancelTabSwitcher() }
        keyLittleArcID = nil
        store.windowBecameKey(window)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    func space(in window: SidebarWindowID?) -> Space {
        store.focusedSpace(in: window)
    }

    func themeColor(in window: SidebarWindowID?) -> Color {
        let theme = shownTheme(in: window)
        return Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    func selectedItemID(in window: SidebarWindowID?) -> UUID? {
        store.selectedItemID(inSpace: store.focusedSpaceID(in: window))
    }

    func selectedTab(in window: SidebarWindowID?) -> Tab? {
        store.selectedTab(inSpace: store.focusedSpaceID(in: window))
    }

    func selectedEaselRef(in window: SidebarWindowID?) -> SidebarEaselRef? {
        selectedItemID(in: window).flatMap { store.easelRef(withSidebarID: $0) }
    }

    func activeSplit(in window: SidebarWindowID?) -> SplitViewItem? {
        selectedItemID(in: window).flatMap { store.split(withID: $0) }
    }

    func profile(in window: SidebarWindowID?) -> Profile {
        store.profile(withID: space(in: window).profileID) ?? store.activeProfile
    }

    /// The engine of the tab a window shows (nil until it was loaded).
    func focusedEngine(in window: SidebarWindowID?) -> (any WebEngine)? {
        guard selectedEaselRef(in: window) == nil, let tab = selectedTab(in: window) else { return nil }
        return engineHost.engine(forTabID: tab.id, profileID: profileID(for: tab))
    }
}

/// Reports when its window becomes key, and when it closes.
struct WindowKeyObserver: NSViewRepresentable {
    var onBecameKey: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onBecameKey = onBecameKey
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onBecameKey = onBecameKey
        nsView.onClose = onClose
    }

    final class ObservingView: NSView {
        var onBecameKey: (() -> Void)?
        var onClose: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onBecameKey?()
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onClose?()
            })
            if window.isKeyWindow {
                DispatchQueue.main.async { [weak self] in self?.onBecameKey?() }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
