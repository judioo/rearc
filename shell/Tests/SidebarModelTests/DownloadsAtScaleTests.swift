import Foundation
import SidebarModel
import XCTest

/// Downloads at scale (docs/PERF-BASELINE.md): the list's id lookup, the
/// launch read that stops after the kept rows, the search index and the
/// quick view's one-pass pick behave exactly as before.
final class DownloadsAtScaleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, path: String? = nil, url: String? = nil, state: DownloadState = .complete,
                        updated: TimeInterval = 0) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: url ?? "https://example.com/\(id)", targetPath: path ?? "/tmp/\(id).bin",
                       totalBytes: 10, state: state, startedAt: base, updatedAt: base.addingTimeInterval(updated))
    }

    private func finished(_ guid: String) -> DownloadEvent {
        DownloadEvent(kind: .created, guid: guid, url: "https://example.com/\(guid)", targetPath: "/tmp/\(guid)", state: .complete)
    }

    // MARK: DownloadList

    func testReplayedHistoryAppendsEachGUIDOnceAndMergesKnownRows() {
        var list = DownloadList(records: [record("kept")])
        for index in 0 ..< 500 { list.apply(finished("h\(index)"), source: .chromium, now: base) }
        XCTAssertEqual(list.apply(finished("kept"), source: .chromium, now: base), .updated("kept"))
        XCTAssertEqual(list.apply(finished("h7"), source: .chromium, now: base), .updated("h7"))
        XCTAssertEqual(list.records.count, 501)
        XCTAssertEqual(list.records.first?.id, "kept")
        XCTAssertEqual(list.records.last?.id, "h499")
        XCTAssertEqual(list.record(withID: "h250")?.targetPath, "/tmp/h250")
    }

    func testLookupFollowsRemoveClearAndTrim() {
        var list = DownloadList(records: (0 ..< 60).map { record("r\($0)") })
        XCTAssertTrue(list.remove(id: "r3"))
        XCTAssertNil(list.record(withID: "r3"))
        XCTAssertFalse(list.remove(id: "r3"))
        XCTAssertEqual(list.apply(DownloadEvent(kind: .removed, guid: "r4", url: ""), source: .chromium, now: base), .removed("r4"))
        XCTAssertEqual(list.apply(DownloadEvent(kind: .removed, guid: "r4", url: ""), source: .chromium, now: base), .ignored)
        list.trim(to: 10)
        XCTAssertNil(list.record(withID: "r30"), "trimmed rows are gone from the lookup")
        XCTAssertEqual(list.apply(finished("r30"), source: .chromium, now: base), .inserted("r30"))
        list.apply(DownloadEvent(kind: .created, guid: "live", url: "https://example.com/live"), source: .chromium, now: base)
        _ = list.clearFinished()
        XCTAssertEqual(list.records.map(\.id), ["live"])
        XCTAssertNil(list.record(withID: "r0"))
        XCTAssertEqual(list.apply(finished("r0"), source: .chromium, now: base), .inserted("r0"))
    }

    func testDuplicateIDsFromAFileStayFindableUntilTheLastGoes() {
        var list = DownloadList(records: [record("dup"), record("dup"), record("other")])
        XCTAssertTrue(list.remove(id: "dup"))
        XCTAssertNotNil(list.record(withID: "dup"))
        XCTAssertEqual(list.apply(finished("dup"), source: .chromium, now: base), .updated("dup"))
        XCTAssertTrue(list.remove(id: "dup"))
        XCTAssertNil(list.record(withID: "dup"))
    }

    func testEqualityAndCodingIgnoreTheLookup() throws {
        var built = DownloadList()
        built.apply(finished("a"), source: .chromium, now: base)
        built.apply(finished("b"), source: .chromium, now: base)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(built)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       ["records": try JSONSerialization.jsonObject(with: encoder.encode(built.records))] as NSDictionary)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadList.self, from: data)
        XCTAssertEqual(decoded, built)
        XCTAssertEqual(decoded.record(withID: "b")?.id, "b")
    }

    // MARK: Launch read

    func testLaunchReadKeepsWhatAFullReadKeeps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-downloads-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(DownloadListFile.fileName)
        var records = (0 ..< 200).map { record("r\($0)", updated: Double(-$0)) }
        records[3].state = .inProgress
        records[120].state = .inProgress
        try DownloadListFile.save(.init(directory: "/tmp/d", askWhereToSave: true, list: DownloadList(records: records)), to: url)

        let full = DownloadListFile.load(from: url)
        let limited = DownloadListFile.load(from: url, limit: DownloadList.defaultLimit)
        XCTAssertEqual(full.list.records.count, 200)
        XCTAssertEqual(limited.list.records.count, DownloadList.defaultLimit)
        XCTAssertEqual(limited.directory, "/tmp/d")
        XCTAssertEqual(limited.askWhereToSave, true)
        // What the tray does with it at launch.
        func launch(_ contents: DownloadListFile.Contents) -> DownloadList {
            var list = contents.list
            list.markStaleTransfersInterrupted()
            list.trim()
            return list
        }
        XCTAssertEqual(launch(limited), launch(full))
        XCTAssertEqual(launch(limited).record(withID: "r3")?.state, .interrupted)
    }

    func testLaunchReadOfAShortOrMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-downloads-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(DownloadListFile.fileName)
        XCTAssertEqual(DownloadListFile.load(from: url, limit: 50), DownloadListFile.Contents())
        try DownloadListFile.save(.init(list: DownloadList(records: [record("only")])), to: url)
        XCTAssertEqual(DownloadListFile.load(from: url, limit: 50).list.records.map(\.id), ["only"])
        XCTAssertEqual(DownloadListFile.load(from: url, limit: 0).list.records, [])
    }
}
