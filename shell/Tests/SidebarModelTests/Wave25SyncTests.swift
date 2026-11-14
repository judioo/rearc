import XCTest
@testable import SidebarModel

/// Wave 25: CloudKit sidebar sync, end to end against `InMemorySyncServer`
/// (no network, no CloudKit): two-device convergence, field-level conflicts,
/// deletes, offline queueing, restart from persisted state, zone resets,
/// account changes, quota and rate limits, concurrent reorders and folder cycles.

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class Device {
    let name: String
    let transport: InMemorySyncTransport
    let stateStore: InMemorySyncStateStore
    var store: SidebarStore
    private(set) var coordinator: SidebarSyncCoordinator
    let clock: TestClock

    init(_ name: String, server: InMemorySyncServer, account: String? = "alice", store: SidebarStore? = nil, clock: TestClock) {
        self.name = name
        self.clock = clock
        self.transport = server.transport(account: account)
        self.stateStore = InMemorySyncStateStore()
        self.store = store ?? SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        self.store.now = { [clock] in clock.date }
        self.coordinator = SidebarSyncCoordinator(transport: transport, stateStore: stateStore, deviceID: name, now: { [clock] in clock.date })
        coordinator.host = self.store
        coordinator.setEnabled(true)
    }

    @discardableResult
    func sync() async -> SyncCycleOutcome {
        clock.advance()
        let outcome = await coordinator.sync()
        clock.advance()
        return outcome
    }

    /// Quit and relaunch: the sidebar reloads from its snapshot, sync from its state file.
    func restart() {
        let snapshot = store.makeSnapshot()
        let reloaded = SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        reloaded.applySnapshot(snapshot)
        reloaded.now = { [clock] in clock.date }
        store = reloaded
        coordinator = SidebarSyncCoordinator(transport: transport, stateStore: stateStore, deviceID: name, now: { [clock] in clock.date })
        coordinator.host = store
    }

    var records: [String: SyncRecordBody] { SidebarSyncProjection.extract(store.makeSnapshot()) }

    /// What the app's scheduler does after each batch of edits: stamp them now.
    func edited() {
        coordinator.captureLocalChanges()
    }

    func space(named name: String) -> Space? { store.spaces.first { $0.name == name } }

    func pinnedTitles(_ spaceName: String) -> [String] {
        guard let space = space(named: spaceName) else { return [] }
        return SidebarTree.leaves(store.content(for: space.id).pinned).compactMap { entry in
            if case .tab(let tab) = entry { return tab.displayTitle }
            return nil
        }
    }

    func pinnedTab(_ title: String) -> Tab? {
        for space in store.spaces {
            for case .tab(let tab) in SidebarTree.leaves(store.content(for: space.id).pinned) where tab.displayTitle == title {
                return tab
            }
        }
        return nil
    }
}

private func url(_ text: String) -> URL { URL(string: "https://\(text).test")! }

/// Equal synced sidebars, reported record by record and field by field.
@MainActor
private func assertSameRecords(_ a: Device, _ b: Device, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let left = a.records, right = b.records
    var problems: [String] = []
    for name in Set(left.keys).union(right.keys).sorted() {
        guard let l = left[name] else { problems.append("only on \(b.name): \(name) \(right[name]!.values)"); continue }
        guard let r = right[name] else { problems.append("only on \(a.name): \(name) \(l.values)"); continue }
        for key in Set(l.values.keys).union(r.values.keys).sorted() where l.values[key] != r.values[key] {
            problems.append("\(name).\(key): \(a.name)=\(String(describing: l.values[key])) \(b.name)=\(String(describing: r.values[key]))")
        }
    }
    if !problems.isEmpty { XCTFail("\(message) " + problems.joined(separator: "\n"), file: file, line: line) }
}

