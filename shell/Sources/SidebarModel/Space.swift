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

    /// Theme editor swatches: three rows of nine, after Arc's style editor
    /// pads (`ColorPickerPastel1..9`, `ColorPickerGreyscale1..9`,
    /// `ColorPickerDrab1..9`, SIDEBAR-SPEC §4.6). Values are ReArc's own.
    public static let editorPalette: [[SpaceTheme]] = [
        // Vivid
        [(0.45, 0.35, 0.90), (0.20, 0.60, 0.86), (0.25, 0.72, 0.55), (0.55, 0.78, 0.30), (0.95, 0.78, 0.25),
         (0.92, 0.55, 0.30), (0.88, 0.32, 0.32), (0.85, 0.35, 0.55), (0.65, 0.40, 0.85)],
        // Pastel
        [(0.72, 0.68, 0.95), (0.65, 0.82, 0.95), (0.66, 0.90, 0.80), (0.80, 0.92, 0.66), (0.98, 0.92, 0.66),
         (0.98, 0.80, 0.66), (0.96, 0.70, 0.70), (0.95, 0.72, 0.84), (0.85, 0.74, 0.95)],
        // Greyscale and drab
        [(0.95, 0.95, 0.96), (0.78, 0.78, 0.80), (0.55, 0.55, 0.60), (0.33, 0.33, 0.36), (0.15, 0.15, 0.17),
         (0.55, 0.50, 0.42), (0.45, 0.52, 0.42), (0.40, 0.47, 0.55), (0.52, 0.42, 0.48)],
    ].map { row in row.map { SpaceTheme(red: $0.0, green: $0.1, blue: $0.2) } }
}

public extension Space {
    /// SF Symbols offered by the space icon picker (emoji can be typed instead).
    static let iconChoices = [
        "house.fill", "briefcase.fill", "star.fill", "flame.fill", "leaf.fill", "moon.fill",
        "globe", "music.note", "book.fill", "graduationcap.fill", "gamecontroller.fill", "cart.fill",
        "heart.fill", "bolt.fill", "paintbrush.fill", "hammer.fill", "airplane", "camera.fill",
        "chart.bar.fill", "terminal.fill", "cup.and.saucer.fill", "pawprint.fill", "sun.max.fill", "circle.fill",
    ]

    /// SF Symbol names are lowercase ASCII words joined by dots; anything else
    /// (an emoji or a letter) is drawn as text.
    var iconIsSymbolName: Bool {
        Space.isSymbolName(iconName)
    }

    static func isSymbolName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }
    }
}

/// A Space is a named, themed workspace. Pinned and today tabs belong to a
/// single space; favorites belong to the space's profile and show in every
/// space of that profile.
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
