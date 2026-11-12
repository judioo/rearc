import AppKit
import SwiftUI
import SidebarModel

/// The sidebar (left, or right by Settings): navigation controls and URL field, the favorites row,
/// the space header, per-space pinned (with folders) and today sections, and
/// the bottom bar with the space switcher. There is no traditional tab bar.
/// In the Library the window's sidebar is the Library (`LibraryView`),
/// drawn over the sidebar it hides: the list's table stays as it was, so
/// leaving the Library shows it again without rebuilding it.
struct SidebarView: View {
    let model: BrowserViewModel
    @Environment(\.sidebarWindow) private var window
    @Binding var draggedItemID: UUID?
    @State private var dropState: SidebarDropState?
    @Environment(\.spacePager) private var sharedPager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localPager = SpacePagerController()
    @Environment(\.themeChrome) private var chrome
    @AppStorage(ToolbarURLPreference.key) private var urlInToolbar = ToolbarURLPreference.defaultValue

    private var pager: SpacePagerController { sharedPager ?? localPager }
    private var focusedSpace: Space { model.space(in: window) }

    var body: some View {
        let section = model.librarySection(in: window)
        ZStack(alignment: .topLeading) {
            spaces
                .opacity(section == nil ? 1 : 0)
                .allowsHitTesting(section == nil)
                .accessibilityHidden(section != nil)
                .environment(\.sidebarCoveredByLibrary, section != nil)
            if let section {
                LibraryView(model: model, window: window, section: section, draggedItemID: $draggedItemID)
                    .frame(width: model.sidebarWidth(in: window))
            }
        }
        .frame(width: model.sidebarWidth(in: window), alignment: .leading)
        .frame(maxHeight: .infinity)
        // The sidebar has no panel: it sits on the window's theme, and its
        // text is the theme's own title tint in the space's appearance.
        .foregroundStyle(chrome.title)
        .environment(\.colorScheme, chrome.isDark ? .dark : .light)
    }

    /// Create a Space shows as a page after the profile's last space.
    private var focusedPageID: Space.ID {
        model.isCreatingSpace(in: window) ? SpaceCreationSession.pageID : focusedSpace.id
    }

