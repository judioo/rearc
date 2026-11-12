import XCTest
@testable import SidebarModel

/// Settings › Profiles: which profiles are in iCloud too, the profiles only
/// iCloud has, and deleting one profile from iCloud with sync off or on.
/// Everything runs against `InMemorySyncServer`, never CloudKit.
@MainActor
final class CloudProfileTests: XCTestCase {
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

    private func mac(_ device: String, on: Bool, account: String? = "alice", store: SidebarStore = SidebarStore()) -> Mac {
        var state = SidebarSyncState()
        state.enabled = on
        state.decision = on ? .user : nil
        let file = InMemorySyncStateStore(state)
        let sync = SidebarSyncCoordinator(transport: server.transport(account: account), stateStore: file, deviceID: device,
                                          now: { [unowned self] in self.date })
        sync.host = store
        return Mac(store: store, sync: sync, state: file)
    }

    private func cycle(_ mac: Mac) async {
        date += 2
        _ = await mac.sync.sync()
    }

    private func look(_ mac: Mac) async throws -> CloudSidebarFound {
        date += 2
        let detection = await mac.sync.detectCloudSidebar()
        return try XCTUnwrap(detection.found)
    }

    private func plan(_ id: Profile.ID, _ found: CloudSidebarFound) throws -> CloudProfileDeletion {
        try XCTUnwrap(CloudProfileDeletion(profileID: id, in: Dictionary(uniqueKeysWithValues: found.records.map { ($0.recordName, $0) })))
    }

    /// Another Mac in iCloud: "Personal" (Home, 1 pinned tab, a favorite) and
    /// "akilu" (Work with 2 pinned tabs and a folder holding 1, Notes with 1,
    /// their styles, a favorite).
    private struct OtherMac {
        var mac: Mac
        var personal: Profile.ID
        var akilu: Profile.ID
        var work: Space.ID
        var notes: Space.ID
        /// Every record of akilu's, all of which a delete marks deleted.
        var akiluRecords: Set<String>
        var akiluFavorite: String
        var personalFavorite: String
    }

    private func otherMacInICloud() async -> OtherMac {
        let other = mac("B", on: true)
        let store = other.store
        let personal = store.activeProfileID
        store.renameSpace(store.spaces[0].id, to: "Home")
        _ = store.addTab(kind: .pinned, title: "Docs", url: URL(string: "https://docs.test")!, in: store.spaces[0].id)
        let calendar = store.addTab(kind: .favorite, title: "Calendar", url: URL(string: "https://calendar.test")!)
        let akilu = store.addProfile(name: "akilu", createInitialSpace: false).id
        let work = store.addSpace(name: "Work", profileID: akilu).id
        let notes = store.addSpace(name: "Notes", profileID: akilu).id
        let board = store.addTab(kind: .pinned, title: "Board", url: URL(string: "https://board.test")!, in: work)
        let mail = store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test")!, in: work)
        let inFolder = store.addTab(kind: .pinned, title: "Paper", url: URL(string: "https://paper.test")!, in: work)
        let folder = store.createFolder(title: "Reading", in: work, containing: [inFolder.id])!
        let jot = store.addTab(kind: .pinned, title: "Jot", url: URL(string: "https://jot.test")!, in: notes)
        let favorite = store.addTab(kind: .favorite, title: "Music", url: URL(string: "https://music.test")!, in: work)
        await cycle(other)
        let items = [board.id, mail.id, folder.id, inFolder.id, jot.id, favorite.id].map { SyncRecordKind.item.recordName(for: $0) }
        let styles = [work, notes].map { SyncRecordKind.spaceStyle.recordName(for: $0) }
        XCTAssertTrue(styles.allSatisfy { server.records(account: "alice")[$0] != nil })
        return OtherMac(mac: other, personal: personal, akilu: akilu, work: work, notes: notes,
                        akiluRecords: Set([SyncRecordKind.profile.recordName(for: akilu), SyncRecordKind.space.recordName(for: work),
                                           SyncRecordKind.space.recordName(for: notes)] + items + styles),
                        akiluFavorite: SyncRecordKind.item.recordName(for: favorite.id),
                        personalFavorite: SyncRecordKind.item.recordName(for: calendar.id))
    }

