import Foundation
import SQLite3

/// The site searches in a Chromium profile's `Web Data` (SQLite `keywords`:
/// short_name, keyword, url with `{searchTerms}`), the same table for Chrome,
/// Brave and Arc. Arc's custom site searches ("cwc" › cushwake) live there.
/// Read from a copy; only `keywords` is selected, never the autofill, address
/// or card tables beside it. Only the person's own entries are taken: not
/// Chromium's prepopulated or starter-pack ones, not policy-made ones, not
/// ones the person switched off, and not the inactive ones Chromium makes by
/// itself from sites' OpenSearch files. Each template must pass
/// `SiteSearchTemplate.validated`.
public enum ChromiumKeywordsReader {
    public static let fileName = "Web Data"
    /// More rows than this are not one person's site searches.
    public static let maxRows = 500

    public enum ReadError: Error { case cannotOpen, notWebData }

    public struct Row: Equatable, Sendable {
        public var name: String
        public var keyword: String
        public var template: String
    }

    /// The profile's site searches, most used first.
    public static func read(_ url: URL) throws -> [Row] {
        let snapshot = try SQLiteSnapshot(copying: url)
        defer { snapshot.remove() }
        guard let db = ImportFile.openDatabase(snapshot.url) else { throw ReadError.cannotOpen }
        defer { sqlite3_close(db) }
        return try rows(db)
    }

    /// Site searches in `profile`'s Web Data; none when it has no such file.
    public static func read(profile: URL) -> [Row] {
        let file = profile.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return (try? read(file)) ?? []
    }

    static func rows(_ db: OpaquePointer) throws -> [Row] {
        let columns = try columnNames(db)
        guard ["short_name", "keyword", "url"].allSatisfy(columns.contains) else { throw ReadError.notWebData }
        // Each filter only where this Chromium's table has the column.
        var filters: [String] = []
        if columns.contains("prepopulate_id") { filters.append("prepopulate_id = 0") }
        if columns.contains("created_by_policy") { filters.append("created_by_policy = 0") }
        if columns.contains("starter_pack_id") { filters.append("starter_pack_id = 0") }
        // TemplateURLData::ActiveStatus: 1 true, 2 false, 0 unspecified (made by Chromium itself, inactive).
        if columns.contains("is_active") {
            filters.append("is_active != 2")
            if columns.contains("safe_for_autoreplace") { filters.append("(safe_for_autoreplace = 0 OR is_active = 1)") }
        } else if columns.contains("safe_for_autoreplace") {
            filters.append("safe_for_autoreplace = 0")
        }
        let order = columns.contains("usage_count") ? " ORDER BY usage_count DESC" : ""
        let sql = "SELECT short_name, keyword, url FROM keywords"
            + (filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")) + order + " LIMIT \(maxRows)"
        var rows: [Row] = []
        try step(db, sql) { row in
            func text(_ column: Int32) -> String { sqlite3_column_text(row, column).map { String(cString: $0) } ?? "" }
            rows.append(Row(name: text(0), keyword: text(1), template: text(2)))
        }
        return rows
    }

    static func columnNames(_ db: OpaquePointer) throws -> Set<String> {
        var names: Set<String> = []
        try step(db, "PRAGMA table_info(keywords)") { row in
            if let name = sqlite3_column_text(row, 1) { names.insert(String(cString: name)) }
        }
        guard !names.isEmpty else { throw ReadError.notWebData }
        return names
    }

    private static func step(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ReadError.notWebData
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }
}

/// Site searches brought from other browsers, per ReArc profile (the owning
/// profile: a container follows its parent's). Keywords, names and URL
/// templates only; a template that no longer validates is dropped on load.
/// Kept beside the visit history (`SiteSearches.json`), local to this Mac.
public struct ImportedSiteSearches: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var keyword: String
        public var template: String
        /// `ImportSourceProfile.id` ("arc/Default").
        public var sourceID: String
    }

    public static let fileName = "SiteSearches.json"
    /// Most entries kept for one profile.
    public static let capacity = 500

    public private(set) var byProfile: [UUID: [Entry]] = [:]

    public init() {}

    /// Adds `rows` from `sourceID` to `profileID`, skipping any whose
    /// template does not validate and any the profile already has (same
    /// keyword, or the same search page). Returns how many were new.
    @discardableResult
    public mutating func merge(_ rows: [ChromiumKeywordsReader.Row], from sourceID: String, into profileID: UUID) -> Int {
        var entries = byProfile[profileID] ?? []
        var keywords = Set(entries.map { $0.keyword.lowercased() })
        var pages = Set(entries.map { SiteSearchCatalog.pageKey($0.template) })
        var added = 0
        for row in rows where entries.count < Self.capacity {
            guard let engine = SiteSearchEngine(keywordRowID: "imported", name: row.name, keyword: row.keyword,
                                                template: row.template, source: .imported) else { continue }
            let keyword = engine.keyword ?? "", page = SiteSearchCatalog.pageKey(engine.template)
            guard !pages.contains(page), keyword.isEmpty || !keywords.contains(keyword) else { continue }
            entries.append(Entry(name: engine.name, keyword: keyword, template: engine.template, sourceID: sourceID))
            keywords.insert(keyword)
            pages.insert(page)
            added += 1
        }
        byProfile[profileID] = entries
        return added
    }

    /// `profileID`'s imported site searches, each validated again.
    public func engines(for profileID: UUID) -> [SiteSearchEngine] {
        (byProfile[profileID] ?? []).enumerated().compactMap { index, entry in
            SiteSearchEngine(keywordRowID: "imported-\(index)-\(entry.keyword)", name: entry.name, keyword: entry.keyword,
                             template: entry.template, source: .imported)
        }
    }

    /// How many of `rows` `merge` would add to `profileID`.
    public func newCount(_ rows: [ChromiumKeywordsReader.Row], into profileID: UUID) -> Int {
        var copy = self
        return copy.merge(rows, from: "", into: profileID)
    }

    public mutating func removeAll(for profileID: UUID) {
        byProfile[profileID] = nil
    }

    public static func load(from url: URL) -> ImportedSiteSearches {
        guard let data = try? ImportFile.data(url, maxBytes: 4 << 20),
              let decoded = try? JSONDecoder().decode(ImportedSiteSearches.self, from: data) else { return ImportedSiteSearches() }
        return decoded
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