    private var spaces: some View {
        let spaceIDs = model.store.spaces(in: focusedSpace.profileID).map(\.id)
        let pages = PagerPages(
            ids: model.isCreatingSpace(in: window) ? SpaceCreationSession.pages(spaces: spaceIDs) : spaceIDs,
            focused: focusedPageID
        )
        let hasFavorites = !model.store.favorites(in: focusedSpace.profileID).isEmpty
        let mini = model.isMiniSidebar(in: window)
        let width = model.sidebarListWidth(in: window)
        return VStack(spacing: 0) {
            if mini {
                // The traffic lights' row; they sit over it and the card's strip.
                // Under them, the shown page's container, as the full toolbar's URL field has it.
                Color.clear.frame(height: SidebarToolbarView.rowHeight)
                    .overlay(alignment: .bottom) {
                        if let container = model.containerLabel(for: model.focusedEngine(in: window), tab: model.selectedTab(in: window)) {
                            ContainerChip(label: container, style: .compact, maxWidth: CGFloat(MiniSidebarLayout.highlight) + 8)
                                .padding(.bottom, 1)
                        }
                    }
            } else {
                SidebarToolbarView(model: model, urlInToolbar: urlInToolbar)
            }

            // A swipe over the favorites pages the spaces under them too.
            VStack(spacing: 0) {
                // Arc shows no favorites row, and no divider, until there are favorites.
                if hasFavorites || draggedItemID != nil {
                    FavoritesRowView(model: model, draggedTabID: $draggedItemID, dropState: $dropState)
                        .padding(.horizontal, SidebarMetrics.rowInset)
                    if hasFavorites {
                        SidebarDivider().padding(.vertical, 8)
                    }
                }

                SpacePagesView(pager: pager, focusedSpaceID: pages.focused) { spaceID in
                    spacePage(spaceID)
                }
            }
            .background(
                SidebarSwipeMonitor(
                    // Not under a drag, the Library, nor the command bar or tab switcher's scrim.
                    isEnabled: { [model, window, binding = $draggedItemID] in
                        binding.wrappedValue == nil && !model.isCommandBarPresented && model.tabSwitcher == nil
                            && model.librarySection(in: window) == nil
                    },
                    onBegin: { pager.beginSwipe() },
                    onChange: { pager.swipe(byPoints: $0, pageWidth: Double(width)) },
                    onEnd: { swipeLanded(on: pager.endSwipe()) },
                    onCancel: { pager.cancelSwipe() }
                )
            )

            if mini {
                // Media as icons, then the bar's buttons stacked; the Finish
                // setup card is a badge on the space icon (`MiniSpaceHeaderView`).
                MiniMediaColumn(model: model)
                MiniBottomBar(model: model, draggedItemID: $draggedItemID)
            } else {
                // Arc's media strips (and ReArc's live video) sit above the bottom bar.
                MediaControlsStackView(model: model)

                // Deferred onboarding's invitation, in the strips' insets and gap.
                if model.onboardingSetupState.showsCard {
                    FinishSetupCard(model: model)
                        .padding(.horizontal, MediaStripMetrics.inset)
                        .padding(.bottom, MediaStripMetrics.gap)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }

                BottomBarView(model: model, draggedItemID: $draggedItemID)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.onboardingSetupState)
        .environment(\.isMiniSidebar, mini)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: Alignment(horizontal: model.sidebarPlacement.resizeHandleEdge.horizontalAlignment, vertical: .center)) {
            // The mini column has a fixed width.
            if !mini { SidebarResizeHandle(model: model) }
        }
        .onAppear { pager.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in pager.reduceMotion = value }
        // A new space list snaps; a new focus springs, or fades to and from
        // Create a Space's page.
        .onChange(of: pages, initial: true) { old, new in
            let creationSwap = old.focused != new.focused
                && (old.focused == SpaceCreationSession.pageID || new.focused == SpaceCreationSession.pageID)
            pager.sync(spaceIDs: new.ids, focused: new.focused, animated: true,
                       fade: creationSwap ? SpaceCreationSession.fadeDuration(opening: model.spaceCreation?.origin) : nil)
        }
    }

    /// A swipe let go. A full pull past the last space opens Create a Space;
    /// a swipe from its page onto a space closes it once the page rests.
    private func swipeLanded(on id: Space.ID?) {
        guard let id else { return }
        let creating = model.isCreatingSpace(in: window)
        if id == SpaceCreationSession.pageID {
            if !creating { model.beginSpaceCreation(in: window, origin: .overscroll) }
            return
        }
        if id != model.space(in: window).id { model.selectSpace(id) }
        guard creating else { return }
        pager.whenSettled { [model, pager] in
            if !pager.restsOnCreationPage { model.spaceCreation = nil }
        }
    }

    /// A neighbouring space slides in with its own theme's text colours. The
    /// modifiers are the same for every page, so a page that becomes the
    /// focused one keeps its table.
    private func spacePage(_ spaceID: Space.ID) -> some View {
        let colors = pageChrome(spaceID)
        return Group {
            if spaceID == SpaceCreationSession.pageID {
                SpaceCreationPage(model: model)
            } else {
                SidebarSpacePage(model: model, spaceID: spaceID, draggedItemID: $draggedItemID, dropState: $dropState,
                                 draggedID: draggedItemID, drop: dropState)
                    .equatable()
            }
        }
        .environment(\.themeChrome, colors)
        .environment(\.colorScheme, colors.isDark ? .dark : .light)
        .foregroundStyle(colors.title)
    }

    private func pageChrome(_ spaceID: Space.ID) -> ThemeChromeColors {
        guard spaceID != focusedPageID, let theme = model.pageTheme(spaceID) else { return chrome }
        let dark = theme.appearance.isDark(systemDark: SystemAppearance.isSystemDark)
        return model.themeColors.colors(for: spaceID, theme: theme, dark: dark)
    }
}

/// The pager's pages and the one in front.
private struct PagerPages: Equatable {
    var ids: [Space.ID]
    var focused: Space.ID
}

