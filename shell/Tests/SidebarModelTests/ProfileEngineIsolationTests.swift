import XCTest
@testable import SidebarModel

final class ProfileEngineIsolationTests: XCTestCase {

    func testWebsiteDataStoreKeysDifferPerProfile() {
        let profileA = Profile.personalDefault()
        let profileB = Profile(name: "Work")
        let ctxA = EngineProfileContext(profileID: profileA.id)
        let ctxB = EngineProfileContext(profileID: profileB.id)
        XCTAssertNotEqual(ctxA.websiteDataStoreIdentifier, ctxB.websiteDataStoreIdentifier)
        XCTAssertEqual(ctxA.websiteDataStoreIdentifier, profileA.id)
        XCTAssertEqual(ctxB.websiteDataStoreIdentifier, profileB.id)
    }

    func testEphemeralContextUsesNonPersistentPolicyFlag() {
        let profile = Profile.personalDefault()
        let persistent = EngineProfileContext(profileID: profile.id, isEphemeral: false)
        let ephemeral = EngineProfileContext(profileID: profile.id, isEphemeral: true)
        XCTAssertFalse(persistent.isEphemeral)
        XCTAssertTrue(ephemeral.isEphemeral)
        XCTAssertEqual(persistent.websiteDataStoreIdentifier, ephemeral.websiteDataStoreIdentifier)
    }

    func testLittleArcPromoteSwitchesToOriginatingProfile() {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        let workSpace = store.activeSpaceID
        let little = store.createLittleArcWindow(url: URL(string: "https://little.test")!, title: "Little")
        XCTAssertEqual(little.profileID, work.id)

        store.selectProfile(store.profiles.first(where: { $0.id != work.id })!.id)
        XCTAssertNotEqual(store.activeProfileID, work.id)

        _ = store.promoteLittleArcToTab(id: little.id)
        XCTAssertEqual(store.activeProfileID, work.id)
        XCTAssertEqual(store.activeSpaceID, workSpace)
    }

    func testV7SnapshotMigratesLittleArcProfileID() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        _ = store.createLittleArcWindow(url: URL(string: "https://legacy.test")!, title: "Legacy")
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(store.makeSnapshot())
        ) as! [String: Any]
        object["schemaVersion"] = 7
        if var windows = object["littleArcWindows"] as? [[String: Any]] {
            for index in windows.indices {
                windows[index].removeValue(forKey: "profileID")
            }
            object["littleArcWindows"] = windows
        }
        let snapshot = try JSONDecoder().decode(
            SidebarSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertEqual(snapshot.littleArcWindows.count, 1)
        XCTAssertEqual(snapshot.littleArcWindows[0].profileID, work.id)
    }
}
