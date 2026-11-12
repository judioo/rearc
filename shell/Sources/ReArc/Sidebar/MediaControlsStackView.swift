import AppKit
import SwiftUI
import SidebarModel

/// What one media strip shows, read from the model for its source tab.
struct MediaStripInfo: Identifiable {
    let id: Tab.ID
    let title: String
    let site: String
    /// Where the tab lives: "Space › Folder", its profile first when the window shows another.
    let location: String
    let favicon: NSImage?
    let faviconToken: String
    let isPlaying: Bool
    let isMuted: Bool
    let canPreviousTrack: Bool
    let canNextTrack: Bool
    /// "Open Picture in Picture": the panel was minimized, or the video can enter PiP.
    let offersPictureInPicture: Bool
}

/// Arc's media strip tokens (MINI-PLAYER.md §2.1, §2.3).
enum MediaStripMetrics {
    static let height: CGFloat = 33
    static let radius: CGFloat = 8
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8
    /// The favicon's and the speaker's centres, and the × above the speaker, from the strip's edges.
    static let edgeSlot: CGFloat = 44
    /// The title's leading inset in the expanded row.
    static let titleInset: CGFloat = 14
    /// The expanded title row with ReArc's location line under the title [RA]; Arc's has the title alone in 33 pt.
    static let titleRowHeight: CGFloat = 42

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
        let calls = model.callCards(in: window)
        VStack(spacing: MediaStripMetrics.gap) {
            ForEach(calls, id: \.self) { id in
                if let tab = model.store.tab(withID: id), let capture = model.captureStateByTab[id] {
                    CallCardView(
                        title: tab.displayTitle,
                        favicon: model.favicon(for: tab),
                        faviconToken: tab.faviconToken,
                        capture: capture,
                        isAlone: calls.count == 1,
                        endTitle: model.callEndAction(for: id)?.title,
                        goToTab: { model.goToMediaTab(id) },
                        toggle: { model.toggleCapture($0, in: id) },
                        endCall: { model.endCall(id) }
                    )
                    .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
                }
            }
            // The stack grows upwards from a fixed bottom edge: a new card
            // enters at the top from behind the one below, which stays put.
            if let live, let info = model.mediaStripInfo(for: live, in: window) {
                LivePlayerCard(model: model, info: info)
                    .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
                    .zIndex(0)
            }
            if !strips.isEmpty {
                MediaStripStack(model: model, infos: strips.compactMap { model.mediaStripInfo(for: $0, in: window) })
                    .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
                    .zIndex(1)
            }
        }
        .padding(.horizontal, MediaStripMetrics.inset)
        .padding(.bottom, live == nil && strips.isEmpty && calls.isEmpty ? 0 : MediaStripMetrics.gap)
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: calls)
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: strips)
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: live)
    }
}

/// Arc's media stack motion (ARC-RECORDING-2026-11-06.md §4 item 5): a card
/// slides up from below its top edge and fades in, on the sidebar spring
/// (about 0.25 s); removal reverses it. Reduce Motion fades only.
enum MediaStackMotion {
    static func card(reduceMotion: Bool, distance: CGFloat = MediaStripMetrics.height) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: distance))
    }
}

/// Several strips: collapsed, the front card with up to two peeking behind
/// it; on hover they fan into a list with the newest on top, so a strip that
/// arrives slides in above the others and they stay put, as in Arc
/// (ARC-RECORDING-2026-11-06.md §2 rule 5).
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
                    ForEach(infos) { info in
                        MediaStripCard(model: model, info: info, isExpanded: true, isAlone: infos.count == 1)
                            .transition(MediaStackMotion.card(reduceMotion: reduceMotion))
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    ForEach(Array(infos.prefix(3).enumerated()).reversed(), id: \.element.id) { index, info in
                        MediaStripCard(model: model, info: info, isExpanded: false, isAlone: infos.count == 1)
                            .padding(.horizontal, CGFloat(index) * 8)
                            .offset(y: CGFloat(index) * -4)
                            .opacity(1 - 0.25 * Double(index))
                            .allowsHitTesting(index == 0)
                            // A strip joining or leaving the pile rises into
                            // place without dropping below the stack's edge.
                            .transition(MediaStackMotion.card(reduceMotion: reduceMotion, distance: 8))
                    }
                }
            }
        }
        .animation(SidebarMotion.spring(reduceMotion: reduceMotion), value: infos.map(\.id))
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

