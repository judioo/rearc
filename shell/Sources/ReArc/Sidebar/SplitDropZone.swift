import AppKit
import SwiftUI
import SidebarModel

/// Drag-to-split over the page (Arc `isDraggingToCreateSplitView`,
/// SPLIT-VIEW §2.3): while a sidebar tab is dragged, the content shows where
/// it would land (left, right, top or bottom half) and a drop makes the split.
/// Present only during a sidebar drag of a tab that can split here, so drops
/// from other apps still reach the page.
struct ContentSplitDropZone: View {
    /// The dragged sidebar item, used when the pasteboard cannot be read.
    let draggedItemID: UUID
    let accent: Color
    let onDrop: (UUID, SplitDropEdge) -> Bool
    @State private var hovered: SplitDropEdge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let hovered {
                    preview(hovered, in: geometry.size)
                        .transition(.opacity)
                }
                SplitDropTarget(
                    fallbackID: draggedItemID,
                    onHover: { hovered = $0 },
                    onDrop: onDrop
                )
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.86), value: hovered)
    }

    private func preview(_ edge: SplitDropEdge, in size: CGSize) -> some View {
        let half = Self.frame(for: edge, in: size)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(accent.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.7), lineWidth: 2)
            )
            .overlay {
                Label(edge.title, systemImage: Self.symbol(for: edge))
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
            }
            .frame(width: half.width, height: half.height)
            .offset(x: half.minX, y: half.minY)
            .allowsHitTesting(false)
    }

    /// The half of the page the new pane takes, inset from the card edge.
    static func frame(for edge: SplitDropEdge, in size: CGSize) -> CGRect {
        let inset: CGFloat = 6
        let w = size.width / 2, h = size.height / 2
        let rect: CGRect
        switch edge {
        case .leading: rect = CGRect(x: 0, y: 0, width: w, height: size.height)
        case .trailing: rect = CGRect(x: w, y: 0, width: w, height: size.height)
        case .top: rect = CGRect(x: 0, y: 0, width: size.width, height: h)
        case .bottom: rect = CGRect(x: 0, y: h, width: size.width, height: h)
        }
        return rect.insetBy(dx: inset, dy: inset)
    }

    private static func symbol(for edge: SplitDropEdge) -> String {
        switch edge {
        case .leading: return "rectangle.lefthalf.inset.filled"
        case .trailing: return "rectangle.righthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        }
    }
}

/// An AppKit drop target, so it sits above the engine's own view (WKWebView
/// and Chromium's host view register for drags themselves). It ignores
/// clicks (`hitTest` is nil); dragging destinations are found by drag type.
private struct SplitDropTarget: NSViewRepresentable {
    let fallbackID: UUID
    let onHover: (SplitDropEdge?) -> Void
    let onDrop: (UUID, SplitDropEdge) -> Bool

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TargetView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TargetView) {
        view.fallbackID = fallbackID
        view.onHover = onHover
        view.onDrop = onDrop
    }

    final class TargetView: NSView {
        var fallbackID: UUID?
        var onHover: ((SplitDropEdge?) -> Void)?
        var onDrop: ((UUID, SplitDropEdge) -> Bool)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func edge(_ sender: NSDraggingInfo) -> SplitDropEdge? {
            let point = convert(sender.draggingLocation, from: nil)
            return SplitDropEdge.nearest(x: point.x, y: point.y, width: bounds.width, height: bounds.height)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let edge = edge(sender)
            onHover?(edge)
            return edge == nil ? [] : .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onHover?(nil)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onHover?(nil)
            let text = sender.draggingPasteboard.string(forType: .string)
            guard let id = text.flatMap(UUID.init(uuidString:)) ?? fallbackID, let edge = edge(sender) else { return false }
            return onDrop?(id, edge) ?? false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onHover?(nil)
        }
    }
}

/// SwiftUI's `onDrag` never reports a drag that ends outside a drop target.
/// The first mouse move or click with no button held after it clears the
/// dragged item, so drop affordances do not linger.
struct DragSessionEndMonitor: NSViewRepresentable {
    var isActive: Bool
    var onEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event)
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: DragSessionEndMonitor
        var monitor: Any?

        init(parent: DragSessionEndMonitor) { self.parent = parent }

        func handle(_ event: NSEvent) {
            guard parent.isActive else { return }
            if event.type == .leftMouseDown || NSEvent.pressedMouseButtons & 1 == 0 {
                parent.onEnded()
            }
        }
    }
}
