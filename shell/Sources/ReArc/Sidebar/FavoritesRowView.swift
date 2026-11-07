import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// The grid of favorite tabs: icon-only squares, no close button. They
/// belong to the active profile and show in all its spaces. Drag to reorder,
/// drag a sidebar tab in to favorite it, drag a favorite into a section to
/// unfavorite it.
struct FavoritesRowView: View {
    let model: BrowserViewModel
    @Binding var draggedTabID: UUID?
    @Binding var dropState: SidebarDropState?
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        // The favorites of this window's space's profile.
        let profileID = model.space(in: window).profileID
        let favorites = model.store.favorites(in: profileID)
        let selectedID = model.selectedItemID(in: window)
        let layout = FavoritesGridLayout(itemCount: favorites.count,
                                         availableWidth: Double(model.sidebarWidth - 2 * SidebarMetrics.rowInset))
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: FavoritesGridLayout.spacing),
                                     count: layout.columns), spacing: FavoritesGridLayout.spacing) {
                ForEach(favorites) { tab in
                    FavoriteIconView(
                        model: model,
                        tab: tab,
                        favicon: model.favicon(for: tab),
                        isSelected: tab.id == selectedID,
                        isUnloaded: model.isTabUnloaded(tab.id),
                        isInPictureInPicture: model.isPictureInPicture(tab.id),
                        activity: model.tabActivity(tab.id),
                        insertion: insertion(for: tab.id),
                        width: layout.tileWidth
                    )
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .modifier(ItemIconPopover(model: model, itemID: tab.id))
                    .onDrag {
                        draggedTabID = tab.id
                        SidebarDropHaptics.dragBegan()
                        return SidebarDragPayload.itemProvider(for: tab.id)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: FavoriteDropDelegate(
                            targetTab: tab,
                            tileWidth: layout.tileWidth,
                            model: model,
                            draggedTabID: $draggedTabID,
                            dropState: $dropState
                        )
                    )
                }
            }
            if draggedTabID != nil {
                SectionEndDropZone(
                    destination: .favorites(profileID),
                    placeholder: favorites.isEmpty && draggedTabID.flatMap({ model.store.entry(withID: $0) }).map(isPlainTab) == true
                        ? "Drop here to add to Favorites" : nil,
                    model: model,
                    draggedItemID: $draggedTabID,
                    dropState: $dropState
                )
                .frame(minHeight: favorites.isEmpty ? 34 : 18)
            }
        }
        .onDrop(of: SidebarURLDropLoader.acceptedTypes, delegate: FavoriteAreaDropDelegate(
            model: model, profileID: profileID, draggedTabID: $draggedTabID, dropState: $dropState
        ))
    }

    private func isPlainTab(_ entry: SidebarEntry) -> Bool {
        if case .tab = entry { return true }
        return false
    }

    private func insertion(for id: Tab.ID) -> SidebarDropPosition? {
        guard let dropState, dropState.targetID == id else { return nil }
        return dropState.position
    }
}

private struct FavoriteAreaDropDelegate: DropDelegate {
    let model: BrowserViewModel
    let profileID: Profile.ID
    @Binding var draggedTabID: UUID?
    @Binding var dropState: SidebarDropState?

    func validateDrop(info: DropInfo) -> Bool {
        if let draggedTabID {
            guard case .tab = model.store.entry(withID: draggedTabID) else { return false }
            return true
        }
        return SidebarURLDropLoader.hasLinks(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? (draggedTabID == nil ? .copy : .move) : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        defer { draggedTabID = nil; dropState = nil }
        if let draggedTabID {
            let count = model.store.favorites(in: profileID).filter { $0.id != draggedTabID }.count
            model.moveItem(draggedTabID, to: .favorites(profileID), index: count)
            return true
        }
        return SidebarURLDropLoader.load(info) { urls in
            model.openDroppedURLs(urls, appendingTo: .favorites(profileID))
        }
    }
}

private struct FavoriteDropDelegate: DropDelegate {
    let targetTab: Tab
    let tileWidth: CGFloat
    let model: BrowserViewModel
    @Binding var draggedTabID: UUID?
    @Binding var dropState: SidebarDropState?

    /// Only plain tabs can become favorites (SidebarStore.moveItem rules).
    private func accepts() -> Bool {
        guard let draggedTabID, draggedTabID != targetTab.id,
              case .tab = model.store.entry(withID: draggedTabID) else { return false }
        return true
    }

    private func position(_ info: DropInfo) -> SidebarDropPosition {
        info.location.x < tileWidth / 2 ? .before : .after
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts() else { return DropProposal(operation: .forbidden) }
        let state = SidebarDropState(targetID: targetTab.id, position: position(info))
        if dropState != state { dropState = state }
        SidebarDropHaptics.positionChanged(to: state)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropState?.targetID == targetTab.id { dropState = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabID = nil
            dropState = nil
        }
        guard accepts(), let draggedTabID else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.moveItem(draggedTabID, relativeTo: targetTab.id, after: position(info) == .after)
        }
        SidebarDropHaptics.dropped(moved: true)
        return true
    }
}

private struct FavoriteIconView: View {
    let model: BrowserViewModel
    let tab: Tab
    let favicon: NSImage?
    let isSelected: Bool
    var isUnloaded = false
    var isInPictureInPicture = false
    var activity: TabActivity = .idle
    let insertion: SidebarDropPosition?
    var width: CGFloat = 34
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 3) {
            tile
                .onTapGesture { model.selectTab(tab.id) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.beginRename(.tab(tab.id)) })
            if let rename = SidebarRowRename(row: tab.id, model: model) {
                rename.field().frame(width: width, height: 22)
            }
        }
    }

    private var tile: some View {
        TabActivityIcon(activity: activity) {
            SiteIconView(image: favicon, token: tab.faviconToken, size: favicon == nil ? 22 : 18, customIcon: tab.customIcon)
                .saturation(isUnloaded ? 0 : 1)
                .opacity(isUnloaded ? 0.4 : 1)
        }
            .frame(width: width, height: FavoritesGridLayout.tileHeight)
            .background(
                isSelected
                    ? Color.primary.opacity(0.16)
                    : Color.primary.opacity(isHovering ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(alignment: .topTrailing) {
                if tab.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isInPictureInPicture {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 8, weight: .bold))
                        .padding(2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: 2, y: 2)
                        .help("Playing in Picture in Picture")
                        .accessibilityLabel("Picture in Picture")
                }
            }
            .overlay(alignment: insertion == .before ? .leading : .trailing) {
                if insertion != nil {
                    Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, 4)
                        .offset(x: insertion == .before ? -4 : 4)
                }
            }
            .help(tab.displayTitle)
            .onHover { isHovering = $0 }
    }
}
