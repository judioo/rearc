import XCTest
@testable import SidebarModel

/// RC-0.1.0-602 T-01 (no sync without a choice), T-02 (a first join never
/// lets a joining Mac's stale rows beat newer iCloud ones or bring back
/// deleted ones) and T-03 (no crafted record can crash a sync).

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class Mac {
    let name: String
    let store: SidebarStore
    let coordinator: SidebarSyncCoordinator
    let clock: Clock

    init(_ name: String, server: InMemorySyncServer, clock: Clock, state: SidebarSyncState? = nil, store: SidebarStore = SidebarStore()) {
        self.name = name
        self.clock = clock
        self.store = store
        store.now = { [clock] in clock.date }
        coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(state ?? SidebarSyncState()),
                                             deviceID: name, now: { [clock] in clock.date })
        coordinator.host = store
    }

    @discardableResult
    func sync() async -> SyncCycleOutcome {
        clock.advance()
        let outcome = await coordinator.sync()
        clock.advance()
        return outcome
    }

    func edited() { coordinator.captureLocalChanges() }

    func tab(_ title: String) -> Tab? {
        for space in store.spaces {
            for case .tab(let tab) in SidebarTree.leaves(store.content(for: space.id).pinned) where tab.displayTitle == title { return tab }
        }
        return store.profiles.flatMap { store.favorites(in: $0.id) }.first { $0.displayTitle == title }
    }

    var records: [String: SyncRecordBody] { SidebarSyncProjection.extract(store.makeSnapshot()) }
}

private func arcSource() throws -> ArcSidebarImport {
    let export = try ArcSidebarReader.parse(JSONSerialization.data(withJSONObject: BrowserImportFixture.arcSidebar()))
    return ArcSidebarImport(export: export, profileNames: ["Default": "Home", "Profile 1": "Studio"])
}

