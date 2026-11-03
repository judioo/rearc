import SwiftUI
import SidebarModel

/// The left sidebar: navigation controls and URL field, the favorites row,
/// the space header, per-space pinned (with folders) and today sections, and
/// the bottom bar with the space switcher. There is no traditional tab bar.
struct SidebarView: View {
    let model: BrowserViewModel
    @State private var draggedItemID: UUID?
    @State private var dropState: SidebarDropState?

    var body: some View {
        VStack(spacing: 0) {
            SidebarToolbarView(model: model)
                .padding(.bottom, 8)

            FavoritesRowView(model: model, draggedTabID: $draggedItemID, dropState: $dropState)
                .padding(.horizontal, 10)

            Divider().padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let space = model.store.activeSpace
                    let content = model.store.content(for: space.id)
                    SpaceHeaderView(model: model, space: space)
                    TabSectionView(
                        title: nil,
                        section: .pinned,
                        spaceID: space.id,
                        entries: content.pinned,
                        model: model,
                        draggedItemID: $draggedItemID,
                        dropState: $dropState
                    )
                    Divider().padding(.horizontal, 8)
                    TabSectionView(
                        title: nil,
                        section: .unpinned,
                        spaceID: space.id,
                        entries: content.today,
                        model: model,
                        draggedItemID: $draggedItemID,
                        dropState: $dropState
                    )
                }
                .padding(.horizontal, 8)
            }

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
            BottomBarView(model: model)
        }
        .frame(width: 244)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

/// Current space identity above the pinned section, with the space menu
/// (Arc `spaceHeader` / `spaceHeaderContextMenu`). Double-click renames.
private struct SpaceHeaderView: View {
    let model: BrowserViewModel
    let space: Space

    var body: some View {
        HStack(spacing: 6) {
            SpaceIconView(iconName: space.iconName, size: 11)
                .foregroundStyle(model.themeColor)
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
