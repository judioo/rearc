import SwiftUI
import SidebarModel

/// The left sidebar: favorites row, per-space pinned/today sections, and the
/// bottom bar with the space switcher. There is no traditional tab bar.
struct SidebarView: View {
    let model: BrowserViewModel
    @State private var draggedItemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ProfileAvatarView(profile: model.store.activeProfile, diameter: 20)
                    .opacity(0.85)
                    .help(model.store.activeProfile.name)
            }
            .padding(.horizontal, 12)
            .padding(.top, 36)
            .padding(.bottom, 4)

            FavoritesRowView(model: model, draggedTabID: $draggedItemID)
                .padding(.horizontal, 10)

            Divider().padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let content = model.store.content(for: model.store.activeSpaceID)
                    TabSectionView(
                        title: "Pinned",
                        section: .pinned,
                        entries: content.pinned,
                        model: model,
                        draggedItemID: $draggedItemID
                    )
                    TabSectionView(
                        title: nil,
                        section: .unpinned,
                        entries: content.today,
                        model: model,
                        draggedItemID: $draggedItemID
                    )
                }
                .padding(.horizontal, 8)
            }

            if let miniID = model.miniPlayerTabID, let tab = model.store.tab(withID: miniID) {
                let media = model.mediaState(for: miniID)
                MiniPlayerView(
                    title: media.title ?? tab.title,
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