/// Offset changes belong to SpacePagesView. A frame of the pager does not
/// rebuild an unchanged outline. The list is an AppKit table of reused
/// hosting cells (`SidebarListTable`): a scroll step moves rows, and a
/// change one row observes updates that row's cell only.
private struct SidebarSpacePage: View, Equatable {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?
    @Environment(\.sidebarWindow) private var window
    let draggedID: UUID?
    let drop: SidebarDropState?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.spaceID == rhs.spaceID
            && lhs.draggedID == rhs.draggedID && lhs.drop == rhs.drop
    }

    var body: some View {
        let showsThemeEditor = model.themePopoverSpaceID == spaceID && model.isKeyBrowserWindow(window)
        SidebarListTable(model: model, spaceID: spaceID, tint: model.themeColor(in: window),
                         draggedItemID: $draggedItemID, dropState: $dropState)
        // Edit Theme Color hangs the editor under the header
        // (ARC-RECORDING-ANALYSIS.md §2.1). It is presented from here, over
        // the header's slot: a popover did not open from the list's own
        // hosting view.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: SidebarMetrics.headerHeight)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .allowsHitTesting(false)
                .popover(isPresented: Binding(
                    get: { showsThemeEditor },
                    set: { if !$0 { model.themePopoverSpaceID = nil } }
                ), arrowEdge: .bottom) {
                    SpaceStyleEditor(theme: Binding(
                        get: { model.store.space(withID: spaceID)?.theme ?? .default },
                        set: { model.store.setSpaceTheme(spaceID, theme: $0) }
                    ))
                }
        }
    }
}

/// Measured sidebar geometry (THEMES.md §4.6), in points from the sidebar's
/// left edge: rows are drawn 8 pt in from each side, icons start at 18 and
/// text at 45, and rows sit on a 41 pt pitch.
enum SidebarMetrics {
    /// Arc's stored sidebar width.
    static let width: CGFloat = 228
    /// Row highlight inset from the sidebar's edges.
    static let rowInset: CGFloat = 8
    /// Icon start inside a row (18 − 8).
    static let iconLeading: CGFloat = 10
    static let iconSize: CGFloat = 16
    /// Icon to title (45 − 18 − 16).
    static let iconToText: CGFloat = 11
    static let rowPitch: CGFloat = 41
    /// The highlight's height inside the pitch (unobserved; §8).
    static let rowHeight: CGFloat = 36
    static let titleSize: CGFloat = 14
    static let subtitleSize: CGFloat = 11
    /// Header centre to the first row's centre is 42; header rows are 28 tall.
    static let headerHeight: CGFloat = 28
    static let headerToFirstRow: CGFloat = 42 - 14 - 20.5
}

/// A 1 pt separator in the theme's separator tint, inset 18 pt from each
/// sidebar edge (10 inside the row inset).
struct SidebarDivider: View {
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Rectangle()
            .fill(chrome.separator)
            .frame(height: 1)
            .padding(.horizontal, 18 - SidebarMetrics.rowInset)
    }
}

/// The drag handle on the sidebar's inner edge that resizes it (Arc `SidebarResizeState`).
private struct SidebarResizeHandle: View {
    let model: BrowserViewModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? model.sidebarWidth
                        startWidth = start
                        model.sidebarWidth = CGFloat(model.sidebarPlacement.resizedWidth(start: Double(start),
                                                                                         translation: Double(value.translation.width)))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        SidebarWidth.save(Double(model.sidebarWidth))
                    }
            )
            .help("Drag to resize the sidebar")
    }
}

