import Foundation
import SQLite3

/// Builds `BookmarkNode` trees from other browsers' bookmark stores under
/// the HTML import's limits: http(s) links without credentials
/// (`VisitHistory.isRecordable`), `BookmarkHTMLImport.maxLinks` of them,
/// `maxDepth` levels (deeper folders' links join their parent).
struct BookmarkTreeBuilder {
    private(set) var links = 0

    mutating func link(title: String, href: String?) -> BookmarkNode? {
        guard links < BookmarkHTMLImport.maxLinks, let href, let url = URL(string: href),
              VisitHistory.isRecordable(url) else { return nil }
        links += 1
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .link(title: title.isEmpty ? (url.host() ?? href) : title, url: url)
    }

    func folder(title: String, children: [BookmarkNode], depth: Int) -> [BookmarkNode] {
        guard depth < BookmarkHTMLImport.maxDepth else { return children }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.folder(title: title.isEmpty ? "Folder" : title, children: children)]
    }
}

/// Safari's `Bookmarks.plist` (`~/Library/Safari`, Full Disk Access): the
/// Favorites bar at the top level, then the Bookmarks menu, other top-level
/// folders and the Reading List as folders. History is a proxy, not a list.
public enum SafariBookmarksReader {
    public static let fileName = "Bookmarks.plist"
    static let bar = "BookmarksBar"
    static let menu = "BookmarksMenu"
    static let readingList = "com.apple.ReadingList"

    public enum ReadError: Error { case notBookmarks }

    public static func read(_ url: URL) throws -> [BookmarkNode] {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let top = root["Children"] as? [Any] else { throw ReadError.notBookmarks }
        var builder = BookmarkTreeBuilder()
        func nodes(_ children: Any?, depth: Int) -> [BookmarkNode] {
            var out: [BookmarkNode] = []
            for case let child as [String: Any] in children as? [Any] ?? [] {
                switch child["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                    if let link = builder.link(title: title, href: child["URLString"] as? String) { out.append(link) }
                case "WebBookmarkTypeList":
                    let inner = nodes(child["Children"], depth: depth + 1)
                    out += builder.folder(title: child["Title"] as? String ?? "", children: inner, depth: depth)
                default:
                    break
                }
            }
            return out
        }
        let lists = top.compactMap { $0 as? [String: Any] }.filter { $0["WebBookmarkType"] as? String == "WebBookmarkTypeList" }
        func list(_ title: String) -> [String: Any]? { lists.first { $0["Title"] as? String == title } }
        var result = nodes(list(bar)?["Children"], depth: 0)
        func add(_ children: Any?, as title: String) {
            let inner = nodes(children, depth: 1)
            if !inner.isEmpty { result.append(.folder(title: title, children: inner)) }
        }
        add(list(menu)?["Children"], as: "Bookmarks Menu")
        for other in lists where ![bar, menu, readingList].contains(other["Title"] as? String ?? "") {
            add(other["Children"], as: other["Title"] as? String ?? "Folder")
        }
        add(list(readingList)?["Children"], as: "Reading List")
        return BookmarkHTMLImport.pruned(result)
    }
}

/// Safari's `History.db` (SQLite: `history_items` url and visit_count,
/// `history_visits` visit_time in seconds since 2001 and title). Read from a
/// copy, like Chromium's History.
public enum SafariHistoryReader {
    public static let fileName = "History.db"

    /// The most recently visited web pages, newest first, at most `limit`;
    /// each titled as it was at its last visit.
    public static func read(_ url: URL, limit: Int = VisitHistory.capacity) throws -> [VisitRecord] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        return try ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            var records: [VisitRecord] = []
            let sql = """
                SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id ORDER BY v2.visit_time DESC LIMIT 1),
                       i.visit_count, MIN(v.visit_time), MAX(v.visit_time)
                FROM history_items i JOIN history_visits v ON v.history_item = i.id
                WHERE i.visit_count > 0 GROUP BY i.id ORDER BY MAX(v.visit_time) DESC
                """
            try ChromiumHistoryReader.query(db, sql) { row in
                guard let text = sqlite3_column_text(row, 0),
                      let page = URL(string: String(cString: text)), VisitHistory.isRecordable(page) else { return true }
                let title = sqlite3_column_text(row, 1).map { String(cString: $0) } ?? ""
                records.append(VisitRecord(url: page, title: title, visitCount: max(1, Int(sqlite3_column_int(row, 2))),
                                           firstVisit: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 3)),
                                           lastVisit: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 4))))
                return records.count < limit
            }
            return records
        }
    }

    /// Visited pages, for the import preview; with `after`, only those visited since.
    public static func pageCount(_ url: URL, after: Date? = nil) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let snapshot = try? SQLiteSnapshot(copying: url) else { return nil }
        defer { snapshot.remove() }
        let since = after.map {
            " AND id IN (SELECT history_item FROM history_visits WHERE visit_time > \($0.timeIntervalSinceReferenceDate + 0.000_001))"
        } ?? ""
        return try? ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            var count = 0
            try ChromiumHistoryReader.query(db, "SELECT COUNT(*) FROM history_items WHERE visit_count > 0" + since) { row in
                count = Int(sqlite3_column_int64(row, 0))
                return false
            }
            return count
        }
    }
}