@MainActor
final class Wave25SyncConvergenceTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: TestClock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = TestClock()
    }

    /// A sidebar with every synced kind: spaces with themes, favorites,
    /// pinned tabs, a folder, a split and a Boost; plus local-only rows.
    private func richDevice(_ name: String) -> Device {
        let device = Device(name, server: server, clock: clock)
        let store = device.store
        let personal = store.spaces[0].id
        _ = store.renameSpace(personal, to: "Home")
        let work = store.addSpace(name: "Work", theme: SpaceTheme.presets[2], iconName: "briefcase.fill")
        store.setSpaceTheme(personal, theme: SpaceTheme.presets[4])
        _ = store.addTab(kind: .favorite, title: "Mail", url: url("mail"))
        _ = store.addTab(kind: .pinned, title: "Docs", url: url("docs"), in: personal)
        let folder = store.createFolder(title: "Reading", in: personal)!
        let article = store.addTab(kind: .pinned, title: "Article", url: url("article"), in: personal)
        _ = store.moveItem(article.id, to: .folder(folder.id), index: 0)
        let left = store.addTab(kind: .pinned, title: "Left", url: url("left"), in: work.id)
        let right = store.addTab(kind: .pinned, title: "Right", url: url("right"), in: work.id)
        XCTAssertNotNil(store.createSplit(tabIDs: [left.id, right.id], orientation: .horizontal, in: work.id))
        let boost = BoostPackage.newStyle(name: "Dark", hostScope: [BoostHostRule(host: "docs.test")], css: "body{}")
        XCTAssertNil(store.addBoost(boost))
        store.setBoostSpacePolicy(packageID: boost.manifest.id, spaceID: work.id, policy: .forceOff)
        store.setBoostSpacePolicy(packageID: boost.manifest.id, spaceID: personal, policy: .forceOn)
        _ = store.addTab(kind: .today, title: "Scratch", url: url("scratch"), in: personal)
        return device
    }

    func testTwoDevicesConvergeOnEverySyncedKind() async {
        let a = richDevice("A")
        let outcome = await a.sync()
        XCTAssertNil(outcome.error)
        XCTAssertGreaterThan(outcome.pushed, 0)
        XCTAssertEqual(a.coordinator.state.pendingCount, 0)

        let b = Device("B", server: server, clock: clock)
        await b.sync()
        assertSameRecords(b, a, "B holds exactly A's synced sidebar")
        XCTAssertEqual(b.store.spaces.map(\.name), ["Home", "Work"])
        XCTAssertEqual(b.space(named: "Home")?.theme, SpaceTheme.presets[4])
        XCTAssertEqual(b.space(named: "Work")?.iconName, "briefcase.fill")
        // A favorite's page title stays on its Mac (RC-0.1.0-602 T-05): until it loads, B names it by host.
        XCTAssertEqual(b.store.favorites(in: b.store.activeProfileID).map(\.title), ["mail.test"])
        XCTAssertEqual(b.pinnedTitles("Home"), ["Docs", "Article"])
        let work = b.space(named: "Work")!
        guard case .split(let split)? = b.store.content(for: work.id).pinned.first else {
            return XCTFail("split did not sync")
        }
        XCTAssertEqual(split.tabs.map(\.title), ["Left", "Right"])
        XCTAssertEqual(b.store.boostLibrary().packages.map(\.manifest.name), ["Dark"])
        XCTAssertEqual(b.store.boostLibrary().installations.first?.spacePolicy[work.id], .forceOff)
        // Today tabs are per-Mac.
        XCTAssertFalse(b.store.displayTabs().contains { $0.title == "Scratch" })
        XCTAssertTrue(a.store.displayTabs().contains { $0.title == "Scratch" })

        // Quiescent: nothing more moves.
        let again = await a.sync()
        XCTAssertEqual(again.pushed, 0)
        XCTAssertFalse(again.appliedRemote)
        let againB = await b.sync()
        XCTAssertEqual(againB.pushed, 0)
    }

    func testEditsOnBothMacsMergeFieldByField() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()

        let homeA = a.space(named: "Home")!.id
        _ = a.store.renameSpace(homeA, to: "House")
        clock.advance()
        b.store.setSpaceTheme(homeA, theme: SpaceTheme.presets[1])
        _ = b.store.renameTab(b.pinnedTab("Docs")!.id, to: "Manuals")

        await a.sync()
        await b.sync()
        await a.sync()
        assertSameRecords(a, b)
        XCTAssertEqual(a.store.space(withID: homeA)?.name, "House")
        XCTAssertEqual(a.store.space(withID: homeA)?.theme, SpaceTheme.presets[1])
        XCTAssertEqual(a.pinnedTitles("House"), ["Manuals", "Article"])
    }

    func testSameFieldConflictLastWriterWins() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        let docs = a.pinnedTab("Docs")!.id

        _ = a.store.renameTab(docs, to: "Earlier")
        a.edited()
        clock.advance(5)
        _ = b.store.renameTab(docs, to: "Later")
        b.edited()
        // B uploads first; A's older rename arrives afterwards and must lose.
        await b.sync()
        await a.sync()
        await b.sync()
        XCTAssertEqual(a.store.tab(withID: docs)?.customTitle, "Later")
        XCTAssertEqual(b.store.tab(withID: docs)?.customTitle, "Later")
    }

    func testStaleSaveIsRejectedMergedAndRetried() async throws {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        let docs = a.pinnedTab("Docs")!.id
        let name = SyncRecordKind.item.recordName(for: docs)

        _ = b.store.renameTab(docs, to: "From B")
        // Another Mac saves the same record between B's fetch and B's upload.
        server.beforeModify = { server in
            var record = try! XCTUnwrap(server.records(account: "alice")[name])
            // An hour ahead: later than B's write, and still a stamp a real Mac could make (RC-0.1.0-602 T-03).
            record.payload.fields["savedTitle"] = SyncField(value: .string("From C"), stamp: SyncStamp(millis: 1_800_003_600_000, device: "C"))
            server.overwrite(account: "alice", record: record)
        }
        let outcome = await b.sync()
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.appliedRemote)
        let stored = try XCTUnwrap(server.records(account: "alice")[name])
        XCTAssertEqual(stored.payload.values["customTitle"], .string("From B"), "B's write survived the conflict")
        XCTAssertEqual(stored.payload.values["savedTitle"], .string("From C"), "the concurrent write survived too")
        XCTAssertEqual(b.store.tab(withID: docs)?.savedTitle, "From C")
        await a.sync()
        assertSameRecords(a, b)
    }

    func testDeletePropagatesAndBeatsOlderOfflineEdit() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        let docs = a.pinnedTab("Docs")!.id

        _ = b.store.renameTab(docs, to: "Edited offline")
        b.edited()
        clock.advance(5)
        a.store.closeTab(docs)
        a.edited()
        await a.sync()
        await b.sync()
        await a.sync()
        XCTAssertNil(b.store.tab(withID: docs), "the later delete wins over the earlier edit")
        XCTAssertNil(a.store.tab(withID: docs))
        let record = server.records(account: "alice")[SyncRecordKind.item.recordName(for: docs)]
        XCTAssertNotNil(record?.payload.tombstone)
        XCTAssertEqual(record?.payload.isAlive, false)
    }

    func testEditAfterDeleteBringsTheRowBack() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        let docs = a.pinnedTab("Docs")!.id

        a.store.closeTab(docs)
        a.edited()
        clock.advance(5)
        _ = b.store.renameTab(docs, to: "Still needed")
        b.edited()
        await a.sync()
        await b.sync()
        await a.sync()
        XCTAssertEqual(a.store.tab(withID: docs)?.customTitle, "Still needed")
        assertSameRecords(a, b)
    }

    func testSpaceDeletionRemovesItsPinnedRowsEverywhere() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        let work = a.space(named: "Work")!.id
        XCTAssertTrue(a.store.removeSpace(work))
        await a.sync()
        await b.sync()
        XCTAssertNil(b.space(named: "Work"))
        assertSameRecords(a, b)
    }

    func testConcurrentReordersConverge() async {
        let a = Device("A", server: server, clock: clock)
        let space = a.store.spaces[0].id
        let tabs = (1 ... 5).map { a.store.addTab(kind: .pinned, title: "T\($0)", url: url("t\($0)"), in: space) }
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        XCTAssertEqual(b.pinnedTitles("Personal"), ["T1", "T2", "T3", "T4", "T5"])

        // Offline at the same time: A drags T5 to the top, B drags T1 to the
        // bottom and both pin a new tab at the end.
        _ = a.store.moveItem(tabs[4].id, to: .section(spaceID: space, section: .pinned), index: 0)
        _ = b.store.moveItem(tabs[0].id, to: .section(spaceID: space, section: .pinned), index: 5)
        _ = a.store.addTab(kind: .pinned, title: "NewA", url: url("newa"), in: space)
        _ = b.store.addTab(kind: .pinned, title: "NewB", url: url("newb"), in: space)

        await a.sync()
        await b.sync()
        await a.sync()
        await b.sync()
        XCTAssertEqual(a.pinnedTitles("Personal"), b.pinnedTitles("Personal"))
        let order = a.pinnedTitles("Personal")
        XCTAssertEqual(order.first, "T5")
        XCTAssertEqual(Set(order), ["T1", "T2", "T3", "T4", "T5", "NewA", "NewB"])
        XCTAssertEqual(order.filter { ["T2", "T3", "T4"].contains($0) }, ["T2", "T3", "T4"])
        assertSameRecords(a, b)
    }

    func testFolderCycleFromConcurrentMovesIsBrokenTheSameWayOnBothMacs() async {
        let a = Device("A", server: server, clock: clock)
        let space = a.store.spaces[0].id
        let f1 = a.store.createFolder(title: "F1", in: space)!
        let f2 = a.store.createFolder(title: "F2", in: space)!
        _ = a.store.addTab(kind: .pinned, title: "Keep", url: url("keep"), in: space)
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()

        XCTAssertTrue(a.store.moveItem(f1.id, to: .folder(f2.id), index: 0))
        a.edited()
        clock.advance()
        XCTAssertTrue(b.store.moveItem(f2.id, to: .folder(f1.id), index: 0))
        b.edited()
        await a.sync()
        await b.sync()
        await a.sync()

        assertSameRecords(a, b)
        let folders = SidebarTree.folders(a.store.content(for: space).pinned).map(\.title).sorted()
        XCTAssertEqual(folders, ["F1", "F2"], "both folders still visible, no cycle")
        // A's move was first, so it is the one revoked: F1 goes back to the root, F2 stays inside it.
        let roots = a.store.content(for: space).pinned.compactMap { entry -> String? in
            if case .folder(let folder) = entry { return folder.title }
            return nil
        }
        XCTAssertEqual(roots, ["F1"])
    }

    func testRowInADeletedFolderIsRescuedToThePinnedRoot() async {
        let a = Device("A", server: server, clock: clock)
        let space = a.store.spaces[0].id
        let folder = a.store.createFolder(title: "Box", in: space)!
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()

        _ = a.store.deleteFolder(folder.id, keepingChildren: false)
        clock.advance()
        let late = b.store.addTab(kind: .pinned, title: "Late", url: url("late"), in: space)
        _ = b.store.moveItem(late.id, to: .folder(folder.id), index: 0)
        await a.sync()
        await b.sync()
        await a.sync()
        XCTAssertEqual(a.pinnedTitles("Personal"), ["Late"])
        XCTAssertTrue(SidebarTree.folders(a.store.content(for: space).pinned).isEmpty)
        assertSameRecords(a, b)
    }

    func testFreshInstallAdoptsInsteadOfDuplicating() async {
        let a = richDevice("A")
        await a.sync()
        let fresh = Device("B", server: server, store: SidebarStore.sample(), clock: clock)
        await fresh.sync()
        XCTAssertEqual(fresh.store.spaces.map(\.name), ["Home", "Work"])
        XCTAssertEqual(fresh.store.profiles.count, 1)
        assertSameRecords(fresh, a)
        // The starter Today tabs are kept, moved into the adopted sidebar.
        XCTAssertTrue(fresh.store.displayTabs().contains { $0.title == "SwiftUI Documentation" })
    }

    func testFreshInstallOnTheEmptyStarterAdoptsTheICloudSidebar() async {
        let a = richDevice("A")
        await a.sync()
        let starter = SidebarStore.starter()
        XCTAssertTrue(SidebarSyncProjection.isPristine(starter.makeSnapshot()))
        let fresh = Device("B", server: server, store: starter, clock: clock)
        await fresh.sync()
        XCTAssertEqual(fresh.store.spaces.map(\.name), ["Home", "Work"], "no empty Personal space next to iCloud's")
        XCTAssertEqual(fresh.store.profiles.count, 1)
        assertSameRecords(fresh, a)
    }

    func testAStarterTheOnboardingShapedMergesWithTheICloudSidebar() async {
        let a = richDevice("A")
        await a.sync()
        let starter = SidebarStore.starter()
        _ = starter.addSpace(name: "Side project", iconName: "🎮")
        XCTAssertFalse(SidebarSyncProjection.isPristine(starter.makeSnapshot()))
        let b = Device("B", server: server, store: starter, clock: clock)
        await b.sync()
        XCTAssertEqual(Set(b.store.spaces.map(\.name)), ["Home", "Work", "Personal", "Side project"])
    }

    func testUsedMacMergesWithTheICloudSidebar() async {
        let a = richDevice("A")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        _ = b.store.addTab(kind: .pinned, title: "Mine", url: url("mine"), in: b.store.spaces[0].id)
        await b.sync()
        await a.sync()
        XCTAssertEqual(Set(b.store.spaces.map(\.name)), ["Home", "Work", "Personal"])
        XCTAssertNotNil(a.pinnedTab("Mine"))
        assertSameRecords(a, b)
    }
}

