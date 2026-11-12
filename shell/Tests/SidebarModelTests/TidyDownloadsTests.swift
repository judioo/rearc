import XCTest
@testable import SidebarModel

/// Max › Tidy Downloads' naming rules (MAX.md §3). File names come from
/// servers and pages, so most of these are about what never gets through.
final class TidyDownloadsTests: XCTestCase {
    private func name(_ file: String, title: String? = nil, host: String? = nil) -> String? {
        TidyDownloads.tidyName(for: file, origin: TidyDownloads.Origin(pageTitle: title, pageHost: host))
    }

    func testAnInformativeNameIsOnlyMadeReadable() {
        XCTAssertEqual(name("annual_report-2026.pdf"), "annual report 2026.pdf")
        XCTAssertEqual(name("Quarterly+Plan%20Final.docx"), "Quarterly Plan Final.docx")
        XCTAssertEqual(name("budget (1).xlsx"), "budget.xlsx", "Chromium's copy counter goes; a free name is found on disk")
        XCTAssertNil(name("Meeting notes.txt"), "already clear")
        XCTAssertEqual(name("release-2026-11-12.zip"), "release 2026-11-12.zip", "a date keeps its dashes")
    }

    func testAnUninformativeNameTakesThePagesTitleOrItsSite() {
        XCTAssertEqual(name("download.pdf", title: "Invoice #4471 - Acme Billing", host: "billing.acme.com"), "Invoice #4471.pdf")
        XCTAssertEqual(name("a8f3e2c19b7d4e6fa0c1.pdf", title: "Lease agreement | Example Homes", host: "examplehomes.com"), "Lease agreement.pdf")
        XCTAssertEqual(name("file-4471.csv", title: nil, host: "billing.acme.com"), "Acme 4471.csv", "the site's name, and the number it had")
        XCTAssertEqual(name("IMG_2041.jpg", title: "Holiday photos", host: "photos.example.com"), "Holiday photos 2041.jpg")
        XCTAssertNil(name("download.pdf", title: nil, host: nil), "nothing better to go on")
        XCTAssertNil(name("download.pdf", title: nil, host: "192.168.1.4"))
    }

    func testTheExtensionIsTheFilesOwnAndNeverChanges() throws {
        let renamed = try XCTUnwrap(name("download.PDF", title: "Report.app", host: "example.com"))
        XCTAssertEqual(TidyDownloads.fileExtension(of: renamed), "pdf")
        XCTAssertFalse(renamed.contains(".app"))
        XCTAssertEqual(renamed, "Report app.pdf")
        XCTAssertNil(name("README", title: "Read me", host: "example.com"), "no extension, no rename")
    }

    func testRunnableInstallableAndMountableFilesAreLeftAlone() {
        for file in ["setup.dmg", "Installer.pkg", "tool.command", "run.sh", "App.app", "image.iso", "thing.exe",
                     "script.py", "partial.crdownload", "shortcut.webloc", "Profile.mobileconfig", ".hidden.pdf"] {
            XCTAssertNil(name(file, title: "Something", host: "example.com"), file)
            XCTAssertTrue(TidyDownloads.isUntouched(file), file)
        }
    }

    func testHostileTitlesBecomeSafeNames() throws {
        let cases: [(title: String, expect: String)] = [
            ("../../etc/passwd", "etc passwd.pdf"),
            ("a/b\\c:d<e>f\"g|h?i*j", "a b c d e f g h i j.pdf"),
            (".bashrc", "bashrc.pdf"),
            ("Invoice\u{202E}fdp.exe", "Invoicefdp exe.pdf"),
            ("Zero\u{200B}width\u{0000}nul", "Zerowidthnul.pdf"),
            ("  ...  ", ""),
        ]
        for (title, expect) in cases {
            let result = name("download.pdf", title: title, host: "example.com")
            if expect.isEmpty {
                XCTAssertEqual(result, "Example.pdf", "nothing left of the title: the site's name")
            } else {
                XCTAssertEqual(result, expect, title)
            }
            if let result {
                XCTAssertFalse(result.contains("/"))
                XCTAssertFalse(result.hasPrefix("."))
                XCTAssertTrue(result.hasSuffix(".pdf"))
                for scalar in result.unicodeScalars { XCTAssertFalse(TidyText.invisible.contains(scalar), title) }
            }
        }
    }

