import SwiftUI
import SidebarModel

struct MiniPlayerView: View {
    let title: String
    let artist: String?
    let isPlaying: Bool
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void
    let onGoToTab: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            Button("Go to Tab", action: onGoToTab)
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
