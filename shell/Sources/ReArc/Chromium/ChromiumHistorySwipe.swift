#if REARC_CHROMIUM
import AppKit
import SidebarModel

/// The ABI has no wheel ACK/overscroll event. Hold the opening wheel events
/// briefly while checking scroll edges; an unknown edge always goes to the page.
@MainActor
final class ChromiumHistorySwipe {
    private weak var host: ChromiumHostView?
    private weak var wheelTarget: NSView?
    private var monitor: Any?
    private var machine = HistorySwipe()
    private var edges = HistorySwipe.Edges(back: false, forward: false)
    private var pending: [NSEvent] = []
    private var probing = false
    private var gesture = false
    private var awaitingBegan = false
    private var generation = 0
    private let indicator = HistorySwipeIndicator()

    init(host: ChromiumHostView) {
        self.host = host
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        generation += 1
        flushProbe(edges: nil)
        indicator.removeFromSuperview()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let host, event.window === host.window, host.window?.isKeyWindow == true,
              !host.isHiddenOrHasHiddenAncestor, host.pickerOverlay == nil, host.leaseAttachmentID != nil else { return event }
        let point = host.convert(event.locationInWindow, from: nil)
        guard event.hasPreciseScrollingDeltas else { return event }
        if event.phase.contains(.mayBegin) || (event.phase.contains(.began) && !awaitingBegan) {
            guard host.bounds.contains(point), let content = host.window?.contentView,
                  let target = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  target.isDescendant(of: host) else { return event }
            awaitingBegan = event.phase.contains(.mayBegin)
            begin(event, point: point, host: host)
            return nil
        }
        if event.phase.contains(.began) { awaitingBegan = false }
        guard gesture else { return event }
        if probing {
            pending.append(event)
            if pending.count >= 48 { generation += 1; flushProbe(edges: nil) }
            return nil
        }
        return process(event) ? nil : event
    }

    private func begin(_ event: NSEvent, point: NSPoint, host: ChromiumHostView) {
        generation += 1
        flushProbe(edges: nil)
        machine = HistorySwipe()
        indicator.removeFromSuperview()
        gesture = true
        probing = true
        pending = [event]
        wheelTarget = host.hitTest(point)
        let token = generation, engine = host.engine
        let x = (point.x - host.bounds.minX) / max(host.bounds.width, 1)
        let y = (point.y - host.bounds.minY) / max(host.bounds.height, 1)
        let source = HistorySwipeEdgeScript.source(x: x, y: host.isFlipped ? y : 1 - y)
        Task { [weak self, weak engine] in
            guard let engine else { return }
            let result = try? await engine.evaluate(source, in: .editor, timeoutMS: 100, sameNavigation: true)
            guard let self, self.generation == token, self.host?.engine === engine, self.probing else { return }
            let values = result as? [String: Bool]
            self.flushProbe(edges: values.map { .init(back: $0["back"] == true, forward: $0["forward"] == true) })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.generation == token, self.probing else { return }
            self.generation += 1
            self.flushProbe(edges: nil)
        }
    }

    private func flushProbe(edges: HistorySwipe.Edges?) {
        guard probing else { return }
        probing = false
        self.edges = edges ?? .init(back: false, forward: false)
        let events = pending
        pending = []
        for event in events where !process(event) { wheelTarget?.scrollWheel(with: event) }
    }

    private func process(_ event: NSEvent) -> Bool {
        guard let host else { return false }
        let phase: HistorySwipe.Phase
        if !event.momentumPhase.isEmpty { phase = .momentum }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else { phase = .unphased }
        let update = machine.handle(phase: phase, x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                    edges: edges, canGoBack: host.engine.canGoBack, canGoForward: host.engine.canGoForward)
        if let direction = update.direction {
            indicator.direction = direction
            indicator.progress = update.progress
            indicator.frame = NSRect(x: direction == .back ? 12 : host.bounds.width - 52,
                                     y: host.bounds.midY - 20, width: 40, height: 40)
            if indicator.superview == nil { host.addSubview(indicator) }
            indicator.needsDisplay = true
        } else { indicator.removeFromSuperview() }
        if let commit = update.commit {
            if commit == .back { host.engine.goBack() } else { host.engine.goForward() }
        }
        if phase == .cancelled || event.momentumPhase.contains(.ended) { gesture = false }
        return update.consumes
    }
}

private final class HistorySwipeIndicator: NSView {
    var direction: HistorySwipe.Direction = .back
    var progress = 0.0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.3 + 0.7 * progress).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        ring.lineWidth = 3
        ring.stroke()
        let symbol = direction == .back ? "arrow.left" : "arrow.right"
        NSImage(systemSymbolName: symbol, accessibilityDescription: direction == .back ? "Back" : "Forward")?
            .draw(in: bounds.insetBy(dx: 11, dy: 11))
    }
}
#endif