@MainActor
final class Wave25SyncResilienceTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: TestClock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = TestClock()
    }

    private func pinned(_ device: Device, _ title: String) -> Tab {
        device.store.addTab(kind: .pinned, title: title, url: url(title.lowercased()), in: device.store.spaces[0].id)
    }

    func testOfflineEditsQueueAndUploadWhenBack() async {
        let a = Device("A", server: server, clock: clock)
        await a.sync()
        server.fault = .networkUnavailable
        _ = pinned(a, "Offline")
        let failed = await a.sync()
        XCTAssertEqual(failed.error, .networkUnavailable)
        XCTAssertGreaterThan(a.coordinator.state.pendingCount, 0)
        guard case .waiting = a.coordinator.details.phase else { return XCTFail("\(a.coordinator.details.phase)") }
        XCTAssertEqual(a.coordinator.details.engineStatus, .error(SyncTransportError.networkUnavailable.userMessage))

        server.fault = nil
        let back = await a.sync()
        XCTAssertNil(back.error)
        XCTAssertEqual(a.coordinator.state.pendingCount, 0)
        XCTAssertEqual(a.coordinator.details.phase, .upToDate)
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        XCTAssertNotNil(b.pinnedTab("Offline"))
    }

    func testRestartResumesFromPersistedStateWithoutReuploading() async {
        let a = Device("A", server: server, clock: clock)
        _ = pinned(a, "One")
        _ = pinned(a, "Two")
        await a.sync()
        let saved = a.coordinator.state
        XCTAssertNotNil(saved.transportToken)
        XCTAssertTrue(saved.joined)

        server.fault = .networkUnavailable
        _ = pinned(a, "Queued")
        await a.sync()
        let queued = a.coordinator.state.pendingCount
        XCTAssertGreaterThan(queued, 0)

        a.restart()
        XCTAssertEqual(a.coordinator.state.pendingCount, queued, "the queue survived the relaunch")
        server.fault = nil
        let resumed = await a.sync()
        XCTAssertNil(resumed.error)
        XCTAssertEqual(resumed.pushed, queued, "only the queued records upload after a restart")
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        XCTAssertNotNil(b.pinnedTab("Queued"))
        assertSameRecords(a, b)
    }

    func testStateFileRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w25-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SidebarSyncStateFile(fileURL: directory.appendingPathComponent(SidebarSyncStateFile.fileName))
        XCTAssertEqual(file.load(), SidebarSyncState(), "a missing file is a fresh state")
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        state.accountID = "alice"
        state.transportToken = Data("token".utf8)
        state.records["space_x"] = SyncShadowRecord(
            payload: SyncRecordPayload(kind: .space, fields: ["name": SyncField(value: .string("Home"), stamp: SyncStamp(millis: 5, device: "A"))]),
            serverTag: Data("tag".utf8),
            pending: true
        )
        file.save(state)
        XCTAssertEqual(file.load(), state)
    }

    func testZoneResetReuploadsFromBothMacsAndConverges() async {
        let a = Device("A", server: server, clock: clock)
        _ = pinned(a, "Survivor")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        _ = pinned(b, "OnlyB")

        server.resetZone(account: "alice")
        let outcomeA = await a.sync()
        XCTAssertNil(outcomeA.error, "zoneNotFound is handled by recreating the zone")
        let outcomeB = await b.sync()
        XCTAssertNil(outcomeB.error)
        await a.sync()
        assertSameRecords(a, b)
        XCTAssertNotNil(a.pinnedTab("OnlyB"))
        XCTAssertNotNil(server.records(account: "alice")[SyncRecordKind.item.recordName(for: a.pinnedTab("Survivor")!.id)])
    }

    func testUserDeletedDataTurnsSyncOffAndNeverReuploads() async {
        let a = Device("A", server: server, clock: clock)
        _ = pinned(a, "Private")
        await a.sync()
        server.userDeletesData(account: "alice")
        let outcome = await a.sync()
        XCTAssertEqual(outcome.error, .userDeletedZone)
        XCTAssertFalse(a.coordinator.isEnabled)
        XCTAssertTrue(server.records(account: "alice").isEmpty)
        XCTAssertNotNil(a.pinnedTab("Private"), "the local sidebar is untouched")
        let skipped = await a.sync()
        XCTAssertTrue(skipped.skipped)
    }

    func testAccountSwitchJoinsTheNewAccountAndSignOutPauses() async {
        let a = Device("A", server: server, clock: clock)
        _ = pinned(a, "Shared")
        await a.sync()
        let aliceRecords = server.records(account: "alice")

        a.transport.account = nil
        let signedOut = await a.sync()
        XCTAssertEqual(signedOut.error, .notAuthenticated)
        guard case .signedOut = a.coordinator.details.phase else { return XCTFail("\(a.coordinator.details.phase)") }

        a.transport.account = "bob"
        let switched = await a.sync()
        XCTAssertNil(switched.error)
        XCTAssertEqual(a.coordinator.state.accountID, "bob")
        XCTAssertEqual(Set(server.records(account: "bob").keys), Set(aliceRecords.keys), "this Mac's sidebar joins Bob's iCloud")
        XCTAssertEqual(server.records(account: "alice"), aliceRecords, "Alice's zone is untouched")
    }

    func testQuotaExceededKeepsTheQueue() async {
        let a = Device("A", server: server, clock: clock)
        await a.sync()
        _ = pinned(a, "Big")
        server.fault = .quotaExceeded
        let outcome = await a.sync()
        XCTAssertEqual(outcome.error, .quotaExceeded)
        XCTAssertGreaterThan(a.coordinator.state.pendingCount, 0)
        XCTAssertEqual(a.coordinator.details.phase, .waiting(SyncTransportError.quotaExceeded.userMessage))
        server.fault = nil
        await a.sync()
        XCTAssertEqual(a.coordinator.state.pendingCount, 0)
    }

    func testRateLimitCarriesRetryAfter() async {
        let a = Device("A", server: server, clock: clock)
        server.fault = .rateLimited(retryAfter: 30)
        let outcome = await a.sync()
        XCTAssertEqual(outcome.error, .rateLimited(retryAfter: 30))
        XCTAssertEqual(outcome.error?.retryAfter, 30)
        XCTAssertTrue(outcome.error?.isTransient == true)
    }

    func testPagedFetchAndExpiredTokenStillConverge() async {
        server.pageSize = 2
        let a = Device("A", server: server, clock: clock)
        for index in 1 ... 7 { _ = pinned(a, "P\(index)") }
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        assertSameRecords(b, a)

        _ = pinned(a, "After")
        await a.sync()
        server.expireTokens(account: "alice")
        _ = pinned(a, "AfterExpiry")
        await a.sync()
        let outcome = await b.sync()
        XCTAssertNil(outcome.error)
        assertSameRecords(b, a)
    }

    func testOldTombstonesAreGarbageCollectedFromTheServer() async {
        let a = Device("A", server: server, clock: clock)
        let doomed = pinned(a, "Doomed")
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        a.store.closeTab(doomed.id)
        await a.sync()
        let name = SyncRecordKind.item.recordName(for: doomed.id)
        XCTAssertNotNil(server.records(account: "alice")[name])
        clock.advance(SidebarSyncCoordinator.tombstoneLifetime + 60)
        await a.sync()
        XCTAssertNil(server.records(account: "alice")[name], "a month-old tombstone is deleted for good")
        XCTAssertNil(a.coordinator.state.records[name])
        await b.sync()
        XCTAssertNil(b.coordinator.state.records[name])
        XCTAssertNil(b.store.tab(withID: doomed.id))
    }

    func testEditsAreStampedWhenMadeEvenWithoutNetwork() async {
        let a = Device("A", server: server, clock: clock)
        await a.sync()
        server.fault = .networkUnavailable
        let calls = server.fetchCount + server.modifyCount
        _ = pinned(a, "Plane")
        a.edited()
        XCTAssertEqual(server.fetchCount + server.modifyCount, calls, "capturing needs no server")
        let name = SyncRecordKind.item.recordName(for: a.pinnedTab("Plane")!.id)
        let stamp = a.coordinator.state.records[name]?.payload.fields["title"]?.stamp
        XCTAssertEqual(stamp?.millis, Int64(clock.date.timeIntervalSince1970 * 1000))
        XCTAssertEqual(a.coordinator.state.records[name]?.pending, true)
    }

    func testDisabledSyncIsInert() async {
        let a = Device("A", server: server, clock: clock)
        a.coordinator.setEnabled(false)
        _ = pinned(a, "Local")
        let outcome = await a.sync()
        XCTAssertTrue(outcome.skipped)
        XCTAssertEqual(server.modifyCount + server.fetchCount, 0)
        XCTAssertEqual(a.coordinator.details.phase, .off)
    }
}

