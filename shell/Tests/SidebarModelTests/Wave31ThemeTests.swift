import XCTest
@testable import SidebarModel

/// Wave 31: Arc's theme maths (docs/FEATURE-SPECS/THEMES.md §3).
final class Wave31ThemeTests: XCTestCase {
    // MARK: OKLab

    func testOKLabMatchesTheReferenceValues() {
        let white = OKLab(SpaceColor.white)
        XCTAssertEqual(white.l, 1, accuracy: 1e-4)
        XCTAssertEqual(white.lch.c, 0, accuracy: 1e-4)
        XCTAssertEqual(OKLab(SpaceColor.black).l, 0, accuracy: 1e-9)
        // Ottosson's published sRGB red: L 0.628, C 0.2577, h 29.2°.
        let red = OKLab(SpaceColor(red: 1, green: 0, blue: 0)).lch
        XCTAssertEqual(red.l, 0.6280, accuracy: 1e-3)
        XCTAssertEqual(red.c, 0.2577, accuracy: 1e-3)
        XCTAssertEqual(red.h, 29.23, accuracy: 0.1)
    }

    func testOKLabRoundTripsAndKeepsOutOfGamutValues() {
        for hex in ["#6CBAD9", "#7F7EDC", "#5CD8B8", "#F25E6B", "#2731FF", "#090D4F"] {
            let color = SpaceColor(hex: hex)!
            let back = OKLab(color).color
            XCTAssertEqual(back.red, color.red, accuracy: 1e-6, hex)
            XCTAssertEqual(back.green, color.green, accuracy: 1e-6, hex)
            XCTAssertEqual(back.blue, color.blue, accuracy: 1e-6, hex)
        }
        // Arc stores extended sRGB (a P3 green with a negative red); never clamp.
        let p3Green = SpaceColor(red: -0.414, green: 0.862, blue: 0.265)
        XCTAssertEqual(OKLab(p3Green).color.red, -0.414, accuracy: 1e-6)
    }

    func testOKLabInterpolationIsPerceptuallyEvenWhereSRGBSags() {
        let red = SpaceColor(red: 1, green: 0, blue: 0), green = SpaceColor(red: 0, green: 1, blue: 0)
        let lab = OKLab(red).mixed(with: OKLab(green), fraction: 0.5)
        let srgb = OKLab(red.mixed(with: green, fraction: 0.5))
        XCTAssertEqual(lab.l, (OKLab(red).l + OKLab(green).l) / 2, accuracy: 1e-9, "lightness is linear in OKLab")
        XCTAssertGreaterThan(lab.l, srgb.l + 0.1, "an sRGB mix sags to a dark olive")
        let cyan = SpaceColor(hex: "#6CBAD9")!, violet = SpaceColor(hex: "#7F7EDC")!
        let mid = OKLab(cyan).mixed(with: OKLab(violet), fraction: 0.5).lch
        XCTAssertGreaterThan(mid.c, 0.09, "cyan to violet stays saturated through the middle")
        XCTAssertTrue((226 ... 285).contains(mid.h))
    }

    func testGamutMappingKeepsLightnessAndHue() {
        let vivid = OKLCH(l: 0.77, c: 0.4, h: 146)
        let mapped = vivid.gamutMapped(to: .sRGB)
        XCTAssertEqual(mapped.l, 0.77)
        XCTAssertEqual(mapped.h, 146)
        XCTAssertLessThan(mapped.c, 0.4)
        let rgb = mapped.lab.linear
        for component in [rgb.red, rgb.green, rgb.blue] {
            XCTAssertGreaterThanOrEqual(component, -1e-4)
            XCTAssertLessThanOrEqual(component, 1 + 1e-4)
        }
        XCTAssertGreaterThan(vivid.gamutMapped(to: .displayP3).c, mapped.c, "P3 holds more green")
    }

    // MARK: Gradient (shader port, §3.2)

    /// The user's capture of real Arc: a 1707 × 1410 pt window on the default theme (§4.2).
    private func uv(_ x: Double, _ y: Double) -> (Double, Double) { (x / 1707, y / 1410) }

