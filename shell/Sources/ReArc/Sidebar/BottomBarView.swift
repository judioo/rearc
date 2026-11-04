import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// The sidebar's bottom bar as Arc draws it (THEMES.md §4.7): the Library
/// (archive) button at the left, one 4 pt dot per space of this window's
/// profile on a 9 pt pitch with the current space's icon in place of its
/// dot, and the "+" menu at the right, 17 pt in from each side and centred
/// 24.5 pt above the window's bottom. Click a dot to switch, right-click
/// for the space menu, drag to reorder, drop a sidebar item on one to move
/// it there (hovering a drag over one switches to it). Downloads and the
/// sync dot show only while they have something to say; the space and
/// profile lists open from the "+" menu (SIDEBAR-SPEC §3.1.6, §4.3, §4.7).
struct BottomBarView: View {
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome
    @State private var draggedSpaceID: Space.ID?
    @State private var showingSpaceList = false
    @State private var showingProfileList = false
    @State private var renamingProfileID: Profile.ID?
    @State private var renameDraft = ""
    @State private var profileActionError: String?

    static let height: CGFloat = 49

    var body: some View {
        let current = model.space(in: window)
        let profile = model.profile(in: window)
        HStack(spacing: 0) {
            // Arc's Home button (`SidebarHomeButton`): opens the Library on
            // its last page, or closes it.
            let libraryOpen = model.librarySection(in: window) != nil
            Button { model.toggleLibrary(in: window) } label: {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(libraryOpen ? chrome.accent : chrome.glyph)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Library: Spaces, Downloads, Media, Easels & Notes, Archive and Boosts")
            .accessibilityLabel("Library")
            .popover(isPresented: $showingProfileList, arrowEdge: .top) {
                ProfileListView(
                    model: model,
                    isPresented: $showingProfileList,
                    onRename: beginRename,
                    onDelete: attemptDelete
                )
            }

            Spacer(minLength: 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    let spaces = model.store.spaces(in: current.profileID)
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        SpaceIconButton(
                            model: model,
                            space: space,
                            index: index,
                            isCurrent: space.id == current.id,
                            draggedItemID: $draggedItemID,
                            draggedSpaceID: $draggedSpaceID
                        )
                    }
                }
            }
            .frame(maxWidth: 140)
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $showingSpaceList, arrowEdge: .top) {
                SpaceListView(model: model, isPresented: $showingSpaceList)
            }

            Spacer(minLength: 6)

            if SyncStatusPresentation(model.syncStatus).indicator == .red {
                Circle()
                    .fill(model.syncStatusColor)
                    .frame(width: 6, height: 6)
                    .help(model.syncStatusHelp)
                    .padding(.trailing, 8)
            }

            if model.downloads.activeCount > 0 || model.downloads.hasDangerous || model.downloads.isTrayPresented {
                DownloadsButton(downloads: model.downloads, isPresented: Binding(
                    get: { model.downloads.isTrayPresented && model.isKeyBrowserWindow(window) },
                    set: { model.downloads.isTrayPresented = $0 }
                ))
                .padding(.trailing, 8)
            }

