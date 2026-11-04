import AppKit
import SwiftUI
import SidebarModel

/// The floating Picture in Picture panel for a live video (Arc's PiP window):
/// a borderless, non-activating panel above other windows that parents the
/// same engine view the sidebar card shows. It follows the model: shown
/// while a tab's effective placement is `.panel`, ordered out otherwise
/// (minimized into the strip, docked, or the session ended).
@MainActor
final class LiveVideoPanelController {
    private weak var model: BrowserViewModel?
    private var panel: NSPanel?
    private(set) var tabID: Tab.ID?
    /// The last frame, so the panel reopens where it was (Arc `lastVideoPIPPosition`).
    private var lastFrame: NSRect?

    init(model: BrowserViewModel) {
        self.model = model
    }

    var isShowing: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }

    /// Re-evaluates now and whenever what it read changes.
    func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.track() }
        }
    }

    private func apply() {
        guard let model else { return }
        let target = model.livePlacements.keys.sorted { $0.uuidString < $1.uuidString }.first { id in
            model.effectiveLivePlacement(for: id) == .panel && model.liveVideo(for: id) != nil
        }
        guard let target, let video = model.liveVideo(for: target) else {
            hide()
            return
        }
        show(tabID: target, video: video, model: model)
    }

    private func show(tabID: Tab.ID, video: any LiveVideoHandle, model: BrowserViewModel) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if self.tabID != tabID || panel.contentView == nil {
            self.tabID = tabID
            let content = LiveVideoPanelContent(model: model, tabID: tabID, video: video) { [weak self] ended in
                self?.drag(ended: ended)
            }
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 10
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
        }
        if let size = video.naturalSize, size.width > 0, size.height > 0 {
            panel.contentAspectRatio = size
        }
        if !panel.isVisible {
            panel.setFrame(lastFrame ?? defaultFrame(for: video.naturalSize), display: false)
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        guard let panel, panel.isVisible || panel.contentView != nil else { return }
        lastFrame = panel.frame
        panel.orderOut(nil)
        // Dropping the hosting view takes the video view out of this window.
        panel.contentView = nil
        tabID = nil
    }

    private var dragAnchor: NSPoint?

    /// Moves the panel with the pointer in screen coordinates (the view's own
    /// coordinates move with the panel).
    private func drag(ended: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if let anchor = dragAnchor {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + mouse.x - anchor.x, y: panel.frame.minY + mouse.y - anchor.y))
            lastFrame = panel.frame
        }
        dragAnchor = ended ? nil : mouse
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: defaultFrame(for: nil), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 200, height: 112)
        panel.title = "Picture in Picture"
        return panel
    }

    /// 320 pt wide at the video's aspect, 16 pt in from the main screen's bottom right.
    private func defaultFrame(for natural: CGSize?) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var aspect = 16.0 / 9.0
        if let natural, natural.width > 0, natural.height > 0 { aspect = natural.width / natural.height }
        let width: CGFloat = 320, height = (width / aspect).rounded()
        return NSRect(x: visible.maxX - width - 16, y: visible.minY + 16, width: width, height: height)
    }
}

/// The panel's content: the video and its hover controls. Dragging the
/// video moves the panel; a click goes to the tab.
struct LiveVideoPanelContent: View {
    let model: BrowserViewModel
    let tabID: Tab.ID
    let video: any LiveVideoHandle
    /// Called while dragging (false) and once at the end (true).
    let onDrag: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            LiveVideoHostView(video: video, owner: .panel)
            LiveVideoControls(model: model, tabID: tabID, video: video, style: .panel)
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in onDrag(false) }
                    .onEnded { _ in onDrag(true) })
        }
        .ignoresSafeArea()
    }
}
