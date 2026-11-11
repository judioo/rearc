import XCTest
@testable import SidebarModel

/// What the multi-row selection and the mini sidebar add to saved files:
/// `ClosedTabRecord.batchID` in sidebar.json and `SavedBrowserWindow.sidebarMode`
/// in window-session.json. Both keys are optional: files from before them
/// load, and the files written now carry them through a save and a load.
final class SavedSelectionAndModeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func saved(_ store: SidebarStore) -> URL {
        let url = directory.appendingPathComponent("sidebar.json")
        let persistence = SidebarFilePersistence(fileURL: url)
        persistence.start(autoSave: store, onMutate: nil)
        persistence.flush()
        persistence.stop()
        return url
    }

    /// Three Today tabs, two of them closed by one selection ⌘W, one alone.
    private func storeWithAClosedBatch() -> (SidebarStore, batch: [String], single: String) {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let tabs = (1 ... 3).map { store.addTab(kind: .today, title: "Tab \($0)", url: URL(string: "https://t\($0).test")!) }
        store.closeTab(tabs[0].id)
        store.closingAsOneBatch {
            store.closeTab(tabs[1].id)
            store.closeTab(tabs[2].id)
        }
        return (store, [tabs[2].title, tabs[1].title], tabs[0].title)
    }

    func testAClosedBatchSurvivesASaveAndOneReopenStillBringsItBack() throws {
        let (store, batch, single) = storeWithAClosedBatch()
        let url = saved(store)
        let loaded = try XCTUnwrap(SidebarFilePersistence(fileURL: url).loadSnapshot())
        let ids = loaded.closedTabStack.records.map(\.batchID)
        XCTAssertNil(ids[0])
        XCTAssertNotNil(ids[1])
        XCTAssertEqual(ids[1], ids[2], "the batch keeps one id")

        let restored = SidebarStore()
        restored.applySnapshot(loaded)
        XCTAssertEqual(Set(restored.reopenMostRecentClosedBatch().map(\.title)), Set(batch))
        XCTAssertEqual(restored.reopenMostRecentClosedBatch().map(\.title), [single])
    }

    /// The previous release's sidebar.json has no `batchID` on its closed
    /// tabs: it loads whole (not quarantined), and ⇧⌘T reopens one at a time.
    func testASidebarFileFromBeforeBatchesLoadsAndReopensOneAtATime() throws {
        let (store, _, _) = storeWithAClosedBatch()
        let url = saved(store)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stack = try XCTUnwrap(json["closedTabStack"])
        json["closedTabStack"] = Self.removingKey("batchID", from: stack)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("batchID"))

        let persistence = SidebarFilePersistence(fileURL: url)
        let loaded = try XCTUnwrap(persistence.loadSnapshot())
        XCTAssertEqual(persistence.loadOutcome, .loaded)
        XCTAssertEqual(loaded.closedTabStack.records.count, 3)
        XCTAssertTrue(loaded.closedTabStack.records.allSatisfy { $0.batchID == nil })
        let restored = SidebarStore()
        restored.applySnapshot(loaded)
        XCTAssertEqual(restored.reopenMostRecentClosedBatch().count, 1, "no batch: one tab per ⇧⌘T, as before")
    }

    /// window-session.json: a mini window's mode comes back through a save
    /// and a load; a file without the key (and a full window, which writes
    /// none) restores full.
    func testTheSidebarModeRoundTripsAndAnOldWindowFileRestoresFull() throws {
        let display = SavedDisplay(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
        let windows = [
            SavedBrowserWindow(frame: CGRect(x: 10, y: 10, width: 1000, height: 800), display: display, isKey: true, sidebarMode: .mini),
            SavedBrowserWindow(frame: CGRect(x: 60, y: 60, width: 1000, height: 800), display: display),
        ]
        let data = try WindowSessionFile.encode(WindowSessionSnapshot(windows: windows))
        let decoded = try XCTUnwrap(WindowSessionFile.decode(data))
        XCTAssertEqual(decoded.windows, windows)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["windows"] = Self.removingKey("sidebarMode", from: try XCTUnwrap(json["windows"]))
        let old = try XCTUnwrap(WindowSessionFile.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(old.windows.count, 2)
        var modes = SidebarModes()
        for window in old.windows {
            XCTAssertNil(window.sidebarMode)
            let id = SidebarWindowID()
            modes.open(id, restoring: window.sidebarMode)
            XCTAssertEqual(modes.mode(in: id), .full)
        }
    }

    private static func removingKey(_ key: String, from value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { $0.key != key }.mapValues { removingKey(key, from: $0) }
        case let array as [Any]:
            return array.map { removingKey(key, from: $0) }
        default:
            return value
        }
    }
}
