import AppKit
import SidebarModel
import SwiftUI

/// What the engine offers the Settings window beyond the model.
struct SettingsCapabilities {
    var pictureInPicture = true
    /// Chrome's "Warn you if passwords are exposed in a data breach" (Chromium only).
    var passwordLeakCheck: Binding<Bool>?
    /// What Safe Browsing is doing now: the engine's key (ABI 1.57) and whether
    /// lists have actually been downloaded. nil: no such engine (WebKit).
    /// Settings never claims protection the build is not giving (audit F-02).
    var safeBrowsingStatus: (() -> SafeBrowsingStatus)?
}

/// Arc's Settings window (FEATURE-SPECS/SETTINGS.md §11). One pane at a
/// time in a fixed 684 × 562 pt content area under the toolbar; long panes
/// scroll inside it. The Chromium shell hosts it under an NSToolbar
/// (`SettingsWindowController`), the WebKit app in its `Settings` scene.
struct SettingsPaneView: View {
    @Bindable var model: BrowserViewModel
    let pane: SettingsPane
    var capabilities = SettingsCapabilities()

    var body: some View {
        Group {
            switch pane {
            case .account: AccountSettingsPane(model: model)
            case .general: GeneralSettingsPane(model: model)
            case .profiles: ProfilesSettingsPane(model: model, capabilities: capabilities)
            case .max: MaxSettingsPane(model: model)
            case .links: LinksSettingsPane(model: model)
            case .shortcuts: ShortcutsSettingsPane(model: model)
            case .icon: IconSettingsPane(model: model)
            case .advanced: AdvancedSettingsPane(model: model, capabilities: capabilities)
            }
        }
        .frame(width: SettingsMetrics.windowSize.width, height: SettingsMetrics.contentHeight, alignment: .top)
        .background(SettingsColors.background)
        // Arc's 1 pt line under the toolbar.
        .overlay(alignment: .top) { SettingsHairline() }
        .buttonStyle(SettingsButtonStyle())
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
                    .tabItem { Label(pane.title(accountName: model.accountName), systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
    }
}

// MARK: Form rows (File › Import)

/// A grouped form: label on the left, control on the right. The Import
/// window still uses these; Settings uses Arc's boxes (SettingsChrome).
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

private extension AutoArchiveThreshold {
    static var options: [(value: AutoArchiveThreshold, title: String)] { allCases.map { ($0, $0.title) } }
}

// MARK: General

/// Arc's General keeps Warn before quitting and Profile Settings…; its
/// updater and Previews rows wait for those features. ReArc's own rows
/// (default browser, the sidebar's look and sides) have their own box.
struct GeneralSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsPage {
            SettingsGroup {
                SettingsSwitchRow(label: "Warn before quitting", isOn: $model.warnBeforeQuitting)
                SettingsLabeledRow(label: "Default browser") {
                    Button("Set ReArc as Default…") { model.setAsDefaultBrowser() }
                }
            }
            #if REARC_CHROMIUM
            if AppUpdater.shared.isEnabled { UpdateSettingsSection() }
            #endif
            SettingsGroup {
                SettingsLabeledRow(label: "New spaces", detail: "Containers are profiles with separate cookies, sign-ins and site storage. Each space can choose a profile in its menu.") {
                    SettingsPopUp(label: "New spaces", selection: $model.newSpaceContainerPolicy,
                                  options: NewSpaceContainerPolicy.allCases.map { ($0, $0.title) })
                }
                SettingsLabeledRow(label: "Space icons") {
                    SettingsPopUp(label: "Space icons", selection: $model.spaceIconStyle,
                                  options: SpaceIconStyle.allCases.map { ($0, $0.title) })
                }
                SettingsLabeledRow(label: "Sidebar position", detail: "The traffic lights stay at the window's top left.") {
                    Picker("Sidebar position", selection: Binding(
                        get: { model.pendingSidebarSide ?? model.sidebarSide },
                        set: { model.setSidebarSide($0) }
                    )) {
                        ForEach(SidebarSide.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden().fixedSize()
                }
                SettingsLabeledRow(label: "Side panel position",
                                   detail: "Extension side panels. On the sidebar's side, the panel sits between the sidebar and the page.") {
                    SettingsPopUp(label: "Side panel position", selection: Binding(
                        get: { model.pendingSidePanelPosition ?? model.sidePanelPosition },
                        set: { model.setSidePanelPosition($0) }
                    ), options: SidePanelPosition.allCases.map { ($0, $0.title) })
                }
            }
            SettingsGroup {
                SettingsLabeledRow(label: "Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { model.settingsPane = .profiles }
                }
            }
        }
    }
}

// MARK: Profiles

/// Arc's two columns: the profile list on the left (205 pt), the selected
/// profile's boxes on the right.
struct ProfilesSettingsPane: View {
    @Bindable var model: BrowserViewModel
    var capabilities = SettingsCapabilities()
    @State private var editor: ProfileEditorRequest?
    @State private var selection: Profile.ID?
    /// A profile only iCloud has, selected in the list's "In iCloud only".
    @State private var cloudSelection: Profile.ID?
    @State private var renaming: Profile.ID?
    @State private var renameDraft = ""
    @State private var deleting: Profile.ID?
    /// A container whose Remove Container… is asking.
    @State private var removingContainer: Profile.ID?
    @State private var showsLearnMore = false

    private static let listWidth: CGFloat = 205

    private var selected: Profile? {
        model.store.profile(withID: selection ?? model.store.activeProfileID) ?? model.store.profiles.first
    }

    private var selectedCloud: CloudProfile? {
        cloudSelection.flatMap(model.cloudOnlyProfile)
    }

    private var selectedIsContainer: Bool {
        selectedCloud == nil && selected.map { model.store.isContainer($0.id) } == true
    }

    var body: some View {
        SettingsPage {
            intro
            HStack(alignment: .top, spacing: 10) {
                profileList
                VStack(alignment: .leading, spacing: SettingsMetrics.boxSpacing) {
                    if let cloud = selectedCloud {
                        CloudProfileDetail(model: model, cloud: cloud)
                    } else if let profile = selected, model.store.isContainer(profile.id) {
                        ContainerSettingsDetail(model: model, container: profile, removing: $removingContainer)
                    } else if let profile = selected {
                        ProfileCloudStatusGroup(model: model, profileID: profile.id)
                        profileSettings(profile)
                        ProfileContainerConversionGroup(model: model, profile: profile)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 10)
        }
        .sheet(item: $editor) { request in
            ProfileEditorView(draft: request.draft, isCreating: request.profileID == nil, images: model.avatarImages) { draft in
                guard let profile = model.saveProfile(draft, id: request.profileID, selecting: false) else { return false }
                selection = profile.id
                return true
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
            Text(ProfileCloudText.localDeleteMessage(deleting.map(model.cloudPresence(of:)) ?? .onlyHere, syncOn: model.isSyncEnabled)
                 + (deleting.map { model.containersDeletedNote($0, reachesICloud: false) } ?? ""))
        }
        .cloudProfileDeleteAlert(model)
        .containerRemovalAlert(model, removing: $removingContainer)
        .cloudSidebarChoiceSheet(model)
    }

    /// Arc's text; its "Learn more." opens the explanation here, not a web page.
    private var intro: some View {
        (Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces. ")
            + Text("[Learn more.](rearc-settings:profiles)"))
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { _ in
                showsLearnMore = true
                return .handled
            })
            .popover(isPresented: $showsLearnMore, arrowEdge: .bottom) {
                Text("Each profile has its own history, cookies, logins, passwords and extensions, and its own search engine and Archive setting. A space belongs to one profile: switching to it switches the profile. Pick a profile when you make a space, or change it in Edit Space. A container gives one space its own sign-ins inside its profile; it is listed under the profile.")
                    .font(.callout)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            .padding(.horizontal, 2)
    }

    private var deleteTitle: String {
        let name = deleting.flatMap { model.store.profile(withID: $0)?.name } ?? "Profile"
        return "Delete “\(name)”?"
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            Text("Your Profiles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsColors.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .accessibilityAddTraits(.isHeader)
            SettingsHairline()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.store.listedProfiles) { profile in
                        profileRow(profile)
                        ForEach(model.store.containers(of: profile.id)) { container in
                            ContainerProfileRow(model: model, container: container,
                                                isSelected: selectedCloud == nil && container.id == selected?.id) {
                                selection = container.id
                                cloudSelection = nil
                            }
                        }
                    }
                    CloudOnlyProfilesSection(model: model, selection: $cloudSelection)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
            }
            SettingsHairline()
            HStack(spacing: 0) {
                listButton("plus", help: "Add Profile") { editor = ProfileEditorRequest() }
                Divider().frame(height: 18)
                listButton("minus", help: model.store.listedProfiles.count < 2 && selectedCloud == nil && !selectedIsContainer
                           ? "The last profile can't be deleted." : selectedIsContainer ? "Remove Container" : "Delete Profile") {
                    deleteSelected()
                }
                .disabled(model.store.listedProfiles.count < 2 && selectedCloud == nil && !selectedIsContainer)
                Divider().frame(height: 18)
                listButton("pencil", help: "Rename Profile") {
                    renameDraft = selected?.name ?? ""
                    renaming = selected?.id
                }
                Spacer()
            }
            .frame(height: 30)
        }
        .frame(width: Self.listWidth, height: 445)
        .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).strokeBorder(SettingsColors.border))
    }

    /// A profile iCloud has too asks where to delete it from; one only here
    /// (or not known yet) deletes as it always did; one only in iCloud is deleted there.
    private func deleteSelected() {
        if let cloud = selectedCloud { return _ = model.requestCloudProfileDeletion(cloud.id) }
        guard let id = selected?.id else { return }
        if selectedIsContainer { return removingContainer = id }
        // Sync on and up to date counts as in iCloud before a look lists it: the plain delete reaches iCloud then.
        if model.cloudPresence(of: id) == .inICloud, model.canDeleteFromICloud, model.requestCloudProfileDeletion(id) { return }
        deleting = id
    }

    private func profileRow(_ profile: Profile) -> some View {
        let isSelected = selectedCloud == nil && profile.id == selected?.id
        return Button {
            selection = profile.id
            cloudSelection = nil
        } label: {
            HStack(spacing: 6) {
                ProfileAvatarView(profile: profile, diameter: 16)
                Text(profile.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Text(model.spaceCountText(for: profile.id)).font(.system(size: 11)).foregroundStyle(.secondary)
                CloudPresenceMark(presence: model.cloudPresence(of: profile.id))
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(isSelected ? SettingsColors.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if model.cloudPresence(of: profile.id) == .onlyHere {
                Button(ProfileCloudText.putInICloud(syncOn: model.isSyncEnabled)) { model.putInICloud(profile.id) }
                    .disabled(!model.canPutInICloud(profile.id))
            }
        }
    }

    private func listButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func profileSettings(_ profile: Profile) -> some View {
        SettingsGroup {
            SettingsLabeledRow(label: "Avatar and colour") {
                Button("Edit…") { editor = ProfileEditorRequest(profile: profile) }
            }
        }
        if let search = model.activeSearchEngineSettings {
            SettingsGroup {
                SettingsLabeledRow(label: "Search engine") {
                    SettingsPopUp(label: "Search engine", selection: Binding(
                        get: { search.defaultEngine(for: profile.id) ?? "" },
                        set: { model.setDefaultSearchEngine($0, for: profile.id) }
                    ), options: search.engines(for: profile.id).map { ($0.id, $0.name) })
                    .disabled(!search.isEditable(for: profile.id))
                }
                if model.canOpenBrowserPage(.searchSettings) {
                    SettingsLabeledRow(label: "Manage search") { Button("Search Settings…") { open(.searchSettings, in: profile) } }
                }
            }
        } else if model.canOpenBrowserPage(.searchSettings) {
            SettingsGroup {
                SettingsLabeledRow(label: "Search engine") { Button("Search Settings…") { open(.searchSettings, in: profile) } }
            }
        }
        SettingsGroup {
            SettingsLabeledRow(label: "Archive tabs after",
                               info: "Today tabs you haven't opened in this long move to the Archive. Pinned tabs and Favorites stay. Each profile has its own setting.") {
                SettingsPopUp(label: "Archive tabs after", selection: Binding(
                    get: { model.store.autoArchiveThreshold(for: profile.id) },
                    set: { model.store.setAutoArchiveThreshold($0, for: profile.id) }
                ), options: AutoArchiveThreshold.options)
            }
            if model.canOpenBrowserPage(.downloadSettings) {
                SettingsLabeledRow(label: "Download location") { Button("Download Settings…") { open(.downloadSettings, in: profile) } }
            }
        }
        ArchivedSpacesGroup(model: model, profileID: profile.id)
        // Arc's icons and colours.
        let dataRows: [(BrowserInternalPage, String, Color)] = [
            (.privacy, "lock.fill", .blue),
            (.passwords, "key.fill", .green),
            (.payments, "creditcard.and.123", .yellow),
            (.notifications, "bell.fill", .orange),
            (.clearBrowsingData, "trash.fill", .red),
        ].filter { model.canOpenBrowserPage($0.0) }
        if !dataRows.isEmpty {
            SettingsHeader(title: "Your Data and Settings")
            if let status = capabilities.safeBrowsingStatus?() {
                let row = SafeBrowsingRow(status)
                SettingsGroup {
                    SettingsLabeledRow(label: "Safe Browsing", info: row.info) {
                        Text(row.value)
                            .foregroundStyle(row.isWarning ? Color.red : Color.secondary)
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(dataRows, id: \.0) { page, symbol, color in
                    SettingsLinkRow(title: page.title, systemImage: symbol, color: color) { open(page, in: profile) }
                }
            }
            .padding(.vertical, 5)
            .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).strokeBorder(SettingsColors.border))
        }
    }

    /// Chromium's page opens as a tab of that profile (its own storage and
    /// settings), in one of its own spaces, never in one of its containers'.
    private func open(_ page: BrowserInternalPage, in profile: Profile) {
        model.openBrowserPage(page, inStorageOf: profile.id)
    }
}

// MARK: Links

/// Little Arc and Peek, each introduced as in Arc, under ReArc's own hero.
struct LinksSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsPage(topPadding: 0) {
            LittleArcHero(model: model)
                .padding(.horizontal, -SettingsMetrics.margin)
                .padding(.bottom, 22)
            SettingsIntro(text: "Little ReArc is a smaller, simpler ReArc window. It’s perfect for quick lookups and reading the links your friends send you.")
                .padding(.bottom, 14)
            SettingsGroup {
                SettingsSwitchRow(label: "Open Little ReArc when I press \(LittleArcHotkeyPreference.display) in any app",
                                  isOn: $model.isLittleArcHotkeyEnabled)
                SettingsSwitchRow(label: "Open Little ReArc when clicking on links with ⌥⌘ held", isOn: $model.littleArcOnModifiedClick)
                SettingsSwitchRow(label: "Links from other apps open in Little ReArc", detail: model.externalLinkDestination == .littleArc
                                      ? nil : "Off: they open as a new tab in the current space.",
                                  isOn: Binding(get: { model.externalLinkDestination == .littleArc },
                                                set: { model.externalLinkDestination = $0 ? .littleArc : .activeSpace }))
                SettingsLabeledRow(label: "Archive Little ReArcs after:") {
                    SettingsPopUp(label: "Archive Little ReArcs after", selection: $model.littleArcArchiveAfter,
                                  options: AutoArchiveThreshold.options)
                }
            }
            SettingsHairline().padding(.vertical, 16)
            SettingsIntro(text: "Peek is a way to preview a link without opening a new tab. It’s perfect for quickly looking at a link from an email, a news article, or a post.")
                .padding(.bottom, 14)
            SettingsGroup {
                SettingsSwitchRow(label: "Open a Peek window when clicking on links with Shift held", isOn: $model.peekOnShiftClick)
                SettingsSwitchRow(label: "Open a Peek window when clicking on links to other sites",
                                  detail: "Note: This only affects Favorites and Pinned tabs", italicDetail: true,
                                  isOn: $model.automaticPeekEnabled)
            }
            SettingsGroup {
                SettingsLabeledRow(label: "Choose where links open inside ReArc.",
                                   info: "Air Traffic Control sends links from other apps to a space or a Little ReArc of a profile, by site or by the app they come from.") {
                    Button("Air Traffic Control…") { model.showAirTrafficControl() }
                }
            }
        }
    }
}

/// ReArc's own Links hero, drawn here: a Little Arc window over the active
/// space's theme, with a scalloped edge.
private struct LittleArcHero: View {
    let model: BrowserViewModel

    var body: some View {
        let theme = model.themeColor
        let space = model.store.activeSpace.name
        ZStack(alignment: .top) {
            theme.opacity(0.8)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.black.opacity(0.14)).frame(width: 6, height: 6) }
                    }
                    Text("☺ \(space)")
                        .font(.system(size: 7, weight: .medium))
                        .padding(.horizontal, 5).frame(height: 13)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    Label("rearc.imara.ae", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                        .font(.system(size: 7.5, weight: .medium))
                    Spacer()
                    Text("Open in \(space)  ⌘O")
                        .font(.system(size: 7, weight: .medium))
                        .padding(.horizontal, 6).frame(height: 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 3))
                }
                .foregroundStyle(.black.opacity(0.6))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.white.opacity(0.55))
                LinearGradient(colors: [theme.opacity(0.55), theme.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .background(.white.opacity(0.5))
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 60)
            .padding(.top, 47)
        }
        .frame(width: SettingsMetrics.windowSize.width, height: 135)
        .clipShape(ScallopedBottom())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A Little ReArc window")
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

