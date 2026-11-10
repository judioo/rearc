import CoreGraphics
@testable import Onboarding
import SidebarModel
import SQLite3
import XCTest

final class Act2Tests: XCTestCase {
    let A = Act2Layout(size: CGSize(width: 1440, height: 900))

    func testChoicesShapeWhatComesOver() {
        let log = Act2Log.demo(start: 0)
        var all = ImportSource.demo.map(\.stats).reduce(ImportStats(), +)
        all.passwords = 0
        XCTAssertEqual(log.totals(at: 0), all)
        let chosen = log.totals(at: log.choice!.time)
        XCTAssertEqual(chosen.extensions, 0, "extensions were switched off")
        XCTAssertEqual(chosen.bookmarks, all.bookmarks - ImportSource.demo[3].stats.bookmarks, "Brave was left behind")
        XCTAssertEqual(chosen.spaces, all.spaces)
    }

    func testCountsTickUpAndLandOnTheTotals() {
        let log = Act2Log.demo(start: 0)
        let start = log.flowStart!
        XCTAssertEqual(Act2Timeline.frame(log, start, A).shown, ImportStats())
        let mid = Act2Timeline.frame(log, start + Act2Timeline.flow / 2, A).shown
        XCTAssertGreaterThan(mid.pages, 0)
        XCTAssertLessThan(mid.pages, log.totals(at: start).pages)
        XCTAssertEqual(Act2Timeline.frame(log, log.done!, A).shown, log.totals(at: log.done!))
    }

    func testLightOnlyLeavesTheSourcesYouKeep() {
        let log = Act2Log.demo(start: 0)
        let t = log.flowStart! + 1.5
        let particles = Act2Timeline.particles(log, t, A)
        XCTAssertFalse(particles.isEmpty)
        let brave = ImportSource.demo[3].colour.mix(RGBA(1, 0.97, 0.92), 0.55)
        XCTAssertFalse(particles.contains { $0.colour == brave })
    }

    func testRestoredOrRefocused() {
        let bring = Act2Log.demo(start: 0)
        XCTAssertEqual(Act2Timeline.frame(bring, bring.done! + 1, A).restored, 1, accuracy: 1e-9)
        XCTAssertEqual(Act2Timeline.frame(bring, bring.done! + 1, A).refocused, 0)

        var fresh = Act2Log(start: 0, sources: ImportSource.demo)
        fresh.choice = (4, false)
        XCTAssertFalse(fresh.bringing)
        XCTAssertNil(fresh.flowStart)
        XCTAssertEqual(Act2Timeline.frame(fresh, fresh.done! + 1, A).refocused, 1, accuracy: 1e-9)
        XCTAssertTrue(Act2Timeline.particles(fresh, 6, A).isEmpty)
    }

    func testBringingNothingIsAFreshStart() {
        var log = Act2Log(start: 0, sources: ImportSource.demo)
        log.toggles = ImportSource.demo.indices.map { (1.0, $0) }
        log.choice = (4, true)
        XCTAssertFalse(log.bringing)
        XCTAssertEqual(Act2Timeline.frame(log, log.done! + 1, A).refocused, 1, accuracy: 1e-9)
    }

    func testPasswordsAreNeverBroughtButSaidToStayBehind() {
        XCTAssertFalse(ImportCategory.allCases.map(\.title).contains("Passwords"), "no chip that does nothing")
        var log = Act2Log.demo(start: 0)
        XCTAssertEqual(log.totals(at: 0).passwords, 0)
        XCTAssertEqual(log.passwordsLeftBehind(at: 0), "Arc, Chrome and Brave")
        XCTAssertEqual(Act2Timeline.frame(log, 0, A).passwordsLeftBehind, "Arc, Chrome and Brave")
        log.toggles = [(1, 3)]
        XCTAssertEqual(log.passwordsLeftBehind(at: 1), "Arc and Chrome", "Brave was left behind, and its passwords with it")
        var none = ImportSource.demo
        for i in none.indices { none[i].stats.passwords = 0 }
        XCTAssertNil(Act2Log(start: 0, sources: none).passwordsLeftBehind(at: 0))
    }

