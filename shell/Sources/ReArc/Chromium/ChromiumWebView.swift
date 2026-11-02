#if REARC_CHROMIUM
import AppKit
import ReArcEngine
import SwiftUI

/// SwiftUI host for a Chromium tab. The engine's view is a leased, +1 retained
/// NSView (C-ABI.md "Core callbacks and ownership"): attach when the host
/// enters a window, detach on dismantle/identity change, then ReArcViewRelease.
struct ChromiumWebView: NSViewRepresentable {
    let engine: ChromiumEngine

    func makeNSView(context: Context) -> ChromiumHostView {
        ChromiumHostView(engine: engine)
    }

    func updateNSView(_ nsView: ChromiumHostView, context: Context) {
        nsView.bind(engine)
    }

    static func dismantleNSView(_ nsView: ChromiumHostView, coordinator: ()) {
        nsView.dismantle()
    }
}

final class ChromiumHostView: NSView {
    private struct Lease {
        let tabID: UInt64
        let attachmentID: UInt64
        let windowID: UInt64
        /// The ABI's +1 retain; balanced by exactly one ReArcViewRelease.
        let retained: UnsafeMutableRawPointer
        let view: NSView
    }

    private(set) var engine: ChromiumEngine
    private var lease: Lease?
    private var dismantled = false
    private var reportedSize: CGSize = .zero
    private var reportedScale: CGFloat = 0

    init(engine: ChromiumEngine) {
        self.engine = engine
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ newEngine: ChromiumEngine) {
        guard newEngine !== engine else { return }
        releaseLease(detach: true)
        engine = newEngine
        reconcile()
    }

    func dismantle() {
        dismantled = true
        releaseLease(detach: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcile()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    override func layout() {
        super.layout()
        lease?.view.frame = bounds
        pushSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushSize()
    }

    /// Attach to the current window, re-attaching after a window or tab change.
    func reconcile() {
        guard !dismantled, let window else {
            releaseLease(detach: true)
            return
        }
        guard engine.ensureTab() else { return }
        let windowID = ChromiumRuntime.shared.windowID(for: window)
        guard windowID != 0 else { return }
        if let lease, lease.windowID == windowID, lease.tabID == engine.tabID {
            updateVisibility()
            return
        }
        releaseLease(detach: true)
        attach(windowID: windowID, scale: window.backingScaleFactor)
    }

    private func attach(windowID: UInt64, scale: CGFloat) {
        engine.claimLease(for: self)
        let tabID = engine.tabID
        var attachment = ReArcAttachment()
        let size = bounds.size
        let status = ReArcViewAttach(tabID, windowID, Double(size.width), Double(size.height), Double(scale), &attachment)
        guard status == .rearcOK, let retained = attachment.native_view else {
            ChromiumLog.info("tab \(tabID) attach rejected: \(status.rearcName)")
            return
        }
        let view = Unmanaged<NSView>.fromOpaque(retained).takeUnretainedValue()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        lease = Lease(
            tabID: tabID,
            attachmentID: attachment.attachment_id,
            windowID: windowID,
            retained: retained,
            view: view
        )
        reportedSize = size
        reportedScale = scale
        ChromiumRuntime.shared.registerLease(attachment.attachment_id, host: self)
        engine.leaseChanged(attachment.attachment_id, host: self)
        updateVisibility()
    }

    /// Ends this host's lease. `detach` is false when the engine already
    /// invalidated it (it emptied the host and dropped its own retain).
    func releaseLease(detach: Bool) {
        guard let lease else { return }
        self.lease = nil
        ChromiumRuntime.shared.unregisterLease(lease.attachmentID)
        if detach {
            let status = ReArcViewDetach(lease.tabID, lease.attachmentID)
            if status != .rearcOK, status != ReArcStatus(REARC_STALE_ATTACHMENT) {
                ChromiumLog.info("tab \(lease.tabID) detach rejected: \(status.rearcName)")
            }
        }
        lease.view.removeFromSuperview()
        ReArcViewRelease(lease.retained)
        engine.leaseChanged(nil, host: self)
    }

    /// reason: 0 tab_closed, 1 window_closed, 2 content_replaced, 3 engine_stopped.
    func leaseInvalidated(reason: UInt32) {
        ChromiumLog.info("lease \(lease?.attachmentID ?? 0) invalidated (reason \(reason))")
        releaseLease(detach: false)
        if reason == 2 {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
    }

    private func updateVisibility() {
        guard let lease else { return }
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        let status = ReArcViewSetVisible(lease.tabID, lease.attachmentID, visible)
        if status != .rearcOK {
            ChromiumLog.info("tab \(lease.tabID) visibility rejected: \(status.rearcName)")
        }
    }

    private func pushSize() {
        guard let lease, let window else { return }
        let size = bounds.size
        let scale = window.backingScaleFactor
        guard size != reportedSize || scale != reportedScale else { return }
        reportedSize = size
        reportedScale = scale
        let status = ReArcViewResize(lease.tabID, lease.attachmentID, Double(size.width), Double(size.height), Double(scale))
        if status != .rearcOK {
            ChromiumLog.info("tab \(lease.tabID) resize rejected: \(status.rearcName)")
        }
    }
}
#endif
