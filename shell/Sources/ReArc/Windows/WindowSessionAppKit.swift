import AppKit
import SidebarModel

/// AppKit side of the browser-window session (docs/WINDOW-RESTORE.md): which
/// display a window is on, its macOS desktop, and debounced saves while it
/// moves.
///
/// Why not `setFrameAutosaveName` / `setFrameUsingName`: on macOS 26/27,
/// `-setFrameFromString:` ignores the display recorded in the string and
/// re-maps the frame onto `NSScreen.main`, the display with keyboard focus
/// at launch. A window saved on the external display comes back on the
/// built-in one whenever focus is there (and vice versa). `setFrame(_:display:)`
/// with a rect `WindowPlacement` worked out from the display UUID keeps it.
extension DisplayDescriptor {
    /// Connected displays, primary first (`NSScreen.screens` order).
    @MainActor
    static func current(_ screens: [NSScreen] = NSScreen.screens) -> [DisplayDescriptor] {
        screens.compactMap { screen in
            screen.displayUUID.map { DisplayDescriptor(uuid: $0, frame: screen.frame, visibleFrame: screen.visibleFrame) }
        }
    }
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike the CGDirectDisplayID.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// macOS desktops (Spaces). No public API moves a window to a Space, and the
/// private CGS/SLS calls that did are refused for ordinary apps since 14.5.
/// What works is the window's own restorable state: an archive from
/// `-encodeRestorableStateWithCoder:` handed back to `-restoreStateWithCoder:`
/// before the window is ordered in. AppKit then puts the window back on the
/// desktop it was on, provided the decoder answers `_windowRestorationOptions`
/// with a default `NSWindowRestorationOptions` (macOS 15 and later; before
/// that the `NSWindowRestoresWorkspaceAtLaunch` default did it). Chromium
/// uses the same mechanism (native_widget_ns_window_bridge.mm, FB15644170);
/// we only answer a selector AppKit sends to our own decoder and call no
/// private function. If AppKit stops doing this, windows open on the current
/// desktop and everything else still restores.
///
/// This works whatever "Close windows when quitting an application" is set
/// to: that setting (NSQuitAlwaysKeepsWindows) only governs AppKit's own
/// launch-time restoration through `restorationClass`, which the Chromium
/// shell does not use (its windows need the engine, which AppKit can't wait for).
enum WindowDesktopState {
    static func encode(_ window: NSWindow) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        let filter = ArchiveFilter(window: window)
        archiver.delegate = filter
        window.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        return withExtendedLifetime(filter) { archiver.encodedData }
    }

    /// Call before the window is first ordered in; restores its desktop (and
    /// AppKit's own frame, so set the placed frame again afterwards).
    static func restore(_ window: NSWindow, from data: Data) {
        guard let decoder = try? SpaceRestoringUnarchiver(forReadingFrom: data) else { return }
        decoder.requiresSecureCoding = true
        window.restoreState(with: decoder)
        decoder.finishDecoding()
    }

    /// Keeps the window itself and its views (the first responder) out of
    /// the archive, as AppKit's own restoration coder does.
    private final class ArchiveFilter: NSObject, NSKeyedArchiverDelegate {
        weak var window: NSWindow?
        init(window: NSWindow) { self.window = window }

        func archiver(_ archiver: NSKeyedArchiver, willEncode object: Any) -> Any? {
            if let object = object as? NSObject, object === window || object is NSView { return nil }
            return object
        }
    }

    private final class SpaceRestoringUnarchiver: NSKeyedUnarchiver {
        @objc func _windowRestorationOptions() -> AnyObject? {
            (NSClassFromString("NSWindowRestorationOptions") as? NSObject.Type)?.init()
        }
    }
}

/// Watches browser windows and saves the session after a quiet period:
/// moves, resizes, display and desktop changes, full screen, key changes,
/// opens and closes. `snapshot` builds the session from the shell's windows,
/// or returns nil to keep the file as it is (a launch restore still running).
@MainActor
final class WindowSessionRecorder {
    static let saveDelay: TimeInterval = 0.5

    let fileURL: URL
    private let snapshot: () -> WindowSessionSnapshot?
    private lazy var debouncer = Debouncer(delay: Self.saveDelay) { [weak self] in
        MainActor.assumeIsolated { self?.saveNow() }
    }
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// A full-screen window's frame from before it went full screen.
    private var windowedFrames: [ObjectIdentifier: CGRect] = [:]
    /// Windows entering or leaving full screen (the restore must not toggle them).
    private(set) var transitioning: Set<ObjectIdentifier> = []
    private(set) var saveCount = 0

    init(fileURL: URL = WindowSessionFile.defaultFileURL, snapshot: @escaping () -> WindowSessionSnapshot?) {
        self.fileURL = fileURL
        self.snapshot = snapshot
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
    }

    func observe(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard observers[key] == nil else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            // A window dragged to another desktop changes occlusion; no other notification says so.
            NSWindow.didChangeOcclusionStateNotification,
        ]
        var tokens = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
        tokens.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) {
            [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.windowedFrames[key] = window.frame
                self.transitioning.insert(key)
            }
        })
        tokens.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { _ = self?.transitioning.insert(key) }
        })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.transitioning.remove(key)
                    if note.name == NSWindow.didExitFullScreenNotification { self.windowedFrames[key] = nil }
                    self.changed()
                }
            })
        }
        observers[key] = tokens
        changed()
    }

    func forget(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        observers.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver)
        windowedFrames[key] = nil
        transitioning.remove(key)
    }

    func changed() { debouncer.signal() }

    /// Quit: write now, and nothing after (windows closing at quit must not
    /// empty the session).
    func finish() {
        debouncer.cancel()
        saveNow()
        appObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        appObservers = []
        workspaceObservers = []
        for key in Array(observers.keys) { observers.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver) }
    }

    func saveNow() {
        debouncer.cancel()
        guard let session = snapshot() else { return }
        do {
            try WindowSessionFile.save(session, to: fileURL)
            saveCount += 1
        } catch {
            NSLog("ReArc: window session not saved: \(error)")
        }
    }

    /// One window's record. Its frame is the windowed one when it is full screen.
    func record(_ window: NSWindow, isKey: Bool, space: Space?) -> SavedBrowserWindow {
        let fullScreen = window.styleMask.contains(.fullScreen)
        let frame = fullScreen ? (windowedFrames[ObjectIdentifier(window)] ?? window.frame) : window.frame
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(frame) }
        return SavedBrowserWindow(
            frame: frame,
            display: screen.map { SavedDisplay(uuid: $0.displayUUID, frame: $0.frame, visibleFrame: $0.visibleFrame) },
            isFullScreen: fullScreen,
            isZoomed: !fullScreen && window.isZoomed,
            isKey: isKey,
            spaceID: space?.id,
            profileID: space?.profileID,
            appKitState: WindowDesktopState.encode(window)
        )
    }
}

extension NSWindow {
    /// Before the first order-in: the placed frame, and the window's desktop.
    @MainActor
    func applySavedPlacement(_ saved: SavedBrowserWindow, displays: [DisplayDescriptor]? = nil) {
        let placed = WindowPlacement.resolve(saved, displays: displays ?? DisplayDescriptor.current()).frame
        setFrame(placed, display: false)
        if let state = saved.appKitState {
            WindowDesktopState.restore(self, from: state)
            // The archive carries AppKit's frame too, which may be on a display that is gone.
            if frame != placed { setFrame(placed, display: false) }
        }
    }
}
