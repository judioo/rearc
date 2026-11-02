import XCTest
@testable import SidebarModel

final class SnapshotMigrationTests: XCTestCase {

    func testMigratesV1JSONToV2Model() throws {
        let spaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let tabID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let favID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let json = """
        {
          "schemaVersion": 1,
          "spaces": [{
            "id": "\(spaceID.uuidString)",
            "name": "Personal",
            "theme": { "red": 0.5, "green": 0.5, "blue": 0.9 },
            "iconName": "house.fill"
          }],
          "activeSpaceID": "\(spaceID.uuidString)",
          "favorites": [{
            "id": "\(favID.uuidString)",
            "kind": "favorite",
            "title": "Fav",
            "url": "https://example.com",
            "faviconToken": "E",
            "isUnread": false
          }],
          "contentBySpace": {
            "\(spaceID.uuidString)": {
              "pinned": [],
              "today": [{
                "id": "\(tabID.uuidString)",
                "kind": "today",
                "title": "Today",
                "url": "https://today.test",
                "faviconToken": "T",
                "isUnread": false
              }]
            }
          },
          "selectedTabID": "\(tabID.uuidString)",
          "selectionBySpace": {}
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        XCTAssertEqual(snapshot.schemaVersion, 9)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.profiles[0].name, "Personal")
        XCTAssertEqual(snapshot.spaces[0].profileID, snapshot.profiles[0].id)
        XCTAssertEqual(snapshot.topAppsContainer.kind, .topApps)
        XCTAssertEqual(snapshot.topAppsContainer.childIDs, [favID])
        XCTAssertEqual(snapshot.tabsByID[tabID]?.title, "Today")
        XCTAssertEqual(snapshot.spaceContainers[spaceID]?.unpinned.childIDs, [tabID])
        XCTAssertTrue(snapshot.littleArcWindows.isEmpty)

        let store = SidebarStore()
        store.applySnapshot(snapshot)
        XCTAssertEqual(store.favorites.map(\.id), [favID])
        XCTAssertEqual(store.content(for: spaceID).today.count, 1)
        XCTAssertEqual(store.selectedItemID, tabID)
    }

    func testV2SnapshotEncodesContainerStructure() throws {
        let store = SidebarStore.sample()
        let snapshot = store.makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertEqual(decoded.profiles.map(\.name), store.profiles.map(\.name))
        XCTAssertEqual(decoded.activeProfileID, store.activeProfileID)
        XCTAssertEqual(decoded.topAppsContainer.childIDs, store.favorites.map(\.id))
        for space in store.spaces {
            let bundle = try XCTUnwrap(decoded.spaceContainers[space.id])
            XCTAssertEqual(bundle.pinned.kind, .spaceItems(spaceID: space.id, section: .pinned))
            XCTAssertEqual(bundle.unpinned.kind, .spaceItems(spaceID: space.id, section: .unpinned))
        }
    }

    func testV3JSONMigratesToV4Profiles() throws {
        let store = SidebarStore(spaces: [Space(name: "Legacy")])
        let spaceID = store.spaces[0].id
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(store.makeSnapshot())
        ) as! [String: Any]
        object["schemaVersion"] = 3
        object.removeValue(forKey: "profiles")
        object.removeValue(forKey: "activeProfileID")
        object.removeValue(forKey: "lastActiveSpaceByProfile")
        let snapshot = try JSONDecoder().decode(
            SidebarSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(snapshot.schemaVersion, 9)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.profiles[0].name, "Personal")
        XCTAssertEqual(snapshot.spaces[0].profileID, snapshot.profiles[0].id)
        XCTAssertEqual(snapshot.lastActiveSpaceByProfile[snapshot.profiles[0].id], spaceID)
    }

    func testUnpinnedSharedRoundTrip() {
        let store = SidebarStore(spaces: [Space(name: "Shared", unpinnedShared: true)])
        store.setUnpinnedShared(true, for: store.spaces[0].id)
        let snapshot = store.makeSnapshot()
        XCTAssertTrue(snapshot.spaceContainers[store.spaces[0].id]?.unpinned.unpinnedShared == true)
        let loaded = SidebarStore()
        loaded.applySnapshot(snapshot)
        XCTAssertTrue(loaded.spaces[0].unpinnedShared)
    }
}
