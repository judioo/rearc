import AppKit
import SwiftUI
import SidebarModel

/// Arc's media strip (THEMES.md §4.7): a near-white 33 pt bar inset 8 pt,
/// radius 8, with five equal cells and no track title: the site's icon
/// (goes to the tab), previous, play/pause, next and volume.
struct MiniPlayerView: View {
    let title: String
    let favicon: NSImage?
    let faviconToken: String
    let isPlaying: Bool
    let isMuted: Bool
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void
    let onToggleMute: () -> Void
    let onGoToTab: () -> Void
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: 0) {
            cell(help: "Go to \(title)", action: onGoToTab) {
                SiteIconView(image: favicon, token: faviconToken, size: 16)
            }
            // No previous-track action reaches the page yet; Arc greys it the same way.
            cell(help: "Previous", enabled: false, action: {}) {
                Image(systemName: "backward.end.fill").font(.system(size: 11))
            }
            cell(help: isPlaying ? "Pause" : "Play", action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
            }
            cell(help: "Next", action: onNext) {
                Image(systemName: "forward.end.fill").font(.system(size: 11))
            }
            cell(help: isMuted ? "Unmute" : "Mute", action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill").font(.system(size: 13))
            }
        }
        .frame(height: 33)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chrome.isDark ? Color.white.opacity(0.1) : Color(.sRGB, red: 0.992, green: 0.992, blue: 1))
                .shadow(color: .black.opacity(chrome.isDark ? 0.3 : 0.1), radius: 1, y: 1)
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .padding(.bottom, 4)
    }

    private func cell<Content: View>(help: String, enabled: Bool = true, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(white: enabled ? 0.48 : 0.82))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
