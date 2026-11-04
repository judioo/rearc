import XCTest
@testable import SidebarModel

/// Wave 20 pure models: find-in-page session reduction, the downloads list,
/// visit history ranking and the command bar's history rows.
final class Wave20ModelTests: XCTestCase {

    // MARK: Find in page

    private func result(_ session: UInt64, _ count: Int32, _ ordinal: Int32, final: Bool = true) -> FindInPageEvent {
        FindInPageEvent(sessionID: session, matchCount: count, activeOrdinal: ordinal, finalUpdate: final, reason: .result)
    }

    func testFindShowsOnlyFinalResultsOfTheCurrentSession() {
        var state = FindInPageState(query: "needle")
        state.began(session: 7)
        XCTAssertEqual(state.statusText, "", "nothing until the first final result")
        XCTAssertFalse(state.apply(result(7, 2, 1, final: false)), "partial results are ignored")
        XCTAssertFalse(state.apply(result(6, 9, 9)), "an old session's result is ignored")
        XCTAssertTrue(state.apply(result(7, 4, 1)))
        XCTAssertEqual(state.statusText, "1 of 4")
        state.apply(result(7, 4, 2))
        XCTAssertEqual(state.statusText, "2 of 4")
    }

    func testFindTerminalEndsTheSessionAndHidesTheCount() {
        var state = FindInPageState(query: "needle")
        state.began(session: 3)
        state.apply(result(3, 4, 4))
        let navigated = FindInPageEvent(sessionID: 3, matchCount: -1, activeOrdinal: -1, finalUpdate: true, rawReason: 1)
        XCTAssertEqual(navigated.reason, .navigated)
        XCTAssertTrue(state.apply(navigated))
        XCTAssertEqual(state.sessionID, 0)
        XCTAssertNil(state.matchCount)
        XCTAssertEqual(state.statusText, "")
        XCTAssertFalse(state.apply(result(3, 4, 1)), "nothing applies after the terminal")
        XCTAssertEqual(FindInPageEvent(sessionID: 1, matchCount: 0, activeOrdinal: 0, finalUpdate: true, rawReason: 99).reason, .stopped)
    }

    func testFindReportsNoMatchesAndClampsOrdinals() {
        var state = FindInPageState(query: "zzz")
        state.began(session: 1)
        state.apply(result(1, 0, 0))
        XCTAssertEqual(state.statusText, "No matches")
        XCTAssertTrue(state.hasNoMatches)
        state.began(session: 2)
        state.apply(result(2, 3, 9))
        XCTAssertEqual(state.activeOrdinal, 3)
    }

    func testFindOrdinalWrapsBothWays() {
        XCTAssertEqual(FindOrdinal.step(1, count: 4, forward: true), 2)
        XCTAssertEqual(FindOrdinal.step(4, count: 4, forward: true), 1)
        XCTAssertEqual(FindOrdinal.step(1, count: 4, forward: false), 4)
        XCTAssertEqual(FindOrdinal.step(0, count: 4, forward: false), 4)
        XCTAssertEqual(FindOrdinal.step(2, count: 0, forward: true), 0)
    }

    func testFindCountFollowsMatchCase() {
        let text = "Needle needle NEEDLE haystack néedle"
        XCTAssertEqual(FindOrdinal.count(of: "needle", in: text, matchCase: false), 4)
        XCTAssertEqual(FindOrdinal.count(of: "needle", in: text, matchCase: true), 1)
        XCTAssertEqual(FindOrdinal.count(of: "", in: text, matchCase: false), 0)
        XCTAssertEqual(FindOrdinal.count(of: "aa", in: "aaaa", matchCase: true), 2, "non-overlapping, like page find")
    }