final class Wave25SyncPrimitiveTests: XCTestCase {
    func testBetweenIsStrictlyBetween() {
        let samples: [String?] = [nil, "", "0", "1", "U", "T", "TU", "Tz", "a", "z", "zz", "B0", "B00U", "U0U"]
        for left in samples {
            for right in samples {
                if let left, let right, left >= right { continue }
                guard let mid = SyncRanks.between(left, right) else {
                    // Only impossible when right is left followed by zeros.
                    XCTAssertTrue(right.map { $0.hasPrefix(left ?? "") && $0.dropFirst((left ?? "").count).allSatisfy { $0 == "0" } } ?? false, "\(String(describing: left)) \(String(describing: right))")
                    continue
                }
                if let left { XCTAssertGreaterThan(mid, left) }
                if let right { XCTAssertLessThan(mid, right) }
            }
        }
        var current: String? = "T"
        for _ in 0 ..< 200 {
            let next = SyncRanks.between(current, "U")!
            XCTAssertGreaterThan(next, current!)
            XCTAssertLessThan(next, "U")
            current = next
        }
    }

    func testNormalizedKeepsTheLongestRunAndIncreases() {
        let input = ["B", "D", "", "C", "F", "F", "A"]
        let output = SyncRanks.normalized(input)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(zip(output, output.dropFirst()).filter { $0 >= $1 }.count, 0, "\(output)")
        let kept = zip(input, output).filter { $0 == $1 }.count
        XCTAssertEqual(kept, 3, "a longest increasing run (B, D, F) is kept")
        XCTAssertEqual(SyncRanks.normalized(["a", "b", "c"]), ["a", "b", "c"])
    }

