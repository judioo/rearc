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

/// A window theme that dissolves from one fully rendered theme into the
/// next (§3.7): the old one stays opaque underneath while the new one fades
/// in over it, so every frame is a per-pixel mix, not a dimmed overlap.
/// During a swipe the mix follows the finger instead.
struct ThemeCrossfadeView: View {
    let theme: SpaceTheme
    let dark: Bool
    /// A swipe in progress: both themes and how far it has moved.
    var swipe: (from: SpaceTheme, to: SpaceTheme, fraction: Double)?
    var dark2: Bool?

    @State private var previous: ThemeKey?
    @State private var progress = 1.0

    struct ThemeKey: Equatable {
        var theme: SpaceTheme
        var dark: Bool
    }

    /// Arc's clicked-switch duration is unmeasured (§8); 0.35 s ease-in-out.
    static let duration = 0.35

    var body: some View {
        ZStack {
            if let swipe {
                ThemeLayerView(theme: swipe.from, dark: dark)
                ThemeLayerView(theme: swipe.to, dark: dark2 ?? dark)
                    .opacity(swipe.fraction)
            } else {
                if let previous, progress < 1 {
                    ThemeLayerView(theme: previous.theme, dark: previous.dark)
                }
                ThemeLayerView(theme: theme, dark: dark)
                    .opacity(previous == nil ? 1 : progress)
            }
        }
        .onChange(of: ThemeKey(theme: theme, dark: dark)) { old, _ in
            guard swipe == nil else { return }
            previous = old
            progress = 0
            withAnimation(.easeInOut(duration: Self.duration)) {
                progress = 1
            } completion: {
                if progress >= 1 { previous = nil }
            }
        }
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
struct ThemeChromeColors {
    var title: Color
    var secondaryText: Color
    var tertiaryText: Color
    var glyph: Color
    var separator: Color
    /// Folder glyphs and accents (`foregroundPrimary`).
    var accent: Color
    var rowHover: Color
    var rowSelected: Color
    var focus: Color
    /// Floating panels over the window (command bar, Peek): the theme's
    /// `backgroundExtra` / dark `background` washed over the material.
    var panel: Color
    var isDark: Bool

    init(theme: SpaceTheme, dark: Bool) {
        let roles = SpaceThemeRoles(theme: theme)
        let semantic = roles.semantic(dark: dark)
        let chrome = roles.chrome(dark: dark)
        title = Color(semantic.title)
        secondaryText = Color(chrome.secondaryText)
        tertiaryText = Color(chrome.tertiaryText)
        glyph = Color(chrome.glyph)
        separator = Color(chrome.separator)
        accent = Color(semantic.foregroundPrimary)
        // Arc's selected row is near-white `backgroundExtra`; hover a lighter
        // wash of it (row geometry and fills are still to observe, §8).
        rowSelected = Color(semantic.backgroundExtra).opacity(dark ? 0.16 : 0.92)
        rowHover = Color(semantic.backgroundExtra).opacity(dark ? 0.08 : 0.42)
        focus = Color(semantic.focus).opacity(semantic.focusAlpha)
        panel = Color(dark ? semantic.background : semantic.backgroundExtra).opacity(dark ? 0.6 : 0.55)
        isDark = dark
    }

    static let fallback = ThemeChromeColors(theme: .arcDefault, dark: false)
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
