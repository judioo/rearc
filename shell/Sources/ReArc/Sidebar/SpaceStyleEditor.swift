import AppKit
import SwiftUI
import SidebarModel

/// Arc's theme editor (`SpaceStyleEditor`) as the user's recording shows it
/// (ARC-RECORDING-ANALYSIS.md §2): a popover about 357 × 508 pt. At the top a
/// neutral dot-grid pad, 337 pt square, holds one handle per colour, the
/// ✦ / ☀ / ☾ appearance control and the − / + buttons. Under it sit one row
/// of nine swatches between ‹ and ›, then the sine-wave intensity slider and
/// the grain dial. Every change writes through the binding at once, so the
/// window behind redraws in the same frame (§2.9).
struct SpaceStyleEditor: View {
    @Binding var theme: SpaceTheme
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 357
    static let height: CGFloat = 508
    static let padSide: CGFloat = 337

    var body: some View {
        let dark = theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))
        VStack(spacing: 0) {
            ThemeColorPadView(theme: $theme, dark: dark)
                .frame(width: Self.padSide, height: Self.padSide)
                .padding(.top, 10)
            SwatchRow(theme: $theme)
                .frame(height: 30)
                .padding(.top, 18)
            HStack(spacing: 0) {
                SineSlider(value: Binding(get: { theme.intensity }, set: { theme.intensity = $0 }),
                           range: SpaceTheme.intensityRange, enabled: !ThemeColorPad.isUnset(theme))
                    .frame(width: 220, height: 43)
                    .padding(.leading, 20)
                Spacer(minLength: 0)
                GrainDial(noise: Binding(get: { theme.noise }, set: { theme.noise = $0 }),
                          texture: Binding(get: { theme.texture }, set: { theme.texture = $0 }),
                          enabled: !ThemeColorPad.isUnset(theme))
                    .frame(width: 72, height: 72)
                    .padding(.trailing, 22)
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: Self.height)
        .background(EditorColors.panel(dark: dark))
        // The editor follows the space's appearance, not the Mac's (§2.1).
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// The editor's neutral greys, sampled from the recording (frames 476, 1000):
/// light pad `#ECEBF1` over a `#FCF9FE` panel; dark `#767469` over `#6D6D68`
/// (both partly the window theme showing through the popover's material).
enum EditorColors {
    static func panel(dark: Bool) -> Color { dark ? Color(white: 0.43) : Color(white: 0.985) }
    static func pad(dark: Bool) -> Color { dark ? Color(white: 0.465) : Color(white: 0.925) }
    static func dot(dark: Bool) -> Color { dark ? Color.white.opacity(0.13) : Color.black.opacity(0.11) }
    static func ink(dark: Bool) -> Color { dark ? Color.white.opacity(0.75) : Color.black.opacity(0.55) }
    static func faint(dark: Bool) -> Color { dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16) }
}

/// The pad: a neutral dot grid (it shows no colours), one handle per colour,
/// the appearance control at the top and − / + inside its bottom edge. Angle
/// is hue and distance from the centre lowers saturation (`ThemeColorPad`).
/// Dragging any handle turns and scales the set; a tap on an empty spot
/// moves the active handle there and keeps following the drag.
private struct ThemeColorPadView: View {
    @Binding var theme: SpaceTheme
    let dark: Bool
    /// The handle drawn large: the last one touched (§2.2).
    @State private var active = 0
    /// The set while a drag runs, so handles do not snap to the nearest
    /// stored saturation between frames.
    @State private var drag: (start: [ThemeColorPad.Point], theme: SpaceTheme, handle: Int)?
    @State private var dragPoints: [ThemeColorPad.Point]?

    static let activeHandle: CGFloat = 37
    static let handle: CGFloat = 27

