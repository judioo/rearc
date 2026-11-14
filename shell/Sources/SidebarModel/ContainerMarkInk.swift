import Foundation

/// How a container shows on its space's icon and profile avatar: a ring
/// around them and a badge at their corner, in the container's colour. A
/// container takes its space's colour when it is made, which is the tint of
/// the sidebar it is then drawn on, so the colour as it is vanished there
/// (an 11 pt disc of the sidebar's own hue). The mark therefore takes the
/// colour fitted to what is under it: kept where it already reads, else
/// moved in lightness only, at its own hue and chroma, to the glyph floor.
public struct ContainerMarkInk: Hashable, Sendable {
    /// The ring and the badge's disc.
    public var tint: SpaceColor
    /// The badge's symbol on its disc: white where that clears the glyph
    /// floor, as on the chip's saturated colours, else black.
    public var glyph: SpaceColor

    /// `backdrop` is what the mark is drawn on, and `lightInk` the side its
    /// chrome reads on (`SidebarBackdrop.prefersLightInk`): a colour that
    /// has to move goes that way, so the ring sits with the icons beside it.
    public init(container: SpaceColor, backdrop: SidebarBackdrop, lightInk: Bool) {
        let floor = SidebarContrast.glyph
        // Lighter than the lightest spot or darker than the darkest, either reads.
        let reads = max(backdrop.contrast(of: container, lightInk: true), backdrop.contrast(of: container, lightInk: false)) >= floor
        tint = reads ? container.clamped : backdrop.legible(container, floor: floor, lightInk: lightInk)
        glyph = tint.contrast(with: .white) >= floor ? .white : .black
    }

    /// Off the sidebar (Settings, the Spaces list, Little ReArc's toolbar):
    /// a window's own background in one appearance, a popover's included.
    public init(container: SpaceColor, windowDark: Bool) {
        self.init(container: container, backdrop: Self.window(dark: windowDark), lightInk: windowDark)
    }

    /// Window and popover backgrounds: #ECECEC to white, #1E1E1E to #323232.
    public static func window(dark: Bool) -> SidebarBackdrop {
        func grey(_ level: Double) -> SpaceColor { SpaceColor(red: level, green: level, blue: level) }
        return dark ? SidebarBackdrop(darkest: grey(0.118), lightest: grey(0.196))
                    : SidebarBackdrop(darkest: grey(0.925), lightest: grey(1))
    }
}
