import Foundation

/// What earlier imports already brought, per source profile
/// (`ImportSourceProfile.id`), so importing a profile again brings only what
/// is new (the Arc sidebar keeps its own ledger on its spaces, and a
/// profile's bookmarks theirs on `Space.bookmarkSourceID`). Saved beside
/// the sidebar file.
public struct ImportLedger: Codable, Equatable, Sendable {
    public static let fileName = "import-ledger.json"

    /// The newest visit merged from each profile's history. Only pages
    /// visited after it are new: the command bar's history keeps
    /// `VisitHistory.capacity` pages, so asking it whether a page is there
    /// would bring old ones back every time.
    public var historyThrough: [String: Date] = [:]

    public init() {}

    /// The records not yet merged from `sourceID`.
    public func newHistory(_ records: [VisitRecord], from sourceID: String) -> [VisitRecord] {
        guard let through = historyThrough[sourceID] else { return records }
        return records.filter { $0.lastVisit > through }
    }

    /// Notes `records` from `sourceID` as merged.
    public mutating func recordHistory(_ records: [VisitRecord], from sourceID: String) {
        guard let newest = records.map(\.lastVisit).max() else { return }
        historyThrough[sourceID] = max(historyThrough[sourceID] ?? .distantPast, newest)
    }

    public static func load(from url: URL) -> ImportLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ImportLedger.self, from: data) else { return ImportLedger() }
        return ledger
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
