import AppKit
import SwiftUI
import SidebarModel

/// The floating Picture in Picture panel for a live video (Arc's PiP window):
/// a borderless, non-activating panel above other windows that parents the
/// same engine view the sidebar card shows. It follows the model: shown
/// while a tab's effective placement is `.panel`, ordered out otherwise
/// (minimized into the strip, docked, or the session ended).
/// `BrowserViewModel.livePanelTabID` says whose video it has on a screen:
/// the strip of that tab hides only then.
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
            // On the display the person is looking at: the last frame's place
            // there, or the corner; a panel on another display is out of sight.
            let screens = NSScreen.screens.map(\.visibleFrame)
            let target = anchorScreen()?.visibleFrame ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(Self.frame(last: lastFrame, naturalSize: video.naturalSize, screens: screens, on: target), display: false)
            panel.orderFrontRegardless()
        }
        let shown = panel.isVisible && Self.isOnScreen(panel.frame) ? tabID : nil
        if model.livePanelTabID != shown { model.livePanelTabID = shown }
    }

    private func hide() {
        if model?.livePanelTabID != nil { model?.livePanelTabID = nil }
        guard let panel, panel.isVisible || panel.contentView != nil else { return }
        lastFrame = panel.frame
        panel.orderOut(nil)
        // Dropping the hosting view takes the video view out of this window.
        panel.contentView = nil
        tabID = nil
    }

    /// Most of the panel lies on some display.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersection(frame).area >= frame.area / 2 }
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
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: Self.frame(last: nil, naturalSize: nil, screens: [visible], on: visible), styleMask: [.borderless, .nonactivatingPanel, .resizable],
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

    /// The screen of the browser window the person is in (the strip's button,
    /// the switch away that started automatic PiP), else the main screen.
    private func anchorScreen() -> NSScreen? {
        let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0 !== panel && !($0 is NSPanel) }
            ?? NSApp.orderedWindows.first { $0 !== panel && !($0 is NSPanel) && $0.isVisible }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Where the panel opens on `target` (a screen's visible frame): the
    /// last frame when it is there; a last frame from another display at the
    /// same place relative to `target`, kept inside it; otherwise 320 pt wide
    /// at the video's aspect, 16 pt in from the bottom right.
    nonisolated static func frame(last: NSRect?, naturalSize natural: CGSize?, screens: [NSRect], on target: NSRect) -> NSRect {
        if let last {
            if target.intersection(last).area >= last.area / 2 { return last }
            if let source = screens.max(by: { $0.intersection(last).area < $1.intersection(last).area }),
               source.intersection(last).area > 0 {
                let size = NSSize(width: min(last.width, target.width), height: min(last.height, target.height))
                let x = target.minX + (last.minX - source.minX) / max(1, source.width - last.width) * (target.width - size.width)
                let y = target.minY + (last.minY - source.minY) / max(1, source.height - last.height) * (target.height - size.height)
                return NSRect(x: min(max(x, target.minX), target.maxX - size.width).rounded(),
                              y: min(max(y, target.minY), target.maxY - size.height).rounded(),
                              width: size.width, height: size.height)
            }
        }
        var aspect = 16.0 / 9.0
        if let natural, natural.width > 0, natural.height > 0 { aspect = natural.width / natural.height }
        let width: CGFloat = 320, height = (width / aspect).rounded()
        return NSRect(x: target.maxX - width - 16, y: target.minY + 16, width: width, height: height)
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
            if model.blankLiveVideos.contains(tabID) {
                LiveVideoStill(model: model, tabID: tabID)
            }
            LiveVideoControls(model: model, tabID: tabID, video: video, style: .panel)
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in onDrag(false) }
                    .onEnded { _ in onDrag(true) })
        }
        .ignoresSafeArea()
        .task(id: video.overlayID) { await model.watchLiveVideo(tabID) }
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
