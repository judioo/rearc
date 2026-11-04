import AppKit
import SwiftUI
import SidebarModel

/// Capture's overlay over the page (Arc `ContentCaptureOverlayView`,
/// EASEL-CAPTURE §4.2): the page dims, a drag draws the region to capture
/// and a click captures the element under the pointer. Esc cancels.
struct PageCaptureOverlay: View {
    let model: BrowserViewModel

    var body: some View {
        ZStack(alignment: .top) {
            CaptureOverlayRepresentable(
                onFinish: { region, point in
                    Task { await model.completePageCapture(region: region, clickAt: point) }
                },
                onCancel: { model.cancelPageCapture() }
            )
            Text("Drag to capture an area, or click an element — Esc to cancel")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
    }
}

private struct CaptureOverlayRepresentable: NSViewRepresentable {
    var onFinish: (CaptureRect?, (x: Double, y: Double)?) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureOverlayNSView {
        let view = CaptureOverlayNSView()
        view.onFinish = onFinish
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: CaptureOverlayNSView, context: Context) {
        view.onFinish = onFinish
        view.onCancel = onCancel
    }
}

final class CaptureOverlayNSView: NSView {
    var onFinish: ((CaptureRect?, (x: Double, y: Double)?) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        let selection = selectionRect
        if let selection {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: selection).reversed)
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        } else {
            bounds.fill()
        }
    }

    private var selectionRect: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        self.start = nil
        current = nil
        needsDisplay = true
        let size = bounds.size
        if let region = CaptureCropping.dragFraction(from: (start.x, start.y), to: (end.x, end.y),
                                                     viewWidth: size.width, viewHeight: size.height) {
            onFinish?(region, nil)
        } else if size.width > 0, size.height > 0 {
            onFinish?(nil, (x: end.x / size.width, y: end.y / size.height))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
