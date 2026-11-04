import Foundation

/// Arc's colour harmonies for a recoloured site (`AnalogousColorScheme`,
/// `ComplementaryColorScheme` assets, BOOSTS §3).
public enum BoostColorHarmony: String, CaseIterable, Sendable {
    case single
    case analogous
    case complementary

    public var title: String {
        switch self {
        case .single: return "Single"
        case .analogous: return "Analogous"
        case .complementary: return "Complementary"
        }
    }
}

/// A site recolour: a hue on Arc's hue ring and how strongly it tints.
public struct BoostTint: Equatable, Sendable {
    /// 0...1 round the hue ring.
    public var hue: Double
    /// 0...1; how much of the page takes the hue.
    public var intensity: Double
    public var harmony: BoostColorHarmony

    public init(hue: Double, intensity: Double = 0.5, harmony: BoostColorHarmony = .single) {
        self.hue = BoostTint.wrapped(hue)
        self.intensity = min(max(intensity.isFinite ? intensity : 0.5, 0), 1)
        self.harmony = harmony
    }

    static func wrapped(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let value = hue.truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    /// The hues the harmony paints, in degrees.
    public var degrees: [Int] {
        let base = Int((hue * 360).rounded()) % 360
        switch harmony {
        case .single: return [base]
        case .analogous: return [base, (base + 40) % 360]
        case .complementary: return [base, (base + 180) % 360]
        }
    }

    /// Arc's eight named Boost colours (`BoostsBlue`…`BoostsYellow`), as hues.
    public static let namedHues: [(name: String, hue: Double)] = [
        ("Red", 0.0), ("Orange", 0.08), ("Yellow", 0.14), ("Green", 0.36),
        ("Blue", 0.6), ("Purple", 0.74), ("Magenta", 0.84), ("Pink", 0.93),
    ]
}

/// The font a boost sets on a page (Arc's typography control).
public enum BoostFontChoice: Equatable, Sendable {
    case sansSerif
    case serif
    case monospace
    case rounded
    /// An installed font family, by name.
    case family(String)

    public static let presets: [BoostFontChoice] = [.sansSerif, .serif, .monospace, .rounded]

    public var title: String {
        switch self {
        case .sansSerif: return "Sans Serif"
        case .serif: return "Serif"
        case .monospace: return "Monospace"
        case .rounded: return "Rounded"
        case .family(let name): return name
        }
    }

    var stack: String {
        switch self {
        case .sansSerif: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
        case .serif: return "ui-serif, \"New York\", Georgia, serif"
        case .monospace: return "ui-monospace, \"SF Mono\", Menlo, monospace"
        case .rounded: return "ui-rounded, \"SF Pro Rounded\", -apple-system, sans-serif"
        case .family(let name): return "\"\(name)\", sans-serif"
        }
    }

    /// The token in the settings comment.
    var token: String {
        switch self {
        case .sansSerif: return "sans"
        case .serif: return "serif"
        case .monospace: return "mono"
        case .rounded: return "rounded"
        case .family(let name): return "family:" + name.replacingOccurrences(of: " ", with: "_")
        }
    }

    init?(token: String) {
        switch token {
        case "sans": self = .sansSerif
        case "serif": self = .serif
        case "mono": self = .monospace
        case "rounded": self = .rounded
        default:
            guard token.hasPrefix("family:") else { return nil }
            let name = String(token.dropFirst("family:".count)).replacingOccurrences(of: "_", with: " ")
            guard let safe = BoostFontChoice.safeFamilyName(name) else { return nil }
            self = .family(safe)
        }
    }

    /// Letters, digits, spaces and hyphens only, so a name cannot break out
    /// of its CSS string or the settings comment.
    public static func safeFamilyName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" })
        else { return nil }
        return trimmed
    }
}

/// A v2 (visual) Boost (Arc's Boosts Editor, BOOSTS §3): recolour, dark
/// mode, font and text size, and zapped (hidden) elements. It is compiled
/// into a marked block at the top of the boost's stylesheet, headed by a
/// one-line settings comment. The stylesheet stays the single source of
/// truth, so the settings travel with the CSS through sync, export and every
/// older ReArc, which keep CSS as it is. Hand-written CSS follows the block.
public struct BoostVisualStyle: Equatable, Sendable {
    public var tint: BoostTint?
    public var darkMode: Bool
    public var font: BoostFontChoice?
    /// Text size, 1 is the site's own (0.75...2).
    public var textScale: Double
    /// Selectors of zapped elements, in the order they were zapped.
    public var zaps: [String]

    public static let textScaleRange: ClosedRange<Double> = 0.75 ... 2

    public init(tint: BoostTint? = nil, darkMode: Bool = false, font: BoostFontChoice? = nil, textScale: Double = 1, zaps: [String] = []) {
        self.tint = tint
        self.darkMode = darkMode
        self.font = font
        self.textScale = Self.clampedScale(textScale)
        self.zaps = zaps
    }

    public var isEmpty: Bool { self == BoostVisualStyle() }

