import Foundation

/// Snapshot of a tab at close time, used to reopen it later.
public struct ClosedTabRecord: Equatable, Codable {
    public var tab: Tab
    public var spaceID: Space.ID

    public init(tab: Tab, spaceID: Space.ID) {
        self.tab = tab
        self.spaceID = spaceID
    }
}

/// Per-profile stack of recently closed tabs (newest at end).
public struct ClosedTabStack: Equatable, Codable {
    public static let capacity = 25

    public var records: [ClosedTabRecord]

    public init(records: [ClosedTabRecord] = []) {
        self.records = records
    }

    public mutating func push(_ record: ClosedTabRecord) {
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    public mutating func popMostRecent() -> ClosedTabRecord? {
        guard !records.isEmpty else { return nil }
        return records.removeLast()
    }

    public var canReopen: Bool { !records.isEmpty }
}