    func testDefaultThemeReproducesTheMeasuredWindow() {
        let gradient = ThemeGradient(theme: .arcDefault, dark: false)
        let samples: [(x: Double, y: Double, hex: String)] = [
            (4, 22, "#D8D9F4"),     // top-left
            (4, 662, "#E0DEF1"),    // sidebar middle
            (4, 1362, "#E9E1EC"),   // sidebar bottom
            (1684, 5, "#ECE1E9"),   // top margin
            (1702, 700, "#F4E5E5"), // right margin, flat
            (1702, 1400, "#F4E5E5"),
        ]
        for sample in samples {
            let (u, v) = uv(sample.x, sample.y)
            let rendered = gradient.color(u: u, v: v)
            let error = OKLab(rendered).distance(to: OKLab(SpaceColor(hex: sample.hex)!))
            XCTAssertLessThan(error, 0.012, "(\(sample.x), \(sample.y)) rendered \(rendered.hex), measured \(sample.hex)")
        }
    }

    func testBaseGradientReachesColourTwoAtSeventyFivePercent() {
        let theme = SpaceTheme(red: 0.42, green: 0.73, blue: 0.85, gradientColors: [SpaceColor(hex: "#7F7EDC")!], intensity: 1)
        let gradient = ThemeGradient(theme: theme, dark: false)
        XCTAssertEqual(ThemeGradient.baseT(u: 0.75, v: 0.75), 0.75, accuracy: 1e-12)
        let end = gradient.color(u: 1, v: 1)
        let atThreeQuarters = gradient.color(u: 0.75, v: 0.75)
        XCTAssertEqual(OKLab(end).distance(to: OKLab(atThreeQuarters)), 0, accuracy: 1e-9, "flat for the last quarter")
        XCTAssertEqual(OKLab(end).distance(to: OKLab(SpaceColor(hex: "#7F7EDC")!)), 0, accuracy: 1e-6)
        // Half way along the line is two thirds of the way in OKLab.
        let half = gradient.color(u: 0.5, v: 0.5)
        let expected = OKLab(theme.spaceColor).mixed(with: OKLab(SpaceColor(hex: "#7F7EDC")!), fraction: 2.0 / 3.0)
        XCTAssertEqual(OKLab(half).distance(to: expected), 0, accuracy: 1e-6)
    }

    func testIntensityCompositesOverTheUnderlayInEncodedSRGB() {
        let color = SpaceColor(hex: "#F25E6B")!
        let theme = SpaceTheme(red: color.red, green: color.green, blue: color.blue)
        let light = ThemeGradient(theme: theme, dark: false).color(u: 0.3, v: 0.6)
        XCTAssertEqual(light.red, color.red * 0.8 + 0.2, accuracy: 1e-6)
        XCTAssertEqual(light.green, color.green * 0.8 + 0.2, accuracy: 1e-6)
        XCTAssertEqual(light.blue, color.blue * 0.8 + 0.2, accuracy: 1e-6)
        var full = theme
        full.intensity = 1
        XCTAssertEqual(ThemeGradient(theme: full, dark: false).color(u: 0, v: 0).red, color.red, accuracy: 1e-6)
        let dark = ThemeGradient(theme: theme, dark: true).color(u: 0.3, v: 0.6)
        XCTAssertLessThan(OKLab(dark).l, 0.4, "dark appearance darkens the stops over black")
    }

