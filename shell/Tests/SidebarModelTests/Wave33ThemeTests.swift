import XCTest
@testable import SidebarModel

/// Wave 33: the theme editor's colour pad and the dark-mode gradient, fitted
/// to the user's recording of Arc (docs/ARC-RECORDING-ANALYSIS.md §2).
final class Wave33ColorPadTests: XCTestCase {
    /// §2.3's 639 handle samples, binned by radius: (r, n, HSB S, HSB B).
    private let samples: [(r: Double, n: Double, s: Double, b: Double)] = [
        (0.075, 3, 0.96, 0.89), (0.125, 14, 0.95, 0.90), (0.175, 103, 0.91, 0.92), (0.225, 110, 0.73, 0.94),
        (0.275, 222, 0.62, 0.94), (0.325, 104, 0.55, 0.95), (0.375, 82, 0.38, 0.96),
    ]

    func testSaturationFallsFromAVividCentreToAPastelRim() {
        var squared = 0.0, weight = 0.0
        for sample in samples {
            let s = ThemeColorPad.saturation(atRadius: sample.r)
            XCTAssertEqual(s, sample.s, accuracy: 0.12, "r \(sample.r)")
            squared += sample.n * (s - sample.s) * (s - sample.s)
            weight += sample.n
            let b = HSBColor(ThemeColorPad.color(at: .init(angle: 0, radius: sample.r))).brightness
            XCTAssertEqual(b, sample.b, accuracy: 0.07, "brightness is not on the pad")
        }
        XCTAssertLessThan((squared / weight).squareRoot(), 0.06, "weighted rms against the recording")
        XCTAssertEqual(ThemeColorPad.saturation(atRadius: 0), 1, "the centre is vivid")
        XCTAssertLessThan(ThemeColorPad.saturation(atRadius: ThemeColorPad.maxRadius), 0.2, "the rim is pastel")
    }

    func testHueIsTheScreenAngleClockwiseFromThreeOClock() {
        // Screen offsets (y down) at the clock positions §2.3 lists.
        let clock: [(x: Double, y: Double, hue: Double)] = [
            (0.3, 0, 0), (0.15, 0.26, 60), (-0.15, 0.26, 120), (-0.3, 0, 180), (-0.15, -0.26, 240), (0.15, -0.26, 300),
        ]
        for position in clock {
            let point = ThemeColorPad.Point(offsetX: position.x, y: position.y)
            XCTAssertEqual(point.angle, position.hue, accuracy: 0.5)
            XCTAssertEqual(HSBColor(ThemeColorPad.color(at: point)).hue, position.hue, accuracy: 0.5)
        }
        XCTAssertEqual(ThemeColorPad.Point(angle: 90, radius: 0.2).offset.y, 0.2, accuracy: 1e-9, "90° is 6 o'clock")
    }

