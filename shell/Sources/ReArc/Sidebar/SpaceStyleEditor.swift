import AppKit
import SwiftUI
import SidebarModel

/// The theme part of Edit Space and New Space, after Arc's `SpaceStyleEditor`
/// (THEMES.md §1): a colour pad with one draggable handle per colour (up to
/// three; colour 1 carries the others round with it), + / − colour buttons
/// and the harmony, the Pastel / Greyscale / Drab preset pills, the
/// Automatic → Light → Dark toggle, a sine-wave intensity slider and a
/// grain dial whose face is the chosen texture. Every change writes through
/// the binding at once, so the window behind re-renders live. Sizes are the
/// spec's starting points (pad 260 pt, handles 24 pt, dial 56 pt, slider
/// 200 × 28 pt), still to confirm against Arc (§8).
struct SpaceStyleEditor: View {
    @Binding var theme: SpaceTheme
    @State private var harmony: ThemeHarmony = .analogous
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let points = theme.stops.map { ThemeColorPad.point(of: $0.spaceColor) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Theme").font(.headline)
                Spacer()
                AppearanceToggle(appearance: Binding(get: { theme.appearance }, set: { theme.appearance = $0 }))
            }

            ThemeLayerView(theme: theme, dark: theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme)))
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            HStack(alignment: .top, spacing: 12) {
                ThemeColorPadView(points: points) { newPoints in
                    theme = ThemeColorPad.theme(theme, with: newPoints)
                }
                .frame(width: 200, height: 200)

                VStack(spacing: 10) {
                    Button {
                        theme = ThemeColorPad.theme(theme, with: ThemeColorPad.adding(to: points, harmony: harmony))
                    } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                        .disabled(points.count >= SpaceTheme.maxGradientColors)
                        .help("Add a colour (up to \(SpaceTheme.maxGradientColors))")
                    Button {
                        theme = theme.removingStop(theme.stops.count - 1)
                    } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                        .disabled(points.count < 2)
                        .help("Remove the last colour")
                    Menu {
                        Picker("Harmony", selection: $harmony) {
                            ForEach(ThemeHarmony.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: { Image(systemName: "circle.hexagongrid") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("How added colours sit around colour 1")
                    Spacer(minLength: 0)
                    GrainDial(noise: Binding(get: { theme.noise }, set: { theme.noise = $0 }),
                              texture: Binding(get: { theme.texture }, set: { theme.texture = $0 }))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(height: 200)
            }

            HStack(spacing: 8) {
                Text("Intensity").font(.callout).frame(width: 62, alignment: .leading)
                SineSlider(value: Binding(get: { theme.intensity }, set: { theme.intensity = $0 }),
                           range: SpaceTheme.intensityRange)
                    .frame(width: 200, height: 28)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(SpaceTheme.editorPalette.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(SpaceTheme.editorPalette[row], id: \.self) { swatch in
                            let chosen = theme.stops.count == 1 && theme.baseColor == swatch
                            Button {
                                // A preset sets the theme to that single colour (Arc).
                                var next = theme.withBaseColor(swatch)
                                next.gradientColors = []
                                theme = next
                            } label: {
                                Capsule()
                                    .fill(Color(swatch))
                                    .frame(width: 28, height: 16)
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(chosen ? 0.85 : 0.12),
                                                                    lineWidth: chosen ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help("\(SpaceTheme.editorPaletteNames[row]) \(swatch.spaceColor.hex)")
                        }
                    }
                }
            }
        }
        .frame(width: 300)
    }
}

/// The pad: a hue wheel fading to white at the centre, over a dot grid, with
/// a handle per colour. Dragging colour 1 turns the others with it.
private struct ThemeColorPadView: View {
    let points: [ThemeColorPad.Point]
    let onChange: ([ThemeColorPad.Point]) -> Void
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - 12
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                DotGrid()
                Circle()
                    .fill(AngularGradient(
                        colors: stride(from: 0.0, through: 360, by: 30).map {
                            Color(ThemeColorPad.color(at: .init(angle: -$0, radius: 1)))
                        },
                        center: .center
                    ))
                    .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                                          startRadius: 0, endRadius: radius)))
                    .opacity(0.55)
                    .frame(width: radius * 2, height: radius * 2)
                ForEach(points.indices.reversed(), id: \.self) { index in
                    let point = points[index]
                    let theta = point.angle * .pi / 180
                    Circle()
                        .fill(Color(ThemeColorPad.color(at: point)))
                        .frame(width: index == 0 ? 26 : 22, height: index == 0 ? 26 : 22)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .position(x: centre.x + radius * point.radius * cos(theta),
                                  y: centre.y - radius * point.radius * sin(theta))
                        .accessibilityLabel("Colour \(index + 1)")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = dragging ?? nearest(to: value.startLocation, centre: centre, radius: radius)
                        dragging = index
                        let dx = value.location.x - centre.x, dy = centre.y - value.location.y
                        let target = ThemeColorPad.Point(angle: atan2(dy, dx) * 180 / .pi,
                                                         radius: (dx * dx + dy * dy).squareRoot() / radius)
                        var next = points
                        if index == 0 {
                            next = ThemeColorPad.dragBase(points, to: target)
                        } else {
                            next[index] = target
                        }
                        onChange(next)
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }

    private func nearest(to location: CGPoint, centre: CGPoint, radius: CGFloat) -> Int {
        let distances = points.enumerated().map { index, point -> (Int, CGFloat) in
            let theta = point.angle * .pi / 180
            let x = centre.x + radius * point.radius * cos(theta), y = centre.y - radius * point.radius * sin(theta)
            return (index, hypot(location.x - x, location.y - y))
        }
        return distances.min { $0.1 < $1.1 }?.0 ?? 0
    }
}