    func testThirdColourFadesInFromClearAlongTheOtherDiagonal() {
        let theme = SpaceTheme(red: 0.42, green: 0.73, blue: 0.85,
                               gradientColors: [SpaceColor(hex: "#7F7EDC")!, SpaceColor(hex: "#5CD8B8")!], intensity: 1)
        let three = ThemeGradient(theme: theme, dark: false)
        var twoTheme = theme
        twoTheme.gradientColors.removeLast()
        let two = ThemeGradient(theme: twoTheme, dark: false)
        // Top-right corner: overlay t = 0, colour 3 is clear.
        XCTAssertEqual(OKLab(three.color(u: 1, v: 0)).distance(to: OKLab(two.color(u: 1, v: 0))), 0, accuracy: 1e-9)
        // Bottom-left corner: overlay t = 1, colour 3 is opaque and covers the base.
        XCTAssertEqual(OKLab(three.color(u: 0, v: 1)).distance(to: OKLab(SpaceColor(hex: "#5CD8B8")!)), 0, accuracy: 1e-6)
        // In between it is source-over in linear light of a darkened, part-transparent colour 3.
        let mid = three.color(u: 0.5, v: 0.5)
        XCTAssertNotEqual(mid, two.color(u: 0.5, v: 0.5))
    }

    func testCrossfadeMixesTwoFinishedThemes() {
        let a = ThemeGradient(theme: .arcDefault, dark: false).color(u: 0.2, v: 0.2)
        let b = SpaceColor(hex: "#5CD8B8")!
        XCTAssertEqual(ThemeGradient.crossfade(a, b, progress: 0), a)
        XCTAssertEqual(OKLab(ThemeGradient.crossfade(a, b, progress: 1)).distance(to: OKLab(b)), 0, accuracy: 1e-12)
        XCTAssertEqual(ThemeGradient.crossfade(a, b, progress: 0.5).red, (a.red + b.red) / 2, accuracy: 1e-12)
    }

