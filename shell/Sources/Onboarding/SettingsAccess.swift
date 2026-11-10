import AppKit
import SidebarModel
import SwiftUI

/// Sending the person to System Settings for a privacy permission and
/// keeping them oriented: where its window went, and, for Full Disk Access
/// (which macOS never lists ReArc in by itself), a small panel with ReArc's
/// icon to drag into the list. Used by Act 2 and the Import window.
@MainActor
public enum SettingsAccess {
    public static let settingsBundleID = "com.apple.systempreferences"

    /// Opens `permission`'s pane and brings System Settings to the front.
    public static func open(_ permission: ImportPermission) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(permission.settingsURL, configuration: configuration) { _, _ in }
    }

    /// System Settings' largest on-screen window, in AppKit screen
    /// coordinates. Window bounds need no screen-recording permission.
    public static func settingsWindowFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let pid = app.processIdentifier
        let frames = info.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return appKitFrame(fromWindowServer: largest, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Window Server bounds (origin at the primary display's top left, y
    /// down) as AppKit's (origin at its bottom left, y up).
    public nonisolated static func appKitFrame(fromWindowServer rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display a frame mostly sits on, among `screens`.
    public nonisolated static func screenIndex(of frame: NSRect, in screens: [NSRect]) -> Int? {
        let areas = screens.map { frame.intersection($0).width * frame.intersection($0).height }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    /// Whether System Settings' window is on another display than `window`.
    /// nil while it has not appeared.
    public static func settingsIsElsewhere(than window: NSWindow?) -> Bool? {
        guard let settings = settingsWindowFrame(), let ours = window?.frame else { return nil }
        let screens = NSScreen.screens.map(\.frame)
        guard let theirs = screenIndex(of: settings, in: screens), let mine = screenIndex(of: ours, in: screens) else { return nil }
        return theirs != mine
    }

    /// Calls `found` once System Settings' window is up (or with nil after
    /// a few seconds), polling twice a second.
    public static func whenSettingsAppears(tries: Int = 10, _ found: @escaping @MainActor (NSRect?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                if let frame = settingsWindowFrame() { found(frame); return }
                if tries <= 1 { found(nil); return }
                whenSettingsAppears(tries: tries - 1, found)
            }
        }
    }

    // MARK: Drag helper

    private static var helper: NSPanel?

    /// The drag helper's size.
    public static let helperSize = NSSize(width: 300, height: 92)

    /// A small floating card beside System Settings: ReArc's icon to drag
    /// into the Full Disk Access list, as other Mac apps offer. It does not
    /// take focus, so using it keeps System Settings in front.
    public static func showDragHelper(at frame: NSRect) {
        hideDragHelper()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: frame.size),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DragHelperView(appURL: Bundle.main.bundleURL))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        helper = panel
    }

    /// The display System Settings uses: its window's, else the main one
    /// (the one with the menu bar, where it opens). Visible frames.
    public static func settingsScreen(for settings: NSRect?) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let settings, let i = screenIndex(of: settings, in: NSScreen.screens.map(\.frame)) else { return main }
        return screens[i]
    }

    public static func hideDragHelper() {
        helper?.orderOut(nil)
        helper = nil
    }

}

/// Where the onboarding's window and the drag helper go while System
/// Settings is open: on Settings' display, in the larger free column beside
/// its window, the helper on top and the scene under it, so neither covers
/// Settings. When a column is too narrow they still stay clear of Settings'
/// right-hand list: only its sidebar, on the left, may be covered.
public struct SettingsCompanionLayout: Equatable, Sendable {
    public var scene: NSRect
    public var helper: NSRect?

    static let margin: CGFloat = 16
    static let minSceneWidth: CGFloat = 420
    /// Where System Settings is expected before its window is seen: centred, its usual size.
    static let assumedSettings = NSSize(width: 715, height: 690)

    /// `screen` is a visible frame; `settings` nil means not seen yet.
    public static func layout(screen: NSRect, settings: NSRect?, helper: NSSize?) -> SettingsCompanionLayout {
        let settings = settings ?? NSRect(x: screen.midX - assumedSettings.width / 2, y: screen.midY - assumedSettings.height / 2,
                                          width: assumedSettings.width, height: assumedSettings.height)
        let m = margin
        let leftRoom = settings.minX - screen.minX - 2 * m
        let rightRoom = screen.maxX - settings.maxX - 2 * m
        let useRight = rightRoom >= leftRoom
        var width = max(useRight ? rightRoom : leftRoom, 0)
        var x = useRight ? settings.maxX + m : screen.minX + m
        if width < minSceneWidth {
            // Too narrow beside it: take the left edge, over Settings' sidebar at most, never its list.
            width = min(minSceneWidth, screen.width - 2 * m)
            x = screen.minX + m
        }
        let helperFrame = helper.map { size in
            NSRect(x: x + max(0, (width - size.width) / 2), y: screen.maxY - m - size.height, width: min(size.width, width), height: size.height)
        }
        let top = (helperFrame?.minY ?? screen.maxY) - m
        // The scene keeps its 16:10 shape inside the rest of the column.
        let height = min(top - screen.minY - m, width * 10 / 16)
        let sceneWidth = min(width, height * 16 / 10)
        let scene = NSRect(x: (x + (width - sceneWidth) / 2).rounded(), y: (top - height).rounded(),
                           width: sceneWidth.rounded(), height: height.rounded())
        return SettingsCompanionLayout(scene: scene, helper: helperFrame)
    }
}

/// ReArc's icon, draggable as the app itself, and one line saying what to do.
struct DragHelperView: View {
    let appURL: URL

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 52, height: 52)
                .onDrag { NSItemProvider(object: appURL as NSURL) }
                .help("Drag ReArc into the Full Disk Access list")
            VStack(alignment: .leading, spacing: 3) {
                Text("Not in the list?").font(.system(size: 13, weight: .semibold))
                Text("Drag ReArc into it, then switch it on.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