    // MARK: Downloads

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        _ kind: DownloadEvent.Kind,
        _ guid: String = "g1",
        received: Int64 = 0,
        total: Int64 = 1_000,
        state: DownloadState = .inProgress,
        path: String = "",
        danger: UInt32 = 0,
        paused: Bool = false
    ) -> DownloadEvent {
        DownloadEvent(
            kind: kind, guid: guid, url: "https://files.test/report.pdf", targetPath: path,
            mimeType: "application/pdf", receivedBytes: received, totalBytes: total, state: state,
            dangerType: danger, isPaused: paused, canResume: paused
        )
    }

    func testDownloadEventsBuildOneRowPerGUID() {
        var list = DownloadList()
        XCTAssertEqual(list.apply(event(.created), source: .chromium, now: t0), .inserted("g1"))
        list.apply(event(.updated, received: 250, path: "/tmp/report.pdf"), source: .chromium, now: t0.addingTimeInterval(1))
        list.apply(event(.updated, received: 750, path: ""), source: .chromium, now: t0.addingTimeInterval(2))
        XCTAssertEqual(list.records.count, 1)
        var row = try! XCTUnwrap(list.record(withID: "g1"))
        XCTAssertEqual(row.targetPath, "/tmp/report.pdf", "an empty path in a later event keeps the known one")
        XCTAssertEqual(row.fractionCompleted ?? 0, 0.75, accuracy: 0.001)
        XCTAssertNotNil(row.bytesPerSecond)
        XCTAssertTrue(row.statusText.contains("/s"), row.statusText)
        XCTAssertEqual(list.activeCount, 1)
        XCTAssertEqual(list.activeFraction ?? 0, 0.75, accuracy: 0.001)

        list.apply(event(.completed, received: 1_000, state: .complete), source: .chromium, now: t0.addingTimeInterval(3))
        row = try! XCTUnwrap(list.record(withID: "g1"))
        XCTAssertTrue(row.hasFileOnDisk)
        XCTAssertNil(row.bytesPerSecond)
        XCTAssertEqual(row.fileName, "report.pdf")
        XCTAssertEqual(list.activeCount, 0)
        XCTAssertEqual(list.apply(event(.removed), source: .chromium, now: t0), .removed("g1"))
        XCTAssertTrue(list.records.isEmpty)
        XCTAssertEqual(list.apply(event(.removed), source: .chromium, now: t0), .ignored)
    }

    func testNewDownloadsGoFirstAndRestoredHistoryLast() {
        var list = DownloadList()
        list.apply(event(.created, "old", state: .complete), source: .chromium, now: t0)
        list.apply(event(.created, "new"), source: .chromium, now: t0)
        list.apply(event(.created, "restored", state: .complete), source: .chromium, now: t0)
        XCTAssertEqual(list.records.map(\.id), ["new", "old", "restored"])
    }

    func testPausedAndInterruptedStatus() {
        var list = DownloadList()
        list.apply(event(.created), source: .webKit, now: t0)
        list.apply(event(.updated, received: 100, paused: true), source: .webKit, now: t0.addingTimeInterval(1))
        XCTAssertTrue(list.records[0].statusText.hasPrefix("Paused"), list.records[0].statusText)
        XCTAssertTrue(list.records[0].canResume)
        var failed = event(.interrupted, state: .interrupted)
        failed.interruptReason = 22
        list.apply(failed, source: .webKit, now: t0.addingTimeInterval(2))
        XCTAssertEqual(list.records[0].statusText, "Failed — Network disconnected")
    }

    func testDangerousDownloadsAreFlaggedOnlyWhileInProgress() {
        XCTAssertEqual(DownloadDanger(dangerType: 0), .none)
        XCTAssertEqual(DownloadDanger(dangerType: 4), .checking, "maybe-dangerous is normal while the check runs")
        XCTAssertEqual(DownloadDanger(dangerType: 1), .warning("This type of file can harm your computer"))
        var list = DownloadList()
        list.apply(event(.created, danger: 3), source: .chromium, now: t0)
        XCTAssertTrue(list.hasDangerous)
        XCTAssertEqual(list.records[0].statusText, "This file is dangerous")
        list.apply(event(.cancelled, state: .cancelled, danger: 3), source: .chromium, now: t0)
        XCTAssertFalse(list.hasDangerous)
        XCTAssertEqual(list.records[0].statusText, "Cancelled")
    }

    func testRelaunchInterruptsStaleTransfersAndTrimKeepsActiveRows() {
        var list = DownloadList()
        for index in 0 ..< 5 {
            list.apply(event(.created, "done-\(index)", state: .complete), source: .webKit, now: t0)
        }
        list.apply(event(.created, "live"), source: .webKit, now: t0)
        list.trim(to: 2)
        XCTAssertEqual(list.records.map(\.id), ["live", "done-0", "done-1"])
        list.markStaleTransfersInterrupted()
        XCTAssertEqual(list.record(withID: "live")?.state, .interrupted)
        XCTAssertEqual(list.record(withID: "live")?.statusText, "Failed — Interrupted when ReArc quit")
        XCTAssertEqual(list.clearFinished().count, 3)
        XCTAssertTrue(list.records.isEmpty)
    }

    func testDownloadListPersistsWithoutSessionFields() throws {
        var list = DownloadList()
        list.apply(event(.created), source: .chromium, now: t0)
        list.apply(event(.updated, received: 500), source: .chromium, now: t0.addingTimeInterval(1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w20-\(UUID().uuidString)/Downloads.json")
        try DownloadListFile.save(.init(directory: "/tmp/dl", list: list), to: url)
        let loaded = DownloadListFile.load(from: url)
        XCTAssertEqual(loaded.directory, "/tmp/dl")
        XCTAssertEqual(loaded.list.records.first?.receivedBytes, 500)
        XCTAssertNil(loaded.list.records.first?.bytesPerSecond, "the transfer rate is session-only")
        XCTAssertEqual(DownloadListFile.load(from: url.appendingPathExtension("missing")), .init())
    }

    func testUniqueDestinationsFollowChromiumsUniquifier() {
        let directory = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)
        var taken: Set<String> = ["/tmp/dl/report.pdf", "/tmp/dl/report (1).pdf"]
        XCTAssertEqual(DownloadFormat.uniqueDestination(for: "report.pdf", in: directory) { taken.contains($0.path) }.lastPathComponent,
                       "report (2).pdf")
        taken = []
        XCTAssertEqual(DownloadFormat.uniqueDestination(for: "../../etc/passwd", in: directory) { taken.contains($0.path) }.deletingLastPathComponent().path,
                       "/tmp/dl", "a suggested name never leaves the directory")
        XCTAssertEqual(DownloadFormat.sanitizedFileName("  "), "download")
    }

    // MARK: Visit history

    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testOnlyWebPagesAreRecordedAndKeysNormalize() {
        var history = VisitHistory()
        history.recordVisit(url: URL(string: "about:blank")!, title: nil, at: now)
        history.recordVisit(url: URL(string: "chrome://settings")!, title: nil, at: now)
        history.recordVisit(url: URL(string: "data:text/html,x")!, title: nil, at: now)
        XCTAssertTrue(history.isEmpty)
        history.recordVisit(url: URL(string: "https://Example.test/#top")!, title: "Example", at: now)
        history.recordVisit(url: URL(string: "https://example.test")!, title: nil, at: now.addingTimeInterval(5))
        XCTAssertEqual(history.count, 1, "fragment, case and the lone slash do not make a new page")
        XCTAssertEqual(history.record(for: URL(string: "https://example.test/")!)?.visitCount, 2)
        XCTAssertEqual(history.record(for: URL(string: "https://example.test/")!)?.title, "Example", "a nil title keeps the old one")
        history.updateTitle(url: URL(string: "https://example.test")!, title: "Example Domain")
        XCTAssertEqual(history.record(for: URL(string: "https://example.test")!)?.visitCount, 2, "a title is not a visit")
    }

    func testHistoryRanksHostPrefixOverTitleAndFrecency() {
        var history = VisitHistory()
        history.recordVisit(url: URL(string: "https://news.test/article")!, title: "Github trending today", at: now)
        for _ in 0 ..< 3 { history.recordVisit(url: URL(string: "https://www.github.test/")!, title: "GitHub", at: now) }
        history.recordVisit(url: URL(string: "https://old.test/")!, title: "github mirror", at: now.addingTimeInterval(-200 * 86_400))
        let matches = history.matches(for: "git", now: now)
        XCTAssertEqual(matches.first?.record.url.host(), "www.github.test", "www. is ignored for host prefixes")
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.last?.record.url.host(), "old.test", "old visits rank last")
        XCTAssertEqual(history.matches(for: "github today", now: now).map { $0.record.url.host() }, ["news.test"], "every token must match")
        XCTAssertTrue(history.matches(for: "zzz", now: now).isEmpty)
        let excluded = VisitHistory.key(for: URL(string: "https://www.github.test/")!)!
        XCTAssertFalse(history.matches(for: "git", now: now, excluding: [excluded]).contains { $0.record.url.host() == "www.github.test" })
    }

    func testHistoryPersistsAndEvictsTheOldest() throws {
        var history = VisitHistory()
        history.recordVisit(url: URL(string: "https://a.test/")!, title: "A", at: now)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w20-\(UUID().uuidString)/History.json")
        try VisitHistoryFile.save(history, to: url)
        XCTAssertEqual(VisitHistoryFile.load(from: url), history)
        XCTAssertTrue(VisitHistoryFile.load(from: url.appendingPathExtension("missing")).isEmpty)

        var full = VisitHistory()
        for index in 0 ... VisitHistory.capacity {
            full.recordVisit(url: URL(string: "https://site\(index).test/")!, title: nil, at: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(full.count, VisitHistory.capacity)
        XCTAssertNil(full.record(for: URL(string: "https://site0.test/")!), "the least recent visit goes")
    }
}
