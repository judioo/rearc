import XCTest
@testable import SidebarModel

/// Copies of one Arc space (builds up to 608): two installs importing the
/// same Arc profile, a first join, and sidebars that already hold copies.
@MainActor
final class ArcTwinSpacesTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        server = InMemorySyncServer()
    }

    private func arcSource() throws -> ArcSidebarImport {
        let export = try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar()))
        return ArcSidebarImport(export: export, profileNames: ["Default": "Home", "Profile 1": "Studio"])
    }

    /// An install that imported Arc and has sync on. `legacy`: spaces got
    /// random ids, as up to 608.
    private func install(_ device: String, legacy: Bool = false) throws -> (store: SidebarStore, sync: SidebarSyncCoordinator) {
        let store = SidebarStore()
        let source = try arcSource()
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        if legacy {
            var snapshot = store.makeSnapshot()
            for space in snapshot.spaces { snapshot.rename(space: space.id, to: UUID(), profile: space.profileID) }
            store.applySnapshot(snapshot)
        }
        var on = SidebarSyncState()
        on.enabled = true
        on.decision = .user
        let sync = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(on), deviceID: device,
                                          now: { [unowned self] in self.date })
        sync.host = store
        return (store, sync)
    }

    private func cycle(_ mac: (store: SidebarStore, sync: SidebarSyncCoordinator)) async {
        date += 2
        _ = await mac.sync.sync()
    }

    /// Rows per Arc space, by source, and how many spaces each source has.
    private func shape(_ store: SidebarStore) -> [String: [Int]] {
        var shape: [String: [Int]] = [:]
        for space in store.spaces {
            shape[space.arcSourceID ?? "-", default: []].append(SidebarTree.leaves(store.content(for: space.id).pinned).count)
        }
        return shape.mapValues { $0.sorted() }
    }

    private func allRowIDs(_ store: SidebarStore) -> [UUID] {
        store.spaces.flatMap { space -> [UUID] in
            let content = store.content(for: space.id)
            return SidebarTree.leaves(content.pinned).map(\.id) + SidebarTree.leaves(content.today).map(\.id)
        }
    }

    func testTheSameArcProfileImportedOnTwoInstallsIsOneSetOfSpaces() async throws {
        let a = try install("A")
        await cycle(a)
        let b = try install("B")
        XCTAssertEqual(Set(a.store.spaces.filter { $0.arcSourceID?.hasSuffix("__favorites") == false }.map(\.id)),
                       Set(b.store.spaces.filter { $0.arcSourceID?.hasSuffix("__favorites") == false }.map(\.id)),
                       "an Arc space's id follows from the Arc space")
        await cycle(b)
        await cycle(a)
        for mac in [a, b] {
            XCTAssertEqual(shape(mac.store), shape(try install("fresh").store), "each Arc space once, with all its rows")
            XCTAssertEqual(mac.store.profiles.count, 2, "B's own main and Studio profiles fold into A's")
            XCTAssertEqual(Set(allRowIDs(mac.store)).count, allRowIDs(mac.store).count)
        }
        XCTAssertEqual(Set(SidebarSyncProjection.extract(a.store.makeSnapshot()).keys), Set(SidebarSyncProjection.extract(b.store.makeSnapshot()).keys))
        XCTAssertEqual(a.store.profiles.flatMap { a.store.favorites(in: $0.id) }.count,
                       b.store.profiles.flatMap { b.store.favorites(in: $0.id) }.count, "favorites once each")
    }

    /// iCloud already holds 608's copies (random space ids): a joining Mac
    /// matches them by Arc source instead of adding its own.
    func testAJoinMatchesOlderCopiesInICloudByArcSource() async throws {
        let a = try install("A", legacy: true)
        await cycle(a)
        let b = try install("B")
        let mine = b.store.addTab(kind: .today, title: "Open on B", url: URL(string: "https://b.test/today")!,
                                  in: try XCTUnwrap(b.store.spaces.first { $0.name == "Work" }).id)
        await cycle(b)
        XCTAssertEqual(b.store.spaces.count, a.store.spaces.count, "no second copy of any Arc space")
        XCTAssertEqual(shape(b.store), shape(a.store))
        let work = try XCTUnwrap(b.store.spaces.first { $0.name == "Work" })
        XCTAssertTrue(b.store.content(for: work.id).today.contains { $0.id == mine.id }, "B's Today tab came along into iCloud's Work")
        XCTAssertTrue(a.store.spaces.contains { $0.id == work.id })
    }

    /// The owner's report: imported spaces seemed to lose their rows as they
    /// moved between spaces. Rows never move or hide when switching.
    func testSwitchingSpacesNeverMovesOrHidesRows() async throws {
        let a = try install("A", legacy: true)
        await cycle(a)
        let b = try install("B")
        await cycle(b)
        let before = b.store.spaces.map { ($0.id, b.store.content(for: $0.id)) }
        for _ in 0 ..< 3 {
            for space in b.store.spaces { b.store.selectSpace(space.id) }
            for _ in b.store.spaces { b.store.cycleSpace(forward: Bool.random()) }
            b.sync.captureLocalChanges()
            await cycle(b)
            await cycle(a)
        }
        for (id, content) in before {
            XCTAssertEqual(b.store.content(for: id).pinned.map(\.id), content.pinned.map(\.id))
        }
        XCTAssertEqual(Set(allRowIDs(b.store)).count, allRowIDs(b.store).count)
    }

    // MARK: - A sidebar already holding copies

    /// Two copies in one profile (one with rows, one with a row of its own
    /// and a Today tab), an empty copy in another profile, a copy with rows
    /// of its own in a third, and a profile whose only space is a copy.
    private func duplicated() -> (SidebarSnapshot, mine: UUID, today: UUID) {
        let store = SidebarStore()
        let main = store.activeProfileID
        let other = store.addProfile(name: "Other", createInitialSpace: false).id
        let third = store.addProfile(name: "Third", createInitialSpace: false).id
        let lonely = store.addProfile(name: "Lonely", createInitialSpace: false).id
        func copy(_ profile: Profile.ID) -> Space.ID {
            let space = store.addSpace(name: "Work", profileID: profile)
            if let index = store.spaces.firstIndex(where: { $0.id == space.id }) {
                store.spaces[index].arcSourceID = "Default:work"
                store.spaces[index].arcImportedItemIDs = []
            }
            return space.id
        }
        let rich = copy(main)
        for n in 0 ..< 3 { _ = store.addTab(kind: .pinned, title: "Row \(n)", url: URL(string: "https://row.test/\(n)")!, in: rich) }
        let poor = copy(main)
        let mine = store.addTab(kind: .pinned, title: "Only here", url: URL(string: "https://mine.test")!, in: poor)
        let today = store.addTab(kind: .today, title: "Reading", url: URL(string: "https://today.test")!, in: poor)
        _ = store.addSpace(name: "Notes", profileID: other)
        _ = copy(other)
        let own = copy(third)
        _ = store.addTab(kind: .pinned, title: "Third's", url: URL(string: "https://third.test")!, in: own)
        _ = copy(lonely)
        store.selectSpace(poor)
        var snapshot = store.makeSnapshot()
        // A row listed in two spaces, as copies could leave it.
        let shared = snapshot.spaceContainers[rich]!.pinned.childIDs[0]
        snapshot.spaceContainers[own]!.pinned.childIDs.append(shared)
        return (snapshot, mine.id, today.id)
    }

    func testRepairMergesCopiesAndLosesNothing() throws {
        let (snapshot, mine, today) = duplicated()
        let tabsBefore = Set(snapshot.tabsByID.keys)
        let (repaired, report) = ArcTwinSpaces.repair(snapshot)
        XCTAssertEqual(report.duplicatedSources, 1)
        XCTAssertEqual(report.mergedSameProfile, 1)
        XCTAssertEqual(report.removedEmpty, 1, "the empty copy beside Notes goes")
        XCTAssertEqual(report.keptCopies, 2, "Third's copy has rows of its own; Lonely's is that profile's only space")
        XCTAssertEqual(report.movedRows, 2)
        XCTAssertEqual(report.droppedRepeats, 1)
        XCTAssertEqual(Set(repaired.tabsByID.keys), tabsBefore, "no tab is lost")
        XCTAssertEqual(repaired.spaces.filter { $0.arcSourceID == "Default:work" }.count, 3)
        let keeper = try XCTUnwrap(repaired.spaces.first { $0.arcSourceID == "Default:work" && $0.profileID == snapshot.activeProfileID })
        let held = repaired.reachableIDs(in: keeper.id)
        XCTAssertTrue(held.contains(mine) && held.contains(today))
        XCTAssertEqual(repaired.activeSpaceID, keeper.id, "the merged copy was on screen; the kept one is now")
        let store = SidebarStore()
        store.applySnapshot(repaired)
        let rows = store.spaces.flatMap { space in SidebarTree.leaves(store.content(for: space.id).pinned + store.content(for: space.id).today).map(\.id) }
        XCTAssertEqual(Set(rows).count, rows.count, "each row in one place")
        XCTAssertEqual(Set(rows), tabsBefore.subtracting(store.profiles.flatMap { store.favorites(in: $0.id).map(\.id) }))
        // Idempotent.
        let (again, second) = ArcTwinSpaces.repair(repaired)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(again, repaired)
    }

    func testAStoreWithARowInTwoSpacesLoadsItOnce() {
        let (snapshot, _, _) = duplicated()
        let store = SidebarStore()
        store.applySnapshot(snapshot)
        var seen: [UUID: Int] = [:]
        for space in store.spaces {
            for row in SidebarTree.leaves(store.content(for: space.id).pinned + store.content(for: space.id).today) { seen[row.id, default: 0] += 1 }
        }
        XCTAssertTrue(seen.values.allSatisfy { $0 == 1 })
        let saved = store.makeSnapshot()
        let listed = saved.spaceContainers.values.flatMap { $0.pinned.childIDs + $0.unpinned.childIDs }
        XCTAssertEqual(Set(listed).count, listed.count)
    }

    func testTheRepairRunsOnceAtLoadAndKeepsTheFileItReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twin-repair-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sidebar.json")
        let (snapshot, mine, _) = duplicated()
        let original = try JSONEncoder().encode(snapshot)
        try original.write(to: url)

        let persistence = SidebarFilePersistence(fileURL: url)
        let loaded = try XCTUnwrap(persistence.loadSnapshot())
        XCTAssertEqual(loaded.spaces.count, snapshot.spaces.count - 2)
        XCTAssertTrue(loaded.reachableIDs(in: loaded.activeSpaceID).contains(mine))
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("sidebar.before-arc-twin-repair-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(backups[0])), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.arcTwinRepairMarkerURL.path))
        XCTAssertEqual(try JSONDecoder().decode(SidebarSnapshot.self, from: Data(contentsOf: url)), loaded, "the repaired sidebar is saved at once")

        // Once: a file with copies again (from anywhere) is left to the join's matching.
        try original.write(to: url)
        let again = try XCTUnwrap(SidebarFilePersistence(fileURL: url).loadSnapshot())
        XCTAssertEqual(again.spaces.count, snapshot.spaces.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("sidebar.before-") }.count, 1)
    }

    func testAFreshSidebarHasNothingToRepair() {
        let snapshot = SidebarStore().makeSnapshot()
        let (repaired, report) = ArcTwinSpaces.repair(snapshot)
        XCTAssertFalse(report.changed)
        XCTAssertEqual(repaired, snapshot)
    }
}