    func testMergeIsCommutativeAssociativeAndIdempotent() {
        func stamp(_ millis: Int64, _ device: String) -> SyncStamp { SyncStamp(millis: millis, device: device) }
        let a = SyncRecordPayload(kind: .item, fields: [
            "title": SyncField(value: .string("a"), stamp: stamp(3, "A")),
            "url": SyncField(value: .string("u1"), stamp: stamp(1, "A")),
        ])
        let b = SyncRecordPayload(kind: .item, fields: [
            "title": SyncField(value: .string("b"), stamp: stamp(2, "B")),
            "url": SyncField(value: .string("u2"), stamp: stamp(4, "B")),
        ], tombstone: stamp(3, "B"))
        let c = SyncRecordPayload(kind: .item, fields: [
            "title": SyncField(value: .string("c"), stamp: stamp(3, "C")),
        ])
        let merge = SyncRecordPayload.merge
        XCTAssertEqual(merge(a, b), merge(b, a))
        XCTAssertEqual(merge(merge(a, b), c), merge(a, merge(b, c)))
        XCTAssertEqual(merge(a, a), a)
        let all = merge(merge(a, b), c)
        XCTAssertEqual(all.values["title"], .string("c"), "equal millis: device C > A")
        XCTAssertEqual(all.values["url"], .string("u2"))
        XCTAssertTrue(all.isAlive, "url was written after the tombstone")
        XCTAssertFalse(merge(a, SyncRecordPayload(kind: .item, tombstone: stamp(9, "Z"))).isAlive)
    }