/// Current space identity above the pinned section, with the space menu
/// (Arc `spaceHeader` / `spaceHeaderContextMenu`). Double-click renames.
struct SpaceHeaderView: View {
    let model: BrowserViewModel
    let space: Space
    var hasPinned = false
    var isPinnedCollapsed = false
    var onTogglePinned: () -> Void = {}
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        // Arc: an 18 pt icon at x 17, the name in 13 pt semibold grey at x 45.
        HStack(spacing: 0) {
            SpaceIconView(iconName: space.iconName, size: 15)
                .foregroundStyle(chrome.accent)
                .frame(width: 18, height: 18)
                .padding(.leading, SidebarMetrics.iconLeading - 1)
                .padding(.trailing, SidebarMetrics.iconToText - 1)
            Group {
                if let rename = SidebarRowRename(row: space.id, model: model) {
                    rename.field(weight: .semibold)
                } else {
                    Text(space.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(chrome.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, 4)
            // Arc's pinned-section toggle: shown on hover, and always while collapsed.
            if hasPinned, isHovering || isPinnedCollapsed {
                Button(action: onTogglePinned) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(chrome.secondaryText)
                        .rotationEffect(.degrees(isPinnedCollapsed ? 0 : 90))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPinnedCollapsed ? "Expand Pinned Section" : "Collapse Pinned Section")
                .accessibilityLabel(isPinnedCollapsed ? "Expand Pinned Section" : "Collapse Pinned Section")
            }
            Spacer(minLength: 0)
            // Before the avatar, so the avatar keeps its place when the pointer comes over the header.
            if isHovering {
                Menu {
                    SpaceContextMenu(model: model, space: space)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chrome.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 8)
                .help("Space options")
            }
            if let profile = model.store.profile(withID: space.profileID) {
                Menu {
                    SpaceProfileChoices(model: model, space: space, heading: "Switch Space to Profile")
                } label: {
                    ProfileAvatarView(profile: profile, diameter: 18, sidebarBadge: chrome.badge)
                }
                    // A plain button draws the badge as is (the borderless style dims it).
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Profile: \(profile.name) — switch this space to another profile")
                    .accessibilityLabel("Profile: \(profile.name)")
                    .padding(.trailing, 6)
            }
        }
        .frame(height: SidebarMetrics.headerHeight)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.beginRename(.space(space.id)) },
                 including: model.inlineRename(forRow: space.id) == nil ? .all : .subviews)
        .onHover { isHovering = $0 }
        .contextMenu {
            if hasPinned {
                Button(isPinnedCollapsed ? "Expand Pinned Section" : "Collapse Pinned Section", action: onTogglePinned)
                Divider()
            }
            SpaceContextMenu(model: model, space: space)
        }
    }
}

/// The divider above Today with Arc's Clear action (`UnpinnedSectionDividerCellView`,
/// menu Clear Unpinned Tabs); after a clear it offers Undo.
struct TodayHeaderView: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    let hasTabs: Bool
    @State private var isHovering = false
    @State private var isHoveringClear = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        // Arc (§4.6): the line is 7.5 pt under the last pinned row's
        // highlight pitch and 8.5 pt above New Tab's, so the row centres sit
        // 29 and 30 pt from it.
        ZStack(alignment: .top) {
            SidebarDivider()
                .padding(.top, 7.5)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if !model.lastClearedTabIDs.isEmpty, !hasTabs {
                    Button("Undo Clear") { model.undoClearTodayTabs() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(chrome.secondaryText)
                        .padding(.horizontal, 6)
                        .background(Color.clear)
                        .help("Put the cleared tabs back")
                } else if hasTabs, isHovering {
                    Button {
                        if model.store.activeSpaceID != spaceID { model.selectSpace(spaceID) }
                        model.clearTodayTabs()
                    } label: {
                        Label("Clear", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(isHoveringClear ? chrome.title : chrome.secondaryText)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .help("Clear Unpinned Tabs: archive every Today tab in this space")
                    .onHover { isHoveringClear = $0 }
                }
            }
            .frame(height: 17)
        }
        .frame(height: 17)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// Arc's persistent "+ New Tab" cell at the head of Today (`NewTabCellView`):
/// a 12 pt plus and readable secondary text on the row pitch.
struct NewTabRowView: View {
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: SidebarMetrics.iconToText) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(chrome.secondaryText)
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            Text("New Tab")
                .font(.system(size: SidebarMetrics.titleSize))
                .foregroundStyle(chrome.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.iconLeading)
        .frame(height: SidebarMetrics.rowHeight)
        .background(chrome.rowHover.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .help("New Tab (⌘T)")
    }
}
