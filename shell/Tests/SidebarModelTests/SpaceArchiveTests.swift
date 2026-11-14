import XCTest
@testable import SidebarModel

/// Build 767's `Space` decoding (Space.swift at 70f67202): a keyed container
/// that reads the keys it knows and skips the rest, `archivedAt` among them.
private struct Space767: Decodable {
    let id: UUID
    let name: String
    let profileID: UUID?
    let sortRank: String?
    enum CodingKeys: String, CodingKey {
        case arcSourceID, arcImportedItemIDs, arcItemMapping, bookmarkSourceID
        case id, name, theme, iconName
        case pinnedContainerID, unpinnedContainerID, unpinnedShared
        case profileID, sortRank, boostsEnabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        _ = try c.decode(SpaceTheme.self, forKey: .theme)
        _ = try c.decode(String.self, forKey: .iconName)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank)
    }
}

private struct Snapshot767: Decodable {
    let schemaVersion: Int
    let spaces: [Space767]
}

/// Archive Space (docs/FEATURE-SPECS/ARCHIVE-SPACE.md).
final class SpaceArchiveTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }
    private let archivedDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// Personal with Home, Work and Side; Work has pinned tabs in a folder
    /// (collapsed), a Today tab, a theme, an icon, boosts off and a selection.
    private func makeStore() throws -> (store: SidebarStore, home: Space.ID, work: Space.ID, side: Space.ID) {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")])
        store.now = { [archivedDate] in archivedDate }
        let home = store.spaces[0].id
        let work = store.addSpace(name: "Work", theme: SpaceTheme.presets[3], iconName: "briefcase.fill").id
        let side = store.addSpace(name: "Side").id
        _ = store.addTab(kind: .pinned, title: "Docs", url: url("docs.test"), in: work)
        let folder = try XCTUnwrap(store.createFolder(title: "Reading", in: work))
        let article = store.addTab(kind: .pinned, title: "Article", url: url("article.test"), in: work)
        XCTAssertTrue(store.moveItem(article.id, to: .folder(folder.id), index: 0))
        let open = try XCTUnwrap(store.createFolder(title: "Open", in: work))
        store.setFolderExpanded(open.id, true)
        store.setFolderExpanded(folder.id, false)
        _ = store.addTab(kind: .today, title: "Scratch", url: url("scratch.test"), in: work)
        store.setSpaceBoostsEnabled(false, for: work)
        store.selectSpace(work)
        store.selectTab(article.id)
        return (store, home, work, side)
    }

    // MARK: Archive and restore

    func testArchiveAndRestoreRoundTripTheSpaceExactly() throws {
        let f = try makeStore()
        let before = try XCTUnwrap(f.store.space(withID: f.work))
        let content = f.store.content(for: f.work)
        let expanded = f.store.expandedFolderIDs
        let selection = f.store.selectedItemID

        XCTAssertNil(f.store.archiveSpace(f.work))
        let archived = try XCTUnwrap(f.store.space(withID: f.work))
        XCTAssertEqual(archived.archivedAt, archivedDate)
        var unarchived = archived
        unarchived.archivedAt = nil
        XCTAssertEqual(unarchived, before, "only archivedAt changes")
        XCTAssertEqual(f.store.content(for: f.work), content, "pinned and Today tabs, folders and splits stay")
        XCTAssertEqual(f.store.expandedFolderIDs, expanded, "folders keep their open or closed state")

        XCTAssertNil(f.store.restoreArchivedSpace(f.work))
        XCTAssertEqual(f.store.space(withID: f.work), before)
        XCTAssertEqual(f.store.content(for: f.work), content)
        XCTAssertEqual(f.store.expandedFolderIDs, expanded)
        f.store.selectSpace(f.work)
        XCTAssertEqual(f.store.selectedItemID, selection, "the space comes back on the tab it was on")
    }

    func testRestorePutsTheSpaceBackInItsPlace() throws {
        let f = try makeStore()
        let order = f.store.spacesInActiveProfile.map(\.id)
        XCTAssertEqual(order, [f.home, f.work, f.side])
        XCTAssertNil(f.store.archiveSpace(f.work))
        XCTAssertEqual(f.store.spacesInActiveProfile.map(\.id), [f.home, f.side])
        let late = f.store.addSpace(name: "Late").id
        XCTAssertNil(f.store.restoreArchivedSpace(f.work))
        XCTAssertEqual(f.store.spacesInActiveProfile.map(\.id), [f.home, f.work, f.side, late])
    }

    func testRestoreGoesToTheEndWhenItsSlotIsTaken() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        let rank = try XCTUnwrap(f.store.space(withID: f.work)?.sortRank)
        // Another Mac's space landed on the same rank while this one was archived.
        let twin = f.store.addSpace(name: "Twin").id
        let index = try XCTUnwrap(f.store.spaces.firstIndex { $0.id == twin })
        f.store.spaces[index].sortRank = rank
        XCTAssertNil(f.store.restoreArchivedSpace(f.work))
        XCTAssertEqual(f.store.spacesInActiveProfile.last?.id, f.work)
        let ranks = f.store.spaces.map(\.sortRank)
        XCTAssertEqual(Set(ranks).count, ranks.count, "no two spaces share a rank")
    }

    func testArchivingTheActiveSpaceSwitchesToANeighbourAsDeleteDoes() throws {
        let f = try makeStore()
        XCTAssertEqual(f.store.activeSpaceID, f.work)
        XCTAssertNil(f.store.archiveSpace(f.work))
        XCTAssertEqual(f.store.activeSpaceID, f.home, "the profile's first listed space, as removeSpace picks")
        XCTAssertNotEqual(f.store.lastActiveSpaceByProfile[f.store.activeProfileID], f.work)

        // The same choice Delete makes from the same state.
        let g = try makeStore()
        XCTAssertTrue(g.store.removeSpace(g.work))
        XCTAssertEqual(g.store.activeSpaceID, g.home)
    }

    func testArchivingTheOnlySpaceOfAProfileMovesToAnotherProfile() throws {
        let f = try makeStore()
        let studio = f.store.addProfile(name: "Studio")
        let studioSpace = try XCTUnwrap(f.store.spaces(in: studio.id).first)
        f.store.selectSpace(studioSpace.id)
        XCTAssertNil(f.store.archiveSpace(studioSpace.id), "Delete's rule: only the last listed space stays")
        XCTAssertEqual(f.store.activeProfileID, f.store.space(withID: f.store.activeSpaceID)?.profileID)
        XCTAssertNotEqual(f.store.activeSpaceID, studioSpace.id)
        XCTAssertEqual(f.store.archivedSpaces(in: studio.id).map(\.id), [studioSpace.id])
    }

    func testTheLastListedSpaceCannotBeArchived() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        XCTAssertNil(f.store.archiveSpace(f.side))
        XCTAssertEqual(f.store.archiveBlocker(forSpace: f.home), .lastSpace)
        XCTAssertEqual(f.store.archiveSpace(f.home), .lastSpace)
        XCTAssertEqual(f.store.visibleSpaces.map(\.id), [f.home])
        XCTAssertEqual(f.store.archiveSpace(f.work), .alreadyArchived)
        XCTAssertEqual(f.store.restoreArchivedSpace(f.home), .notArchived)
        XCTAssertEqual(f.store.archiveSpace(UUID()), .spaceNotFound)
        // Delete keeps the same rule for listed spaces, and an archived one can always go.
        XCTAssertFalse(f.store.removeSpace(f.home))
        XCTAssertTrue(f.store.removeSpace(f.side))
        XCTAssertNil(f.store.space(withID: f.side))
    }

    func testAContainersSpaceCannotBeArchivedAndAProfileWithArchivedSpacesIsNotAContainer() throws {
        let f = try makeStore()
        let container = try XCTUnwrap(f.store.createContainer(forSpace: f.side))
        XCTAssertEqual(f.store.archiveSpace(f.side), .containerSpace)
        XCTAssertNil(f.store.space(withID: f.side)?.archivedAt)

        let studio = f.store.addProfile(name: "Studio")
        let first = try XCTUnwrap(f.store.spaces(in: studio.id).first)
        _ = f.store.addSpace(name: "Second", profileID: studio.id)
        XCTAssertNil(f.store.archiveSpace(first.id))
        XCTAssertEqual(f.store.containerConversionBlocker(studio.id, of: f.store.profiles[0].id), .needsExactlyOneSpace(count: 2),
                       "an archived space still counts")
        XCTAssertNotNil(container)
    }

    // MARK: Lists

    func testArchivedSpacesAreInNoListOfSpaces() throws {
        let f = try makeStore()
        let profile = f.store.activeProfileID
        let window = SidebarWindowID()
        f.store.registerWindow(window, spaceID: f.work)
        XCTAssertNil(f.store.archiveSpace(f.work))

        XCTAssertFalse(f.store.visibleSpaces.contains { $0.id == f.work })
        XCTAssertFalse(f.store.spaces(in: profile).contains { $0.id == f.work })
        XCTAssertFalse(f.store.spaces(listedIn: profile).contains { $0.id == f.work })
        XCTAssertFalse(f.store.spacesInActiveProfile.contains { $0.id == f.work }, "switcher, pager, Spaces menu")
        XCTAssertNil(f.store.listedSpace(withID: f.work))
        XCTAssertNotNil(f.store.space(withID: f.work), "still stored")

        // ⌃1–9 and Next/Previous Space.
        XCTAssertTrue(f.store.selectSpace(atIndex: 1))
        XCTAssertEqual(f.store.activeSpaceID, f.side)
        XCTAssertFalse(f.store.selectSpace(atIndex: 2))
        for _ in 0 ..< 4 {
            f.store.cycleSpace()
            XCTAssertNotEqual(f.store.activeSpaceID, f.work)
        }
        // Selecting it directly, or a tab in it, does nothing.
        f.store.selectSpace(f.work)
        XCTAssertNotEqual(f.store.activeSpaceID, f.work)
        let docs = try XCTUnwrap(f.store.content(for: f.work).pinnedLeaves.first?.id)
        XCTAssertFalse(f.store.focusTab(docs))
        XCTAssertNotEqual(f.store.activeSpaceID, f.work)

        // Move to Space and Move to Profile.
        XCTAssertFalse(f.store.spaceMoveDestinations(from: f.home).contains { $0.id == f.work })
        let studio = f.store.addProfile(name: "Studio")
        let studioSpace = try XCTUnwrap(f.store.spaces(in: studio.id).first)
        _ = f.store.addSpace(name: "Studio Two", profileID: studio.id)
        XCTAssertNil(f.store.archiveSpace(studioSpace.id))
        let destinations = f.store.profileMoveDestinations(from: f.home)
        XCTAssertFalse(destinations.flatMap(\.spaces).contains { $0.id == studioSpace.id })

        // Windows, new pages, Little ReArc, Air Traffic Control.
        XCTAssertNotEqual(f.store.focusedSpaceID(in: window), f.work)
        XCTAssertNotEqual(f.store.restoredSpaceID(saved: f.work, profileID: profile), f.work)
        XCTAssertNotEqual(f.store.space(forNewTabIn: profile, preferring: f.work), f.work)
        XCTAssertNotEqual(f.store.space(forNewTabIn: studio.id), studioSpace.id)

        // Command bar tab search.
        let index = CommandBarSearch.TabIndex(store: f.store)
        XCTAssertFalse(index.entries.contains { $0.spaceID == f.work })

        // The profile's count, as Settings and the bottom bar show it.
        XCTAssertEqual(f.store.spaces(listedIn: profile).count, 2)
        XCTAssertEqual(f.store.archivedSpaces(in: profile).map(\.id), [f.work])
    }

    func testArchivedSpacesListNewestFirst() throws {
        let f = try makeStore()
        var date = archivedDate
        f.store.now = { date }
        XCTAssertNil(f.store.archiveSpace(f.work))
        date = date.addingTimeInterval(60)
        XCTAssertNil(f.store.archiveSpace(f.side))
        XCTAssertEqual(f.store.archivedSpaces(in: f.store.activeProfileID).map(\.id), [f.side, f.work])
    }

    func testTodayTabsInAnArchivedSpaceAreNotAutoArchived() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        f.store.setAutoArchiveThreshold(.oneDay)
        f.store.now = { [archivedDate] in archivedDate.addingTimeInterval(90 * 86_400) }
        XCTAssertTrue(f.store.autoArchiveIdleTodayTabs().isEmpty)
        XCTAssertEqual(f.store.content(for: f.work).todayLeaves.count, 1, "Today tabs wait with their space")
    }

    func testDeletingAProfileKeepsAListedSpace() throws {
        let f = try makeStore()
        let studio = f.store.addProfile(name: "Studio")
        _ = f.store.addSpace(name: "Studio Two", profileID: studio.id)
        XCTAssertNil(f.store.archiveSpace(f.work))
        XCTAssertNil(f.store.archiveSpace(f.side))
        XCTAssertNil(f.store.archiveSpace(f.home))
        XCTAssertNil(f.store.deleteProfile(studio.id, deletingSpaces: true))
        XCTAssertEqual(f.store.visibleSpaces.count, 1, "a fresh space, as when the last one goes")
        XCTAssertEqual(f.store.archivedSpaces(in: f.store.profiles[0].id).count, 3, "the archived ones stay archived")
        XCTAssertNotNil(f.store.listedSpace(withID: f.store.activeSpaceID))
    }

    // MARK: Persistence

    func testSnapshotRoundTripsTheArchivedState() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        let reloaded = SidebarStore()
        reloaded.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        XCTAssertEqual(reloaded.space(withID: f.work), f.store.space(withID: f.work))
        XCTAssertEqual(reloaded.content(for: f.work), f.store.content(for: f.work))
        XCTAssertEqual(reloaded.spacesInActiveProfile.map(\.id), [f.home, f.side])
    }

    func testAListedSpaceEncodesAsBefore() throws {
        let space = Space(name: "Plain", sortRank: "a")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as? [String: Any])
        XCTAssertNil(object["archivedAt"], "no new key on spaces that were never archived")
    }

    func testOldBuildsReadTheNewFileAndShowArchivedSpaces() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        let old = try JSONDecoder().decode(Snapshot767.self, from: data)
        XCTAssertEqual(old.schemaVersion, 10, "an unchanged schema version: build 767 refuses a newer one")
        XCTAssertEqual(Set(old.spaces.map(\.id)), Set([f.home, f.work, f.side]), "build 767 reads every space, the archived one too")
    }

    func testAFileAnOldBuildSavedBringsTheSpaceBackWithEverything() throws {
        let f = try makeStore()
        let content = f.store.content(for: f.work)
        XCTAssertNil(f.store.archiveSpace(f.work))
        // An old build re-saves without the key it does not know.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.store.makeSnapshot())) as? [String: Any])
        json["spaces"] = (json["spaces"] as? [[String: Any]])?.map { space in
            var space = space
            space["archivedAt"] = nil
            return space
        }
        let reloaded = SidebarStore()
        reloaded.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertNotNil(reloaded.listedSpace(withID: f.work))
        XCTAssertEqual(reloaded.content(for: f.work), content, "nothing lost")
        XCTAssertEqual(reloaded.spacesInActiveProfile.map(\.id), [f.home, f.work, f.side])
    }

    func testLoadingRepairsAnArchivedActiveSpaceAndAllArchived() throws {
        let f = try makeStore()
        var snapshot = f.store.makeSnapshot()
        let now = archivedDate
        snapshot.spaces = snapshot.spaces.map { space in
            var space = space
            if space.id == f.work { space.archivedAt = now }
            return space
        }
        snapshot.activeSpaceID = f.work
        let reloaded = SidebarStore()
        reloaded.applySnapshot(snapshot)
        XCTAssertEqual(reloaded.activeSpaceID, f.home, "an archived active space hands over on load")

        snapshot.spaces = snapshot.spaces.map { space in
            var space = space
            space.archivedAt = now
            return space
        }
        let all = SidebarStore()
        all.applySnapshot(snapshot)
        XCTAssertEqual(all.visibleSpaces.count, 1, "one space comes back so there is something to show")
        XCTAssertNotNil(all.listedSpace(withID: all.activeSpaceID))
    }

    // MARK: Sync mapping

    func testTheArchiveSyncsInItsOwnRecord() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        let records = SidebarSyncProjection.extract(f.store.makeSnapshot())
        let space = try XCTUnwrap(records[SyncRecordKind.space.recordName(for: f.work)])
        XCTAssertNil(space.values["archivedAt"], "the space record keeps its shape, so older builds never write it back")
        let archive = try XCTUnwrap(records[SyncRecordKind.spaceArchive.recordName(for: f.work)])
        XCTAssertEqual(archive.kind, .spaceArchive)
        XCTAssertEqual(archive.values["space"], .string(f.work.uuidString.lowercased()))
        XCTAssertEqual(archive.values["archivedAt"], .number(archivedDate.timeIntervalSince1970))
        XCTAssertNil(records[SyncRecordKind.spaceArchive.recordName(for: f.home)], "only archived spaces have one")
        XCTAssertEqual(SyncRecordKind.spaceArchive.rawValue, "SidebarSpaceArchiveRecord")
        XCTAssertEqual(SyncRecordKind.parse(recordName: SyncRecordKind.spaceArchive.recordName(for: f.work))?.kind, .spaceArchive)
        XCTAssertEqual(SyncRecordKind.parse(recordName: SyncRecordKind.space.recordName(for: f.work))?.kind, .space)
        // The archived space's pinned rows still sync.
        let docs = try XCTUnwrap(f.store.content(for: f.work).pinnedLeaves.first?.id)
        XCTAssertNotNil(records[SyncRecordKind.item.recordName(for: docs)])

        XCTAssertNil(f.store.restoreArchivedSpace(f.work))
        XCTAssertNil(SidebarSyncProjection.extract(f.store.makeSnapshot())[SyncRecordKind.spaceArchive.recordName(for: f.work)])
    }

    func testApplyingRecordsArchivesAndRestores() throws {
        let f = try makeStore()
        XCTAssertNil(f.store.archiveSpace(f.work))
        let stamp = SyncStamp(millis: 1, device: "A")
        func payloads(_ bodies: [String: SyncRecordBody]) -> [String: SyncRecordPayload] {
            bodies.mapValues { SyncRecordPayload(kind: $0.kind, fields: $0.values.mapValues { SyncField(value: $0, stamp: stamp) }) }
        }
        let archived = payloads(SidebarSyncProjection.extract(f.store.makeSnapshot()))
        let fresh = SidebarStore()
        let applied = SidebarSyncProjection.apply(archived, onto: fresh.makeSnapshot())
        XCTAssertEqual(applied.spaces.first { $0.id == f.work }?.archivedAt, archivedDate)
        XCTAssertNil(applied.spaces.first { $0.id == f.home }?.archivedAt)

        // No archive record: the space is listed, whatever this Mac had.
        var restored = archived
        restored[SyncRecordKind.spaceArchive.recordName(for: f.work)] = nil
        XCTAssertNil(SidebarSyncProjection.apply(restored, onto: f.store.makeSnapshot()).spaces.first { $0.id == f.work }?.archivedAt)

        let name = SyncRecordKind.spaceArchive.recordName(for: f.work)
        XCTAssertTrue(SidebarSyncProjection.canMaterialize(name, archived[name]!))
        let junk = SyncRecordPayload(kind: .spaceArchive, fields: ["archivedAt": SyncField(value: .string("soon"), stamp: stamp)])
        XCTAssertFalse(SidebarSyncProjection.canMaterialize(name, junk), "an unreadable one is left alone")
    }

    // MARK: Import

    func testArcImportNeverArchivesAndBringsAnArchivedSpaceBack() throws {
        let store = SidebarStore()
        let source = ArcSidebarImport(export: try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar())),
                                      profileNames: ["Default": "Home", "Profile 1": "Studio"])
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        XCTAssertTrue(store.spaces.allSatisfy { !$0.isArchived }, "an import makes listed spaces")

        // An Arc space, not the space holding the favorites ledger (`…:__favorites`).
        let imported = try XCTUnwrap(store.spaces.first { space in
            space.arcSourceID.map { !$0.hasSuffix(":__favorites") } == true && store.archiveBlocker(forSpace: space.id) == nil
        })
        XCTAssertNil(store.archiveSpace(imported.id))
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        XCTAssertNotNil(store.listedSpace(withID: imported.id), "importing it again brings it back, not into an unlisted space")
        XCTAssertTrue(store.spaces.allSatisfy { !$0.isArchived })
        XCTAssertEqual(store.spaces.filter { $0.arcSourceID == imported.arcSourceID }.count, 1, "no second copy")
    }

    func testBookmarkReimportBringsAnArchivedSpaceBack() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "a")])
        let first = try XCTUnwrap(store.importBookmarks([.link(title: "A", url: url("a.test"))], spaceName: "Chrome", sourceID: "chrome/Default"))
        XCTAssertFalse(first.space.isArchived)
        XCTAssertNil(store.archiveSpace(first.space.id))
        let again = try XCTUnwrap(store.importBookmarks([.link(title: "B", url: url("b.test"))], spaceName: "Chrome", sourceID: "chrome/Default"))
        XCTAssertEqual(again.space.id, first.space.id)
        XCTAssertFalse(again.space.isArchived)
        XCTAssertNotNil(store.listedSpace(withID: first.space.id))
    }
}
