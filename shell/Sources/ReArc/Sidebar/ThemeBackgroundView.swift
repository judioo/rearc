import AppKit
import SwiftUI
import SidebarModel

/// A theme drawn the way Arc's `WindowThemeBackgroundViewMetal` does
/// (THEMES.md §3): the OKLab gradient at its intensity over the underlay,
/// then the texture multiplied in at the grain amount. The gradient is
/// defined in UV space, so one small float render stretched to the view is
/// the shader's output up to bilinear interpolation.
struct ThemeLayerView: View {
    let theme: SpaceTheme
    let dark: Bool

    var body: some View {
        ZStack {
            Image(decorative: ThemeImageCache.image(for: ThemeGradient(theme: theme, dark: dark)), scale: 1)
                .resizable()
                .interpolation(.high)
            if theme.noise > 0 {
                // Multiply at alpha × grain: D · mix(1, texel, α), the shader's blend.
                Image(nsImage: ThemeTextureTiles.tile(theme.texture))
                    .resizable(resizingMode: .tile)
                    .opacity(theme.noise)
                    .blendMode(.multiply)
            }
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The window theme. A clicked or shortcut switch and every editor change
/// swap it between two frames with no blend, as Arc does
/// (ARC-RECORDING-ANALYSIS.md §2.9, §4). During a swipe the two spaces'
/// rendered themes mix per pixel by the pager's fraction (§3.7).
struct ThemeCrossfadeView: View {
    let theme: SpaceTheme
    let dark: Bool
    /// A swipe in progress: both themes and how far it has moved.
    var swipe: (from: SpaceTheme, to: SpaceTheme, fraction: Double)?
    var dark2: Bool?

    /// Wave 31 dissolved clicked switches over 0.35 s; Arc swaps in ≤ 1 frame.
    static let duration = 0.0

    var body: some View {
        ZStack {
            if let swipe {
                ThemeLayerView(theme: swipe.from, dark: dark)
                ThemeLayerView(theme: swipe.to, dark: dark2 ?? dark)
                    .opacity(swipe.fraction)
            } else {
                ThemeLayerView(theme: theme, dark: dark)
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// Rendered gradients, keyed by their exact inputs.
@MainActor
enum ThemeImageCache {
    /// Samples per side; the UV-space gradient is smooth, so this is plenty.
    static let side = 160
    private static var images: [ThemeGradient: CGImage] = [:]
    private static var order: [ThemeGradient] = []

    static func image(for gradient: ThemeGradient) -> CGImage {
        if let image = images[gradient] { return image }
        let image = render(gradient, width: side, height: side)
        images[gradient] = image
        order.append(gradient)
        if order.count > 48 { images[order.removeFirst()] = nil }
        return image
    }

    /// Float components in extended sRGB, so P3 stops are not clipped and
    /// pale gradients do not band before display.
    static func render(_ gradient: ThemeGradient, width: Int, height: Int) -> CGImage {
        var pixels = gradient.rgba(width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = pixels.withUnsafeMutableBytes { Data($0) }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: width * 16, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// The four textures as 200 pt tiles (400 px at 2x), tiled 1:1 in points
/// so the grain never scales with the window (§3.3).
@MainActor
enum ThemeTextureTiles {
    private static var tiles: [SpaceTexture: NSImage] = [:]

    static func tile(_ texture: SpaceTexture) -> NSImage {
        if let tile = tiles[texture] { return tile }
        let side = 400
        var pixels = ThemeTextureGenerator.rgba(texture, side: side)
        // NSBitmapImageRep wants premultiplied components.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            for c in 0 ..< 3 { pixels[index + c] = UInt8((Double(pixels[index + c]) * alpha).rounded()) }
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)!
        pixels.withUnsafeBufferPointer { rep.bitmapData!.update(from: $0.baseAddress!, count: $0.count) }
        rep.size = NSSize(width: side / 2, height: side / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        tiles[texture] = image
        return image
    }
}

/// One theme's chrome colours for the current appearance, as SwiftUI
/// colours. Sidebar text, glyphs, rows and separators read them from the
/// environment, so nothing on the theme is plain black or white.
struct ThemeChromeColors: Equatable {
    var title: Color
    var secondaryText: Color
    var tertiaryText: Color
    var glyph: Color
    var separator: Color
    /// Folder glyphs and accents (`foregroundPrimary`).
    var accent: Color
    var rowHover: Color
    var rowSelected: Color
    /// The other rows of a multi-row selection: Arc's grey veil, and the
    /// title fitted to read on it (`SidebarRowWash.multiSelected`).
    var rowMultiSelected: Color
    var multiSelectedTitle: Color
    /// Glyphs on that veil (a folder's; a mini square's split or easel glyph),
    /// fitted the same way (`SidebarRowWash.MultiSelected.glyph`).
    var multiSelectedAccent: Color
    var multiSelectedSecondaryText: Color
    var focus: Color
    /// Floating panels over the window (command bar, Peek): the theme's
    /// `backgroundExtra` / dark `background` washed over the material.
    var panel: Color
    /// Toasts: the theme's `background` role, a pale tint of the space colour.
    var toast: Color
    /// The command bar's selected row: the accent lightened toward white
    /// (`#2731FF` → `#858AFF` on the default theme, ARC-RECORDING-ANALYSIS.md §8).
    var selection: Color
    /// The command bar's selected row: `selection` darkened until white text
    /// on it clears 4.5:1 (`CommandBarInk.selectionFill`).
    var commandBarFill: SpaceColor
    /// The chrome's text roles are the dark ones (`ThemeGradient.usesDarkChrome`).
    var isDark: Bool
    /// The space is in dark appearance, whatever its chrome text uses.
    var isWindowDark: Bool
    /// The profile badge beside the space name and in the toolbar.
    var badge: SidebarBadgeInk
    /// The update notice's pill, warning ink and card (`UpdateNoticeInk`).
    var updateNotice: UpdateNoticeInk

    /// `dark` picks the chrome's roles; text and glyphs are then fitted to
    /// the sidebar's backdrop in the window's appearance (`backdrop`, by
    /// default the theme's own), so each clears its contrast floor.
    init(theme: SpaceTheme, dark: Bool, windowDark: Bool? = nil, backdrop: SidebarBackdrop? = nil) {
        let roles = SpaceThemeRoles(theme: theme)
        let semantic = roles.semantic(dark: dark)
        let backdrop = backdrop ?? SidebarBackdrop(theme: theme, dark: windowDark ?? dark)
        let chrome = roles.chrome(dark: dark).legible(on: backdrop, lightInk: dark)
        title = Color(chrome.title)
        secondaryText = Color(chrome.secondaryText)
        tertiaryText = Color(chrome.tertiaryText)
        glyph = Color(chrome.glyph)
        separator = Color(chrome.separator)
        accent = Color(chrome.accent)
        // Arc's selected row is near-white `backgroundExtra`; hover a lighter
        // wash of it (row geometry and fills are still to observe, §8).
        rowSelected = Color(semantic.backgroundExtra).opacity(SidebarRowWash.selectedAlpha(lightInk: dark))
        rowHover = Color(semantic.backgroundExtra).opacity(SidebarRowWash.hoverAlpha(lightInk: dark))
        // Sampled finely once: the veil can take an ink to its floor.
        let fine = SidebarBackdrop(theme: theme, dark: windowDark ?? dark, rows: 20, columns: 10)
        let multi = SidebarRowWash.multiSelected(title: chrome.title, backdrop: fine, lightInk: dark)
        rowMultiSelected = Color(multi.veil).opacity(multi.alpha)
        multiSelectedTitle = Color(multi.title)
        multiSelectedAccent = Color(multi.glyph(chrome.accent, backdrop: fine, lightInk: dark))
        multiSelectedSecondaryText = Color(multi.glyph(chrome.secondaryText, backdrop: fine, lightInk: dark))
        focus = Color(semantic.focus).opacity(semantic.focusAlpha)
        panel = Color(dark ? semantic.background : semantic.backgroundExtra).opacity(dark ? 0.6 : 0.55)
        toast = Color(semantic.background)
        selection = Color(Self.selection(accent: semantic.foregroundPrimary))
        commandBarFill = CommandBarInk.selectionFill(Self.selection(accent: semantic.foregroundPrimary))
        isDark = dark
        isWindowDark = windowDark ?? dark
        badge = SidebarBadgeInk(chrome: chrome, dark: dark)
        updateNotice = UpdateNoticeInk(backdrop: backdrop, lightInk: dark, accent: chrome.accent)
    }

    static let fallback = ThemeChromeColors(theme: .arcDefault, dark: false)

    /// 43.5 % of the way to white fits #2731FF → #858AFF to a level.
    static func selection(accent: SpaceColor) -> SpaceColor {
        accent.mixed(with: .white, fraction: 0.435)
    }
}

/// Two appearance variants per space. Theme edits replace only that space's
/// entry; selecting a tab or animating the pager does no gamut mapping.
final class SpaceThemeColorCache {
    private struct Entry {
        var theme: SpaceTheme
        var light: ThemeChromeColors?
        var dark: ThemeChromeColors?
    }
    private var entries: [Space.ID: Entry] = [:]
    private(set) var buildCount = 0

    func colors(for spaceID: Space.ID, theme: SpaceTheme, dark: Bool) -> ThemeChromeColors {
        if let entry = entries[spaceID], entry.theme == theme,
           let colors = dark ? entry.dark : entry.light { return colors }
        var entry = entries[spaceID].flatMap { $0.theme == theme ? $0 : nil } ?? Entry(theme: theme)
        let backdrop = SidebarBackdrop(theme: theme, dark: dark)
        let colors = ThemeChromeColors(theme: theme, dark: backdrop.prefersLightInk, windowDark: dark, backdrop: backdrop)
        buildCount += 1
        if dark { entry.dark = colors } else { entry.light = colors }
        entries[spaceID] = entry
        return colors
    }

    func retain(spaces: [Space]) {
        let ids = Set(spaces.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }
}

extension EnvironmentValues {
    @Entry var themeChrome: ThemeChromeColors = .fallback
}

extension Color {
    init(_ color: SpaceColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

/// Arc's "URL in toolbar" choice (`topBarURLEnabled`): the address and the
/// navigation buttons sit in a strip at the top of the page card. Off puts
/// them back at the top of the sidebar.
enum ToolbarURLPreference {
    static let key = "ReArcURLInToolbar"
    static let defaultValue = true
}
