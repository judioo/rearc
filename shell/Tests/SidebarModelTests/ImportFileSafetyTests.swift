import Foundation
import SQLite3
import XCTest
@testable import SidebarModel

/// RC-0.1.0-602 T-08: the readers treat another browser's folder as untrusted.
final class ImportFileSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-t08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func places(_ url: URL, chain: Int = 0) throws {
        var statements = [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER, guid TEXT)",
            "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT)",
            "INSERT INTO moz_places VALUES (1, 'https://fox.example.com/', 'Fox', 1, 0, 1, 'p1')",
            "INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________')",
            "INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____')",
            "INSERT INTO moz_bookmarks VALUES (10, 1, 1, 3, 0, 'Fox', 'b10')",
        ]
        var parent = 3
        for level in 0 ..< chain {
            let id = 100 + level
            statements.append("INSERT INTO moz_bookmarks VALUES (\(id), 2, NULL, \(parent), 1, 'f\(level)', 'g\(id)')")
            parent = id
        }
        statements.append("INSERT INTO moz_bookmarks VALUES (99, 1, 1, \(parent), 0, 'Deep', 'b99')")
        try BrowserImportFixture.sqlite(url, statements)
    }

    func testADatabaseThatIsALinkIsNeverOpened() throws {
        let secret = root.appendingPathComponent("secret.sqlite")
        try places(secret)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let link = profile.appendingPathComponent("places.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertThrowsError(try SQLiteSnapshot(copying: link))
        XCTAssertThrowsError(try FirefoxPlacesReader.bookmarks(link))
        XCTAssertNil(FirefoxPlacesReader.pageCount(link))

        // A real file whose write-ahead log is a link: refused too.
        let real = profile.appendingPathComponent("History")
        try places(real)
        try FileManager.default.createSymbolicLink(atPath: real.path + "-wal", withDestinationPath: secret.path)
        XCTAssertThrowsError(try SQLiteSnapshot(copying: real))
    }

    func testDocumentsAreReadOnlyAsRegularFilesWithinTheirSize() throws {
        let target = root.appendingPathComponent("target.json")
        try Data(#"{"roots":{}}"#.utf8).write(to: target)
        let link = root.appendingPathComponent("Bookmarks")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ImportFile.data(link))
        XCTAssertThrowsError(try ChromiumBookmarksReader.read(link))
        XCTAssertThrowsError(try ImportFile.data(target, maxBytes: 4))
        XCTAssertNoThrow(try ImportFile.data(target))
    }

    func testDeeplyNestedJSONIsRefusedBeforeParsing() throws {
        let deep = Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8)
        XCTAssertFalse(ImportFile.nestsWithin(deep, limit: ImportFile.maxJSONNesting))
        XCTAssertTrue(ImportFile.nestsWithin(Data(#"{"a":"[[[[[[[[","b":[1,[2]]}"#.utf8), limit: 3), "brackets inside strings do not count")
        XCTAssertThrowsError(try ChromiumBookmarksReader.parse(Data((#"{"roots":"# + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "}").utf8)))
        XCTAssertThrowsError(try ArcSidebarReader.parse(deep))
    }

    func testProfilesIniPathsStayInsideTheFirefoxFolder() throws {
        let firefox = root.appendingPathComponent("Firefox", isDirectory: true)
        let inside = firefox.appendingPathComponent("Profiles/aaaa.default", isDirectory: true)
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        for folder in [inside, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try places(folder.appendingPathComponent("places.sqlite"))
        }
        try FileManager.default.createSymbolicLink(at: firefox.appendingPathComponent("Profiles/linked"), withDestinationURL: outside)
        let ini = """
            [Profile0]
            Name=good
            IsRelative=1
            Path=Profiles/aaaa.default

            [Profile1]
            Name=absolute
            IsRelative=0
            Path=\(outside.path)

            [Profile2]
            Name=dotdot
            IsRelative=1
            Path=../elsewhere

            [Profile3]
            Name=linked
            IsRelative=1
            Path=Profiles/linked
            """
        try Data(ini.utf8).write(to: firefox.appendingPathComponent("profiles.ini"))
        XCTAssertEqual(FirefoxProfiles.read(root: firefox).map(\.name), ["good"])
    }

    /// The reviewer's case: a 4,000-level chain crashed the reader on a 512 KiB thread.
    func testADeepBookmarkChainIsReadOnASmallStack() throws {
        let url = root.appendingPathComponent("places.sqlite")
        try places(url, chain: 4000)
        var result: Result<[BookmarkNode], Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try FirefoxPlacesReader.bookmarks(url) }
            done.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        let nodes = try XCTUnwrap(result).get()
        XCTAssertFalse(nodes.isEmpty, "the shallow bookmark still comes over")
    }

    func testDatabasesOpenWithTheSchemaDistrusted() throws {
        let url = root.appendingPathComponent("plain.sqlite")
        try places(url)
        let db = try XCTUnwrap(ImportFile.openDatabase(url))
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA trusted_schema", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        XCTAssertNotEqual(sqlite3_exec(db, "CREATE TABLE x (a)", nil, nil, nil), SQLITE_OK, "query only")
    }
}