    var body: some View {
        let points = dragPoints ?? ThemeColorPad.points(of: theme)
        let colors = theme.stops.map(\.spaceColor)
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                DotGrid(dark: dark)
                if points.isEmpty {
                    Text("Tap to pick a color for this space")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(EditorColors.ink(dark: dark))
                        .allowsHitTesting(false)
                }
                ForEach(Array(points.enumerated()).reversed(), id: \.offset) { index, point in
                    let size = index == min(active, points.count - 1) ? Self.activeHandle : Self.handle
                    Circle()
                        .fill(Color(colors.indices.contains(index) ? colors[index] : ThemeColorPad.color(at: point)))
                        .frame(width: size, height: size)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .position(location(of: point, side: side))
                        .accessibilityLabel("Colour \(index + 1)")
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in changed(value, points: points, side: side) }
                .onEnded { _ in
                    drag = nil
                    dragPoints = nil
                })
            .overlay(alignment: .top) {
                AppearanceControl(appearance: Binding(get: { theme.appearance }, set: { theme.appearance = $0 }), dark: dark)
                    .padding(.top, 38 - 14)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    padButton("minus", help: "Remove a colour", enabled: points.count > 1) {
                        theme = ThemeColorPad.theme(theme, with: ThemeColorPad.removing(from: points))
                        active = 0
                    }
                    padButton("plus", help: "Add a colour", enabled: !points.isEmpty && points.count < SpaceTheme.maxGradientColors) {
                        theme = ThemeColorPad.theme(theme, with: ThemeColorPad.adding(to: points))
                    }
                }
                .padding(.bottom, 30 - 14)
            }
        }
        .background(EditorColors.pad(dark: dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// A handle's centre: the pad's centre plus the point's offset, y down.
    private func location(of point: ThemeColorPad.Point, side: CGFloat) -> CGPoint {
        let offset = point.offset
        return CGPoint(x: side / 2 + offset.x * side, y: side / 2 + offset.y * side)
    }

    private func point(at location: CGPoint, side: CGFloat) -> ThemeColorPad.Point {
        ThemeColorPad.Point(offsetX: (location.x - side / 2) / side, y: (location.y - side / 2) / side)
    }

    private func changed(_ value: DragGesture.Value, points: [ThemeColorPad.Point], side: CGFloat) {
        let target = point(at: value.location, side: side)
        if drag == nil {
            // A press on a handle grabs it; elsewhere the active handle jumps there.
            func distance(_ index: Int) -> CGFloat {
                let centre = location(of: points[index], side: side)
                return hypot(centre.x - value.startLocation.x, centre.y - value.startLocation.y)
            }
            let hit = points.indices.min { distance($0) < distance($1) }
            let handle = hit.flatMap { distance($0) <= Self.activeHandle / 2 + 4 ? $0 : nil }
                ?? min(active, max(points.count - 1, 0))
            active = handle
            drag = (points, theme, handle)
        }
        guard let drag else { return }
        let next = drag.start.isEmpty ? [target] : ThemeColorPad.dragging(drag.start, handle: drag.handle, to: target)
        dragPoints = next
        theme = ThemeColorPad.theme(drag.theme, with: next)
    }

    private func padButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 40, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? EditorColors.ink(dark: dark) : EditorColors.faint(dark: dark))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Arc's `DotGrid` pad background, drawn: fine grey dots on a 5 pt grid.
private struct DotGrid: View {
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            let dot = EditorColors.dot(dark: dark)
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)), with: .color(dot))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// ✦ automatic, ☀ light, ☾ dark: a three-way control on a 40 pt pitch, the
/// chosen glyph on a rounded-square chip. A tap selects directly and the
/// window switches in the same frame (§2.7).
struct AppearanceControl: View {
    @Binding var appearance: SpaceAppearance
    let dark: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SpaceAppearance.allCases, id: \.self) { choice in
                Button { appearance = choice } label: {
                    Image(systemName: Self.symbol(choice))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(EditorColors.ink(dark: dark))
                        .frame(width: 28, height: 28)
                        .background(appearance == choice ? EditorColors.faint(dark: dark).opacity(0.8) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(width: 40, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Appearance: \(choice.title) — pages, easels and notes in this space follow it")
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(appearance == choice ? .isSelected : [])
            }
        }
    }

    static func symbol(_ appearance: SpaceAppearance) -> String {
        switch appearance {
        case .automatic: "sparkles"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// One row of nine swatches between ‹ and ›; the arrows page through the
/// sets. A tap resets the theme to that one colour, and its handle springs
/// there with a slight overshoot (≈ 300 ms, ≈ 7 %; §2.4).
private struct SwatchRow: View {
    @Binding var theme: SpaceTheme
    @State private var page = 0

    /// ζ 0.65 overshoots by e^(−πζ/√(1−ζ²)) ≈ 6.8 %.
    static let presetSpring = Animation.spring(response: 0.3, dampingFraction: 0.65)

    var body: some View {
        let swatches = SpaceTheme.editorSwatchPages[page]
        HStack(spacing: 0) {
            chevron("chevron.left", enabled: page > 0) { page -= 1 }
            HStack(spacing: 29.5 - 23) {
                ForEach(swatches, id: \.self) { swatch in
                    let chosen = theme.stops.count == 1 && theme.baseColor == swatch
                    Button {
                        withAnimation(Self.presetSpring) { theme = ThemeColorPad.theme(theme, preset: swatch) }
                    } label: {
                        Circle()
                            .fill(Color(swatch.spaceColor))
                            .frame(width: 23, height: 23)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(chosen ? 0.6 : 0.08), lineWidth: chosen ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(SpaceTheme.editorSwatchPageNames[page]) \(swatch.spaceColor.hex)")
                }
            }
            .frame(width: 8 * 29.5 + 23)
            chevron("chevron.right", enabled: page < SpaceTheme.editorSwatchPages.count - 1) { page += 1 }
        }
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(enabled ? 0.45 : 0.15))
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous colours" : "More colours")
    }
}

/// Arc's `SineSlider`: a sine wave whose amplitude grows with the value at
/// a constant wavelength, dark left of a white capsule thumb and light right
/// of it (§2.6; ink 27 px tall at a high value, 9 px at a low one).
struct SineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var enabled = true

    static let periods = 7.0
    static let minimumAmplitude: CGFloat = 3
    static let maximumAmplitude: CGFloat = 17

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    /// The wave's amplitude at `fraction` of the range.
    static func amplitude(at fraction: Double) -> CGFloat {
        minimumAmplitude + (maximumAmplitude - minimumAmplitude) * CGFloat(min(max(fraction, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let thumbX = enabled ? fraction * size.width : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06)).frame(height: 16)
                wave(in: size).stroke(Color.primary.opacity(enabled ? 0.2 : 0.12), lineWidth: 3.5)
                if enabled {
                    wave(in: size).stroke(Color.primary.opacity(0.55), lineWidth: 3.5)
                        .mask(alignment: .leading) { Rectangle().frame(width: thumbX) }
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 14, height: 34)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .position(x: thumbX, y: size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in set(x: drag.location.x, width: size.width) })
        }
        .disabled(!enabled)
        .accessibilityElement()
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction(adjust)
    }

    private func wave(in size: CGSize) -> Path {
        var path = Path()
        let amplitude = Self.amplitude(at: enabled ? fraction : 0.25)
        let steps = max(Int(size.width), 1)
        for step in 0 ... steps {
            let t = Double(step) / Double(steps)
            let p = CGPoint(x: t * size.width, y: size.height / 2 - amplitude * sin(t * Self.periods * 2 * .pi))
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func set(x: CGFloat, width: CGFloat) {
        let t = min(max(x / max(width, 1), 0), 1)
        value = range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = direction == .increment ? 0.05 : -0.05
        value = min(max(value + step, range.lowerBound), range.upperBound)
    }
}

/// Arc's grain dial (`SpaceStyleDialView`, `NoiseFactorGesture`): a ring of
/// 24 dots round a face that is blank at 0 and grey when on, with a white
/// pointer tick at the ring showing the angle (§2.8). Turn it by dragging
/// round it. Right-click picks the texture (the recording never showed a
/// texture choice, so it stays out of sight).
struct GrainDial: View {
    @Binding var noise: Double
    @Binding var texture: SpaceTexture
    var enabled = true
    @Environment(\.colorScheme) private var colorScheme

    static let dots = 24
    static let ring: CGFloat = 68
    /// 0 points at 12 o'clock; 1 is this far clockwise.
    static let sweep = 330.0

    var body: some View {
        let dark = colorScheme == .dark
        GeometryReader { geometry in
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(0 ..< Self.dots, id: \.self) { index in
                    let angle = Double(index) / Double(Self.dots) * 360
                    let lit = enabled && noise > 0 && angle <= noise * Self.sweep
                    Circle()
                        .fill(lit ? EditorColors.ink(dark: dark) : EditorColors.faint(dark: dark))
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -Self.ring / 2)
                        .rotationEffect(.degrees(angle))
                }
                Circle()
                    .fill(noise > 0 && enabled ? (dark ? Color.black.opacity(0.35) : Color(white: 0.74)) : (dark ? Color.white.opacity(0.06) : Color.white))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                if enabled {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 5, height: 12)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .offset(y: -Self.ring / 2)
                        .rotationEffect(.degrees(noise * Self.sweep))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                // Clockwise from 12 o'clock; past the sweep's end snaps to the nearer end.
                var degrees = atan2(drag.location.x - centre.x, centre.y - drag.location.y) * 180 / .pi
                if degrees < 0 { degrees += 360 }
                noise = degrees > Self.sweep ? (degrees > (360 + Self.sweep) / 2 ? 0 : 1) : degrees / Self.sweep
            })
        }
        .disabled(!enabled)
        .contextMenu {
            Picker("Texture", selection: $texture) {
                ForEach(SpaceTexture.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("Grain \(Int((noise * 100).rounded()))% — drag round the dial; right-click for the texture")
        .accessibilityElement()
        .accessibilityLabel("Grain")
        .accessibilityValue("\(Int((noise * 100).rounded())) percent, \(texture.title)")
        .accessibilityAdjustableAction { direction in
            noise = min(max(noise + (direction == .increment ? 0.05 : -0.05), 0), 1)
        }
    }
}

/// "Choose a Theme": the row in Create a Space and Edit Space that opens the
/// editor as a popover pointing left at it (§2.1).
struct ChooseThemeRow: View {
    @Binding var theme: SpaceTheme
    var title = "Choose a Theme"
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                ThemeSwatchPreview(theme: theme)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(isPresented ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            SpaceStyleEditor(theme: $theme)
        }
    }
}

/// The theme's colours as a short row of dots (none on the built-in theme).
private struct ThemeSwatchPreview: View {
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: -4) {
            if !ThemeColorPad.isUnset(theme) {
                ForEach(Array(theme.stops.enumerated()), id: \.offset) { _, stop in
                    Circle()
                        .fill(Color(stop.spaceColor))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                }
            }
        }
    }
}