/// Arc's `DotGrid` pad background, drawn: grey dots on a 10 pt grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 10
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                                 with: .color(.primary.opacity(0.12)))
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Automatic → Light → Dark, one click each (Arc's `LightDarkToggleView`;
/// its Lottie morph becomes an SF Symbol replace).
private struct AppearanceToggle: View {
    @Binding var appearance: SpaceAppearance

    var body: some View {
        Button {
            appearance = switch appearance {
            case .automatic: .light
            case .light: .dark
            case .dark: .automatic
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Appearance: \(appearance.title) — pages, easels and notes in this space follow it")
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.title)
    }

    private var symbol: String {
        switch appearance {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// Arc's `SineSlider`: the track is a sine wave whose amplitude grows with
/// the value; drag anywhere along it.
private struct SineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .leading) {
                wave(in: size).stroke(Color.primary.opacity(0.18), lineWidth: 2)
                wave(in: size).trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .position(point(at: fraction, in: size))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in set(x: drag.location.x, width: size.width) })
        }
        .accessibilityElement()
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction(adjust)
    }

    private func amplitude(_ height: CGFloat) -> CGFloat { (height / 2 - 3) * (0.25 + 0.75 * fraction) }

    private func point(at t: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: t * size.width, y: size.height / 2 - amplitude(size.height) * sin(t * 4 * .pi))
    }

    private func wave(in size: CGSize) -> Path {
        var path = Path()
        let steps = max(Int(size.width), 1)
        for step in 0 ... steps {
            let p = point(at: Double(step) / Double(steps), in: size)
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

/// Arc's grain dial (`SpaceStyleDialView`, `NoiseFactorGesture`): a 56 pt
/// knob faced with the texture, turned by dragging up/down or round it.
/// Its menu picks the texture (Arc's `AdvancedOptionsView` placement is
/// unobserved).
private struct GrainDial: View {
    @Binding var noise: Double
    @Binding var texture: SpaceTexture
    @State private var start: Double?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: ThemeTextureTiles.tile(texture))
                .resizable(resizingMode: .tile)
                .frame(width: 56, height: 56)
                .background(Color(white: 0.92))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .overlay {
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 3, height: 10)
                        .offset(y: -20)
                        .rotationEffect(.degrees(-135 + 270 * noise))
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    let origin = start ?? noise
                    start = origin
                    noise = min(max(origin + Double(drag.translation.width - drag.translation.height) / 120, 0), 1)
                }.onEnded { _ in start = nil })
                .contextMenu { texturePicker }
                .help("Grain \(Int((noise * 100).rounded()))% — drag to turn; right-click for the texture")
                .accessibilityElement()
                .accessibilityLabel("Grain")
                .accessibilityValue("\(Int((noise * 100).rounded())) percent, \(texture.title)")
                .accessibilityAdjustableAction(adjust)
            Menu(texture.title) { texturePicker }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
        }
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        noise = min(max(noise + (direction == .increment ? 0.05 : -0.05), 0), 1)
    }

    @ViewBuilder
    private var texturePicker: some View {
        Picker("Texture", selection: $texture) {
            ForEach(SpaceTexture.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }
}
