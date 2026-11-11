import XCTest
@testable import SidebarModel

/// Security RC-0.1.0-564: pages and Boosts stay in the container they belong to.
final class ContainerRoutingSecurityTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// S-01, S-03: a page made in another container (a Little ReArc's popup or "Open Link
    /// in New Tab") lands in a space of that container, never in the active space.
    func testNewTabsFromAnotherContainerLandInThatContainersSpace() {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let personal = store.spaces[0]
        let work = store.addProfile(name: "Work")
        let workSpace = store.spaces.first { $0.profileID == work.id }!
        let workSecond = store.addSpace(name: "Work 2", profileID: work.id)
        XCTAssertEqual(store.activeSpaceID, personal.id)

        XCTAssertEqual(store.space(forNewTabIn: work.id), workSpace.id, "the profile's first space")
        XCTAssertEqual(store.space(forNewTabIn: work.id, preferring: workSecond.id), workSecond.id, "the opener's space")
        XCTAssertEqual(store.space(forNewTabIn: work.id, preferring: personal.id), workSpace.id,
                       "an opener space in another profile is not used")
        XCTAssertEqual(store.space(forNewTabIn: personal.profileID), personal.id, "the active space when it matches")

        let tab = store.addTab(kind: .today, title: "Sign in", url: url("corp.test"), in: store.space(forNewTabIn: work.id))
        XCTAssertEqual(store.spaces.first { $0.id == store.spaceContaining(tabID: tab.id) }?.profileID, work.id)

        let orphan = store.addProfile(name: "Empty", createInitialSpace: false)
        XCTAssertNil(store.space(forNewTabIn: orphan.id), "no space: the caller declines")
    }

    /// S-04: a favourite left open in container A keeps A's Boosts after a switch to B.
    func testBackgroundFavouritesKeepTheirOwnContainersBoosts() {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let personal = store.activeProfileID
        XCTAssertNil(store.addBoost(BoostPackage.newStyle(name: "Personal", hostScope: [BoostHostRule(host: "mail.test")], css: "a{color:red}")))
        let favourite = store.addTab(kind: .favorite, title: "Mail", url: url("mail.test"))
        XCTAssertEqual(store.favoriteOwner(of: favourite.id), personal)

        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        XCTAssertEqual(store.activeProfileID, work.id)
        XCTAssertNil(store.addBoost(BoostPackage.newStyle(name: "Work", hostScope: [BoostHostRule(host: "mail.test")], css: "a{color:blue}")))

        let entries = store.activeBoostEntries(for: favourite)
        XCTAssertEqual(entries.map(\.css), ["a{color:red}"], "the favourite's own profile, not the active one")
    }
}
