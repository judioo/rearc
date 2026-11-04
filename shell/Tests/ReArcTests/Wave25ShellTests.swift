import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 25: the shell's iCloud sync wiring. `swift test` is never entitled,
/// so the default engine must be the inert one and Settings must say so.
@MainActor
final class Wave25ShellTests: XCTestCase {
    private func makeModel(syncEngine: SyncEngine?) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w25-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: syncEngine,
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w25-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w25-links-\(UUID().uuidString)")!
        return model
    }

    func testUnentitledBuildLaunchesWithInertSync() {
        let model = makeModel(syncEngine: nil)
        XCTAssertTrue(model.syncEngine is UnavailableSyncEngine)
        XCTAssertNil(model.syncControl)
        XCTAssertNil(model.syncDetails)
        XCTAssertEqual(model.syncUnavailableReason?.hasPrefix("iCloud sync unavailable in this build"), true)
        XCTAssertFalse(model.isSyncEnabled)
        model.setSyncEnabled(true)
        model.syncNow()
        XCTAssertFalse(model.isSyncEnabled, "the toggle cannot turn on an unentitled build")
        XCTAssertEqual(SyncStatusPresentation(model.syncStatus).indicator, .grey)
    }

    func testEntitledEngineDrivesTheStoreAndSettings() async {
        let server = InMemorySyncServer()
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(), deviceID: "A")
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        scheduler.sleeper = { delay in
            if delay >= SidebarSyncScheduler.pollInterval { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        }
        let model = makeModel(syncEngine: scheduler)
        XCTAssertNil(model.syncUnavailableReason)
        XCTAssertNotNil(model.syncControl)
        XCTAssertEqual(model.syncDetails?.phase, .off)
        _ = model.store.addTab(kind: .pinned, title: "Synced", url: URL(string: "https://synced.test")!)

        model.setSyncEnabled(true)
        await scheduler.runCycle()
        XCTAssertTrue(model.isSyncEnabled)
        XCTAssertEqual(model.syncDetails?.phase, .upToDate)
        XCTAssertEqual(model.syncStatus, .idleSynced)
        XCTAssertTrue(server.records(account: "alice").values.contains { $0.payload.values["title"] == .string("Synced") })
        model.setSyncEnabled(false)
        XCTAssertEqual(model.syncDetails?.phase, .off)
        scheduler.stop()
    }
}
