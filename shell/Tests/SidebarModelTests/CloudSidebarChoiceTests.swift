import XCTest
@testable import SidebarModel

/// Switching Sync Sidebar on when iCloud already holds a sidebar: a
/// read-only look, then Use, Replace, Merge or Cancel; and Delete.
/// Everything runs against `InMemorySyncServer`, never CloudKit.
@MainActor
final class CloudSidebarChoiceTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        server = InMemorySyncServer()
    }

    private func mac(_ device: String, on: Bool, account: String? = "alice", store: SidebarStore = SidebarStore()) -> (store: SidebarStore, sync: SidebarSyncCoordinator) {
        var state = SidebarSyncState()
        state.enabled = on
        state.decision = on ? .user : nil
        let sync = SidebarSyncCoordinator(transport: server.transport(account: account), stateStore: InMemorySyncStateStore(state), deviceID: device,
                                          now: { [unowned self] in self.date })
        sync.host = store
        return (store, sync)
    }

    private func cycle(_ mac: (store: SidebarStore, sync: SidebarSyncCoordinator)) async {
        date += 2
        _ = await mac.sync.sync()
    }

    /// Another Mac's sidebar in iCloud: Home and Work, 3 pinned tabs, 1 favorite.
    private func otherMacInICloud() async -> (store: SidebarStore, sync: SidebarSyncCoordinator) {
        let other = mac("B", on: true)
        other.store.renameSpace(other.store.spaces[0].id, to: "Home")
        let work = other.store.addSpace(name: "Work")
        _ = other.store.addTab(kind: .pinned, title: "Docs", url: URL(string: "https://docs.test")!, in: other.store.spaces[0].id)
        _ = other.store.addTab(kind: .pinned, title: "Board", url: URL(string: "https://board.test")!, in: work.id)
        _ = other.store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test")!, in: work.id)
        _ = other.store.addTab(kind: .favorite, title: "Calendar", url: URL(string: "https://calendar.test")!)
        await cycle(other)
        return other
    }

    private func thisMacWithAnImport() -> (store: SidebarStore, sync: SidebarSyncCoordinator) {
        let here = mac("A", on: false)
        let imported = here.store.addSpace(name: "Imported")
        _ = here.store.addTab(kind: .pinned, title: "Just imported", url: URL(string: "https://imported.test")!, in: imported.id)
        _ = here.store.addTab(kind: .today, title: "Reading", url: URL(string: "https://reading.test")!, in: imported.id)
        return here
    }

    private func synced(_ store: SidebarStore) -> [String: SyncRecordBody] {
        SidebarSyncProjection.extract(store.makeSnapshot())
    }

    // MARK: - Looking

    func testDetectionStates() async throws {
        let here = mac("A", on: false)
        var detection = await here.sync.detectCloudSidebar()
        XCTAssertEqual(detection, .empty(accountID: "alice"), "no zone")

        let signedOut = mac("A", on: false, account: nil)
        detection = await signedOut.sync.detectCloudSidebar()
        guard case .signedOut = detection else { return XCTFail("\(detection)") }

        server.fault = .networkUnavailable
        detection = await here.sync.detectCloudSidebar()
        guard case .unreachable = detection else { return XCTFail("\(detection)") }
        server.fault = nil

        _ = await otherMacInICloud()
        let writes = server.modifyCount
        detection = await here.sync.detectCloudSidebar()
        let found = try XCTUnwrap(detection.found)
        XCTAssertEqual(found.summary.spaces, 2)
        XCTAssertEqual(found.summary.pinnedTabs, 3)
        XCTAssertEqual(found.summary.favorites, 1)
        XCTAssertEqual(found.summary.lastUpdated.map { abs($0.timeIntervalSince(date)) < 10 }, true)
        XCTAssertEqual(SyncCloudText.holds(found.summary, now: date).hasPrefix("It has 2 spaces, 3 pinned tabs and 1 favorite, last updated"), true)
        XCTAssertEqual(here.store.spaces.count, 1, "found is held aside, not applied")
        XCTAssertEqual(server.modifyCount, writes, "a look writes nothing")
        XCTAssertEqual(server.zoneCreations, 1)
    }

    func testAZoneWithOnlyDeletionsIsEmpty() async throws {
        let other = await otherMacInICloud()
        for space in other.store.spaces.dropFirst() { other.store.removeSpace(space.id) }
        other.store.renameSpace(other.store.spaces[0].id, to: "Personal")
        for tab in other.store.content(for: other.store.spaces[0].id).pinned { other.store.closeTab(tab.id) }
        // A zone whose every space record is a tombstone.
        var records = server.records(account: "alice")
        for (name, var wire) in records where wire.payload.kind == .space {
            wire.payload.tombstone = SyncStamp(millis: 1_900_000_000_000, device: "B")
            records[name] = wire
            server.overwrite(account: "alice", record: wire)
        }
        let detection = await mac("A", on: false).sync.detectCloudSidebar()
        XCTAssertEqual(detection, .empty(accountID: "alice"))
    }

    func testALookIsTotalAgainstCraftedRecords() async throws {
        _ = await otherMacInICloud()
        let evil = SyncStamp(millis: .max, counter: .max, device: "evil")
        server.overwrite(account: "alice", record: SyncWireRecord(recordName: SyncRecordKind.space.recordName(for: UUID()),
                                                                  payload: SyncRecordPayload(kind: .space, fields: ["name": SyncField(value: .string("Evil"), stamp: evil)])))
        server.overwrite(account: "alice", record: SyncWireRecord(recordName: "item_not-a-uuid", payload: SyncRecordPayload(kind: .item)))
        server.overwrite(account: "alice", record: SyncWireRecord(recordName: SyncRecordKind.item.recordName(for: UUID()), payload: SyncRecordPayload(kind: .space)))
        let detected = await mac("A", on: false).sync.detectCloudSidebar()
        let found = try XCTUnwrap(detected.found)
        XCTAssertEqual(found.summary.spaces, 2, "the impossible records are left out")
        XCTAssertEqual(found.records.count, server.records(account: "alice").count - 3)
        XCTAssertLessThan(found.summary.lastUpdated ?? .distantFuture, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testALookThatTakesTooLongIsUnreachable() async throws {
        final class Slow: SidebarSyncTransport, SidebarCloudReading, @unchecked Sendable {
            func accountStatus() async -> SyncAccountStatus {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .available(userID: "alice")
            }
            func readAllRecords() async throws -> [SyncWireRecord]? { nil }
            func deleteZone() async throws {}
            func prepareZone() async throws {}
            func fetchChanges(since token: Data?) async throws -> SyncFetchResult { SyncFetchResult(token: nil) }
            func modify(saving records: [SyncWireRecord], deleting names: [String]) async throws -> SyncModifyResult { SyncModifyResult() }
        }
        let coordinator = SidebarSyncCoordinator(transport: Slow(), stateStore: InMemorySyncStateStore(), deviceID: "A")
        coordinator.detectionTimeout = 0.05
        let started = Date()
        let detection = await coordinator.detectCloudSidebar()
        guard case .unreachable = detection else { return XCTFail("\(detection)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: - Choices

    func testUseCloudMakesThisMacICloudsSidebarWithNoLeftovers() async throws {
        let other = await otherMacInICloud()
        let here = thisMacWithAnImport()
        let detected = await here.sync.detectCloudSidebar()
        let found = try XCTUnwrap(detected.found)
        let before = server.records(account: "alice")
        here.sync.apply(.useCloud, from: found)
        XCTAssertTrue(here.sync.isEnabled)
        XCTAssertEqual(synced(here.store), synced(other.store), "this Mac's sidebar is iCloud's")
        XCTAssertFalse(here.store.spaces.contains { $0.name == "Imported" || $0.name == "Personal" }, "nothing of the replaced sidebar is left")
        XCTAssertEqual(server.records(account: "alice"), before, "applying uploads nothing by itself")
        await cycle(here)
        XCTAssertEqual(server.records(account: "alice").mapValues(\.payload), before.mapValues(\.payload), "and the first cycle has nothing to change")
        XCTAssertEqual(here.store.archivedTabs.map(\.tab.title), ["Reading"], "its Today tab is in the archive")
    }

    func testReplaceCloudGivesOtherMacsThisMacsSidebar() async throws {
        let other = await otherMacInICloud()
        let here = thisMacWithAnImport()
        let detected = await here.sync.detectCloudSidebar()
        let found = try XCTUnwrap(detected.found)
        here.sync.apply(.replaceCloud, from: found)
        let mine = synced(here.store)
        await cycle(here)
        XCTAssertEqual(synced(here.store), mine, "this Mac is unchanged")
        await cycle(other)
        XCTAssertEqual(synced(other.store), mine, "the other Mac now has this Mac's sidebar")
        XCTAssertFalse(other.store.spaces.contains { $0.name == "Work" })
    }

    func testMergeKeepsBoth() async throws {
        let other = await otherMacInICloud()
        let here = thisMacWithAnImport()
        let detected = await here.sync.detectCloudSidebar()
        let found = try XCTUnwrap(detected.found)
        here.sync.apply(.merge, from: found)
        await cycle(here)
        await cycle(other)
        for store in [here.store, other.store] {
            let names = Set(store.spaces.map(\.name))
            XCTAssertTrue(names.isSuperset(of: ["Home", "Work", "Imported"]), "\(names)")
        }
        XCTAssertEqual(synced(here.store), synced(other.store))
    }

    func testCancelIsJustNotChoosing() async throws {
        _ = await otherMacInICloud()
        let here = thisMacWithAnImport()
        let mine = here.store.makeSnapshot()
        let before = server.records(account: "alice")
        let writes = (server.modifyCount, server.zoneCreations, server.zoneDeletions)
        let detected = await here.sync.detectCloudSidebar()
        XCTAssertNotNil(detected.found)
        await cycle(here)
        XCTAssertFalse(here.sync.isEnabled)
        XCTAssertEqual(here.store.makeSnapshot(), mine)
        XCTAssertEqual(server.records(account: "alice"), before)
        XCTAssertTrue(writes == (server.modifyCount, server.zoneCreations, server.zoneDeletions))
    }

    func testDeleteRemovesICloudsSidebarAndTurnsSyncOffHere() async throws {
        _ = await otherMacInICloud()
        let here = thisMacWithAnImport()
        let detected = await here.sync.detectCloudSidebar()
        let found = try XCTUnwrap(detected.found)
        here.sync.apply(.merge, from: found)
        await cycle(here)
        let mine = here.store.makeSnapshot()
        try await here.sync.deleteCloudSidebar()
        XCTAssertFalse(server.hasZone(account: "alice"))
        XCTAssertFalse(here.sync.isEnabled)
        XCTAssertEqual(here.store.makeSnapshot(), mine, "this Mac's sidebar stays")
        let detection = await here.sync.detectCloudSidebar()
        XCTAssertEqual(detection, .empty(accountID: "alice"))
    }

    func testABackupReadsBackAsTheSidebar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = thisMacWithAnImport()
        let snapshot = here.store.makeSnapshot()
        let sidebar = folder.appendingPathComponent("sidebar.json")
        let first = try SidebarBackup.write(snapshot, besides: sidebar, reason: "before-icloud", now: date)
        let second = try SidebarBackup.write(snapshot, besides: sidebar, reason: "before-icloud", now: date)
        XCTAssertNotEqual(first, second, "a second copy never overwrites the first")
        XCTAssertEqual(first.deletingLastPathComponent(), SidebarBackup.folder(besides: sidebar))
        XCTAssertEqual(try JSONDecoder().decode(SidebarSnapshot.self, from: Data(contentsOf: first)), snapshot)
    }
}