    func testClockIsMonotonicAndStaysAheadOfPeers() {
        var clock = HybridLogicalClock(device: "A")
        let now = Date(timeIntervalSince1970: 100)
        let first = clock.tick(now: now)
        let second = clock.tick(now: now)
        XCTAssertLessThan(first, second)
        clock.observe(SyncStamp(millis: 500_000, counter: 7, device: "B"))
        let third = clock.tick(now: now)
        XCTAssertGreaterThan(third, SyncStamp(millis: 500_000, counter: 7, device: "B"))
    }

    func testRecordPayloadRoundTripsThroughJSON() throws {
        let payload = SyncRecordPayload(kind: .boost, fields: [
            "package": SyncField(value: .object(["n": .number(1), "list": .array([.bool(true), .null])]), stamp: SyncStamp(millis: 1, device: "A")),
        ], tombstone: SyncStamp(millis: 0, counter: 2, device: "A"))
        XCTAssertEqual(try SyncRecordPayload.decode(payload.encoded()), payload)
    }

    func testRecordNamesParse() {
        let id = UUID()
        for kind in SyncRecordKind.allCases {
            let parsed = SyncRecordKind.parse(recordName: kind.recordName(for: id))
            XCTAssertEqual(parsed?.kind, kind)
            XCTAssertEqual(parsed?.id, id)
        }
        XCTAssertNil(SyncRecordKind.parse(recordName: "rearc-sync-keyring"))
    }

    func testUnreadableRecordsAreNeverTombstoned() {
        let unknown = SyncRecordPayload(kind: .item, fields: [
            "type": SyncField(value: .string("hologram"), stamp: SyncStamp(millis: 1, device: "Future")),
            "parent": SyncField(value: .string("pinned:\(UUID().uuidString)"), stamp: SyncStamp(millis: 1, device: "Future")),
        ])
        XCTAssertFalse(SidebarSyncProjection.canMaterialize(SyncRecordKind.item.recordName(for: UUID()), unknown))
    }

    func testExtractApplyRoundTripIsStable() {
        let store = SidebarStore.sample()
        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        var payloads: [String: SyncRecordPayload] = [:]
        for (name, body) in records {
            payloads[name] = SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: SyncStamp(millis: 1, device: "A")) })
        }
        let rebuilt = SidebarSyncProjection.apply(payloads, onto: store.makeSnapshot())
        XCTAssertEqual(SidebarSyncProjection.extract(rebuilt), records)
        XCTAssertTrue(SidebarSyncProjection.isPristine(store.makeSnapshot()))
        XCTAssertTrue(SidebarSyncProjection.isPristine(SidebarStore().makeSnapshot()))
        _ = store.addTab(kind: .pinned, title: "Mine", url: URL(string: "https://mine.test")!)
        XCTAssertFalse(SidebarSyncProjection.isPristine(store.makeSnapshot()))
    }
}

final class Wave25SyncGatingTests: XCTestCase {
    func testTestRunnerIsNotEntitledSoSyncIsInert() async {
        XCTAssertFalse(CloudKitSyncAvailability.hasCloudKitEntitlement)
        let engine = await CloudKitSyncAvailability.makeEngine(stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w25-unused.json"))
        XCTAssertTrue(engine is UnavailableSyncEngine)
        guard case .unavailable(let reason) = engine.status else { return XCTFail("\(engine.status)") }
        XCTAssertTrue(reason.hasPrefix(CloudKitSyncAvailability.unavailableMessage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w25-unused.json").path))
    }

    func testCheckNeedsTheContainerAndCloudKitService() {
        let container = CloudKitSyncAvailability.defaultContainerIdentifier
        let full: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": [container],
            "com.apple.developer.icloud-services": ["CloudKit"],
        ]
        XCTAssertEqual(CloudKitSyncAvailability.check(configuredContainer: container) { full[$0] }, .available(containerIdentifier: container))
        guard case .unavailable = CloudKitSyncAvailability.check(configuredContainer: nil, entitlement: { full[$0] }) else { return XCTFail() }
        guard case .unavailable = CloudKitSyncAvailability.check(configuredContainer: "iCloud.other", entitlement: { full[$0] }) else { return XCTFail() }
        let noService: [String: Any] = ["com.apple.developer.icloud-container-identifiers": [container]]
        guard case .unavailable = CloudKitSyncAvailability.check(configuredContainer: container, entitlement: { noService[$0] }) else { return XCTFail() }
        guard case .unavailable = CloudKitSyncAvailability.check(configuredContainer: container, entitlement: { _ in nil }) else { return XCTFail() }
    }

    func testSettingsTextForEachPhase() {
        let off = SyncSettingsPresentation(details: SyncStatusDetails(phase: .off), enabled: false)
        XCTAssertEqual(off.statusText, "Off")
        XCTAssertEqual(off.lastSyncedText, "Never")
        XCTAssertFalse(off.canSyncNow)
        let now = Date()
        let synced = SyncSettingsPresentation(
            details: SyncStatusDetails(phase: .upToDate, lastSyncedAt: now.addingTimeInterval(-120), account: .available(userID: "x")),
            enabled: true,
            now: now
        )
        XCTAssertEqual(synced.statusText, "Up to date")
        XCTAssertEqual(synced.accountText, "Signed in to iCloud")
        XCTAssertNotEqual(synced.lastSyncedText, "Never")
        XCTAssertTrue(synced.canSyncNow)
        let queued = SyncSettingsPresentation(details: SyncStatusDetails(phase: .waiting("No network"), pendingCount: 3), enabled: true)
        XCTAssertEqual(queued.pendingText, "3 changes waiting to upload")
        XCTAssertEqual(queued.errorText, "No network")
        XCTAssertFalse(SyncSettingsPresentation(details: SyncStatusDetails(phase: .syncing), enabled: true).canSyncNow)
    }
}

@MainActor
final class Wave25SchedulerTests: XCTestCase {
    func testSchedulerSyncsWhenEnabledAndReportsStatus() async throws {
        let server = InMemorySyncServer()
        let store = SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(), deviceID: "A")
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        // Edits and "Sync now" run at once; the poll loop waits until stopped.
        scheduler.sleeper = { delay in
            if delay >= SidebarSyncScheduler.pollInterval { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        }
        scheduler.attach(host: store)
        final class Log: @unchecked Sendable { var statuses: [SyncEngineStatus] = [] }
        let log = Log()
        scheduler.onStatusChange = { log.statuses.append($0) }
        coordinator.setEnabled(false)
        scheduler.start()
        XCTAssertEqual(scheduler.status, .local, "an explicit off is preserved")
        XCTAssertEqual(server.fetchCount, 0)

        scheduler.setUserEnabled(true)
        await scheduler.runCycle()
        XCTAssertTrue(scheduler.isUserEnabled)
        XCTAssertEqual(scheduler.status, .idleSynced)
        XCTAssertTrue(log.statuses.contains(.syncing))
        XCTAssertFalse(server.records(account: "alice").isEmpty)
        scheduler.setUserEnabled(false)
        XCTAssertEqual(scheduler.status, .local)
        scheduler.stop()
    }
}

/// Wave 28: a space's gradient, grain and appearance sync in their own
/// record, so the wave 25 space record (and any Mac still on it) sees only
/// the base colour.
@MainActor
final class Wave28ThemeSyncTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: TestClock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = TestClock()
    }

