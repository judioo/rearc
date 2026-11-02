import AppKit
import SidebarModel
import SwiftUI

/// Reports when the host window becomes fully occluded (auto-PiP trigger input).
struct WindowOcclusionReader: NSViewRepresentable {
    var onChange: (WindowOcclusionState) -> Void

    func makeNSView(context: Context) -> OcclusionTrackingView {
        let view = OcclusionTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: OcclusionTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class OcclusionTrackingView: NSView {
    var onChange: ((WindowOcclusionState) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        report(window)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.report(window)
        }
    }

    private func report(_ window: NSWindow) {
        let visible = window.occlusionState.contains(.visible)
        onChange?(visible ? .visible : .fullyOccluded)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