/// One strip card. Collapsed it is Arc's 33 pt row: favicon (go to tab),
/// previous, play/pause, next and volume. Hovered it grows upward by a
/// title row: the tab's title over where it lives (space and folder, a
/// ReArc addition so the strip says where to find the tab), a pop-out
/// (Picture in Picture) button and ×.
/// The controls row keeps its five cells (ARC-RECORDING-ANALYSIS.md §7,
/// frames 2691–2692; MINI-PLAYER.md §2.3). A title too long for the row
/// scrolls while the pointer is on the card or the strip is alone.
struct MediaStripCard: View {
    let model: BrowserViewModel
    let info: MediaStripInfo
    let isExpanded: Bool
    var isAlone = false
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                titleRow.transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            MediaStripRow(model: model, info: info)
        }
        .background(MediaStripBackground())
        .onHover { isHovering = $0 }
        .help("\(info.title)\n\(info.location)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media controls for \(info.title), in \(info.location)")
    }

    private var titleRow: some View {
        HStack(spacing: 2) {
            Button { model.goToMediaTab(info.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: info.title, font: .system(size: 13),
                                color: chrome.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8),
                                isActive: isHovering || isAlone)
                    Text(info.location)
                        .font(.system(size: 11))
                        .foregroundStyle(chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("In \(info.location)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Tab")
            if info.offersPictureInPicture {
                // Two overlapping rectangles; the strip leaves while PiP is open.
                MediaStripButton(systemName: "rectangle.on.rectangle", size: 11, help: "Open Picture in Picture") {
                    model.openPictureInPicture(info.id)
                }
                .frame(width: 24)
            }
            // Above the speaker, 22 pt from the edge as in Arc.
            MediaStripButton(systemName: "xmark", size: 10, help: "Close Mini Player") { model.closeMediaStrip(info.id) }
                .frame(width: 24)
        }
        .padding(.leading, MediaStripMetrics.titleInset)
        .padding(.trailing, MediaStripMetrics.edgeSlot / 2 - 12)
        .frame(height: MediaStripMetrics.titleRowHeight)
    }
}

/// The collapsed row (§2.1, §2.3): the favicon and the speaker centred
/// 22 pt in from the edges, the three transport buttons centred on the
/// strip a fifth of its width apart. At Arc's default 212 pt that is five
/// equal slots; wider, the ends stay at the edges.
struct MediaStripRow: View {
    let model: BrowserViewModel
    let info: MediaStripInfo

    var body: some View {
        GeometryReader { geometry in
            let pitch = geometry.size.width / 5
            ZStack {
                HStack(spacing: 0) {
                    Button { model.goToMediaTab(info.id) } label: {
                        SiteIconView(image: info.favicon, token: info.faviconToken, size: 16)
                            .frame(maxHeight: .infinity)
                            .frame(width: MediaStripMetrics.edgeSlot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to Tab")
                    .accessibilityLabel("Go to \(info.title)")
                    Spacer(minLength: 0)
                    MediaStripButton(systemName: info.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13,
                                     help: info.isMuted ? "Unmute" : "Mute") { model.toggleMute(info.id) }
                        .frame(width: MediaStripMetrics.edgeSlot)
                }
                HStack(spacing: 0) {
                    MediaStripButton(systemName: "backward.end.fill", size: 11, help: "Previous", enabled: info.canPreviousTrack) {
                        model.mediaPreviousTrack(info.id)
                    }
                    .frame(width: pitch)
                    MediaStripButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 12,
                                     help: info.isPlaying ? "Pause" : "Play") { model.mediaTogglePlayPause(info.id) }
                        .accessibilityIdentifier(info.isPlaying ? "mediaControlsPauseButton" : "mediaControlsPlayButton")
                        .frame(width: pitch)
                    MediaStripButton(systemName: "forward.end.fill", size: 11, help: "Next", enabled: info.canNextTrack) {
                        model.mediaNextTrack(info.id)
                    }
                    .frame(width: pitch)
                }
            }
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