/// Sync Sidebar is off unless the person turned it on (replaces T-01's
/// one-time prompt): no build's own default keeps it on.
@MainActor
final class SyncOffByDefaultTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-decision-\(UUID())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ json: String? = nil) throws -> SidebarSyncStateFile {
        let url = folder.appendingPathComponent(SidebarSyncStateFile.fileName)
        if let json { try Data(json.utf8).write(to: url) }
        return SidebarSyncStateFile(fileURL: url)
    }

    private let record = #""records":{"profile_00000000-0000-0000-0000-000000000001":{"payload":{"kind":"SidebarProfileRecord","fields":{}},"pending":false}}"#

    func testNoFileIsOff() throws {
        let state = try file().load()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.decision)
    }

    func testOnByABuildsOwnDefaultGoesOffAndForgetsWhatItMerged() throws {
        // 602: on, joined, records, no decision.
        var state = try file(#"{"version":1,"enabled":true,"zoneReady":true,"joined":true,"accountID":"a",\#(record)}"#).load()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.decision)
        XCTAssertFalse(state.joined, "turning it on again is a first join, which looks at iCloud first")
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertNil(state.accountID)
        // 605 and 608: on as a new install's default.
        state = try file(#"{"version":1,"enabled":true,"decision":"newInstall","zoneReady":true,"joined":true,"accountID":"a",\#(record)}"#).load()
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.records.isEmpty)
        // 605 and 608 in a REARC_DATA_DIR launch.
        state = try file(#"{"version":1,"enabled":false,"decision":"isolated","zoneReady":false,"joined":false,\#(record)}"#).load()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.decision)
    }

    func testTheirOwnOnStaysOn() throws {
        // Settings' switch, or 605/608's "Turn On": the person chose it.
        let state = try file(#"{"version":1,"enabled":true,"decision":"user","zoneReady":true,"joined":true,\#(record)}"#).load()
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.joined)
        XCTAssertEqual(state.records.count, 1)
        let off = try file(#"{"version":1,"enabled":false,"decision":"user","zoneReady":true,"joined":true,\#(record)}"#).load()
        XCTAssertFalse(off.isActive)
        XCTAssertEqual(off.records.count, 1, "their own off keeps what it synced")
    }

    func testAFileThatDoesNotDecodeIsOff() throws {
        for json in [#"{"version":1,"enabled":true,"decision":"user","records":7}"#, #"{"version":1,"enabled":true,"records":"garbage"}"#,
                     "not json", #"{"version":1,"enabled":true,"decision":"someday"}"#] {
            let state = try file(json).load()
            XCTAssertFalse(state.isActive, json)
            XCTAssertTrue(state.records.isEmpty, json)
        }
    }

    func testOffSyncsNothingUntilSwitchedOn() async throws {
        let server = InMemorySyncServer()
        let stateFile = try file()
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "a"), stateStore: stateFile, deviceID: "A")
        let store = SidebarStore()
        _ = store.addTab(kind: .pinned, title: "Private", url: URL(string: "https://private.test")!)
        coordinator.host = store
        let outcome = await coordinator.sync()
        XCTAssertTrue(outcome.skipped)
        XCTAssertEqual(server.fetchCount, 0)
        XCTAssertFalse(server.hasZone(account: "a"))

        coordinator.setEnabled(true)
        XCTAssertTrue(stateFile.load().isActive)
        let turnedOn = await coordinator.sync()
        XCTAssertFalse(turnedOn.skipped)
        XCTAssertFalse(server.records(account: "a").isEmpty)
    }

    func testAStateHandedInIsNormalizedToo() {
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .newInstall
        let coordinator = SidebarSyncCoordinator(transport: InMemorySyncServer().transport(account: "a"), stateStore: InMemorySyncStateStore(), deviceID: "A",
                                                 initialState: state)
        XCTAssertFalse(coordinator.isEnabled)
    }

    func testSchedulerStaysIdleUntilSwitchedOn() async {
        let server = InMemorySyncServer()
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "a"), stateStore: InMemorySyncStateStore(), deviceID: "A")
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        let host = SidebarStore()
        scheduler.attach(host: host)
        scheduler.sleeper = { delay in
            if delay >= SidebarSyncScheduler.pollInterval { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        }
        scheduler.start()
        await scheduler.runCycle()
        XCTAssertEqual(server.fetchCount, 0)
        scheduler.setUserEnabled(true)
        await scheduler.runCycle()
        XCTAssertGreaterThan(server.fetchCount, 0)
        scheduler.stop()
    }
}