/// Arc's layout: the "Start with the basics" pill, the searchable list in a
/// 340 pt box on the left, ReArc's keycaps and the explanation on the right,
/// Reset All and the ⋯ menu at the bottom right.
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
        VStack(spacing: 0) {
            pill.padding(.top, 20)
            HStack(alignment: .top, spacing: 16) {
                list
                sideCard
            }
            .padding(.horizontal, SettingsMetrics.margin)
            .padding(.top, 30)
            .padding(.bottom, 26)
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
        .onDisappear { recorder.stop() }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Text("Start with the basics").font(.system(size: 13))
            Button { showingEssentials = true } label: {
                Label("Learn the Essential Shortcuts", systemImage: "command.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingEssentials, arrowEdge: .bottom) { essentials }
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }

    private var list: some View {
        let rows = model.shortcutOverrides.rows(matching: query)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a feature name or shortcut (like “Command”)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            SettingsHairline()
            Text("Default Shortcuts")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsColors.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .accessibilityAddTraits(.isHeader)
            SettingsHairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ShortcutListRowView(row: row, isRecording: recorder.recordingID == row.id,
                                            refused: recorder.refused && recorder.recordingID == row.id) {
                            recorder.recordingID == row.id ? recorder.stop() : recorder.start(row.id)
                        } reset: {
                            model.shortcutOverrides.reset(row.id)
                        }
                        if row.id != rows.last?.id { SettingsHairline().padding(.horizontal, 24) }
                    }
                    if rows.isEmpty {
                        Text("No shortcuts match “\(query)”.").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsColors.border))
    }

    private var sideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ShortcutKeycap { Image(systemName: "command").font(.system(size: 26, weight: .bold)) }
                ShortcutKeycap { ReArcMarkGlyph().frame(width: 36, height: 36) }
            }
            .accessibilityHidden(true)
            Text("Custom Shortcuts")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 30)
            Text("Click a shortcut to record a new one; Delete clears it and Esc cancels. Changes reach the menu bar at once. When two clash, the one earlier in the menu bar wins.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer()
            HStack(spacing: 8) {
                Button("Reset All Shortcuts") {
                    recorder.stop()
                    model.shortcutOverrides.resetAll()
                }
                .disabled(!model.shortcutOverrides.hasChanges)
                Menu {
                    Button("Extension Shortcuts…") { model.openPageInNewTab(URL(string: "chrome://extensions/shortcuts")!, title: "Extension Shortcuts") }
                        .disabled(!model.canOpenBrowserPage(.extensions))
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(SettingsColors.border))
                .accessibilityLabel("More")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// ReArc's keycap: a blue key with a lighter face.
private struct ShortcutKeycap<Glyph: View>: View {
    @ViewBuilder var glyph: Glyph

    var body: some View {
        glyph
            .foregroundStyle(ReArcMark.blueColor)
            .frame(width: 54, height: 50)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(red: 0.86, green: 0.89, blue: 1)))
            .padding(4)
            .padding(.bottom, 3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReArcMark.blueColor))
    }
}

