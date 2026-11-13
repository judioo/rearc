import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// The download menu's actions (`DownloadsController.perform(_:on:)`), with
/// a private pasteboard and a stand-in Trash.
final class DownloadMenuActionTests: XCTestCase {
    private final class Trash: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var refuse: Set<String> = []
        var moved: [URL] { lock.withLock { stored } }
        func move(_ url: URL) throws {
            if refuse.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            lock.withLock { stored.append(url) }
        }
    }

    private func makeController() -> (DownloadsController, NSPasteboard, Trash) {
        let downloads = DownloadsController(fileURL: nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-download-menu-\(UUID().uuidString)"))
        let trash = Trash()
        downloads.pasteboard = pasteboard
        downloads.trashItem = { try trash.move($0) }
        downloads.apply([
            DownloadEvent(kind: .created, guid: "gif", url: "https://c.tenor.com/HR3YZjYlr_UAAAAC/tenor.gif",
                          targetPath: "/tmp/rearc-tests/tenor.gif", totalBytes: 2_800_000, state: .complete),
            DownloadEvent(kind: .created, guid: "zip", url: "https://example.test/a.zip",
                          targetPath: "/tmp/rearc-tests/a.zip", totalBytes: 2_048, state: .complete),
            DownloadEvent(kind: .created, guid: "busy", url: "https://example.test/busy", state: .inProgress),
        ], source: .webKit)
        downloads.flushPending()
        return (downloads, pasteboard, trash)
    }

    private func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testCopyPutsTheFilesThemselvesOnThePasteboard() throws {
        let (downloads, pasteboard, _) = makeController()
        downloads.perform(.copyFile, on: ["gif", "busy", "zip"])
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.path), ["/tmp/rearc-tests/tenor.gif", "/tmp/rearc-tests/a.zip"], "only finished files, as files")
        downloads.perform(.copyLink, on: ["gif"])
        XCTAssertEqual(pasteboard.string(forType: .string), "https://c.tenor.com/HR3YZjYlr_UAAAAC/tenor.gif")
        downloads.perform(.copyLink, on: ["gif", "zip"])
        XCTAssertEqual(pasteboard.string(forType: .string), "https://c.tenor.com/HR3YZjYlr_UAAAAC/tenor.gif\nhttps://example.test/a.zip")
    }

    func testMoveToTrashTrashesTheFileAndDropsTheRow() {
        let (downloads, _, trash) = makeController()
        var moved: Int?
        downloads.perform(.moveToTrash, on: ["gif"]) { moved = $0 }
        waitFor { moved != nil }
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(trash.moved.map(\.path), ["/tmp/rearc-tests/tenor.gif"])
        XCTAssertNil(downloads.records.first { $0.id == "gif" })

        // A file that cannot be moved keeps its row; a transfer has no file to move.
        trash.refuse = ["a.zip"]
        moved = nil
        downloads.perform(.moveToTrash, on: ["zip", "busy"]) { moved = $0 }
        waitFor { moved != nil }
        XCTAssertEqual(moved, 0)
        XCTAssertNotNil(downloads.records.first { $0.id == "zip" })
        XCTAssertNotNil(downloads.records.first { $0.id == "busy" })
    }

    func testRemoveFromListKeepsTheFile() {
        let (downloads, _, trash) = makeController()
        downloads.perform(.removeFromList, on: ["zip", "busy"])
        XCTAssertEqual(downloads.records.map(\.id), ["gif"])
        XCTAssertTrue(trash.moved.isEmpty)
    }
}
