import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// The top row of favorite tabs: icon-only squares, no close button. They
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(favorites) { tab in
                    FavoriteIconView(
                        tab: tab,
                        favicon: model.favicon(for: tab),
                        isSelected: tab.id == selectedID,
                        insertion: insertion(for: tab.id)
                    )
                    .onTapGesture { model.selectTab(tab.id) }
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .onDrag {
                        draggedTabID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: FavoriteDropDelegate(
                            targetTab: tab,
                            model: model,
                            draggedTabID: $draggedTabID,
                            dropState: $dropState
                        )
                    )
                }
                if favorites.isEmpty, draggedTabID.flatMap({ model.store.entry(withID: $0) }).map(isPlainTab) == true {
                    Text("Drop here to add to Favorites")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(.secondary.opacity(0.6))
                        )
                }
                SectionEndDropZone(
                    destination: .favorites(profileID),
                    placeholder: nil,
                    model: model,
                    draggedItemID: $draggedTabID,
                    dropState: $dropState
                )
                .frame(minWidth: 24, minHeight: 34)
            }
        }
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

private struct FavoriteDropDelegate: DropDelegate {
    let targetTab: Tab
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
        info.location.x < 17 ? .before : .after
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts() else { return DropProposal(operation: .forbidden) }
        let state = SidebarDropState(targetID: targetTab.id, position: position(info))
        if dropState != state { dropState = state }
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
        return true
    }
}

private struct FavoriteIconView: View {
    let tab: Tab
    let favicon: NSImage?
    let isSelected: Bool
    let insertion: SidebarDropPosition?
    @State private var isHovering = false

    var body: some View {
        SiteIconView(image: favicon, token: tab.faviconToken, size: favicon == nil ? 22 : 18)
            .frame(width: 34, height: 34)
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
