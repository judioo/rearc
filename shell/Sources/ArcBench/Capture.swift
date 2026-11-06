import ArcBenchCore
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures ONE window with ScreenCaptureKit (a desktop-independent window
/// filter: never the display, never another app) and reduces every frame to
/// numbers in memory: per region, the changed fraction against the pre-input
/// baseline and against the previous frame, stamped with the frame's own
/// display time. Pixels are dropped as soon as the next frame arrives, unless
/// `keepFrames` names a directory for this window's frames.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let regions: [String: Region]
    let diff: DiffSettings
    let keepFrames: URL?

    private let queue = DispatchQueue(label: "rearc.arc-vs-rearc.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var previous: Frame?
    private var baseline: Frame?
    private var samples: [String: [FrameSample]] = [:]
    /// Frame-to-frame changes over the whole window, kept for the pre-input quiet check.
    private var recent: [FrameSample] = []
    private var stopError: Error?
    private var keepLabel: String?
    private var kept = 0
    private(set) var framesSeen = 0

    init(windowID: CGWindowID, regions: [String: Region], diff: DiffSettings, keepFrames: URL?) {
        self.windowID = windowID
        self.regions = regions
        self.diff = diff
        self.keepFrames = keepFrames
    }

    func start(refreshHz: Int, scale: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw Failure("window \(windowID) is not shareable (off screen?)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(64, Int((window.frame.width * scale).rounded()))
        config.height = max(64, Int((window.frame.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, refreshHz)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 6
        config.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// The last frame becomes the baseline; samples start empty.
    /// `keep` labels this measurement's frames when keeping frames.
    func arm(keep label: String? = nil) {
        lock.withLock {
            baseline = previous
            samples = [:]
            keepLabel = label
            kept = 0
        }
    }

    func disarm() { lock.withLock { keepLabel = nil } }

    var hasFrame: Bool { lock.withLock { previous != nil } }

    /// The newest frame (in memory; for the after-scenario check).
    var latestFrame: Frame? { lock.withLock { previous } }

    func samples(_ region: String) -> [FrameSample] { lock.withLock { samples[region] ?? [] } }

    func isQuiet(window: Double, areaThreshold: Double) -> Bool {
        let recent = lock.withLock { self.recent }
        return Detector.isQuiet(recent, now: HostClock.now, window: window, areaThreshold: areaThreshold)
    }

    var failure: Error? { lock.withLock { stopError } }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let displayTime = info[.displayTime] as? UInt64,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = Self.frame(pixelBuffer) else { return }
        let time = HostClock.seconds(displayTime)
        lock.lock()
        defer { lock.unlock() }
        framesSeen += 1
        if let previous {
            let whole = FrameDiff.changedFraction(previous, frame, settings: diff)
            recent.append(FrameSample(time: time, fromBaseline: 0, fromPrevious: whole))
            if recent.count > 512 { recent.removeFirst(recent.count - 256) }
            if let baseline {
                for (name, region) in regions {
                    let fromPrevious = region == .window ? whole : FrameDiff.changedFraction(previous, frame, in: region, settings: diff)
                    samples[name, default: []].append(FrameSample(
                        time: time, fromBaseline: FrameDiff.changedFraction(baseline, frame, in: region, settings: diff), fromPrevious: fromPrevious))
                }
            }
        }
        previous = frame
        if let keepFrames, let keepLabel {
            kept += 1
            Self.writePNG(frame, to: keepFrames.appendingPathComponent(String(format: "%@-%03d.png", keepLabel, kept)))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { stopError = error }
    }

    // MARK: Pixels

    private static func frame(_ buffer: CVPixelBuffer) -> Frame? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
        return Frame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
    }

    /// `--keep-frames` only: this window's frame as a PNG.
    private static func writePNG(_ frame: Frame, to url: URL) {
        let data = Data(frame.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
