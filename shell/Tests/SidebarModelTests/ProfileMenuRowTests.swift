import XCTest
@testable import SidebarModel

final class ProfileMenuRowTests: XCTestCase {
    func testCountsReadAsWordsWithSingularAndNone() {
        XCTAssertEqual(ProfileMenuRow.spaceCountText(0), "No spaces")
        XCTAssertEqual(ProfileMenuRow.spaceCountText(1), "1 space")
        XCTAssertEqual(ProfileMenuRow.spaceCountText(2), "2 spaces")
        XCTAssertEqual(ProfileMenuRow.spaceCountText(13), "13 spaces")
    }

    func testRowsKeepTheStoreOrderAndCountEachProfilesSpaces() throws {
        let store = SidebarStore()
        let first = store.activeProfile
        // The owner's near-identical names.
        let upper = store.addProfile(name: "Akilu")
        let typo = store.addProfile(name: "akliu", createInitialSpace: false)
        let assured = store.addProfile(name: "Assured.living")
        for index in 0..<12 { _ = store.addSpace(name: "S\(index)", profileID: first.id) }

        let rows = store.profileMenuRows(active: upper.id)
        XCTAssertEqual(rows.map(\.id), [first.id, upper.id, typo.id, assured.id], "the order of the store")
        XCTAssertEqual(rows.map(\.spaceCount), [13, 1, 0, 1])
        XCTAssertEqual(rows.map(\.spaceCountText), ["13 spaces", "1 space", "No spaces", "1 space"])
        XCTAssertEqual(rows.map(\.isActive), [false, true, false, false])
        XCTAssertEqual(rows[2].profile, typo, "a profile with no spaces still lists")
    }

    func testSameNamesStayDistinctRowsAndOnlyOneIsActive() {
        let store = SidebarStore()
        let a = store.addProfile(name: "akilu")
        // Synced or imported profiles can share a name.
        let b = store.addProfile(name: "akilu")
        let rows = store.profileMenuRows(active: b.id)
        XCTAssertEqual(rows.filter { $0.profile.name == "akilu" }.map(\.id), [a.id, b.id])
        XCTAssertEqual(rows.filter(\.isActive).map(\.id), [b.id])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertTrue(store.profileMenuRows(active: nil).allSatisfy { !$0.isActive })
        XCTAssertTrue(store.profileMenuRows(active: UUID()).allSatisfy { !$0.isActive })
    }
}
