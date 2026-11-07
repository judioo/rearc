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

    func testArchivedRowsAppendAfterTheListAndSkipKnownOnes() {
        var list = DownloadList(records: [record("kept")])
        list.apply(finished("live"), source: .chromium, now: base)
        let added = list.appendArchived([record("a0"), record("kept"), record("a1")])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(list.records.map(\.id), ["kept", "live", "a0", "a1"], "older rows go last, newest first")
        XCTAssertEqual(list.record(withID: "a1")?.targetPath, "/tmp/a1.bin")
        XCTAssertEqual(list.apply(finished("a0"), source: .chromium, now: base), .updated("a0"), "an archived row is found again")
    }

    func testRemovingIDsInOnePassKeepsTheLookup() {
        var list = DownloadList(records: (0 ..< 10).map { record("r\($0)") })
        list.remove(ids: ["r1", "r5", "missing"])
        XCTAssertEqual(list.records.count, 8)
        XCTAssertNil(list.record(withID: "r5"))
        XCTAssertNotNil(list.record(withID: "r6"))
        XCTAssertEqual(list.apply(finished("r5"), source: .chromium, now: base), .inserted("r5"))
    }

    func testRestoredRowsKeepTheEngineTimesSoTheQuickViewPicksTheNewest() {
        var list = DownloadList(records: [record("persisted", updated: 50)])
        let replayed = base.addingTimeInterval(3_600)
        func restored(_ guid: String, ended: TimeInterval) -> DownloadEvent {
            var event = finished(guid)
            event.startedAt = base.addingTimeInterval(ended - 1)
            event.endedAt = base.addingTimeInterval(ended)
            return event
        }
        // Newest first, as the engine creates restored items from 1.48.
        list.apply(restored("newest", ended: 40), source: .chromium, now: replayed)
        list.apply(restored("persisted", ended: 30), source: .chromium, now: replayed)
        list.apply(restored("older", ended: 20), source: .chromium, now: replayed)
        XCTAssertEqual(list.record(withID: "newest")?.startedAt, base.addingTimeInterval(39))
        XCTAssertEqual(list.record(withID: "persisted")?.updatedAt, base.addingTimeInterval(30), "the engine's end time, not the replay's")
        XCTAssertEqual(RecentDownloads.latest(list.records, limit: 2).map(\.id), ["newest", "persisted"])
        // Without engine times (older engines) the arrival time stays the fallback.
        list.apply(finished("untimed"), source: .chromium, now: replayed)
        XCTAssertEqual(list.record(withID: "untimed")?.updatedAt, replayed)
    }

    func testTheLiveLimitKeepsAWholeRealisticHistoryLive() {
        // The 2,173-row fixture (one record per item of a real Downloads folder) stays on stock Chromium's path.
        XCTAssertGreaterThan(DownloadHistoryPolicy.liveLimit, 2_173)
        XCTAssertGreaterThan(DownloadHistoryPolicy.liveLimit, UInt32(DownloadList.defaultLimit))
        XCTAssertLessThanOrEqual(DownloadHistoryPolicy.archivedPageSize, 5_000, "the engine's page limit")
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

    // MARK: Search index

    func testSearchIndexMatchesLikeAFreshSearch() {
        let records = [
            record("a", path: "/d/Quarterly Report.pdf", url: "https://files.example.com/a"),
            record("b", path: "/d/photo.jpg", url: "https://cdn.example.org/b"),
            record("c", path: "", url: "https://éxample.net/Résumé.docx"),
            record("d", path: "/d/notes.txt", url: "not a url"),
            record("e", path: "/d/写真 2026.png", url: "https://例え.jp/e"),
            record("f", path: "/d/line\r\nbreak.txt", url: "https://example.com/f"),
            record("g", path: "/d/Cafe\u{301} menu.pdf", url: "https://example.com/g"),
        ]
        var index = LibraryDownloads.SearchIndex()
        for query in ["", " report ", "CDN", "resume", "EXAMPLE", "zip", "txt", "é", "写真", "例え", "\n", "line", "cafe", "café menu", "E"] {
            XCTAssertEqual(index.matching(records, query: query).map(\.id),
                           LibraryDownloads.matching(records, query: query).map(\.id), "query \(query)")
        }
    }

    func testSearchIndexFollowsRowsWhosePathOrURLChanged() {
        var records = [record("a", path: "/d/draft.txt"), record("b", path: "/d/photo.jpg")]
        var index = LibraryDownloads.SearchIndex()
        XCTAssertEqual(index.matching(records, query: "draft").map(\.id), ["a"])
        records[0].targetPath = "/d/final.txt"
        XCTAssertEqual(index.matching(records, query: "draft").map(\.id), [])
        XCTAssertEqual(index.matching(records, query: "final").map(\.id), ["a"])
        records[1].url = "https://pictures.example.com/b"
        XCTAssertEqual(index.matching(records, query: "pictures").map(\.id), ["b"])
        records.append(record("c", path: "/d/final-2.txt"))
        XCTAssertEqual(index.matching(records, query: "final").map(\.id), ["a", "c"])
    }

    // MARK: Quick view

    /// The pick before the one-pass version: filter, sort newest first, take the first.
    private func sortedLatest(_ records: [DownloadRecord], limit: Int) -> [DownloadRecord] {
        Array(records.filter(\.hasFileOnDisk).sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    func testLatestPicksTheNewestFinishedRowsWithFiles() {
        let records = [
            record("old", updated: 10),
            record("live", state: .inProgress, updated: 100),
            record("cancelled", state: .cancelled, updated: 90),
            record("nofile", path: "", updated: 80),
            record("new", updated: 50),
            record("newer", updated: 60),
            record("oldest", updated: 1),
            record("mid", updated: 30),
        ]
        XCTAssertEqual(RecentDownloads.latest(records).map(\.id), ["newer", "new", "mid", "old"])
        XCTAssertEqual(RecentDownloads.latest(records, limit: 1).map(\.id), ["newer"])
        XCTAssertEqual(RecentDownloads.latest(records, limit: 0), [])
        XCTAssertEqual(RecentDownloads.latest(Array(records.prefix(2))).map(\.id), ["old"])
    }

    func testLatestMatchesTheSortedPickIncludingTies() {
        var generator = SystemRandomNumberGenerator()
        for round in 0 ..< 200 {
            let records = (0 ..< 40).map { index in
                record("r\(round)-\(index)", path: Bool.random(using: &generator) ? "/tmp/x" : "",
                       state: [.complete, .complete, .inProgress, .interrupted].randomElement(using: &generator)!,
                       updated: Double(Int.random(in: 0 ..< 8, using: &generator)))
            }
            for limit in [1, 4, 7] {
                XCTAssertEqual(RecentDownloads.latest(records, limit: limit).map(\.id), sortedLatest(records, limit: limit).map(\.id))
            }
        }
    }
}
