import Foundation
import Observation
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Downloads at scale (docs/PERF-BASELINE.md): Chromium replays its whole
/// download history into the controller at launch, one event per item.
final class DownloadsReplayTests: XCTestCase {
    private func event(_ kind: DownloadEvent.Kind, _ guid: String, state: DownloadState, received: Int64 = 100) -> DownloadEvent {
        DownloadEvent(kind: kind, guid: guid, url: "https://files.test/\(guid).zip", targetPath: "/tmp/\(guid).zip",
                      receivedBytes: received, totalBytes: 100, state: state)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("downloads-replay-\(UUID().uuidString)/Downloads.json")
    }

    func testReplayedHistoryArmsOneSave() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let controller = DownloadsController(fileURL: file)
        controller.apply(event(.created, "h0", state: .complete), source: .chromium)
        let first = try XCTUnwrap(controller.saveDeadline)
        for index in 1 ..< 2_000 { controller.apply(event(.created, "h\(index)", state: .complete), source: .chromium) }
        XCTAssertEqual(controller.saveDeadline, first, "every replayed row rides on the first save")
        XCTAssertEqual(controller.records.count, 2_000)

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(controller.saveDeadline)
        let saved = DownloadListFile.load(from: file)
        XCTAssertEqual(saved.list.records.count, DownloadList.defaultLimit, "the file keeps the newest rows, as before")
    }

    func testAStateChangeBringsAProgressSaveForward() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let controller = DownloadsController(fileURL: file)
        controller.apply(event(.created, "a", state: .inProgress, received: 0), source: .chromium)
        controller.save()
        controller.apply(event(.updated, "a", state: .inProgress, received: 10), source: .chromium)
        let progress = try XCTUnwrap(controller.saveDeadline)
        controller.apply(event(.updated, "a", state: .inProgress, received: 20), source: .chromium)
        XCTAssertEqual(controller.saveDeadline, progress, "more progress waits for the same save")
        controller.apply(event(.completed, "a", state: .complete), source: .chromium)
        let finished = try XCTUnwrap(controller.saveDeadline)
        XCTAssertLessThan(finished, progress, "completion saves within 50 ms, not 2 s")

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(controller.saveDeadline)
        XCTAssertEqual(DownloadListFile.load(from: file).list.record(withID: "a")?.state, .complete)
    }

    func testFinishedRowsWithoutAWarningLeaveTheWarningsAlone() {
        let controller = DownloadsController(fileURL: nil)
        controller.apply(event(.created, "warned", state: .inProgress, received: 0), source: .chromium)
        let warning = DownloadWarning(dangerType: 1, insecureStatus: 0, isDangerous: true, isInsecure: false)
        controller.updateWarning(warning, for: "warned")

        var changed = false
        withObservationTracking { _ = controller.warnings } onChange: { changed = true }
        for index in 0 ..< 500 { controller.apply(event(.created, "h\(index)", state: .complete), source: .chromium) }
        XCTAssertFalse(changed, "a replayed row with no warning does not touch the observed map")
        XCTAssertEqual(controller.warnings["warned"], warning)

        controller.apply(event(.completed, "warned", state: .complete), source: .chromium)
        XCTAssertTrue(changed)
        XCTAssertNil(controller.warnings["warned"], "a finished row still drops its warning")
    }

    func testClearRemovesEachEnginesRowsInOneBatch() {
        final class Backend: DownloadBackend {
            var batches: [[String]] = []
            var single = 0
            func perform(_ action: DownloadAction, id: String) -> Bool { single += 1; return true }
            func directoryChanged(_ directory: URL) {}
            func removeFinished(_ ids: [String]) { batches.append(ids) }
        }
        let backend = Backend()
        let controller = DownloadsController(fileURL: nil)
        controller.chromium = backend
        for index in 0 ..< 3_000 { controller.apply(event(.created, "h\(index)", state: .complete), source: .chromium) }
        controller.apply(event(.created, "live", state: .inProgress, received: 0), source: .chromium)
        controller.clearFinished()
        XCTAssertEqual(backend.batches.count, 1)
        XCTAssertEqual(backend.batches.first?.count, 3_000)
        XCTAssertEqual(backend.single, 0, "no call per row")
        XCTAssertEqual(controller.records.map(\.id), ["live"])
    }

    func testArchivedRowsJoinTheListUnsaved() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let controller = DownloadsController(fileURL: file)
        controller.save()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        controller.appendArchived((0 ..< 1_000).map {
            DownloadRecord(id: "a\($0)", source: .chromium, url: "https://files.test/\($0)", targetPath: "/tmp/\($0)",
                           state: .complete, startedAt: date)
        })
        XCTAssertEqual(controller.records.count, 1_000)
        XCTAssertEqual(controller.matching("999").map(\.id), ["a999"], "the Library's search finds archived rows")
        XCTAssertNil(controller.saveDeadline, "archived rows stay in the engine's database")
    }
}
