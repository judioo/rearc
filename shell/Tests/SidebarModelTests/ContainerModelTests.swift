import XCTest
@testable import SidebarModel

/// Build 608's and 677's `Profile` decoding, as in their Profile.swift
/// (583f1a8e, 195aebe8): a keyed container that skips keys it does not know.
private struct Profile677: Decodable, Equatable {
    let id: UUID
    let name: String
    enum CodingKeys: String, CodingKey { case id, name, avatar, themeColor }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        _ = try c.decodeIfPresent(ProfileAvatarDescriptor.self, forKey: .avatar)
        _ = try c.decodeIfPresent(SpaceTheme.self, forKey: .themeColor)
    }
}

/// Containers inside profiles (docs/SPACE-CONTAINERS.md).
final class ContainerModelTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// Personal with Mail, Bank and News; Bank gets a container.
    private func makeStore() throws -> (store: SidebarStore, personal: Profile.ID, mail: Space, bank: Space, news: Space, container: Profile) {
        let store = SidebarStore(spaces: [Space(name: "Mail", sortRank: "b")])
        let personal = store.activeProfileID
        let mail = store.spaces[0]
        let bank = store.addSpace(name: "Bank", profileID: personal)
        let news = store.addSpace(name: "News", profileID: personal)
        let container = try XCTUnwrap(store.createContainer(forSpace: bank.id))
        return (store, personal, mail, try XCTUnwrap(store.space(withID: bank.id)), news, container)
    }

    // MARK: Model rules

    func testCreatingAContainerKeepsTheSpaceInItsProfileAndPlace() throws {
        let f = try makeStore()
        XCTAssertEqual(f.container.containerOf, f.personal)
        XCTAssertEqual(f.bank.profileID, f.container.id, "the storage key moves to the container")
        XCTAssertEqual(f.bank.sortRank, f.store.spaces(listedIn: f.personal)[1].sortRank)
        XCTAssertEqual(f.store.spaces(listedIn: f.personal).map(\.name), ["Mail", "Bank", "News"], "same place in the strip")
        XCTAssertEqual(f.store.spaces(listedIn: f.container.id).map(\.name), ["Mail", "Bank", "News"])
        XCTAssertEqual(f.store.spaces(in: f.personal).map(\.name), ["Mail", "News"], "storage stays exact")
        XCTAssertEqual(f.store.listedProfiles.map(\.id), [f.personal])
        XCTAssertTrue(f.store.isContainer(f.container.id))
        XCTAssertEqual(f.store.owningProfileID(of: f.container.id), f.personal)
        XCTAssertNil(f.store.createContainer(forSpace: f.bank.id), "a container is never the parent of another")
        XCTAssertEqual(f.store.containers(of: f.personal).map(\.id), [f.container.id])
        XCTAssertEqual(f.store.containerTitle(f.container.id), "Container for Bank")
    }

    func testAContainerHasExactlyOneSpaceAndIsNeverAParent() throws {
        let f = try makeStore()
        let extra = f.store.addSpace(name: "Extra", profileID: f.container.id)
        XCTAssertEqual(extra.profileID, f.personal, "a second space goes to the parent's own session")
        XCTAssertEqual(f.store.profileChangeBlocker(forSpace: f.news.id, to: f.container.id), .profileIsContainer)
        XCTAssertFalse(f.store.profileChoices(forSpace: f.news.id).contains { $0.id == f.container.id })
        let work = f.store.addProfile(name: "Work")
        XCTAssertEqual(f.store.containerConversionBlocker(work.id, of: f.container.id), .parentIsContainer)
        XCTAssertEqual(f.store.containerConversionBlocker(f.personal, of: work.id), .firstProfile)

        // A link that does not hold leaves a plain profile.
        var snapshot = f.store.makeSnapshot()
        let index = try XCTUnwrap(snapshot.profiles.firstIndex { $0.id == f.container.id })
        snapshot.profiles[index].containerOf = UUID()
        let dangling = SidebarStore(spaces: [Space(name: "x")])
        dangling.applySnapshot(snapshot)
        XCTAssertFalse(dangling.isContainer(f.container.id))
        XCTAssertEqual(dangling.listedProfiles.count, 3, "Personal, Work and the former container")
        snapshot.profiles[index].containerOf = f.container.id
        dangling.applySnapshot(snapshot)
        XCTAssertFalse(dangling.isContainer(f.container.id), "its own parent")
    }

    func testDeletingAParentTakesItsContainersWithIt() throws {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let work = store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(store.spaces(in: work.id).first)
        let client = store.addSpace(name: "Client", profileID: work.id)
        let container = try XCTUnwrap(store.createContainer(forSpace: client.id))
        let littleArc = store.createLittleArcWindow(url: url("client.test"), profileID: container.id)
        XCTAssertEqual(store.profilesDeleted(with: work.id), [work.id, container.id])
        XCTAssertEqual(store.deleteProfile(work.id), .profileOwnsSpaces(count: 2))
        XCTAssertNil(store.deleteProfile(work.id, deletingSpaces: true))
        XCTAssertNil(store.profile(withID: container.id))
        XCTAssertNil(store.space(withID: client.id))
        XCTAssertNil(store.space(withID: workSpace.id))
        XCTAssertNil(store.littleArcWindow(withID: littleArc.id), "S-07: its Little ReArcs go too")

        // The last profile with containers cannot go.
        let only = try XCTUnwrap(store.createContainer(forSpace: store.spaces[0].id))
        XCTAssertEqual(store.deleteProfile(store.profiles[0].id, deletingSpaces: true), .cannotDeleteLastProfile)
        XCTAssertEqual(store.deleteProfile(only.id), .profileOwnsSpaces(count: 1))
        XCTAssertNil(store.deleteProfile(only.id, deletingSpaces: true), "a container alone can go")
    }

    func testRemovingAContainerPutsTheSpaceBackInPlace() throws {
        let f = try makeStore()
        f.store.selectSpace(f.bank.id)
        XCTAssertEqual(f.store.moveSpaceOutOfContainer(f.bank.id), f.container.id)
        let bank = try XCTUnwrap(f.store.space(withID: f.bank.id))
        XCTAssertEqual(bank.profileID, f.personal)
        XCTAssertEqual(bank.sortRank, f.bank.sortRank)
        XCTAssertEqual(f.store.activeProfileID, f.personal)
        XCTAssertNil(f.store.deleteProfile(f.container.id), "no space left in it")
        XCTAssertEqual(f.store.spaces(listedIn: f.personal).map(\.name), ["Mail", "Bank", "News"])
        XCTAssertNil(f.store.moveSpaceOutOfContainer(f.bank.id))
    }

    func testChangeProfileTakesTheContainerAlong() throws {
        let f = try makeStore()
        let work = f.store.addProfile(name: "Work")
        XCTAssertTrue(f.store.profileChangeKeepsStorage(forSpace: f.bank.id))
        XCTAssertEqual(f.store.profileChangeBlocker(forSpace: f.bank.id, to: f.personal), .sameProfile)
        XCTAssertNil(f.store.changeProfile(ofSpace: f.bank.id, to: work.id))
        XCTAssertEqual(f.store.space(withID: f.bank.id)?.profileID, f.container.id, "same storage")
        XCTAssertEqual(f.store.parentProfile(ofContainer: f.container.id)?.id, work.id)
        XCTAssertEqual(f.store.spaces(listedIn: work.id).map(\.name), ["Space 1", "Bank"])
        XCTAssertEqual(f.store.spaces(listedIn: f.personal).map(\.name), ["Mail", "News"])
        XCTAssertFalse(f.store.profileChangeKeepsStorage(forSpace: f.news.id))
    }

    func testDeletingAContainersSpaceLeavesTheContainerToTheCaller() throws {
        let f = try makeStore()
        XCTAssertTrue(f.store.removeSpace(f.bank.id))
        XCTAssertTrue(f.store.isContainer(f.container.id), "the shell deletes it with its data (deleteSpace)")
        XCTAssertEqual(f.store.containerTitle(f.container.id), "Container (no space)")
    }

    // MARK: Lists by profile

    func testSwitchingAndMemoryListAContainersSpaceWithItsParent() throws {
        let f = try makeStore()
        let work = f.store.addProfile(name: "Work")
        f.store.selectSpace(f.mail.id)
        XCTAssertTrue(f.store.selectSpace(atIndex: 1), "⌃2")
        XCTAssertEqual(f.store.activeSpaceID, f.bank.id)
        XCTAssertEqual(f.store.activeProfileID, f.container.id, "storage follows the space")
        XCTAssertEqual(f.store.activeOwningProfileID, f.personal)
        f.store.cycleSpace(forward: true)
        XCTAssertEqual(f.store.activeSpaceID, f.news.id)
        f.store.cycleSpace(forward: false)
        XCTAssertEqual(f.store.activeSpaceID, f.bank.id)
        XCTAssertEqual(f.store.spacesInActiveProfile.map(\.id), [f.mail.id, f.bank.id, f.news.id])

        // Last active space per profile: back to the container's space.
        f.store.selectProfile(work.id)
        XCTAssertEqual(f.store.activeProfileID, work.id)
        f.store.selectProfile(f.personal)
        XCTAssertEqual(f.store.activeSpaceID, f.bank.id)
        XCTAssertEqual(f.store.activeProfileID, f.container.id)
        XCTAssertEqual(f.store.lastActiveSpaceByProfile[f.personal], f.bank.id)
        XCTAssertEqual(f.store.restoredSpaceID(saved: nil, profileID: f.personal), f.bank.id, "window restore")
        XCTAssertEqual(f.store.restoredSpaceID(saved: nil, profileID: f.container.id), f.bank.id)

        // Selecting the container itself shows its space; selecting a parent with
        // only a container's space makes no landing space.
        f.store.selectProfile(work.id)
        f.store.selectProfile(f.container.id)
        XCTAssertEqual(f.store.activeSpaceID, f.bank.id)
        let count = f.store.spaces.count
        f.store.selectProfile(work.id)
        f.store.selectProfile(f.personal)
        XCTAssertEqual(f.store.spaces.count, count)
    }

    func testReorderingMovesAContainersSpaceAmongItsParents() throws {
        let f = try makeStore()
        XCTAssertTrue(f.store.moveSpace(f.bank.id, toIndex: 0))
        XCTAssertEqual(f.store.spaces(listedIn: f.personal).map(\.name), ["Bank", "Mail", "News"])
        XCTAssertTrue(f.store.moveSpace(f.news.id, toIndex: 0))
        XCTAssertEqual(f.store.spaces(listedIn: f.personal).map(\.name), ["News", "Bank", "Mail"])
    }

    func testMenusAndCommandsListProfilesOnly() throws {
        let f = try makeStore()
        let work = f.store.addProfile(name: "Work")
        let rows = f.store.profileMenuRows(active: f.container.id)
        XCTAssertEqual(rows.map(\.id), [f.personal, work.id])
        XCTAssertEqual(rows.map(\.spaceCount), [3, 1], "a profile's count includes its containers' spaces")
        XCTAssertEqual(rows.map(\.isActive), [true, false], "a container checks its parent")
        let littleArc = f.store.profileMenuRows(active: f.container.id, includingContainers: true)
        XCTAssertEqual(littleArc.map(\.id), [f.personal, f.container.id, work.id])
        XCTAssertEqual(littleArc.map(\.title), ["Personal", "Container for Bank", "Work"])
        XCTAssertEqual(littleArc.map(\.isActive), [false, true, false], "the exact session")

        f.store.selectSpace(f.mail.id)
        f.store.selectTab(f.store.addTab(kind: .today, title: "Inbox", url: url("mail.test"), in: f.mail.id).id)
        let context = CommandBarContext(store: f.store, isSidebarVisible: true, closedTabStack: f.store.closedTabStack)
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.contains { $0.action == .switchToSpace(f.bank.id) }, "command bar")
        XCTAssertTrue(commands.contains { $0.action == .moveTabToSpace(f.bank.id) })
        XCTAssertFalse(commands.contains { $0.action == .switchToProfile(f.container.id) })
        XCTAssertFalse(commands.contains { $0.action == .moveSpaceToProfile(f.container.id) })
        f.store.selectSpace(f.bank.id)
        let switchBack = AppCommand(id: "t", title: "t", keywords: [], minQueryLength: 0, action: .switchToProfile(f.personal))
        XCTAssertFalse(switchBack.isEnabled(in: context), "already there")

        XCTAssertEqual(LibrarySpaces.groups(in: f.store).map { $0.rows.map(\.space.name) }, [["Mail", "Bank", "News"], ["Space 1"]])
    }

    func testMoveToSpaceListsContainersAndTheCrossingIsFlagged() throws {
        let f = try makeStore()
        let work = f.store.addProfile(name: "Work")
        let tab = f.store.addTab(kind: .today, title: "Inbox", url: url("mail.test"), in: f.mail.id)
        XCTAssertEqual(f.store.spaceMoveDestinations(from: f.mail.id).map(\.name), ["Bank", "News"])
        XCTAssertTrue(f.store.crossesProfile([tab.id], toSpace: f.bank.id), "into a container: another session")
        XCTAssertFalse(f.store.crossesProfile([tab.id], toSpace: f.news.id))
        let destinations = f.store.profileMoveDestinations(from: f.mail.id)
        XCTAssertEqual(destinations.map(\.profile.id), [work.id])
        XCTAssertEqual(f.store.profileMoveDestinations(from: f.bank.id).map(\.profile.id), [work.id], "the container's own profile is not another")
    }

    /// S-01, S-03: a page made in a profile never lands in one of its containers' spaces.
    func testPagesNeverLandInAContainersSpace() throws {
        let f = try makeStore()
        f.store.selectSpace(f.bank.id)
        XCTAssertEqual(f.store.space(forNewTabIn: f.personal), f.mail.id)
        XCTAssertEqual(f.store.space(forNewTabIn: f.personal, preferring: f.bank.id), f.mail.id)
        XCTAssertEqual(f.store.space(forNewTabIn: f.container.id), f.bank.id)

        let window = f.store.createLittleArcWindow(url: url("personal.test"), profileID: f.personal)
        XCTAssertEqual(f.store.littleArcTargetSpace(for: window.id)?.profileID, f.personal)
        let promoted = try XCTUnwrap(f.store.promoteLittleArcToTab(id: window.id))
        let landed = try XCTUnwrap(f.store.spaceContaining(tabID: promoted.id))
        XCTAssertEqual(f.store.space(withID: landed)?.profileID, f.personal, "not the active container's space")

        f.store.selectSpace(f.bank.id)
        f.store.selectSpace(usingStorageOf: f.personal)
        XCTAssertEqual(f.store.activeSpace.profileID, f.personal)
    }

    // MARK: Settings

    func testPerProfileSettingsComeFromTheParent() throws {
        let f = try makeStore()
        f.store.setAutoArchiveThreshold(.sevenDays, for: f.personal)
        XCTAssertEqual(f.store.autoArchiveThreshold(for: f.container.id), .sevenDays)
        f.store.setAutoArchiveThreshold(.thirtyDays, for: f.container.id)
        XCTAssertEqual(f.store.autoArchiveThreshold(for: f.personal), .thirtyDays, "set on the parent")
        XCTAssertNil(f.store.autoArchiveThresholdByProfile[f.container.id])
        f.store.selectSpace(f.bank.id)
        XCTAssertEqual(f.store.autoArchiveThreshold(), .thirtyDays)
    }

    // MARK: Profiles made by earlier builds

    func testAnEarlierContainerIsOfferedAndConvertedOnlyWhenChosen() throws {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let personal = store.activeProfileID
        // What the old New Container for This Space made: a plain profile named after its space.
        let old = store.createContainerProfile(name: "Bank", theme: .default)
        let bank = store.addSpace(name: "Bank", profileID: old.id)
        let clash = store.createContainerProfile(name: "Bank", theme: .default)
        _ = store.addSpace(name: "Bank", profileID: clash.id)
        let work = store.addProfile(name: "Work")
        _ = store.addSpace(name: "Second", profileID: work.id)
        XCTAssertFalse(old.containerOf != nil || clash.containerOf != nil)
        XCTAssertTrue(store.looksLikeEarlierContainer(old.id))
        XCTAssertTrue(store.looksLikeEarlierContainer(clash.id), "“Bank 2”")
        XCTAssertFalse(store.looksLikeEarlierContainer(work.id), "two spaces")
        XCTAssertFalse(store.looksLikeEarlierContainer(personal), "the first profile")
        XCTAssertEqual(store.containerParentChoices(for: old.id).map(\.id), [personal, clash.id, work.id])
        XCTAssertFalse(store.isContainer(old.id), "nothing changes by itself")

        XCTAssertNil(store.makeContainer(old.id, of: personal))
        XCTAssertEqual(store.space(withID: bank.id)?.profileID, old.id, "storage stays")
        XCTAssertEqual(store.spaces(listedIn: personal).map(\.name), ["Personal", "Bank"])
        XCTAssertFalse(store.listedProfiles.contains { $0.id == old.id })
        XCTAssertEqual(store.makeContainer(old.id, of: personal), .unchanged)
        XCTAssertEqual(store.containerConversionBlocker(personal, of: work.id), .firstProfile)
        XCTAssertEqual(store.containerConversionBlocker(work.id, of: personal), .needsExactlyOneSpace(count: 2))

        XCTAssertNil(store.makeProfile(old.id))
        XCTAssertEqual(store.spaces(listedIn: old.id).map(\.id), [bank.id])
        XCTAssertTrue(store.listedProfiles.contains { $0.id == old.id })
        XCTAssertEqual(store.makeProfile(old.id), .unchanged)
    }

    // MARK: Decoding, other builds, sync

    func testDecodingIsTotal() throws {
        let id = UUID(), parent = UUID()
        func decode(_ extra: String) throws -> Profile {
            try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"\#(id)","name":"Bank"\#(extra)}"#.utf8))
        }
        XCTAssertEqual(try decode(#","containerOf":"\#(parent)""#).containerOf, parent)
        XCTAssertNil(try decode("").containerOf)
        XCTAssertNil(try decode(#","containerOf":null"#).containerOf)
        XCTAssertNil(try decode(#","containerOf":"not a uuid""#).containerOf)
        XCTAssertNil(try decode(#","containerOf":42"#).containerOf)
        let round = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(Profile(id: id, name: "Bank", containerOf: parent)))
        XCTAssertEqual(round.containerOf, parent)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Profile(name: "Plain")), as: UTF8.self).contains("containerOf"),
                       "a profile writes no key")
    }

    @MainActor
    func testA677FileLoadsWithNoContainers() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-677c-\(UUID().uuidString)/sidebar.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(Sidebar677Fixture.json.utf8).write(to: file)
        let persistence = SidebarFilePersistence(fileURL: file)
        let snapshot = try XCTUnwrap(persistence.loadSnapshot())
        XCTAssertEqual(persistence.loadOutcome, .loaded)
        let store = SidebarStore(spaces: [Space(name: "x")])
        store.applySnapshot(snapshot)
        XCTAssertTrue(snapshot.profiles.allSatisfy { $0.containerOf == nil })
        XCTAssertEqual(store.listedProfiles.count, 3)
        XCTAssertEqual(store.spaces(listedIn: Sidebar677Fixture.profileIDs.personal).map(\.name), store.spaces(in: Sidebar677Fixture.profileIDs.personal).map(\.name))
    }

    /// A file this build writes loads in 608 and 677: the schema version is theirs and
    /// their Profile decoder skips `containerOf`, so the container is a plain profile.
    func testAFileWithContainersDecodesIn608And677() throws {
        let f = try makeStore()
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 10, "608 and 677 refuse a later schema")
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertTrue(profiles.contains { $0["containerOf"] as? String != nil })
        let old = try JSONDecoder().decode([Profile677].self, from: JSONSerialization.data(withJSONObject: profiles))
        XCTAssertEqual(old.map(\.id), [f.personal, f.container.id])
        XCTAssertEqual(old.map(\.name), ["Personal", "Bank"])
        // And the 677 fixture with a container added still decodes through this build.
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Sidebar677Fixture.json.utf8)) as? [String: Any])
        var fixtureProfiles = try XCTUnwrap(fixture["profiles"] as? [[String: Any]])
        fixtureProfiles[2]["containerOf"] = Sidebar677Fixture.profileIDs.personal.uuidString
        fixture["profiles"] = fixtureProfiles
        let snapshot = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: fixture))
        XCTAssertEqual(snapshot.profiles[2].containerOf, Sidebar677Fixture.profileIDs.personal)
    }

    func testTheParentLinkSyncsInTheProfileRecord() throws {
        let f = try makeStore()
        let records = SidebarSyncProjection.extract(f.store.makeSnapshot())
        let body = try XCTUnwrap(records[SyncRecordKind.profile.recordName(for: f.container.id)])
        XCTAssertEqual(body.values["containerOf"]?.stringValue.flatMap(UUID.init(uuidString:)), f.personal)
        XCTAssertNil(records[SyncRecordKind.profile.recordName(for: f.personal)]?.values["containerOf"])

        func payloads(_ records: [String: SyncRecordBody]) -> [String: SyncRecordPayload] {
            records.mapValues { SyncRecordPayload(kind: $0.kind, fields: $0.values.mapValues { SyncField(value: $0, stamp: SyncStamp(millis: 1, device: "B")) }) }
        }
        let other = SidebarStore(spaces: [Space(name: "Other")])
        other.applySnapshot(SidebarSyncProjection.apply(payloads(records), onto: other.makeSnapshot()))
        XCTAssertEqual(other.parentProfile(ofContainer: f.container.id)?.id, f.personal, "another Mac gets the link")

        // A Mac on 677 sends the record without the key: the link here stays.
        var old = records
        old[SyncRecordKind.profile.recordName(for: f.container.id)]?.values["containerOf"] = nil
        let applied = SidebarSyncProjection.apply(payloads(old), onto: f.store.makeSnapshot())
        XCTAssertEqual(applied.profiles.first { $0.id == f.container.id }?.containerOf, f.personal)
        // Make This a Profile elsewhere sends null: the link goes.
        var cleared = records
        cleared[SyncRecordKind.profile.recordName(for: f.container.id)]?.values["containerOf"] = .null
        let plain = SidebarSyncProjection.apply(payloads(cleared), onto: f.store.makeSnapshot())
        XCTAssertNil(plain.profiles.first { $0.id == f.container.id }?.containerOf)
    }

    // MARK: Showing it

    func testTheChipNamesTheEnginesContainer() throws {
        let f = try makeStore()
        XCTAssertEqual(f.store.containerLabel(forEngineProfile: f.container.id),
                       ContainerLabel(containerID: f.container.id, name: "Bank", theme: f.bank.theme))
        XCTAssertNil(f.store.containerLabel(forEngineProfile: f.personal))
        XCTAssertNil(f.store.containerLabel(forEngineProfile: nil))
        f.store.renameSpace(f.bank.id, to: "Banking")
        XCTAssertEqual(f.store.containerLabel(forEngineProfile: f.container.id)?.name, "Banking", "named by its space")
    }

    func testICloudOnlyContainersNestUnderAnICloudOnlyParent() {
        let parent = Profile(name: "Away")
        let nested = Profile(name: "Mail", containerOf: parent.id)
        let orphan = Profile(name: "Bank", containerOf: UUID())
        let chained = Profile(name: "Deep", containerOf: nested.id)
        let cloud = [parent, nested, orphan, chained].map { CloudProfile(profile: $0, spaces: []) }
        let rows = CloudContainerNesting.rows(cloud)
        XCTAssertEqual(rows.map(\.profile.profile.name), ["Away", "Mail", "Bank", "Deep"])
        XCTAssertEqual(rows.map(\.nested), [false, true, false, false])
    }
}
