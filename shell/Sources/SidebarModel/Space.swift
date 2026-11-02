import Foundation

/// A space's color theme, stored as plain RGB components so the model layer
/// has no dependency on SwiftUI/AppKit colors.
public struct SpaceTheme: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let presets: [SpaceTheme] = [
        SpaceTheme(red: 0.45, green: 0.35, blue: 0.90), // indigo
        SpaceTheme(red: 0.20, green: 0.60, blue: 0.86), // sky
        SpaceTheme(red: 0.25, green: 0.72, blue: 0.55), // mint
        SpaceTheme(red: 0.92, green: 0.55, blue: 0.30), // ember
        SpaceTheme(red: 0.85, green: 0.35, blue: 0.55), // rose
        SpaceTheme(red: 0.55, green: 0.55, blue: 0.60), // graphite
    ]

    public static let `default`: SpaceTheme = presets[0]
}

/// A Space is a named, themed workspace. Pinned and today tabs belong to a
/// single space; favorites are global and shown in every space.
public struct Space: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var theme: SpaceTheme
    /// SF Symbol name used as the space's glyph in the switcher.
    public var iconName: String
    /// Persisted `itemContainer` ids for pinned / unpinned section roots.
    public var pinnedContainerID: UUID
    public var unpinnedContainerID: UUID
    /// Modifier on the unpinned container (`unpinned.shared` in Arc serialization).
    public var unpinnedShared: Bool
    /// Owning profile; every space belongs to exactly one profile.
    public var profileID: Profile.ID
    /// LexoRank position among spaces in the profile.
    public var sortRank: String

    public init(
        id: UUID = UUID(),
        name: String,
        theme: SpaceTheme = .default,
        iconName: String = "circle.fill",
        pinnedContainerID: UUID = UUID(),
        unpinnedContainerID: UUID = UUID(),
        unpinnedShared: Bool = false,
        profileID: Profile.ID? = nil,
        sortRank: String = ""
    ) {
        self.id = id
        self.name = name
        self.theme = theme
        self.iconName = iconName
        self.pinnedContainerID = pinnedContainerID
        self.unpinnedContainerID = unpinnedContainerID
        self.unpinnedShared = unpinnedShared
        self.profileID = profileID ?? UUID()
        self.sortRank = sortRank
    }

    enum CodingKeys: String, CodingKey {
        case id, name, theme, iconName
        case pinnedContainerID, unpinnedContainerID, unpinnedShared
        case profileID, sortRank
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        theme = try c.decode(SpaceTheme.self, forKey: .theme)
        iconName = try c.decode(String.self, forKey: .iconName)
        pinnedContainerID = try c.decodeIfPresent(UUID.self, forKey: .pinnedContainerID) ?? UUID()
        unpinnedContainerID = try c.decodeIfPresent(UUID.self, forKey: .unpinnedContainerID) ?? UUID()
        unpinnedShared = try c.decodeIfPresent(Bool.self, forKey: .unpinnedShared) ?? false
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID) ?? UUID()
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank) ?? ""
    }
}
