import CoreGraphics
import Foundation

/// The browser windows open at the last save, for launch restore
/// (docs/WINDOW-RESTORE.md). `windows` is front to back (z-order); the key
/// window has `isKey`. Private and Little Arc windows are never in it.
public struct WindowSessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var windows: [SavedBrowserWindow]
    /// The last browser window the user closed: with no windows left at quit,
    /// the next launch opens one where it was.
    public var lastClosed: SavedBrowserWindow?

    public init(windows: [SavedBrowserWindow], lastClosed: SavedBrowserWindow? = nil) {
        self.version = Self.currentVersion
        self.windows = windows
        self.lastClosed = lastClosed
    }

    /// The window the launch puts up first (the early window): the key window,
    /// else the frontmost, else the one closed last.
    public var launchWindow: SavedBrowserWindow? {
        windows.first(where: \.isKey) ?? windows.first ?? lastClosed
    }

    /// Restore turned off (`WindowRestorePreference`): the launch window alone,
    /// where it was.
    public var launchWindowOnly: WindowSessionSnapshot {
        WindowSessionSnapshot(windows: launchWindow.map { [$0] } ?? [])
    }

    /// Every other saved window, front to back.
    public var otherWindows: [SavedBrowserWindow] {
        guard let launch = windows.firstIndex(where: \.isKey) ?? (windows.isEmpty ? nil : 0) else { return [] }
        var rest = windows
        rest.remove(at: launch)
        return rest
    }
}

/// The display a window was on, by its stable `CGDisplayCreateUUIDFromDisplayID`
/// UUID (display IDs change across reboots and reconnects), with its frames
/// at save time so a resolution change is noticed.
public struct SavedDisplay: Codable, Equatable, Sendable {
    /// Nil only for a frame migrated from AppKit's autosave string.
    public var uuid: String?
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(uuid: String?, frame: CGRect, visibleFrame: CGRect) {
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct SavedBrowserWindow: Codable, Equatable, Sendable {
    /// Global AppKit coordinates (origin at the primary display's bottom
    /// left). For a full-screen window, the frame it had before it went full
    /// screen.
    public var frame: CGRect
    public var display: SavedDisplay?
    public var isFullScreen: Bool
    public var isZoomed: Bool
    public var isKey: Bool
    /// The ReArc space the window showed, and its profile (the fallback when
    /// the space is gone).
    public var spaceID: UUID?
    public var profileID: UUID?
    /// The window's sidebar mode (⇧⌘S). Nil in files from before it, and
    /// for a full sidebar: older builds ignore the key.
    public var sidebarMode: SidebarMode?
    /// `-[NSWindow encodeRestorableStateWithCoder:]` output. Handing it back
    /// through `-restoreStateWithCoder:` is what returns the window to its
    /// macOS desktop (Space); see WindowDesktopState.
    public var appKitState: Data?

    public init(
        frame: CGRect,
        display: SavedDisplay?,
        isFullScreen: Bool = false,
        isZoomed: Bool = false,
        isKey: Bool = false,
        spaceID: UUID? = nil,
        profileID: UUID? = nil,
        sidebarMode: SidebarMode? = nil,
        appKitState: Data? = nil
    ) {
        self.frame = frame
        self.display = display
        self.isFullScreen = isFullScreen
        self.isZoomed = isZoomed
        self.isKey = isKey
        self.spaceID = spaceID
        self.profileID = profileID
        self.sidebarMode = sidebarMode
        self.appKitState = appKitState
    }

    /// AppKit's frame autosave string (`-[NSWindow stringWithSavedFrame]`):
    /// "x y w h  sx sy sw sh", the window frame then the screen's visible
    /// frame. Used once, to migrate the old `NSWindow Frame` default.
    public init?(appKitFrameString string: String) {
        let numbers = string.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        let frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        var display: SavedDisplay?
        if numbers.count >= 8 {
            let visible = CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7])
            display = SavedDisplay(uuid: nil, frame: visible, visibleFrame: visible)
        }
        self.init(frame: frame, display: display, isKey: true)
    }
}