    private func styled(_ base: SpaceTheme = SpaceTheme.presets[1]) -> SpaceTheme {
        var theme = base
        theme.gradientColors = [SpaceColor(red: 0.9, green: 0.2, blue: 0.4), SpaceColor(red: 0.1, green: 0.8, blue: 0.5)]
        theme.noise = 0.4
        theme.appearance = .dark
        return theme
    }

    func testGradientGrainAndAppearanceReachTheOtherMac() async {
        let a = Device("A", server: server, clock: clock)
        let home = a.store.spaces[0].id
        _ = a.store.renameSpace(home, to: "Home")
        a.store.setSpaceTheme(home, theme: styled())
        await a.sync()

        let spaceRecord = a.records[SyncRecordKind.space.recordName(for: home)]!
        guard case .object(let theme)? = spaceRecord.values["theme"] else { return XCTFail("no theme field") }
        XCTAssertEqual(Set(theme.keys), ["red", "green", "blue"], "the space record keeps the wave 25 shape")
        let styleRecord = a.records[SyncRecordKind.spaceStyle.recordName(for: home)]
        XCTAssertEqual(styleRecord?.kind, .spaceStyle)

        let b = Device("B", server: server, clock: clock)
        await b.sync()
        XCTAssertEqual(b.space(named: "Home")?.theme, styled())
        assertSameRecords(a, b)
        let again = await a.sync()
        XCTAssertEqual(again.pushed, 0, "quiescent")
    }

    func testGrainOnOneMacAndAppearanceOnTheOtherBothStay() async {
        let a = Device("A", server: server, clock: clock)
        let home = a.store.spaces[0].id
        a.store.setSpaceTheme(home, theme: styled())
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()

        var grain = a.store.spaces[0].theme
        grain.noise = 0.9
        a.store.setSpaceTheme(home, theme: grain)
        a.edited()
        var light = b.store.spaces[0].theme
        light.appearance = .light
        b.store.setSpaceTheme(home, theme: light)
        b.edited()
        await a.sync()
        await b.sync()
        await a.sync()

        for device in [a, b] {
            XCTAssertEqual(device.store.spaces[0].theme.noise, 0.9, accuracy: 1e-9, device.name)
            XCTAssertEqual(device.store.spaces[0].theme.appearance, .light, device.name)
        }
        assertSameRecords(a, b)
    }

    func testBackToOneColourDropsTheStyleRecordEverywhere() async {
        let a = Device("A", server: server, clock: clock)
        let home = a.store.spaces[0].id
        a.store.setSpaceTheme(home, theme: styled())
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()

        a.store.setSpaceTheme(home, theme: SpaceTheme.presets[3])
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertNil(a.records[SyncRecordKind.spaceStyle.recordName(for: home)])
        XCTAssertEqual(b.store.spaces[0].theme, SpaceTheme.presets[3])
        XCTAssertTrue(SidebarSyncProjection.canMaterialize(
            SyncRecordKind.spaceStyle.recordName(for: home),
            SyncRecordPayload(kind: .spaceStyle, fields: ["noise": SyncField(value: .number(0.2), stamp: SyncStamp(millis: 1, device: "A"))])
        ), "a style record with only some fields still reads")
    }
}

@MainActor
final class SyncedScriptApprovalTests: XCTestCase {
    func testScriptsNeedLocalApprovalAndChangedCodeNeedsNewApproval() async throws {
        let server = InMemorySyncServer(), clock = TestClock()
        let a = Device("A", server: server, clock: clock)
        let package = BoostPackage.newScript(name: "Script", hostScope: [BoostHostRule(host: "example.test")], js: "document.title = 'a'")
        let id = package.manifest.id
        XCTAssertNil(a.store.addBoost(package))
        a.store.setBoostScriptUserEnabled(packageID: id, enabled: true)
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        XCTAssertEqual(b.store.boostLibrary().package(id: id)?.scriptBoost?.userScriptEnabled, false)
        b.store.setBoostScriptUserEnabled(packageID: id, enabled: true)
        b.edited()
        b.restart()
        await b.sync()
        XCTAssertEqual(b.store.boostLibrary().package(id: id)?.scriptBoost?.userScriptEnabled, true, "approval survives restart and unchanged sync")
        XCTAssertTrue(a.store.updateBoostScript(packageID: id, css: "", js: "document.title = 'changed'").isEmpty)
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertEqual(b.store.boostLibrary().package(id: id)?.scriptBoost?.js, "document.title = 'changed'")
        XCTAssertEqual(b.store.boostLibrary().package(id: id)?.scriptBoost?.userScriptEnabled, false, "approval of the previous hash cannot authorize new code")
        b.store.setBoostScriptUserEnabled(packageID: id, enabled: true)
        await b.sync()
        XCTAssertEqual(b.store.boostLibrary().package(id: id)?.scriptBoost?.userScriptEnabled, true)
        let exported = try XCTUnwrap(b.records[SyncRecordKind.boost.recordName(for: id)]?.values["package"])
        XCTAssertEqual(try exported.decoded(as: BoostPackage.self).scriptBoost?.userScriptEnabled, false, "consent never syncs")
    }

