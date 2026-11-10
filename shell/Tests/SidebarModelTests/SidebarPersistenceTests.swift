import XCTest
@testable import SidebarModel

final class SidebarPersistenceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func fileURL() -> URL {
        tempDirectory.appendingPathComponent("sidebar.json")
    }

    func testRoundTripSnapshotPreservesState() throws {
        let store = SidebarStore.sample()
        let persistence = SidebarFilePersistence(fileURL: fileURL(), debounceInterval: 0.01)
        persistence.start(autoSave: store)
        persistence.flush()

        let loaded = SidebarFilePersistence.loadStore(fileURL: fileURL()) {
            XCTFail("Should not fall back")
            return SidebarStore()
        }

        XCTAssertEqual(loaded.spaces.map(\.name), store.spaces.map(\.name))
        XCTAssertEqual(loaded.activeSpaceID, store.activeSpaceID)
        XCTAssertEqual(loaded.favorites.map(\.id), store.favorites.map(\.id))
        XCTAssertEqual(loaded.selectedTabID, store.selectedTabID)
        func tabTitles(in content: SidebarStore.SpaceContent) -> [String] {
            content.today.compactMap { entry in
                if case .tab(let tab) = entry { return tab.title }
                return nil
            }
        }
        XCTAssertEqual(
            tabTitles(in: loaded.content(for: loaded.activeSpaceID)),
            tabTitles(in: store.content(for: store.activeSpaceID))
        )
    }

    func testCorruptFileFallsBackToSample() throws {
        let url = fileURL()
        try Data("not json".utf8).write(to: url)
        let store = SidebarFilePersistence.loadStore(fileURL: url, fallback: SidebarStore.sample)
        XCTAssertFalse(store.spaces.isEmpty)
        XCTAssertFalse(store.favorites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileFallsBack() {
        let url = fileURL()
        let store = SidebarFilePersistence.loadStore(fileURL: url) {
            SidebarStore(spaces: [Space(name: "Fallback")])
        }
        XCTAssertEqual(store.spaces.first?.name, "Fallback")
    }

    func testAFirstRunStartsOnOneEmptySpace() {
        let persistence = SidebarFilePersistence(fileURL: fileURL())
        let store = SidebarFilePersistence.loadStore(persistence: persistence)
        XCTAssertTrue(persistence.isFirstRun)
        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertTrue(store.displayTabs().isEmpty)
        XCTAssertTrue(store.profiles.allSatisfy { store.favorites(in: $0.id).isEmpty })
        XCTAssertFalse(store.spaces.contains { $0.name == "Work" }, "no developer sample")

        let prepared = SidebarFilePersistence.prepareLoad(from: fileURL())
        let restored = SidebarFilePersistence(fileURL: fileURL()).restoreStore(from: prepared)
        XCTAssertTrue(prepared.isFirstRun)
        XCTAssertEqual(restored.spaces.count, 1)
        XCTAssertTrue(restored.displayTabs().isEmpty)
    }

    func testAStartedOnboardingKeepsTheNextLaunchAFirstRun() {
        let persistence = SidebarFilePersistence(fileURL: fileURL(), debounceInterval: 0.01)
        let store = SidebarFilePersistence.loadStore(persistence: persistence)
        persistence.beginOnboarding()
        persistence.start(autoSave: store)
        store.addTab(kind: .today, title: "A", url: URL(string: "https://a.com")!)
        persistence.flush()

        let relaunch = SidebarFilePersistence(fileURL: fileURL())
        _ = SidebarFilePersistence.loadStore(persistence: relaunch)
        XCTAssertEqual(relaunch.loadOutcome, .loaded)
        XCTAssertTrue(relaunch.isFirstRun, "a quit or crash before the end is still a first run")
        XCTAssertTrue(SidebarFilePersistence.prepareLoad(from: fileURL()).isFirstRun)

        relaunch.finishOnboarding()
        let after = SidebarFilePersistence(fileURL: fileURL())
        _ = SidebarFilePersistence.loadStore(persistence: after)
        XCTAssertFalse(after.isFirstRun)
        XCTAssertFalse(SidebarFilePersistence.prepareLoad(from: fileURL()).isFirstRun)
        persistence.stop()
    }

    func testAnExistingSidebarWithoutTheMarkerIsNoFirstRun() {
        // Installs from before the marker: a sidebar file, never onboarded again.
        let persistence = SidebarFilePersistence(fileURL: fileURL())
        persistence.start(autoSave: SidebarStore.sample())
        persistence.flush()
        let relaunch = SidebarFilePersistence(fileURL: fileURL())
        let store = SidebarFilePersistence.loadStore(persistence: relaunch)
        XCTAssertFalse(relaunch.isFirstRun)
        XCTAssertFalse(SidebarFilePersistence.prepareLoad(from: fileURL()).isFirstRun)
        XCTAssertTrue(store.spaces.contains { $0.name == "Work" }, "their sidebar is left as it is")
        persistence.stop()
    }

    func testDeferredSetupPersistsThroughBothLaunchLoadPaths() {
        let persistence = SidebarFilePersistence(fileURL: fileURL())
        let store = SidebarFilePersistence.loadStore(persistence: persistence)
        persistence.beginOnboarding()
        persistence.start(autoSave: store)
        persistence.flush()
        persistence.deferOnboarding()
        persistence.stop()

        let relaunch = SidebarFilePersistence(fileURL: fileURL())
        _ = SidebarFilePersistence.loadStore(persistence: relaunch)
        XCTAssertEqual(relaunch.onboardingSetupState, .deferred)
        XCTAssertFalse(relaunch.isFirstRun)
        XCTAssertTrue(relaunch.onboardingPending, "deferred is not completed")

        let prepared = SidebarFilePersistence.prepareLoad(from: fileURL())
        XCTAssertFalse(prepared.isFirstRun, "Chromium's early-window decision agrees")
        let restored = SidebarFilePersistence(fileURL: fileURL())
        _ = restored.restoreStore(from: prepared)
        XCTAssertEqual(restored.onboardingSetupState, .deferred)
        XCTAssertFalse(restored.isFirstRun)

        restored.dismissOnboardingCard()
        let dismissed = SidebarFilePersistence.prepareLoad(from: fileURL())
        XCTAssertEqual(dismissed.onboardingSetupState, .dismissed)
        XCTAssertFalse(dismissed.onboardingSetupState.showsCard)
        XCTAssertTrue(dismissed.onboardingSetupState.showsMenuItem)
        _ = relaunch.restoreStore(from: dismissed)
        relaunch.finishOnboarding()
        let completed = SidebarFilePersistence.prepareLoad(from: fileURL())
        XCTAssertFalse(completed.isFirstRun)
        XCTAssertFalse(completed.onboardingPending)
        XCTAssertFalse(completed.onboardingSetupState.showsCard)
        XCTAssertFalse(completed.onboardingSetupState.showsMenuItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunch.onboardingDeferredURL.path))
    }

    func testDismissingWithoutDeferralDoesNotCreateAReminder() {
        let persistence = SidebarFilePersistence(fileURL: fileURL())
        _ = SidebarFilePersistence.loadStore(persistence: persistence)
        persistence.dismissOnboardingCard()
        XCTAssertEqual(persistence.onboardingSetupState, .notDeferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.onboardingDeferredURL.path))
    }

    func testLegacyEmptyPendingMarkerStillResumesOnboarding() throws {
        let persistence = SidebarFilePersistence(fileURL: fileURL())
        persistence.start(autoSave: SidebarStore.starter())
        persistence.flush()
        persistence.stop()
        try Data().write(to: persistence.onboardingMarkerURL)
        let prepared = SidebarFilePersistence.prepareLoad(from: fileURL())
        XCTAssertTrue(prepared.isFirstRun)
        XCTAssertEqual(prepared.onboardingSetupState, .notDeferred)
    }

    func testDebounceCoalescesRapidMutations() {
        let url = fileURL()
        let store = SidebarStore(spaces: [Space(name: "One")])
        let persistence = SidebarFilePersistence(
            fileURL: url,
            debounceInterval: 0.2,
            queue: DispatchQueue.main
        )
        persistence.start(autoSave: store)

        store.addTab(kind: .today, title: "A", url: URL(string: "https://a.com")!)
        store.addTab(kind: .today, title: "B", url: URL(string: "https://b.com")!)
        store.addTab(kind: .today, title: "C", url: URL(string: "https://c.com")!)

        let beforeFlush = (try? Data(contentsOf: url)) == nil
        XCTAssertTrue(beforeFlush)

        let expectation = expectation(description: "debounced write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let loaded = SidebarFilePersistence.loadStore(fileURL: url) { SidebarStore() }
        let titles = loaded.content(for: loaded.activeSpaceID).today.compactMap { entry -> String? in
            if case .tab(let tab) = entry { return tab.title }
            return nil
        }
        XCTAssertEqual(titles, ["C", "B", "A"])
        persistence.stop()
    }
}
