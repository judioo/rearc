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

    // MARK: Row window

    func testRowWindowShowsAPageAndGrowsNearItsEnd() {
        var window = LibraryDownloads.RowWindow()
        let page = LibraryDownloads.RowWindow.page
        XCTAssertEqual(window.shown(of: 39_413), page)
        XCTAssertEqual(window.shown(of: 12), 12)
        // Rows well above the end ask for nothing.
        XCTAssertFalse(window.rowAppeared(0, of: 39_413))
        XCTAssertFalse(window.rowAppeared(page - LibraryDownloads.RowWindow.lead - 1, of: 39_413))
        XCTAssertTrue(window.rowAppeared(page - LibraryDownloads.RowWindow.lead, of: 39_413))
        XCTAssertEqual(window.shown(of: 39_413), 2 * page)
        // The same row again does not add another page.
        XCTAssertFalse(window.rowAppeared(page - LibraryDownloads.RowWindow.lead, of: 39_413))
    }

    func testRowWindowSaysWhenAPageWouldJoinWithoutChanging() {
        var window = LibraryDownloads.RowWindow()
        XCTAssertTrue(window.isFirstPage)
        for count in [0, 1, 99, 100, 101, 5_000] {
            for index in [0, 50, 74, 75, 99, 150] where index < max(count, 1) {
                var copy = window
                XCTAssertEqual(window.needsNextPage(after: index, of: count), copy.rowAppeared(index, of: count), "row \(index) of \(count)")
            }
        }
        window.rowAppeared(99, of: 5_000)
        XCTAssertFalse(window.isFirstPage)
        XCTAssertFalse(window.needsNextPage(after: 99, of: 5_000))
        XCTAssertTrue(window.needsNextPage(after: 175, of: 5_000))
    }

    func testRowWindowReachesEveryRowAndStopsAtTheEnd() {
        var window = LibraryDownloads.RowWindow()
        let count = 1_234
        var pages = 0
        while window.shown(of: count) < count {
            XCTAssertTrue(window.rowAppeared(window.shown(of: count) - 1, of: count))
            pages += 1
            XCTAssertLessThan(pages, 20)
        }
        XCTAssertEqual(window.shown(of: count), count)
        XCTAssertFalse(window.rowAppeared(count - 1, of: count))
        // A list shorter than a page never grows.
        var short = LibraryDownloads.RowWindow()
        XCTAssertFalse(short.rowAppeared(40, of: 41))
        XCTAssertEqual(short, LibraryDownloads.RowWindow())
    }

    func testRowWindowResetsToTheFirstPage() {
        var window = LibraryDownloads.RowWindow()
        window.rowAppeared(LibraryDownloads.RowWindow.page - 1, of: 10_000)
        window.rowAppeared(2 * LibraryDownloads.RowWindow.page - 1, of: 10_000)
        XCTAssertEqual(window.shown(of: 10_000), 3 * LibraryDownloads.RowWindow.page)
        window.reset()
        XCTAssertEqual(window, LibraryDownloads.RowWindow())
        // Rows that arrive later are shown once the window reaches them.
        XCTAssertEqual(window.shown(of: 50), 50)
        XCTAssertEqual(window.shown(of: 150), LibraryDownloads.RowWindow.page)
    }
}
