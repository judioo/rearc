import AppKit
import SwiftUI
import SidebarModel

/// Edit Space sheet: name, theme (Arc's style editor: colours or a
/// gradient, grain and appearance, SIDEBAR-SPEC §4.6), icon (SF Symbols or an emoji) and
/// profile. Changes apply live, like Arc's editor, except a profile change,
/// which asks first; Done closes the sheet.
struct SpaceEditorView: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = ""
    /// A profile change waiting for confirmation (the sheet has its own alert).
    @State private var profileChange: SpaceProfileChange?

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

            if let space {
                profileRow(space)
            }

            SpaceStyleEditor(theme: Binding(
                get: { model.store.space(withID: spaceID)?.theme ?? .default },
                set: { model.store.setSpaceTheme(spaceID, theme: $0) }
            ))

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
        .alert(profileChange.map(model.spaceProfileChangeMessage)?.title ?? "", isPresented: Binding(
            get: { profileChange != nil },
            set: { if !$0 { profileChange = nil } }
        )) {
            Button("Cancel", role: .cancel) { profileChange = nil }
            Button("Move Space") {
                if let change = profileChange { model.changeSpaceProfile(change.spaceID, to: change.profileID) }
                profileChange = nil
            }
        } message: {
            Text(profileChange.map(model.spaceProfileChangeMessage)?.message ?? "")
        }
        .onAppear {
            name = space?.name ?? ""
            if let icon = space?.iconName, !Space.isSymbolName(icon) { emoji = icon }
        }
    }

    private func profileRow(_ space: Space) -> some View {
        let choices = model.store.profileChoices(forSpace: space.id)
        return HStack {
            Text("Profile").font(.headline)
            Spacer()
            Menu(model.store.profile(withID: space.profileID)?.name ?? "Profile") {
                ForEach(choices) { profile in
                    Button("Move to \(profile.name)") {
                        profileChange = SpaceProfileChange(spaceID: space.id, profileID: profile.id)
                    }
                }
            }
            .fixedSize()
            .disabled(choices.isEmpty)
            .help(choices.isEmpty && model.store.profiles.count > 1
                  ? "A profile keeps at least one space"
                  : "Move this space and its tabs to another profile")
        }
    }

    private func color(_ theme: SpaceTheme) -> Color {
        Color(red: theme.red, green: theme.green, blue: theme.blue)
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
