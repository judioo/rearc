import AppKit
import SwiftUI
import SidebarModel

struct ProfileEditorRequest: Identifiable {
    let id = UUID()
    var profileID: Profile.ID?
    var draft: ProfileDraft
    /// New Profile… from a space's profile menu: the new profile becomes
    /// that space's container instead of getting a starter space.
    var spaceID: Space.ID?

    init(profile: Profile? = nil, forSpace spaceID: Space.ID? = nil) {
        profileID = profile?.id
        draft = profile.map(ProfileDraft.init(profile:)) ?? ProfileDraft()
        self.spaceID = profile == nil ? spaceID : nil
    }
}

extension BrowserViewModel {
    func beginProfileCreation(forSpace spaceID: Space.ID? = nil) {
        let request = ProfileEditorRequest(forSpace: spaceID)
        guard spaceEditorID != nil else {
            profileEditorRequest = request
            return
        }
        // From the Edit Theme and Icon sheet: a window shows one sheet at a
        // time, so the profile editor opens once that sheet has gone.
        spaceEditorID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.profileEditorRequest = request
        }
    }

    func beginProfileEditing(_ profile: Profile) {
        profileEditorRequest = ProfileEditorRequest(profile: profile)
    }

    /// At launch: pictures no profile names any more (replaced, the profile
    /// deleted, or changed on another Mac). Not after a load that fell back
    /// from a damaged sidebar.json, whose profiles may still come back.
    func removeUnusedProfileAvatarImages() {
        guard persistence.loadOutcome == .loaded else { return }
        avatarImages.removeUnused(keeping: store.profileAvatarImageNames)
    }

    @discardableResult
    func saveProfile(_ draft: ProfileDraft, id: Profile.ID?, selecting: Bool, forSpace spaceID: Space.ID? = nil) -> Profile? {
        let profile: Profile?
        let previousImage = id.flatMap { store.profile(withID: $0)?.avatar.image }
        if let id {
            guard store.updateProfile(id, from: draft) == nil else { return nil }
            profile = store.profile(withID: id)
        } else {
            let assigning = spaceID.flatMap { store.space(withID: $0) } != nil
            profile = store.createProfile(from: draft, createInitialSpace: !assigning)
        }
        guard let profile else { return nil }
        profileEditorRequest = nil
        if let previousImage, !store.profileAvatarImageNames.contains(previousImage) { avatarImages.remove(previousImage) }
        if id == nil, let spaceID, store.space(withID: spaceID) != nil {
            // Choosing New Profile… for this space is the confirmation:
            // its tabs reload signed out in the new container.
            changeSpaceProfile(spaceID, to: profile.id)
        } else if selecting {
            store.selectProfile(profile.id)
            loadSelectedIfNeeded()
        }
        return profile
    }
}

struct ProfileEditorView: View {
    @State var draft: ProfileDraft
    let isCreating: Bool
    var images: ProfileAvatarImageStore = .shared
    let onSave: (ProfileDraft) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var imageProblem: String?
    @State private var isDropTargeted = false
    @State private var isReadingImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCreating ? "Create Profile" : "Edit Profile").font(.headline)
            HStack(spacing: 10) {
                avatarPreview
                TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
            }
            imageRow
            // Choosing a symbol or emoji replaces the picture.
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
                .disabled(!draft.canSave || isReadingImage)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onPasteCommand(of: ProfileAvatarImageIntake.dropTypes) { providers in
            _ = ProfileAvatarImageIntake.loadSource(from: providers) { if let source = $0 { adopt(source) } }
        }
    }

    private var avatarPreview: some View {
        ProfileAvatarView(profile: Profile(name: draft.name, avatar: draft.avatar, themeColor: draft.themeColor), diameter: 44, images: images)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isDropTargeted ? 1 : 0))
            .onDrop(of: ProfileAvatarImageIntake.dropTypes, isTargeted: $isDropTargeted) { providers in
                ProfileAvatarImageIntake.loadSource(from: providers) { if let source = $0 { adopt(source) } }
            }
            .contextMenu {
                Button("Choose Image…", action: chooseImage)
                Button("Paste Image", action: pasteImage)
                if draft.avatar.image != nil { Button("Remove Image") { draft.avatar.image = nil } }
            }
            .help("Drop or paste an image here to use it as the avatar")
            .accessibilityLabel("Avatar")
    }

    private var imageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Choose Image…", action: chooseImage)
                Button("Paste Image", action: pasteImage)
                if draft.avatar.image != nil {
                    Button("Remove Image") {
                        draft.avatar.image = nil
                        imageProblem = nil
                    }
                }
                if isReadingImage { ProgressView().controlSize(.small) }
            }
            .disabled(isReadingImage)
            Group {
                if let imageProblem {
                    Text(imageProblem).foregroundStyle(.red)
                } else if let name = draft.avatar.image {
                    // Other Macs, and builds before pictures, show the symbol or emoji below.
                    Text(images.contains(name) ? "The image stays on this Mac." : "The image is on another Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // An alias is read as the alias file, never followed to what it names.
        panel.resolvesAliases = false
        panel.message = "Choose an image for this profile's avatar."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(.file(url))
    }

    private func pasteImage() {
        guard let source = ProfileAvatarImageIntake.source(from: .general) else {
            imageProblem = "There's no image to paste. Copy an image or an image file first."
            return
        }
        adopt(source)
    }

    private func adopt(_ source: ProfileAvatarImageIntake.Source) {
        isReadingImage = true
        imageProblem = nil
        ProfileAvatarImageIntake.adopt(source, into: images) { result in
            isReadingImage = false
            switch result {
            case .success(let name): draft.avatar.image = name
            case .failure(let error): imageProblem = error.message
            }
        }
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
                ProfileEditorView(draft: request.draft, isCreating: request.profileID == nil, images: model.avatarImages) { draft in
                    model.saveProfile(draft, id: request.profileID, selecting: request.profileID == nil,
                                      forSpace: request.spaceID) != nil
                }
            }

    }
}
