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
    @Environment(\.colorScheme) private var colorScheme
    @State private var localPager = SpacePagerController()

    private var pager: SpacePagerController { sharedPager ?? localPager }
    private var focusedSpace: Space { model.space(in: window) }

    var body: some View {
        let spaceIDs = model.store.spaces(in: focusedSpace.profileID).map(\.id)
        let palette = SpaceThemePalette(theme: focusedSpace.theme, darkAppearance: colorScheme == .dark)
        VStack(spacing: 0) {
            SidebarToolbarView(model: model)
                .padding(.bottom, 8)

            FavoritesRowView(model: model, draggedTabID: $draggedItemID, dropState: $dropState)
                .padding(.horizontal, 10)

            Divider().padding(.vertical, 8)

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

            if let miniID = model.miniPlayerTabID, let tab = model.store.tab(withID: miniID) {
                let media = model.mediaState(for: miniID)
                MiniPlayerView(
                    title: media.title ?? tab.displayTitle,
                    artist: media.artist,
                    isPlaying: media.isPlaying,
                    onTogglePlayPause: { model.miniPlayerTogglePlayPause() },
                    onNext: { model.miniPlayerNextTrack() },
                    onGoToTab: { model.goToMiniPlayerTab() }
                )
            }

            Divider()
            BottomBarView(model: model, draggedItemID: $draggedItemID)
        }
        .frame(width: model.sidebarWidth)
        .frame(maxHeight: .infinity)
        // The sidebar sits on the window's theme background; text follows its brightness.
        .environment(\.colorScheme, palette.prefersLightForeground ? .dark : .light)
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

    /// One space's page: header, pinned, Today and the New Tab row.
    private func spacePage(_ spaceID: Space.ID) -> some View {
        let space = model.store.space(withID: spaceID) ?? focusedSpace
        let content = model.store.content(for: space.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SpaceHeaderView(model: model, space: space, theme: Color(space.theme))
                TabSectionView(
                    title: nil,
                    section: .pinned,
                    spaceID: space.id,
                    entries: content.pinned,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                )
                TodayHeaderView(model: model, spaceID: space.id, hasTabs: !content.today.isEmpty)
                TabSectionView(
                    title: nil,
                    section: .unpinned,
                    spaceID: space.id,
                    entries: content.today,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                )
                NewTabRowView { model.newTab() }
            }
            .padding(.horizontal, 8)
        }
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
    let theme: Color

    var body: some View {
        HStack(spacing: 6) {
            SpaceIconView(iconName: space.iconName, size: 11)
                .foregroundStyle(theme)
                .frame(width: 16)
            Text(space.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                SpaceContextMenu(model: model, space: space)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Space options")
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.beginRename(.space(space.id)) }
        .contextMenu { SpaceContextMenu(model: model, space: space) }
    }
}

/// The divider above Today with Arc's Clear action (`UnpinnedSectionDividerCellView`,
/// menu Clear Unpinned Tabs); after a clear it offers Undo.
private struct TodayHeaderView: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    let hasTabs: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            if !model.lastClearedTabIDs.isEmpty, !hasTabs {
                Button("Undo Clear") { model.undoClearTodayTabs() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Put the cleared tabs back")
            } else if hasTabs {
                Button {
                    if model.store.activeSpaceID != spaceID { model.selectSpace(spaceID) }
                    model.clearTodayTabs()
                } label: {
                    Label("Clear", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Unpinned Tabs: archive every Today tab in this space")
                .onHover { isHovering = $0 }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 16)
    }
}

/// Arc's persistent "+ New Tab" cell at the end of Today (`NewTabCellView`).
private struct NewTabRowView: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
            Text("New Tab")
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(isHovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .help("New Tab (⌘T)")
    }
}
