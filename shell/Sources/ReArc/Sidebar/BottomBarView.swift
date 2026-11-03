import SwiftUI
import SidebarModel

/// The sidebar's bottom bar: space switcher (click cycles, chevron opens a
/// popover listing spaces in the active profile), new-space button, and profile avatar.
struct BottomBarView: View {
    let model: BrowserViewModel
    @State private var showingSpaceList = false
    @State private var showingProfileList = false
    @State private var renamingProfileID: Profile.ID?
    @State private var renameDraft = ""
    @State private var profileActionError: String?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.cycleSpace) {
                Image(systemName: model.store.activeSpace.iconName)
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .background(model.themeColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("\(model.store.activeSpace.name) — click to switch space")

            Button(action: { showingSpaceList.toggle() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Spaces in \(model.store.activeProfile.name)")
            .popover(isPresented: $showingSpaceList, arrowEdge: .top) {
                SpaceListView(model: model, isPresented: $showingSpaceList)
            }

            Spacer()

            Circle()
                .fill(model.syncStatusColor)
                .frame(width: 8, height: 8)
                .help(model.syncStatusHelp)

            Menu {
                Button("New Space") { model.addSpace() }
                Divider()
                Button("New Easel") { _ = model.createEasel() }
                Button("New Note") { _ = model.createEasel(title: "Note", note: true) }
                Divider()
                Button("Add Split View (Right)") {
                    model.addSplitView(orientation: .horizontal)
                }
                Button("Add Split View (Bottom)") {
                    model.addSplitView(orientation: .vertical)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("New Space / Split View")

            Button(action: { showingProfileList.toggle() }) {
                ProfileAvatarView(profile: model.store.activeProfile, diameter: 24)
            }
            .buttonStyle(.plain)
            .help(model.store.activeProfile.name)
            .popover(isPresented: $showingProfileList, arrowEdge: .top) {
                ProfileListView(
                    model: model,
                    isPresented: $showingProfileList,
                    onRename: beginRename,
                    onDelete: attemptDelete
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private func attemptDelete(_ profile: Profile) {
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

private struct SpaceListView: View {
    let model: BrowserViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.store.spacesInActiveProfile) { space in
                Button {
                    model.selectSpace(space.id)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: space.iconName)
                            .frame(width: 18)
                        Text(space.name)
                            .lineLimit(1)
                        Spacer()
                        if space.id == model.store.activeSpaceID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
                        Button("Delete", role: .destructive) { onDelete(profile) }
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