            // Arc's + menu (`ARC_SidebarPlusButton` icons: add-tab, folder,
            // space, note, easel, boost, split-add-right, split-add-bottom).
            Menu {
                Button { model.newTab() } label: { Label("New Tab", systemImage: "plus.square") }
                Button { model.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { model.beginSpaceCreation(profileID: current.profileID) } label: {
                    Label("New Space…", systemImage: "plus.rectangle.portrait")
                }
                Divider()
                Button { _ = model.createEasel(title: "Note", note: true) } label: { Label("New Note", systemImage: "note.text") }
                Button { _ = model.createEasel() } label: { Label("New Easel", systemImage: "scribble.variable") }
                Button { model.newBoost() } label: { Label("New Boost", systemImage: "paintbrush.pointed") }
                Divider()
                Button { model.addSplitView(orientation: .horizontal) } label: {
                    Label("Add Split View (Right)", systemImage: "rectangle.split.2x1")
                }
                Button { model.addSplitView(orientation: .vertical) } label: {
                    Label("Add Split View (Bottom)", systemImage: "rectangle.split.1x2")
                }
                Divider()
                Button("Spaces in \(profile.name)…") { showingSpaceList = true }
                Button("Profiles…") { showingProfileList = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(chrome.glyph)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Tab, Folder, Space, Note, Easel, Boost or Split View")
        }
        .padding(.horizontal, 17)
        .frame(height: Self.height)
        .alert("Rename Profile", isPresented: Binding(
            get: { renamingProfileID != nil },
            set: { if !$0 { renamingProfileID = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingProfileID = nil }
            Button("Save") { commitRename() }
        }
        .alert("Profile", isPresented: Binding(
            get: { profileActionError != nil },
            set: { if !$0 { profileActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(profileActionError ?? "")
        }
    }

    private func beginRename(_ profile: Profile) {
        renamingProfileID = profile.id
        renameDraft = profile.name
        showingProfileList = false
    }

    private func commitRename() {
        guard let id = renamingProfileID else { return }
        if let error = model.store.renameProfile(id, to: renameDraft) {
            profileActionError = profileErrorMessage(error)
        }
        renamingProfileID = nil
    }

    /// A profile with spaces asks first, then goes with its spaces (Arc DeleteProfileDialog).
    private func attemptDelete(_ profile: Profile) {
        showingProfileList = false
        if !model.store.spaces(in: profile.id).isEmpty, model.store.profiles.count > 1 {
            model.pendingDeletion = .profile(profile.id)
            return
        }
        if let error = model.deleteProfile(profile.id) {
            profileActionError = profileErrorMessage(error)
        }
    }

    private func profileErrorMessage(_ error: ProfileMutationError) -> String {
        switch error {
        case .profileNotFound:
            return "Profile not found."
        case .cannotDeleteLastProfile:
            return "You can't delete the last profile."
        case .profileOwnsSpaces(let count):
            return "This profile still has \(count) space(s). Remove or move them before deleting."
        case .duplicateName:
            return "Enter a profile name."
        }
    }
}

/// One space in the bottom bar. A sidebar item dropped on it moves to that
/// space (keeping its section); held over it for a moment, the drag switches
/// to the space so it can be placed precisely. A space dropped on it takes
/// its position.
private struct SpaceIconButton: View {
    let model: BrowserViewModel
    let space: Space
    let index: Int
    let isCurrent: Bool
    @Binding var draggedItemID: UUID?
    @Binding var draggedSpaceID: Space.ID?
    @State private var isTargeted = false

    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button { model.selectSpace(space.id) } label: {
            Group {
                if isCurrent {
                    // The current space shows its icon in place of its dot.
                    SpaceIconView(iconName: space.iconName, size: 11)
                        .foregroundStyle(chrome.accent)
                        .frame(width: 22, height: 24)
                } else {
                    Circle()
                        .fill(chrome.tertiaryText)
                        .frame(width: 4, height: 4)
                        .frame(width: 9, height: 24)
                }
            }
            .background(isTargeted ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(space.name) (⌃\(index + 1)) — drop a tab here to move it to this space")
        .contextMenu { SpaceContextMenu(model: model, space: space) }
        .onDrag {
            draggedSpaceID = space.id
            return SidebarDragPayload.itemProvider(for: space.id)
        }
        .onDrop(of: [.plainText], delegate: SpaceIconDropDelegate(icon: self, isTargeted: $isTargeted))
    }
}

private struct SpaceIconDropDelegate: DropDelegate {
    let icon: SpaceIconButton
    @Binding var isTargeted: Bool
    /// Spring-loading: a held drag switches to the space after this delay.
    static let springDelay: TimeInterval = 0.7

    func validateDrop(info: DropInfo) -> Bool {
        icon.draggedItemID != nil || icon.draggedSpaceID != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        guard let dragged = icon.draggedItemID else { return }
        let spaceID = icon.space.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay) { [model = icon.model] in
            // Still hovering the same drag over this icon: open the space.
            guard isTargeted, icon.draggedItemID == dragged, model.store.activeSpaceID != spaceID else { return }
            model.selectSpace(spaceID)
        }
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        defer {
            icon.draggedItemID = nil
            icon.draggedSpaceID = nil
        }
        if let space = icon.draggedSpaceID {
            guard space != icon.space.id else { return false }
            withAnimation(.easeInOut(duration: 0.15)) { icon.model.moveSpace(space, toIndex: icon.index) }
            return true
        }
        guard let item = icon.draggedItemID else { return false }
        withAnimation(.easeInOut(duration: 0.15)) { icon.model.moveEntry(item, toSpace: icon.space.id) }
        return true
    }
}

private struct SpaceListView: View {
    let model: BrowserViewModel
    @Binding var isPresented: Bool
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let current = model.space(in: window)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.store.spaces(in: current.profileID)) { space in
                Button {
                    model.selectSpace(space.id)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        SpaceIconView(iconName: space.iconName)
                            .frame(width: 18)
                        Text(space.name)
                            .lineLimit(1)
                        Spacer()
                        if space.id == current.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { SpaceContextMenu(model: model, space: space) }
            }
            Divider().padding(.vertical, 4)
            Button {
                isPresented = false
                model.beginSpaceCreation(profileID: current.profileID)
            } label: {
                Label("New Space…", systemImage: "plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 200)
    }
}

private struct ProfileListView: View {
    let model: BrowserViewModel
    @Binding var isPresented: Bool
    var onRename: (Profile) -> Void
    var onDelete: (Profile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.store.profiles) { profile in
                HStack(spacing: 0) {
                    Button {
                        model.selectProfile(profile.id)
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            ProfileAvatarView(profile: profile, diameter: 22)
                            Text(profile.name)
                                .lineLimit(1)
                            Spacer()
                            if profile.id == model.store.activeProfileID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("Rename…") { onRename(profile) }
                        Menu("Archive Today Tabs After") {
                            ForEach(AutoArchiveThreshold.allCases, id: \.self) { threshold in
                                Toggle(threshold.title, isOn: Binding(
                                    get: { model.store.autoArchiveThreshold(for: profile.id) == threshold },
                                    set: { if $0 { model.store.setAutoArchiveThreshold(threshold, for: profile.id) } }
                                ))
                            }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { onDelete(profile) }
                            .disabled(model.store.profiles.count < 2)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.trailing, 4)
                }
            }

            Divider().padding(.vertical, 4)

            Button {
                model.addProfile()
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Profile")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220)
    }
}