/// One connected display, as `WindowPlacement` sees it (the shell builds
/// these from NSScreen; tests inject them).
public struct DisplayDescriptor: Equatable, Sendable {
    public var uuid: String
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(uuid: String, frame: CGRect, visibleFrame: CGRect) {
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where a saved window goes on the displays connected now.
public enum WindowPlacement {
    public enum Match: Equatable, Sendable {
        /// Its display, unchanged: the frame is used exactly as saved.
        case sameDisplay
        /// Its display, at another resolution or arrangement.
        case displayChanged
        /// Its display is gone: moved onto the primary display.
        case displayMissing
    }

    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        public var display: DisplayDescriptor?
        public var match: Match

        /// Whether the window goes back to its saved desktop. A window whose
        /// display is gone opens on the desktop in front instead: macOS moves
        /// that display's desktops onto another one, where it would be out of sight.
        public var restoresDesktop: Bool { match != .displayMissing }
    }

    /// `displays` must list the primary display (the one with the menu bar
    /// in System Settings > Displays) first, as `NSScreen.screens` does.
    public static func resolve(_ saved: SavedBrowserWindow, displays: [DisplayDescriptor]) -> Result {
        guard let primary = displays.first else {
            return Result(frame: saved.frame, display: nil, match: .displayMissing)
        }
        guard let savedDisplay = saved.display else {
            return Result(frame: clamp(saved.frame, into: primary.visibleFrame), display: primary, match: .displayMissing)
        }
        if let display = match(savedDisplay, in: displays) {
            if display.frame == savedDisplay.frame, display.visibleFrame == savedDisplay.visibleFrame {
                return Result(frame: saved.frame, display: display, match: .sameDisplay)
            }
            return Result(frame: move(saved.frame, from: savedDisplay.visibleFrame, to: display.visibleFrame),
                          display: display, match: .displayChanged)
        }
        return Result(frame: move(saved.frame, from: savedDisplay.visibleFrame, to: primary.visibleFrame),
                      display: primary, match: .displayMissing)
    }

    /// By UUID; a migrated record without one matches the display whose
    /// visible frame it saved.
    static func match(_ saved: SavedDisplay, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        if let uuid = saved.uuid { return displays.first { $0.uuid == uuid } }
        return displays.first { $0.visibleFrame == saved.visibleFrame }
    }

    /// Keeps the window's offset from the top-left of the visible frame it was
    /// on, then keeps it entirely inside `target` (size clamped first).
    public static func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let left = frame.minX - source.minX
        let top = source.maxY - frame.maxY
        let size = CGSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        let moved = CGRect(x: target.minX + left, y: target.maxY - top - size.height, width: size.width, height: size.height)
        return clamp(moved, into: target)
    }

    /// The largest part of `frame` that fits, moved fully inside `bounds`.
    public static func clamp(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// `window-session.json` in the shell data root (`ShellDataLocation`, so
/// `REARC_DATA_DIR` launches keep their own).
public enum WindowSessionFile {
    public static let defaultFileURL: URL = ShellDataLocation.root
        .appendingPathComponent("window-session.json", isDirectory: false)

    /// Nil when the file is missing, unreadable, or from a newer schema.
    public static func load(from url: URL = defaultFileURL) -> WindowSessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public static func decode(_ data: Data) -> WindowSessionSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(WindowSessionSnapshot.self, from: data),
              snapshot.version <= WindowSessionSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public static func encode(_ snapshot: WindowSessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func save(_ snapshot: WindowSessionSnapshot, to url: URL = defaultFileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: [.atomic])
    }
}

extension SidebarStore {
    /// The space a restored window shows: its saved space if it still exists,
    /// else its profile's last active space (or first space), else nil (the
    /// window starts on the key window's space, as a new window does).
    public func restoredSpaceID(saved spaceID: Space.ID?, profileID: Profile.ID?) -> Space.ID? {
        if let spaceID, space(withID: spaceID) != nil { return spaceID }
        guard let profileID, profile(withID: profileID) != nil else { return nil }
        let owner = owningProfileID(of: profileID)
        if let last = lastActiveSpaceByProfile[owner], space(withID: last) != nil { return last }
        return spaces(listedIn: owner).first?.id
    }
}

/// Coalesces a burst of signals (a window drag posts didMove for every
/// frame) into one `action` after `delay` without a new signal. Main thread.
public final class Debouncer {
    /// Runs the block after the delay; the returned closure cancels it.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    public let delay: TimeInterval
    private let schedule: Schedule
    private let action: () -> Void
    private var cancelPending: (() -> Void)?

    public static let mainQueue: Schedule = { delay, block in
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    public init(delay: TimeInterval, schedule: @escaping Schedule = Debouncer.mainQueue, action: @escaping () -> Void) {
        self.delay = delay
        self.schedule = schedule
        self.action = action
    }

    public var isPending: Bool { cancelPending != nil }

    public func signal() {
        cancelPending?()
        cancelPending = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            self.action()
        }
    }

    /// Runs a pending action now (quit).
    public func flush() {
        guard isPending else { return }
        cancel()
        action()
    }

    public func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}