    func testPlusAddsTheComplementThenSplitsIt() {
        // Frames 803 → 804: yellow at 60.7°, r 0.343 → second handle at 241.0°, r 0.344.
        let two = ThemeColorPad.adding(to: [.init(angle: 60.7, radius: 0.343)])
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[1].angle, 241.0, accuracy: 1)
        XCTAssertEqual(two[1].radius, 0.344, accuracy: 0.005)
        // Frames 1124 → 1128: green 141.8° → 291.6° and 351.3°.
        let three = ThemeColorPad.adding(to: [.init(angle: 141.8, radius: 0.3), .init(angle: 321.3, radius: 0.3)])
        XCTAssertEqual(three.map(\.angle)[1], 291.6, accuracy: 1)
        XCTAssertEqual(three.map(\.angle)[2], 351.3, accuracy: 1)
        XCTAssertEqual(ThemeColorPad.adding(to: three), three, "three at most")
        XCTAssertEqual(ThemeColorPad.removing(from: three).map(\.angle), [141.8, 321.8].map { $0 })
        XCTAssertEqual(ThemeColorPad.removing(from: two).count, 1)
    }

    func testDraggingAnyHandleTurnsAndScalesTheSet() {
        // Frames 825–832: r 0.226 / 0.236 / 0.236 → 0.177 / 0.169 / 0.171, offsets held.
        let points = [ThemeColorPad.Point(angle: 100, radius: 0.226), .init(angle: 250, radius: 0.236), .init(angle: 310, radius: 0.236)]
        let moved = ThemeColorPad.dragging(points, handle: 1, to: .init(angle: 280, radius: 0.169))
        XCTAssertEqual(moved.map(\.angle), [130, 280, 340])
        XCTAssertEqual(moved[0].radius, 0.177, accuracy: 0.02)
        XCTAssertEqual(moved[2].radius, 0.171, accuracy: 0.005)
        XCTAssertEqual(ThemeColorPad.dragging(points, handle: 0, to: .init(angle: 350, radius: 0.226))[1].angle, 140, "wraps round")
    }

    func testPresetsAreOneRowOfNineSaturatedSwatchesAndResetToOneColour() {
        XCTAssertEqual(SpaceTheme.editorVibrant.map(\.spaceColor.hex),
                       ["#EFE6E0", "#EF91B6", "#9D6794", "#EF5260", "#FE794C", "#F8CF4C", "#2AE48A", "#62B2D4", "#5A5C7C"])
        XCTAssertEqual(SpaceTheme.editorSwatchPages.count, 4)
        XCTAssertTrue(SpaceTheme.editorSwatchPages.allSatisfy { $0.count == 9 })
        let catalog = Set(SpaceTheme.editorPalette.joined().map(\.spaceColor.hex))
        XCTAssertTrue(catalog.isDisjoint(with: SpaceTheme.editorVibrant.map(\.spaceColor.hex)), "§2.5: a fourth set")

        let three = ThemeColorPad.theme(.arcDefault, with: ThemeColorPad.adding(to: ThemeColorPad.adding(to: [.init(angle: 30, radius: 0.2)])))
        XCTAssertEqual(three.stops.count, 3)
        let red = SpaceTheme.editorVibrant[3]
        let reset = ThemeColorPad.theme(three, preset: red)
        XCTAssertEqual(reset.stops, [red], "swatch = colour 1 exactly (#EF5260 → handle #F15460)")
        XCTAssertEqual(reset.intensity, three.intensity, "style is kept")
    }

    func testStoredColoursKeepTheirBrightnessAndUnmovedHandlesTheirColour() {
        let slate = SpaceTheme.editorVibrant[8]
        let theme = ThemeColorPad.theme(.arcDefault, preset: slate)
        let points = ThemeColorPad.points(of: theme)
        XCTAssertEqual(ThemeColorPad.theme(theme, with: points).stops, [slate], "no drift on a redraw")
        let added = ThemeColorPad.theme(theme, with: ThemeColorPad.adding(to: points))
        XCTAssertEqual(added.stops[0], slate)
        XCTAssertEqual(HSBColor(added.stops[1].spaceColor).brightness, HSBColor(slate.spaceColor).brightness, accuracy: 0.005,
                       "§2.3: a preset's brightness is off the pad and stays")
        XCTAssertEqual(HSBColor(added.stops[1].spaceColor).hue, HSBColor(slate.spaceColor).hue + 180 - 360, accuracy: 1)
        let cream = ThemeColorPad.theme(.arcDefault, preset: SpaceTheme.editorVibrant[0])
        XCTAssertEqual(ThemeColorPad.theme(cream, with: ThemeColorPad.points(of: cream)).stops, cream.stops,
                       "a swatch paler than the rim stays itself")
    }

    func testTheBuiltInThemeIsAnEmptyPad() {
        XCTAssertTrue(ThemeColorPad.isUnset(.arcDefault))
        XCTAssertEqual(ThemeColorPad.points(of: .arcDefault), [])
        let tapped = ThemeColorPad.theme(.arcDefault, with: [.init(angle: 0, radius: 0.1)])
        XCTAssertFalse(ThemeColorPad.isUnset(tapped))
        XCTAssertEqual(tapped.stops.count, 1, "a tap picks one colour")
        XCTAssertEqual(HSBColor(tapped.spaceColor).brightness, ThemeColorPad.brightness, accuracy: 0.005)
        XCTAssertEqual(HSBColor(tapped.spaceColor).saturation, 0.95, accuracy: 0.005)
    }

    func testHSBRoundTrips() {
        for hex in ["#EF5260", "#2AE48A", "#62B2D4", "#5A5C7C", "#000000", "#FFFFFF", "#FF00FF"] {
            let color = SpaceColor(hex: hex)!
            XCTAssertEqual(HSBColor(color).color.hex, hex)
        }
        XCTAssertEqual(HSBColor(SpaceColor(hex: "#FF0000")!).hue, 0)
        XCTAssertEqual(HSBColor(SpaceColor(hex: "#FF00FF")!).hue, 300)
    }
}
