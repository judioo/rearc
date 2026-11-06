import Foundation
import SQLite3

/// Chromium's `Bookmarks` file (JSON, `roots.bookmark_bar` / `other` /
/// `synced`), the same tree for Chrome, Brave and Arc. It becomes the
/// `BookmarkNode` tree the HTML import already places as pinned tabs.
public enum ChromiumBookmarksReader {
    public static let fileName = "Bookmarks"

    public enum ReadError: Error { case notBookmarks }

    /// The bar's contents at the top level, then Other and Mobile bookmarks
    /// as folders. Same limits as the HTML import: http(s) only,
    /// `BookmarkHTMLImport.maxLinks` links, `maxDepth` levels.
    public static func read(_ url: URL) throws -> [BookmarkNode] {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw ReadError.notBookmarks }
        var links = 0
        func nodes(_ children: Any?, depth: Int) -> [BookmarkNode] {
            var out: [BookmarkNode] = []
            for case let child as [String: Any] in children as? [Any] ?? [] {
                let title = (child["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if child["type"] as? String == "folder" {
                    let inner = nodes(child["children"], depth: depth + 1)
                    // Past the depth limit a folder's links join its parent.
                    if depth >= BookmarkHTMLImport.maxDepth {
                        out += inner
                    } else {
                        out.append(.folder(title: title.isEmpty ? "Folder" : title, children: inner))
                    }
                } else if links < BookmarkHTMLImport.maxLinks,
                          let href = child["url"] as? String, let url = URL(string: href),
                          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil {
                    out.append(.link(title: title.isEmpty ? (url.host() ?? href) : title, url: url))
                    links += 1
                }
            }
            return out
        }
        var result = nodes((roots["bookmark_bar"] as? [String: Any])?["children"], depth: 0)
        for (key, title) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            let inner = nodes((roots[key] as? [String: Any])?["children"], depth: 1)
            if !inner.isEmpty { result.append(.folder(title: title, children: inner)) }
        }
        return BookmarkHTMLImport.pruned(result)
    }
}

/// Chromium's `History` (SQLite `urls`: url, title, visit_count,
/// last_visit_time in microseconds since 1601, hidden). Read from a copy.
/// It feeds ReArc's command-bar history; Chromium's own history service has
/// no import entry point in the engine ABI (PROFILE-IMPORT §2.2).
public enum ChromiumHistoryReader {
    public static let fileName = "History"

    public enum ReadError: Error { case cannotOpen, notHistory }

    /// Seconds between 1601-01-01 and 1970-01-01.
    static let windowsEpochOffset: Double = 11_644_473_600

    public static func date(chromiumTime: Int64) -> Date {
        Date(timeIntervalSince1970: Double(chromiumTime) / 1_000_000 - windowsEpochOffset)
    }

    public static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000)
    }

    /// The most recently visited web pages, newest first, at most `limit`.
    public static func read(_ url: URL, limit: Int = VisitHistory.capacity) throws -> [VisitRecord] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        return try withDatabase(snapshot.url) { db in
            var records: [VisitRecord] = []
            try query(db, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND visit_count > 0 ORDER BY last_visit_time DESC") { row in
                guard let text = sqlite3_column_text(row, 0),
                      let page = URL(string: String(cString: text)), VisitHistory.isRecordable(page) else { return true }
                let title = sqlite3_column_text(row, 1).map { String(cString: $0) } ?? ""
                let visited = date(chromiumTime: sqlite3_column_int64(row, 3))
                records.append(VisitRecord(url: page, title: title, visitCount: max(1, Int(sqlite3_column_int(row, 2))),
                                           firstVisit: visited, lastVisit: visited))
                return records.count < limit
            }
            return records
        }
    }

    /// Visible pages, for the import preview; nil when it cannot be read.
    public static func pageCount(_ url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let snapshot = try? SQLiteSnapshot(copying: url) else { return nil }
        defer { snapshot.remove() }
        return try? withDatabase(snapshot.url) { db in
            var count = 0
            try query(db, "SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0") { row in
                count = Int(sqlite3_column_int64(row, 0))
                return false
            }
            return count
        }
    }

    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ReadError.cannotOpen
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    /// Steps `sql`'s rows while `row` returns true.
    static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Bool) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ReadError.notHistory
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if !row(statement) { break }
        }
    }
}

extension VisitHistory {
    /// Adds another browser's pages. A page already here keeps the higher
    /// visit count and the wider date range, so importing twice changes
    /// nothing. Returns how many pages were new.
    @discardableResult
    public mutating func merge(_ imported: [VisitRecord]) -> Int {
        var added = 0
        var merged = records
        for record in imported {
            guard let key = Self.key(for: record.url) else { continue }
            if var existing = merged[key] {
                existing.visitCount = max(existing.visitCount, record.visitCount)
                existing.firstVisit = min(existing.firstVisit, record.firstVisit)
                existing.lastVisit = max(existing.lastVisit, record.lastVisit)
                if existing.title.isEmpty { existing.title = record.title }
                merged[key] = existing
            } else {
                merged[key] = record
                added += 1
            }
        }
        if merged.count > Self.capacity {
            let kept = merged.sorted { $0.value.lastVisit > $1.value.lastVisit }.prefix(Self.capacity)
            merged = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        self = VisitHistory(records: Array(merged.values))
        return added
    }
}

/// A source profile's setup from its `Preferences`: the default search
/// engine and what opens at startup (PROFILE-IMPORT §4).
public struct ChromiumProfileSetup: Equatable, Sendable {
    public struct SearchEngine: Equatable, Sendable {
        public var name: String
        public var keyword: String
        public var searchURL: String
    }

    /// Chromium `session.restore_on_startup`.
    public enum Startup: Int, Equatable, Sendable {
        case restoreLastSession = 1
        case openURLs = 4
        case newTabPage = 5
    }

    public var searchEngine: SearchEngine?
    public var startup: Startup?
    public var startupPageCount = 0
    /// A theme from the Web Store (`extensions.theme.id`); it reinstalls as an extension.
    public var themeExtensionID: String?

    public init() {}

    public static func read(profile: URL) -> ChromiumProfileSetup {
        guard let data = try? Data(contentsOf: profile.appendingPathComponent("Preferences")) else { return ChromiumProfileSetup() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> ChromiumProfileSetup {
        var setup = ChromiumProfileSetup()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return setup }
        let provider = root["default_search_provider_data"] as? [String: Any]
        let template = (provider?["template_url_data"] ?? provider?["mirrored_template_url_data"]) as? [String: Any]
        if let template, let name = template["short_name"] as? String, !name.isEmpty {
            setup.searchEngine = SearchEngine(name: name, keyword: template["keyword"] as? String ?? "",
                                              searchURL: template["url"] as? String ?? "")
        }
        let session = root["session"] as? [String: Any]
        setup.startup = (session?["restore_on_startup"] as? Int).flatMap(Startup.init(rawValue:))
        setup.startupPageCount = (session?["startup_urls"] as? [Any])?.count ?? 0
        let theme = (root["extensions"] as? [String: Any])?["theme"] as? [String: Any]
        setup.themeExtensionID = (theme?["id"] as? String).flatMap { ExtensionInventoryReader.isExtensionID($0) ? $0 : nil }
        return setup
    }
}
