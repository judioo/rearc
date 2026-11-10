import XCTest
@testable import SidebarModel

final class SpaceContainerTests: XCTestCase {
    func testPickerIncludesCurrentAndDefaultWithOneOrManyProfiles() {
        let store = SidebarStore()
        let space = store.activeSpaceID
        let personal = store.activeProfile
        XCTAssertEqual(store.profileChoices(forSpace: space), [personal])
        let work = store.addProfile(name: "Work")
        let other = store.addProfile(name: "Other")
        XCTAssertEqual(store.profileChoices(forSpace: space), [personal, work, other])
        XCTAssertNil(store.changeProfile(ofSpace: space, to: work.id))
        XCTAssertEqual(store.profileChoices(forSpace: space), [personal, work, other])
        XCTAssertTrue(store.profileChoices(forSpace: UUID()).isEmpty)
    }

    func testNewSpacePolicyPersistsAndUnknownValuesUseSharedDefault() {
        let suite = "SpaceContainerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NewSpaceContainerPolicy.load(from: defaults), .sharedDefault)
        NewSpaceContainerPolicy.ownContainer.save(to: defaults)
        XCTAssertEqual(NewSpaceContainerPolicy.load(from: defaults), .ownContainer)
        NewSpaceContainerPolicy.sharedDefault.save(to: defaults)
        XCTAssertEqual(NewSpaceContainerPolicy.load(from: defaults), .sharedDefault)
        defaults.set("unknown", forKey: NewSpaceContainerPolicy.defaultsKey)
        XCTAssertEqual(NewSpaceContainerPolicy.load(from: defaults), .sharedDefault)
        defaults.removeObject(forKey: NewSpaceContainerPolicy.defaultsKey)
    }

    func testSharedDefaultAndExplicitOverride() throws {
        let store = SidebarStore()
        let personal = store.activeProfileID
        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        let shared = try XCTUnwrap(store.createSpace(from: .suggested(in: store)))
        XCTAssertEqual(shared.profileID, personal)
        let explicit = try XCTUnwrap(store.createSpace(from: .suggested(in: store, profileID: work.id)))
        XCTAssertEqual(explicit.profileID, work.id)
    }

    func testOwnContainerDraftCreatesOnlyOnSaveAndCanBeOverridden() throws {
        let store = SidebarStore()
        var draft = SpaceDraft.blank(in: store, containerPolicy: .ownContainer)
        XCTAssertTrue(draft.createsOwnContainer)
        XCTAssertNil(store.createSpace(from: draft))
        XCTAssertEqual(store.profiles.count, 1)
        draft.name = "Work"
        let space = try XCTUnwrap(store.createSpace(from: draft))
        XCTAssertNotEqual(space.profileID, store.profiles[0].id)
        XCTAssertEqual(store.profile(withID: space.profileID)?.name, "Work")
        XCTAssertEqual(store.spaces(in: space.profileID).map(\.id), [space.id], "no extra starter space")
        XCTAssertEqual(store.activeSpaceID, space.id)
        draft.createsOwnContainer = false
        let shared = try XCTUnwrap(store.createSpace(from: draft))
        XCTAssertEqual(shared.profileID, store.profiles[0].id)
        XCTAssertEqual(store.profiles.count, 2)
    }

    func testContainerCreationKeepsTabsAndPersistsProfileMapping() throws {
        let store = SidebarStore()
        let original = store.activeProfileID
        let space = store.activeSpaceID
        let tab = store.addTab(kind: .today, title: "Account", url: URL(string: "https://example.test")!)
        let container = try XCTUnwrap(store.createContainer(forSpace: space))
        XCTAssertNotEqual(container.id, original)
        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertEqual(store.spaceContaining(tabID: tab.id), space)
        XCTAssertEqual(store.activeSpace.profileID, container.id)
        let second = try XCTUnwrap(store.createContainer(forSpace: space))
        XCTAssertNotEqual(second.id, container.id)
        XCTAssertNotEqual(second.name, container.name)
        XCTAssertNil(store.createContainer(forSpace: UUID()))
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(store.makeSnapshot())))
        XCTAssertEqual(restored.activeSpace.profileID, second.id)
        XCTAssertEqual(restored.tab(withID: tab.id)?.url, tab.url)
        // An empty former profile stays available, and selecting it gets its own landing space.
        restored.selectProfile(original)
        XCTAssertEqual(restored.activeSpace.profileID, original)
        XCTAssertEqual(restored.spaces(in: original).count, 1)
    }
}
