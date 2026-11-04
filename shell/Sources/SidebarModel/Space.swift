import Foundation

/// One colour stop of a gradient theme (plain sRGB components).
public struct SpaceColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A space's light or dark look (Arc's style editor Appearance:
/// `automaticMode`, `lightMode`, `darkMode`; DESIGN-TOKENS §2.8). The
/// window follows it, and so do pages, easels and notes in it.
public enum SpaceAppearance: String, Codable, CaseIterable, Sendable {
    case automatic
    case light
    case dark

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Dark for `.dark`, light for `.light`, otherwise the system's choice.
    public func isDark(systemDark: Bool) -> Bool {
        switch self {
        case .automatic: return systemDark
        case .light: return false
        case .dark: return true
        }
    }
}

/// A space's theme: a base colour, up to two more gradient stops (Arc
/// `blendedGradient.baseColors`; one colour is `blendedSingleColor`), a
/// grain amount (`modifiers.noiseFactor`) and an appearance (SIDEBAR-SPEC
/// §4.6, DATA-SCHEMA `WindowTheme`). Stored as plain RGB so the model layer
/// has no dependency on SwiftUI/AppKit colors.
public struct SpaceTheme: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// Further gradient stops after the base colour, at most `maxGradientColors - 1`.
    public var gradientColors: [SpaceColor] {
        didSet { gradientColors = Array(gradientColors.prefix(Self.maxGradientColors - 1)) }
    }
    /// Grain over the background, 0 (none) to 1.
    public var noise: Double {
        didSet { noise = Self.clampedNoise(noise) }
    }
    public var appearance: SpaceAppearance

    /// Arc's dial holds three colours.
    public static let maxGradientColors = 3

    public init(
        red: Double,
        green: Double,
        blue: Double,
        gradientColors: [SpaceColor] = [],
        noise: Double = 0,
        appearance: SpaceAppearance = .automatic
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.gradientColors = Array(gradientColors.prefix(Self.maxGradientColors - 1))
        self.noise = Self.clampedNoise(noise)
        self.appearance = appearance
    }

    enum CodingKeys: String, CodingKey {
        case red, green, blue, gradientColors, noise, appearance
    }

    /// Themes saved before wave 28 hold only `red`, `green` and `blue`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try c.decode(Double.self, forKey: .red),
            green: try c.decode(Double.self, forKey: .green),
            blue: try c.decode(Double.self, forKey: .blue),
            gradientColors: try c.decodeIfPresent([SpaceColor].self, forKey: .gradientColors) ?? [],
            noise: try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0,
            appearance: (try? c.decodeIfPresent(SpaceAppearance.self, forKey: .appearance)) ?? .automatic
        )
    }

    /// The style keys are written only when set, so a plain colour theme
    /// encodes exactly as before wave 28.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(red, forKey: .red)
        try c.encode(green, forKey: .green)
        try c.encode(blue, forKey: .blue)
        if !gradientColors.isEmpty { try c.encode(gradientColors, forKey: .gradientColors) }
        if noise != 0 { try c.encode(noise, forKey: .noise) }
        if appearance != .automatic { try c.encode(appearance, forKey: .appearance) }
    }

    private static func clampedNoise(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    /// The base colour alone, with no gradient, grain or appearance.
    public var baseColor: SpaceTheme { SpaceTheme(red: red, green: green, blue: blue) }

    /// Every stop in order, the base colour first.
    public var stops: [SpaceTheme] {
        [baseColor] + gradientColors.map { SpaceTheme(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    public var isGradient: Bool { !gradientColors.isEmpty }

    /// Same style with another base colour (a swatch or the colour well).
    public func withBaseColor(_ color: SpaceTheme) -> SpaceTheme {
        var theme = self
        theme.red = color.red
        theme.green = color.green
        theme.blue = color.blue
        return theme
    }

    /// The gradient, grain and appearance alone (what the style sync record carries).
    public var style: SpaceThemeStyle {
        get { SpaceThemeStyle(gradientColors: gradientColors, noise: noise, appearance: appearance) }
        set {
            gradientColors = newValue.gradientColors
            noise = newValue.noise
            appearance = newValue.appearance
        }
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

    /// Gradient presets for the editor (ReArc's own pairings in the spirit
    /// of Arc's dial).
    public static let gradientPresets: [SpaceTheme] = [
        SpaceTheme(red: 0.45, green: 0.35, blue: 0.90, gradientColors: [SpaceColor(red: 0.90, green: 0.40, blue: 0.70)]),
        SpaceTheme(red: 0.20, green: 0.60, blue: 0.86, gradientColors: [SpaceColor(red: 0.30, green: 0.85, blue: 0.70)]),
        SpaceTheme(red: 0.95, green: 0.55, blue: 0.30, gradientColors: [SpaceColor(red: 0.90, green: 0.30, blue: 0.45)]),
        SpaceTheme(red: 0.25, green: 0.72, blue: 0.55, gradientColors: [SpaceColor(red: 0.95, green: 0.85, blue: 0.35)]),
        SpaceTheme(red: 0.65, green: 0.40, blue: 0.85, gradientColors: [
            SpaceColor(red: 0.30, green: 0.55, blue: 0.95), SpaceColor(red: 0.40, green: 0.85, blue: 0.80),
        ]),
        SpaceTheme(red: 0.15, green: 0.15, blue: 0.20, gradientColors: [SpaceColor(red: 0.40, green: 0.30, blue: 0.55)]),
    ]

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

/// The part of a theme beyond its base colour. It syncs in its own record
/// (`SidebarSpaceStyleRecord`), so Macs on an older ReArc, which cannot
/// read it, never see it and so never write it back without it.
public struct SpaceThemeStyle: Hashable, Codable, Sendable {
    public var gradientColors: [SpaceColor]
    public var noise: Double
    public var appearance: SpaceAppearance

    public init(gradientColors: [SpaceColor] = [], noise: Double = 0, appearance: SpaceAppearance = .automatic) {
        self.gradientColors = gradientColors
        self.noise = noise
        self.appearance = appearance
    }

    public var isDefault: Bool { self == SpaceThemeStyle() }
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
