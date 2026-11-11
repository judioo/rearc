import Foundation

/// Where a closed tab sat, so ⇧⌘T can put it back among the same neighbours.
public enum ClosedTabPlacement: Equatable, Codable {
    case favorite(profileID: Profile.ID, index: Int)
    case section(ItemContainerKind.SpaceSection, index: Int)
    case folder(UUID, index: Int)
    /// A pane of a split; `index` is the split's place in its section.
    case splitPane(splitID: SplitViewItem.ID, paneIndex: Int, section: ItemContainerKind.SpaceSection, index: Int)
}

/// Snapshot of a tab at close time, used to reopen it later.
public struct ClosedTabRecord: Equatable, Codable {
    public var tab: Tab
    public var spaceID: Space.ID
    /// Nil in records saved before placements were kept (top of Today / end of Pinned).
    public var placement: ClosedTabPlacement?
    /// Set when a whole split was closed; reopening brings back every pane.
    public var split: SplitViewItem?
    /// Shared by the tabs one command closed together (a multi-row
    /// selection's ⌘W): ⇧⌘T reopens them together. Optional, so records
    /// saved before it decode, and older builds ignore it.
    public var batchID: UUID?

    public init(tab: Tab, spaceID: Space.ID, placement: ClosedTabPlacement? = nil, split: SplitViewItem? = nil, batchID: UUID? = nil) {
        self.tab = tab
        self.spaceID = spaceID
        self.placement = placement
        self.split = split
        self.batchID = batchID
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
