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
        indicator.reset()
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
        indicator.reset()
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
        if update.released {
            indicator.dismiss(committing: update.commit != nil)
        } else if let direction = update.direction {
            indicator.show(direction, progress: update.progress, in: host)
        }
        if let commit = update.commit {
            if commit == .back { host.engine.goBack() } else { host.engine.goForward() }
        }
        if phase == .cancelled || event.momentumPhase.contains(.ended) { gesture = false }
        return update.consumes
    }
}

/// Arc's half disc: black at a progress-driven alpha with an opaque white
/// arrow, sliding out from behind the page edge and clipped by it.
private final class HistorySwipeIndicator: NSView {
    private let content = CALayer()
    private let disc = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private var fade = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        disc.fillColor = NSColor.black.cgColor
        arrow.fillColor = nil
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = HistorySwipe.arrowStroke
        arrow.lineCap = .round
        arrow.lineJoin = .round
        // Geometry tracks the fingers, so only opacity is ever animated.
        for shape in [disc, arrow] {
            shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            content.addSublayer(shape)
        }
        content.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func reset() {
        fade += 1
        content.removeAllAnimations()
        disc.removeAllAnimations()
        content.opacity = 1
        disc.opacity = 0
        removeFromSuperview()
    }

    func show(_ direction: HistorySwipe.Direction, progress: Double, in host: NSView) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shape = HistorySwipe.indicator(progress: progress, reduceMotion: reduceMotion)
        let width = HistorySwipe.reach + 4, height = 2 * HistorySwipe.armedRadius + 4
        frame = NSRect(x: direction == .back ? 0 : host.bounds.width - width,
                       y: host.bounds.midY - height / 2, width: width, height: height)
        let appearing = superview !== host
        if appearing { host.addSubview(self) }
        let scale = host.window?.backingScaleFactor ?? 2
        disc.contentsScale = scale
        arrow.contentsScale = scale
        // Inward distance from the page edge to this view's x.
        let x = { (inset: Double) in direction == .back ? inset : width - inset }
        let midY = height / 2, r = shape.radius
        content.frame = bounds
        disc.path = CGPath(ellipseIn: CGRect(x: x(shape.centre) - r, y: midY - r, width: 2 * r, height: 2 * r), transform: nil)
        arrow.path = Self.arrow(pointing: direction == .back ? -1 : 1, at: CGPoint(x: x(shape.arrowCentre), y: midY))
        let from = disc.presentation()?.opacity ?? disc.opacity
        disc.opacity = Float(shape.opacity)
        guard !reduceMotion, !appearing, from != disc.opacity else {
            disc.removeAnimation(forKey: "tone")
            return
        }
        let ease = CABasicAnimation(keyPath: "opacity")
        ease.fromValue = from
        ease.toValue = disc.opacity
        ease.duration = HistorySwipe.opacityDuration
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        disc.add(ease, forKey: "tone")
    }

    /// The disc stays put and fades; a commit's page swap happens underneath it.
    func dismiss(committing: Bool) {
        guard superview != nil else { return }
        fade += 1
        let token = fade
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = content.presentation()?.opacity ?? content.opacity
        out.toValue = 0
        out.duration = committing ? HistorySwipe.commitFadeDuration : HistorySwipe.cancelFadeDuration
        out.timingFunction = CAMediaTimingFunction(name: committing ? .easeInEaseOut : .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.fade == token else { return }
            self.reset()
        }
        content.opacity = 0
        content.add(out, forKey: "fade")
        CATransaction.commit()
    }

    private static func arrow(pointing sign: CGFloat, at centre: CGPoint) -> CGPath {
        let half = (HistorySwipe.arrowWidth - HistorySwipe.arrowStroke) / 2
        let head = (HistorySwipe.arrowHeight - HistorySwipe.arrowStroke) / 2
        let tip = CGPoint(x: centre.x + sign * half, y: centre.y)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x - sign * half, y: centre.y))
        path.addLine(to: tip)
        path.move(to: CGPoint(x: tip.x - sign * head, y: centre.y - head))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - sign * head, y: centre.y + head))
        return path
    }
}
#endif
