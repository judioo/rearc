import AppKit
import SwiftUI

/// Tracks true fullscreen on this view's window, independently of zoom.
struct WindowFullscreenReader: NSViewRepresentable {
    var onChange: (Bool, NSWindow) -> Void

    func makeNSView(context: Context) -> FullscreenTrackingView {
        let view = FullscreenTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: FullscreenTrackingView, context: Context) {
        view.onChange = onChange
    }
}

final class FullscreenTrackingView: NSView {
    var onChange: ((Bool, NSWindow) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        onChange?(window.styleMask.contains(.fullScreen), window)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onChange?(window.styleMask.contains(.fullScreen), window)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
