import AppKit
import SwiftUI
import SidebarModel

/// What one media strip shows, read from the model for its source tab.
struct MediaStripInfo: Identifiable {
    let id: Tab.ID
    let title: String
    let site: String
    let favicon: NSImage?
    let faviconToken: String
    let isPlaying: Bool
    let isMuted: Bool
    let canPreviousTrack: Bool
    let canNextTrack: Bool
    /// "Open Picture in Picture": the panel was minimized, or the video can enter PiP.
    let offersPictureInPicture: Bool
}

/// Arc's media strip tokens (MINI-PLAYER.md §2.1).
enum MediaStripMetrics {
    static let height: CGFloat = 33
    static let radius: CGFloat = 8
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8

    /// #FDFDFF in light mode; an opaque elevated grey in dark mode (Arc's is palette-driven, [RA]).
    static func fill(dark: Bool) -> Color {
        dark ? Color(.sRGB, red: 0.17, green: 0.17, blue: 0.19) : Color(.sRGB, red: 0.992, green: 0.992, blue: 1)
    }

    /// `PlaybackControlForeground`: black at 50%, white at 66% in dark mode; disabled at about 35% of that.
    static func glyph(dark: Bool, enabled: Bool = true) -> Color {
        let base = dark ? Color.white.opacity(0.66) : Color.black.opacity(0.5)
        return enabled ? base : (dark ? Color.white.opacity(0.66 * 0.35) : Color.black.opacity(0.5 * 0.35))
    }

    static func hover(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
    }
}

/// The strips and the live video card at the bottom of the sidebar: the
/// sidebar's live video (when its placement is the sidebar) above a stack of
/// strips for the other sources, pinned above the bottom bar with Arc's 8 pt
/// insets and gaps.
struct MediaControlsStackView: View {
    let model: BrowserViewModel
    @Environment(\.sidebarWindow) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = model.sidebarLiveVideoTabID(in: window)
        let strips = model.mediaStrips(in: window).filter { $0 != live }
        VStack(spacing: MediaStripMetrics.gap) {
            if let live, let info = model.mediaStripInfo(for: live) {
                LivePlayerCard(model: model, info: info)
                    .transition(cardTransition)
            }
            if !strips.isEmpty {
                MediaStripStack(model: model, infos: strips.compactMap { model.mediaStripInfo(for: $0) })
                    .transition(cardTransition)
            }
        }
        .padding(.horizontal, MediaStripMetrics.inset)
        .padding(.bottom, live == nil && strips.isEmpty ? 0 : MediaStripMetrics.gap)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85), value: strips)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85), value: live)
    }

    /// In: up 12 pt from 98 %, fading in; out: down 8 pt, fading (§3.5).
    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity.combined(with: .offset(y: 8))
        )
    }
}

/// Several strips: collapsed, the front card with up to two peeking behind
/// it; on hover they fan into a list, front at the bottom (§3.4).
struct MediaStripStack: View {
    let model: BrowserViewModel
    let infos: [MediaStripInfo]
    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(infos.reversed()) { info in
                        MediaStripCard(model: model, info: info, isExpanded: true)
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    ForEach(Array(infos.prefix(3).enumerated()).reversed(), id: \.element.id) { index, info in
                        MediaStripCard(model: model, info: info, isExpanded: false)
                            .padding(.horizontal, CGFloat(index) * 8)
                            .offset(y: CGFloat(index) * -4)
                            .opacity(1 - 0.25 * Double(index))
                            .allowsHitTesting(index == 0)
                    }
                }
            }
        }
        .onHover { hovering in
            collapseTask?.cancel()
            if hovering {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)) {
                    isExpanded = true
                }
            } else {
                // Arc's debounced hover-off (§3.3): 350 ms.
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                    }
                }
            }
        }
    }
}

