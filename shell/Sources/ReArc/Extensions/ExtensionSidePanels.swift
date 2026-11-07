import AppKit
import SidebarModel
import SwiftUI

/// The engine side of extension side panels (Chromium ABI 1.47). WebKit has
/// none, and no window ever shows a panel there.
protocol ExtensionSidePanelBackend: AnyObject {
    /// The header's close button.
    func closeSidePanel(in window: SidebarWindowID)
}

/// Extension side panels (`chrome.sidePanel`), one per window as in Arc: a
/// pane beside the page on the side opposite the sidebar, with the
/// extension's icon and name over its page, kept across the window's tab
/// switches. The backend decides what each window shows; the pane width is
/// shared and persisted (docs/arc-recordings/2026-11-06-side-panel.md).
@Observable
final class ExtensionSidePanelController {
    struct Shown {
        var extensionID: String
        var title: String
        var iconPNG: Data?
        /// The panel's hosted page; its identity keys the pane's view.
        var engine: any WebEngine
        var panelID: UInt64
    }

    private(set) var shown: [SidebarWindowID: Shown] = [:]
    /// The committed pane width (a drag updates it when it ends).
    private(set) var width: Double
    @ObservationIgnored weak var backend: ExtensionSidePanelBackend?
    @ObservationIgnored var defaults: UserDefaults {
        didSet { width = SidePanelWidth.load(from: defaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        width = SidePanelWidth.load(from: defaults)
    }

    func panel(in window: SidebarWindowID?) -> Shown? {
        window.flatMap { shown[$0] }
    }

    /// The extension's panel is open in `window` (its toolbar button can show it).
    func isOpen(_ extensionID: String, in window: SidebarWindowID?) -> Bool {
        panel(in: window)?.extensionID == extensionID
    }

    func setShown(_ panel: Shown?, in window: SidebarWindowID) {
        shown[window] = panel
    }

    func close(in window: SidebarWindowID) {
        backend?.closeSidePanel(in: window)
    }

    func commitWidth(_ value: Double, available: Double?) {
        let clamped = SidePanelWidth.clamped(value, available: available)
        SidePanelWidth.save(clamped, to: defaults)
        if clamped != width { width = clamped }
    }
}

extension View {
    /// The window's content with its extension side panel beside it
    /// (`ExtensionSidePanelSplit`).
    func extensionSidePanel(_ extensions: ExtensionsController, window: SidebarWindowID,
                            sidebarSide: SidebarSide = .left, topInset: CGFloat = 10, isHidden: Bool) -> some View {
        ExtensionSidePanelSplit(extensions: extensions, window: window, sidebarSide: sidebarSide, topInset: topInset,
                                isHidden: isHidden) { self }
    }
}

/// The window's content beside its extension side panel. Only this view and
/// the pane read the panel state, and only the pane reads a drag's live
/// width: opening, closing and resizing never evaluate the sidebar or the
/// page card again, they are only laid out narrower.
struct ExtensionSidePanelSplit<Content: View>: View {
    let extensions: ExtensionsController
    private var controller: ExtensionSidePanelController { extensions.sidePanels }
    let window: SidebarWindowID
    /// `SidePanelPlacement` puts the pane on the other side.
    var sidebarSide: SidebarSide = .left
    /// Level with the page card's top (below the traffic lights when the pane takes their side).
    var topInset: CGFloat = 10
    /// HTML fullscreen: the page alone (the pane is not removed from under it).
    var isHidden = false
    @ViewBuilder var content: Content
    @State private var available: Double?

    var body: some View {
        let side = SidePanelPlacement.side(sidebarSide: sidebarSide)
        let panel = isHidden ? nil : controller.panel(in: window)
        HStack(spacing: 0) {
            if side == .left, let panel { pane(panel, side: side) }
            content
            if side == .right, let panel { pane(panel, side: side) }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { available = $0 }
        // Arc slides it in over ~160 ms and out over ~70 ms (§1 of the recording notes).
        // A replaced panel swaps in place (same width, no motion).
        .animation(panel == nil ? .easeIn(duration: 0.07) : .easeOut(duration: 0.16), value: panel != nil)
    }

    private func pane(_ panel: ExtensionSidePanelController.Shown, side: SidebarSide) -> some View {
        ExtensionSidePanelPane(extensions: extensions, window: window, panel: panel, side: side, topInset: topInset,
                               available: available)
            .id(panel.panelID)
            .transition(.move(edge: side == .right ? .trailing : .leading))
    }
}

/// The pane: the extension's icon, name and a close button on the window's
/// chrome, its page in a card below, and a resize edge facing the page. A
/// drag resizes only this view; the width is saved when it ends.
struct ExtensionSidePanelPane: View {
    let extensions: ExtensionsController
    private var controller: ExtensionSidePanelController { extensions.sidePanels }
    let window: SidebarWindowID
    let panel: ExtensionSidePanelController.Shown
    let side: SidebarSide
    var topInset: CGFloat = Self.inset
    let available: Double?
    @State private var dragWidth: Double?
    @State private var dragStart: Double?

    static let headerHeight: CGFloat = 36
    static let inset: CGFloat = 10
    static let radius: CGFloat = 8

    var body: some View {
        let width = SidePanelWidth.clamped(dragWidth ?? controller.width, available: available)
        VStack(spacing: 0) {
            header
            panel.engine.makeView()
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .padding(.top, topInset)
        .padding(.bottom, Self.inset)
        // The page card's own inset is the gap on the page's side.
        .padding(side == .right ? .trailing : .leading, Self.inset)
        .frame(width: width)
        .overlay(alignment: side == .right ? .leading : .trailing) { resizeEdge(width: width) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(panel.title) side panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let data = panel.iconPNG, let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            } else {
                Image(systemName: "puzzlepiece.extension").frame(width: 16, height: 16)
            }
            Text(panel.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button { extensions.togglePin(panel.extensionID) } label: {
                Image(systemName: extensions.pins.pinnedIDs.contains(panel.extensionID) ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(extensions.pins.pinnedIDs.contains(panel.extensionID) ? "Unpin from toolbar" : "Pin to toolbar")
            .accessibilityLabel(extensions.pins.pinnedIDs.contains(panel.extensionID) ? "Unpin \(panel.title) from toolbar" : "Pin \(panel.title) to toolbar")
            Button { controller.close(in: window) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close side panel")
            .accessibilityLabel("Close \(panel.title) side panel")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.headerHeight)
    }

    /// Straddles the gap between the page card and the pane.
    private func resizeEdge(width: Double) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: side == .right ? -6 : 6)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                let start = dragStart ?? width
                dragStart = start
                let delta = Double(drag.translation.width)
                dragWidth = SidePanelWidth.clamped(side == .right ? start - delta : start + delta, available: available)
            }.onEnded { _ in
                if let dragWidth { controller.commitWidth(dragWidth, available: available) }
                dragWidth = nil
                dragStart = nil
            })
            .accessibilityHidden(true)
    }
}
