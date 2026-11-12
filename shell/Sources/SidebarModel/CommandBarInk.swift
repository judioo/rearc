import Foundation

/// The command bar card's colours. Arc's card is opaque and neutral over
/// every space theme (#F9F9F9 in light, 2026-11-12 recording); only the
/// selected row and a site search's chip take a colour. Every ink is fitted
/// to its floor on that surface, and the selected fill is darkened (OKLab
/// lightness, its own hue) until white text on it reads, which Arc's own
/// fill on a pale theme does not (#AE9D8D with white is 2.6:1).
public enum CommandBarInk {
    /// Arc's card, measured: #F9F9F9. Dark is ReArc's own (not observed).
    public static func surface(dark: Bool) -> SpaceColor {
        dark ? grey(0x2B) : grey(0xF9)
    }

    /// Titles and typed text (Arc's are near black, #1A1A1A–#272727).
    public static func primaryText(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0xF2) : grey(0x1C), dark: dark, floor: SidebarContrast.text)
    }

    /// Subtitles, hints ("Switch to Tab", "Search cushwake") and the
    /// placeholder. Arc's hint grey (#999) is 2.7:1; this one clears 4.5.
    public static func secondaryText(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0xA8) : grey(0x8A), dark: dark, floor: SidebarContrast.text)
    }

    /// The magnifier and row glyphs.
    public static func glyph(dark: Bool) -> SpaceColor {
        fit(dark ? grey(0x9A) : grey(0x8A), dark: dark, floor: SidebarContrast.glyph)
    }

    /// The line under the field (Arc #DDDDDD) and the card's hairline.
    public static func separator(dark: Bool) -> SpaceColor { dark ? grey(0x3D) : grey(0xDD) }

    /// An unselected keycap's fill (Arc #EBEBEB).
    public static func keycap(dark: Bool) -> SpaceColor { dark ? grey(0x3F) : grey(0xEB) }

    /// Text on the selected row and on a chip.
    public static let selectedText = SpaceColor.white

    /// `accent` darkened just enough for white text on it to clear 4.5:1.
    public static func selectionFill(_ accent: SpaceColor) -> SpaceColor {
        SidebarBackdrop(darkest: .white, lightest: .white).legible(accent.clamped, floor: SidebarContrast.text, lightInk: false)
    }

    /// The selected row on a space: its accent lightened as Arc's is
    /// (`#2731FF` → `#858AFF` on the default theme, 43.5 % toward white),
    /// then fitted for white text.
    public static func accentFill(theme: SpaceTheme, dark: Bool) -> SpaceColor {
        let accent = SpaceThemeRoles(theme: theme).semantic(dark: dark).foregroundPrimary
        return selectionFill(accent.mixed(with: .white, fraction: 0.435))
    }

    /// A site search's chip and selected row: the entry's or its favicon's
    /// colour, fitted for white text; the space's fill when the site has
    /// none or when it would vanish into the dark card.
    public static func siteFill(_ color: SpaceColor?, accentFill: SpaceColor, dark: Bool) -> SpaceColor {
        guard let color else { return accentFill }
        let fill = selectionFill(color)
        if dark, fill.contrast(with: surface(dark: true)) < 1.5 { return accentFill }
        return fill
    }

    /// The card washed with a site's colour as it collapses to the field
    /// (Arc: 17 % of the colour over the card, gone in ≈ 0.25 s).
    public static let collapseTint = 0.17

    private static func grey(_ value: Int) -> SpaceColor {
        let v = Double(value) / 255
        return SpaceColor(red: v, green: v, blue: v)
    }

    private static func fit(_ ink: SpaceColor, dark: Bool, floor: Double) -> SpaceColor {
        let card = surface(dark: dark)
        return SidebarBackdrop(darkest: card, lightest: card).legible(ink, floor: floor, lightInk: dark)
    }
}

/// A site's colour from its favicon (Arc `loadedSiteSearchDominantColor`):
/// the most common saturated colour, ignoring transparent, near-white,
/// near-black and grey pixels. Nil for a monochrome icon.
public enum FaviconColor {
    /// The colour's pixels must be at least this share of the opaque ones.
    public static let minimumShare = 0.08

    public static func dominant(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> SpaceColor? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, rgba.count >= bytesPerRow * (height - 1) + width * 4 else {
            return nil
        }
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Double>](repeating: .zero, count: 4096)
        var opaque = 0
        for y in 0 ..< height {
            var i = y * bytesPerRow
            for _ in 0 ..< width {
                defer { i += 4 }
                guard rgba[i + 3] >= 128 else { continue }
                opaque += 1
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 36, low < 232, high - low >= 40 else { continue }
                let bucket = (r >> 4) << 8 | (g >> 4) << 4 | b >> 4
                counts[bucket] += 1
                sums[bucket] += SIMD3(Double(r), Double(g), Double(b))
            }
        }
        guard opaque > 0, let best = counts.indices.max(by: { counts[$0] < counts[$1] }),
              counts[best] > 0, Double(counts[best]) >= minimumShare * Double(opaque) else { return nil }
        let mean = sums[best] / Double(counts[best]) / 255
        return SpaceColor(red: mean.x, green: mean.y, blue: mean.z)
    }
}
