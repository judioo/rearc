import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Row icons and file checks off the main thread (docs/DOWNLOADS-AT-SCALE.md):
/// the service against a reader that hangs like a sleeping or protected volume.
@MainActor
final class DownloadFileServiceTests: XCTestCase {
    /// Files by path; a path in `hanging` blocks its read until `release()`.
    private final class FakeFiles: DownloadFileReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [String: FileState] = [:]
        private var _hanging: Set<String> = []
        private var _reads: [String] = []
        private var _icons = 0
        private var _active: [String: Int] = [:]
        private var _maxActive: [String: Int] = [:]
        private let gate = DispatchSemaphore(value: 0)

        func set(_ path: String, _ state: FileState) { lock.withLock { _states[path] = state } }
        func hang(_ path: String) { lock.withLock { _ = _hanging.insert(path) } }
        func release(_ count: Int = 64) {
            lock.withLock { _hanging = [] }
            for _ in 0 ..< count { gate.signal() }
        }

        var reads: [String] { lock.withLock { _reads } }
        var icons: Int { lock.withLock { _icons } }
        func maxActive(lane: String) -> Int { lock.withLock { _maxActive[lane] ?? 0 } }

        func state(atPath path: String) -> FileState {
            let lane = FileLane.key(for: path, home: "/Users/test")
            let hangs = lock.withLock { () -> Bool in
                _reads.append(path)
                _active[lane, default: 0] += 1
                _maxActive[lane] = max(_maxActive[lane] ?? 0, _active[lane]!)
                return _hanging.contains(path)
            }
            if hangs { _ = gate.wait(timeout: .now() + 10) }
            return lock.withLock {
                _active[lane, default: 1] -= 1
                return _states[path] ?? .missing
            }
        }

        func icon(atPath path: String, pixels: Int) -> CGImage? {
            lock.withLock { _icons += 1 }
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return context?.makeImage()
        }

