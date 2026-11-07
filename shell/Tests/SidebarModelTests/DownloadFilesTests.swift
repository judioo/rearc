import Foundation
import SidebarModel
import XCTest

/// Row icons and file checks off the main thread (docs/DOWNLOADS-AT-SCALE.md):
/// the cache the file service keeps, and which reads share a lane.
final class DownloadFilesTests: XCTestCase {
    // MARK: ExpiringCache

    func testCacheEntriesExpireAfterTheirTTL() {
        var cache = ExpiringCache<String, Int>(ttl: 30, capacity: 10)
        cache.insert(1, for: "/a", now: 100)
        XCTAssertEqual(cache.value(for: "/a", now: 129.9), 1)
        XCTAssertNil(cache.value(for: "/b", now: 100))
        XCTAssertNil(cache.value(for: "/a", now: 130), "expired at the TTL")
        XCTAssertNil(cache.lastValue(for: "/a"), "an expired read drops the entry")
        cache.insert(2, for: "/a", now: 200)
        XCTAssertNil(cache.value(for: "/a", now: 400))
        cache.insert(3, for: "/c", now: 0)
        XCTAssertEqual(cache.lastValue(for: "/c"), 3, "the last value stays readable without a fresh read")
    }

    func testCacheEvictsTheLeastRecentlyUsedPastItsCapacity() {
        var cache = ExpiringCache<Int, Int>(ttl: .infinity, capacity: 8)
        for key in 0 ..< 8 { cache.insert(key, for: key, now: 0) }
        for key in [0, 1, 2] { _ = cache.value(for: key, now: 0) }
        cache.insert(8, for: 8, now: 0)
        XCTAssertLessThanOrEqual(cache.count, 8)
        XCTAssertEqual(cache.count, 6, "evicts down to three quarters at once")
        for key in [0, 1, 2, 8] { XCTAssertEqual(cache.lastValue(for: key), key, "recently used \(key) stays") }
        for key in [3, 4, 5] { XCTAssertNil(cache.lastValue(for: key), "least recently used \(key) goes") }
        cache.removeValue(for: 8)
        XCTAssertNil(cache.lastValue(for: 8))
    }

    // MARK: FileLane

    func testLanesSeparateVolumesAndHomeFolders() {
        let home = "/Users/someone"
        XCTAssertEqual(FileLane.key(for: "/Volumes/Backup/a/b.zip", home: home), "/Volumes/Backup")
        XCTAssertEqual(FileLane.key(for: "/Volumes/NAS share/x", home: home), "/Volumes/NAS share")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/Downloads/a/b.pdf", home: home), "/Users/someone/Downloads")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/Desktop/c.png", home: home), "/Users/someone/Desktop")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/d", home: home),
                       "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/Library/CloudStorage/Dropbox/e", home: home), "/Users/someone/Library/CloudStorage/Dropbox")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/Library/Caches/f", home: home), "/Users/someone/Library/Caches")
        XCTAssertEqual(FileLane.key(for: "/Users/someone/file.txt", home: home), "/Users/someone/file.txt")
        XCTAssertEqual(FileLane.key(for: "/Users/other/Downloads/g", home: home), "/Users/other")
        XCTAssertEqual(FileLane.key(for: "/private/tmp/x/y", home: home), "/private/tmp")
        XCTAssertEqual(FileLane.key(for: "/Users/someoneelse/Downloads/h", home: home), "/Users/someoneelse", "a prefix of the home name is not home")
    }
}