@MainActor
final class SyncFirstJoinTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: Clock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = Clock()
    }

    private func on() -> SidebarSyncState {
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        return state
    }

    private func arcMac(_ name: String) throws -> Mac {
        let store = SidebarStore()
        let source = try arcSource()
        store.importArcSidebar(source, choices: source.defaultChoices(for: store))
        return Mac(name, server: server, clock: clock, state: on(), store: store)
    }

    /// Mac A imported from Arc and was tidied since; Mac B imports the same
    /// Arc data much later and joins. B's copy is stale: A's edits stay.
    func testAJoiningMacThatImportedTheSameArcDataNeverRevertsOrResurrects() async throws {
        let a = try arcMac("A")
        await a.sync()

        let handbook = try XCTUnwrap(a.tab("Handbook"))
        _ = a.store.renameTab(handbook.id, to: "Team handbook")
        // A row of its own (not a split's member), inside a folder.
        func rows(_ entries: [SidebarEntry]) -> [Tab] {
            entries.flatMap { entry -> [Tab] in
                switch entry {
                case .tab(let tab): return [tab]
                case .folder(let folder): return rows(folder.children)
                default: return []
                }
            }
        }
        let deleted = try XCTUnwrap(a.store.spaces.flatMap { space in
            a.store.content(for: space.id).pinned.compactMap { entry -> SidebarFolder? in if case .folder(let folder) = entry { return folder } else { return nil } }
        }.flatMap { rows($0.children) }.first)
        a.store.closeTab(deleted.id)
        a.edited()
        await a.sync()
        XCTAssertNil(a.store.tab(withID: deleted.id))

        // Within the 30 days a tombstone stays on the server (SYNC-DESIGN §5.4).
        clock.advance(10 * 24 * 3600)
        let b = try arcMac("B")
        XCTAssertNotNil(b.store.tab(withID: deleted.id), "B's own import still has the row A deleted")
        XCTAssertEqual(b.store.tab(withID: handbook.id)?.displayTitle, "Handbook")
        let mine = b.store.addTab(kind: .pinned, title: "Only on B", url: URL(string: "https://only-b.test")!, in: b.store.spaces[0].id)
        await b.sync()
        await a.sync()
        await b.sync()

        for mac in [a, b] {
            XCTAssertEqual(mac.store.tab(withID: handbook.id)?.displayTitle, "Team handbook", "\(mac.name) keeps A's later rename")
            XCTAssertNil(mac.store.tab(withID: deleted.id), "\(mac.name): the row A deleted stays deleted")
            XCTAssertNotNil(mac.store.tab(withID: mine.id), "\(mac.name): B's own new row is merged in")
        }
        let record = server.records(account: "alice")[SyncRecordKind.item.recordName(for: deleted.id)]
        XCTAssertEqual(record?.payload.isAlive, false)
        XCTAssertEqual(Set(a.records.keys), Set(b.records.keys))
    }

    /// After the join, B is an ordinary member: its own later edits win.
    func testEditsAfterTheJoinStillWin() async throws {
        let a = try arcMac("A")
        await a.sync()
        let b = try arcMac("B")
        await b.sync()
        let handbook = try XCTUnwrap(b.tab("Handbook"))
        _ = b.store.renameTab(handbook.id, to: "B's handbook")
        b.edited()
        await b.sync()
        await a.sync()
        XCTAssertEqual(a.store.tab(withID: handbook.id)?.displayTitle, "B's handbook")
    }
}

