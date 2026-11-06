import XCTest
@testable import SidebarModel

/// P3.29: a space can turn boosts off for itself, under the profile's master switch.
final class SpaceBoostPolicyTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    func testASpaceWithBoostsOffGetsNoneAndOtherSpacesKeepThem() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let home = store.spaces[0].id
        let work = store.addSpace(name: "Work").id
        XCTAssertNil(store.addBoost(BoostPackage.newStyle(name: "Dark", hostScope: [BoostHostRule(host: "docs.test")], css: "body{}"), enabled: true))
        let homeTab = store.addTab(kind: .pinned, title: "Docs", url: url("docs.test"), in: home)
        let workTab = store.addTab(kind: .pinned, title: "Docs", url: url("docs.test"), in: work)
        XCTAssertEqual(store.activeBoostEntries(for: workTab).count, 1)

        store.setSpaceBoostsEnabled(false, for: work)
        XCTAssertEqual(store.activeBoostEntries(for: workTab), [])
        XCTAssertEqual(store.activeBoostEntries(for: homeTab).count, 1, "only that space")

        store.setSpaceBoostsEnabled(true, for: work)
        XCTAssertEqual(store.activeBoostEntries(for: workTab).count, 1)
    }

    func testTheSpaceSwitchBeatsAForceOnPolicyAndTheMasterSwitchBeatsTheSpace() {
        let profile = Profile.personalDefault()
        var library = ProfileBoostLibrary(profileID: profile.id)
        let package = BoostPackage.newStyle(name: "Hide", hostScope: [BoostHostRule(host: "example.com")], css: ".ad { display: none; }")
        _ = BoostLibraryOps.add(package, to: &library, enabled: true)
        let spaceID = UUID()
        _ = BoostLibraryOps.setSpacePolicy(packageID: package.manifest.id, spaceID: spaceID, policy: .forceOn, library: &library)
        let page = URL(string: "https://example.com/page")!

        let off = BoostTabContext(profileID: profile.id, spaceID: spaceID, url: page, spaceBoostsEnabled: false)
        XCTAssertFalse(BoostActivation.effectiveEnabled(installation: library.installations[0], library: library, context: off))
        XCTAssertEqual(BoostActivation.activeEntries(library: library, context: off), [])

        library.masterEnabled = false
        let on = BoostTabContext(profileID: profile.id, spaceID: spaceID, url: page)
        XCTAssertEqual(BoostActivation.activeEntries(library: library, context: on), [], "a space's on defers to the profile")
    }

    func testSpacesEncodeAsBeforeUnlessBoostsAreOffAndOldFilesDecodeOn() throws {
        let space = Space(name: "Home")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as? [String: Any]
        XCTAssertNil(plain?["boostsEnabled"], "an untouched space writes no new key")

        var off = space
        off.boostsEnabled = false
        let data = try JSONEncoder().encode(off)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["boostsEnabled"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(Space.self, from: data), off)

        // A space saved before the switch existed.
        let legacy = try JSONEncoder().encode(space)
        XCTAssertTrue(try JSONDecoder().decode(Space.self, from: legacy).boostsEnabled)
    }

    func testTheSwitchSyncsWithTheSpaceRecord() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let work = store.addSpace(name: "Work").id
        store.setSpaceBoostsEnabled(false, for: work)
        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        XCTAssertEqual(records[SyncRecordKind.space.recordName(for: work)]?.values["boostsEnabled"], .bool(false))
        XCTAssertNil(records[SyncRecordKind.space.recordName(for: store.spaces[0].id)]?.values["boostsEnabled"])

        var payloads: [String: SyncRecordPayload] = [:]
        for (name, body) in records {
            payloads[name] = SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: SyncStamp(millis: 1, device: "A")) })
        }
        let fresh = SidebarStore(spaces: [Space(name: "Other")])
        let rebuilt = SidebarSyncProjection.apply(payloads, onto: fresh.makeSnapshot())
        XCTAssertEqual(rebuilt.spaces.first { $0.id == work }?.boostsEnabled, false)
        XCTAssertEqual(rebuilt.spaces.first { $0.id == store.spaces[0].id }?.boostsEnabled, true)
    }
}
