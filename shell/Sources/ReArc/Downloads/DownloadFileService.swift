import AppKit
import QuickLookThumbnailing
import SidebarModel
import UniformTypeIdentifiers

/// The blocking file reads behind `DownloadFileService`, called on a lane's
/// queue and never on the main thread. Tests swap in a double that hangs
/// like a sleeping volume.
protocol DownloadFileReading: Sendable {
    func state(atPath path: String) -> FileState
    /// The file's own icon, drawn at `pixels` square.
    func icon(atPath path: String, pixels: Int) -> CGImage?
    /// A QuickLook thumbnail framed like an icon, or nil after `timeout`.
    func thumbnail(atPath path: String, pixels: Int, timeout: TimeInterval) -> CGImage?
}

struct SystemDownloadFiles: DownloadFileReading {
    func state(atPath path: String) -> FileState {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return FileState(exists: true, isDirectory: info.st_mode & S_IFMT == S_IFDIR, modified: modified, size: Int64(info.st_size))
    }

    func icon(atPath path: String, pixels: Int) -> CGImage? {
        // The workspace's icon loads its images lazily: draw it here so the
        // main thread never resolves it (that is where the reads would block).
        Self.render(NSWorkspace.shared.icon(forFile: path), pixels: pixels)
    }

    func thumbnail(atPath path: String, pixels: Int, timeout: TimeInterval) -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: pixels, height: pixels),
                                                   scale: 1, representationTypes: [.icon, .thumbnail])
        request.iconMode = true
        let done = DispatchSemaphore(value: 0)
        let result = ThumbnailResult()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            result.image = representation?.cgImage
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return result.image
    }

    private final class ThumbnailResult: @unchecked Sendable {
        var image: CGImage?
    }

    static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Icons, QuickLook thumbnails and file checks for the downloads tray, the
/// Library's Downloads page and the quick view, read off the main thread.
///
/// - A row shows its type's icon at once (`placeholder`, no file access) and
///   swaps in the real one when `image` returns it.
/// - Reads run on `FileLane` queues, one file at a time per lane, so a hung
///   volume holds one thread. A read that takes longer than `timeout` gives
///   its callers nil (the type icon stays) and rests its lane for `coolOff`:
///   until then the lane answers nil at once instead of queueing more reads,
///   and its queued reads are dropped.
/// - States are cached for `stateTTL`; images by path, modification date,
///   size and kind, so a changed file gets a new icon.
/// - A caller whose task is cancelled (its row scrolled away) leaves its
///   read; a read nobody waits for and that has not started is dropped.
@MainActor
final class DownloadFileService {
    static let shared = DownloadFileService()

    enum ImageKind: Hashable, Sendable {
        case icon, thumbnail
    }

    /// QuickLook thumbnails are capped at this many pixels a side.
    static let maxThumbnailPixels = 256

    private struct ImageSlot: Hashable {
        var path: String
        var pixels: Int
        var kind: ImageKind
    }

    private struct CachedImage {
        var modified: Date?
        var image: NSImage
    }

    private struct JobKey: Hashable {
        var path: String
        /// nil reads only the state.
        var kind: ImageKind?
        var pixels: Int
    }

    private struct Outcome {
        var state: FileState
        var image: CGImage?
    }