@MainActor
final class SyncHostileRecordTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: Clock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = Clock()
    }

    private func on() -> SidebarSyncState {
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        return state
    }

    /// An attacker with the Apple Account writes records straight to the zone.
    private func plant(_ name: String, _ payload: SyncRecordPayload) async throws {
        let attacker = server.transport(account: "alice")
        try await attacker.prepareZone()
        _ = try await attacker.modify(saving: [SyncWireRecord(recordName: name, payload: payload)], deleting: [])
    }

    private func field(_ value: SyncValue, millis: Int64 = 1_800_000_000_000, counter: UInt32 = 0) -> SyncField {
        SyncField(value: value, stamp: SyncStamp(millis: millis, counter: counter, device: "evil"))
    }

    func testClockAtItsLimitNeverTraps() {
        var clock = HybridLogicalClock(device: "A", last: SyncStamp(millis: 5, counter: .max, device: "B"))
        let next = clock.tick(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(next.millis, 6)
        XCTAssertEqual(next.counter, 0)
        var end = HybridLogicalClock(device: "A", last: SyncStamp(millis: .max, counter: .max, device: "B"))
        _ = end.tick(now: Date())
        _ = end.tick(now: Date(timeIntervalSince1970: .infinity))
        _ = end.tick(now: Date(timeIntervalSince1970: .nan))
    }

    func testASaturatedStampIsQuarantinedAndLaterEditsStillSync() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let name = SyncRecordKind.item.recordName(for: UUID())
        let tab: [String: SyncField] = [
            "type": field(.string("tab"), millis: .max, counter: .max),
            "parent": field(.string("pinned:\(a.store.spaces[0].id.uuidString.lowercased())"), millis: .max, counter: .max),
            "url": field(.string("https://evil.test"), millis: .max, counter: .max),
        ]
        try await plant(name, SyncRecordPayload(kind: .item, fields: tab))
        let outcome = await a.sync()
        XCTAssertNil(outcome.error)
        XCTAssertNil(a.coordinator.state.records[name], "never merged")
        XCTAssertTrue(a.coordinator.quarantinedRecordNames.contains(name))
        XCTAssertLessThan(a.coordinator.state.clock?.millis ?? 0, Int64.max)
        _ = a.store.addTab(kind: .pinned, title: "After", url: URL(string: "https://after.test")!, in: a.store.spaces[0].id)
        a.edited()
        let synced = await a.sync()
        XCTAssertNil(synced.error)
        XCTAssertEqual(a.coordinator.state.pendingCount, 0)
    }

    func testAFarFutureStampIsQuarantinedButSmallSkewIsNot() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let now = Int64(clock.date.timeIntervalSince1970 * 1000)
        let space = a.store.spaces[0].id.uuidString.lowercased()
        func tab(_ url: String, millis: Int64) -> SyncRecordPayload {
            SyncRecordPayload(kind: .item, fields: [
                "type": field(.string("tab"), millis: millis), "parent": field(.string("pinned:\(space)"), millis: millis),
                "url": field(.string(url), millis: millis), "title": field(.string(url), millis: millis),
            ])
        }
        let future = SyncRecordKind.item.recordName(for: UUID()), skewed = SyncRecordKind.item.recordName(for: UUID())
        try await plant(future, tab("https://future.test", millis: now + 400 * 24 * 3600 * 1000))
        try await plant(skewed, tab("https://skewed.test", millis: now + 60 * 1000))
        await a.sync()
        XCTAssertNil(a.coordinator.state.records[future])
        XCTAssertNotNil(a.coordinator.state.records[skewed], "a peer a minute ahead is normal")
    }

    func testAStateFileAlreadySaturatedRecoversAtLaunch() {
        var state = on()
        let name = SyncRecordKind.profile.recordName(for: UUID())
        state.records[name] = SyncShadowRecord(payload: SyncRecordPayload(kind: .profile, fields: ["name": field(.string("x"), millis: .max, counter: .max)]))
        state.clock = SyncStamp(millis: .max, counter: .max, device: "A")
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(state), deviceID: "A", now: { [clock] in clock!.date })
        XCTAssertNil(coordinator.state.records[name])
        XCTAssertNil(coordinator.state.clock)
        var reset = state
        reset.resetServerState()
        XCTAssertNil(reset.clock, "Reset iCloud state drops the clock with the records")
    }

    func testHugeOrderAndNonFiniteNumbersNeverTrap() {
        for order in [1e300, -1e300, Double(Int.max), .infinity, -.infinity, .nan] {
            let value = SyncValue.object(["packageID": .string(UUID().uuidString), "order": .number(order)])
            XCTAssertNotNil(SidebarSyncProjection.installation(from: value))
        }
        XCTAssertEqual(SidebarSyncProjection.clampedInt(1e300), Int.max)
        XCTAssertEqual(SidebarSyncProjection.clampedInt(.nan), 0)
    }

    func testDuplicateTabsInASplitAndTwoInstallationsForOnePackageNeverTrap() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let space = a.store.spaces[0].id.uuidString.lowercased()
        let tabID = UUID()
        let member: SyncValue = .object(["id": .string(tabID.uuidString), "kind": .string("pinned"), "title": .string("t"), "url": .string("https://t.test")])
        try await plant(SyncRecordKind.item.recordName(for: UUID()), SyncRecordPayload(kind: .item, fields: [
            "type": field(.string("split")), "parent": field(.string("pinned:\(space)")), "orientation": field(.string("horizontal")),
            "tabs": field(.array([member, member])),
        ]))
        // A second split claiming a tab that is also a row of its own.
        let row = SyncRecordKind.item.recordName(for: tabID)
        try await plant(row, SyncRecordPayload(kind: .item, fields: [
            "type": field(.string("tab")), "parent": field(.string("pinned:\(space)")), "url": field(.string("https://t.test")),
        ]))
        let other = SyncValue.object(["id": .string(UUID().uuidString), "kind": .string("pinned"), "title": .string("u"), "url": .string("https://u.test")])
        try await plant(SyncRecordKind.item.recordName(for: UUID()), SyncRecordPayload(kind: .item, fields: [
            "type": field(.string("split")), "parent": field(.string("pinned:\(space)")), "orientation": field(.string("horizontal")),
            "tabs": field(.array([member, other])),
        ]))
        let package = BoostPackage.newStyle(name: "x", hostScope: [], css: "a{}")
        let profile = a.store.profiles[0].id.uuidString
        for _ in 0 ..< 2 {
            var spoofed = package
            spoofed.manifest.id = UUID()
            try await plant(SyncRecordKind.boost.recordName(for: spoofed.manifest.id), SyncRecordPayload(kind: .boost, fields: [
                "profileID": field(.string(profile)), "package": field(try SyncValue.encoding(spoofed)),
                "installation": field(.object(["packageID": .string(package.manifest.id.uuidString), "order": .number(1e300)])),
            ]))
        }
        let synced = await a.sync()
        XCTAssertNil(synced.error)
        XCTAssertEqual(a.store.makeSnapshot().splitsByID.count, 0)
        XCTAssertNotNil(a.store.tab(withID: tabID))
        let library = try XCTUnwrap(a.store.boostLibrariesByProfileID[a.store.profiles[0].id])
        XCTAssertEqual(BoostLibraryListing.rows(library).count, 2)
    }

    func testAVeryLongFolderChainBuildsWithoutDeepRecursion() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let space = a.store.spaces[0].id.uuidString.lowercased()
        var parent = "pinned:\(space)"
        var wires: [SyncWireRecord] = []
        for index in 0 ..< 3000 {
            let id = UUID()
            wires.append(SyncWireRecord(recordName: SyncRecordKind.item.recordName(for: id), payload: SyncRecordPayload(kind: .item, fields: [
                "type": field(.string("folder")), "parent": field(.string(parent)), "title": field(.string("f\(index)")),
                "sortRank": field(.string(String(repeating: "0", count: 20_000))),
            ])))
            parent = "folder:\(id.uuidString.lowercased())"
        }
        let attacker = server.transport(account: "alice")
        _ = try await attacker.modify(saving: wires, deleting: [])
        let synced = await a.sync()
        XCTAssertNil(synced.error)
        func depth(_ entries: [SidebarEntry]) -> Int {
            var deepest = 0, level = entries
            while !level.isEmpty {
                deepest += 1
                level = level.flatMap { if case .folder(let folder) = $0 { return folder.children } else { return [] } }
            }
            return deepest
        }
        XCTAssertLessThanOrEqual(depth(a.store.content(for: a.store.spaces[0].id).pinned), SidebarSyncProjection.maxFolderDepth + 1)
        XCTAssertEqual(SidebarTree.folders(a.store.content(for: a.store.spaces[0].id).pinned).count, 3000)
    }

    func testRanksFromSyncNeverTrap() {
        XCTAssertNotNil(SyncRanks.between(nil, String(repeating: "0", count: 100_000) + "1"))
        XCTAssertNil(SyncRanks.between("", String(repeating: "0", count: 100_000)))
        XCTAssertFalse(LexoRank.between("b", "a").isEmpty)
        XCTAssertFalse(LexoRank.between("a", "a").isEmpty)
    }

    func testKindThatDisagreesWithTheRecordNameIsQuarantined() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let name = SyncRecordKind.space.recordName(for: UUID())
        try await plant(name, SyncRecordPayload(kind: .item, fields: ["type": field(.string("tab"))]))
        await a.sync()
        XCTAssertNil(a.coordinator.state.records[name])
    }

    func testDeeplyNestedJSONIsRefusedNotACrash() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertThrowsError(try SyncCoding.decoder.decode(SyncValue.self, from: Data(deep.utf8)))
        let payload = #"{"kind":"SidebarItemRecord","fields":{"x":{"value":"# + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000)
            + #","stamp":{"millis":1,"counter":0,"device":"e"}}}}"#
        XCTAssertThrowsError(try SyncRecordPayload.decode(Data(payload.utf8)))
    }
}

