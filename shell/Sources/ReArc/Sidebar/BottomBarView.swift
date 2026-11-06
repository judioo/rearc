import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// The sidebar's bottom bar as Arc draws it (THEMES.md §4.7): the Library
/// (archive) button at the left, one 4 pt dot per space of this window's
/// profile on a 9 pt pitch (the current space: its icon, or an 8 pt dot),
/// and the "+" menu at the right, 17 pt in from each side and centred
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
    @State private var showingPlusMenu = false
    @State private var renamingProfileID: Profile.ID?
    @State private var renameDraft = ""
    @State private var profileActionError: String?
    /// The Library button's downloads stack; local so hover never re-renders the sidebar.
    @State private var libraryReveal = HoverReveal()
    @State private var revealTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 49

    var body: some View {
        let libraryOpen = model.librarySection(in: window) != nil
        let recent = libraryOpen ? [] : RecentDownloads.latest(model.downloads.records)
        let showsDownloads = libraryReveal.isShown && !recent.isEmpty
        VStack(spacing: 0) {
            // The downloads stack takes the update pill's place while shown.
            // The Library's rail has no pill.
            if !libraryOpen {
                UpdateBannerSlot(update: model.availableUpdate) { model.installUpdate?() }
                    .opacity(showsDownloads ? 0 : 1)
                    .animation(QuickViewMotion.pill(reduceMotion: reduceMotion, showingDownloads: showsDownloads), value: showsDownloads)
            }
            bar(libraryOpen: libraryOpen)
                .overlay(alignment: .top) {
                    // The stack rises from the button and rests wholly above the bar, at its
                    // own height (not the bar's), so it never covers the Library button. Its
                    // bottom sits on a zero-height anchor at the bar's top edge: an overlay
                    // ignores a `.top` guide moved to the content's bottom.
                    Color.clear.frame(height: 0)
                        .overlay(alignment: .bottom) {
                            if showsDownloads {
                                RecentDownloadsStack(records: recent, downloads: model.downloads)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onHover { setLibraryHover($0, .content) }
                                    .transition(QuickViewMotion.transition(reduceMotion: reduceMotion))
                            }
                        }
                }
        }
        .animation(.linear(duration: showsDownloads ? DownloadsQuickView.openDuration : DownloadsQuickView.closeDuration), value: showsDownloads)
        .onChange(of: libraryOpen) { _, _ in dismissLibraryHover() }
    }

    @ViewBuilder
    private func bar(libraryOpen: Bool) -> some View {
        let current = model.space(in: window)
        let profile = model.profile(in: window)
        HStack(spacing: 0) {
            if libraryOpen {
                // In the Library the bar shows only Arc's ← (§5.1); Esc leaves too.
                Button { model.closeLibrary(in: window) } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(chrome.glyph)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(BarButtonChip(label: .exitLibrary))
                .accessibilityLabel("Exit Library")
                Spacer(minLength: 0)
            } else {
                normalBar(current: current, profile: profile)
            }
        }
        .padding(.horizontal, 17)
        .frame(height: Self.height)
        .coordinateSpace(.named(BarChip.coordinateSpace))
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

    /// The bar outside the Library: Library button, space dots, downloads, sync and +.
    @ViewBuilder
    private func normalBar(current: Space, profile: Profile) -> some View {
        // Arc's Home button (`SidebarHomeButton`): opens the Library on
        // its last page, or closes it. Resting on it shows the latest
        // downloads above the bar (ARC-RECORDING-2026-11-06.md §5.1).
        LibraryButton(isRevealed: libraryReveal.isShown) {
            dismissLibraryHover()
            model.toggleLibrary(in: window)
        } onHover: { setLibraryHover($0, .trigger) }
        .modifier(BarButtonChip(label: .library(overrides: model.shortcutOverrides)))
        .accessibilityLabel("Library")
        .accessibilityHint("View Library: Spaces, Downloads, Media, Easels & Notes, Archive and Boosts")
        .popover(isPresented: $showingProfileList, arrowEdge: .top) {
            ProfileListView(
                model: model,
                isPresented: $showingProfileList,
                onRename: beginRename,
                onDelete: attemptDelete
            )
        }
        // Its chip lies over the dots.
        .zIndex(1)

        Spacer(minLength: 6)

        SpaceDotRow(model: model, current: current, draggedItemID: $draggedItemID, draggedSpaceID: $draggedSpaceID)
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

        // Arc's + menu: an in-window panel above the bar; the + turns
        // into × while it is open (ARC-RECORDING-ANALYSIS.md §5.1).
        Button { showingPlusMenu.toggle() } label: {
            Image(systemName: showingPlusMenu ? "xmark" : "plus")
                .font(.system(size: showingPlusMenu ? 13 : 15, weight: .medium))
                .foregroundStyle(chrome.glyph)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(BarButtonChip(label: .new, placement: .above, isEnabled: !showingPlusMenu))
        .accessibilityLabel(showingPlusMenu ? "Close Menu" : "New")
        .accessibilityHint("New Space, Folder, Easel, Boost, Split or Tab")
        .popover(isPresented: $showingPlusMenu, arrowEdge: .top) {
            PlusMenuPanel(sections: plusMenu(current: current, profile: profile)) { showingPlusMenu = false }
        }
    }

    // MARK: Library hover

    private func setLibraryHover(_ hovering: Bool, _ region: HoverReveal.Region) {
        libraryReveal.setHovering(hovering, region, at: ProcessInfo.processInfo.systemUptime)
        revealTask?.cancel()
        guard let deadline = libraryReveal.deadline else { return }
        revealTask = Task { @MainActor in
            let wait = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            libraryReveal.advance(to: max(ProcessInfo.processInfo.systemUptime, deadline))
        }
    }

    private func dismissLibraryHover() {
        revealTask?.cancel()
        libraryReveal.dismiss()
    }

    /// Arc's rows and shortcuts in Arc's order, then ReArc's extras.
    private func plusMenu(current: Space, profile: Profile) -> [[PlusMenuPanel.Row]] {
        [
            [.init("New Space", "plus.rectangle.portrait") { model.beginSpaceCreation(profileID: current.profileID) },
             .init("New Folder", "folder.badge.plus") { model.newFolder() }],
            [.init("New Easel", "scribble.variable", shortcut: "⌃⇧E") { _ = model.createEasel() },
             .init("New Boost", "paintbrush.pointed") { model.newBoost() }],
            [.init("New Split", "rectangle.split.2x1", shortcut: "⌃⇧=") { model.addSplitView(orientation: .horizontal) },
             .init("New Tab", "plus.square", shortcut: "⌘T") { model.newTab() }],
            [.init("New Note", "note.text") { _ = model.createEasel(title: "Note", note: true) },
             .init("Split Below", "rectangle.split.1x2") { model.addSplitView(orientation: .vertical) },
             .init("Spaces in \(profile.name)…", "square.stack") { showingSpaceList = true },
             .init("Profiles…", "person.2") { showingProfileList = true }],
        ]
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

/// The space dots. Hover lives here so moving along the row redraws only the
/// row: the hovered dot morphs into its space's icon and the current space's
/// icon falls back to its larger dot, so one icon shows at a time (§5.2).
/// After a rest a chip above the dot names the space and its ⌃N, in the
/// space's own colours; it moves straight to the next dot along the row.
private struct SpaceDotRow: View {
    let model: BrowserViewModel
    let current: Space
    @Binding var draggedItemID: UUID?
    @Binding var draggedSpaceID: Space.ID?
    @State private var hoveredSpaceID: Space.ID?
    @State private var chip = HoverChipTiming<Space.ID>()
    @State private var chipTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spaces = model.store.spaces(in: current.profileID)
        let appearances = SpaceDots.appearances(spaces: spaces, current: current.id, hovered: hoveredSpaceID)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceIconButton(
                        model: model,
                        space: space,
                        index: index,
                        appearance: appearances[index],
                        isLabelled: chip.shown == space.id,
                        onHover: { hover(space.id, $0) },
                        draggedItemID: $draggedItemID,
                        draggedSpaceID: $draggedSpaceID
                    )
                }
            }
        }
        .frame(maxWidth: 140)
        .fixedSize(horizontal: true, vertical: false)
        // Outside the scroll view, so the chip is not clipped to the row.
        .overlayPreferenceValue(SpaceDotChipAnchor.self) { anchor in
            if let anchor, let index = spaces.firstIndex(where: { $0.id == chip.shown }) {
                GeometryReader { proxy in
                    let row = proxy.frame(in: .named(BarChip.coordinateSpace))
                    BarChipAboveLayout(anchor: proxy[anchor], minX: -row.minX, maxX: model.sidebarWidth - row.minX) {
                        spaceChip(spaces[index], index: index)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// The row reflows in the same transaction as the morph.
    private func hover(_ id: Space.ID, _ hovering: Bool) {
        hoverChip($chip, $chipTask, hovering: hovering, id: id)
        let next = hovering ? id : (hoveredSpaceID == id ? nil : hoveredSpaceID)
        guard next != hoveredSpaceID else { return }
        withAnimation(SidebarMotion.spring(response: SpaceIconButton.morphResponse, reduceMotion: reduceMotion)) {
            hoveredSpaceID = next
        }
    }

    private func spaceChip(_ space: Space, index: Int) -> BarChip {
        let dark = space.theme.appearance.isDark(systemDark: SystemAppearance.isSystemDark)
        let colors = model.themeColors.colors(for: space.id, theme: space.theme, dark: dark)
        return BarChip(label: .space(named: space.name, at: index, overrides: model.shortcutOverrides),
                       fill: colors.toast, text: colors.title, secondary: colors.secondaryText, swatch: Color(space.theme))
    }
}

/// The bounds of the dot whose chip shows.
private struct SpaceDotChipAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
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
    let appearance: SpaceDotAppearance
    let isLabelled: Bool
    let onHover: (Bool) -> Void
    @Binding var draggedItemID: UUID?
    @Binding var draggedSpaceID: Space.ID?
    @State private var isTargeted = false

    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dot ↔ icon in about 0.15 s (§5.2: 130–200 ms).
    static let morphResponse = 0.15

    var body: some View {
        Button { model.selectSpace(space.id) } label: {
            ZStack {
                if appearance == .icon {
                    SpaceIconView(iconName: space.iconName, size: 11)
                        .foregroundStyle(chrome.accent)
                        .transition(morph)
                } else {
                    // 4 pt on a 9 pt pitch; the current space's dot is 8 pt.
                    let large = appearance == .largeDot
                    Circle()
                        .fill(large ? chrome.accent : chrome.tertiaryText)
                        .frame(width: large ? 8 : 4, height: large ? 8 : 4)
                        .transition(morph)
                }
            }
            .frame(width: width, height: 24)
            .background(isTargeted ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .anchorPreference(key: SpaceDotChipAnchor.self, value: .bounds) { isLabelled ? $0 : nil }
        .accessibilityLabel(space.name)
        .accessibilityHint("Drop a tab here to move it to this space")
        .contextMenu { SpaceContextMenu(model: model, space: space) }
        .onDrag {
            draggedSpaceID = space.id
            return SidebarDragPayload.itemProvider(for: space.id)
        }
        .onDrop(of: [.plainText], delegate: SpaceIconDropDelegate(icon: self, isTargeted: $isTargeted))
    }

    private var width: CGFloat {
        switch appearance {
        case .dot: return 9
        case .largeDot: return 13
        case .icon: return 22
        }
    }

    private var morph: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity)
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
                        Button("Edit Avatar and Color…") {
                            isPresented = false
                            model.beginProfileEditing(profile)
                        }
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
                model.beginProfileCreation()
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

/// The + menu's panel: sections of rows with an SF Symbol, the title and
/// Arc's shortcut, a grey chip under the hovered row (§5.1; ≈ 213 pt wide).
struct PlusMenuPanel: View {
    struct Row: Identifiable {
        let id = UUID()
        var title: String
        var systemImage: String
        var shortcut: String?
        var action: () -> Void

        init(_ title: String, _ systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.shortcut = shortcut
            self.action = action
        }
    }

    let sections: [[Row]]
    let dismiss: () -> Void
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, rows in
                if index > 0 { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
                ForEach(rows) { row in
                    Button {
                        dismiss()
                        row.action()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.systemImage).frame(width: 18).foregroundStyle(.secondary)
                            Text(row.title)
                            Spacer(minLength: 12)
                            if let shortcut = row.shortcut {
                                Text(shortcut).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(hovered == row.id ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                }
            }
        }
        .padding(6)
        .frame(width: 213)
    }
}
