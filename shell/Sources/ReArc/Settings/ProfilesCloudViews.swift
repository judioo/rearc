import SidebarModel
import SwiftUI

// Settings › Profiles and iCloud (docs/SYNC-RUNTIME.md, "Profiles in
// iCloud"): a mark on each of this Mac's profiles, a row saying where it
// is, the profiles only iCloud has, and deleting one from iCloud.

/// The row's small mark: a cloud for a profile iCloud has too, a Mac for one
/// only here, nothing while iCloud is being read or can't be.
struct CloudPresenceMark: View {
    let presence: ProfileCloudPresence

    var body: some View {
        switch presence {
        case .inICloud: mark("icloud", ProfileCloudText.inICloud)
        case .onlyHere: mark("laptopcomputer", ProfileCloudText.onlyHere)
        case .looking, .unknown: EmptyView()
        }
    }

    private func mark(_ symbol: String, _ text: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10))
            .foregroundStyle(SettingsColors.tertiary)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// The detail pane's first box for a profile of this Mac: where it is,
/// Put in iCloud… when only this Mac has it, and Sync Sidebar itself, the
/// same switch as the account tab's, which holds the rest.
struct ProfileCloudStatusGroup: View {
    @Bindable var model: BrowserViewModel
    let profileID: Profile.ID

