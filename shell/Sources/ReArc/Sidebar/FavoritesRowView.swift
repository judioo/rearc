import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// The top row of favorite tabs: icon-only squares, no close button,
/// drag-to-reorder within the row. Favorites are global across spaces.
struct FavoritesRowView: View {
    let model: BrowserViewModel
    @Binding var draggedTabID: Tab.ID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.store.favorites) { tab in
                    FavoriteIconView(tab: tab, isSelected: tab.id == model.store.selectedItemID)
                        .onTapGesture { model.selectTab(tab.id) }
                        .onDrag {
                            draggedTabID = tab.id
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: FavoriteDropDelegate(
                                targetTab: tab,
                                model: model,
                                draggedTabID: $draggedTabID
                            )
                        )
                }
            }
        }
    }
}

private struct FavoriteDropDelegate: DropDelegate {
    let targetTab: Tab
    let model: BrowserViewModel
    @Binding var draggedTabID: Tab.ID?

    func dropEntered(info: DropInfo) {
        guard let draggedTabID,
              draggedTabID != targetTab.id,
              model.store.kind(of: draggedTabID) == .favorite,
              let destination = model.store.favorites.firstIndex(where: { $0.id == targetTab.id })
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.store.moveTab(draggedTabID, to: destination)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let compatible = draggedTabID.flatMap { model.store.kind(of: $0) } == .favorite
        return DropProposal(operation: compatible ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }
}

private struct FavoriteIconView: View {
    let tab: Tab
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        Text(tab.faviconToken)
            .font(.system(size: 15, weight: .semibold))
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
            .help(tab.title)
            .onHover { isHovering = $0 }
    }
}