/// The Icon item's line glyph, in the current foreground style.
private struct ReArcMarkGlyph: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 20, y: size.height / 20)
            context.fill(Path(ReArcMark.glyphPath()), with: .foreground)
        }
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
            Text(row.title).font(.system(size: 13)).lineLimit(1)
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
                    .accessibilityLabel(row.conflicts.map(\.message).joined(separator: ". "))
            }
            Button(action: record) {
                Text(isRecording ? (refused ? "Add ⌘, ⌃ or ⌥" : "Type…") : (row.chord == nil ? "---" : row.chipText))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(row.chord == nil && !isRecording ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 62, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isRecording ? Color.accentColor : SettingsColors.border, lineWidth: isRecording ? 2 : 1))
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new shortcut" : "Click to record a new shortcut")
            .accessibilityLabel("\(row.title): \(row.chord?.display ?? "no shortcut")")
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
    }
}

// MARK: Icon

/// ReArc's app icons in Arc's rows: a radio, a 64 pt preview, the name and,
/// on the current one, CURRENT ICON in the accent colour; in two lists,
/// the Sun's Path and Treatments. None is locked.
struct IconSettingsPane: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        SettingsPage {
            let available = AppIconChoice.available
            ForEach(AppIconChoice.Group.allCases) { group in
                let choices = available.filter { $0.group == group }
                if !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsHeader(title: group.title)
                        VStack(spacing: 0) {
                            ForEach(choices) { choice in
                                row(choice)
                                if choice != choices.last { SettingsHairline().padding(.horizontal, 40) }
                            }
                        }
                        .padding(.vertical, 8)
                        .background(SettingsColors.box, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsColors.border))
                    }
                }
            }
            Text("The Dock shows the icon while ReArc is running. Finder and Launchpad keep the standard icon.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsColors.tertiary)
                .padding(.horizontal, SettingsMetrics.rowInset)
        }
    }

    private func row(_ choice: AppIconChoice) -> some View {
        let current = model.appIcon == choice
        return Button { model.appIcon = choice } label: {
            HStack(spacing: 0) {
                RadioDot(isOn: current).padding(.leading, 16)
                Group {
                    if let image = choice.image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                    }
                }
                .frame(width: 64, height: 64)
                .padding(.leading, 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.system(size: 14, weight: .semibold))
                    if current {
                        Text("CURRENT ICON").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    } else {
                        Text(choice.caption).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 14)
                Spacer()
            }
            .frame(height: 81)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// Arc's radio: a grey ring, or the accent colour with a white ring inside.
private struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Color.accentColor)
                Circle().strokeBorder(.white, lineWidth: 2.5).padding(1.5)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: Advanced

