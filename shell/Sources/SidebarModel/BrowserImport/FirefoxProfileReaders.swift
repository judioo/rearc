import Foundation
import SQLite3

/// Firefox's `profiles.ini` (`~/Library/Application Support/Firefox`): one
/// `[ProfileN]` section per profile (Name, Path, IsRelative, Default), and
/// `[Install…]` sections naming each installation's default profile.
public enum FirefoxProfiles {
    public static let fileName = "profiles.ini"

    /// The default profile first (an install's, then `Default=1`), then the
    /// rest in file order; only those with a `places.sqlite`. A profile's
    /// `directory` is its `Path` as written. A `Path` that leads outside the
    /// Firefox folder (absolute, `..`, or through a link) is not a profile
    /// ReArc reads (RC-0.1.0-602 T-08).
    public static func read(root: URL, fileManager: FileManager = .default) -> [ImportSourceProfile] {
        guard let data = try? ImportFile.data(root.appendingPathComponent(fileName), maxBytes: 1 << 20),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text).compactMap { entry in
            let url = entry.isRelative ? root.appendingPathComponent(entry.path, isDirectory: true)
                : URL(fileURLWithPath: entry.path, isDirectory: true)
            guard isInside(url, root: root),
                  ImportFile.isRegularFile(url.appendingPathComponent(FirefoxPlacesReader.fileName), maxBytes: ImportFile.maxDatabaseBytes) else { return nil }
            return ImportSourceProfile(browser: .firefox, directory: entry.path, name: entry.name, url: url)
        }
    }

    /// `url`, with links and `..` resolved, is a folder inside `root`.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    struct Entry: Equatable {
        var name: String
        var path: String
        var isRelative: Bool
    }

    static func parse(_ text: String) -> [Entry] {
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !line.hasPrefix(";"), !line.hasPrefix("#"), !sections.isEmpty {
                sections[sections.count - 1].values[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        let installDefaults = sections.filter { $0.name.hasPrefix("Install") }.compactMap { $0.values["Default"] }
        var entries: [(entry: Entry, rank: Int)] = []
        for (index, section) in sections.enumerated() where section.name.hasPrefix("Profile") {
            guard let path = section.values["Path"], !path.isEmpty else { continue }
            let entry = Entry(name: section.values["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? path, path: path,
                              isRelative: section.values["IsRelative"] != "0")
            let rank = installDefaults.contains(path) ? 0 : section.values["Default"] == "1" ? 1 : 2
            entries.append((entry, rank * 10_000 + index))
        }
        return entries.sorted { $0.rank < $1.rank }.map(\.entry)
    }
}

/// A Firefox profile's `places.sqlite`: bookmarks (`moz_bookmarks` over
/// `moz_places`) and history (`moz_places` visit_count and
/// last_visit_date in microseconds since 1970, `moz_historyvisits`). Read
/// from a copy, with its `-wal`: Firefox holds it open while it runs.
public enum FirefoxPlacesReader {
    public static let fileName = "places.sqlite"
    /// More bookmark rows than any real profile has; the rest are not read.
    static let maxBookmarkRows = 500_000

    /// The toolbar's contents at the top level, then the Bookmarks Menu,
    /// Other Bookmarks and Mobile Bookmarks as folders. Tags are not bookmarks.
    public static func bookmarks(_ url: URL) throws -> [BookmarkNode] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        struct Row { var type: Int32; var title: String; var url: String? }
        var rows: [Int64: Row] = [:]
        var children: [Int64: [Int64]] = [:]
        var roots: [String: Int64] = [:]
        try ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            let sql = "SELECT b.id, b.type, b.parent, b.title, p.url, b.guid FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position LIMIT \(maxBookmarkRows)"
            try ChromiumHistoryReader.query(db, sql) { row in
                let id = sqlite3_column_int64(row, 0)
                rows[id] = Row(type: sqlite3_column_int(row, 1),
                               title: sqlite3_column_text(row, 3).map { String(cString: $0) } ?? "",
                               url: sqlite3_column_text(row, 4).map { String(cString: $0) })
                children[sqlite3_column_int64(row, 2), default: []].append(id)
                if let guid = sqlite3_column_text(row, 5) { roots[String(cString: guid)] = id }
                return true
            }
        }
        var builder = BookmarkTreeBuilder()
        var visited = Set<Int64>()
        func nodes(_ parent: Int64, depth: Int) -> [BookmarkNode] {
            var out: [BookmarkNode] = []
            for id in children[parent] ?? [] where visited.insert(id).inserted {
                guard let row = rows[id] else { continue }
                switch row.type {
                case 1:
                    if let link = builder.link(title: row.title, href: row.url) { out.append(link) }
                case 2:
                    // A chain deeper than `maxWalkDepth` is not walked: one level is one stack frame (T-08).
                    guard depth < BookmarkTreeBuilder.maxWalkDepth else { break }
                    out += builder.folder(title: row.title, children: nodes(id, depth: depth + 1), depth: depth)
                default:
                    break
                }
            }
            return out
        }
        var result = roots["toolbar_____"].map { nodes($0, depth: 0) } ?? []
        for (guid, title) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            guard let id = roots[guid] else { continue }
            let inner = nodes(id, depth: 1)
            if !inner.isEmpty { result.append(.folder(title: title, children: inner)) }
        }
        return BookmarkHTMLImport.pruned(result)
    }

    static func date(firefoxTime: Int64) -> Date { Date(timeIntervalSince1970: Double(firefoxTime) / 1_000_000) }

    /// The most recently visited web pages, newest first, at most `limit`.
    public static func history(_ url: URL, limit: Int = VisitHistory.capacity) throws -> [VisitRecord] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        return try ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            var records: [VisitRecord] = []
            let sql = """
                SELECT p.url, p.title, p.visit_count, p.last_visit_date,
                       (SELECT MIN(v.visit_date) FROM moz_historyvisits v WHERE v.place_id = p.id)
                FROM moz_places p WHERE p.hidden = 0 AND p.visit_count > 0 AND p.last_visit_date IS NOT NULL
                ORDER BY p.last_visit_date DESC
                """
            try ChromiumHistoryReader.query(db, sql) { row in
                guard let text = sqlite3_column_text(row, 0),
                      let page = URL(string: String(cString: text)), VisitHistory.isRecordable(page) else { return true }
                let title = sqlite3_column_text(row, 1).map { String(cString: $0) } ?? ""
                let last = date(firefoxTime: sqlite3_column_int64(row, 3))
                let first = sqlite3_column_type(row, 4) == SQLITE_NULL ? last : date(firefoxTime: sqlite3_column_int64(row, 4))
                records.append(VisitRecord(url: page, title: title, visitCount: max(1, Int(sqlite3_column_int(row, 2))),
                                           firstVisit: min(first, last), lastVisit: last))
                return records.count < limit
            }
            return records
        }
    }

    /// Visible pages, for the import preview; with `after`, only those visited since.
    public static func pageCount(_ url: URL, after: Date? = nil) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let snapshot = try? SQLiteSnapshot(copying: url) else { return nil }
        defer { snapshot.remove() }
        let since = after.map { " AND last_visit_date > \(Int64($0.timeIntervalSince1970 * 1_000_000) + 1)" } ?? ""
        return try? ChromiumHistoryReader.withDatabase(snapshot.url) { db in
            var count = 0
            try ChromiumHistoryReader.query(db, "SELECT COUNT(*) FROM moz_places WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL" + since) { row in
                count = Int(sqlite3_column_int64(row, 0))
                return false
            }
            return count
        }
    }
}
