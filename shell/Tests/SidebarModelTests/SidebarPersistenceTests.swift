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