        func thumbnail(atPath path: String, pixels: Int, timeout: TimeInterval) -> CGImage? { nil }
    }

    private var now: TimeInterval = 1_000

    private func service(_ files: FakeFiles, timeout: TimeInterval = 5, laneQueueLimit: Int = 64) -> DownloadFileService {
        DownloadFileService(reader: files, timeout: timeout, coolOff: 30, stateTTL: 30, laneQueueLimit: laneQueueLimit,
                            home: "/Users/test", clock: { [unowned self] in self.now })
    }

    private func file(_ seconds: TimeInterval) -> FileState {
        FileState(exists: true, modified: Date(timeIntervalSince1970: seconds), size: 10)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testARowShowsTheTypeIconAtOnceAndReadsItsFileOnce() async {
        let files = FakeFiles()
        files.set("/tmp/a.pdf", file(1))
        let service = service(files)
        XCTAssertNotNil(service.placeholder(forFileName: "a.pdf"))
        XCTAssertNil(service.cachedImage(atPath: "/tmp/a.pdf", pixels: 60, kind: .icon))
        XCTAssertEqual(service.readsStarted, 0, "the placeholder and the cache read no file")

        let image = await service.image(atPath: "/tmp/a.pdf", pixels: 60, kind: .icon)
        XCTAssertNotNil(image)
        XCTAssertNotNil(service.cachedImage(atPath: "/tmp/a.pdf", pixels: 60, kind: .icon))
        _ = await service.image(atPath: "/tmp/a.pdf", pixels: 60, kind: .icon)
        XCTAssertEqual(files.reads, ["/tmp/a.pdf"], "the second ask is a cache hit")
        XCTAssertEqual(files.icons, 1)
        XCTAssertEqual(service.cachedState(atPath: "/tmp/a.pdf"), file(1))
    }

    func testTheImageKeyIsThePathAndItsModificationDate() async {
        let files = FakeFiles()
        files.set("/tmp/a.png", file(1))
        let service = service(files)
        _ = await service.image(atPath: "/tmp/a.png", pixels: 60, kind: .icon)

        // After the state's TTL the file is checked again; the same date keeps the icon.
        now += 31
        let same = await service.image(atPath: "/tmp/a.png", pixels: 60, kind: .icon)
        XCTAssertNotNil(same)
        XCTAssertEqual(files.reads.count, 2)
        XCTAssertEqual(files.icons, 1, "unchanged file: no new icon")

        // A new date draws a new one; until the check, the old icon no longer counts as current.
        files.set("/tmp/a.png", file(2))
        now += 31
        XCTAssertNotNil(service.cachedImage(atPath: "/tmp/a.png", pixels: 60, kind: .icon), "the last state still has the old date")
        _ = await service.image(atPath: "/tmp/a.png", pixels: 60, kind: .icon)
        XCTAssertEqual(files.icons, 2)
        XCTAssertNotNil(service.cachedImage(atPath: "/tmp/a.png", pixels: 60, kind: .icon))

        // Each size and kind is its own entry.
        _ = await service.image(atPath: "/tmp/a.png", pixels: 80, kind: .thumbnail)
        XCTAssertEqual(files.icons, 3, "a thumbnail that QuickLook cannot make falls back to the icon")
    }

    func testAMissingFileKeepsTheTypeIcon() async {
        let files = FakeFiles()
        let service = service(files)
        let image = await service.image(atPath: "/tmp/gone.zip", pixels: 60, kind: .icon)
        XCTAssertNil(image)
        XCTAssertEqual(files.icons, 0)
        let state = await service.state(atPath: "/tmp/gone.zip")
        XCTAssertEqual(state?.exists, false)
        XCTAssertEqual(files.reads.count, 1, "the state is cached for its TTL")
        let empty = await service.image(atPath: "", pixels: 60, kind: .icon)
        XCTAssertNil(empty)
    }

    func testRowsAskingForTheSameFileShareOneRead() async {
        let files = FakeFiles()
        files.set("/tmp/b.mov", file(1))
        files.hang("/tmp/b.mov")
        let service = service(files)
        let first = Task { await service.image(atPath: "/tmp/b.mov", pixels: 60, kind: .icon) }
        let second = Task { await service.image(atPath: "/tmp/b.mov", pixels: 60, kind: .icon) }
        await waitUntil { files.reads.count == 1 }
        files.release()
        let images = await [first.value, second.value]
        XCTAssertEqual(images.compactMap { $0 }.count, 2)
        XCTAssertEqual(files.reads.count, 1)
    }

    func testASlowReadTimesOutToTheTypeIconAndRestsItsLane() async {
        let files = FakeFiles()
        files.set("/Volumes/Slow/a.dmg", file(1))
        files.set("/Volumes/Slow/b.dmg", file(1))
        files.set("/tmp/fast.txt", file(1))
        files.hang("/Volumes/Slow/a.dmg")
        let service = service(files, timeout: 0.1)

        let started = Date()
        let slow = await service.image(atPath: "/Volumes/Slow/a.dmg", pixels: 60, kind: .icon)
        XCTAssertNil(slow, "the type icon stays")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the caller waits for the timeout, not the volume")

        // The lane rests: another file there gets no read at all.
        let resting = await service.image(atPath: "/Volumes/Slow/b.dmg", pixels: 60, kind: .icon)
        XCTAssertNil(resting)
        let restingState = await service.state(atPath: "/Volumes/Slow/b.dmg")
        XCTAssertNil(restingState, "unknown, not missing")
        XCTAssertEqual(files.reads, ["/Volumes/Slow/a.dmg"])

        // Other lanes are not held up.
        let fast = await service.image(atPath: "/tmp/fast.txt", pixels: 60, kind: .icon)
        XCTAssertNotNil(fast)

        // The hung read returns: its answer is kept, and the lane rests for the cool-off.
        files.release()
        await waitUntil { service.cachedState(atPath: "/Volumes/Slow/a.dmg") != nil }
        XCTAssertNotNil(service.cachedImage(atPath: "/Volumes/Slow/a.dmg", pixels: 60, kind: .icon))
        now += 29
        let stillResting = await service.image(atPath: "/Volumes/Slow/b.dmg", pixels: 60, kind: .icon)
        XCTAssertNil(stillResting)
        now += 2
        let rested = await service.image(atPath: "/Volumes/Slow/b.dmg", pixels: 60, kind: .icon)
        XCTAssertNotNil(rested)
        XCTAssertEqual(files.reads.filter { $0.hasPrefix("/Volumes/Slow/") }.count, 2)
    }

    func testAHungLaneHoldsOneThreadAndQueuesTheRest() async {
        let files = FakeFiles()
        let paths = (0 ..< 10).map { "/Users/test/Downloads/f\($0).zip" }
        for path in paths {
            files.set(path, file(1))
            files.hang(path)
        }
        let service = service(files)
        let tasks = paths.map { path in Task { await service.image(atPath: path, pixels: 60, kind: .icon) } }
        await waitUntil { files.reads.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files.reads.count, 1, "one read at a time on the lane")
        files.release()
        for task in tasks { _ = await task.value }
        XCTAssertEqual(Set(files.reads), Set(paths))
        XCTAssertEqual(files.maxActive(lane: "/Users/test/Downloads"), 1)
    }

    func testARowThatScrolledAwayLeavesTheQueue() async {
        let files = FakeFiles()
        files.set("/private/tmp/first", file(1))
        files.set("/private/tmp/second", file(1))
        files.hang("/private/tmp/first")
        let service = service(files)
        let first = Task { await service.image(atPath: "/private/tmp/first", pixels: 60, kind: .icon) }
        await waitUntil { files.reads.count == 1 }
        let second = Task { await service.image(atPath: "/private/tmp/second", pixels: 60, kind: .icon) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        second.cancel()
        let cancelled = await second.value
        XCTAssertNil(cancelled)
        files.release()
        _ = await first.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files.reads, ["/private/tmp/first"], "a cancelled read that had not started never runs")
    }

    func testAFullLaneDropsItsOldestWaitingRead() async {
        let files = FakeFiles()
        for name in ["running", "a", "b", "c"] {
            files.set("/private/tmp/\(name)", file(1))
        }
        files.hang("/private/tmp/running")
        let service = service(files, laneQueueLimit: 2)
        let running = Task { await service.image(atPath: "/private/tmp/running", pixels: 60, kind: .icon) }
        await waitUntil { files.reads.count == 1 }
        let a = Task { await service.image(atPath: "/private/tmp/a", pixels: 60, kind: .icon) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let b = Task { await service.image(atPath: "/private/tmp/b", pixels: 60, kind: .icon) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let c = Task { await service.image(atPath: "/private/tmp/c", pixels: 60, kind: .icon) }
        let dropped = await a.value
        XCTAssertNil(dropped, "the oldest waiting read is dropped")
        files.release()
        let kept = await [running.value, b.value, c.value]
        XCTAssertEqual(kept.compactMap { $0 }.count, 3)
        XCTAssertFalse(files.reads.contains("/private/tmp/a"))
    }
}
