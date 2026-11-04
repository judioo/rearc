import AppKit
import SwiftUI
import SidebarModel

/// The theme part of Edit Space and New Space (Arc `SpaceStyleEditorView`,
/// SIDEBAR-SPEC §4.6): a preview, up to three colour stops (one colour is a
/// plain theme, more make a gradient), the swatch pads and gradient presets,
/// a grain slider and the Automatic / Light / Dark appearance. A swatch or
/// the colour well changes the selected stop and keeps the rest.
struct SpaceStyleEditor: View {
    @Binding var theme: SpaceTheme
    @State private var selectedStop = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let stops = theme.stops
        let stop = min(selectedStop, stops.count - 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme").font(.headline)

            SpaceThemeFill(palette: SpaceThemePalette(
                theme: theme,
                darkAppearance: theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))
            ))
            .frame(height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                ForEach(stops.indices, id: \.self) { index in
                    Button { selectedStop = index } label: {
                        Circle()
                            .fill(Color(stops[index]))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(index == stop ? 0.9 : 0.15),
                                                           lineWidth: index == stop ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(index == 0 ? "Base colour" : "Gradient colour \(index + 1)")
                    .contextMenu {
                        Button("Remove Colour") { remove(index) }.disabled(stops.count < 2)
                    }
                }
                Button {
                    theme = theme.addingStop()
                    selectedStop = theme.stops.count - 1
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(stops.count >= SpaceTheme.maxGradientColors)
                .help("Add a gradient colour (up to \(SpaceTheme.maxGradientColors))")
                if stops.count > 1 {
                    Button { remove(stop) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove the selected colour")
                }
                Spacer()
                ColorPicker("Colour", selection: Binding(
                    get: { Color(stops[stop]) },
                    set: { newValue in
                        guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                        theme = theme.settingStop(stop, to: SpaceTheme(
                            red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent)))
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Custom colour for the selected stop")
            }

            ForEach(SpaceTheme.editorPalette.indices, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(SpaceTheme.editorPalette[row], id: \.self) { swatch in
                        Button { theme = theme.settingStop(stop, to: swatch) } label: {
                            Circle()
                                .fill(Color(swatch))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(stops[stop] == swatch ? 0.9 : 0.12),
                                                               lineWidth: stops[stop] == swatch ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(SpaceTheme.gradientPresets, id: \.self) { preset in
                    Button {
                        var next = preset
                        next.noise = theme.noise
                        next.appearance = theme.appearance
                        theme = next
                        selectedStop = 0
                    } label: {
                        SpaceThemeFill(palette: SpaceThemePalette(theme: preset, darkAppearance: false))
                            .frame(width: 40, height: 22)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(theme.stops == preset.stops ? 0.9 : 0.12),
                                                            lineWidth: theme.stops == preset.stops ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("Gradient preset")
                }
            }

            HStack {
                Text("Grain")
                Slider(value: Binding(get: { theme.noise }, set: { theme.noise = $0 }), in: 0 ... 1)
                Text("\(Int((theme.noise * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            Picker("Appearance", selection: Binding(get: { theme.appearance }, set: { theme.appearance = $0 })) {
                ForEach(SpaceAppearance.allCases, id: \.self) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .help("Light or dark for this space's window, pages, easels and notes; Automatic follows the Mac")
        }
    }

    private func remove(_ index: Int) {
        theme = theme.removingStop(index)
        selectedStop = max(0, min(selectedStop, theme.stops.count - 1))
    }
}