    func testLibrariesSavedBeforeApprovalsKeepTheirEnabledScripts() throws {
        var package = BoostPackage.newScript(name: "Script", hostScope: [BoostHostRule(host: "a.test")], js: "void 0")
        package.scriptBoost?.userScriptEnabled = true
        let off = BoostPackage.newScript(name: "Off", hostScope: [BoostHostRule(host: "b.test")], js: "void 1")
        var library = ProfileBoostLibrary(profileID: UUID(), packages: [package, off], installations: [
            BoostInstallation(packageID: package.manifest.id, order: 0), BoostInstallation(packageID: off.manifest.id, order: 1),
        ])
        library.approvedScriptHashes = nil
        var legacy = try JSONDecoder().decode(ProfileBoostLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertNil(legacy.approvedScriptHashes, "older snapshots have no approvals key")
        legacy.adoptLegacyScriptApprovals()
        XCTAssertEqual(legacy.approvedScriptHashes, [package.manifest.id: BoostLibraryOps.scriptApprovalHash(package)!])
        legacy.approvedScriptHashes?[package.manifest.id] = nil
        legacy.adoptLegacyScriptApprovals()
        XCTAssertEqual(legacy.approvedScriptHashes, [:], "adopted once, never again")
    }

    func testApprovalHashIncludesCodeAndHostScope() {
        var package = BoostPackage.newScript(name: "Script", hostScope: [BoostHostRule(host: "a.test")], js: "void 0")
        let original = BoostLibraryOps.scriptApprovalHash(package)
        package.manifest.name = "Rename"
        XCTAssertEqual(original, BoostLibraryOps.scriptApprovalHash(package))
        package.manifest.hostScope = [BoostHostRule(host: "bank.test")]
        XCTAssertNotEqual(original, BoostLibraryOps.scriptApprovalHash(package))
    }
}

/// Archive Space: the archived state syncs in `SidebarSpaceArchiveRecord`,
/// alive only while the space is archived; the space record keeps its shape,
/// so a Mac that rewrites it (an older build, or any rename) never brings the
/// space back.
@MainActor
final class ArchiveSpaceSyncTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: TestClock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = TestClock()
    }

    /// Home and Work, Work with a pinned tab; both Macs in step.
    private func pair() async -> (a: Device, b: Device, work: Space.ID) {
        let a = Device("A", server: server, clock: clock)
        _ = a.store.renameSpace(a.store.spaces[0].id, to: "Home")
        let work = a.store.addSpace(name: "Work", theme: SpaceTheme.presets[2], iconName: "briefcase.fill").id
        _ = a.store.addTab(kind: .pinned, title: "Docs", url: url("docs"), in: work)
        await a.sync()
        let b = Device("B", server: server, clock: clock)
        await b.sync()
        return (a, b, work)
    }

    func testArchiveAndRestoreReachTheOtherMac() async {
        let (a, b, work) = await pair()
        XCTAssertNil(a.store.archiveSpace(work))
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertNotNil(b.store.space(withID: work)?.archivedAt)
        XCTAssertNil(b.store.listedSpace(withID: work))
        XCTAssertEqual(b.pinnedTitles("Work"), ["Docs"], "its pinned rows stay with it")
        assertSameRecords(a, b)
        let again = await a.sync()
        XCTAssertEqual(again.pushed, 0, "quiescent")

        XCTAssertNil(b.store.restoreArchivedSpace(work))
        b.edited()
        await b.sync()
        await a.sync()
        XCTAssertNotNil(a.store.listedSpace(withID: work))
        XCTAssertNil(a.records[SyncRecordKind.spaceArchive.recordName(for: work)])
        XCTAssertEqual(a.store.spacesInActiveProfile.map(\.name), ["Home", "Work"], "back in its place")
        assertSameRecords(a, b)
    }

    func testRewritingTheSpaceRecordElsewhereKeepsItArchived() async {
        let (a, b, work) = await pair()
        XCTAssertNil(a.store.archiveSpace(work))
        a.edited()
        // Meanwhile the other Mac renames it: a write to every field of the space record.
        _ = b.store.renameSpace(work, to: "Work 2")
        b.store.setSpaceIcon(work, iconName: "star.fill")
        b.edited()
        await a.sync()
        await b.sync()
        await a.sync()
        for device in [a, b] {
            XCTAssertNotNil(device.store.space(withID: work)?.archivedAt, device.name)
            XCTAssertEqual(device.store.space(withID: work)?.name, "Work 2", device.name)
        }
        XCTAssertNil(b.records[SyncRecordKind.space.recordName(for: work)]?.values["archivedAt"])
        assertSameRecords(a, b)
    }

    func testDeletingAnArchivedSpaceRemovesItEverywhere() async {
        let (a, b, work) = await pair()
        XCTAssertNil(a.store.archiveSpace(work))
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertTrue(b.store.removeSpace(work))
        b.edited()
        await b.sync()
        await a.sync()
        XCTAssertNil(a.store.space(withID: work))
        XCTAssertNil(a.records[SyncRecordKind.spaceArchive.recordName(for: work)])
        assertSameRecords(a, b)
    }
}
