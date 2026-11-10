import AppKit
import SwiftUI
import SidebarModel

/// Keeps the page in the same view tree and at a constant size while the
/// toolbar slides over it. Only changing the preference resizes the page once.
struct AddressBarContainer<Page: View, Toolbar: View>: View {
    var showsToolbar: Bool
    var holdsForAddressEditing: Bool
    var revealsAtWindowTop = true
    @ViewBuilder var page: () -> Page
    @ViewBuilder var toolbar: () -> Toolbar
    @AppStorage(AutoHideAddressBarPreference.key) private var autoHide = AutoHideAddressBarPreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibility = AddressBarVisibility()
    @State private var pointer = AddressBarVisibility.Pointer.outside
    @State private var toolbarHasFocus = false
    @State private var menuIsTracking = false

    private var isVisible: Bool { showsToolbar && (!autoHide || visibility.isRevealed) }
    private var holdsFocus: Bool { holdsForAddressEditing || toolbarHasFocus || menuIsTracking }

    var body: some View {
        ZStack(alignment: .top) {
            page()
                .padding(.top, showsToolbar && !autoHide ? CardToolbarView.height : 0)
            if showsToolbar {
                toolbar()
                    .background { if autoHide { Rectangle().fill(.regularMaterial) } }
                    .onPreferenceChange(AddressBarFocusPreference.self) { toolbarHasFocus = $0 }
                    .offset(y: isVisible ? 0 : -CardToolbarView.height)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .disabled(!isVisible)
                    .accessibilityHidden(!isVisible)
                    .zIndex(1)
            }
        }
        .clipped()
        .background(AddressBarPointerMonitor(
            isEnabled: autoHide && showsToolbar, revealsAtWindowTop: revealsAtWindowTop,
            toolbarHasFocus: toolbarHasFocus, onChange: { pointer = $0 },
            onMenuTracking: { menuIsTracking = $0 }
        ))
        .onAppear { updateVisibility() }
        .onChange(of: autoHide) { _, _ in updateVisibility() }
        .onChange(of: pointer) { _, _ in updateVisibility() }
        .onChange(of: holdsFocus) { _, _ in updateVisibility() }
        .onChange(of: showsToolbar) { _, _ in updateVisibility() }
        .task(id: visibility.hideDeadline) {
            guard let deadline = visibility.hideDeadline else { return }
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            animate { visibility.hideIfDue(at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    private func updateVisibility() {
        animate {
            visibility.update(autoHideEnabled: autoHide, pointer: showsToolbar ? pointer : .outside,
                              hasKeyboardFocus: showsToolbar && holdsFocus,
                              now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func animate(_ change: () -> Void) {
        // The sidebar's 120 ms ease-out convention (⌘S), without travel or fade
        // under Reduce Motion. Never animate a web view's frame.
        withAnimation(reduceMotion ? nil : BrowserViewModel.sidebarAnimation, change)
    }
}

/// Focus from actual toolbar buttons/menus, plus any presented site controls
/// or extension popup. Each container reduces only its own descendants.
struct AddressBarFocusPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct AddressBarControlFocus: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused)
            .preference(key: AddressBarFocusPreference.self, value: focused)
    }
}

extension View {
    func addressBarControlFocus() -> some View { modifier(AddressBarControlFocus()) }
}

/// Observes mouse movement without intercepting the page's clicks, including
/// over Chromium's native host. Screen coordinates avoid flipped-view and
/// fullscreen titlebar offsets. No global event is consumed or modified.
private struct AddressBarPointerMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var revealsAtWindowTop: Bool
    var toolbarHasFocus: Bool
    var onChange: (AddressBarVisibility.Pointer) -> Void
    var onMenuTracking: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        nsView.window?.acceptsMouseMovedEvents = true
        if isEnabled {
            if context.coordinator.localMonitor == nil { context.coordinator.start() }
        } else {
            context.coordinator.stop()
        }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.sample() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
    }

    final class Coordinator {
        var parent: AddressBarPointerMonitor
        weak var view: NSView?
        var localMonitor: Any?
        var globalMonitor: Any?
        var observers: [NSObjectProtocol] = []
        var lastPosition: AddressBarVisibility.Pointer = .outside
        var trackingMenus: Set<ObjectIdentifier> = []

        init(parent: AddressBarPointerMonitor) { self.parent = parent }

        func start() {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .leftMouseDragged, .leftMouseDown, .keyUp]) { [weak self] event in
                // Fullscreen menu-bar moves may have no event.window. Sample
                // the pointer directly; sample() checks our window is key.
                self?.sample()
                return event
            }
            // Mouse moves in the system fullscreen menu bar are outside our
            // process. This monitor needs no keyboard/accessibility permission.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.sample()
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu,
                      !self.trackingMenus.isEmpty || self.lastPosition != .outside || self.parent.toolbarHasFocus else { return }
                self.trackingMenus.insert(ObjectIdentifier(menu))
                self.parent.onMenuTracking(true)
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu,
                      self.trackingMenus.remove(ObjectIdentifier(menu)) != nil else { return }
                self.parent.onMenuTracking(!self.trackingMenus.isEmpty)
                self.sample()
            })
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.sample()
                })
            }
        }

        func stop() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            localMonitor = nil
            globalMonitor = nil
            trackingMenus.removeAll()
        }

        func sample() {
            guard parent.isEnabled, NSApp.isActive, let view, let window = view.window,
                  window.isKeyWindow else { report(.outside); return }
            let pane = window.convertToScreen(view.convert(view.bounds, to: nil))
            var top = pane.maxY
            if parent.revealsAtWindowTop {
                top = window.frame.maxY
                if window.styleMask.contains(.fullScreen), let screen = window.screen { top = screen.frame.maxY }
            }
            report(AddressBarPointerRegion.position(NSEvent.mouseLocation, pane: pane, topEdge: top))
        }

        private func report(_ position: AddressBarVisibility.Pointer) {
            guard lastPosition != position else { return }
            lastPosition = position
            parent.onChange(position)
        }
    }
}