    func testRenderedBufferIsOpaqueAndTopRowFirst() {
        let pixels = ThemeGradient(theme: .arcDefault, dark: false).rgba(width: 8, height: 4)
        XCTAssertEqual(pixels.count, 8 * 4 * 4)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 1 })
        let topLeft = SpaceColor(red: Double(pixels[0]), green: Double(pixels[1]), blue: Double(pixels[2]))
        XCTAssertLessThan(OKLab(topLeft).distance(to: OKLab(SpaceColor(hex: "#D8D9F4")!)), 0.02)
    }

    // MARK: Texture (§3.3)

    func testMultiplyOnlyDarkens() {
        let color = SpaceColor(hex: "#E0DEF1")!
        let out = ThemeTextureBlend.multiply(color, texel: SpaceColor(red: 0.73, green: 0.73, blue: 0.73), alpha: 0.26 * 0.75)
        XCTAssertLessThan(out.red, color.red)
        XCTAssertEqual(out.red, color.red * (1 - 0.27 * 0.26 * 0.75), accuracy: 1e-9)
        XCTAssertEqual(ThemeTextureBlend.multiply(color, texel: .white, alpha: 1), color)
        XCTAssertEqual(ThemeTextureBlend.multiply(color, texel: .black, alpha: 0), color)
    }

    func testGeneratedTexturesMatchArcsStatistics() {
        let expected: [SpaceTexture: (mean: Double, sd: ClosedRange<Double>, alpha: Double)] = [
            .grain: (0.73, 0.09 ... 0.15, 0.26),
            .sand: (0.66, 0.14 ... 0.22, 1),
            .denim: (0.84, 0.02 ... 0.05, 1),
            .tweed: (0.71, 0.03 ... 0.055, 1),
        ]
        for texture in SpaceTexture.allCases {
            let side = 200
            let pixels = ThemeTextureGenerator.rgba(texture, side: side)
            let greys = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
            let alphas = stride(from: 3, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
            let mean = greys.reduce(0, +) / Double(greys.count)
            let sd = (greys.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(greys.count)).squareRoot()
            let alpha = alphas.reduce(0, +) / Double(alphas.count)
            let spec = expected[texture]!
            XCTAssertEqual(mean, spec.mean, accuracy: 0.02, "\(texture) mean")
            XCTAssertTrue(spec.sd.contains(sd), "\(texture) SD \(sd)")
            XCTAssertEqual(alpha, spec.alpha, accuracy: 0.02, "\(texture) alpha")
        }
        XCTAssertEqual(ThemeTextureGenerator.rgba(.grain, side: 16), ThemeTextureGenerator.rgba(.grain, side: 16), "deterministic")
    }

    // MARK: Derived roles (§3.5), against the user's stored Arc themes

    struct StoredTheme {
        let base: String
        let tintedLight: String, midTone: String, shaded: String, shadedDark: String
        let light: [String: String]
        let dark: [String: String]

        var primary: ThemePrimaryPalette {
            ThemePrimaryPalette(tintedLight: SpaceColor(hex: tintedLight)!, midTone: SpaceColor(hex: midTone)!,
                                shaded: SpaceColor(hex: shaded)!, shadedDark: SpaceColor(hex: shadedDark)!)
        }
    }

    static let vectors: [StoredTheme] = [
        StoredTheme(base: "#6CBAD9", tintedLight: "#E4F2F8", midTone: "#6CBAD9", shaded: "#6CBAD9", shadedDark: "#005F7D",
                    light: ["background": "#E6EFF2", "backgroundExtra": "#FCFDFE", "cutoutColor": "#E4F2F8", "focus": "#80AFBE", "foregroundPrimary": "#6CBAD9", "foregroundSecondary": "#6CBAD9", "foregroundTertiary": "#E4F2F8", "hover": "#CCDFE5", "maxContrastColor": "#005F7D", "minContrastColor": "#E4F2F8", "subtitle": "#99BFCB", "title": "#001D26"],
                    dark: ["background": "#001D26", "backgroundExtra": "#000E13", "cutoutColor": "#005F7D", "focus": "#327F97", "foregroundPrimary": "#E4F2F8", "foregroundSecondary": "#6CBAD9", "foregroundTertiary": "#6CBAD9", "hover": "#458BA0", "maxContrastColor": "#E4F2F8", "minContrastColor": "#005F7D", "subtitle": "#72797C", "title": "#D9E7EC"]),
        StoredTheme(base: "#DEFDEB", tintedLight: "#DEFDEB", midTone: "#00DC44", shaded: "#00DC44", shadedDark: "#006721",
                    light: ["background": "#E1F0E9", "backgroundExtra": "#FCFDFD", "cutoutColor": "#DEFDEB", "focus": "#6AB390", "foregroundPrimary": "#00DC44", "foregroundSecondary": "#00DC44", "foregroundTertiary": "#DEFDEB", "hover": "#C3E1D3", "maxContrastColor": "#006721", "minContrastColor": "#DEFDEB", "subtitle": "#87C2A6", "title": "#001F0A"],
                    dark: ["background": "#001F0A", "backgroundExtra": "#000F05", "cutoutColor": "#006721", "focus": "#0E854C", "foregroundPrimary": "#DEFDEB", "foregroundSecondary": "#00DC44", "foregroundTertiary": "#00DC44", "hover": "#25905D", "maxContrastColor": "#DEFDEB", "minContrastColor": "#006721", "subtitle": "#6F7E75", "title": "#D2E8DE"]),
        StoredTheme(base: "#F2EAE4", tintedLight: "#F4EDE7", midTone: "#D2B5A0", shaded: "#D2B5A0", shadedDark: "#735137",
                    light: ["background": "#F1EEEB", "backgroundExtra": "#FEFDFD", "cutoutColor": "#F4EDE7", "focus": "#B9A89B", "foregroundPrimary": "#D2B5A0", "foregroundSecondary": "#D2B5A0", "foregroundTertiary": "#F4EDE7", "hover": "#E3DCD7", "maxContrastColor": "#735137", "minContrastColor": "#F4EDE7", "subtitle": "#C7BAAF", "title": "#221811"],
                    dark: ["background": "#221811", "backgroundExtra": "#110C08", "cutoutColor": "#735137", "focus": "#8E735E", "foregroundPrimary": "#F4EDE7", "foregroundSecondary": "#D2B5A0", "foregroundTertiary": "#D2B5A0", "hover": "#99806D", "maxContrastColor": "#F4EDE7", "minContrastColor": "#735137", "subtitle": "#7A7674", "title": "#EAE5E1"]),
        StoredTheme(base: "#F8D558", tintedLight: "#FCEDBC", midTone: "#E9B300", shaded: "#E9B300", shadedDark: "#6F5600",
                    light: ["background": "#F1EEE3", "backgroundExtra": "#FEFDFC", "cutoutColor": "#FCEDBC", "focus": "#B7AA75", "foregroundPrimary": "#E9B300", "foregroundSecondary": "#E9B300", "foregroundTertiary": "#FCEDBC", "hover": "#E2DDC8", "maxContrastColor": "#6F5600", "minContrastColor": "#FCEDBC", "subtitle": "#C6BB91", "title": "#211A00"],
                    dark: ["background": "#211A00", "backgroundExtra": "#110D00", "cutoutColor": "#6F5600", "focus": "#8B7721", "foregroundPrimary": "#FCEDBC", "foregroundSecondary": "#E9B300", "foregroundTertiary": "#E9B300", "hover": "#968436", "maxContrastColor": "#FCEDBC", "minContrastColor": "#6F5600", "subtitle": "#7E775E", "title": "#E9E6D6"]),
        StoredTheme(base: "#F25E6B", tintedLight: "#FEEBEC", midTone: "#F46D78", shaded: "#F25E6B", shadedDark: "#B70021",
                    light: ["background": "#F8E6E9", "backgroundExtra": "#FEFCFD", "cutoutColor": "#FEEBEC", "focus": "#DB8090", "foregroundPrimary": "#F25E6B", "foregroundSecondary": "#F46D78", "foregroundTertiary": "#FEEBEC", "hover": "#F1CCD3", "maxContrastColor": "#B70021", "minContrastColor": "#FEEBEC", "subtitle": "#E299A6", "title": "#37000A"],
                    dark: ["background": "#37000A", "backgroundExtra": "#1B0005", "cutoutColor": "#B70021", "focus": "#C5324D", "foregroundPrimary": "#FEEBEC", "foregroundSecondary": "#F46D78", "foregroundTertiary": "#F25E6B", "hover": "#CA455D", "maxContrastColor": "#FEEBEC", "minContrastColor": "#B70021", "subtitle": "#7F7576", "title": "#F4D9DE"]),
        StoredTheme(base: "#B6E251", tintedLight: "#E4F4C0", midTone: "#90CB00", shaded: "#90CB00", shadedDark: "#446000",
                    light: ["background": "#ECEFE4", "backgroundExtra": "#FDFDFC", "cutoutColor": "#E4F4C0", "focus": "#A2AF7A", "foregroundPrimary": "#90CB00", "foregroundSecondary": "#90CB00", "foregroundTertiary": "#E4F4C0", "hover": "#DADFCA", "maxContrastColor": "#446000", "minContrastColor": "#E4F4C0", "subtitle": "#B4BF95", "title": "#141D00"],
                    dark: ["background": "#141D00", "backgroundExtra": "#0A0E00", "cutoutColor": "#446000", "focus": "#697F29", "foregroundPrimary": "#E4F4C0", "foregroundSecondary": "#90CB00", "foregroundTertiary": "#90CB00", "hover": "#778B3D", "maxContrastColor": "#E4F4C0", "minContrastColor": "#446000", "subtitle": "#727A60", "title": "#E3E7D7"]),
        StoredTheme(base: "#34E895", tintedLight: "#C8F8DD", midTone: "#00D856", shaded: "#00D856", shadedDark: "#006629",
                    light: ["background": "#E2F0EA", "backgroundExtra": "#FCFDFD", "cutoutColor": "#C8F8DD", "focus": "#6CB394", "foregroundPrimary": "#00D856", "foregroundSecondary": "#00D856", "foregroundTertiary": "#C8F8DD", "hover": "#C4E0D4", "maxContrastColor": "#006629", "minContrastColor": "#C8F8DD", "subtitle": "#89C2AA", "title": "#001F0C"],
                    dark: ["background": "#001F0C", "backgroundExtra": "#000F06", "cutoutColor": "#006629", "focus": "#128453", "foregroundPrimary": "#C8F8DD", "foregroundSecondary": "#00D856", "foregroundTertiary": "#00D856", "hover": "#289063", "maxContrastColor": "#C8F8DD", "minContrastColor": "#006629", "subtitle": "#647C6F", "title": "#D3E8DF"]),
        StoredTheme(base: "#00DDB4", tintedLight: "#C8F7ED", midTone: "#00D5A7", shaded: "#00D5A7", shadedDark: "#00644F",
                    light: ["background": "#E2F0ED", "backgroundExtra": "#FCFDFD", "cutoutColor": "#C8F7ED", "focus": "#6DB2A7", "foregroundPrimary": "#00D5A7", "foregroundSecondary": "#00D5A7", "foregroundTertiary": "#C8F7ED", "hover": "#C4E0DC", "maxContrastColor": "#00644F", "minContrastColor": "#C8F7ED", "subtitle": "#8AC1B8", "title": "#001E18"],
                    dark: ["background": "#001E18", "backgroundExtra": "#000F0C", "cutoutColor": "#00644F", "focus": "#138371", "foregroundPrimary": "#C8F7ED", "foregroundSecondary": "#00D5A7", "foregroundTertiary": "#00D5A7", "hover": "#298E7E", "maxContrastColor": "#C8F7ED", "minContrastColor": "#00644F", "subtitle": "#647C76", "title": "#D3E8E5"]),
    ]

    private func roles(_ palette: ThemeSemanticPalette) -> [String: SpaceColor] {
        [
            "background": palette.background, "backgroundExtra": palette.backgroundExtra,
            "cutoutColor": palette.cutoutColor, "focus": palette.focus,
            "foregroundPrimary": palette.foregroundPrimary, "foregroundSecondary": palette.foregroundSecondary,
            "foregroundTertiary": palette.foregroundTertiary, "hover": palette.hover,
            "maxContrastColor": palette.maxContrastColor, "minContrastColor": palette.minContrastColor,
            "subtitle": palette.subtitle, "title": palette.title,
        ]
    }

    /// Byte-rounded and clamped, as the stored hex samples are.
    private func error(_ color: SpaceColor, _ hex: String) -> Double {
        OKLab(SpaceColor(hex: color.clamped.hex)!).distance(to: OKLab(SpaceColor(hex: hex)!))
    }

    func testSemanticRolesMatchEveryStoredTheme() {
        for vector in Self.vectors {
            let derived = SpaceThemeRoles(primary: vector.primary, hueOf: SpaceColor(hex: vector.base)!)
            for (appearance, stored, palette) in [("light", vector.light, derived.light), ("dark", vector.dark, derived.dark)] {
                let mine = roles(palette)
                XCTAssertEqual(Set(mine.keys), Set(stored.keys))
                for (role, hex) in stored {
                    XCTAssertLessThanOrEqual(error(mine[role]!, hex), 0.02, "\(vector.base) \(appearance) \(role): \(mine[role]!.hex) vs \(hex)")
                }
            }
            XCTAssertEqual(derived.dark.hoverAlpha, 0.48)
            XCTAssertEqual(derived.dark.focusAlpha, 0.8075)
            XCTAssertEqual(derived.light.hoverAlpha, 1)
        }
    }

    func testPrimaryPaletteIsDerivedFromColourOne() {
        var worst: [String: Double] = [:]
        for vector in Self.vectors {
            let derived = ThemePrimaryPalette(base: SpaceColor(hex: vector.base)!)
            let pairs = [("tintedLight", derived.tintedLight, vector.tintedLight), ("midTone", derived.midTone, vector.midTone),
                         ("shaded", derived.shaded, vector.shaded), ("shadedDark", derived.shadedDark, vector.shadedDark)]
            for (role, mine, hex) in pairs {
                worst[role] = max(worst[role] ?? 0, error(mine, hex))
                // The lightness rule itself: within 0.03 of the stored value.
                XCTAssertEqual(OKLab(mine).l, OKLab(SpaceColor(hex: hex)!).l, accuracy: 0.035, "\(vector.base) \(role)")
            }
        }
        XCTAssertLessThanOrEqual(worst["tintedLight"]!, 0.02)
        XCTAssertLessThanOrEqual(worst["shadedDark"]!, 0.05)
        XCTAssertLessThanOrEqual(worst["midTone"]!, 0.09)
        XCTAssertLessThanOrEqual(worst["shaded"]!, 0.09)
    }

    func testFullDerivationStaysInsideTheSpecsLightnessTable() {
        for vector in Self.vectors {
            let roles = SpaceThemeRoles(theme: SpaceTheme(red: SpaceColor(hex: vector.base)!.red,
                                                          green: SpaceColor(hex: vector.base)!.green,
                                                          blue: SpaceColor(hex: vector.base)!.blue))
            func l(_ c: SpaceColor) -> Double { OKLab(c).l }
            XCTAssertTrue((0.93 ... 0.96).contains(l(roles.light.background)), vector.base)
            XCTAssertTrue((0.99 ... 1.0).contains(l(roles.light.backgroundExtra)), vector.base)
            XCTAssertTrue((0.86 ... 0.91).contains(l(roles.light.hover)), vector.base)
            XCTAssertTrue((0.19 ... 0.24).contains(l(roles.light.title)), vector.base)
            XCTAssertTrue((0.89 ... 0.94).contains(l(roles.dark.title)), vector.base)
            XCTAssertEqual(roles.light.title, roles.dark.background, "title is the dark background")
        }
    }

    func testDefaultThemeUsesTheMeasuredNavyAndAccent() {
        let roles = SpaceTheme.arcDefault.roles
        XCTAssertLessThanOrEqual(error(roles.light.title, "#090D4F"), 0.02, roles.light.title.hex)
        XCTAssertEqual(roles.light.foregroundPrimary.hex, "#2731FF")
        // Chrome greys measured from the capture (§4.6, §4.7).
        let chrome = roles.lightChrome
        XCTAssertLessThanOrEqual(error(chrome.secondaryText, "#6D6D79"), 0.03, chrome.secondaryText.hex)
        XCTAssertLessThanOrEqual(error(chrome.tertiaryText, "#9F9BA7"), 0.03, chrome.tertiaryText.hex)
        XCTAssertLessThanOrEqual(error(chrome.glyph, "#666267"), 0.03, chrome.glyph.hex)
        XCTAssertLessThanOrEqual(error(chrome.separator, "#C0BDCC"), 0.03, chrome.separator.hex)
        // Never plain black or white.
        for color in [roles.light.title, roles.dark.title, chrome.secondaryText, roles.darkChrome.secondaryText] {
            XCTAssertNotEqual(color.hex, "#000000")
            XCTAssertNotEqual(color.hex, "#FFFFFF")
        }
    }

    func testThemesSharingColourOneShareTheirRoles() {
        let single = SpaceTheme(red: 0.42, green: 0.73, blue: 0.85)
        var gradient = single
        gradient.gradientColors = [SpaceColor(hex: "#7F7EDC")!]
        XCTAssertEqual(single.roles, gradient.roles)
    }

    // MARK: Model

    func testDefaultThemeIsTheLavenderToPinkGradient() {
        let theme = SpaceTheme.default
        XCTAssertEqual(theme, .arcDefault)
        XCTAssertEqual(theme.stops.count, 2)
        XCTAssertEqual(theme.intensity, 0.8)
        XCTAssertEqual(theme.noise, 0)
        XCTAssertEqual(Space(name: "New").theme, .arcDefault)
    }

    func testIntensityAndTextureRoundTripAndOldThemesDecode() throws {
        var theme = SpaceTheme(red: 0.9, green: 0.8, blue: 0.3, noise: 0.9)
        theme.intensity = 0.59
        theme.texture = .sand
        let data = try JSONEncoder().encode(theme)
        XCTAssertEqual(try JSONDecoder().decode(SpaceTheme.self, from: data), theme)

        let old = try JSONDecoder().decode(SpaceTheme.self, from: Data(#"{"red":0.2,"green":0.6,"blue":0.86}"#.utf8))
        XCTAssertEqual(old.intensity, 0.8)
        XCTAssertEqual(old.texture, .grain)
        let plain = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(plain.contains("intensity"), "defaults stay off the wire")

        let legacy = try JSONDecoder().decode(SpaceTheme.self, from: Data(#"{"red":0.45,"green":0.35,"blue":0.9}"#.utf8))
        XCTAssertEqual(legacy, .arcDefault, "the old indigo default becomes Arc's default")

        theme.intensity = 7
        XCTAssertEqual(theme.intensity, 1)
        let style = try JSONDecoder().decode(SpaceThemeStyle.self, from: Data(#"{"noise":0.5}"#.utf8))
        XCTAssertEqual(style.intensity, 0.8)
        XCTAssertEqual(style.texture, .grain)
    }

    func testEditorSwatchesAreArcsMeasuredSets() {
        XCTAssertEqual(SpaceTheme.editorPalette.count, 3)
        XCTAssertTrue(SpaceTheme.editorPalette.allSatisfy { $0.count == 9 })
        XCTAssertEqual(SpaceTheme.editorPalette[0][8].spaceColor.hex, "#C5C6E2")
        XCTAssertEqual(SpaceTheme.editorPalette[2][0].spaceColor.hex, "#4B3B58")
    }
}

/// Wave 31: the theme editor's colour pad maths.
final class Wave31ColorPadTests: XCTestCase {
    func testCentreIsNearWhiteAndTheRimIsVivid() {
        let centre = OKLab(ThemeColorPad.color(at: .init(angle: 120, radius: 0)))
        XCTAssertGreaterThan(centre.l, 0.95)
        XCTAssertLessThan(centre.lch.c, 0.005)
        let rim = OKLab(ThemeColorPad.color(at: .init(angle: 260, radius: 1))).lch
        XCTAssertEqual(rim.l, 0.66, accuracy: 0.01)
        XCTAssertGreaterThan(rim.c, 0.15)
        XCTAssertEqual(rim.h, 260, accuracy: 3)
    }

    func testPointsRoundTripThroughColours() {
        for angle in stride(from: 10.0, to: 360, by: 50) {
            for radius in [0.25, 0.5, 0.9] {
                let point = ThemeColorPad.Point(angle: angle, radius: radius)
                let back = ThemeColorPad.point(of: ThemeColorPad.color(at: point))
                XCTAssertEqual(back.radius, radius, accuracy: 0.02, "\(angle)° r\(radius)")
                XCTAssertEqual(back.angle, angle, accuracy: 4, "\(angle)° r\(radius)")
            }
        }
    }

    func testDraggingColourOneCarriesTheOthers() {
        let points = [ThemeColorPad.Point(angle: 200, radius: 0.5), .init(angle: 250, radius: 0.4), .init(angle: 150, radius: 0.6)]
        let moved = ThemeColorPad.dragBase(points, to: .init(angle: 230, radius: 0.7))
        XCTAssertEqual(moved.map(\.angle), [230, 280, 180])
        XCTAssertEqual(moved.map(\.radius), [0.7, 0.4, 0.6])
        XCTAssertEqual(ThemeColorPad.dragBase(points, to: .init(angle: 350, radius: 0.5))[1].angle, 40, "wraps round")
    }

    func testAddingFollowsTheHarmonyUpToThreeColours() {
        var points = [ThemeColorPad.Point(angle: 100, radius: 0.5)]
        points = ThemeColorPad.adding(to: points, harmony: .analogous)
        points = ThemeColorPad.adding(to: points, harmony: .analogous)
        XCTAssertEqual(points.map(\.angle), [100, 150, 50])
        XCTAssertEqual(ThemeColorPad.adding(to: points, harmony: .analogous).count, 3)
        XCTAssertEqual(ThemeColorPad.adding(to: [points[0]], harmony: .complementary)[1].angle, 280)
        let theme = ThemeColorPad.theme(SpaceTheme.arcDefault, with: points)
        XCTAssertEqual(theme.stops.count, 3)
        XCTAssertEqual(theme.intensity, SpaceTheme.arcDefault.intensity, "style is kept")
    }
}
