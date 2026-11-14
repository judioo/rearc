import XCTest
@testable import SidebarModel

/// Which profile in iCloud is this Mac's under another id (RC-2026.1113.765
/// Y-01): only one whose every space is a space of this Mac's profile. One
/// that shares a space and holds another besides is a profile of its own,
/// listed "In iCloud only" and never the target of this Mac's delete.
/// Everything runs against `InMemorySyncServer`, never CloudKit.
@MainActor
final class CloudProfileMatchTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        server = InMemorySyncServer()
    }

    /// An Arc profile's import as ReArc makes it: a profile with an id of
    /// this install's, spaces with ids that follow from Arc's.
    @discardableResult
    private func importArc(_ name: String, spaces: [String], into store: SidebarStore) -> Profile.ID {
        let profile = store.addProfile(name: name, createInitialSpace: false).id
        for space in spaces {
            let source = "Default:\(space)"
            let made = store.addSpace(name: space, profileID: profile, id: SidebarStore.arcSpaceID(source))
            store.spaces[store.spaces.firstIndex { $0.id == made.id }!].arcSourceID = source
            _ = store.addTab(kind: .pinned, title: space, url: URL(string: "https://\(space.lowercased()).test")!, in: made.id,
                             tabID: SidebarStore.arcItemID("\(source):0"))
        }
        return profile
    }

    /// An install whose only profiles are imports, synced when `on`.
    private func install(_ device: String, on: Bool, _ imports: [(String, [String])]) async -> (store: SidebarStore, sync: SidebarSyncCoordinator, profiles: [Profile.ID]) {
        let store = SidebarStore()
        let starter = store.activeProfileID
        let profiles = imports.map { importArc($0.0, spaces: $0.1, into: store) }
        _ = store.deleteProfile(starter, deletingSpaces: true)
        var state = SidebarSyncState()
        state.enabled = on
        state.decision = on ? .user : nil
        let sync = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(state), deviceID: device,
                                          now: { [unowned self] in self.date })
        sync.host = store
        if on {
            date += 2
            _ = await sync.sync()
        }
        return (store, sync, profiles)
    }

    private func look(_ sync: SidebarSyncCoordinator) async throws -> CloudSidebarFound {
        date += 2
        let detection = await sync.detectCloudSidebar()
        return try XCTUnwrap(detection.found)
    }

    // MARK: - A partial overlap

    /// An earlier install synced one "Personal" with Arc's Home and Work;
    /// this install made "Personal" (Home) and "Work" (Work) of the same
    /// Arc. iCloud's "Personal" is neither: deleting this Mac's "Personal"
    /// must not take Work with it.
    func testAProfileThatOnlySharesASpaceIsNoMatch() async throws {
        let earlier = await install("A", on: true, [("Personal", ["Home", "Work"])])
        let fresh = await install("B", on: false, [("Personal", ["Home"]), ("Work", ["Work"])])
        let found = try await look(fresh.sync)
        XCTAssertEqual(found.profiles.map(\.id), earlier.profiles)
        XCTAssertEqual(Set(found.profiles[0].spaces.map(\.id)), Set(fresh.store.spaces.map(\.id)), "the same Arc spaces, split over two profiles here")

        for (profile, name) in zip(fresh.profiles, ["Personal", "Work"]) {
            XCTAssertEqual(found.profiles(matching: profile, spaces: fresh.store.spaces, among: fresh.store.profiles), [], name)
            let presence = ProfileCloudPresence.of(profile, spaces: fresh.store.spaces, detection: .found(found), looking: false)
            XCTAssertEqual(presence, .onlyHere, name)
            XCTAssertEqual(ProfileCloudText.status(presence), "Only on this Mac", name)
            XCTAssertEqual(ProfileCloudText.note(presence, syncOn: false), ProfileCloudText.putInICloudNote, "\(name): Put in iCloud… is offered")
        }
        let cloudOnly = found.profiles(notIn: fresh.store.profiles, spaces: fresh.store.spaces)
        XCTAssertEqual(cloudOnly.map(\.id), earlier.profiles, "iCloud's “Personal” is listed “In iCloud only”")
        XCTAssertEqual(cloudOnly.first?.spaces.map(\.name), ["Home", "Work"])
    }

    /// The same by Arc source alone, where the space ids differ too.
    func testAPartialOverlapByArcSourceIsNoMatch() {
        let local = Profile(name: "Personal")
        var home = Space(name: "Home", profileID: local.id)
        home.arcSourceID = "Default:Home"
        let cloud = CloudProfile(profile: Profile(name: "Personal"), spaces: [
            CloudSpace(id: UUID(), name: "Home", pinnedTabs: 4, arcSourceID: "Default:Home"),
            CloudSpace(id: UUID(), name: "Work", pinnedTabs: 9, arcSourceID: "Default:Work"),
        ])
        let found = CloudSidebarFound(accountID: "alice", records: [], summary: CloudSidebarSummary(spaces: 2, pinnedTabs: 13, favorites: 0, lastUpdated: nil),
                                      profiles: [cloud])
        XCTAssertEqual(found.profiles(matching: local.id, spaces: [home], among: [local]), [])
        XCTAssertEqual(found.profiles(notIn: [local], spaces: [home]), [cloud])

        // With Work in the same profile here, every space of iCloud's is this profile's.
        var work = Space(name: "Office", profileID: local.id)
        work.arcSourceID = "Default:Work"
        XCTAssertEqual(found.profiles(matching: local.id, spaces: [home, work], among: [local]), [cloud])
        // Work in another profile here: still split, still no match for either.
        let other = Profile(name: "Work")
        work.profileID = other.id
        XCTAssertEqual(found.profiles(matching: local.id, spaces: [home, work], among: [local, other]), [])
        XCTAssertEqual(found.profiles(matching: other.id, spaces: [home, work], among: [local, other]), [])
    }

    // MARK: - A full subset

    /// iCloud's profile holds some of this profile's spaces and no other:
    /// it is this profile, also when this Mac's has a space more.
    func testAProfileWhoseEverySpaceIsThisProfilesMatches() async throws {
        let earlier = await install("A", on: true, [("Personal", ["Home", "Work"])])
        let fresh = await install("B", on: false, [("Mine", ["Home", "Work", "Travel"])])
        _ = fresh.store.addSpace(name: "Made here", profileID: fresh.profiles[0])
        let found = try await look(fresh.sync)
        XCTAssertEqual(found.profiles(matching: fresh.profiles[0], spaces: fresh.store.spaces, among: fresh.store.profiles).map(\.id), earlier.profiles)
        XCTAssertEqual(ProfileCloudPresence.of(fresh.profiles[0], spaces: fresh.store.spaces, detection: .found(found), looking: false), .inICloud)
        XCTAssertEqual(found.profiles(notIn: fresh.store.profiles, spaces: fresh.store.spaces), [], "not “In iCloud only”")
    }

    /// A profile in iCloud with no spaces holds nothing of this Mac's.
    func testAProfileWithNoSpacesIsNoMatch() {
        let local = Profile(name: "Personal")
        let home = Space(name: "Home", profileID: local.id)
        let empty = CloudProfile(profile: Profile(name: "Empty"), spaces: [])
        let found = CloudSidebarFound(accountID: "alice", records: [], summary: CloudSidebarSummary(spaces: 0, pinnedTabs: 0, favorites: 0, lastUpdated: nil),
                                      profiles: [empty])
        XCTAssertEqual(found.profiles(matching: local.id, spaces: [home], among: [local]), [])
        XCTAssertEqual(found.profiles(notIn: [local], spaces: [home]), [empty])
    }

    /// A profile in iCloud with the id of a profile of this Mac is that
    /// profile, whatever spaces it holds: never another profile's copy.
    func testAProfileWithALocalProfilesIDIsNeverAnotherProfilesCopy() {
        let personal = Profile(name: "Personal")
        let work = Profile(name: "Work")
        let home = Space(name: "Home", profileID: personal.id)
        // iCloud's "Work" (this Mac's Work, by id) holds only Home, which this Mac has in Personal.
        let cloud = CloudProfile(profile: work, spaces: [CloudSpace(id: home.id, name: "Home", pinnedTabs: 1)])
        let found = CloudSidebarFound(accountID: "alice", records: [], summary: CloudSidebarSummary(spaces: 1, pinnedTabs: 1, favorites: 0, lastUpdated: nil),
                                      profiles: [cloud])
        XCTAssertEqual(found.profiles(matching: personal.id, spaces: [home], among: [personal, work]), [])
        XCTAssertEqual(found.profiles(matching: work.id, spaces: [home], among: [personal, work]), [cloud], "by its id")
        XCTAssertEqual(found.profiles(notIn: [personal, work], spaces: [home]), [])
    }

    // MARK: - What the delete says

    func testTheDeleteNamesICloudsCopyAndItsSpaces() {
        let cloud = CloudProfile(profile: Profile(name: "Old Personal"), spaces: [
            CloudSpace(id: UUID(), name: "Home", pinnedTabs: 12),
            CloudSpace(id: UUID(), name: "Work", pinnedTabs: 1),
        ])
        XCTAssertEqual(ProfileCloudText.cloudCopy(cloud),
                       "In iCloud it is “Old Personal”, from another Mac or an earlier install, with 2 spaces: Home (12 pinned tabs) and Work (1 pinned tab).")
        var one = cloud
        one.spaces.removeLast()
        XCTAssertEqual(ProfileCloudText.cloudCopy(one),
                       "In iCloud it is “Old Personal”, from another Mac or an earlier install, with 1 space: Home (12 pinned tabs).")

        var many = cloud
        many.spaces = (1 ... 13).map { CloudSpace(id: UUID(), name: "S\($0)", pinnedTabs: 0) }
        let text = ProfileCloudText.cloudCopy(many)
        XCTAssertTrue(text.contains("with 13 spaces: S1 (0 pinned tabs), "), text)
        XCTAssertTrue(text.hasSuffix("S10 (0 pinned tabs) and 3 more."), text)

        XCTAssertEqual(ProfileCloudText.noLongerACopy("Old Personal", of: "Personal"),
                       "“Old Personal” in iCloud now holds spaces that are not in this Mac’s “Personal”, so it is a profile of its own. "
                           + "Nothing was deleted. It is listed under In iCloud only.")
    }
}
