import XCTest
@testable import SidebarModel

final class BenchFixtureTests: XCTestCase {
    private func url(_ n: Int) -> URL { URL(string: "http://127.0.0.1:9/bench/tab/\(n)")! }

    func testItems300LayoutCounts() {
        let fixture = BenchFixture.make(.items300, seed: 1, pageURL: url)
        let store = fixture.store
        XCTAssertEqual(fixture.spaceIDs.count, 5)
        XCTAssertEqual(fixture.profileIDs.count, 2)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(fixture.spaceIDs.prefix(3).map { store.space(withID: $0)?.profileID }, Array(repeating: fixture.profileIDs[0], count: 3))
        XCTAssertEqual(fixture.spaceIDs.suffix(2).map { store.space(withID: $0)?.profileID }, Array(repeating: fixture.profileIDs[1], count: 2))
        let first = store.content(for: fixture.spaceIDs[0])
        XCTAssertEqual(first.todayLeaves.count, 250)
        XCTAssertEqual(first.pinnedLeaves.count, 40)
        XCTAssertEqual(SidebarTree.folders(first.pinned).count, 6)
        XCTAssertEqual(BenchFixture.layout(.items300).firstSpaceRows, 296)
        XCTAssertEqual(fixture.tabIDs.count, 290 + 4 * 16)
        XCTAssertEqual(store.activeSpaceID, fixture.spaceIDs[0])
    }

    func testFoldersNestThreeLevelsDeep() {
        let fixture = BenchFixture.make(.items300, seed: 1, pageURL: url)
        let pinned = fixture.store.content(for: fixture.spaceIDs[0]).pinned
        let folders = SidebarTree.folders(pinned)
        let depths = folders.map { (SidebarTree.ancestorFolderIDs(of: $0.id, in: pinned) ?? []).count }
        XCTAssertEqual(depths.max(), 2, "three levels: a top folder and two nested ones")
        XCTAssertEqual(depths.filter { $0 == 0 }.count, 2)
    }

    func testItems500GivesFiveHundredRowsInTheFirstSpace() {
        let layout = BenchFixture.layout(.items500)
        XCTAssertEqual(layout.firstSpaceRows, 496)
        let fixture = BenchFixture.make(.items500, seed: 7, pageURL: url)
        XCTAssertEqual(fixture.store.content(for: fixture.spaceIDs[0]).todayLeaves.count, 450)
    }

    func testSameSeedSameTitlesAndURLs() {
        func titles(_ seed: UInt64) -> [String] {
            let fixture = BenchFixture.make(.items300, seed: seed, pageURL: url)
            return fixture.tabIDs.compactMap { fixture.store.tab(withID: $0)?.title }
        }
        XCTAssertEqual(titles(3), titles(3))
        XCTAssertNotEqual(titles(3), titles(4))
        let fixture = BenchFixture.make(.items300, seed: 3, pageURL: url)
        let urls = fixture.tabIDs.compactMap { fixture.store.tab(withID: $0)?.url }
        XCTAssertEqual(urls.count, fixture.tabIDs.count)
        XCTAssertTrue(urls.allSatisfy { $0.host == "127.0.0.1" })
        XCTAssertEqual(Set(urls).count, urls.count)
    }

    func testSplitMixIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        XCTAssertEqual((0 ..< 5).map { _ in a.next() }, (0 ..< 5).map { _ in b.next() })
    }
}