    /// This Mac with sync off: B's "Personal" (same id), its own "akilu"
    /// (another id, same name) and "Assured.living"; B's "akilu" is not here.
    private func thisMac(_ other: OtherMac) -> (mac: Mac, ownAkilu: Profile.ID, assured: Profile.ID) {
        let store = SidebarStore()
        store.applySnapshot(other.mac.store.makeSnapshot())
        _ = store.deleteProfile(other.akilu, deletingSpaces: true)
        let ownAkilu = store.addProfile(name: "akilu").id
        let assured = store.addProfile(name: "Assured.living").id
        return (mac("A", on: false, store: store), ownAkilu, assured)
    }

    // MARK: - Where each profile is

    func testStatePerProfile() async throws {
        let other = await otherMacInICloud()
        let (here, ownAkilu, assured) = thisMac(other)
        let found = try await look(here)
        let detection = CloudSidebarDetection.found(found)
        XCTAssertEqual(ProfileCloudPresence.of(other.personal, detection: detection, looking: false), .inICloud, "same id")
        XCTAssertEqual(ProfileCloudPresence.of(ownAkilu, detection: detection, looking: false), .onlyHere, "same name, another id")
        XCTAssertEqual(ProfileCloudPresence.of(assured, detection: detection, looking: false), .onlyHere)

        let cloudOnly = found.profiles(notIn: here.store.profiles)
        XCTAssertEqual(cloudOnly.map(\.id), [other.akilu], "B's akilu is only in iCloud, next to this Mac's own akilu")
        let akilu = try XCTUnwrap(cloudOnly.first)
        XCTAssertEqual(akilu.profile.name, "akilu")
        XCTAssertEqual(akilu.spaces.map(\.name), ["Work", "Notes"])
        XCTAssertEqual(akilu.spaces.map(\.pinnedTabs), [3, 1])
        XCTAssertEqual(akilu.pinnedTabs, 4)
        XCTAssertEqual(akilu.lastEdited.map { abs($0.timeIntervalSince(date)) < 10 }, true)
        XCTAssertEqual(ProfileCloudText.summary(akilu, now: date).hasPrefix("2 spaces and 4 pinned tabs in iCloud, last edited"), true)
        XCTAssertEqual(found.profiles.reduce(0) { $0 + $1.spaces.count }, found.summary.spaces, "the Profiles pane adds up to the Account pane")
        XCTAssertEqual(found.profiles.reduce(0) { $0 + $1.pinnedTabs }, found.summary.pinnedTabs)

        XCTAssertEqual(ProfileCloudPresence.of(ownAkilu, detection: .empty(accountID: "alice"), looking: false), .onlyHere)
    }

    func testNoGuessWhileLookingOrUnreachable() async throws {
        let other = await otherMacInICloud()
        let (here, ownAkilu, _) = thisMac(other)
        let found = CloudSidebarDetection.found(try await look(here))
        XCTAssertEqual(ProfileCloudPresence.of(ownAkilu, detection: nil, looking: false), .looking(nil), "no look finished yet")
        XCTAssertEqual(ProfileCloudPresence.of(ownAkilu, detection: found, looking: true, itemsRead: 1200), .looking(1200),
                       "a look again: not the last result")
        XCTAssertEqual(ProfileCloudText.status(.looking(1200)), "Looking at iCloud… 1,200 items")

        let signedOut = await mac("A", on: false, account: nil).sync.detectCloudSidebar()
        guard case .unknown(let why) = ProfileCloudPresence.of(other.personal, detection: signedOut, looking: false) else {
            return XCTFail("signed out is not a place")
        }
        XCTAssertEqual(ProfileCloudText.status(.unknown(why)), why)

        server.fault = .networkUnavailable
        let offline = await here.sync.detectCloudSidebar()
        server.fault = nil
        XCTAssertEqual(ProfileCloudPresence.of(other.personal, detection: offline, looking: false),
                       .unknown("ReArc can't reach iCloud. Check your connection and try again."))
        XCTAssertEqual(ProfileCloudPresence.of(ownAkilu, detection: offline, looking: false),
                       .unknown("ReArc can't reach iCloud. Check your connection and try again."), "never “Only on this Mac” unread")
    }

