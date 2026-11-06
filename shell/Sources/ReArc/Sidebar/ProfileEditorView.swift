import AppKit
import SwiftUI
import SidebarModel

struct ProfileEditorRequest: Identifiable {
    let id = UUID()
    var profileID: Profile.ID?
    var draft: ProfileDraft

    init(profile: Profile? = nil) {
        profileID = profile?.id
        draft = profile.map(ProfileDraft.init(profile:)) ?? ProfileDraft()
    }
}

extension BrowserViewModel {
    func beginProfileCreation() {
        profileEditorRequest = ProfileEditorRequest()
    }

    func beginProfileEditing(_ profile: Profile) {
        profileEditorRequest = ProfileEditorRequest(profile: profile)
    }

    @discardableResult
    func saveProfile(_ draft: ProfileDraft, id: Profile.ID?, selecting: Bool) -> Profile? {
        let profile: Profile?
        if let id {
            guard store.updateProfile(id, from: draft) == nil else { return nil }
            profile = store.profile(withID: id)
        } else {
            profile = store.createProfile(from: draft)
        }
        guard let profile else { return nil }
        profileEditorRequest = nil
        if selecting {
            store.selectProfile(profile.id)
            loadSelectedIfNeeded()
        }
        return profile
    }
}

struct ProfileEditorView: View {
    @State var draft: ProfileDraft
    let isCreating: Bool
    let onSave: (ProfileDraft) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCreating ? "Create Profile" : "Edit Profile").font(.headline)
            HStack(spacing: 10) {
                ProfileAvatarView(profile: Profile(name: draft.name, avatar: draft.avatar, themeColor: draft.themeColor), diameter: 36)
                TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
            }
            IconChooser(selection: Binding(
                get: { draft.avatar.kind },
                set: { draft.avatar = ProfileAvatarDescriptor(kind: $0) }
            ))
            ChooseThemeRow(theme: $draft.themeColor, title: "Color")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create Profile" : "Save") {
                    if onSave(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Shared by profile and item editors so emoji and SF Symbols use the same controls.
struct IconChooser: View {
    @Binding var selection: ProfileAvatarDescriptor.Kind
    @State private var emoji = ""
    @State private var symbol = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(["person.fill"] + Space.iconChoices.filter { $0 != "person.fill" }, id: \.self) { name in
                    Button { selection = .sfSymbol(name: name) } label: {
                        Image(systemName: name)
                            .frame(width: 30, height: 30)
                            .background(selection == .sfSymbol(name: name) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            HStack {
                TextField("Emoji", text: $emoji).textFieldStyle(.roundedBorder)
                Button("Use Emoji") {
                    selection = .emoji(String(emoji.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
                }.disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Emoji & Symbols…") { NSApp.orderFrontCharacterPalette(nil) }
            }
            HStack {
                TextField("SF Symbol name", text: $symbol).textFieldStyle(.roundedBorder)
                Button("Use Symbol") { selection = .sfSymbol(name: trimmedSymbol) }
                    .disabled(NSImage(systemSymbolName: trimmedSymbol, accessibilityDescription: nil) == nil)
            }
        }
        .onAppear {
            switch selection {
            case .emoji(let text): emoji = text
            case .sfSymbol(let name): symbol = name
            }
        }
    }

    private var trimmedSymbol: String { symbol.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct SidebarPersonalizationSheets: ViewModifier {
    let model: BrowserViewModel
    let isOwner: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { isOwner ? model.profileEditorRequest : nil },
                set: { model.profileEditorRequest = $0 }
            )) { request in
                ProfileEditorView(draft: request.draft, isCreating: request.profileID == nil) { draft in
                    model.saveProfile(draft, id: request.profileID, selecting: request.profileID == nil) != nil
                }
            }
            .sheet(isPresented: Binding(
                get: { model.itemIconEditorID != nil && isOwner },
                set: { if !$0 { model.itemIconEditorID = nil } }
            )) {
                if let id = model.itemIconEditorID { ItemIconEditorView(model: model, itemID: id) }
            }
    }
}
