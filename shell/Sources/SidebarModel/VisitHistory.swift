import Foundation

/// Command-bar visit history (pure, no UI imports). The engine C ABI has no
/// history query (WAVE-18-REPORT "Not claimed: command-bar history queries"),
/// so the shell records committed top-level navigations of sidebar tabs
/// itself, on both engines, and ranks them by match quality and frecency.
/// Private windows, peeks and Little Arc never record. On Chromium,
/// chrome://history (HistoryService) stays the full history UI; this store
/// only feeds command-bar suggestions.
public struct VisitRecord: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var firstVisit: Date
    public var lastVisit: Date

    public init(url: URL, title: String, visitCount: Int = 1, firstVisit: Date, lastVisit: Date? = nil) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.firstVisit = firstVisit
        self.lastVisit = lastVisit ?? firstVisit
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed
    }
}

public struct VisitHistory: Codable, Equatable, Sendable {
    public static let capacity = 5_000

    /// Keyed by `VisitHistory.key(for:)`.
    public private(set) var records: [String: VisitRecord]

    public init(records: [VisitRecord] = []) {
        var byKey: [String: VisitRecord] = [:]
        for record in records {
            guard let key = Self.key(for: record.url) else { continue }
            byKey[key] = record
        }
        self.records = byKey
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    public func record(for url: URL) -> VisitRecord? {
        Self.key(for: url).flatMap { records[$0] }
    }

    /// Only web pages are history: http(s) without credentials. about:, data:,
    /// file:, WebUI and view-source are not suggested.
    public static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    /// Scheme/host lowercased, fragment and a lone trailing slash dropped.
    public static func key(for url: URL) -> String? {
        guard isRecordable(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        return components.string
    }

    /// A new top-level visit to `url`.
    public mutating func recordVisit(url: URL, title: String?, at date: Date) {
        guard let key = Self.key(for: url) else { return }
        if var existing = records[key] {
            existing.visitCount += 1
            existing.lastVisit = date
            existing.url = url
            if let title, !title.isEmpty { existing.title = title }
            records[key] = existing
        } else {
            records[key] = VisitRecord(url: url, title: title ?? "", firstVisit: date)
            evictIfNeeded()
        }
    }

    /// The page's title arrived after its commit; not a new visit.
    public mutating func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let key = Self.key(for: url), records[key] != nil else { return }
        records[key]?.title = title
    }

    public mutating func remove(url: URL) {
        guard let key = Self.key(for: url) else { return }
        records[key] = nil
    }

    public mutating func removeAll() {
        records = [:]
    }

    private mutating func evictIfNeeded() {
        guard records.count > Self.capacity else { return }
        let overflow = records.count - Self.capacity
        let oldest = records.sorted { $0.value.lastVisit < $1.value.lastVisit }.prefix(overflow).map(\.key)
        for key in oldest { records[key] = nil }
    }

    // MARK: Ranking

    public struct Match: Equatable, Sendable {
        public var record: VisitRecord
        public var score: Double
    }

    /// Recency weight in the spirit of Firefox's frecency buckets.
    public static func recencyWeight(age: TimeInterval) -> Double {
        let days = age / 86_400
        switch days {
        case ..<1: return 100
        case ..<4: return 80
        case ..<14: return 60
        case ..<31: return 40
        case ..<90: return 20
        default: return 10
        }
    }

    public static func frecency(_ record: VisitRecord, now: Date) -> Double {
        recencyWeight(age: max(now.timeIntervalSince(record.lastVisit), 0)) * log2(Double(record.visitCount) + 1)
    }

    /// How well `needle` (lowercased, trimmed) matches: the host or URL start
    /// beats a title word start, which beats a substring. Every
    /// whitespace-separated token must match the title or URL. nil = no match.
    public static func matchQuality(_ record: VisitRecord, needle: String) -> Double? {
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return nil }
        let title = record.title.lowercased()
        let host = (record.url.host() ?? "").lowercased()
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let address = strippedAddress(record.url)
        for token in tokens where !title.contains(token) && !address.contains(token) {
            return nil
        }
        if bareHost.hasPrefix(first) || host.hasPrefix(first) { return 4 }
        if address.hasPrefix(first) { return 3.5 }
        let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if titleWords.contains(where: { $0.hasPrefix(first) }) { return 2.5 }
        if title.contains(first) { return 1.5 }
        return 1
    }

    /// The URL as typed: no scheme, no leading "www.".
    static func strippedAddress(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }

    /// Best matches for a command-bar needle, highest score first.
    public func matches(for needle: String, now: Date, limit: Int = 5, excluding excluded: Set<String> = []) -> [Match] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        var found: [Match] = []
        for (key, record) in records where !excluded.contains(key) {
            guard let quality = Self.matchQuality(record, needle: trimmed) else { continue }
            found.append(Match(record: record, score: quality * (Self.frecency(record, now: now) + 1)))
        }
        found.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.record.lastVisit != rhs.record.lastVisit { return lhs.record.lastVisit > rhs.record.lastVisit }
            return lhs.record.url.absoluteString < rhs.record.url.absoluteString
        }
        return Array(found.prefix(limit))
    }
}

/// Persists `VisitHistory` as JSON next to the sidebar file.
public enum VisitHistoryFile {
    public static let fileName = "History.json"

    private struct Payload: Codable {
        var version = 1
        var visits: [VisitRecord]
    }

    public static func load(from url: URL) -> VisitHistory {
        guard let data = try? Data(contentsOf: url) else { return VisitHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return VisitHistory() }
        return VisitHistory(records: payload.visits)
    }

    public static func save(_ history: VisitHistory, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let visits = history.records.values.sorted { $0.lastVisit > $1.lastVisit }
        let data = try encoder.encode(Payload(visits: visits))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Persists the downloads tray list and the default directory.
public enum DownloadListFile {
    public static let fileName = "Downloads.json"

    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var directory: String?
        /// "Ask where to save each file" (absent in files from before wave 22: off).
        public var askWhereToSave: Bool?
        public var list: DownloadList

        public init(directory: String? = nil, askWhereToSave: Bool? = nil, list: DownloadList = DownloadList()) {
            self.directory = directory
            self.askWhereToSave = askWhereToSave
            self.list = list
        }
    }

    public static func load(from url: URL) -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Contents.self, from: data)) ?? Contents()
    }

    public static func save(_ contents: Contents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
