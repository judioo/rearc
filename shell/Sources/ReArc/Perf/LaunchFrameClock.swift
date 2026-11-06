import AppKit
import CoreVideo
import Foundation

/// The first display refresh after a commit, read off the main thread.
///
/// The early window (ABI 1.45 `early_window`) is committed while Chromium
/// still holds the main thread, so `PresentationProbe`'s display link, which
/// runs on the main run loop, cannot fire until `ready`. A CVDisplayLink calls
/// back on its own thread instead and gives the same reading as the probe:
/// the output (presentation) time of the first refresh whose callback comes
/// after the commit. Times are seconds on `CACurrentMediaTime`'s clock.
final class LaunchFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var link: CVDisplayLink?
    private var committed = 0.0
    private var result: Double?

    /// Seconds of a CVTimeStamp host time (mach_absolute_time ticks).
    static func seconds(hostTime: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Watches the refreshes of `screen` (the main display when nil) for the
    /// first one after `committed`. False when no display link could start.
    @discardableResult
    func start(after committed: Double, screen: NSScreen?) -> Bool {
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let link = created else { return false }
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(number.uint32Value))
        }
        lock.withLock {
            self.committed = committed
            self.link = link
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, now, output, _, _ in
            self?.refresh(now: Self.seconds(hostTime: now.pointee.hostTime),
                          output: Self.seconds(hostTime: output.pointee.hostTime))
            return kCVReturnSuccess
        }
        return CVDisplayLinkStart(link) == kCVReturnSuccess
    }

    private func refresh(now: Double, output: Double) {
        let finished: CVDisplayLink? = lock.withLock {
            guard result == nil, now >= committed else { return nil }
            result = output
            defer { link = nil }
            return link
        }
        guard let finished else { return }
        done.signal()
        // Not from inside the link's own callback.
        DispatchQueue.global(qos: .utility).async { CVDisplayLinkStop(finished) }
    }

    /// The presentation time, waiting up to `timeout` seconds for it.
    func presented(timeout: TimeInterval) -> Double? {
        if let value = lock.withLock({ result }) { return value }
        _ = done.wait(timeout: .now() + timeout)
        return lock.withLock { result }
    }
}