    // MARK: - Deleting, sync off

    func testDeleteWithSyncOffMarksExactlyTheProfilesRecords() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let found = try await look(here)
        let plan = try plan(other.akilu, found)
        XCTAssertEqual(Set(plan.changes.keys), other.akiluRecords)
        XCTAssertEqual(plan.spaces, 2)
        XCTAssertEqual(plan.deletedTabs, 4)
        XCTAssertEqual(plan.deletedFavorites, 1)
        XCTAssertEqual(plan.movedTabs + plan.movedFavorites, 0)
        XCTAssertEqual(ProfileCloudText.deleteFromICloudTitle("akilu"), "Delete “akilu” from iCloud?")
        XCTAssertEqual(ProfileCloudText.deleteFromICloudMessage(plan, receiving: [], syncOn: false, backupFolder: "Backups"),
                       "Its 2 spaces, 4 pinned tabs and 1 favorite are removed from iCloud. Other Macs that sync lose them too. This Mac is not changed. "
                           + "A copy of what is deleted is saved first in Backups.")

        let before = server.records(account: "alice")
        let writesBefore = server.modifyCount
        let zonesBefore = server.zoneCreations
        let stateBefore = here.state.state
        let savesBefore = here.state.saveCount
        let localBefore = here.store.makeSnapshot()
        var backedUp: [SyncWireRecord] = []
        var writesAtBackup = -1
        let result = await here.sync.deleteCloudProfile(plan, in: found, backup: { records in
            backedUp = records
            writesAtBackup = self.server.modifyCount
            return self.backupURL
        })
        guard case .deleted(let url, let detection, let queued) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(url, backupURL)
        XCTAssertFalse(queued)

        // The backup came first and holds the records as read.
        XCTAssertEqual(writesAtBackup, writesBefore)
        XCTAssertEqual(Set(backedUp.map(\.recordName)), other.akiluRecords)
        XCTAssertEqual(backedUp, backedUp.map { before[$0.recordName]! })

        let after = server.records(account: "alice")
        XCTAssertEqual(Set(after.keys), Set(before.keys), "nothing added, nothing hard-deleted")
        let changed = Set(after.keys.filter { after[$0]!.payload != before[$0]!.payload })
        XCTAssertEqual(changed, other.akiluRecords, "exactly the profile's records")
        for name in changed {
            XCTAssertFalse(after[name]!.payload.isAlive, name)
            XCTAssertEqual(after[name]!.payload.fields, before[name]!.payload.fields, "a tombstone, the fields as they were")
        }
        XCTAssertTrue(after[other.personalFavorite]!.payload.isAlive, "other profiles' favorites stay")
        XCTAssertEqual(server.existingSaveCount, 1)
        XCTAssertEqual(server.zoneCreations, zonesBefore, "no zone created")
        XCTAssertEqual(here.state.saveCount, savesBefore, "sync-state.json is not written")
        XCTAssertEqual(here.state.state, stateBefore)
        XCTAssertFalse(here.sync.isEnabled, "sync stays off")
        XCTAssertEqual(here.store.makeSnapshot(), localBefore, "this Mac is not changed")

        // The look no longer lists it, and the result is that look: both panes agree without reading again.
        let again = await here.sync.detectCloudSidebar()
        XCTAssertEqual(again, detection)
        XCTAssertNil(again.found?.profile(other.akilu))
        XCTAssertEqual(again.found?.summary.spaces, found.summary.spaces - 2)
        XCTAssertEqual(again.found?.summary.pinnedTabs, found.summary.pinnedTabs - 4)