/// Arc's three boxes with their coloured icons (SETTINGS.md §9). Rows Arc
/// has for features ReArc doesn't (sounds, window dragging, Shared Quotes,
/// theme data for sites) wait for them; ReArc's own rows join the box
/// closest to them.
struct AdvancedSettingsPane: View {
    @Bindable var model: BrowserViewModel
    let capabilities: SettingsCapabilities
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue
    @AppStorage(AutoHideAddressBarPreference.key) private var autoHideAddressBar = AutoHideAddressBarPreference.defaultValue
    @AppStorage(ReorderHapticsPreference.key) private var reorderHaptics = ReorderHapticsPreference.defaultValue
    @AppStorage(ToolbarPageColorPreference.key) private var matchesPageColor = ToolbarPageColorPreference.defaultValue

    private func icon(_ symbol: String, _ color: Color) -> SettingsIconTile {
        SettingsIconTile(systemImage: symbol, color: color)
    }

    var body: some View {
        SettingsPage {
            SettingsGroup {
                SettingsSwitchRow(label: "Haptic feedback when reordering tabs", icon: icon("hand.tap.fill", .blue), isOn: $reorderHaptics)
            }
            SettingsGroup {
                SettingsSwitchRow(label: "When opening ReArc, restore windows from previous session",
                                  icon: icon("macwindow", .green), isOn: $model.restoresWindows)
                if let leakCheck = capabilities.passwordLeakCheck {
                    SettingsSwitchRow(label: "Warn if passwords are exposed in a data breach",
                                      icon: icon("key.viewfinder", .green), isOn: leakCheck)
                }
                SettingsSwitchRow(label: "Show URL in toolbar", detail: urlInToolbar
                    ? "Back, forward, reload and the address sit in a strip at the top of the page."
                    : "Back, forward, reload and the address sit at the top of the sidebar.",
                    icon: icon("menubar.rectangle", .red), isOn: $urlInToolbar)
                // Not tied to the switch above: the mini sidebar (⇧⌘S) puts the address in the toolbar whatever it says.
                SettingsSwitchRow(label: "Auto-hide address bar",
                                  detail: urlInToolbar
                                    ? "Move to the top of a page pane or press ⌘L to reveal its toolbar."
                                    : "Applies when the address is in the toolbar, as it always is with the mini sidebar (⇧⌘S). Move to the top of a page pane or press ⌘L to reveal it.",
                                  icon: icon("menubar.arrow.up.rectangle", .red), isOn: $autoHideAddressBar)
            }
            SettingsGroup {
                if capabilities.pictureInPicture {
                    SettingsSwitchRow(label: "Enable Picture in Picture when you leave a video tab",
                                      icon: icon("play.square", .purple), isOn: $model.automaticPictureInPicture)
                }
                if model.engineHost.supportsLiveVideo {
                    SettingsSwitchRow(label: "Play video in the sidebar",
                                      detail: "A video you leave plays above its sidebar strip instead of a floating window.",
                                      icon: icon("play.rectangle.on.rectangle", .purple), isOn: $model.embedsVideoInSidebar)
                }
                SettingsSwitchRow(label: "Match toolbar to website colours",
                                  detail: "The toolbar takes the page's theme colour, or the colour along its top edge.",
                                  icon: icon("paintpalette.fill", .purple), isOn: $matchesPageColor)
                SettingsSwitchRow(label: "Enable Boosts on websites you visit", detail: "In every profile.",
                                  icon: icon("paintbrush.fill", .purple),
                                  isOn: Binding(get: { model.boostsEnabledInAllProfiles }, set: { model.boostsEnabledInAllProfiles = $0 }))
            }
            if model.canOpenBrowserPage(.settings) {
                HStack {
                    Button("More Settings…") { model.openBrowserPage(.settings) }
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
    }
}

/// The Settings row for `SafeBrowsingStatus`: what is happening, never what is configured.
struct SafeBrowsingRow: Equatable {
    var value: String
    var info: String
    var isWarning: Bool

    init(_ status: SafeBrowsingStatus, now: Date = Date()) {
        let level = " Choose the level in Privacy and security › Security."
        switch status {
        case .unavailable:
            value = "Unavailable"
            info = "This build of ReArc has no Safe Browsing key, so it can’t check sites or downloads against Google’s lists of phishing and malware. The protection level in Privacy and security has no effect."
            isWarning = true
        case .waitingForLists:
            value = "Starting"
            info = "ReArc is downloading Google’s lists of phishing and malware sites. Until they arrive, sites and downloads are not checked." + level
            isWarning = false
        case .active(let date):
            value = "On"
            info = "Warnings before known phishing and malware sites and downloads. Lists updated "
                + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now) + "." + level
            isWarning = false
        case .notUpdating:
            value = "Not working"
            info = "ReArc could not download Google’s lists of phishing and malware sites, so sites and downloads are not being checked. Check your network or firewall."
            isWarning = true
        case .stale(let date):
            value = "Out of date"
            info = "Google’s lists of phishing and malware sites were last updated "
                + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
                + ", so new threats are not recognised. Check your network or firewall."
            isWarning = true
        }
    }
}
