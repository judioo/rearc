import SidebarModel
import SwiftUI

// Settings › Profiles and containers (docs/SPACE-CONTAINERS.md): a profile's
// containers listed under it, what a container keeps separate, and turning
// a profile an earlier build made into a container, or back.

/// A container under its parent in the profile list: indented, with the
/// badge, named by its space, and its own iCloud mark.
struct ContainerProfileRow: View {
    let model: BrowserViewModel
    let container: Profile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let label = model.store.containerLabel(forEngineProfile: container.id) {
                    ContainerChip(label: label, style: .badge)
                        .frame(width: 16)
                }
                Text(model.store.containerTitle(container.id)).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                CloudPresenceMark(presence: model.cloudPresence(of: container.id))
            }
            .padding(.leading, 23)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background(isSelected ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ContainerChip.help)
        .accessibilityLabel("\(model.store.containerTitle(container.id)), a container")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The detail pane for a container: what is its own, that the rest follows
/// its parent, and its actions.
struct ContainerSettingsDetail: View {
    @Bindable var model: BrowserViewModel
    let container: Profile
    @Binding var removing: Profile.ID?

    static let separate = "Cookies, sign-ins, site data, extensions, history and saved passwords"

    var body: some View {
        let parent = model.store.parentProfile(ofContainer: container.id)
        SettingsGroup {
            HStack(spacing: 10) {
                if let label = model.store.containerLabel(forEngineProfile: container.id) {
                    ContainerChip(label: label)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.store.containerTitle(container.id)).font(.system(size: 13, weight: .semibold))
                    Text("A separate browsing session for this space, inside \(parent?.name ?? "its profile").")
                        .font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 8)
            SettingsLabeledRow(label: "Its own", detail: Self.separate + ". Sign in here to a different account than the rest of the profile.") {
                EmptyView()
            }
            SettingsLabeledRow(label: "From \(parent?.name ?? "its profile")",
                               detail: "Search engine, Archive tabs after and download location: change them on \(parent?.name ?? "the profile").") {
                EmptyView()
            }
        }
        ProfileCloudStatusGroup(model: model, profileID: container.id)
        SettingsGroup {
            if model.canOpenBrowserPage(.clearBrowsingData) {
                SettingsLabeledRow(label: BrowserInternalPage.clearBrowsingData.title, detail: "Opens in the container's space, for its data only.") {
                    Button("Clear…") { model.openBrowserPage(.clearBrowsingData, inStorageOf: container.id) }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
            SettingsLabeledRow(label: "Make This a Profile", detail: "The space leaves \(parent?.name ?? "its profile") with its sign-ins, as a profile of its own.") {
                Button("Make Profile") { model.makeProfile(container.id) }
                    .buttonStyle(SettingsButtonStyle())
            }
            SettingsLabeledRow(label: "Remove Container", detail: "The space goes back to \(parent?.name ?? "its profile")'s own session. The container's data is deleted.") {
                Button("Remove…", role: .destructive) { removing = container.id }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }
}

/// On a profile's detail: Make This a Container of ▸, for a profile with one
/// space, which an earlier build's New Container for This Space would have made.
/// Nothing changes until a parent is chosen.
struct ProfileContainerConversionGroup: View {
    @Bindable var model: BrowserViewModel
    let profile: Profile

    static let earlierNote = "This looks like a container an earlier ReArc made: one space, named as the profile. Make it a container to show the space with its profile's spaces; its sign-ins stay."

    var body: some View {
        let parents = model.store.containerParentChoices(for: profile.id)
        if !parents.isEmpty {
            SettingsGroup {
                SettingsLabeledRow(label: "Make This a Container of",
                                   detail: model.store.looksLikeEarlierContainer(profile.id) ? Self.earlierNote
                                       : "Its one space joins that profile's spaces and keeps its own sign-ins.") {
                    Menu("Choose") {
                        ForEach(parents) { parent in
                            Button(parent.name) { model.makeContainer(profile.id, of: parent.id) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

extension View {
    /// Remove Container…'s confirmation in Settings, Cancel the default.
    func containerRemovalAlert(_ model: BrowserViewModel, removing: Binding<Profile.ID?>) -> some View {
        let text: (title: String, message: String, action: String) = removing.wrappedValue.map(model.containerRemovalMessage) ?? ("", "", "")
        return alert(text.title, isPresented: Binding(get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } })) {
            Button(text.action, role: .destructive) {
                if let id = removing.wrappedValue { model.removeContainer(id) }
                removing.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { removing.wrappedValue = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(text.message)
        }
    }
}
