import AppKit
import SidebarModel
import SwiftUI

/// Settings › Account, named after the profile (SETTINGS.md §2, §11.2):
/// Arc's two columns. The membership card with Share, Download and
/// Randomize on the left; on the right the Account row (ReArc is
/// local-first, so the name and a ⋯ menu of what ReArc can do), Sync
/// Sidebar, and Share ReArc with a Friend.
struct AccountSettingsPane: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var showsSyncDetails = false
    @State private var canImportArc = false
    @State private var cardShareAnchor: NSView?
    @State private var shareReArcAnchor: NSView?
    /// A destructive iCloud action waiting for its confirmation.
    @State private var confirming: CloudAction?

    private static let columnWidth: CGFloat = 339

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                cardColumn.frame(width: MembershipCardView.size.width)
                Spacer(minLength: 0)
                VStack(spacing: 17) {
                    accountBox
                    syncBox
                    if model.syncControl != nil { cloudBox }
                    shareBox
                }
                .frame(width: Self.columnWidth)
            }
            .padding(.leading, 35)
            .padding(.trailing, 35.5)
            .padding(.top, 50)
            .padding(.bottom, 24)
        }
        .onAppear {
            // In the background, once a session: the pane and the switch stay usable meanwhile.
            if model.syncControl != nil, model.cloudDetection == nil, !model.isCheckingCloud { model.checkCloudSidebar() }
            model.membershipCard.ensureLoaded()
            canImportArc = model.canImportArcMembershipCard()
            model.membershipCard.accountTabAppeared(reduceMotion: reduceMotion)
        }
        .onChange(of: model.membershipCard.card) {
            canImportArc = model.canImportArcMembershipCard()
        }
        .alert("Change Name", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.changeAccountName(nameDraft) }
        } message: {
            Text("The name on your card and your profile.")
        }
        .cloudSidebarChoiceSheet(model)
        .alert(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { action in
            Button(action.button, role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { action in
            Text(action.message(found: model.cloudDetection?.found, backupFolder: model.sidebarBackupFolderName))
        }
    }

    private func perform(_ action: CloudAction) {
        switch action {
        case .use: model.chooseCloudSidebarAfterLooking(.useCloud)
        case .replace: model.chooseCloudSidebarAfterLooking(.replaceCloud)
        case .delete: model.deleteCloudSidebar()
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardColumn: some View {
        if let card = model.membershipCard.card {
            let name = card.displayName(profileName: model.accountName)
            VStack(spacing: 24) {
                MembershipCardView(card: card, name: name, theme: model.membershipCardTheme,
                                   transitionStart: model.membershipCard.transitionStart)
                    .contextMenu { cardMenu(card) }
                HStack(spacing: 8) {
                    cardButton("Share", symbol: "square.and.arrow.up") {
                        if let cardShareAnchor { MembershipCardExport.share(card: card, name: name, theme: model.membershipCardTheme, from: cardShareAnchor) }
                    }
                    .background(AnchorReader { cardShareAnchor = $0 })
                    cardButton("Download", symbol: "square.and.arrow.down") {
                        MembershipCardExport.download(card: card, name: name, theme: model.membershipCardTheme, from: cardShareAnchor?.window)
                    }
                    cardButton("Randomize", symbol: "dice") { model.randomizeMembershipCard() }
                        .help("Randomize the card's title and colours")
                }
                if canImportArc {
                    Button("Import Your Card from Arc") { importFromArc() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder
    private func cardMenu(_ card: MembershipCard) -> some View {
        if card.hasArcHistory {
            Button("Replay Arc to ReArc") { model.membershipCard.playTransition(reduceMotion: reduceMotion) }
        }
        Button("Randomize") { model.randomizeMembershipCard() }
        if canImportArc {
            Button("Import Your Card from Arc") { importFromArc() }
        }
    }

    private func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    private func importFromArc() {
        guard model.importArcMembershipCardFromArc() else { return NSSound.beep() }
        canImportArc = model.canImportArcMembershipCard()
        model.membershipCard.playTransition(reduceMotion: reduceMotion)
    }

    // MARK: Boxes

    private var accountBox: some View {
        AccountBox {
            HStack(spacing: 10) {
                Text("Account").font(.system(size: 13))
                Spacer(minLength: 8)
                Text(model.accountName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Menu {
                    Button("Change Name…") {
                        nameDraft = model.accountName
                        renaming = true
                    }
                    if model.membershipCard.card?.hasArcHistory == true {
                        Divider()
                        Button("Replay Arc to ReArc") { model.membershipCard.playTransition(reduceMotion: reduceMotion) }
                    }
                    if canImportArc {
                        Divider()
                        Button("Import Your Card from Arc") { importFromArc() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 24)
                        .background(SettingsColors.button, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Account actions")
            }
            .frame(minHeight: 23)
        }
    }

    @ViewBuilder
    private var syncBox: some View {
        if let reason = model.syncUnavailableReason {
            AccountBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sync Sidebar").font(.system(size: 13))
                        Spacer()
                        Toggle("Sync Sidebar", isOn: .constant(false))
                            .toggleStyle(.switch).controlSize(.large).labelsHidden().disabled(true)
                    }
                    Label(CloudKitSyncAvailability.unavailableMessage, systemImage: "icloud.slash")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if reason != CloudKitSyncAvailability.unavailableMessage {
                        Text(reason).font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary)
                    }
                    SettingsHairline()
                    Text("Sidebar changes stay on this Mac. Signing ReArc with an iCloud container is described in docs/ICLOUD-SETUP.md.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            let details = model.syncDetails ?? SyncStatusDetails(phase: .off)
            let text = SyncSettingsPresentation(details: details, enabled: model.isSyncEnabled)
            AccountBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sync Sidebar").font(.system(size: 13))
                        Spacer()
                        // On while it waits for the look: switching it off then stops the wait.
                        Toggle("Sync Sidebar", isOn: Binding(get: { model.syncSwitchIsOn }, set: { model.setSyncEnabled($0) }))
                            .toggleStyle(.switch).controlSize(.large).labelsHidden()
                    }
                    HStack(spacing: 8) {
                        Circle().fill(text.errorText == nil && model.isSyncEnabled ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text("Last synced: \(text.lastSyncedText)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    // The switch waits for the look: the same words as the iCloud box below.
                    if model.syncSwitchWaiting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(model.cloudStatusText).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    if let message = model.syncCloudMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let error = text.errorText {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    SettingsHairline()
                    Text("Off unless you turn it on. ReArc syncs Spaces and their themes, Favorites, pinned tabs, folders, splits and Boosts through your iCloud account; only you can see them. Today tabs and easels stay on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Details", isExpanded: $showsSyncDetails) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow { Text("Status"); Text(text.statusText).foregroundStyle(.secondary) }
                            GridRow { Text("iCloud account"); Text(text.accountText).foregroundStyle(.secondary) }
                            if let pending = text.pendingText {
                                GridRow { Text("Queued"); Text(pending).foregroundStyle(.secondary) }
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.top, 4)
                        if let technicalError = text.technicalError {
                            Text(technicalError)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                        Button("Sync Now") { model.syncNow() }
                            .disabled(!text.canSyncNow)
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    /// What iCloud holds, and what can be done with it, sync on or off.
    private var cloudBox: some View {
        let found = model.cloudDetection?.found
        return AccountBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sidebar in iCloud").font(.system(size: 13))
                    Spacer()
                    Button { model.checkCloudSidebar() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isCheckingCloud && !model.cloudLook.isStalled)
                    .help("Look at iCloud again")
                    .accessibilityLabel("Look at iCloud again")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.isCheckingCloud && !model.cloudLook.isStalled { ProgressView().controlSize(.mini) }
                    Text(model.cloudStatusText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsHairline()
                VStack(alignment: .leading, spacing: 6) {
                    Button("Use on This Mac…") { confirming = .use }
                    Button("Replace iCloud with This Mac…") { confirming = .replace }
                    Button("Delete iCloud Content…", role: .destructive) { confirming = .delete }
                }
                .controlSize(.small)
                .disabled(found == nil || model.isCheckingCloud)
            }
        }
    }

    private var shareBox: some View {
        AccountBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Share ReArc with a Friend").font(.system(size: 13))
                    Spacer()
                    Button {
                        if let shareReArcAnchor { ShareReArc.show(from: shareReArcAnchor) }
                    } label: {
                        Label("Share ReArc", systemImage: "gift")
                    }
                    .background(AnchorReader { shareReArcAnchor = $0 })
                }
                SettingsHairline()
                Text("Send a friend a link to ReArc. Personal invite links are coming later.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The account tab's boxes: Arc's fill and border, 16 pt in.
private struct AccountBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).strokeBorder(SettingsColors.border))
    }
}

/// The iCloud box's destructive actions, each confirmed with what it affects.
enum CloudAction: Identifiable {
    case use, replace, delete

    var id: Self { self }

    var title: String {
        switch self {
        case .use: return "Use the iCloud sidebar on this Mac?"
        case .replace: return "Replace iCloud's sidebar with this Mac's?"
        case .delete: return "Delete ReArc's sidebar from iCloud?"
        }
    }

    var button: String {
        switch self {
        case .use: return "Use iCloud's Sidebar"
        case .replace: return "Replace iCloud's Sidebar"
        case .delete: return "Delete from iCloud"
        }
    }

    func message(found: CloudSidebarFound?, backupFolder: String) -> String {
        let holds = found.map { SyncCloudText.holds($0.summary) + " " } ?? ""
        switch self {
        case .use:
            return holds + SyncCloudText.consequence(.useCloud, backupFolder: backupFolder) + " Sync Sidebar is on afterwards."
        case .replace:
            return holds + SyncCloudText.consequence(.replaceCloud, backupFolder: backupFolder) + " Sync Sidebar is on afterwards."
        case .delete:
            return holds + "It is deleted from iCloud. This Mac's sidebar stays as it is, and Sync Sidebar turns off here. "
                + "Another Mac that still syncs uploads its own sidebar again."
        }
    }
}

extension View {
    /// The sheet switching Sync Sidebar on shows when iCloud holds a
    /// sidebar, wherever the switch is (Account, Profiles).
    func cloudSidebarChoiceSheet(_ model: BrowserViewModel) -> some View {
        sheet(isPresented: Binding(get: { model.syncCloudChoice != nil }, set: { if !$0 { model.syncCloudChoice = nil } })) {
            if let found = model.syncCloudChoice {
                CloudSidebarChoiceSheet(found: found, backupFolder: model.sidebarBackupFolderName,
                                        choose: { model.chooseCloudSidebar($0, from: found) },
                                        cancel: { model.syncCloudChoice = nil })
            }
        }
    }
}

/// Switching Sync Sidebar on found a sidebar in iCloud: say so, and what
/// each way forward does, before anything moves. Cancel is the default.
struct CloudSidebarChoiceSheet: View {
    let found: CloudSidebarFound
    let backupFolder: String
    let choose: (CloudSidebarChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "icloud").font(.system(size: 26)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(SyncCloudText.sheetTitle).font(.headline)
                    Text(SyncCloudText.holds(found.summary)).font(.callout)
                    Text(SyncCloudText.sheetWarning).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(CloudSidebarChoice.allCases, id: \.self) { choice in
                    row(SyncCloudText.title(choice), SyncCloudText.consequence(choice, backupFolder: backupFolder)) { choose(choice) }
                }
                row(SyncCloudText.cancel, SyncCloudText.cancelConsequence, isDefault: true, action: cancel)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand(perform: cancel)
    }

    private func row(_ title: String, _ consequence: String, isDefault: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if isDefault {
                Button(title, action: action).keyboardShortcut(.defaultAction)
            } else {
                Button(title, action: action)
            }
            Text(consequence).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
