import Foundation

/// Horizontal (side-by-side) or vertical (stacked) split layout.
public enum SplitLayoutOrientation: String, Codable, CaseIterable, Equatable {
    case horizontal
    case vertical
}

/// A split-view sidebar item: 2–4 plain tabs, no nested splits.
public struct SplitViewItem: Identifiable, Equatable, Codable {
    public let id: UUID
    public var orientation: SplitLayoutOrientation
    public var focusTabID: Tab.ID
    /// Per-pane width/height ratios; normalized to sum 1 when persisted.
    public var widthFactors: [Tab.ID: Double]
    public var tabs: [Tab]
    /// Where member tabs return on unsplit (section + index at split creation).
    public var memberPlacements: [Tab.ID: TabPlacement]
    public var sortRank: String

    public init(
        id: UUID = UUID(),
        orientation: SplitLayoutOrientation,
        focusTabID: Tab.ID? = nil,
        widthFactors: [Tab.ID: Double] = [:],
        tabs: [Tab],
        memberPlacements: [Tab.ID: TabPlacement] = [:],
        sortRank: String = ""
    ) {
        precondition((2 ... 4).contains(tabs.count))
        self.id = id
        self.orientation = orientation
        self.focusTabID = focusTabID ?? tabs[0].id
        self.tabs = tabs
        self.memberPlacements = memberPlacements
        if widthFactors.isEmpty {
            let equal = 1.0 / Double(tabs.count)
            self.widthFactors = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, equal) })
        } else {
            self.widthFactors = SplitViewItem.normalizedFactors(widthFactors, tabIDs: tabs.map(\.id))
        }
        self.sortRank = sortRank
    }

    enum CodingKeys: String, CodingKey {
        case id, orientation, focusTabID, widthFactors, tabs, memberPlacements, sortRank
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        orientation = try c.decode(SplitLayoutOrientation.self, forKey: .orientation)
        let decodedTabs = try c.decode([Tab].self, forKey: .tabs)
        tabs = decodedTabs
        focusTabID = try c.decodeIfPresent(Tab.ID.self, forKey: .focusTabID) ?? decodedTabs[0].id
        widthFactors = try c.decodeIfPresent([Tab.ID: Double].self, forKey: .widthFactors) ?? [:]
        memberPlacements = try c.decodeIfPresent([Tab.ID: TabPlacement].self, forKey: .memberPlacements) ?? [:]
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank) ?? ""
        if widthFactors.isEmpty {
            let equal = 1.0 / Double(tabs.count)
            widthFactors = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, equal) })
        } else {
            widthFactors = SplitViewItem.normalizedFactors(widthFactors, tabIDs: tabs.map(\.id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(orientation, forKey: .orientation)
        try c.encode(focusTabID, forKey: .focusTabID)
        try c.encode(widthFactors, forKey: .widthFactors)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(memberPlacements, forKey: .memberPlacements)
        try c.encode(sortRank, forKey: .sortRank)
    }

    public static func normalizedFactors(
        _ factors: [Tab.ID: Double],
        tabIDs: [Tab.ID]
    ) -> [Tab.ID: Double] {
        let raw = tabIDs.map { max(factors[$0] ?? 0, 0) }
        let sum = raw.reduce(0, +)
        guard sum > 0 else {
            let equal = 1.0 / Double(tabIDs.count)
            return Dictionary(uniqueKeysWithValues: tabIDs.map { ($0, equal) })
        }
        return Dictionary(uniqueKeysWithValues: zip(tabIDs, raw.map { $0 / sum }))
    }
}

/// Section membership for a tab (favorites use the global top-apps container).
public enum TabPlacement: Equatable, Codable {
    case favorite(index: Int)
    case pinned(spaceID: Space.ID, index: Int)
    case today(spaceID: Space.ID, index: Int)
}

/// One row in a sidebar section: a plain tab, split item, or easel reference.
public enum SidebarEntry: Identifiable, Equatable, Codable {
    case tab(Tab)
    case split(SplitViewItem)
    case easel(SidebarEaselRef)

    public var id: UUID {
        switch self {
        case .tab(let tab): return tab.id
        case .split(let split): return split.id
        case .easel(let ref): return ref.id
        }
    }
}