/// One strip card. Collapsed it is Arc's 33 pt row of five equal slots:
/// favicon (go to tab), previous, play/pause, next and volume. Expanded it
/// grows upward by a title row with the close button, and its controls row
/// groups the transport and adds "Open Picture in Picture".
struct MediaStripCard: View {
    let model: BrowserViewModel
    let info: MediaStripInfo
    let isExpanded: Bool
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                titleRow.transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.05)))
                controlsRow
            } else {
                MediaStripRow(model: model, info: info)
            }
        }
        .background(MediaStripBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media controls for \(info.title)")
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Button { model.goToMediaTab(info.id) } label: {
                HStack(spacing: 8) {
                    SiteIconView(image: info.favicon, token: info.faviconToken, size: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(chrome.isDark ? Color.white : Color.black.opacity(0.85))
                        Text(info.site).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(MediaStripMetrics.glyph(dark: chrome.isDark))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Tab")
            MediaStripButton(systemName: "xmark", size: 10, help: "Close Mini Player") { model.closeMediaStrip(info.id) }
                .frame(width: 24)
        }
        .padding(.horizontal, 10)
        .frame(height: MediaStripMetrics.height)
    }

    private var controlsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            MediaStripButton(systemName: "backward.end.fill", size: 11, help: "Previous", enabled: info.canPreviousTrack) {
                model.mediaPreviousTrack(info.id)
            }
            .frame(width: 36)
            MediaStripButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 12,
                             help: info.isPlaying ? "Pause" : "Play") { model.mediaTogglePlayPause(info.id) }
                .frame(width: 36)
                .accessibilityIdentifier(info.isPlaying ? "mediaControlsPauseButton" : "mediaControlsPlayButton")
            MediaStripButton(systemName: "forward.end.fill", size: 11, help: "Next", enabled: info.canNextTrack) {
                model.mediaNextTrack(info.id)
            }
            .frame(width: 36)
            Spacer(minLength: 0)
            if info.offersPictureInPicture {
                MediaStripButton(systemName: "pip.enter", size: 12, help: "Open Picture in Picture") {
                    model.openPictureInPicture(info.id)
                }
                .frame(width: 32)
            }
            MediaStripButton(systemName: info.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13,
                             help: "Adjust Tab Volume") { model.toggleMute(info.id) }
                .frame(width: 32)
        }
        .padding(.horizontal, 4)
        .frame(height: MediaStripMetrics.height)
    }
}

/// The collapsed row: five equal slots, glyphs centred (§2.1).
struct MediaStripRow: View {
    let model: BrowserViewModel
    let info: MediaStripInfo

    var body: some View {
        HStack(spacing: 0) {
            Button { model.goToMediaTab(info.id) } label: {
                SiteIconView(image: info.favicon, token: info.faviconToken, size: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Tab")
            .accessibilityLabel("Go to \(info.title)")
            MediaStripButton(systemName: "backward.end.fill", size: 11, help: "Previous", enabled: info.canPreviousTrack) {
                model.mediaPreviousTrack(info.id)
            }
            MediaStripButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 12,
                             help: info.isPlaying ? "Pause" : "Play") { model.mediaTogglePlayPause(info.id) }
                .accessibilityIdentifier(info.isPlaying ? "mediaControlsPauseButton" : "mediaControlsPlayButton")
            MediaStripButton(systemName: "forward.end.fill", size: 11, help: "Next", enabled: info.canNextTrack) {
                model.mediaNextTrack(info.id)
            }
            MediaStripButton(systemName: info.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13,
                             help: info.isMuted ? "Unmute" : "Mute") { model.toggleMute(info.id) }
        }
        .frame(height: MediaStripMetrics.height)
    }
}

/// A strip glyph button: Arc's foreground colour, dimmed when disabled, with
/// a soft round highlight on hover.
struct MediaStripButton: View {
    let systemName: String
    let size: CGFloat
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(MediaStripMetrics.glyph(dark: chrome.isDark, enabled: enabled))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering && enabled ? MediaStripMetrics.hover(dark: chrome.isDark) : .clear))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The card: opaque fill, 8 pt continuous corners and Arc's soft all-round shadow.
struct MediaStripBackground: View {
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        RoundedRectangle(cornerRadius: MediaStripMetrics.radius, style: .continuous)
            .fill(MediaStripMetrics.fill(dark: chrome.isDark))
            .shadow(color: .black.opacity(chrome.isDark ? 0.3 : 0.08), radius: 3, y: 0)
    }
}