        // A Mac that syncs drops it, and keeps the rest.
        await cycle(other.mac)
        XCTAssertNil(other.mac.store.profile(withID: other.akilu))
        XCTAssertFalse(other.mac.store.spaces.contains { $0.id == other.work || $0.id == other.notes })
        XCTAssertEqual(other.mac.store.favorites(in: other.personal).map(\.title), ["Calendar"])
        XCTAssertEqual(other.mac.sync.state.pendingCount, 0, "it uploads nothing back")
    }

    func testDeleteFromThisMacAndICloudWithSyncOffDeletesHereAfterICloud() async throws {
        let other = await otherMacInICloud()
        let here = mac("A", on: false, store: SidebarStore())
        here.store.applySnapshot(other.mac.store.makeSnapshot())
        let found = try await look(here)
        XCTAssertEqual(ProfileCloudPresence.of(other.akilu, detection: .found(found), looking: false), .inICloud)
        let plan = try plan(other.akilu, found)

        server.fault = .networkUnavailable
        let offline = await here.sync.deleteCloudProfile(plan, in: found, backup: { _ in self.backupURL }) {
            _ = here.store.deleteProfile(other.akilu, deletingSpaces: true)
        }
        server.fault = nil
        guard case .failed(let why) = offline else { return XCTFail("\(offline)") }
        XCTAssertTrue(why.hasSuffix("so nothing was deleted. Look at iCloud again and try again."), why)
        XCTAssertNotNil(here.store.profile(withID: other.akilu), "iCloud's part failed: this Mac keeps it")

        let result = await here.sync.deleteCloudProfile(plan, in: found, backup: { _ in self.backupURL }) {
            _ = here.store.deleteProfile(other.akilu, deletingSpaces: true)
        }
        guard case .deleted = result else { return XCTFail("\(result)") }
        XCTAssertNil(here.store.profile(withID: other.akilu))
        XCTAssertFalse(server.records(account: "alice")[SyncRecordKind.profile.recordName(for: other.akilu)]!.payload.isAlive)
        XCTAssertEqual(here.state.saveCount, 0)
    }

    func testNoBackupNoDelete() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let found = try await look(here)
        let before = server.records(account: "alice")
        let writes = server.modifyCount
        struct DiskFull: Error {}
        let result = await here.sync.deleteCloudProfile(try plan(other.akilu, found), in: found, backup: { _ in throw DiskFull() })
        XCTAssertEqual(result, .failed(SidebarSyncCoordinator.profileBackupFailedMessage))
        XCTAssertEqual(server.modifyCount, writes)
        XCTAssertEqual(server.records(account: "alice"), before)
    }

    /// The real writer: the records as read land in Backups beside
    /// sidebar.json and read back; where the folder can't be made, nothing is deleted.
    func testTheBackupBesideTheSidebarFile() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let found = try await look(here)
        let plan = try plan(other.akilu, found)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidebar = folder.appendingPathComponent("sidebar.json")

        // "Backups" is a file here: the folder can't be made.
        try Data().write(to: SidebarBackup.folder(besides: sidebar))
        let before = server.records(account: "alice")
        let refused = await here.sync.deleteCloudProfile(plan, in: found, backup: { try SidebarBackup.writeCloudRecords($0, besides: sidebar) })
        XCTAssertEqual(refused, .failed(SidebarSyncCoordinator.profileBackupFailedMessage))
        XCTAssertEqual(server.records(account: "alice"), before)

        try FileManager.default.removeItem(at: SidebarBackup.folder(besides: sidebar))
        let result = await here.sync.deleteCloudProfile(plan, in: found, backup: { try SidebarBackup.writeCloudRecords($0, besides: sidebar, now: self.date) })
        guard case .deleted(let url, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(url.deletingLastPathComponent(), SidebarBackup.folder(besides: sidebar))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("icloud-profile-before-delete-"))
        let saved = try JSONDecoder().decode([SyncWireRecord].self, from: Data(contentsOf: url))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: saved.map { ($0.recordName, $0) }), before.filter { other.akiluRecords.contains($0.key) })
    }

    func testAProfileThatChangedSinceItWasShownIsAskedAgain() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let shown = try plan(other.akilu, try await look(here))

        // Another Mac adds a space to it meanwhile.
        let travel = other.mac.store.addSpace(name: "Travel", profileID: other.akilu)
        _ = other.mac.store.addTab(kind: .pinned, title: "Maps", url: URL(string: "https://maps.test")!, in: travel.id)
        await cycle(other.mac)
        let now = try await look(here)
        let before = server.records(account: "alice")
        let first = await here.sync.deleteCloudProfile(shown, in: now, backup: { _ in self.backupURL })
        guard case .changed(let fresh) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(fresh.spaces, 3)
        XCTAssertEqual(fresh.deletedTabs, 5)
        XCTAssertTrue(ProfileCloudText.deleteFromICloudMessage(fresh, receiving: [], syncOn: false, backupFolder: "B", changed: true)
            .hasPrefix("It changed in iCloud since you looked. Its 3 spaces, 5 pinned tabs and 1 favorite are removed from iCloud."))
        XCTAssertEqual(server.records(account: "alice"), before, "nothing written before asking again")

        let second = await here.sync.deleteCloudProfile(fresh, in: now, backup: { _ in self.backupURL })
        guard case .deleted(_, let detection, _) = second else { return XCTFail("\(second)") }
        XCTAssertNil(detection.found?.profile(other.akilu))
        XCTAssertFalse(server.records(account: "alice")[SyncRecordKind.space.recordName(for: travel.id)]!.payload.isAlive)
    }

    func testAChangeDuringTheWriteStopsIt() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let found = try await look(here)
        let before = server.records(account: "alice")
        let board = before.values.first { $0.payload.values["title"]?.stringValue == "Board" }!
        var edited = board
        edited.payload.fields["title"] = SyncField(value: .string("Board 2"), stamp: SyncStamp(millis: SyncStamp.millis(of: date), device: "B"))
        server.beforeModify = { $0.overwrite(account: "alice", record: edited) }
        let result = await here.sync.deleteCloudProfile(try plan(other.akilu, found), in: found, backup: { _ in self.backupURL })
        XCTAssertEqual(result, .failed("iCloud changed while ReArc was deleting, so nothing was deleted. Look at iCloud again and try again."))
        let after = server.records(account: "alice")
        XCTAssertEqual(after.filter { $0.key != board.recordName }, before.filter { $0.key != board.recordName }, "all or none")
    }

    func testAZoneGoneSinceTheLookIsNotCreated() async throws {
        let other = await otherMacInICloud()
        let (here, _, _) = thisMac(other)
        let found = try await look(here)
        let creations = server.zoneCreations
        server.resetZone(account: "alice")
        let result = await here.sync.deleteCloudProfile(try plan(other.akilu, found), in: found, backup: { _ in self.backupURL })
        XCTAssertEqual(result, .gone(.empty(accountID: "alice")))
        XCTAssertFalse(server.hasZone(account: "alice"))
        XCTAssertEqual(server.zoneCreations, creations)
    }

    // MARK: - Deleting, sync on

    func testDeleteWithSyncOnGoesThroughSync() async throws {
        let other = await otherMacInICloud()
        let here = mac("A", on: true)
        await cycle(here)
        XCTAssertNotNil(here.store.profile(withID: other.akilu), "synced here")
        let found = try await look(here)
        let plan = try plan(other.akilu, found)
        let saves = server.existingSaveCount
        var backedUp = false
        let result = await here.sync.deleteCloudProfile(plan, in: found, backup: { _ in
            backedUp = true
            return self.backupURL
        }) {
            XCTAssertTrue(backedUp)
            _ = here.store.deleteProfile(other.akilu, deletingSpaces: true)
        }
        guard case .deleted(_, let detection, let queued) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(queued)
        XCTAssertEqual(server.existingSaveCount, saves, "uploaded by sync, not the targeted write")

        let server = self.server.records(account: "alice")
        for name in other.akiluRecords {
            XCTAssertFalse(server[name]!.payload.isAlive, name)
            XCTAssertEqual(here.sync.state.records[name]?.payload, server[name]!.payload, "this Mac and iCloud agree")
        }
        XCTAssertTrue(server[other.personalFavorite]!.payload.isAlive, "other profiles' favorites stay")
        XCTAssertEqual(here.sync.state.pendingCount, 0, "nothing left queued")
        XCTAssertNil(here.store.profile(withID: other.akilu))
        XCTAssertNil(detection.found?.profile(other.akilu))
        let again = await here.sync.detectCloudSidebar()
        XCTAssertEqual(again.found?.summary, detection.found?.summary, "the Account pane's counts agree")

        await cycle(other.mac)
        XCTAssertNil(other.mac.store.profile(withID: other.akilu))
    }

    // MARK: - Copies of one Arc space

    /// A space of the deleted profile whose Arc space a profile that stays
    /// also has: its rows (the only copy of them in iCloud) move to that
    /// copy, a folder with what is in it; only the space goes. A space with
    /// no such copy goes with its rows.
    func testRowsAnArcCopyInAnotherProfileSharesMoveThere() async throws {
        let other = mac("B", on: true)
        let store = other.store
        let old = store.activeProfileID
        let kept = store.addProfile(name: "Akilu", createInitialSpace: false).id
        func arcSpace(_ name: String, _ profile: Profile.ID, source: String?) -> Space.ID {
            let space = store.addSpace(name: name, profileID: profile)
            let index = store.spaces.firstIndex { $0.id == space.id }!
            store.spaces[index].arcSourceID = source
            return space.id
        }
        let oldWork = arcSpace("Work", old, source: "Default:work")
        let richer = arcSpace("Work", kept, source: "Default:work")
        let emptier = arcSpace("Work", kept, source: "Default:work")
        let ownSpace = arcSpace("Scratch", old, source: nil)
        let rows = (0 ..< 3).map { store.addTab(kind: .pinned, title: "Row \($0)", url: URL(string: "https://row.test/\($0)")!, in: oldWork).id }
        let nested = store.addTab(kind: .pinned, title: "Nested", url: URL(string: "https://nested.test")!, in: oldWork)
        let folder = store.createFolder(title: "Folder", in: oldWork, containing: [nested.id])!
        let keptOwn = store.addTab(kind: .pinned, title: "Kept's own", url: URL(string: "https://kept.test")!, in: richer)
        _ = store.addTab(kind: .favorite, title: "Same", url: URL(string: "https://same.test")!, in: richer)
        let same = store.addTab(kind: .favorite, title: "Same", url: URL(string: "https://same.test/")!, in: oldWork)
        let unique = store.addTab(kind: .favorite, title: "Unique", url: URL(string: "https://unique.test")!, in: oldWork)
        let scratch = store.addTab(kind: .pinned, title: "Scratch", url: URL(string: "https://scratch.test")!, in: ownSpace)
        store.selectSpace(richer)
        await cycle(other)

        let here = mac("A", on: false)
        let found = try await look(here)
        let plan = try plan(old, found)
        let item = { SyncRecordKind.item.recordName(for: $0) }
        for id in rows + [folder.id] { XCTAssertEqual(plan.changes[item(id)], .move(toSpace: richer, topLevel: true)) }
        XCTAssertEqual(plan.changes[item(nested.id)], .move(toSpace: richer, topLevel: false), "it stays in its folder")
        XCTAssertEqual(plan.changes[item(scratch.id)], .delete)
        XCTAssertEqual(plan.changes[SyncRecordKind.space.recordName(for: oldWork)], .delete)
        XCTAssertNil(plan.changes[SyncRecordKind.space.recordName(for: emptier)])
        XCTAssertEqual(plan.changes[item(unique.id)], .moveFavorite(toProfile: kept))
        XCTAssertEqual(plan.changes[item(same.id)], .delete, "one favorite per address")
        XCTAssertEqual(plan.movedTabs, 4)
        XCTAssertEqual(plan.deletedTabs, 1)
        XCTAssertEqual(plan.spaces, 3, "Work, Scratch and the profile's first space")
        XCTAssertEqual(plan.receivingProfiles, [kept])
        XCTAssertEqual(ProfileCloudText.deleteFromICloudMessage(plan, receiving: ["Akilu"], syncOn: false, backupFolder: "B")
            .components(separatedBy: ". ").prefix(2).joined(separator: ". "),
                       "Its 3 spaces, 1 pinned tab and 1 favorite are removed from iCloud. 4 pinned tabs and 1 favorite move to “Akilu”, which has copies of the same Arc spaces")

        guard case .deleted = await here.sync.deleteCloudProfile(plan, in: found, backup: { _ in self.backupURL }) else { return XCTFail() }
        await cycle(other)
        XCTAssertNil(store.profile(withID: old))
        let content = store.content(for: richer).pinned
        XCTAssertEqual(Set(SidebarTree.leaves(content).map(\.id)), Set(rows + [nested.id, keptOwn.id]))
        XCTAssertTrue(content.contains { $0.id == folder.id }, "the folder came along with what is in it")
        XCTAssertFalse(SidebarTree.leaves(store.content(for: emptier).pinned).contains { rows.contains($0.id) })
        XCTAssertFalse(store.spaces.contains { $0.id == ownSpace })
        XCTAssertEqual(store.favorites(in: kept).map(\.title).sorted(), ["Same", "Unique"])
    }

    // MARK: - Bad remote data

    /// T-03: what a look leaves out (impossible stamps, the wrong kind, past
    /// the record limit) is never written; values of the wrong type and
    /// folder cycles are total, and rows that can't be placed stay.
    func testBadRemoteDataIsTotalAndUntouched() async throws {
        let other = await otherMacInICloud()
        let evil = SyncStamp(millis: .max, counter: .max, device: "evil")
        let stamp = SyncStamp(millis: SyncStamp.millis(of: date), device: "B")
        let pinned = SidebarSyncProjection.Parent.pinned(other.work).key
        func put(_ name: String, _ kind: SyncRecordKind, _ values: [String: SyncValue], _ at: SyncStamp = stamp) {
            server.overwrite(account: "alice", record: SyncWireRecord(recordName: name, payload: SyncRecordPayload(kind: kind, fields: values.mapValues { SyncField(value: $0, stamp: at) })))
        }
        let impossible = SyncRecordKind.item.recordName(for: UUID())
        put(impossible, .item, ["type": .string("tab"), "parent": .string(pinned), "url": .string("https://evil.test")], evil)
        let wrongKind = SyncRecordKind.item.recordName(for: UUID())
        put(wrongKind, .space, ["profileID": .string(other.akilu.uuidString)])
        put(SyncRecordKind.space.recordName(for: UUID()), .space, ["profileID": .number(3), "name": .array([])])
        put(SyncRecordKind.boost.recordName(for: UUID()), .boost, ["profileID": .object([:])])
        let (a, b) = (UUID(), UUID())
        put(SyncRecordKind.item.recordName(for: a), .item, ["type": .string("folder"), "parent": .string("folder:\(b.uuidString)"), "title": .string("A")])
        put(SyncRecordKind.item.recordName(for: b), .item, ["type": .string("folder"), "parent": .string("folder:\(a.uuidString)"), "title": .string("B")])
        put(SyncRecordKind.item.recordName(for: UUID()), .item, ["type": .string("tab"), "parent": .number(1), "space": .bool(true)])
        let lateRow = SyncRecordKind.item.recordName(for: UUID())
        put(lateRow, .item, ["type": .string("tab"), "parent": .string(pinned), "url": .string("https://late.test")])

        let (here, _, _) = thisMac(other)
        let all = server.records(account: "alice")
        here.sync.recordLimit = all.count - 4 // past the limit: the last records read, after the two left out
        let found = try await look(here)
        let read = Set(found.records.map(\.recordName))
        XCTAssertFalse(read.contains(impossible) || read.contains(wrongKind))
        let unread = Set(all.keys).subtracting(read).subtracting([impossible, wrongKind])
        XCTAssertEqual(unread.count, 2)
        let plan = try plan(other.akilu, found)
        XCTAssertTrue(Set(plan.changes.keys).isSubset(of: read), "only records the look kept")
        XCTAssertTrue(Set(plan.changes.keys).isSubset(of: other.akiluRecords.union([lateRow])), "only what is clearly the profile's")
        XCTAssertTrue(plan.changes.values.allSatisfy { $0 == .delete })
        guard case .deleted = await here.sync.deleteCloudProfile(plan, in: found, backup: { _ in self.backupURL }) else { return XCTFail() }
        let after = server.records(account: "alice")
        for name in Set(all.keys).subtracting(plan.changes.keys) { XCTAssertEqual(after[name], all[name], name) }
        XCTAssertNil(CloudProfileDeletion(profileID: UUID(), in: [:]))
    }
}
