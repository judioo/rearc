import CoreGraphics
@testable import Onboarding
import XCTest

final class Act2Tests: XCTestCase {
    let A = Act2Layout(size: CGSize(width: 1440, height: 900))

    func testChoicesShapeWhatComesOver() {
        let log = Act2Log.demo(start: 0)
        let all = ImportSource.demo.map(\.stats).reduce(ImportStats(), +)
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
