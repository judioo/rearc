import AppKit
import SwiftUI
import SidebarModel

// The mini sidebar's rows (⇧⌘S, `MiniSidebarRepresentation`): each row is
// the full row's own behaviour drawn as its icon on a 36 pt square, at the
// x the full row puts its icon. Rows keep their 41 pt pitch, so the list
// scrolls and drops exactly as it does at full width. Titles move into the
// tooltip; a tab's ✕ is in its context menu (and ⌘W), not on the square,
// where it would cover the icon.

/// The square highlight under a mini row: the full rows' fills, in one place,
/// with a ⇧/⌘-click selection's grey veil between the active pill and the
/// hover wash, as the full rows draw it (`SidebarRowWash.multiSelected`).
struct MiniRowHighlight: ViewModifier {
    var isSelected = false
    var isMultiSelected = false
    var isHovering = false
    var isDropTarget = false
    @Environment(\.themeChrome) private var chrome

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SidebarMetrics.rowHeight)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if isDropTarget {
                    shape.fill(Color.accentColor.opacity(0.22))
                } else if isSelected {
                    shape.fill(chrome.rowSelected)
                        .shadow(color: .black.opacity(chrome.isDark ? 0.3 : 0.08), radius: 1.5, y: 0.5)
                } else if isMultiSelected {
                    // Arc keeps the grey under the pointer.
                    shape.fill(chrome.rowMultiSelected)
                } else if isHovering {
                    shape.fill(chrome.rowHover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
    }
}

/// A mini row's icon at the full row's icon position, with its marks on
/// the icon's corners: unread at the top, audio, Picture in Picture or a
/// split's mark at the bottom.
private struct MiniRowIcon<Icon: View, Top: View, Bottom: View>: View {
    var size: CGFloat = SidebarMetrics.iconSize
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        icon()
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) { top().offset(x: 5, y: -5) }
            .overlay(alignment: .bottomTrailing) { bottom().offset(x: 7, y: 7) }
            .padding(.leading, CGFloat(MiniSidebarLayout.iconLeading) - (size - SidebarMetrics.iconSize) / 2)
    }
}

private struct MiniUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Unread")
    }
}

/// A mark on an icon's corner in the profile badge's ink, on its opaque
/// disc (`SidebarBadgeInk.cornerDisc`), so it reads over any favicon.
private struct MiniCornerMark<Mark: InsettableShape>: View {
    let systemName: String
    let shape: Mark
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        let ink = chrome.badge
        Image(systemName: systemName)
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(Color(ink.glyph))
            .frame(width: 13, height: 13)
            .background(Color(ink.cornerDisc), in: shape)
            .overlay(shape.strokeBorder(Color(ink.glyph).opacity(ink.outlineAlpha * 0.5), lineWidth: 0.5))
    }
}