    func testAnExtensionInTwoProfilesIsCountedOnce() {
        let shared = "abcdefghijklmnopabcdefghijklmnop", own = "ponmlkjihgfedcbaponmlkjihgfedcba"
        let arc = ImportSource(browser: "Arc", directory: "Default", profile: "Personal", colour: RGBA(hex: 0xEC4F99),
                               stats: ImportStats(extensions: 1), extensionIDs: [shared])
        let chrome = ImportSource(browser: "Chrome", directory: "Default", profile: "Kai", colour: RGBA(hex: 0x3B8AF6),
                                  stats: ImportStats(extensions: 2), extensionIDs: [shared, own])
        let counted = ImportSource(browser: "Brave", directory: "Default", profile: "Default", colour: RGBA(hex: 0xF5A524),
                                   stats: ImportStats(extensions: 4))
        XCTAssertEqual(ImportSource.totals([arc, chrome], categories: [.extensions]).extensions, 2)
        XCTAssertEqual(ImportSource.totals([arc, chrome, counted], categories: [.extensions]).extensions, 6, "a count without ids adds as it is")
        XCTAssertEqual(ImportSource.totals([arc, chrome], categories: [.spaces]).extensions, 0)
        var log = Act2Log(start: 0, sources: [arc, chrome], offered: [.spaces, .extensions])
        XCTAssertEqual(log.totals(at: 0), ImportSource.totals([arc, chrome], categories: [.spaces, .extensions]),
                       "Act 2's line and the host's rehearsal are one sum")
        log.categories = [(1, .extensions)]
        XCTAssertEqual(log.totals(at: 1).extensions, 0)
    }

    /// Chrome keeps History open, often with new rows still in
    /// the write-ahead log: the scanner counts a copy, so it sees them, and
    /// leaves nothing behind.
    func testTheScannerCountsACopyOfALiveDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            CREATE TABLE urls(url VARCHAR NOT NULL, hidden INTEGER NOT NULL);
            INSERT INTO urls VALUES ('https://a.example.com/', 0), ('https://b.example.com/', 0), ('https://c.example.com/', 1);
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"), "the rows are still in the log")
        let leftovers = { (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("ReArcScan-") }.count ?? 0 }
        let before = leftovers()
        XCTAssertEqual(BrowserScanner.count(url), 3)
        XCTAssertEqual(leftovers(), before, "the copy is removed")
        XCTAssertEqual(BrowserScanner.count(folder.appendingPathComponent("Missing")), 0)
    }

    /// The scanner reads Chromium-style profiles and Arc's sidebar, read-only.
    func testScannerCountsAFakeArcProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let arc = root.appendingPathComponent("Arc/User Data")
        let profile = arc.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Extensions/abcdefghijklmnopabcdefghijklmnop"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ object: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: url) }
        try write(["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 9": ["name": "Gone"]]]],
                  arc.appendingPathComponent("Local State"))
        try write(["extensions": ["settings": ["abcdefghijklmnopabcdefghijklmnop": [
            "location": 1, "from_webstore": true, "manifest": ["name": "Store", "version": "1"],
        ]]]], profile.appendingPathComponent("Preferences"))
        try write(["roots": ["bookmark_bar": ["type": "folder", "children": [
            ["type": "url"], ["type": "folder", "children": [["type": "url"], ["type": "url"]]],
        ]]]], profile.appendingPathComponent("Bookmarks"))
        try write(["sidebar": ["containers": [["global": [:]], [
            "spaces": ["s1", ["id": "s1", "title": "Work", "containerIDs": ["pinned", "c1"], "profile": ["default": true]],
                       "s2", ["id": "s2", "title": "Play", "containerIDs": ["c2"], "profile": ["default": true]]],
            "items": [["id": "f1", "parentID": "c1", "data": ["list": [:]]],
                      ["id": "t1", "parentID": "f1", "data": ["tab": [:]]],
                      ["id": "t2", "parentID": "c2", "data": ["tab": [:]]],
                      ["id": "t3", "parentID": "nowhere", "data": ["tab": [:]]]],
        ]]]], root.appendingPathComponent("Arc/StorableSidebar.json"))

        let found = BrowserScanner.scan(applicationSupport: root)
        XCTAssertEqual(found.count, 1, "missing profile directories are skipped")
        XCTAssertEqual(found.first?.profile, "Personal")
        XCTAssertEqual(found.first?.stats, ImportStats(spaces: 2, tabs: 2, bookmarks: 3, pages: 0, passwords: 0, extensions: 1))
    }
}

