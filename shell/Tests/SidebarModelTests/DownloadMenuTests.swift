import XCTest
@testable import SidebarModel

/// The download menu the tray, the bottom bar's recent downloads and
/// Library › Downloads share (2026-11-13: the owner found no actions on a
/// downloaded GIF).
final class DownloadMenuTests: XCTestCase {
    private func record(_ id: String, _ state: DownloadState, path: String? = nil, paused: Bool = false, canResume: Bool = false) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: "https://c.tenor.com/\(id)/tenor.gif", targetPath: path ?? "/tmp/rearc-tests/\(id).gif",
                       totalBytes: 2_800_000, state: state, isPaused: paused, canResume: canResume, startedAt: Date(timeIntervalSince1970: 0))
    }

    private func items(_ sections: [[DownloadMenu.Entry]]) -> [[DownloadMenuItem]] { sections.map { $0.map(\.item) } }

    func testAFinishedFileGetsArcsActions() {
        let sections = DownloadMenu.sections(for: [record("gif", .complete)])
        XCTAssertEqual(items(sections), [[.open, .showInFinder], [.copyFile, .copyLink], [.moveToTrash, .removeFromList]])
        XCTAssertTrue(sections.joined().allSatisfy(\.isEnabled))
        XCTAssertEqual(sections.joined().map { $0.item.title(count: 1) },
                       ["Open", "Show in Finder", "Copy", "Copy Download Link", "Move to Trash", "Remove from List"])
    }

    func testATidiedFileOffersItsOriginalName() {
        var tidied = record("gif", .complete, path: "/tmp/rearc-tests/Nervous sweating.gif")
        tidied.originalPath = "/tmp/rearc-tests/tenor.gif"
        XCTAssertEqual(items(DownloadMenu.sections(for: [tidied]))[0], [.open, .showInFinder, .useOriginalName])
    }

    func testTransfersOfferPauseResumeAndCancelButNoFileActions() {
        XCTAssertEqual(items(DownloadMenu.sections(for: [record("busy", .inProgress)])),
                       [[.pause, .cancel], [.copyLink], [.removeFromList]])
        let paused = DownloadMenu.sections(for: [record("paused", .inProgress, paused: true, canResume: false)])
        XCTAssertEqual(items(paused)[0], [.resume, .cancel])
        XCTAssertEqual(paused[0][0].isEnabled, false, "a transfer that cannot resume shows Resume disabled")
        // Waiting for Keep or Discard: no Pause.
        XCTAssertEqual(items(DownloadMenu.sections(for: [record("risky", .inProgress)], isWarned: { _ in true }))[0], [.cancel])
        XCTAssertEqual(items(DownloadMenu.sections(for: [record("gone", .cancelled)])), [[.copyLink], [.removeFromList]])
    }

    func testSeveralRowsGetWhatAppliesToEach() {
        let sections = DownloadMenu.sections(for: [record("a", .complete), record("b", .inProgress), record("c", .complete)])
        XCTAssertEqual(items(sections), [[.open, .showInFinder], [.copyFile, .copyLink], [.moveToTrash, .removeFromList]],
                       "no transfer actions for a mixed selection; file actions act on the finished files")
        XCTAssertEqual(DownloadMenuItem.copyLink.title(count: 3), "Copy Download Links")
        XCTAssertEqual(DownloadMenu.sections(for: []), [])
    }
}
