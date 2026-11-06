import AppKit
import CoreGraphics
import Foundation

/// The window server's list of an app's on-screen windows (no pixels, no
/// titles used), front to back.
struct WindowInfo: Equatable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    /// Points, top-left origin (CGWindowList's space).
    var bounds: CGRect
}

enum WindowList {
    static func onScreen(pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            return WindowInfo(id: CGWindowID(id), pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// Ordinary (layer 0) windows of the app.
    static func normal(pid: pid_t) -> [WindowInfo] { onScreen(pid: pid).filter { $0.layer == 0 } }

    /// The frontmost browser window: layer 0 and at least 800 × 500 pt, which
    /// leaves out Little Arc, popovers and panels.
    static func browserWindow(pid: pid_t) -> WindowInfo? { normal(pid: pid).first(where: isBrowserSized) }

    static func isBrowserSized(_ window: WindowInfo) -> Bool { window.bounds.width >= 800 && window.bounds.height >= 500 }

    /// Polls until a layer-0 window appears that is not in `before` (or, with
    /// `closing`, until `closing` leaves the list). Returns the host time of
    /// the first poll that saw it and the mean poll period, or nil on timeout.
    static func waitForChange(pid: pid_t, before: Set<CGWindowID>, closing: CGWindowID?, timeout: Double)
        -> (time: Double, window: CGWindowID?, period: Double)? {
        let start = HostClock.now
        var polls = 0
        while HostClock.now - start < timeout {
            let ids = Set(normal(pid: pid).map(\.id))
            polls += 1
            let now = HostClock.now
            if let closing {
                if !ids.contains(closing) { return (now, nil, (now - start) / Double(polls)) }
            } else if let opened = ids.subtracting(before).first {
                return (now, opened, (now - start) / Double(polls))
            }
            usleep(500)
        }
        return nil
    }
}

enum Display {
    /// The refresh rate of the screen showing most of `bounds` (CG top-left points).
    static func refreshHz(for bounds: CGRect) -> Int {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        CGGetDisplaysWithRect(bounds, 8, &displays, &count)
        let id = count > 0 ? displays[0] : CGMainDisplayID()
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if let fps = screen?.maximumFramesPerSecond, fps > 0 { return fps }
        let rate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return rate > 0 ? Int(rate.rounded()) : 60
    }

    static func name(for bounds: CGRect) -> String {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        CGGetDisplaysWithRect(bounds, 8, &displays, &count)
        let id = count > 0 ? displays[0] : CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName ?? "display \(id)"
    }
}
