import AppKit
import SwiftUI
import SidebarModel

/// Create a Space as Arc lays it out (ARC-RECORDING-ANALYSIS.md §5.2): a
/// title and subtitle, the name field with a leading icon button, the
/// Profile row, Choose a Theme (the editor popover), then a full-width
/// Create Space button in the theme's colour with Cancel under it. A new
/// space starts on Arc's built-in theme, and the window previews the theme
/// as it is edited. Nothing is created until Create; Cancel or Escape
/// leaves the sidebar unchanged. It stays a sheet: Arc pages it into the
/// sidebar as a new space, which is not built yet.
struct SpaceCreationView: View {
    let model: BrowserViewModel
    @State var draft: SpaceDraft
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    @State private var choosingIcon = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("Create a Space").font(.system(size: 17, weight: .semibold))
            Text("Separate your tabs for life, work, projects, and more.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            HStack(spacing: 8) {
                Button { choosingIcon = true } label: {
                    SpaceIconView(iconName: draft.iconName, size: 12)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose an icon")
                .popover(isPresented: $choosingIcon, arrowEdge: .bottom) { iconPicker }
                TextField("Space name…", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(create)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if model.store.profiles.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "face.smiling").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Profile").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Picker("Profile", selection: $draft.profileID) {
                        ForEach(model.store.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("The space's tabs use this profile's cookies, history and favorites")
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            ChooseThemeRow(theme: $draft.theme)

            Spacer(minLength: 12)

            Button(action: create) {
                Text("Create Space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(createColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .opacity(draft.canCreate(in: model.store) ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canCreate(in: model.store))
            Button("Cancel", role: .cancel) {
                model.spaceCreationDraft = nil
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 260, height: 430)
        // The window behind previews the new space's theme as it is edited.
        .onChange(of: draft.theme) { _, theme in model.spaceCreationDraft?.theme = theme }
    }

    /// The theme's accent, as Arc tints the button (red on a red theme).
    private var createColor: Color {
        Color(SpaceThemeRoles(theme: draft.theme).semantic(dark: false).foregroundPrimary)
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                ForEach(Space.iconChoices, id: \.self) { symbol in
                    Button {
                        draft.iconName = symbol
                        choosingIcon = false
                    } label: {
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
                    .frame(width: 120)
                    .onSubmit(useEmoji)
                Button("Use") { useEmoji() }
                    .disabled(emoji.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
        }
        .padding(12)
    }

    private func create() {
        guard model.createSpace(from: draft) != nil else { return }
        dismiss()
    }

    /// Lowercase words would be read as an SF Symbol name; take them only if one exists.
    private func useEmoji() {
        let glyph = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glyph.isEmpty else { return }
        if Space.isSymbolName(glyph), NSImage(systemSymbolName: glyph, accessibilityDescription: nil) == nil { return }
        draft.iconName = Space.isSymbolName(glyph) ? glyph : String(glyph.prefix(2))
    }
}
