import AppKit
import ImageIO
import SidebarModel

/// Keeps one page's toolbar colour (`PageToolbarColorState`): the engine
/// reports theme colours and documents; the tracker samples the top edge
/// when the page declares none. Samples are rare (a new document, the end of
/// its load, a settled scroll, the page coming on screen), the PNG is a few
/// rows tall, and it is decoded off the main thread. `onChange` runs only
/// when the colour changes. Main thread only, like the engines that own it.
final class PageColorTracker {
    private(set) var state = PageToolbarColorState()
    private(set) var color: PageColor?
    var onChange: (PageColor?) -> Void = { _ in }

    /// The top strip as PNG, or nil when it can't be taken now (hidden, busy).
    private let capture: () async -> Data?
    /// The page is on screen, is a web page, and the engine can capture its edge.
    private let canSample: () -> Bool
    private var pending: Task<Void, Never>?
    private var sampling = false
    private var sampleAgain = false

    init(capture: @escaping () async -> Data?, canSample: @escaping () -> Bool) {
        self.capture = capture
        self.canSample = canSample
    }

    func documentChanged(to generation: UInt64, isWebPage: Bool) {
        state.documentChanged(to: generation)
        if !isWebPage { state.clear(); pending?.cancel() }
        publish()
        // The header is usually painted well before the load ends.
        if isWebPage { schedule(after: .milliseconds(800)) }
    }

    func themeColorChanged(_ themeColor: PageColor?) {
        state.setThemeColor(themeColor)
        if themeColor != nil { pending?.cancel() }
        publish()
        if themeColor == nil { schedule(after: .milliseconds(800)) }
    }

    /// The load finished or a scroll settled: what is at the top may have changed.
    func pageSettled() {
        schedule(after: .milliseconds(250), force: true)
    }

    /// A toolbar shows the page: sample once if this document has none yet.
    func pageShown() {
        if state.needsEdgeSample { schedule(after: .milliseconds(100)) }
    }

    func reset() {
        pending?.cancel()
        state = PageToolbarColorState()
        publish()
    }

    private func schedule(after delay: Duration, force: Bool = false) {
        guard state.themeColor == nil, force || state.needsEdgeSample,
              ToolbarPageColorPreference.isEnabled(in: .standard) else { return }
        if sampling { sampleAgain = true; return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sample()
        }
    }

    private func sample() async {
        guard canSample(), state.themeColor == nil else { return }
        sampling = true
        let document = state.document
        let png = await capture()
        sampling = false
        if let png {
            let color = await Task.detached(priority: .utility) { PageEdgeImage.dominantColor(png: png) }.value
            if state.themeColor == nil {
                state.setEdgeColor(color, document: document)
                publish()
            }
        }
        if sampleAgain {
            sampleAgain = false
            schedule(after: .milliseconds(250), force: true)
        }
    }

    private func publish() {
        let next = state.color
        guard next != color else { return }
        color = next
        onChange(next)
    }
}

/// Decodes the top-strip PNG into RGBA and asks `PageEdgeSample` for its colour.
enum PageEdgeImage {
    nonisolated static func dominantColor(png: Data) -> PageColor? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 1 << 22,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // Opaque over white: a transparent page edge reads as the white Chromium paints.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // noneSkipLast leaves the fourth byte undefined; the sampler reads it as alpha.
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        return PageEdgeSample.dominantColor(rgba: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}

/// One app-wide scroll-wheel monitor. Each event only records its window,
/// point and time; 0.3 s after the last one the page under that point is told
/// its scroll settled (a sticky header may now sit at the top). Main thread only.
final class PageScrollSettleWatcher {
    static let shared = PageScrollSettleWatcher()
    static let settleDelay: TimeInterval = 0.3

    private struct Subscriber {
        weak var view: NSView?
        let settled: () -> Void
    }
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var monitor: Any?
    private var last: (window: NSWindow, point: NSPoint, time: TimeInterval)?
    private var timerArmed = false

    /// `view` is the page's host view; `settled` runs when a scroll over it settles.
    func watch(_ view: NSView, settled: @escaping () -> Void) {
        subscribers[ObjectIdentifier(view)] = Subscriber(view: view, settled: settled)
        installIfNeeded()
    }

    func unwatch(_ view: NSView) {
        subscribers[ObjectIdentifier(view)] = nil
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            PageScrollSettleWatcher.shared.record(event)
            return event
        }
    }

    private func record(_ event: NSEvent) {
        guard let window = event.window else { return }
        last = (window, event.locationInWindow, event.timestamp)
        guard !timerArmed else { return }
        timerArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in self?.check() }
    }

    private func check() {
        timerArmed = false
        guard let last else { return }
        let idle = ProcessInfo.processInfo.systemUptime - last.time
        if idle < Self.settleDelay {
            timerArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.settleDelay - idle)) { [weak self] in self?.check() }
            return
        }
        self.last = nil
        subscribers = subscribers.filter { $0.value.view != nil }
        for subscriber in subscribers.values {
            guard let view = subscriber.view, view.window === last.window,
                  view.bounds.contains(view.convert(last.point, from: nil)) else { continue }
            subscriber.settled()
        }
    }
}
