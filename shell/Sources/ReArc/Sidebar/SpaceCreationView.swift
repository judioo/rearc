import AppKit
import SwiftUI
import SidebarModel

/// New Space dialog (Arc `SpaceCreationView`, SIDEBAR-SPEC §4.6): name,
/// profile, theme and icon. Nothing is created until Create; Cancel or
/// Escape leaves the sidebar unchanged.
struct SpaceCreationView: View {
    let model: BrowserViewModel
    @State var draft: SpaceDraft
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space").font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                SpaceIconView(iconName: draft.iconName, size: 16)
                    .frame(width: 34, height: 34)
                    .background(color(draft.theme).opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                TextField("Space name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit(create)
            }

            if model.store.profiles.count > 1 {
                Picker("Profile", selection: $draft.profileID) {
                    ForEach(model.store.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .help("The space's tabs use this profile's cookies, history and favorites")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Theme").font(.headline)
                ForEach(SpaceTheme.editorPalette.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(SpaceTheme.editorPalette[row], id: \.self) { theme in
                            swatch(theme)
                        }
                    }
                }
                ColorPicker("Custom color", selection: Binding(
                    get: { color(draft.theme) },
                    set: { newValue in
                        guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                        draft.theme = SpaceTheme(
                            red: Double(rgb.redComponent),
                            green: Double(rgb.greenComponent),
                            blue: Double(rgb.blueComponent)
                        )
                    }
                ), supportsOpacity: false)
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Space.iconChoices, id: \.self) { symbol in
                        Button { draft.iconName = symbol } label: {
                            Image(systemName: symbol)
                                .frame(width: 30, height: 30)
                                .background(
                                    draft.iconName == symbol ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
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
                        .onSubmit(useEmoji)
                    Button("Use") { useEmoji() }
                        .disabled(emoji.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.spaceCreationDraft = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create Space", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCreate(in: model.store))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        guard model.createSpace(from: draft) != nil else { return }
        dismiss()
    }

    private func color(_ theme: SpaceTheme) -> Color {
        Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    private func swatch(_ theme: SpaceTheme) -> some View {
        let selected = draft.theme == theme
        return Button { draft.theme = theme } label: {
            Circle()
                .fill(color(theme))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Lowercase words would be read as an SF Symbol name; take them only if one exists.
    private func useEmoji() {
        let glyph = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glyph.isEmpty else { return }
        if Space.isSymbolName(glyph), NSImage(systemSymbolName: glyph, accessibilityDescription: nil) == nil { return }
        draft.iconName = Space.isSymbolName(glyph) ? glyph : String(glyph.prefix(2))
    }
}
