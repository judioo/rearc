import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

@MainActor
struct OnboardingSyncGatingTests {
    private func settle(_ until: () -> Bool) async {
        for _ in 0 ..< 200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Finished, deferred or skipped, onboarding never turns sync on; the
    /// switch does, and with nothing in iCloud it just starts.
    @Test(arguments: [false, true])
    func syncStaysOffAfterOnboardingUntilSwitchedOn(deferOnboarding: Bool) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = InMemorySyncServer()
        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "fixture"), stateStore: InMemorySyncStateStore(), deviceID: "A")
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        scheduler.sleeper = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        let model = BrowserViewModel(persistence: SidebarFilePersistence(fileURL: folder.appendingPathComponent("sidebar.json")), syncEngine: scheduler, faviconStore: FaviconStore(directory: nil))
        #expect(model.isFirstRun)
        model.beginFirstRunOnboarding()
        _ = model.store.addTab(kind: .pinned, title: "Imported fixture", url: URL(string: "https://fixture.invalid")!)
        if deferOnboarding { model.deferFirstRunOnboarding() } else { model.finishFirstRunOnboarding() }
        model.syncNow()
        await scheduler.runCycle()
        #expect(!model.isSyncEnabled)
        #expect(server.fetchCount == 0 && server.modifyCount == 0 && server.readCount == 0)

        model.setSyncEnabled(true)
        await settle { model.isSyncEnabled }
        #expect(model.syncCloudChoice == nil, "an empty iCloud asks nothing")
        let imported = { server.records(account: "fixture").values.contains { $0.payload.values["title"] == .string("Imported fixture") } }
        await settle { model.syncDetails?.phase == .upToDate && imported() }
        #expect(server.modifyCount > 0)
        #expect(server.records(account: "fixture").values.contains { $0.payload.values["title"] == .string("Imported fixture") })
        scheduler.stop()
        model.persistence.stop()
    }

    /// iCloud holds a sidebar: switching on asks first, and Cancel leaves
    /// both this Mac and iCloud exactly as they were.
    @Test func switchingOnAgainstAFullICloudAsksAndCancelChangesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = InMemorySyncServer()
        // Another Mac's sidebar is in iCloud.
        let other = SidebarStore()
        _ = other.addTab(kind: .pinned, title: "From the other Mac", url: URL(string: "https://other.invalid")!)
        var on = SidebarSyncState(); on.enabled = true; on.decision = .user
        let otherMac = SidebarSyncCoordinator(transport: server.transport(account: "fixture"), stateStore: InMemorySyncStateStore(on), deviceID: "B")
        otherMac.host = other
        await otherMac.sync()
        let before = server.records(account: "fixture")
        let writes = (server.modifyCount, server.zoneCreations)

        let coordinator = SidebarSyncCoordinator(transport: server.transport(account: "fixture"), stateStore: InMemorySyncStateStore(), deviceID: "A")
        let scheduler = SidebarSyncScheduler(coordinator: coordinator)
        scheduler.sleeper = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        let model = BrowserViewModel(persistence: SidebarFilePersistence(fileURL: folder.appendingPathComponent("sidebar.json")), syncEngine: scheduler, faviconStore: FaviconStore(directory: nil))
        model.finishFirstRunOnboarding()
        _ = model.store.addTab(kind: .pinned, title: "Just imported", url: URL(string: "https://mine.invalid")!)
        let mine = model.store.makeSnapshot()

        model.setSyncEnabled(true)
        await settle { model.syncCloudChoice != nil }
        let found = try #require(model.syncCloudChoice)
        #expect(found.summary.pinnedTabs == 1)
        #expect(!model.isSyncEnabled)
        model.syncCloudChoice = nil // Cancel
        await scheduler.runCycle()
        #expect(!model.isSyncEnabled)
        #expect(model.store.makeSnapshot() == mine)
        #expect(server.records(account: "fixture") == before)
        #expect(server.modifyCount == writes.0 && server.zoneCreations == writes.1, "only reads reached iCloud")
        #expect(server.readCount == 1)
        scheduler.stop()
        model.persistence.stop()
    }
}