/// Every browser on the trail, and its label, is on screen with room to spare.
final class Act2TrailLayoutTests: XCTestCase {
    func testEveryBrowserSitsOnScreen() {
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 1024, height: 768), CGSize(width: 2000, height: 1293)] {
            let layout = Act2Layout(size: size)
            let H = size.height
            for n in 1 ... 8 {
                var previous: CGPoint?
                for i in 0 ..< n {
                    let p = layout.point(layout.nodeAngle(i, of: n))
                    // The node, then its two-line label below its centre.
                    XCTAssertLessThan(p.y + layout.nodeRadius, H * 0.955, "\(n) browsers, #\(i), \(size): above the bottom bar")
                    XCTAssertLessThan(p.y + H * 0.0195, H * 0.955, "\(n) browsers, #\(i) label")
                    XCTAssertGreaterThan(p.x - layout.nodeRadius - H * 0.16, 0, "\(n) browsers, #\(i) label inside the left edge")
                    XCTAssertGreaterThan(hypot(p.x - layout.apex.x, p.y - layout.apex.y), layout.avatarRadius * 1.6 + layout.nodeRadius,
                                         "\(n) browsers, #\(i) clear of you")
                    if let previous, n <= 6 {
                        XCTAssertGreaterThan(hypot(p.x - previous.x, p.y - previous.y), layout.nodeRadius * 2.4, "\(n) browsers apart")
                    }
                    previous = p
                }
            }
        }
    }
}

/// Browsers macOS keeps private sit on the trail with a lock, and one that
/// is allowed while Act 2 asks joins it, saying "Found".
final class Act2PendingBrowserTests: XCTestCase {
    func testABlockedBrowserFlipsToFoundOnTheRescan() {
        let arc = ImportSource.demo[0]
        let chrome = ImportSource.demo[2]
        let pending = [PendingBrowser(browser: .chrome, state: .needsPermission(.appData)),
                       PendingBrowser(browser: .safari, state: .needsPermission(.fullDiskAccess)),
                       PendingBrowser(browser: .edge, state: .noData)]
        var log = Act2Log(start: 0, sources: [arc], pending: pending)
        XCTAssertEqual(log.nodeCount, 4)
        XCTAssertEqual(log.blockedNames, "Chrome and Safari")
        XCTAssertEqual(log.neededPermission, .fullDiskAccess, "one button: the pane that covers both")
        let A = Act2Layout(size: CGSize(width: 1440, height: 900))
        XCTAssertGreaterThan(Act2Timeline.frame(log, Act2Timeline.ready, A).permission, 0.9)

        log.toggles = [(Act2Timeline.ready + 0.5, 0)]
        XCTAssertTrue(log.merge(BrowserScan(sources: [arc, chrome], pending: [pending[1], pending[2]]), at: 10))
        XCTAssertEqual(log.sources.map(\.id), [arc.id, chrome.id], "Arc keeps index 0, so its toggle stays")
        XCTAssertFalse(log.isOn(source: 0, at: 11))
        XCTAssertEqual(log.pending.map(\.browser), [.safari, .edge])
        XCTAssertEqual(log.arrivals, [1: 10])
        XCTAssertEqual(log.blockedNames, "Safari")
        let frame = Act2Timeline.frame(log, 11, A)
        XCTAssertEqual(frame.nodes.count, 4)
        XCTAssertGreaterThan(frame.found[1], 0.9, "Chrome rings and reads Found")
        XCTAssertEqual(Act2Timeline.frame(log, 14, A).found[1], 0, "then its profile again")
        XCTAssertFalse(log.merge(BrowserScan(sources: [arc, chrome], pending: [pending[1], pending[2]]), at: 12), "nothing new")

        log.choice = (20, true)
        XCTAssertFalse(log.merge(BrowserScan(sources: [arc, chrome, ImportSource.demo[3]]), at: 21), "the choice is made")
    }

    func testTheSurveyNamesBlockedAndEmptyBrowsers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Library/Application Support")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let brave = root.appendingPathComponent("BraveSoftware/Brave-Browser")
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: brave.appendingPathComponent("Local State"))
        let scan = BrowserScanner.survey(applicationSupport: root, installed: { $0 == .brave || $0 == .edge },
                                         probe: { $0.path.hasPrefix(brave.path) ? .denied : ImportAccessProbes.system($0) })
        XCTAssertTrue(scan.sources.isEmpty)
        XCTAssertEqual(scan.pending, [PendingBrowser(browser: .brave, state: .needsPermission(.appData)),
                                      PendingBrowser(browser: .edge, state: .noData)])
    }
}
