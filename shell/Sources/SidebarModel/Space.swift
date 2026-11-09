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
    /// How strongly the colours cover the light underlay (Arc
    /// `modifiers.intensityFactor`, default 0.8; THEMES.md §3.2). Below 1 the
    /// theme reads as a milky tint.
    public var intensity: Double {
        didSet { intensity = Self.clampedIntensity(intensity) }
    }
    /// The texture the grain amount shows (`modifiers.overlay`).
    public var texture: SpaceTexture

    /// Arc's dial holds three colours.
    public static let maxGradientColors = 3
    public static let defaultIntensity = 0.8
    public static let intensityRange = 0.2 ... 1.0

    public init(
        red: Double,
        green: Double,
        blue: Double,
        gradientColors: [SpaceColor] = [],
        noise: Double = 0,
        appearance: SpaceAppearance = .automatic,
        intensity: Double = SpaceTheme.defaultIntensity,
        texture: SpaceTexture = .grain
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.gradientColors = Array(gradientColors.prefix(Self.maxGradientColors - 1))
        self.noise = Self.clampedNoise(noise)
        self.appearance = appearance
        self.intensity = Self.clampedIntensity(intensity)
        self.texture = texture
    }

    enum CodingKeys: String, CodingKey {
        case red, green, blue, gradientColors, noise, appearance, intensity, texture
    }

    /// Themes saved before wave 28 hold only `red`, `green` and `blue`. A
    /// space still on the pre-wave-31 default (plain indigo) takes the new
    /// Arc default, as a space without a stored theme does in Arc.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try c.decode(Double.self, forKey: .red),
            green: try c.decode(Double.self, forKey: .green),
            blue: try c.decode(Double.self, forKey: .blue),
            gradientColors: try c.decodeIfPresent([SpaceColor].self, forKey: .gradientColors) ?? [],
            noise: try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0,
            appearance: (try? c.decodeIfPresent(SpaceAppearance.self, forKey: .appearance)) ?? .automatic,
            intensity: try c.decodeIfPresent(Double.self, forKey: .intensity) ?? Self.defaultIntensity,
            texture: (try? c.decodeIfPresent(SpaceTexture.self, forKey: .texture)) ?? .grain
        )
        if self == Self.legacyDefault { self = Self.arcDefault }
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
        if intensity != Self.defaultIntensity { try c.encode(intensity, forKey: .intensity) }
        if texture != .grain { try c.encode(texture, forKey: .texture) }
    }

    private static func clampedNoise(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func clampedIntensity(_ value: Double) -> Double {
        value.isFinite ? min(max(value, intensityRange.lowerBound), intensityRange.upperBound) : defaultIntensity
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
        get {
            SpaceThemeStyle(gradientColors: gradientColors, noise: noise, appearance: appearance,
                            intensity: intensity, texture: texture)
        }
        set {
            gradientColors = newValue.gradientColors
            noise = newValue.noise
            appearance = newValue.appearance
            intensity = newValue.intensity
            texture = newValue.texture
        }
    }

    /// The colour a stop must hold so that, at the default intensity over
    /// white, it lands on `screen` (the shader composites in encoded sRGB).
    static func stop(onScreen screen: SpaceColor) -> SpaceColor {
        func stored(_ value: Double) -> Double { (value - (1 - defaultIntensity)) / defaultIntensity }
        return SpaceColor(red: stored(screen.red), green: stored(screen.green), blue: stored(screen.blue))
    }

    /// Arc's built-in theme for a space without one (THEMES.md §4.2):
    /// lavender `#D8D9F4` → pale pink `#F4E5E5` on screen, diagonal, no grain.
    public static let arcDefault: SpaceTheme = {
        let first = stop(onScreen: SpaceColor(hex: "#D8D9F4")!)
        return SpaceTheme(red: first.red, green: first.green, blue: first.blue,
                          gradientColors: [stop(onScreen: SpaceColor(hex: "#F4E5E5")!)])
    }()

    /// ReArc's default before wave 31.
    public static let legacyDefault = SpaceTheme(red: 0.45, green: 0.35, blue: 0.90)

    public static let presets: [SpaceTheme] = [
        arcDefault,
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

    /// Theme editor swatches: Arc's three pads of nine, measured from its
    /// asset catalog (`ColorPickerPastel1..9`, `ColorPickerGreyscale1..9`,
    /// `ColorPickerDrab1..9`; DESIGN-TOKENS §2.1).
    public static let editorPalette: [[SpaceTheme]] = [
        ["#FDFBFA", "#FBEAF3", "#ECD2EA", "#F7CDD2", "#FAE1D5", "#FEF9E7", "#E4FCEC", "#E0F2FB", "#C5C6E2"],
        ["#FFFFFF", "#E5E5E5", "#CCCCCC", "#B2B2B2", "#808080", "#666666", "#333333", "#1A1A1A", "#000000"],
        ["#4B3B58", "#623856", "#854444", "#A77048", "#D1B46A", "#CDCCA8", "#84A885", "#34604B", "#2D4468"],
    ].map { row in
        row.map { hex in
            let color = SpaceColor(hex: hex)!
            return SpaceTheme(red: color.red, green: color.green, blue: color.blue)
        }
    }

    /// The names of `editorPalette`'s rows.
    public static let editorPaletteNames = ["Pastel", "Greyscale", "Drab"]

    /// The editor's first swatch page as the user's recording shows it: nine
    /// saturated colours, none of them in the three catalog sets above
    /// (ARC-RECORDING-ANALYSIS.md §2.5; sampled from the video, ±3–5 levels).
    public static let editorVibrant: [SpaceTheme] = [
        "#EFE6E0", "#EF91B6", "#9D6794", "#EF5260", "#FE794C", "#F8CF4C", "#2AE48A", "#62B2D4", "#5A5C7C",
    ].map { hex in
        let color = SpaceColor(hex: hex)!
        return SpaceTheme(red: color.red, green: color.green, blue: color.blue)
    }

    /// The pages the editor's ‹ › arrows step through: the observed set first,
    /// then the three catalog sets (their place behind the arrows is inferred).
    public static let editorSwatchPages: [[SpaceTheme]] = [editorVibrant] + editorPalette
    public static let editorSwatchPageNames = ["Vibrant"] + editorPaletteNames
}

/// The part of a theme beyond its base colour. It syncs in its own record
/// (`SidebarSpaceStyleRecord`), so Macs on an older ReArc, which cannot
/// read it, never see it and so never write it back without it.
public struct SpaceThemeStyle: Hashable, Codable, Sendable {
    public var gradientColors: [SpaceColor]
    public var noise: Double
    public var appearance: SpaceAppearance
    public var intensity: Double
    public var texture: SpaceTexture

    public init(
        gradientColors: [SpaceColor] = [],
        noise: Double = 0,
        appearance: SpaceAppearance = .automatic,
        intensity: Double = SpaceTheme.defaultIntensity,
        texture: SpaceTexture = .grain
    ) {
        self.gradientColors = gradientColors
        self.noise = noise
        self.appearance = appearance
        self.intensity = intensity
        self.texture = texture
    }

    enum CodingKeys: String, CodingKey {
        case gradientColors, noise, appearance, intensity, texture
    }

    /// Records written before wave 31 have no intensity or texture.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gradientColors: try c.decodeIfPresent([SpaceColor].self, forKey: .gradientColors) ?? [],
            noise: try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0,
            appearance: (try? c.decodeIfPresent(SpaceAppearance.self, forKey: .appearance)) ?? .automatic,
            intensity: try c.decodeIfPresent(Double.self, forKey: .intensity) ?? SpaceTheme.defaultIntensity,
            texture: (try? c.decodeIfPresent(SpaceTexture.self, forKey: .texture)) ?? .grain
        )
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
    /// Arc's stable source identity and import ledger, including removed rows.
    public var arcSourceID: String? = nil
    public var arcImportedItemIDs: Set<UUID>? = nil
    public var arcItemMapping: [UUID: UUID]? = nil
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
    /// Boosts run in this space's tabs (Arc's per-space boost policy). Under
    /// the profile's master switch: off here wins, on defers to it.
    public var boostsEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        theme: SpaceTheme = .default,
        iconName: String = "circle.fill",
        pinnedContainerID: UUID = UUID(),
        unpinnedContainerID: UUID = UUID(),
        unpinnedShared: Bool = false,
        profileID: Profile.ID? = nil,
        sortRank: String = "",
        boostsEnabled: Bool = true
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
        self.boostsEnabled = boostsEnabled
    }

    enum CodingKeys: String, CodingKey {
        case arcSourceID, arcImportedItemIDs, arcItemMapping
        case id, name, theme, iconName
        case pinnedContainerID, unpinnedContainerID, unpinnedShared
        case profileID, sortRank, boostsEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arcItemMapping = try c.decodeIfPresent([UUID: UUID].self, forKey: .arcItemMapping)
        arcSourceID = try c.decodeIfPresent(String.self, forKey: .arcSourceID)
        arcImportedItemIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .arcImportedItemIDs)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        theme = try c.decode(SpaceTheme.self, forKey: .theme)
        iconName = try c.decode(String.self, forKey: .iconName)
        pinnedContainerID = try c.decodeIfPresent(UUID.self, forKey: .pinnedContainerID) ?? UUID()
        unpinnedContainerID = try c.decodeIfPresent(UUID.self, forKey: .unpinnedContainerID) ?? UUID()
        unpinnedShared = try c.decodeIfPresent(Bool.self, forKey: .unpinnedShared) ?? false
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID) ?? UUID()
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank) ?? ""
        boostsEnabled = try c.decodeIfPresent(Bool.self, forKey: .boostsEnabled) ?? true
    }

    /// `boostsEnabled` is written only when off, so a space encodes (and syncs) exactly as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(arcItemMapping, forKey: .arcItemMapping)
        try c.encodeIfPresent(arcSourceID, forKey: .arcSourceID)
        try c.encodeIfPresent(arcImportedItemIDs, forKey: .arcImportedItemIDs)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(theme, forKey: .theme)
        try c.encode(iconName, forKey: .iconName)
        try c.encode(pinnedContainerID, forKey: .pinnedContainerID)
        try c.encode(unpinnedContainerID, forKey: .unpinnedContainerID)
        try c.encode(unpinnedShared, forKey: .unpinnedShared)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(sortRank, forKey: .sortRank)
        if !boostsEnabled { try c.encode(false, forKey: .boostsEnabled) }
    }
}