/// RC-0.1.0-602 T-05 (no live address uploads) and T-07 (only web pages become synced tabs).
@MainActor
final class SyncAddressTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: Clock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = Clock()
    }

    private func on() -> SidebarSyncState {
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        return state
    }

    func testNavigationInAPinnedTabOrFavoriteNeverUploadsTheLiveAddress() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        let pinned = a.store.addTab(kind: .pinned, title: "Docs", url: URL(string: "https://docs.test/start")!, in: a.store.spaces[0].id)
        let favorite = a.store.addTab(kind: .favorite, title: "Mail", url: URL(string: "https://mail.test/inbox")!)
        await a.sync()
        a.store.updateTab(pinned.id, title: "Secret doc 42", url: URL(string: "https://docs.test/d/42?code=SIGNIN#access_token=abc")!)
        a.store.updateTab(favorite.id, title: "Inbox (3) – kai@example.test", url: URL(string: "https://mail.test/inbox#token=xyz")!)
        a.edited()
        await a.sync()
        let records = server.records(account: "alice")
        let pinnedValues = try XCTUnwrap(records[SyncRecordKind.item.recordName(for: pinned.id)]?.payload.values)
        XCTAssertEqual(pinnedValues["url"], .string("https://docs.test/start"), "the pinned URL, not where it went")
        XCTAssertEqual(pinnedValues["title"], .string("Docs"))
        let favoriteValues = try XCTUnwrap(records[SyncRecordKind.item.recordName(for: favorite.id)]?.payload.values)
        XCTAssertEqual(favoriteValues["url"], .string("https://mail.test/inbox"), "no fragment")
        XCTAssertEqual(favoriteValues["title"], .string("mail.test"), "no page title")
        let text = records.values.map { String(describing: $0.payload.values) }.joined()
        XCTAssertFalse(text.contains("SIGNIN") || text.contains("access_token") || text.contains("kai@example.test"))
        // A's own tabs keep their live pages through its own syncs.
        XCTAssertEqual(a.store.tab(withID: pinned.id)?.url.absoluteString, "https://docs.test/d/42?code=SIGNIN#access_token=abc")
        XCTAssertEqual(a.store.tab(withID: favorite.id)?.title, "Inbox (3) – kai@example.test")
    }

    func testOnlyWebPagesBecomeSyncedTabs() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        await a.sync()
        let attacker = server.transport(account: "alice")
        let profile = a.store.profiles[0].id.uuidString.lowercased()
        let stamp = SyncStamp(millis: Int64(clock.date.timeIntervalSince1970 * 1000), device: "evil")
        var planted: [UUID: String] = [:]
        for url in ["data:text/html,<h1>Bank</h1>", "file:///etc/passwd", "chrome://settings", "javascript:alert(1)",
                    "https://user:pw@bank.test/", "https://bank.test/login"] {
            let id = UUID()
            planted[id] = url
            let fields: [String: SyncField] = [
                "type": SyncField(value: .string("tab"), stamp: stamp), "parent": SyncField(value: .string("favorites:\(profile)"), stamp: stamp),
                "url": SyncField(value: .string(url), stamp: stamp), "title": SyncField(value: .string("My Bank"), stamp: stamp),
                "space": SyncField(value: .null, stamp: stamp),
            ]
            _ = try await attacker.modify(saving: [SyncWireRecord(recordName: SyncRecordKind.item.recordName(for: id), payload: SyncRecordPayload(kind: .item, fields: fields))], deleting: [])
        }
        await a.sync()
        let shown = Set(a.store.favorites(in: a.store.profiles[0].id).map(\.id))
        for (id, url) in planted {
            XCTAssertEqual(shown.contains(id), url == "https://bank.test/login", url)
        }
    }
}

