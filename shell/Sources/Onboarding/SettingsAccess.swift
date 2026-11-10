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

    /// A small floating card beside System Settings: ReArc's icon to drag
    /// into the Full Disk Access list, as other Mac apps offer. It does not
    /// take focus, so using it keeps System Settings in front.
    public static func showDragHelper(near settings: NSRect?, fallback screen: NSScreen?) {
        hideDragHelper()
        let size = NSSize(width: 300, height: 92)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        panel.setFrameOrigin(helperOrigin(size: size, near: settings, screen: (screen ?? NSScreen.main)?.visibleFrame,
                                          displays: NSScreen.screens.map(\.visibleFrame)))
        panel.orderFrontRegardless()
        helper = panel
    }

    public static func hideDragHelper() {
        helper?.orderOut(nil)
        helper = nil
    }

    /// Under System Settings' window, centred, if there is room on its
    /// display; else at the bottom of `screen`.
    public nonisolated static func helperOrigin(size: NSSize, near settings: NSRect?, screen: NSRect?, displays: [NSRect]) -> NSPoint {
        if let settings {
            let below = NSPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - 12)
            let display = displays.first { $0.intersects(settings) }
            if display.map({ below.y >= $0.minY }) ?? true { return below }
            return NSPoint(x: settings.minX - size.width - 12, y: settings.minY + 24)
        }
        let area = screen ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.midX - size.width / 2, y: area.minY + 40)
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
