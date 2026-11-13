import XCTest
@testable import SidebarModel

/// A fresh install that imports Arc while iCloud holds an earlier
/// install's import of the same Arc spaces: one profile, not one "Only on
/// this Mac" next to one "In iCloud only". And after iCloud's copy was
/// deleted, putting this Mac's back. Everything runs against
/// `InMemorySyncServer`, never CloudKit.
@MainActor
final class CloudProfileResyncTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private let backupURL = URL(fileURLWithPath: "/dev/null/backup.json")

    override func setUp() {
        server = InMemorySyncServer()
    }

    private struct Mac {
        var store: SidebarStore
        var sync: SidebarSyncCoordinator
        var state: InMemorySyncStateStore
    }

    /// A new install (nothing saved) that imported Arc.
    private func install(_ device: String, on: Bool) throws -> Mac {
        let store = SidebarStore()
        let export = try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar()))
        let source = ArcSidebarImport(export: export, profileNames: ["Default": "Home", "Profile 1": "Studio"])
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        var state = SidebarSyncState()
        state.enabled = on
        state.decision = on ? .user : nil
        let file = InMemorySyncStateStore(state)
        let sync = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: file, deviceID: device,
                                          now: { [unowned self] in self.date })
        sync.host = store
        return Mac(store: store, sync: sync, state: file)
    }

    private func cycle(_ mac: Mac) async {
        date += 2
        _ = await mac.sync.sync()
    }

    private func look(_ mac: Mac) async -> CloudSidebarDetection {
        date += 2
        return await mac.sync.detectCloudSidebar()
    }

    private func sidebar(_ mac: Mac) async throws -> CloudSidebarFound {
        let detection = await look(mac)
        return try XCTUnwrap(detection.found)
    }

    /// Every pinned row of every space, by space.
    private func pinned(_ store: SidebarStore) -> [Space.ID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: store.spaces.map { ($0.id, Set(SidebarTree.leaves(store.content(for: $0.id).pinned).map(\.id))) })
    }

    /// Deletes iCloud's copy of each profile as Settings did with sync off
    /// (the "In iCloud only" row's Delete from iCloud…).
    private func deleteFromICloud(_ ids: [Profile.ID], by mac: Mac) async throws {
        for id in ids {
            let found = try await sidebar(mac)
            let plan = try XCTUnwrap(CloudProfileDeletion(profileID: id, in: Dictionary(uniqueKeysWithValues: found.records.map { ($0.recordName, $0) })))
            let result = await mac.sync.deleteCloudProfile(plan, in: found, backup: { _ in self.backupURL })
            guard case .deleted = result else { return XCTFail("\(result)") }
        }
    }

    // MARK: - Where a fresh import is

    func testAFreshInstallsImportIsTheProfileICloudHas() async throws {
        let earlier = try install("A", on: true)
        await cycle(earlier)
        let fresh = try install("B", on: false)
        XCTAssertTrue(Set(fresh.store.profiles.map(\.id)).isDisjoint(with: earlier.store.profiles.map(\.id)), "profile ids are made per install")
        let arc = { (store: SidebarStore) in Set(store.spaces.filter { $0.arcSourceID?.hasSuffix(":__favorites") == false }.map(\.id)) }
        XCTAssertEqual(arc(fresh.store), arc(earlier.store), "an Arc space's id follows from the Arc space")

        let found = try await sidebar(fresh)
        // By id alone (the bug): every profile here looked only here, every one in iCloud only there.
        XCTAssertEqual(found.profiles(notIn: fresh.store.profiles).count, found.profiles.count)

        XCTAssertEqual(found.profiles(notIn: fresh.store.profiles, spaces: fresh.store.spaces), [], "nothing is only in iCloud")
        for profile in fresh.store.profiles {
            let twins = found.profiles(matching: profile.id, spaces: fresh.store.spaces)
            XCTAssertEqual(twins.count, 1, profile.name)
            XCTAssertEqual(Set(twins.first?.spaces.compactMap(\.arcSourceID) ?? []),
                           Set(fresh.store.spaces(in: profile.id).compactMap(\.arcSourceID)), "\(profile.name): the same Arc spaces")
            XCTAssertEqual(ProfileCloudPresence.of(profile.id, spaces: fresh.store.spaces, detection: .found(found), looking: false), .inICloud,
                           "\(profile.name) is on this Mac and in iCloud")
        }
        XCTAssertEqual(found.profiles(matching: earlier.store.profiles[0].id, spaces: earlier.store.spaces).first?.id, earlier.store.profiles[0].id,
                       "the same id first")
    }

    /// A profile of this Mac with the same name as one in iCloud but none of
    /// its spaces is still another profile.
    func testOnlyTheSameSpacesMakeTheSameProfile() async throws {
        let earlier = try install("A", on: true)
        await cycle(earlier)
        let fresh = try install("B", on: false)
        let home = try XCTUnwrap(earlier.store.profiles.first { !earlier.store.spaces(in: $0.id).isEmpty })
        let namesake = fresh.store.addProfile(name: home.name)
        let found = try await sidebar(fresh)
        XCTAssertEqual(ProfileCloudPresence.of(namesake.id, spaces: fresh.store.spaces, detection: .found(found), looking: false), .onlyHere)
        XCTAssertEqual(found.profiles(notIn: fresh.store.profiles, spaces: fresh.store.spaces), [])
    }

    // MARK: - Back into iCloud after iCloud's copy was deleted

    /// What the owner did: iCloud's copies, listed "In iCloud only", deleted
    /// from iCloud, so iCloud holds this Mac's spaces and rows as deleted.
    /// Switching sync on (iCloud has no sidebar) uploads this Mac's sidebar
    /// whole; the deletes take nothing from this Mac.
    func testSwitchingOnAfterICloudsCopyWasDeletedUploadsThisMacsSidebar() async throws {
        let earlier = try install("A", on: true)
        await cycle(earlier)
        let fresh = try install("B", on: false)
        try await deleteFromICloud(earlier.store.profiles.map(\.id), by: fresh)
        let deleted = server.records(account: "alice").filter { !$0.value.payload.isAlive }
        XCTAssertFalse(deleted.isEmpty)
        guard case .empty = await look(fresh) else { return XCTFail("iCloud has no sidebar") }

        let before = fresh.store.makeSnapshot()
        let rows = pinned(fresh.store)
        fresh.sync.setEnabled(true)
        await cycle(fresh)
        XCTAssertEqual(pinned(fresh.store), rows, "every space and pinned row stays")
        XCTAssertEqual(Set(fresh.store.profiles.map(\.id)), Set(before.profiles.map(\.id)))

        let cloud = server.records(account: "alice")
        for name in SidebarSyncProjection.extract(fresh.store.makeSnapshot()).keys {
            XCTAssertEqual(cloud[name]?.payload.isAlive, true, name)
        }
        XCTAssertEqual(fresh.sync.state.pendingCount, 0)
        let again = try await sidebar(fresh)
        XCTAssertEqual(again.profiles(notIn: fresh.store.profiles, spaces: fresh.store.spaces), [])
        for profile in fresh.store.profiles {
            XCTAssertEqual(ProfileCloudPresence.of(profile.id, detection: .found(again), looking: false), .inICloud, "in iCloud by its own id")
        }
    }

    /// iCloud still has another profile: switching on asks, and Merge with
    /// the profile put in iCloud brings it back there whole.
    func testPutInICloudWinsOverICloudsDeletedCopyInAMerge() async throws {
        let earlier = try install("A", on: true)
        await cycle(earlier)
        let fresh = try install("B", on: false)
        let found = try await sidebar(fresh)
        let studio = try XCTUnwrap(fresh.store.profiles.first { $0.name == "Studio" })
        let cloudStudio = try XCTUnwrap(found.profiles(matching: studio.id, spaces: fresh.store.spaces).first)
        try await deleteFromICloud([cloudStudio.id], by: fresh)
        let rows = pinned(fresh.store)
        let studioSpaces = fresh.store.spaces(in: studio.id).map(\.id)
        XCTAssertFalse(studioSpaces.isEmpty)

        fresh.sync.putInICloud([studio.id])
        XCTAssertEqual(fresh.state.state.putInICloud, [studio.id], "kept until the join")
        fresh.sync.apply(.merge, from: try await sidebar(fresh))
        XCTAssertEqual(fresh.state.state.putInICloud, [studio.id], "a merge joins at the next cycle")
        await cycle(fresh)
        XCTAssertNil(fresh.sync.state.putInICloud, "used once")
        for space in studioSpaces {
            XCTAssertEqual(pinned(fresh.store)[space], rows[space], "Studio's spaces keep their rows")
            XCTAssertEqual(server.records(account: "alice")[SyncRecordKind.space.recordName(for: space)]?.payload.isAlive, true)
        }
        let after = try await sidebar(fresh)
        XCTAssertEqual(ProfileCloudPresence.of(try XCTUnwrap(fresh.store.space(withID: studioSpaces[0])).profileID, spaces: fresh.store.spaces,
                                               detection: .found(after), looking: false), .inICloud)

        // The earlier install gets it back too.
        await cycle(earlier)
        XCTAssertTrue(studioSpaces.allSatisfy { id in earlier.store.spaces.contains { $0.id == id } })
    }

    /// Without Put in iCloud, a merge keeps iCloud's deletes (RC-0.1.0-602
    /// T-02): the profile put back is the one the person chose.
    func testOnlyTheProfilePutInICloudWinsOverDeletes() async throws {
        let earlier = try install("A", on: true)
        await cycle(earlier)
        let fresh = try install("B", on: false)
        let found = try await sidebar(fresh)
        let studio = try XCTUnwrap(fresh.store.profiles.first { $0.name == "Studio" })
        try await deleteFromICloud(found.profiles(matching: studio.id, spaces: fresh.store.spaces).map(\.id), by: fresh)
        let studioSpaces = fresh.store.spaces(in: studio.id).map(\.id)
        fresh.sync.apply(.merge, from: try await sidebar(fresh))
        await cycle(fresh)
        for space in studioSpaces {
            XCTAssertEqual(server.records(account: "alice")[SyncRecordKind.space.recordName(for: space)]?.payload.isAlive, false)
        }
    }

    /// The records a profile owns: itself, its spaces, their rows (in
    /// folders too) and its favorites; nothing of another profile.
    func testTheRecordsOfAProfile() throws {
        let store = try install("B", on: false).store
        let studio = try XCTUnwrap(store.profiles.first { $0.name == "Studio" })
        let snapshot = store.makeSnapshot()
        let names = SidebarSyncCoordinator.records(of: [studio.id], in: snapshot)
        let all = SidebarSyncProjection.extract(snapshot)
        let others = SidebarSyncCoordinator.records(of: Set(store.profiles.map(\.id)).subtracting([studio.id]), in: snapshot)
        XCTAssertTrue(names.contains(SyncRecordKind.profile.recordName(for: studio.id)))
        XCTAssertTrue(store.spaces(in: studio.id).allSatisfy { names.contains(SyncRecordKind.space.recordName(for: $0.id)) })
        XCTAssertTrue(names.isDisjoint(with: others))
        XCTAssertEqual(names.union(others), Set(all.keys), "every record belongs to one profile")
        XCTAssertEqual(SidebarSyncCoordinator.records(of: [], in: snapshot), [])
    }

    // MARK: - The claim is dropped

    func testPutInICloudIsDroppedWhenSyncGoesOffAndAtLoad() async throws {
        let fresh = try install("B", on: false)
        let id = fresh.store.profiles[0].id
        fresh.sync.putInICloud([id])
        XCTAssertEqual(fresh.state.state.putInICloud, [id])
        fresh.sync.setEnabled(false)
        XCTAssertNil(fresh.state.state.putInICloud, "switched off: no claim left for a later join")

        fresh.sync.putInICloud([id])
        let reloaded = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(fresh.state.state), deviceID: "B")
        XCTAssertNil(reloaded.state.putInICloud, "sync off at load: none")

        // Joined already: nothing to keep, a cycle uploads every profile anyway.
        let on = try install("C", on: true)
        await cycle(on)
        on.sync.putInICloud([on.store.profiles[0].id])
        XCTAssertNil(on.state.state.putInICloud)
    }

    /// Delete iCloud Content… removes the zone: no deleted records are left
    /// to hold this Mac's sidebar back when sync is switched on again.
    func testAfterDeletingICloudContentSwitchingOnUploadsEverything() async throws {
        let mac = try install("A", on: true)
        await cycle(mac)
        try await mac.sync.deleteCloudSidebar()
        XCTAssertFalse(mac.sync.isEnabled)
        XCTAssertTrue(server.records(account: "alice").isEmpty)
        let rows = pinned(mac.store)
        mac.sync.setEnabled(true)
        await cycle(mac)
        XCTAssertEqual(pinned(mac.store), rows)
        let cloud = server.records(account: "alice")
        XCTAssertTrue(SidebarSyncProjection.extract(mac.store.makeSnapshot()).keys.allSatisfy { cloud[$0]?.payload.isAlive == true })
    }
}
