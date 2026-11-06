import AppKit
import SwiftUI
import SidebarModel

/// The left sidebar: navigation controls and URL field, the favorites row,
/// the space header, per-space pinned (with folders) and today sections, and
/// the bottom bar with the space switcher. There is no traditional tab bar.
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
        let spaceIDs = model.store.spaces(in: focusedSpace.profileID).map(\.id)
        let hasFavorites = !model.store.favorites(in: focusedSpace.profileID).isEmpty
        VStack(spacing: 0) {
            SidebarToolbarView(model: model, urlInToolbar: urlInToolbar)

            // Arc shows no favorites row, and no divider, until there are favorites.
            if hasFavorites || draggedItemID != nil {
                FavoritesRowView(model: model, draggedTabID: $draggedItemID, dropState: $dropState)
                    .padding(.horizontal, SidebarMetrics.rowInset)
                if hasFavorites {
                    SidebarDivider().padding(.vertical, 8)
                }
            }

            SpacePagesView(pager: pager, focusedSpaceID: focusedSpace.id) { spaceID in
                spacePage(spaceID)
            }
            .background(
                SidebarSwipeMonitor(
                    isEnabled: draggedItemID == nil,
                    onBegin: { pager.beginSwipe() },
                    onChange: { pager.swipe(byPoints: $0, pageWidth: Double(model.sidebarWidth)) },
                    onEnd: {
                        if let id = pager.endSwipe(), id != model.space(in: window).id {
                            model.selectSpace(id)
                        }
                    },
                    onCancel: { pager.cancelSwipe() }
                )
            )

            // Arc's media strips (and ReArc's live video) sit above the bottom bar.
            MediaControlsStackView(model: model)

            BottomBarView(model: model, draggedItemID: $draggedItemID)
        }
        .frame(width: model.sidebarWidth)
        .frame(maxHeight: .infinity)
        // The sidebar has no panel: it sits on the window's theme, and its
        // text is the theme's own title tint in the space's appearance.
        .foregroundStyle(chrome.title)
        .environment(\.colorScheme, chrome.isDark ? .dark : .light)
        .overlay(alignment: .trailing) { SidebarResizeHandle(model: model) }
        .onAppear { pager.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, value in pager.reduceMotion = value }
        .onChange(of: spaceIDs, initial: true) { _, ids in
            pager.sync(spaceIDs: ids, focused: focusedSpace.id, animated: false)
        }
        .onChange(of: focusedSpace.id) { _, id in
            pager.sync(spaceIDs: spaceIDs, focused: id, animated: true)
        }
    }

    private func spacePage(_ spaceID: Space.ID) -> some View {
        SidebarSpacePage(model: model, spaceID: spaceID, draggedItemID: $draggedItemID, dropState: $dropState,
                         draggedID: draggedItemID, drop: dropState)
            .equatable()
    }
}

/// Offset changes belong to SpacePagesView. A frame of the pager does not
/// rebuild an unchanged outline. The list runs in its own hosting view
/// (`SidebarListHost`): a scroll step, or a change one of its rows
/// observes, updates and lays out only the list, not the window.
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
        SidebarListHost(tint: model.themeColor(in: window)) {
            SidebarSpaceList(model: model, spaceID: spaceID, draggedItemID: $draggedItemID, dropState: $dropState)
        }
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

/// One space's scrolling outline: header, pinned, Today. It observes its
/// own space, outline and rows inside the list's hosting view.
private struct SidebarSpaceList: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let space = model.store.space(withID: spaceID) ?? model.space(in: window)
        let outline = model.store.outline(for: space.id)
        let collapsed = model.isPinnedSectionCollapsed(spaceID: space.id, in: window)
        let pinned = collapsed ? collapsedPinned(outline.pinned, spaceID: space.id) : outline.pinned
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SpaceHeaderView(
                    model: model,
                    space: space,
                    hasPinned: !outline.pinned.isEmpty,
                    isPinnedCollapsed: collapsed,
                    onTogglePinned: { model.togglePinnedSection(spaceID: space.id, in: window) }
                )
                .padding(.bottom, SidebarMetrics.headerToFirstRow)
                TabSectionView(
                    title: nil,
                    section: .pinned,
                    spaceID: space.id,
                    nodes: pinned,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                )
                TodayHeaderView(model: model, spaceID: space.id, hasTabs: !outline.today.isEmpty)
                // Arc's "+ New Tab" heads Today, right under the divider.
                NewTabRowView { model.newTab() }
                TabSectionView(
                    title: nil,
                    section: .unpinned,
                    spaceID: space.id,
                    nodes: outline.today,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                )
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
        }
    }

    /// A collapsed Pinned section keeps only its selected item
    /// (`PinnedSectionCollapseState.visibleEntries`).
    private func collapsedPinned(_ nodes: [SidebarOutlineNode], spaceID: Space.ID) -> [SidebarOutlineNode] {
        let leaves = SidebarOutlineNode.leaves(nodes)
        guard let selected = model.store.selection(among: leaves.map(\.id), inSpace: spaceID) else { return [] }
        return leaves.filter { $0.id == selected }
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

/// The trailing-edge drag handle that resizes the sidebar (Arc `SidebarResizeState`).
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
                        model.sidebarWidth = CGFloat(SidebarWidth.clamped(Double(start + value.translation.width)))
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
private struct SpaceHeaderView: View {
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
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chrome.secondaryText)
                .lineLimit(1)
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
            if let profile = model.store.profile(withID: space.profileID) {
                ProfileAvatarView(profile: profile, diameter: 16)
                    .help("Profile: \(profile.name)")
                    .accessibilityLabel("Profile: \(profile.name)")
                    .padding(.trailing, 6)
            }
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
        }
        .frame(height: SidebarMetrics.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.beginRename(.space(space.id)) }
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
private struct TodayHeaderView: View {
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
/// a 12 pt plus and faded 14 pt text on the row pitch.
private struct NewTabRowView: View {
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
                .foregroundStyle(chrome.tertiaryText)
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
