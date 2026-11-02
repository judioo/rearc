import Foundation

/// Identifies a persisted sidebar section root (mirrors Arc `itemContainer` cases).
public enum ItemContainerKind: Equatable, Codable {
    case topApps
    case spaceItems(spaceID: Space.ID, section: SpaceSection)

    public enum SpaceSection: String, Codable, CaseIterable {
        case pinned
        case unpinned
    }
}

/// Ordered child IDs for one container node in snapshot v2.
public struct ItemContainerRecord: Equatable, Codable {
    public var id: UUID
    public var kind: ItemContainerKind
    public var childIDs: [UUID]
    /// When `kind` is unpinned space items, marks shared unpinned spaces.
    public var unpinnedShared: Bool

    public init(
        id: UUID = UUID(),
        kind: ItemContainerKind,
        childIDs: [UUID] = [],
        unpinnedShared: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.childIDs = childIDs
        self.unpinnedShared = unpinnedShared
    }
}
