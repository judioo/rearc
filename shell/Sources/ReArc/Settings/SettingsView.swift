import AppKit
import SidebarModel
import SwiftUI

/// What the engine offers the Settings window beyond the model.
struct SettingsCapabilities {
    var pictureInPicture = true
    /// Chrome's "Warn you if passwords are exposed in a data breach" (Chromium only).
    var passwordLeakCheck: Binding<Bool>?
}

/// Wave 35: Arc's Settings window (ARC-RECORDING-2026-11-06 §6). One pane at a
/// time, about 400 pt wide; the Chromium shell hosts it under an NSToolbar
/// (`SettingsWindowController`), the WebKit app in its `Settings` scene.
struct SettingsPaneView: View {
    @Bindable var model: BrowserViewModel
    let pane: SettingsPane
    var capabilities = SettingsCapabilities()

    static let width: CGFloat = 420

    var body: some View {
        Group {
            switch pane {
            case .account: AccountSettingsPane(model: model)
            case .general: GeneralSettingsPane(model: model)
            case .profiles: ProfilesSettingsPane(model: model)
            case .links: LinksSettingsPane(model: model)
            case .shortcuts: ShortcutsSettingsPane(model: model)
            case .icon: IconSettingsPane(model: model)
            case .advanced: AdvancedSettingsPane(model: model, capabilities: capabilities)
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The WebKit app's Settings scene: SwiftUI's tab view gives the same
/// icon-over-label toolbar and pane-named title.
struct SettingsTabsView: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        TabView(selection: $model.settingsPane) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                SettingsPaneView(model: model, pane: pane)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
    }
}

// MARK: Building blocks

/// A pane of Arc's grouped boxes: label on the left, control on the right.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One grouped box.
struct SettingsBox<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        if let title {
            Section(title) { content }
        } else {
            Section { content }
        }
    }
}

/// Label on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            Text(label)
            if let detail { Text(detail) }
        }
    }
}

struct SettingsToggleRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
            if let detail { Text(detail) }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Arc's coloured icon rows that open Chromium's own page.
struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(color))
                Text(title)
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension AutoArchiveThreshold {
    static var picker: some View {
        ForEach(AutoArchiveThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
    }
}

// MARK: Account

/// Sync Sidebar and its last-synced line. ReArc has no accounts, so no
/// membership card (§6.3). A build without the iCloud entitlement says so.
struct AccountSettingsPane: View {
    let model: BrowserViewModel

    var body: some View {
        SettingsForm {
            if let reason = model.syncUnavailableReason {
                SettingsBox(title: "Sync Sidebar") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(CloudKitSyncAvailability.unavailableMessage, systemImage: "icloud.slash")
                        if reason != CloudKitSyncAvailability.unavailableMessage {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Sidebar changes stay on this Mac. Signing ReArc with an iCloud container is described in docs/ICLOUD-SETUP.md.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                available
            }
        }
    }

    private var available: some View {
        let details = model.syncDetails ?? SyncStatusDetails(phase: .off)
        let text = SyncSettingsPresentation(details: details, enabled: model.isSyncEnabled)
        return SettingsBox(title: "Sync Sidebar") {
            SettingsToggleRow(
                label: "Sync Sidebar",
                detail: "Spaces and their themes, Favorites, pinned tabs, folders, splits and Boosts, through iCloud. Today tabs and easels stay on this Mac.",
                isOn: Binding(get: { model.isSyncEnabled }, set: { model.setSyncEnabled($0) })
            )
            HStack(spacing: 6) {
                Circle().fill(text.errorText == nil && model.isSyncEnabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text("Last synced: \(text.lastSyncedText)").font(.callout)
                Spacer()
                Button("Sync Now") { model.syncNow() }.disabled(!text.canSyncNow).controlSize(.small)
            }
            SettingsRow(label: "Status") { Text(text.statusText).foregroundStyle(.secondary) }
            SettingsRow(label: "iCloud account") { Text(text.accountText).foregroundStyle(.secondary) }
            if let pending = text.pendingText {
                SettingsRow(label: "Queued") { Text(pending).foregroundStyle(.secondary) }
            }
            if let error = text.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: General

struct GeneralSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsForm {
            SettingsBox {
                SettingsToggleRow(label: "Warn before quitting", detail: "⌘Q asks first while windows are open.",
                                  isOn: $model.warnBeforeQuitting)
                SettingsRow(label: "Default browser") {
                    Button("Set ReArc as Default…") { model.setAsDefaultBrowser() }
                }
            }
            SettingsBox {
                SettingsRow(label: "Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { model.settingsPane = .profiles }
                }
            }
        }
    }
}

// MARK: Profiles

struct ProfilesSettingsPane: View {
    @Bindable var model: BrowserViewModel
    @State private var selection: Profile.ID?
    @State private var renaming: Profile.ID?
    @State private var renameDraft = ""
    @State private var deleting: Profile.ID?

    private var selected: Profile? {
        model.store.profile(withID: selection ?? model.store.activeProfileID) ?? model.store.profiles.first
    }

    var body: some View {
        SettingsForm {
            SettingsBox {
                Text("Profiles keep their own history, cookies, logins and extensions. Each has its own Spaces.")
                    .font(.callout).foregroundStyle(.secondary)
                profileList
            }
            if let profile = selected {
                profileSettings(profile)
            }
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let id = renaming { _ = model.store.renameProfile(id, to: renameDraft) }
                renaming = nil
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting {
                    model.deleteProfile(id, deletingSpaces: true)
                    if selection == id { selection = nil }
                }
                deleting = nil
            }
        } message: {
            Text("Its spaces and their tabs are deleted too. This can't be undone.")
        }
    }

    private var deleteTitle: String {
        let name = deleting.flatMap { model.store.profile(withID: $0)?.name } ?? "Profile"
        return "Delete “\(name)”?"
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                ForEach(model.store.profiles) { profile in
                    HStack(spacing: 8) {
                        ProfileAvatarView(profile: profile, diameter: 20)
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        Text(model.spaceCountText(for: profile.id)).foregroundStyle(.secondary).font(.callout)
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: min(CGFloat(model.store.profiles.count) * 28 + 8, 150))
            HStack(spacing: 0) {
                Button { selection = model.addProfileFromSettings().id } label: { Image(systemName: "plus") }
                    .help("Add Profile")
                Divider().frame(height: 14)
                Button { deleting = selected?.id } label: { Image(systemName: "minus") }
                    .disabled(model.store.profiles.count < 2)
                    .help("Delete Profile")
                Divider().frame(height: 14)
                Button {
                    renameDraft = selected?.name ?? ""
                    renaming = selected?.id
                } label: { Image(systemName: "pencil") }
                    .help("Rename Profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func profileSettings(_ profile: Profile) -> some View {
        if let search = model.activeSearchEngineSettings {
            SettingsBox(title: profile.name) {
                SettingsRow(label: "Search engine") {
                    Picker("Search engine", selection: Binding(
                        get: { search.defaultEngine(for: profile.id) ?? "" },
                        set: { search.setDefaultEngine($0, for: profile.id) }
                    )) {
                        ForEach(search.engines) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                if model.canOpenBrowserPage(.searchSettings) {
                    SettingsRow(label: "Manage search") { Button("Search Settings…") { open(.searchSettings, in: profile) } }
                }
            }
        } else if model.canOpenBrowserPage(.searchSettings) {
            SettingsBox(title: profile.name) {
                SettingsRow(label: "Search engine") { Button("Search Settings…") { open(.searchSettings, in: profile) } }
            }
        }
        SettingsBox {
            SettingsRow(label: "Archive tabs after", detail: "Today tabs you haven't opened in this long move to the Archive.") {
                Picker("Archive tabs after", selection: Binding(
                    get: { model.store.autoArchiveThreshold(for: profile.id) },
                    set: { model.store.setAutoArchiveThreshold($0, for: profile.id) }
                )) { AutoArchiveThreshold.picker }
                    .labelsHidden().fixedSize()
            }
            if model.canOpenBrowserPage(.downloadSettings) {
                SettingsRow(label: "Download location") { Button("Download Settings…") { open(.downloadSettings, in: profile) } }
            }
        }
        let dataRows: [(BrowserInternalPage, String, Color)] = [
            (.privacy, "hand.raised.fill", .blue),
            (.passwords, "key.fill", .gray),
            (.payments, "creditcard.fill", .green),
            (.notifications, "bell.fill", .red),
            (.clearBrowsingData, "trash.fill", .orange),
        ].filter { model.canOpenBrowserPage($0.0) }
        if !dataRows.isEmpty {
            SettingsBox(title: "Your Data and Settings") {
                ForEach(dataRows, id: \.0) { page, symbol, color in
                    SettingsLinkRow(title: page.title, systemImage: symbol, color: color) { open(page, in: profile) }
                }
            }
        }
    }

    /// Chromium's page opens as a tab of that profile (its own storage and settings).
    private func open(_ page: BrowserInternalPage, in profile: Profile) {
        if model.store.activeProfileID != profile.id { model.selectProfile(profile.id) }
        model.openBrowserPage(page)
    }
}

// MARK: Links

struct LinksSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsForm {
            SettingsBox(title: "Little Arc") {
                SettingsToggleRow(label: "Open Little Arc when I press \(LittleArcHotkeyPreference.display) in any app",
                                  isOn: $model.isLittleArcHotkeyEnabled)
                SettingsToggleRow(label: "… when clicking on links with ⌥⌘ held", isOn: $model.littleArcOnModifiedClick)
                SettingsRow(label: "Links from other apps open in") {
                    Picker("Links from other apps open in", selection: $model.externalLinkDestination) {
                        ForEach(ExternalLinkDestination.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(label: "Archive Little Arcs after") {
                    Picker("Archive Little Arcs after", selection: $model.littleArcArchiveAfter) { AutoArchiveThreshold.picker }
                        .labelsHidden().fixedSize()
                }
            }
            SettingsBox(title: "Peek") {
                SettingsToggleRow(label: "Open a Peek window when clicking on links with Shift held", isOn: $model.peekOnShiftClick)
                SettingsToggleRow(label: "… when clicking on links to other sites",
                                  detail: "Note: This only affects Favorites and Pinned tabs.",
                                  isOn: $model.automaticPeekEnabled)
            }
            SettingsBox {
                SettingsRow(label: "Choose where links open inside ReArc") {
                    Button("Air Traffic Control…") { model.showAirTrafficControl() }
                }
            }
        }
    }
}

// MARK: Shortcuts

/// Records a chord for one row: the next key press with ⌘, ⌃ or ⌥ (or a
/// function key). Esc cancels; Delete unbinds.
@Observable
final class ShortcutRecorder {
    private(set) var recordingID: String?
    /// The last press refused (a bare letter), for the hint line.
    private(set) var refused = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored var onRecord: ((String, ShortcutOverride) -> Void)?

    func start(_ id: String) {
        stop()
        recordingID = id
        refused = false
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let id = self.recordingID else { return event }
            // Typing in another window ends the recording; that key goes where it was going.
            guard event.window === window else {
                self.stop()
                return event
            }
            self.handle(event, for: id)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }

    private func handle(_ event: NSEvent, for id: String) {
        let flags = ShortcutRouter.modifiers(of: event.modifierFlags)
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty {
            onRecord?(id, .unbound)
            return stop()
        }
        guard let (key, modifiers) = ShortcutRouter.combination(for: event) else { return }
        let chord = ShortcutChord(key, modifiers)
        guard chord.isAssignable else {
            refused = true
            return
        }
        onRecord?(id, .chord(chord))
        stop()
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct ShortcutsSettingsPane: View {
    @Bindable var model: BrowserViewModel
    @State private var query = ""
    @State private var recorder = ShortcutRecorder()
    @State private var showingEssentials = false

    /// docs/SHORTCUTS.md "Essential shortcuts", with the chords as set now.
    private var essentials: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(ArcShortcuts.essentialIDs, id: \.self) { id in
                if let shortcut = ArcShortcuts.binding(id: id) {
                    GridRow {
                        Text(model.shortcutOverrides.chord(for: id)?.display ?? "—")
                            .font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
                        Text(shortcut.title)
                    }
                }
            }
        }
        .padding(16)
    }

    var body: some View {
        let rows = model.shortcutOverrides.rows(matching: query)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Click a shortcut to record a new one. Delete clears it; Esc cancels.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Learn the Essential Shortcuts") { showingEssentials = true }
                    .controlSize(.small)
                    .popover(isPresented: $showingEssentials, arrowEdge: .bottom) { essentials }
            }
            TextField("Type a feature name or shortcut", text: $query)
                .textFieldStyle(.roundedBorder)
            Text("Default Shortcuts").font(.headline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ShortcutListRowView(row: row, isRecording: recorder.recordingID == row.id,
                                            refused: recorder.refused && recorder.recordingID == row.id) {
                            recorder.recordingID == row.id ? recorder.stop() : recorder.start(row.id)
                        } reset: {
                            model.shortcutOverrides.reset(row.id)
                        }
                        Divider()
                    }
                    if rows.isEmpty {
                        Text("No shortcuts match “\(query)”.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            .frame(height: 340)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
            HStack {
                Text("Changes apply to the menu bar at once. When shortcuts conflict, the one earlier in the menu bar wins.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset All Shortcuts") {
                    recorder.stop()
                    model.shortcutOverrides.resetAll()
                }
                .disabled(!model.shortcutOverrides.hasChanges)
            }
        }
        .onAppear {
            // The model does not hold the recorder: no cycle.
            recorder.onRecord = { [model] id, change in
                switch change {
                case .chord(let chord): model.shortcutOverrides.set(chord, for: id)
                case .unbound: model.shortcutOverrides.unbind(id)
                }
            }
        }
        .padding(20)
        .onDisappear { recorder.stop() }
    }
}

private struct ShortcutListRowView: View {
    let row: ShortcutListRow
    let isRecording: Bool
    let refused: Bool
    let record: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(row.title).lineLimit(1)
            if row.isCustomized {
                Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Reset to \(ArcShortcuts.binding(id: row.id).map { $0.display } ?? "the default")")
            }
            Spacer()
            if !row.conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(row.conflicts.map(\.message).joined(separator: "\n"))
            }
            Button(action: record) {
                Text(isRecording ? (refused ? "Add ⌘, ⌃ or ⌥" : "Type shortcut…") : row.chipText)
                    .font(.system(.callout, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(minWidth: 54)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 1))
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new shortcut" : "Click to record a new shortcut")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: Icon

struct IconSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsForm {
            SettingsBox {
                ForEach(AppIconChoice.available) { choice in
                    Button { model.appIcon = choice } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.appIcon == choice ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.appIcon == choice ? Color.accentColor : .secondary)
                            if let image = choice.image {
                                Image(nsImage: image).resizable().frame(width: 36, height: 36)
                            }
                            Text(choice.title)
                            Spacer()
                            if model.appIcon == choice {
                                Text("CURRENT ICON").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {} footer: {
                Text("The Dock shows the icon while ReArc is running. Finder and Launchpad keep the standard icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Advanced

struct AdvancedSettingsPane: View {
    @Bindable var model: BrowserViewModel
    let capabilities: SettingsCapabilities
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue

    var body: some View {
        SettingsForm {
            SettingsBox {
                SettingsToggleRow(label: "When opening ReArc, restore windows from previous session", isOn: $model.restoresWindows)
                SettingsToggleRow(label: "Show URL in toolbar", detail: urlInToolbar
                    ? "Back, forward, reload and the address sit in a strip at the top of the page."
                    : "Back, forward, reload and the address sit at the top of the sidebar.",
                    isOn: $urlInToolbar)
            }
            SettingsBox {
                if capabilities.pictureInPicture {
                    SettingsToggleRow(label: "Enable Picture in Picture when you leave a video tab", isOn: $model.automaticPictureInPicture)
                }
                SettingsToggleRow(label: "Play video in the sidebar", detail: "A video you leave plays above its sidebar strip instead of a floating window.",
                                  isOn: $model.embedsVideoInSidebar)
                SettingsToggleRow(label: "Enable Boosts on websites you visit", detail: "In every profile.",
                                  isOn: Binding(get: { model.boostsEnabledInAllProfiles }, set: { model.boostsEnabledInAllProfiles = $0 }))
                if let leakCheck = capabilities.passwordLeakCheck {
                    SettingsToggleRow(label: "Warn if passwords are exposed in a data breach", isOn: leakCheck)
                }
            }
            if model.canOpenBrowserPage(.settings) {
                Section {} footer: {
                    HStack {
                        Spacer()
                        Button("More Settings…") { model.openBrowserPage(.settings) }
                    }
                }
            }
        }
    }
}
