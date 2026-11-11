import XCTest
@testable import SidebarModel

/// Security RC-0.1.0-544 F-02: Settings reports whether lists were downloaded, not whether a key is configured.
final class SafeBrowsingStatusTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-sb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ name: String, bytes: Int = 16, modified: Date = Date()) throws {
        let folder = dir.appendingPathComponent(SafeBrowsingStatus.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testNoKeyIsUnavailableWhateverIsOnDisk() throws {
        try store("UrlSoceng.store")
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: false, userDataDir: dir, engineRunning: 3600), .unavailable)
    }

    func testAKeyWithoutListsIsNotProtection() {
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 30), .waitingForLists)
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 11 * 60), .notUpdating)
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: true, userDataDir: nil, engineRunning: 11 * 60), .notUpdating)
        XCTAssertFalse(SafeBrowsingStatus.waitingForLists.isProtecting)
    }

    func testEmptyOrForeignFilesAreNotLists() throws {
        try store("UrlSoceng.store", bytes: 0)
        try store("notes.txt")
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 11 * 60), .notUpdating)
    }

    func testRecentListsAreActiveAndOldOnesStaleOnceTheEngineHadTimeToUpdate() throws {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 24 * 3600)
        try store("UrlMalware.store", modified: old)
        // Just launched after a week away: the first update has not run yet.
        XCTAssertEqual(SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 60, now: now),
                       .active(lastUpdate: SafeBrowsingStatus.newestStore(in: dir.appendingPathComponent("Safe Browsing"))!))
        guard case .stale = SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 11 * 60, now: now) else {
            return XCTFail("old lists after the grace period are stale")
        }
        try store("UrlSoceng.store", modified: now)
        let status = SafeBrowsingStatus.evaluate(configured: true, userDataDir: dir, engineRunning: 11 * 60, now: now)
        XCTAssertTrue(status.isProtecting, "\(status)")
    }
}
