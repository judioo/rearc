import Foundation

/// The profile badge beside a space's name and in the sidebar toolbar. It
/// used to be a white glyph on the profile's own colour, which vanished
/// whenever that colour was close to the space theme (a blue profile on a
/// blue space). The badge now takes the chrome's glyph on a neutral disc
/// that contrasts with it, plus a glyph-coloured outline so the disc still
/// has an edge on a sidebar of the same lightness.
public struct SidebarBadgeInk: Hashable, Sendable {
    public var glyph: SpaceColor
    public var disc: SpaceColor
    public var discAlpha: Double
    public var outlineAlpha: Double

    /// `dark` is whether the sidebar uses the dark chrome roles (light glyphs).
    public init(chrome: ThemeChromePalette, dark: Bool) {
        glyph = chrome.glyph
        disc = dark ? .black : .white
        discAlpha = dark ? 0.75 : 0.9
        outlineAlpha = 0.65
    }

    /// The disc as drawn over `background`.
    public func disc(over background: SpaceColor) -> SpaceColor {
        background.mixed(with: disc, fraction: discAlpha)
    }

    /// The outline ring as drawn over `background`.
    public func outline(over background: SpaceColor) -> SpaceColor {
        background.mixed(with: glyph, fraction: outlineAlpha)
    }
}
