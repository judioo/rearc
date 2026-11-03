import AppKit
import SwiftUI
import SidebarModel

/// Edit Space sheet: name, theme color (Arc style editor swatch pads plus a
/// custom color well, SIDEBAR-SPEC §4.6) and icon (SF Symbols or an emoji).
/// Changes apply live, like Arc's editor; Done closes the sheet.
struct SpaceEditorView: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = ""

    var body: some View {
        let store = model.store
        let space = store.space(withID: spaceID)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SpaceIconView(iconName: space?.iconName ?? "circle.fill", size: 16)
                    .frame(width: 34, height: 34)
                    .background(color(space?.theme ?? .default).opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit(commitName)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Theme").font(.headline)
                ForEach(SpaceTheme.editorPalette.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(SpaceTheme.editorPalette[row], id: \.self) { theme in
                            swatch(theme, selected: space?.theme == theme)
                        }
                    }
                }
                ColorPicker("Custom color", selection: Binding(
                    get: { color(space?.theme ?? .default) },
                    set: { newValue in
                        guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                        store.setSpaceTheme(spaceID, theme: SpaceTheme(
                            red: Double(rgb.redComponent),
                            green: Double(rgb.greenComponent),
                            blue: Double(rgb.blueComponent)
                        ))
                    }
                ), supportsOpacity: false)
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Space.iconChoices, id: \.self) { symbol in
                        Button { store.setSpaceIcon(spaceID, iconName: symbol) } label: {
                            Image(systemName: symbol)
                                .frame(width: 30, height: 30)
                                .background(
                                    space?.iconName == symbol ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                HStack {
                    TextField("Or type an emoji", text: $emoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(commitEmoji)
                    Button("Use") { commitEmoji() }
                        .disabled(emoji.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
                }
            }

            HStack {
                Button("Delete Space…", role: .destructive) {
                    dismiss()
                    model.pendingDeletion = .space(spaceID)
                }
                .disabled(!model.canDeleteSpaces)
                Spacer()
                Button("Done") {
                    commitName()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = space?.name ?? ""
            if let icon = space?.iconName, !Space.isSymbolName(icon) { emoji = icon }
        }
    }

    private func color(_ theme: SpaceTheme) -> Color {
        Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    private func swatch(_ theme: SpaceTheme, selected: Bool) -> some View {
        Button { model.store.setSpaceTheme(spaceID, theme: theme) } label: {
            Circle()
                .fill(color(theme))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func commitName() {
        model.store.renameSpace(spaceID, to: name)
    }

    /// Lowercase words would be read as an SF Symbol name; take them only if one exists.
    private func commitEmoji() {
        let glyph = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if Space.isSymbolName(glyph), NSImage(systemSymbolName: glyph, accessibilityDescription: nil) == nil { return }
        model.store.setSpaceIcon(spaceID, iconName: glyph)
    }
}
