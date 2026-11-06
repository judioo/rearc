import Foundation

/// Horizontal (side-by-side) or vertical (stacked) split layout.
public enum SplitLayoutOrientation: String, Codable, CaseIterable, Equatable, Sendable {
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
    public var customIcon: SidebarItemIcon?
    /// The collection's name (Arc's split `customInfo` title); nil shows
    /// "N Tabs". Optional and written only when set, so older snapshots load.
    public var title: String?

    public init(
        id: UUID = UUID(),
        orientation: SplitLayoutOrientation,
        focusTabID: Tab.ID? = nil,
        widthFactors: [Tab.ID: Double] = [:],
        tabs: [Tab],
        memberPlacements: [Tab.ID: TabPlacement] = [:],
        sortRank: String = "",
        customIcon: SidebarItemIcon? = nil,
        title: String? = nil
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
        self.customIcon = customIcon
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, orientation, focusTabID, widthFactors, tabs, memberPlacements, sortRank, customIcon, title
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
        customIcon = try c.decodeIfPresent(SidebarItemIcon.self, forKey: .customIcon)
        title = try c.decodeIfPresent(String.self, forKey: .title)
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
        try c.encodeIfPresent(customIcon, forKey: .customIcon)
        try c.encodeIfPresent(title, forKey: .title)
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

/// A sidebar folder (Arc item type `list`): a titled, nestable container in a
/// space's pinned section. Children are plain tabs or further folders; split
/// views and easels stay at section level.
public struct SidebarFolder: Identifiable, Equatable, Codable {
    public let id: UUID
    public var title: String
    public var children: [SidebarEntry]
    public var sortRank: String
    public var customIcon: SidebarItemIcon?

    public init(id: UUID = UUID(), title: String, children: [SidebarEntry] = [], sortRank: String = "", customIcon: SidebarItemIcon? = nil) {
        self.id = id
        self.title = title
        self.children = children
        self.sortRank = sortRank
        self.customIcon = customIcon
    }
}

/// One row in a sidebar section: a plain tab, split item, easel reference, or folder.
public enum SidebarEntry: Identifiable, Equatable, Codable {
    case tab(Tab)
    case split(SplitViewItem)
    case easel(SidebarEaselRef)
    case folder(SidebarFolder)

    public var id: UUID {
        switch self {
        case .tab(let tab): return tab.id
        case .split(let split): return split.id
        case .easel(let ref): return ref.id
        case .folder(let folder): return folder.id
        }
    }

    public var customIcon: SidebarItemIcon? {
        get {
            switch self {
            case .tab(let tab): return tab.customIcon
            case .folder(let folder): return folder.customIcon
            case .split(let split): return split.customIcon
            case .easel(let ref): return ref.customIcon
            }
        }
        set {
            switch self {
            case .tab(var tab): tab.customIcon = newValue; self = .tab(tab)
            case .folder(var folder): folder.customIcon = newValue; self = .folder(folder)
            case .split(var split): split.customIcon = newValue; self = .split(split)
            case .easel(var ref): ref.customIcon = newValue; self = .easel(ref)
            }
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}