    func testHostileOriginalNamesBecomeSafeNames() {
        XCTAssertEqual(name("x%2F..%2F..%2Fsecret_plan.pdf"), "x secret plan.pdf")
        XCTAssertNil(name("..%2Fsecret_plan.pdf"), "a leading dot is a hidden file: left alone")
        XCTAssertEqual(name("report\u{202E}fdp.pdf"), "reportfdp.pdf")
        XCTAssertEqual(name("C:\\Users\\notes_v1.2.txt"), "C Users notes v1.2.txt")
    }

    func testNamesAreBounded() throws {
        let long = String(repeating: "word ", count: 200)
        let result = try XCTUnwrap(name("download.pdf", title: long, host: "example.com"))
        XCTAssertLessThanOrEqual((result as NSString).deletingPathExtension.count, TidyDownloads.maximumStemLength)
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
        let wide = String(repeating: "日本語の文書", count: 40)
        let wideResult = try XCTUnwrap(name("download.pdf", title: wide, host: "example.com"))
        XCTAssertLessThanOrEqual(wideResult.utf8.count, 255)
    }

    func testAFreeNameNeverExists() {
        let directory = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let taken: Set<String> = ["/tmp/x/Report.pdf", "/tmp/x/Report 2.pdf"]
        XCTAssertEqual(TidyDownloads.freeName("Report.pdf", in: directory) { taken.contains($0.path) }.path, "/tmp/x/Report 3.pdf")
        XCTAssertEqual(TidyDownloads.freeName("Other.pdf", in: directory) { taken.contains($0.path) }.path, "/tmp/x/Other.pdf")
    }

    // MARK: The download record

    func testTheRecordKeepsItsOriginalAndTheEngineCannotUndoTheRename() throws {
        var list = DownloadList()
        let now = Date()
        list.apply(DownloadEvent(kind: .created, guid: "g", url: "https://e.com/d", targetPath: "/d/download.pdf"), source: .chromium, now: now)
        list.apply(DownloadEvent(kind: .completed, guid: "g", url: "https://e.com/d", targetPath: "/d/download.pdf", state: .complete), source: .chromium, now: now)
        XCTAssertTrue(list.setRenamedPath("/d/Invoice.pdf", originalPath: "/d/download.pdf", for: "g"))
        // Chromium replays its own path at the next launch.
        list.apply(DownloadEvent(kind: .created, guid: "g", url: "https://e.com/d", targetPath: "/d/download.pdf", state: .complete), source: .chromium, now: now)
        let record = try XCTUnwrap(list.record(withID: "g"))
        XCTAssertEqual(record.targetPath, "/d/Invoice.pdf")
        XCTAssertEqual(record.fileName, "Invoice.pdf")
        XCTAssertEqual(record.originalName, "download.pdf")

        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.originalPath, "/d/download.pdf", "saved with the download")

        XCTAssertTrue(list.setRenamedPath("/d/download.pdf", originalPath: nil, for: "g"))
        XCTAssertNil(list.record(withID: "g")?.originalName)
        XCTAssertFalse(list.setRenamedPath("/d/x.pdf", originalPath: "/d/y.pdf", for: "missing"))
    }

    func testOnlyAFinishedDownloadCanBeRenamed() {
        var list = DownloadList()
        list.apply(DownloadEvent(kind: .created, guid: "g", url: "https://e.com/d", targetPath: "/d/a.pdf"), source: .webKit, now: Date())
        XCTAssertFalse(list.setRenamedPath("/d/b.pdf", originalPath: "/d/a.pdf", for: "g"))
    }
}

final class TidyDownloadsReviewTests: XCTestCase {
    private let origin = TidyDownloads.Origin(pageTitle: "Quarterly Report - Acme", pageHost: "acme.com")

    /// RC-0.1.0-726 W-02: the extension keeps its case, and a name that differs only by case is no rename.
    func testAnUpperCaseExtensionIsKeptAndCaseAloneIsNoRename() {
        XCTAssertNil(TidyDownloads.tidyName(for: "Report.PDF", origin: origin))
        XCTAssertEqual(TidyDownloads.tidyName(for: "annual_report-2026.PDF", origin: origin), "annual report 2026.PDF")
    }

    func testADoubleExtensionIsLeftAlone() {
        XCTAssertNil(TidyDownloads.tidyName(for: "archive.tar.gz", origin: origin))
        XCTAssertNil(TidyDownloads.tidyName(for: "site_backup-2026.tar.bz2", origin: origin))
    }
}
