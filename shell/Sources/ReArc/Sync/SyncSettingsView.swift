import SwiftUI
import SidebarModel

/// Settings > iCloud Sync: the on/off toggle, account and status, "Sync Now".
/// A build without the iCloud entitlement only says so (docs/ICLOUD-SETUP.md).
struct SyncSettingsView: View {
    let model: BrowserViewModel

    var body: some View {
        Form {
            if let reason = model.syncUnavailableReason {
                unavailable(reason)
            } else {
                available
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func unavailable(_ reason: String) -> some View {
        Section {
            Label(CloudKitSyncAvailability.unavailableMessage, systemImage: "icloud.slash")
                .font(.headline)
            if reason != CloudKitSyncAvailability.unavailableMessage {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            Text("Sidebar changes stay on this Mac. Signing ReArc with an iCloud container is described in docs/ICLOUD-SETUP.md.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var available: some View {
        let enabled = model.isSyncEnabled
        let details = model.syncDetails ?? SyncStatusDetails(phase: .off)
        let text = SyncSettingsPresentation(details: details, enabled: enabled)
        Section {
            Toggle("Sync sidebar with iCloud", isOn: Binding(
                get: { model.isSyncEnabled },
                set: { model.setSyncEnabled($0) }
            ))
            Text("Spaces and their themes, Favorites, pinned tabs, folders, splits and Boosts. Today tabs and easels stay on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section("Status") {
            LabeledContent("Status", value: text.statusText)
            LabeledContent("iCloud account", value: text.accountText)
            LabeledContent("Last synced", value: text.lastSyncedText)
            if let pending = text.pendingText {
                LabeledContent("Queued", value: pending)
            }
            if let error = text.errorText {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Sync Now") { model.syncNow() }
                    .disabled(!text.canSyncNow)
            }
        }
    }
}
