import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

@MainActor
struct OnboardingSyncGatingTests {
    @Test(arguments: [false, true])
    func syncWaitsForImportCompletionOrDeferral(deferOnboarding: Bool) async {
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
        model.syncNow()
        await scheduler.runCycle()
        #expect(server.fetchCount == 0)
        #expect(server.modifyCount == 0)
        if deferOnboarding { model.deferFirstRunOnboarding() } else { model.finishFirstRunOnboarding() }
        await scheduler.runCycle()
        #expect(server.modifyCount > 0)
        #expect(server.records(account: "fixture").values.contains { $0.payload.values["title"] == .string("Imported fixture") })
        scheduler.stop()
        model.persistence.stop()
    }
}