    var body: some View {
        SettingsGroup {
            if model.syncControl == nil {
                SettingsLabeledRow(label: "iCloud", detail: "Sidebar changes stay on this Mac.") {
                    Text(CloudKitSyncAvailability.unavailableMessage)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                presenceRow
                SettingsLabeledRow(label: "Sync Sidebar", detail: ProfileCloudText.syncSwitchNote(on: model.isSyncEnabled)) {
                    Toggle("Sync Sidebar", isOn: Binding(get: { model.syncSwitchIsOn }, set: { model.setSyncEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                if let message = model.syncCloudMessage {
                    Text(message)
                        .font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsMetrics.rowInset)
                        .padding(.bottom, 6)
                }
                SettingsLabeledRow(label: ProfileCloudText.accountTabNote(SettingsPane.account.title(accountName: model.accountName))) {
                    Button("iCloud Settings…") { model.settingsPane = .account }
                }
            }
        }
    }

    private var presenceRow: some View {
        let presence = model.cloudPresence(of: profileID)
        let syncOn = model.isSyncEnabled
        // The note runs the box's full width under the row: beside the status and its button it wraps to a column.
        return VStack(alignment: .leading, spacing: 0) {
            presenceLine(presence, syncOn: syncOn)
            if let note = ProfileCloudText.note(presence, syncOn: syncOn) {
                Text(note)
                    .font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.rowInset)
                    .padding(.top, -4)
                    .padding(.bottom, 8)
            }
        }
    }

    private func presenceLine(_ presence: ProfileCloudPresence, syncOn: Bool) -> some View {
        SettingsLabeledRow(label: "iCloud") {
            HStack(spacing: 6) {
                if case .looking = presence { ProgressView().controlSize(.mini) }
                CloudPresenceMark(presence: presence)
                // While a look runs, the Account pane's words.
                Text(model.isCheckingCloud ? model.cloudStatusText : ProfileCloudText.status(presence, syncOn: syncOn))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if presence == .onlyHere {
                    // Whole, never clipped: the note on the left wraps instead.
                    Button(ProfileCloudText.putInICloud(syncOn: syncOn)) { model.putInICloud(profileID) }
                        .disabled(!model.canPutInICloud(profileID))
                        .fixedSize()
                }
            }
        }
    }
}

/// Below this Mac's profiles: those only iCloud has, how the look is going,
/// a button to look again, and how the last delete went.
struct CloudOnlyProfilesSection: View {
    @Bindable var model: BrowserViewModel
    @Binding var selection: Profile.ID?

    var body: some View {
        if model.syncControl != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(ProfileCloudText.cloudOnlySection)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsColors.tertiary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { model.checkCloudSidebar() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled((model.isCheckingCloud && !model.cloudLook.isStalled) || model.cloudProfileDeletes.working != nil)
                    .help("Look at iCloud again")
                    .accessibilityLabel("Look at iCloud again")
                }
                .padding(.horizontal, 7)
                .padding(.top, 14)
                .padding(.bottom, 4)
                status
                // An iCloud-only container sits under its iCloud-only parent when its record names one.
                ForEach(CloudContainerNesting.rows(model.cloudOnlyProfiles), id: \.profile.id) { entry in
                    row(entry.profile, nested: entry.nested)
                }
                if let notice = model.cloudProfileDeletes.notice {
                    note(notice.text, color: notice.isError ? .red : .secondary)
                }
            }
            .onAppear {
                // Once a session, in the background, as the Account pane does.
                if model.cloudDetection == nil, !model.isCheckingCloud { model.checkCloudSidebar() }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.isCheckingCloud {
            HStack(spacing: 6) {
                if !model.cloudLook.isStalled { ProgressView().controlSize(.mini) }
                note(model.cloudStatusText)
            }
        } else if model.cloudDetection?.found == nil || model.cloudOnlyProfiles.isEmpty {
            note(model.cloudDetection?.found == nil ? model.cloudStatusText : "None. iCloud has only this Mac's profiles.")
        }
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
    }

    private func row(_ cloud: CloudProfile, nested: Bool = false) -> some View {
        let isSelected = cloud.id == selection
        return Button { selection = cloud.id } label: {
            HStack(spacing: 6) {
                if nested {
                    ContainerChip(label: ContainerLabel(containerID: cloud.id, name: cloud.spaces.first?.name ?? cloud.profile.name,
                                                        theme: cloud.profile.themeColor), style: .badge)
                        .padding(.leading, 16)
                } else {
                    ProfileAvatarView(profile: cloud.profile, diameter: 16)
                }
                Text(cloud.profile.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Text(cloud.spaces.count == 1 ? "1 Space" : "\(cloud.spaces.count) Spaces")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Image(systemName: "icloud").font(.system(size: 10)).foregroundStyle(SettingsColors.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(isSelected ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cloud.profile.name), in iCloud only")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The detail pane for a profile only iCloud has: what it holds, its spaces
/// by name (so near-identical profiles can be told apart), and Delete.
struct CloudProfileDetail: View {
    @Bindable var model: BrowserViewModel
    let cloud: CloudProfile

    var body: some View {
        SettingsGroup {
            HStack(spacing: 10) {
                ProfileAvatarView(profile: cloud.profile, diameter: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cloud.profile.name).font(.system(size: 13, weight: .semibold))
                    Text(ProfileCloudText.cloudOnlyNote)
                        .font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 8)
            SettingsLabeledRow(label: ProfileCloudText.cloudOnlySection, detail: ProfileCloudText.summary(cloud)) {
                CloudPresenceMark(presence: .inICloud)
            }
        }
        if !cloud.spaces.isEmpty {
            SettingsHeader(title: "Spaces in iCloud")
            SettingsGroup {
                ForEach(cloud.spaces) { space in
                    SettingsLabeledRow(label: space.name) {
                        Text(space.pinnedTabs == 1 ? "1 pinned tab" : "\(space.pinnedTabs.formatted()) pinned tabs")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        SettingsGroup {
            SettingsLabeledRow(label: ProfileCloudText.deleteFromICloud, detail: ProfileCloudText.deleteFromICloudDetail) {
                Button(ProfileCloudText.deleteFromICloud + "…", role: .destructive) { model.requestCloudProfileDeletion(cloud.id) }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.canDeleteFromICloud)
            }
            if model.cloudProfileDeletes.working == cloud.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.isCheckingCloud ? model.cloudStatusText : "Deleting from iCloud…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.vertical, 8)
            }
        }
    }
}

extension View {
    /// The confirmations of a delete that reaches iCloud. Cancel is the
    /// default; each other button's consequence is one line of the message.
    func cloudProfileDeleteAlert(_ model: BrowserViewModel) -> some View {
        modifier(CloudProfileDeleteAlert(model: model))
    }
}

private struct CloudProfileDeleteAlert: ViewModifier {
    @Bindable var model: BrowserViewModel

    func body(content: Content) -> some View {
        let deletes = model.cloudProfileDeletes
        let request = deletes.request
        content.alert(request.map(model.cloudProfileDeleteTitle) ?? "", isPresented: Binding(get: { deletes.request != nil }, set: { if !$0 { deletes.request = nil } }),
                      presenting: request) { request in
            if request.onThisMac {
                if !model.isSyncEnabled {
                    Button(ProfileCloudText.deleteFromThisMac, role: .destructive) {
                        deletes.request = nil
                        model.deleteProfile(request.profile.id, deletingSpaces: true)
                    }
                }
                Button(ProfileCloudText.deleteFromBoth, role: .destructive) { model.deleteCloudProfile(request, alsoThisMac: true) }
            } else {
                Button(ProfileCloudText.deleteFromICloud, role: .destructive) { model.deleteCloudProfile(request, alsoThisMac: false) }
            }
            Button("Cancel", role: .cancel) { deletes.request = nil }
                .keyboardShortcut(.defaultAction)
        } message: { request in
            Text(model.cloudProfileDeleteMessage(request))
        }
    }
}
