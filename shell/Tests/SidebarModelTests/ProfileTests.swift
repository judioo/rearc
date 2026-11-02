import XCTest
@testable import SidebarModel

final class ProfileTests: XCTestCase {

    func testDefaultProfileNamedPersonal() {
        let store = SidebarStore()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Personal")
        XCTAssertEqual(store.spaces[0].profileID, store.profiles[0].id)
    }

    func testNewSpaceBindsToActiveProfile() {
        let store = SidebarStore()
        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        let space = store.addSpace(name: "Desk")
        XCTAssertEqual(space.profileID, work.id)
    }

    func testDeleteRefusedWhenProfileOwnsSpaces() {
        let store = SidebarStore()
        let profileID = store.profiles[0].id
        _ = store.addProfile(name: "Other")
        XCTAssertEqual(store.deleteProfile(profileID), .profileOwnsSpaces(count: 1))
    }

    func testDeleteEmptySecondaryProfile() {
        let store = SidebarStore()
        let extra = store.addProfile(name: "Extra")
        store.removeSpace(store.spaces(in: extra.id)[0].id)
        XCTAssertNil(store.deleteProfile(extra.id))
        XCTAssertFalse(store.profiles.contains(where: { $0.id == extra.id }))
    }

    func testRemovingActiveSpaceKeepsProfileAndSpaceConsistent() {
        let store = SidebarStore()
        let personal = store.activeProfileID
        let extra = store.addProfile(name: "Extra")
        store.selectProfile(extra.id)
        store.removeSpace(store.activeSpaceID)

        XCTAssertEqual(store.activeProfileID, personal)
        XCTAssertEqual(store.activeSpace.profileID, store.activeProfileID)
        let newSpace = store.addSpace(name: "New")
        XCTAssertEqual(newSpace.profileID, personal)
    }

    func testPerProfileLastActiveSpaceMemory() {
        let store = SidebarStore()
        let personalSpace = store.spaces[0].id
        let workProfile = store.addProfile(name: "Work")
        store.selectProfile(workProfile.id)
        let workSpace = store.activeSpaceID
        let secondWork = store.addSpace(name: "Second Work").id
        store.selectSpace(secondWork)

        store.selectProfile(store.profiles[0].id)
        XCTAssertEqual(store.activeSpaceID, personalSpace)

        store.selectProfile(workProfile.id)
        XCTAssertEqual(store.activeSpaceID, secondWork)
        XCTAssertNotEqual(store.activeSpaceID, workSpace)
    }

    func testCycleSpaceStaysWithinActiveProfile() {
        let store = SidebarStore()
        _ = store.addSpace(name: "Second Personal")
        let workProfile = store.addProfile(name: "Work")
        let workSpace = store.spaces(in: workProfile.id)[0].id
        store.selectProfile(workProfile.id)
        store.selectSpace(workSpace)
        store.cycleSpace()
        XCTAssertEqual(store.activeSpaceID, workSpace)
    }

    func testSwitchToSpaceCommandsScopedToActiveProfile() {
        let store = SidebarStore()
        _ = store.addSpace(name: "Personal Two")
        let workProfile = store.addProfile(name: "Work")
        store.selectProfile(store.profiles[0].id)
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        let switchTitles = AppCommandRegistry.all(in: context)
            .filter { if case .switchToSpace = $0.action { return true }; return false }
            .map(\.title)
        XCTAssertEqual(switchTitles.count, 1)
        XCTAssertTrue(switchTitles[0].contains("Personal Two"))
        store.selectProfile(workProfile.id)
        let workFirst = store.activeSpaceID
        let workSecond = store.addSpace(name: "Work Two").id
        store.selectSpace(workFirst)
        let context2 = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        let workSwitch = AppCommandRegistry.all(in: context2)
            .filter { if case .switchToSpace = $0.action { return true }; return false }
        XCTAssertEqual(workSwitch.count, 1)
        XCTAssertTrue(workSwitch[0].title.contains("Work Two"))
    }

    func testProfileCommandEnablement() {
        let store = SidebarStore()
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.contains(where: { $0.title == "New Profile" }))
        XCTAssertTrue(commands.contains(where: { $0.title == "Rename Profile…" }))
        XCTAssertFalse(commands.contains(where: {
            if case .switchToProfile(let id) = $0.action { return id == store.activeProfileID }
            return false
        }))
    }

    func testRenameAndReorderProfiles() {
        let store = SidebarStore()
        let second = store.addProfile(name: "Work")
        XCTAssertNil(store.renameProfile(second.id, to: "Office"))
        XCTAssertEqual(store.profile(withID: second.id)?.name, "Office")
        store.moveProfile(from: 1, to: 0)
        XCTAssertEqual(store.profiles[0].id, second.id)
    }
}