/// RC-0.1.0-602 T-10.
@MainActor
final class SyncSmallGapTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var clock: Clock!

    override func setUp() async throws {
        server = InMemorySyncServer()
        clock = Clock()
    }

    private func on() -> SidebarSyncState {
        var state = SidebarSyncState()
        state.enabled = true
        state.decision = .user
        return state
    }

    func testARemoteSpaceDeleteKeepsTodayTabsInTheirOwnContainer() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        let home = a.store.spaces[0]
        let sibling = a.store.addSpace(name: "Sibling", iconName: "star.fill", profileID: home.profileID)
        let work = a.store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(a.store.spaces(in: work.id).first)
        let lone = a.store.addSpace(name: "Lone", iconName: "moon.fill", profileID: work.id)
        await a.sync()
        let b = Mac("B", server: server, clock: clock, state: on())
        await b.sync()
        let homeToday = b.store.addTab(kind: .today, title: "Home scratch", url: URL(string: "https://home.test")!, in: home.id)
        let loneToday = b.store.addTab(kind: .today, title: "Work scratch", url: URL(string: "https://work.test")!, in: lone.id)
        b.edited()
        await b.sync()

        // A deletes Home (its container keeps Sibling) and the whole Work container.
        XCTAssertTrue(a.store.removeSpace(home.id))
        XCTAssertNil(a.store.deleteProfile(work.id, deletingSpaces: true))
        XCTAssertTrue(a.store.spaces.allSatisfy { $0.id != lone.id && $0.id != workSpace.id })
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertTrue(b.store.content(for: sibling.id).today.contains { $0.id == homeToday.id }, "same container's space")
        for space in b.store.spaces where space.profileID != work.id {
            XCTAssertFalse(b.store.content(for: space.id).today.contains { $0.id == loneToday.id }, "never into another container")
        }
        XCTAssertTrue(b.store.makeSnapshot().archivedTabs.contains { $0.id == loneToday.id }, "archived when its container has no space")
    }

    func testImportBookkeepingEncodesInAStableOrder() throws {
        let store = SidebarStore()
        let ids = (0 ..< 20).map { _ in UUID() }
        let index = try XCTUnwrap(store.spaces.indices.first)
        store.spaces[index].arcImportedItemIDs = Set(ids)
        store.spaces[index].arcItemMapping = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
        let body = try XCTUnwrap(SidebarSyncProjection.extract(store.makeSnapshot())[SyncRecordKind.space.recordName(for: store.spaces[index].id)])
        guard case .array(let imported)? = body.values["arcImportedItemIDs"], case .array(let mapping)? = body.values["arcItemMapping"] else {
            return XCTFail("missing")
        }
        let importedText = imported.compactMap(\.stringValue)
        XCTAssertEqual(importedText, importedText.sorted())
        let keys = stride(from: 0, to: mapping.count, by: 2).compactMap { mapping[$0].stringValue }
        XCTAssertEqual(keys, keys.sorted())
        // And it still reads back.
        let applied = SidebarSyncProjection.apply([SyncRecordKind.space.recordName(for: store.spaces[index].id):
            SyncRecordPayload(kind: .space, fields: body.values.mapValues { SyncField(value: $0, stamp: SyncStamp(millis: 1, device: "A")) })], onto: SidebarStore().makeSnapshot())
        XCTAssertEqual(applied.spaces.first?.arcItemMapping, store.spaces[index].arcItemMapping)
    }

    func testAPullKeepsNoMoreThanTheRecordLimit() async throws {
        let a = Mac("A", server: server, clock: clock, state: on())
        a.coordinator.recordLimit = 40
        await a.sync()
        let stamp = SyncStamp(millis: Int64(clock.date.timeIntervalSince1970 * 1000), device: "evil")
        let flood = (0 ..< 200).map { _ in
            SyncWireRecord(recordName: SyncRecordKind.item.recordName(for: UUID()), payload: SyncRecordPayload(kind: .item, fields: ["type": SyncField(value: .string("folder"), stamp: stamp)]))
        }
        _ = try await server.transport(account: "alice").modify(saving: flood, deleting: [])
        let outcome = await a.sync()
        XCTAssertNil(outcome.error)
        XCTAssertLessThanOrEqual(a.coordinator.state.records.count, 40)
        XCTAssertFalse(a.coordinator.quarantinedRecordNames.isEmpty)
    }
}
