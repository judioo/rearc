import Foundation
import Testing
import SidebarModel
@testable import ReArc

/// Max › Tidy Downloads on disk: a folder of the test's own (never the
/// person's Downloads), the rename and its refusals, Undo, and the
/// controller's wiring from a finished download.
@MainActor
struct TidyDownloadsShellTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A finished file, last written a minute ago.
    private func file(_ name: String, bytes: Int = 10) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: url.path)
        return url.path
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    @Test func renamesInTheSameFolderAndNeverOverwrites() throws {
        let path = try file("download.pdf")
        _ = try file("Invoice.pdf", bytes: 3)
        let outcome = DownloadRenamer.rename(path, to: "Invoice.pdf", expectedSize: 10)
        #expect(outcome == .renamed(to: folder.appendingPathComponent("Invoice 2.pdf").path))
        #expect(try names() == ["Invoice.pdf", "Invoice 2.pdf"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("Invoice.pdf")).count == 3, "the other file is untouched")
    }

    @Test func aFileMovedRenamedOrChangedSinceIsLeftAlone() throws {
        #expect(DownloadRenamer.rename(folder.appendingPathComponent("gone.pdf").path, to: "New.pdf", expectedSize: 10) == .skipped(.missing))
        let changed = try file("download.pdf", bytes: 12)
        #expect(DownloadRenamer.rename(changed, to: "New.pdf", expectedSize: 10) == .skipped(.changed))
        #expect(try names() == ["download.pdf"])
    }

    @Test func aFolderBundleOrLinkIsNotAFile() throws {
        let bundle = folder.appendingPathComponent("Thing.pdf")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(DownloadRenamer.rename(bundle.path, to: "Other.pdf", expectedSize: nil) == .skipped(.notAFile))
        let target = try file("real.pdf")
        let link = folder.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(DownloadRenamer.rename(link.path, to: "Other.pdf", expectedSize: nil) == .skipped(.missing), "a link is not followed")
    }

    @Test func aFileStillOpenOrJustWrittenWaits() throws {
        let path = try file("download.pdf")
        let handle = try #require(FileHandle(forWritingAtPath: path))
        #expect(DownloadRenamer.rename(path, to: "New.pdf", expectedSize: 10) == .skipped(.open))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        #expect(DownloadRenamer.rename(path, to: "New.pdf", expectedSize: 10) == .skipped(.open), "written a moment ago")
        #expect(DownloadRenamer.rename(path, to: "New.pdf", expectedSize: 10, now: Date().addingTimeInterval(5)) == .renamed(to: folder.appendingPathComponent("New.pdf").path))
    }

    @Test func theExtensionCannotChangeAndANameCannotLeaveTheFolder() throws {
        let path = try file("download.pdf")
        #expect(DownloadRenamer.rename(path, to: "Invoice.app", expectedSize: 10) == .skipped(.noBetterName))
        #expect(DownloadRenamer.rename(path, to: "../Invoice.pdf", expectedSize: 10) == .skipped(.noBetterName))
        #expect(DownloadRenamer.rename(path, to: ".Invoice.pdf", expectedSize: 10) == .skipped(.noBetterName))
        #expect(try names() == ["download.pdf"])
    }

    @Test func aNameTakenBetweenTheCheckAndTheMoveGetsTheNextNumber() throws {
        /// The first exclusive rename finds its target just created.
        final class Racing: DownloadFileSystem, @unchecked Sendable {
            var attempts: [String] = []
            func state(atPath path: String) -> (isDirectory: Bool, isPackage: Bool, size: Int64, modified: Date)? {
                (false, false, 10, .distantPast)
            }
            func isOpen(_ path: String) -> Bool { false }
            func exists(_ path: String) -> Bool { false }
            func renameExclusive(_ from: String, to: String) -> Int32 {
                attempts.append((to as NSString).lastPathComponent)
                return attempts.count == 1 ? EEXIST : 0
            }
        }
        let fs = Racing()
        #expect(DownloadRenamer.rename("/d/download.pdf", to: "Invoice.pdf", expectedSize: 10, fileSystem: fs) == .renamed(to: "/d/Invoice 2.pdf"))
        #expect(fs.attempts == ["Invoice.pdf", "Invoice 2.pdf"])
    }

    @Test func useOriginalNamePutsItBackOrBesideAFileThatTookTheName() throws {
        let tidied = try file("Invoice.pdf")
        let original = folder.appendingPathComponent("download.pdf").path
        #expect(DownloadRenamer.restore(tidied, originalPath: original) == .renamed(to: original))
        let again = try file("Invoice.pdf")
        #expect(DownloadRenamer.restore(again, originalPath: original) == .renamed(to: folder.appendingPathComponent("download 2.pdf").path))
        #expect(DownloadRenamer.restore(tidied, originalPath: original) == .skipped(.missing))
    }

    // MARK: Wiring

    private func finish(_ controller: DownloadsController, id: String, path: String, origin: DownloadOrigin?) {
        let created = DownloadEvent(kind: .created, guid: id, url: "https://billing.acme.com/get?id=4471", targetPath: path, totalBytes: 10)
        controller.apply(created, source: .webKit)
        if let origin { controller.noteOrigin(origin, for: id) }
        controller.apply(DownloadEvent(kind: .completed, guid: id, url: created.url, targetPath: path,
                                       receivedBytes: 10, totalBytes: 10, state: .complete), source: .webKit)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func aFinishedDownloadIsRenamedAndUndoPutsItBack() async throws {
        let (model, _) = MaxShellTests.model()
        model.setMaxFeature(.tidyDownloads, on: true)
        let path = try file("download.pdf")
        let page = DownloadOrigin(page: TidyDownloads.Origin(pageTitle: "Invoice 4471 - Acme Billing", pageHost: "billing.acme.com"), isPrivate: false)
        finish(model.downloads, id: "one", path: path, origin: page)
        await waitFor { model.downloads.list.record(withID: "one")?.originalPath != nil }
        let record = try #require(model.downloads.list.record(withID: "one"))
        #expect(record.fileName == "Invoice 4471.pdf")
        #expect(record.originalName == "download.pdf")
        #expect(try names() == ["Invoice 4471.pdf"])
        #expect(model.toast?.message == "Renamed download to “Invoice 4471.pdf”")
        model.runToastUndo()
        await waitFor { model.downloads.list.record(withID: "one")?.originalPath == nil }
        #expect(try names() == ["download.pdf"])
        #expect(model.downloads.list.record(withID: "one")?.fileName == "download.pdf")
    }

    @Test func privateUnknownOrSwitchedOffIsNeverRenamed() async throws {
        let (model, _) = MaxShellTests.model()
        let path = try file("download.pdf")
        let page = DownloadOrigin(page: TidyDownloads.Origin(pageTitle: "Invoice 4471", pageHost: "billing.acme.com"), isPrivate: false)
        finish(model.downloads, id: "off", path: path, origin: page)
        model.setMaxFeature(.tidyDownloads, on: true)
        finish(model.downloads, id: "private", path: path, origin: DownloadOrigin(page: page.page, isPrivate: true))
        finish(model.downloads, id: "unknown", path: path, origin: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try names() == ["download.pdf"])
        #expect(BrowserViewModel.tidyDownloadName(for: try #require(model.downloads.list.record(withID: "private")),
                                                  origin: DownloadOrigin(page: page.page, isPrivate: true)) == nil)
    }

    @Test func aHistoryReplayIsNotAFinish() throws {
        let (model, _) = MaxShellTests.model()
        var finished: [String] = []
        model.downloads.onCompleted = { record, _ in finished.append(record.id) }
        model.downloads.apply(DownloadEvent(kind: .created, guid: "old", url: "https://e.com/a", targetPath: "/x/a.pdf", state: .complete), source: .chromium)
        #expect(finished.isEmpty)
    }

    @Test func aPrivateWebKitPageReportsNothing() {
        #expect(WebKitDownloadCenter.origin(of: nil) == DownloadOrigin(page: TidyDownloads.Origin(), isPrivate: true))
    }
}