/// A small glyph button on an icon's corner (mute, Picture in Picture).
private struct MiniBadgeButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MiniCornerMark(systemName: systemName, shape: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Entries

/// One outline entry at mini width (`SidebarEntryRow` in a mini sidebar).
/// The actions are the full row's, clicks included: ⇧ and ⌘ select through
/// the same handler (`BrowserViewModel.rowClick`), and the row menus pick
/// the selection's menu by the same rule.
struct MiniSidebarEntryContent: View {
    let entry: SidebarEntry
    let spaceID: Space.ID
    let model: BrowserViewModel
    let isDropTarget: Bool
    @Environment(\.sidebarWindow) private var window

    private func isSelected(_ id: UUID) -> Bool { model.store.isSelected(id, inSpace: spaceID) }

    /// In this window's ⇧/⌘-click selection, drawn grey unless it is the active row.
    private func isMultiSelected(_ id: UUID) -> Bool { model.store.isMultiSelected(id, in: window) }

    private func click(_ id: UUID, _ action: @escaping () -> Void) -> () -> Void {
        model.rowClick(id, in: window, action)
    }

    var body: some View {
        switch entry {
        case .tab(let tab):
            MiniTabRowView(
                tab: tab,
                favicon: model.favicon(for: tab),
                isSelected: isSelected(tab.id),
                showsAudibleIndicator: model.showsAudibleIndicator(for: tab.id),
                isMuted: model.isUserMuted(tab.id),
                isDropTarget: isDropTarget,
                isUnloaded: model.isTabUnloaded(tab.id),
                isInPictureInPicture: model.isPictureInPicture(tab.id),
                activity: model.tabActivity(tab.id),
                isMultiSelected: isMultiSelected(tab.id),
                onSelect: click(tab.id) { model.selectTab(tab.id) },
                onMute: { model.toggleMute(tab.id) },
                onPictureInPicture: { model.setPictureInPicture(false, tabID: tab.id) },
                onRename: { model.beginRename(.tab(tab.id)) }
            ) {
                TabContextMenu(model: model, tab: tab)
            }
        case .folder(let folder):
            MiniFolderRowView(
                folder: folder,
                isExpanded: model.store.isFolderExpanded(folder.id),
                isDropTarget: isDropTarget,
                holdsOpenTabs: model.folderHoldsOpenTab(folder.id),
                isMultiSelected: isMultiSelected(folder.id),
                onToggle: click(folder.id) { model.store.toggleFolderExpanded(folder.id) }
            ) {
                // Inside a selection the folder's menu is the selection's.
                if model.folderHoldsOpenTab(folder.id), model.store.menuTargets(for: folder.id, in: window).count == 1 {
                    Button("Close This Folder") { model.closeFolderTabs(folder.id) }
                    Divider()
                }
                FolderContextMenu(model: model, folder: folder)
            }
        case .easel(let ref):
            MiniEaselRowView(
                ref: ref,
                title: model.easelTitle(for: ref),
                isNote: model.easelDocumentStore.document(id: ref.easelDocumentID)?.kind == .note,
                isSelected: isSelected(ref.id),
                onSelect: click(ref.id) { model.selectEasel(ref.id) }
            ) {
                SectionItemContextMenu(model: model, entry: entry)
            }
        case .split(let split):
            MiniSplitRowView(
                split: split,
                isSelected: isSelected(split.id),
                isDropTarget: isDropTarget,
                isMultiSelected: isMultiSelected(split.id) && !isSelected(split.id),
                favicon: { model.favicon(for: $0) },
                isAudible: split.tabs.contains { model.showsAudibleIndicator(for: $0.id) },
                onSelect: click(split.id) { model.selectSplit(split.id) },
                isRenaming: Binding(
                    get: { model.renamingSplitID == split.id },
                    set: { model.renamingSplitID = $0 ? split.id : nil }
                ),
                onRename: { model.renameSplit(split.id, to: $0) }
            ) {
                SectionItemContextMenu(model: model, entry: entry)
            }
        }
    }
}

/// A tab at mini width: its favicon (or the letter tile), dimmed while
/// unloaded, with the loading ring, the unread dot and the audio or Picture
/// in Picture badge on its corners.
struct MiniTabRowView<Menu: View>: View {
    let tab: Tab
    let favicon: NSImage?
    let isSelected: Bool
    let showsAudibleIndicator: Bool
    var isMuted = false
    var isDropTarget = false
    var isUnloaded = false
    var isInPictureInPicture = false
    var activity: TabActivity = .idle
    /// In a multi-row selection (drawn grey unless it is the active row).
    var isMultiSelected = false
    let onSelect: () -> Void
    var onMute: (() -> Void)? = nil
    var onPictureInPicture: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        MiniRowIcon {
            TabActivityIcon(activity: activity) {
                SiteIconView(image: favicon, token: tab.faviconToken, size: SidebarMetrics.iconSize, customIcon: tab.customIcon)
                    .saturation(isUnloaded ? 0 : 1)
                    .opacity(isUnloaded ? 0.4 : 1)
            }
        } top: {
            if tab.isUnread { MiniUnreadDot() }
        } bottom: {
            if isInPictureInPicture {
                MiniBadgeButton(systemName: "pip.fill", help: "Playing in Picture in Picture — click to bring the video back") {
                    onPictureInPicture?()
                }
            } else if showsAudibleIndicator {
                MiniBadgeButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                help: isMuted ? "Unmute tab" : "Mute tab") { onMute?() }
            }
        }
        .modifier(MiniRowHighlight(isSelected: isSelected, isMultiSelected: isMultiSelected, isHovering: isHovering,
                                   isDropTarget: isDropTarget))
        .help(MiniSidebarTooltip.text(title: tab.displayTitle, url: tab.url, isUnloaded: isUnloaded))
        .gesture(TapGesture().onEnded(onSelect))
        .simultaneousGesture(TapGesture(count: 2).onEnded { onRename?() })
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isUnread ? "\(tab.displayTitle), Unread" : tab.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A folder at mini width: Arc's folder glyph, open while expanded, with
/// dots while it holds a live page. Click toggles; its children follow as
/// indented icons.
struct MiniFolderRowView<Menu: View>: View {
    let folder: SidebarFolder
    let isExpanded: Bool
    let isDropTarget: Bool
    var holdsOpenTabs = false
    /// In a multi-row selection: Arc's grey, the glyph fitted to read on it.
    var isMultiSelected = false
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MiniRowIcon(size: SidebarMetrics.iconSize + 3) {
            Group {
                if folder.customIcon == nil {
                    Image(nsImage: SidebarFolderGlyph.image(isOpen: isExpanded, holdsOpenTabs: holdsOpenTabs))
                        .renderingMode(.template)
                } else {
                    SidebarGlyphView(icon: folder.customIcon, fallback: "folder", size: 17)
                }
            }
            .foregroundStyle(isMultiSelected ? chrome.multiSelectedAccent : chrome.accent)
        } top: {
            EmptyView()
        } bottom: {
            EmptyView()
        }
        .modifier(MiniRowHighlight(isMultiSelected: isMultiSelected, isHovering: isHovering, isDropTarget: isDropTarget))
        .help(folder.title)
        .gesture(TapGesture().onEnded {
            let duration = isExpanded ? SidebarListController.collapseDuration : SidebarListController.expandDuration
            withAnimation(reduceMotion ? nil : .easeInOut(duration: duration)) { onToggle() }
        })
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

/// A split at mini width: its own icon if it has one, else its first pane's
/// favicon with the split mark. Rename asks in a small popover.
struct MiniSplitRowView<Menu: View>: View {
    let split: SplitViewItem
    let isSelected: Bool
    let isDropTarget: Bool
    /// In a multi-row selection without being the active row.
    var isMultiSelected = false
    let favicon: (Tab) -> NSImage?
    let isAudible: Bool
    let onSelect: () -> Void
    @Binding var isRenaming: Bool
    let onRename: (String) -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    /// The split glyph's ink, fitted to the selection's grey when it is on it.
    private var glyphInk: Color { isMultiSelected ? chrome.multiSelectedSecondaryText : chrome.secondaryText }

    private var splitSymbol: String { split.orientation == .horizontal ? "square.split.2x1" : "square.split.1x2" }

    var body: some View {
        MiniRowIcon {
            if let icon = split.customIcon {
                SidebarGlyphView(icon: icon, fallback: splitSymbol, size: 13)
                    .foregroundStyle(glyphInk)
            } else if let first = split.tabs.first {
                SiteIconView(image: favicon(first), token: first.faviconToken, size: SidebarMetrics.iconSize, customIcon: first.customIcon)
            } else {
                SidebarGlyphView(icon: nil, fallback: splitSymbol, size: 13)
                    .foregroundStyle(glyphInk)
            }
        } top: {
            EmptyView()
        } bottom: {
            if split.customIcon == nil, !split.tabs.isEmpty {
                MiniCornerMark(systemName: splitSymbol + ".fill", shape: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .modifier(MiniRowHighlight(isSelected: isSelected, isMultiSelected: isMultiSelected, isHovering: isHovering,
                                   isDropTarget: isDropTarget))
        .help(tooltip)
        .gesture(TapGesture().onEnded(onSelect))
        .simultaneousGesture(TapGesture(count: 2).onEnded { isRenaming = true })
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .popover(isPresented: $isRenaming, arrowEdge: .trailing) {
            MiniRenameField(initial: split.displayTitle, onCommit: { text in
                isRenaming = false
                onRename(text)
            }, onCancel: { isRenaming = false })
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(split.displayTitle), split view of \(split.tabs.count) tabs\(isAudible ? ", playing audio" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var tooltip: String {
        let panes = split.tabs.map(\.displayTitle).joined(separator: "\n")
        return split.showsAsNamedRow ? "\(split.displayTitle)\n\(panes)" : panes
    }
}

/// An easel or note at mini width.
struct MiniEaselRowView<Menu: View>: View {
    let ref: SidebarEaselRef
    let title: String
    var isNote = false
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        MiniRowIcon {
            SidebarGlyphView(icon: ref.customIcon, fallback: isNote ? "note.text" : "paintpalette", size: 14)
                .foregroundStyle(chrome.secondaryText)
        } top: {
            EmptyView()
        } bottom: {
            EmptyView()
        }
        .modifier(MiniRowHighlight(isSelected: isSelected, isHovering: isHovering))
        .help(title)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A one-line rename for the rows a mini sidebar cannot rename in place.
private struct MiniRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(initial, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($focused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .padding(10)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onDisappear { finish(commit: true) }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        commit ? onCommit(text) : onCancel()
    }
}

// MARK: The list's other rows

/// The space header at mini width: the space's icon, which opens the space
/// menu. Finish setup and sync trouble are a dot on it; with more than one
/// profile, the profile's badge sits on its corner.
struct MiniSpaceHeaderView: View {
    let model: BrowserViewModel
    let space: Space
    var hasPinned = false
    var isPinnedCollapsed = false
    var onTogglePinned: () -> Void = {}
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    private var badge: Color? {
        if SyncStatusPresentation(model.syncStatus).indicator == .red { return model.syncStatusColor }
        if model.onboardingSetupState.showsCard || model.availableUpdate != nil { return .accentColor }
        return nil
    }

    var body: some View {
        let profile = model.store.profile(withID: model.store.owningProfileID(of: space.profileID))
        Menu {
            menu
        } label: {
            SpaceIconView(iconName: space.iconName, size: 15)
                .foregroundStyle(chrome.accent)
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Circle().fill(badge).frame(width: 6, height: 6).offset(x: 4, y: -3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.store.listedProfiles.count > 1, let profile {
                        ProfileAvatarView(profile: profile, diameter: 11, sidebarBadge: chrome.badge)
                            .offset(x: 6, y: 5)
                    }
                }
                // A container's space: the badge at the icon's other corner.
                .overlay(alignment: .bottomLeading) {
                    if let container = model.containerLabel(forSpace: space.id) {
                        ContainerChip(label: container, style: .badge).offset(x: -4, y: 5)
                    }
                }
                .frame(width: CGFloat(MiniSidebarLayout.highlight), height: SidebarMetrics.headerHeight)
                .background(chrome.rowHover.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        // A right-click opens the same menu, as on the full header.
        .contextMenu { menu }
        .help(model.store.container(ofSpace: space.id) == nil ? space.name : "\(space.name) · \(ContainerChip.help)")
        .accessibilityLabel("Space: \(space.name)")
        .accessibilityHint("Opens the space menu")
    }

    @ViewBuilder
    private var menu: some View {
        Text(space.name)
        if model.onboardingSetupState.showsCard {
            Button("Finish Setting Up ReArc…") { model.showBrowserImport() }
            Button("Hide Finish Setup") { model.dismissOnboardingCard() }
        }
        if model.availableUpdate != nil {
            Button(AvailableUpdate.title) { model.installUpdate?() }
        }
        if SyncStatusPresentation(model.syncStatus).indicator == .red {
            Text(model.syncStatusHelp)
        }
        Divider()
        if hasPinned {
            Button(isPinnedCollapsed ? "Expand Pinned Section" : "Collapse Pinned Section", action: onTogglePinned)
        }
        if model.store.listedProfiles.count > 1 {
            Menu("Switch to Profile") {
                ProfileMenuChoices(store: model.store, active: space.profileID) { model.selectProfile($0) }
            }
        }
        Divider()
        SpaceContextMenu(model: model, space: space)
    }
}

/// New Tab at mini width: a single +.
struct MiniNewTabRowView: View {
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        MiniRowIcon {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(chrome.secondaryText)
        } top: {
            EmptyView()
        } bottom: {
            EmptyView()
        }
        .modifier(MiniRowHighlight(isHovering: isHovering))
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .help("New Tab (⌘T)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Tab")
        .accessibilityAddTraits(.isButton)
    }
}

/// The Today divider at mini width: the line alone, as wide as the
/// favorites' divider (10 pt from each edge). Clear Unpinned Tabs is in the
/// space menu.
struct MiniTodayDivider: View {
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Rectangle()
            .fill(chrome.separator)
            .frame(height: 1)
            .padding(.horizontal, 10 - SidebarMetrics.rowInset)
            .padding(.top, 7.5)
            .frame(height: 17, alignment: .top)
    }
}

// MARK: Below the list

/// The media strips and call cards as icons above the bottom bar: the site's
/// favicon with its playing or capture state. Click plays or pauses (a call
/// goes back to its tab); the context menu has the strip's other controls.
/// The live video card returns with the full sidebar.
struct MiniMediaColumn: View {
    let model: BrowserViewModel
    @Environment(\.sidebarWindow) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let calls = model.callCards(in: window)
        let strips = model.mediaStrips(in: window).compactMap { model.mediaStripInfo(for: $0, in: window) }
        VStack(spacing: 4) {
            ForEach(calls, id: \.self) { id in
                if let tab = model.store.tab(withID: id), let capture = model.captureStateByTab[id] {
                    MiniMediaTile(favicon: model.favicon(for: tab), token: tab.faviconToken,
                                  badge: capture.isCapturingVideo ? "video.fill" : "mic.fill", badgeTint: .red,
                                  help: "\(tab.displayTitle)\nBack to Tab", action: { model.goToMediaTab(id) }) {
                        Button("Back to Tab") { model.goToMediaTab(id) }
                        if let end = model.callEndAction(for: id) {
                            Button(end.title) { model.endCall(id) }
                        }
                    }
                    .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
                }
            }
            ForEach(strips) { info in
                MiniMediaTile(favicon: info.favicon, token: info.faviconToken,
                              badge: info.isPlaying ? (info.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") : "pause.fill",
                              badgeTint: nil, help: "\(info.title)\n\(info.location)\nClick to \(info.isPlaying ? "pause" : "play")",
                              action: { model.mediaTogglePlayPause(info.id) }) {
                    Button("Back to Tab") { model.goToMediaTab(info.id) }
                    Button(info.isPlaying ? "Pause" : "Play") { model.mediaTogglePlayPause(info.id) }
                    if info.canPreviousTrack { Button("Previous Track") { model.mediaPreviousTrack(info.id) } }
                    if info.canNextTrack { Button("Next Track") { model.mediaNextTrack(info.id) } }
                    Button(info.isMuted ? "Unmute" : "Mute") { model.toggleMute(info.id) }
                    if info.offersPictureInPicture {
                        Button("Open Picture in Picture") { model.openPictureInPicture(info.id) }
                    }
                    Divider()
                    Button("Close Mini Player") { model.closeMediaStrip(info.id) }
                }
                .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, CGFloat(MiniSidebarLayout.rowInset))
        .padding(.bottom, calls.isEmpty && strips.isEmpty ? 0 : MediaStripMetrics.gap)
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: calls)
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: strips.map(\.id))
    }
}

/// One media or call icon on the strips' own card.
private struct MiniMediaTile<Menu: View>: View {
    let favicon: NSImage?
    let token: String
    let badge: String
    let badgeTint: Color?
    let help: String
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button(action: action) {
            SiteIconView(image: favicon, token: token, size: SidebarMetrics.iconSize)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: badge)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(badgeTint ?? MediaStripMetrics.glyph(dark: chrome.isDark))
                        .frame(width: 13, height: 13)
                        .background(MediaStripMetrics.fill(dark: chrome.isDark), in: Circle())
                        .offset(x: 7, y: 7)
                }
                .frame(width: CGFloat(MiniSidebarLayout.highlight), height: MediaStripMetrics.height)
                .background(MediaStripBackground())
                .overlay {
                    RoundedRectangle(cornerRadius: MediaStripMetrics.radius, style: .continuous)
                        .fill(MediaStripMetrics.hover(dark: chrome.isDark))
                        .opacity(isHovering ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .contextMenu { menu() }
        .accessibilityLabel(help.replacingOccurrences(of: "\n", with: ", "))
    }
}

/// The bottom bar at mini width, stacked: downloads while one runs, the
/// Library, the current space (click lists the spaces, scroll steps through
/// them; a swipe over the list pages them as at full width) and the + menu.
struct MiniBottomBar: View {
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Environment(\.sidebarWindow) private var window
    @Environment(\.themeChrome) private var chrome
    @State private var showingPlusMenu = false

    var body: some View {
        VStack(spacing: 6) {
            if model.downloads.activeCount > 0 || model.downloads.hasDangerous || model.downloads.isTrayPresented {
                DownloadsButton(downloads: model.downloads, isPresented: Binding(
                    get: { model.downloads.isTrayPresented && model.isKeyBrowserWindow(window) },
                    set: { model.downloads.isTrayPresented = $0 }
                ), showAll: {
                    model.downloads.isTrayPresented = false
                    model.openLibrary(.downloads, in: window)
                })
            }
            LibraryButton(isRevealed: false) { model.toggleLibrary(in: window) } onHover: { _ in }
                .frame(width: LibraryButton.chipSize, height: LibraryButton.chipSize)
                .help("View Library")
                .accessibilityLabel("Library")
            MiniSpaceSwitcher(model: model, current: model.space(in: window))
            Button { showingPlusMenu.toggle() } label: {
                Image(systemName: showingPlusMenu ? "xmark" : "plus")
                    .font(.system(size: showingPlusMenu ? 13 : 15, weight: .medium))
                    .foregroundStyle(chrome.glyph)
                    .frame(width: LibraryButton.chipSize, height: LibraryButton.chipSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Space, Folder, Easel, Boost, Split or Tab")
            .accessibilityLabel(showingPlusMenu ? "Close Menu" : "New")
            .popover(isPresented: $showingPlusMenu, arrowEdge: .trailing) {
                PlusMenuPanel(sections: plusMenu) { showingPlusMenu = false }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    /// The full bar's + menu (its Spaces and Profiles lists open from the
    /// space switcher and the space menu here).
    private var plusMenu: [[PlusMenuPanel.Row]] {
        [
            [.init("New Space", "plus.rectangle.portrait") { model.beginSpaceCreation() },
             .init("New Folder", "folder.badge.plus") { model.newFolder() }],
            [.init("New Easel", "scribble.variable", shortcut: "⌃⇧E") { _ = model.createEasel() },
             .init("New Boost", "paintbrush.pointed") { model.newBoost() }],
            [.init("New Split", "rectangle.split.2x1", shortcut: "⌃⇧=") { model.addSplitView(orientation: .horizontal) },
             .init("New Tab", "plus.square", shortcut: "⌘T") { model.newTab() }],
            [.init("New Note", "note.text") { _ = model.createEasel(title: "Note", note: true) },
             .init("Split Below", "rectangle.split.1x2") { model.addSplitView(orientation: .vertical) }],
        ]
    }
}

/// The current space as the bottom bar draws it (a coloured circle or its
/// icon). Click lists the profile's spaces; a scroll over it steps to the
/// next or previous one.
private struct MiniSpaceSwitcher: View {
    let model: BrowserViewModel
    let current: Space
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        let spaces = model.store.spaces(listedIn: current.profileID)
        Menu {
            ForEach(spaces) { space in
                Button { model.selectSpace(space.id) } label: {
                    if space.id == current.id { Label(space.name, systemImage: "checkmark") } else { Text(space.name) }
                }
            }
            Divider()
            Button("New Space…") { model.beginSpaceCreation() }
        } label: {
            icon
                .frame(width: LibraryButton.chipSize, height: LibraryButton.chipSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(MiniScrollStepper { forward in
            guard spaces.count > 1 else { return }
            model.cycleSpace(forward: forward)
        })
        .contextMenu { SpaceContextMenu(model: model, space: current) }
        .help("\(current.name) — click for spaces, scroll to switch")
        .accessibilityLabel("Space: \(current.name)")
    }

    @ViewBuilder
    private var icon: some View {
        if model.spaceIconStyle == .colouredCircles {
            let ink: Color = SpaceCircles.prefersLightInk(on: current.theme) ? .white : .black
            ZStack {
                Circle()
                    .fill(Color(current.theme))
                    .overlay { Circle().strokeBorder(ink.opacity(0.18), lineWidth: 0.5) }
                    .frame(width: SpaceCircles.diameter, height: SpaceCircles.diameter)
                SpaceIconView(iconName: current.hasIcon ? current.iconName : SpaceCircles.initial(for: current.name), size: 10)
                    .foregroundStyle(ink)
                Circle().stroke(chrome.accent, lineWidth: SpaceCircles.ringWidth)
                    .frame(width: SpaceCircles.ringDiameter, height: SpaceCircles.ringDiameter)
            }
        } else {
            SpaceIconView(iconName: current.iconName, size: 13)
                .foregroundStyle(chrome.accent)
        }
    }
}

/// Steps once per scroll gesture (or wheel notch) over its view, the way the
/// space dots answer a swipe: the step's sign follows the larger axis.
private struct MiniScrollStepper: NSViewRepresentable {
    let onStep: (_ forward: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onStep = onStep
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onStep: onStep) }

    final class Coordinator {
        var onStep: (Bool) -> Void
        weak var view: NSView?
        var monitor: Any?
        private var travel = 0.0
        private var stepped = false

        init(onStep: @escaping (Bool) -> Void) { self.onStep = onStep }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
            guard event.hasPreciseScrollingDeltas else {
                if delta != 0 { onStep(delta > 0) }
                return nil
            }
            if event.phase.contains(.began) {
                travel = 0
                stepped = false
            }
            if !event.momentumPhase.isEmpty { return nil }
            travel += Double(delta)
            if !stepped, abs(travel) >= MiniSidebarLayout.scrollStep {
                stepped = true
                onStep(travel > 0)
            }
            return nil
        }
    }
}