    private final class Job {
        var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]
        var started: TimeInterval?
        var timedOut = false
        /// Skip drawing the image when the file still has this date.
        var unchangedSince: Date?
    }

    private final class Lane {
        let queue: DispatchQueue
        var pending: [JobKey] = []
        var running: JobKey?
        var restingUntil: TimeInterval = -.infinity

        init(_ label: String) {
            queue = DispatchQueue(label: "net.rearc.download-files.\(label)", qos: .utility)
        }
    }

    let timeout: TimeInterval
    let coolOff: TimeInterval
    let laneQueueLimit: Int
    let maxLanes: Int
    private let reader: DownloadFileReading
    private let clock: () -> TimeInterval
    private let home: String
    private var states: ExpiringCache<String, FileState>
    private var images = ExpiringCache<ImageSlot, CachedImage>(ttl: .infinity, capacity: 512)
    private var typeIcons: [String: NSImage] = [:]
    private var lanes: [String: Lane] = [:]
    private var jobs: [JobKey: Job] = [:]
    /// Reads started, for tests and logs.
    private(set) var readsStarted = 0

    init(reader: DownloadFileReading = SystemDownloadFiles(), timeout: TimeInterval = 2, coolOff: TimeInterval = 30,
         stateTTL: TimeInterval = 30, laneQueueLimit: Int = 64, maxLanes: Int = 8, home: String = NSHomeDirectory(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.timeout = timeout
        self.coolOff = coolOff
        self.laneQueueLimit = laneQueueLimit
        self.maxLanes = maxLanes
        self.home = home
        self.clock = clock
        states = ExpiringCache(ttl: stateTTL, capacity: 4_096)
    }

    // MARK: Without file access

    /// The icon for the file's type, by its extension: what a row shows
    /// until the file's own icon arrives, and for files that are gone.
    func placeholder(forFileName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let icon = typeIcons[ext] { return icon }
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let icon = NSWorkspace.shared.icon(for: type ?? .data)
        typeIcons[ext] = icon
        return icon
    }

    /// The last state read for `path`, fresh or not; nil when never read.
    func cachedState(atPath path: String) -> FileState? {
        states.lastValue(for: path)
    }

    /// The real image already read for `path` (while the file's last known
    /// date matches), or nil.
    func cachedImage(atPath path: String, pixels: Int, kind: ImageKind) -> NSImage? {
        guard let cached = images.lastValue(for: ImageSlot(path: path, pixels: Self.pixels(pixels, kind), kind: kind)) else { return nil }
        guard let state = states.lastValue(for: path) else { return cached.image }
        return state.exists && state.modified == cached.modified ? cached.image : nil
    }

    // MARK: Reads

    /// The file's state, read off the main thread (cached for the TTL); nil
    /// when its lane is resting or the read timed out or was cancelled.
    func state(atPath path: String) async -> FileState? {
        guard !path.isEmpty else { return .missing }
        if let state = states.value(for: path, now: clock()) { return state }
        return await request(JobKey(path: path, kind: nil, pixels: 0))?.state
    }

    /// The file's own icon or thumbnail at `pixels` square, read off the
    /// main thread; nil keeps the type icon (no file, a resting lane, a
    /// timeout or cancellation).
    func image(atPath path: String, pixels: Int, kind: ImageKind) async -> NSImage? {
        guard !path.isEmpty else { return nil }
        let pixels = Self.pixels(pixels, kind)
        let slot = ImageSlot(path: path, pixels: pixels, kind: kind)
        let cached = images.value(for: slot, now: clock())
        if let state = states.value(for: path, now: clock()) {
            guard state.exists else { return nil }
            if let cached, cached.modified == state.modified { return cached.image }
        }
        let key = JobKey(path: path, kind: kind, pixels: pixels)
        guard let outcome = await request(key, unchangedSince: cached?.modified) else { return nil }
        guard outcome.state.exists else { return nil }
        // `finish` stored a new image; a file that kept its date keeps the one held.
        return images.lastValue(for: slot).flatMap { $0.modified == outcome.state.modified ? $0.image : nil }
    }

    /// Starts reads for the rows about to show (the quick view's), without waiting.
    func prefetch(paths: [String], pixels: Int, kind: ImageKind) {
        for path in paths where cachedImage(atPath: path, pixels: pixels, kind: kind) == nil {
            Task { _ = await image(atPath: path, pixels: pixels, kind: kind) }
        }
    }

    private static func pixels(_ pixels: Int, _ kind: ImageKind) -> Int {
        kind == .thumbnail ? min(max(pixels, 1), maxThumbnailPixels) : max(pixels, 1)
    }

    // MARK: Lanes

    private func lane(for path: String) -> Lane {
        var name = FileLane.key(for: path, home: home)
        if lanes[name] == nil, lanes.count >= maxLanes { name = "overflow" }
        if let lane = lanes[name] { return lane }
        let lane = Lane(String(lanes.count))
        lanes[name] = lane
        return lane
    }

    private func request(_ key: JobKey, unchangedSince: Date? = nil) async -> Outcome? {
        let lane = lane(for: key.path)
        guard lane.restingUntil <= clock() else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome?, Never>) in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                let job: Job
                if let existing = jobs[key] {
                    job = existing
                } else {
                    job = Job()
                    job.unchangedSince = unchangedSince
                    jobs[key] = job
                    lane.pending.append(key)
                    if lane.pending.count > laneQueueLimit { drop(lane.pending.removeFirst()) }
                }
                job.waiters[id] = continuation
                pump(lane)
            }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.leave(id, key) } }
        }
    }

    /// A caller went away: it gets nil, and a read no one waits for is
    /// dropped if it has not started.
    private func leave(_ id: UUID, _ key: JobKey) {
        guard let job = jobs[key], let continuation = job.waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        guard job.waiters.isEmpty, job.started == nil else { return }
        jobs[key] = nil
        let lane = lane(for: key.path)
        lane.pending.removeAll { $0 == key }
    }

    private func drop(_ key: JobKey) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        for continuation in job.waiters.values { continuation.resume(returning: nil) }
    }

    private func pump(_ lane: Lane) {
        guard lane.running == nil, !lane.pending.isEmpty else { return }
        let key = lane.pending.removeFirst()
        guard let job = jobs[key] else { return pump(lane) }
        let started = clock()
        lane.running = key
        job.started = started
        readsStarted += 1
        let reader = reader, timeout = timeout, unchangedSince = job.unchangedSince
        lane.queue.async {
            let state = reader.state(atPath: key.path)
            var image: CGImage?
            if let kind = key.kind, state.exists, unchangedSince == nil || state.modified != unchangedSince {
                switch kind {
                case .icon: image = reader.icon(atPath: key.path, pixels: key.pixels)
                case .thumbnail:
                    image = reader.thumbnail(atPath: key.path, pixels: key.pixels, timeout: timeout)
                        ?? reader.icon(atPath: key.path, pixels: key.pixels)
                }
            }
            let outcome = Outcome(state: state, image: image)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(key, outcome) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { self.watchdog(key, started: started) }
        }
    }

    /// The read is still running after `timeout`: its callers keep the type
    /// icon, and the lane rests (queued reads dropped) until it returns.
    private func watchdog(_ key: JobKey, started: TimeInterval) {
        let lane = lane(for: key.path)
        guard lane.running == key, let job = jobs[key], job.started == started else { return }
        job.timedOut = true
        lane.restingUntil = .infinity
        for continuation in job.waiters.values { continuation.resume(returning: nil) }
        job.waiters = [:]
        let queued = lane.pending
        lane.pending = []
        queued.forEach(drop)
    }

    private func finish(_ key: JobKey, _ outcome: Outcome) {
        let lane = lane(for: key.path)
        let now = clock()
        states.insert(outcome.state, for: key.path, now: now)
        if let kind = key.kind, let image = outcome.image {
            images.insert(CachedImage(modified: outcome.state.modified, image: NSImage(cgImage: image, size: .zero)),
                          for: ImageSlot(path: key.path, pixels: key.pixels, kind: kind), now: now)
        }
        if let job = jobs.removeValue(forKey: key) {
            if job.timedOut { lane.restingUntil = now + coolOff }
            for continuation in job.waiters.values { continuation.resume(returning: outcome) }
        }
        if lane.running == key { lane.running = nil }
        pump(lane)
    }
}