    static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, textScaleRange.lowerBound), textScaleRange.upperBound)
    }

    static let header = "/* rearc-visual-boost v1"
    static let footer = "/* /rearc-visual-boost */"

    // MARK: Zaps

    /// Zap: hide the element (Arc `appendZap`); a selector zapped twice stays once.
    public mutating func appendZap(_ selector: String) {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeSelector(trimmed), !zaps.contains(trimmed) else { return }
        zaps.append(trimmed)
    }

    public mutating func removeZap(_ selector: String) {
        zaps.removeAll { $0 == selector }
    }

    /// A selector the block can carry: no braces, comment markers or style breakout.
    static func isSafeSelector(_ selector: String) -> Bool {
        !selector.isEmpty && selector.count <= 512
            && !selector.contains("{") && !selector.contains("}")
            && !selector.contains("/*") && !selector.contains("*/")
            && !selector.lowercased().contains("</style")
    }

    // MARK: Compile

    /// The marked CSS block, or "" when nothing is set.
    public func compiled() -> String {
        guard !isEmpty else { return "" }
        var lines = [settingsComment]
        if let tint {
            let stops = tint.degrees.map { "hsl(\($0), 85%, 50%)" }
            let paint = stops.count == 1 ? stops[0] : "linear-gradient(135deg, \(stops.joined(separator: ", ")))"
            lines.append("""
            html::after {
              content: "" !important;
              position: fixed !important;
              inset: 0 !important;
              pointer-events: none !important;
              z-index: 2147483647 !important;
              background: \(paint) !important;
              mix-blend-mode: color !important;
              opacity: \(Self.number(0.15 + tint.intensity * 0.7)) !important;
            }
            """)
        }
        if darkMode {
            lines.append("""
            html {
              filter: invert(1) hue-rotate(180deg) !important;
              background-color: #fff !important;
            }
            img, video, picture, canvas, iframe, embed, object, svg image, [style*="background-image"] {
              filter: invert(1) hue-rotate(180deg) !important;
            }
            """)
        }
        if let font {
            lines.append("""
            body, body *:not(pre):not(code):not(kbd):not(samp):not(i):not([class*="icon"]):not([class*="Icon"]) {
              font-family: \(font.stack) !important;
            }
            """)
        }
        if textScale != 1 {
            let percent = Self.number(textScale * 100)
            lines.append("""
            html {
              font-size: \(percent)% !important;
            }
            body {
              font-size: \(percent)% !important;
            }
            """)
        }
        for zap in zaps {
            lines.append(BoostQuickActions.hideElementRule(selector: zap).trimmingCharacters(in: .newlines))
        }
        lines.append(Self.footer)
        return lines.joined(separator: "\n") + "\n"
    }

    var settingsComment: String {
        var parts = [Self.header]
        if let tint {
            parts.append("hue=\(Self.number(tint.hue))")
            parts.append("intensity=\(Self.number(tint.intensity))")
            parts.append("harmony=\(tint.harmony.rawValue)")
        }
        if darkMode { parts.append("dark=1") }
        if let font { parts.append("font=\(font.token)") }
        if textScale != 1 { parts.append("scale=\(Self.number(textScale))") }
        parts.append("zaps=\(zaps.count)")
        return parts.joined(separator: " ") + " */"
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Parse

    /// The visual settings and the hand-written rest of a boost stylesheet.
    /// A stylesheet without the block is all hand-written.
    public static func parse(_ css: String) -> (style: BoostVisualStyle, customCSS: String) {
        guard let headerRange = css.range(of: header),
              let footerRange = css.range(of: footer, range: headerRange.upperBound ..< css.endIndex),
              let commentEnd = css.range(of: "*/", range: headerRange.upperBound ..< footerRange.lowerBound) else {
            return (BoostVisualStyle(), css)
        }
        var style = BoostVisualStyle()
        var tintHue: Double?, intensity = 0.5, harmony = BoostColorHarmony.single
        var zapCount = 0
        for token in css[headerRange.upperBound ..< commentEnd.lowerBound].split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "hue": tintHue = Double(pair[1])
            case "intensity": intensity = Double(pair[1]) ?? 0.5
            case "harmony": harmony = BoostColorHarmony(rawValue: pair[1]) ?? .single
            case "dark": style.darkMode = pair[1] == "1"
            case "font": style.font = BoostFontChoice(token: pair[1])
            case "scale": style.textScale = clampedScale(Double(pair[1]) ?? 1)
            case "zaps": zapCount = Int(pair[1]) ?? 0
            default: continue
            }
        }
        if let tintHue { style.tint = BoostTint(hue: tintHue, intensity: intensity, harmony: harmony) }
        // Zap rules are the block's last rules, one per zap.
        let body = String(css[commentEnd.upperBound ..< footerRange.lowerBound])
        let rules = BoostStyleCompiler.parseRuleBlocks(body)
        for rule in rules.suffix(zapCount) {
            if let brace = rule.firstIndex(of: "{") {
                style.appendZap(String(rule[..<brace]))
            }
        }
        // `compose` writes the block's own newline and one blank line; the
        // rest is the hand-written CSS exactly as typed.
        var suffix = Substring(css[footerRange.upperBound...])
        for _ in 0 ..< 2 where suffix.first == "\n" { suffix = suffix.dropFirst() }
        return (style, String(css[..<headerRange.lowerBound]) + suffix)
    }

    /// The stylesheet for `style` and the hand-written CSS after it.
    public static func compose(_ style: BoostVisualStyle, customCSS: String) -> String {
        let block = style.compiled()
        if block.isEmpty { return customCSS }
        return block + "\n" + customCSS
    }
}

// MARK: - Editor draft

extension BoostEditorDraft {
    /// The draft's visual settings (read from its stylesheet).
    public var visual: BoostVisualStyle { BoostVisualStyle.parse(draftCSS).style }

    /// The draft's hand-written CSS, without the visual block.
    public var customCSS: String { BoostVisualStyle.parse(draftCSS).customCSS }

    public mutating func setVisual(_ style: BoostVisualStyle) {
        draftCSS = BoostVisualStyle.compose(style, customCSS: customCSS)
    }

    public mutating func setCustomCSS(_ css: String) {
        draftCSS = BoostVisualStyle.compose(visual, customCSS: css)
    }

    public mutating func updateVisual(_ change: (inout BoostVisualStyle) -> Void) {
        var style = visual
        change(&style)
        setVisual(style)
    }
}
