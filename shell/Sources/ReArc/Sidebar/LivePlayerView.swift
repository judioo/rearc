import AppKit
import SwiftUI
import SidebarModel

/// The sidebar's live video card (MINI-PLAYER.md §5.2, a ReArc addition):
/// the tab's PiP video at the sidebar's width above its strip row, one 8 pt
/// card. Hover shows the controls; a click on the video goes to the tab.
struct LivePlayerCard: View {
    let model: BrowserViewModel
    let info: MediaStripInfo

    var body: some View {
        let video = model.liveVideo(for: info.id)
        let height = LiveVideoLayout.videoHeight(
            sidebarWidth: Double(model.sidebarWidth),
            naturalSize: video?.naturalSize.map { (Double($0.width), Double($0.height)) }
        )
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let video {
                    LiveVideoHostView(video: video, owner: .sidebar)
                        .opacity(video.hasFirstFrame ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: video.hasFirstFrame)
                    LiveVideoControls(model: model, tabID: info.id, video: video, style: .sidebar)
                }
            }
            .frame(height: CGFloat(height))
            .clipped()
            MediaStripRow(model: model, info: info)
        }
        .clipShape(RoundedRectangle(cornerRadius: MediaStripMetrics.radius, style: .continuous))
        .background(MediaStripBackground())
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video from \(info.title)")
    }
}

/// Hover controls over a live video: scrims, play/pause in the centre, back
/// to tab and the title top left, pop out (or dock / minimize) and close top
/// right, and a scrubber along the bottom (§5.3). A click elsewhere on the
/// video goes to the tab.
struct LiveVideoControls: View {
    enum Style { case sidebar, panel }

    let model: BrowserViewModel
    let tabID: Tab.ID
    let video: any LiveVideoHandle
    let style: Style
    @State private var isHovering = false
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.goToMediaTab(tabID) }
            if isHovering || isScrubbing {
                controls.transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: hovering ? 0.15 : 0.25)) { isHovering = hovering }
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom).frame(height: 40)
            }
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    overlayButton("arrow.up.backward.square", help: "Back to Tab") { model.goToMediaTab(tabID) }
                    Text(model.store.tab(withID: tabID)?.displayTitle ?? "")
                        .font(.system(size: 11)).foregroundStyle(.white).lineLimit(1)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    switch style {
                    case .sidebar:
                        overlayButton("pip.exit", help: "Open Picture in Picture") { model.popOutLiveVideo(tabID) }
                    case .panel:
                        if model.embedsVideoInSidebar {
                            overlayButton("sidebar.left", help: "Back to Sidebar") { model.dockLiveVideo(tabID) }
                        } else {
                            overlayButton("minus", help: "Minimize") { model.minimizeLiveVideo(tabID) }
                        }
                    }
                    overlayButton("xmark", help: "Close Player") { model.closeLiveVideo(tabID) }
                }
                .padding(.horizontal, 4)
                Spacer(minLength: 0)
                LiveVideoScrubber(video: video, isScrubbing: $isScrubbing)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            Button { video.perform(.togglePlayPause) } label: {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(video.isPlaying ? "Pause" : "Play")
        }
    }

    private func overlayButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A 3 pt track (5 pt on hover) from the engine's media position; drag seeks.
/// Hidden without a finite duration (live streams).
struct LiveVideoScrubber: View {
    let video: any LiveVideoHandle
    @Binding var isScrubbing: Bool
    @State private var isHovering = false
    @State private var dragFraction: Double?

    var body: some View {
        if let duration = video.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let fraction = dragFraction ?? min(1, max(0, (video.position(at: context.date) ?? 0) / duration))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule().fill(.white).frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: isHovering || isScrubbing ? 5 : 3)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            dragFraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        }
                        .onEnded { _ in
                            if let dragFraction { video.seek(to: dragFraction * duration) }
                            dragFraction = nil
                            isScrubbing = false
                        })
                }
            }
            .frame(height: 12)
            .onHover { isHovering = $0 }
        }
    }
}

/// Parents the engine's video view. The same view moves between the sidebar
/// card and the floating panel; whichever host was updated last while on
/// screen holds it. Each layout reports the view's screen rect to the engine.
struct LiveVideoHostView: NSViewRepresentable {
    enum Owner { case sidebar, panel }

    let video: any LiveVideoHandle
    let owner: Owner

    func makeNSView(context: Context) -> LiveVideoContainerView {
        LiveVideoContainerView()
    }

    func updateNSView(_ container: LiveVideoContainerView, context: Context) {
        container.host(video)
    }

    static func dismantleNSView(_ container: LiveVideoContainerView, coordinator: ()) {
        container.release()
    }
}

final class LiveVideoContainerView: NSView {
    private var video: (any LiveVideoHandle)?

    override var isFlipped: Bool { true }

    func host(_ video: any LiveVideoHandle) {
        self.video = video
        adoptIfPossible()
    }

    func release() {
        if let view = video?.view, view.superview === self { view.removeFromSuperview() }
        video = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            release()
        } else {
            adoptIfPossible()
        }
    }

    override func layout() {
        super.layout()
        guard let view = video?.view, view.superview === self else { return }
        view.frame = bounds
        reportFrame()
    }

    private func adoptIfPossible() {
        guard let video, window != nil else { return }
        let view = video.view
        if view.superview !== self {
            // Another visible host (a key window's sidebar, the panel) keeps it.
            if let other = view.window, other.isVisible, other !== window, other.isKeyWindow { return }
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        needsLayout = true
        reportFrame()
    }

    private func reportFrame() {
        guard let window, let video, video.view.superview === self, let primary = NSScreen.screens.first else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        video.reportScreenFrame(CGRect(x: onScreen.minX, y: primary.frame.maxY - onScreen.maxY,
                                       width: onScreen.width, height: onScreen.height))
    }
}
