import AppKit
import SidebarModel

// MARK: - Install, re-enable, permission and uninstall sheets

protocol ExtensionPromptHandle: AnyObject {
    /// The engine withdrew the request: close without a reply.
    func close()
}

protocol ExtensionPromptPresenting: AnyObject {
    /// nil when it cannot be shown (the request is then cancelled).
    func present(_ request: ExtensionPromptRequest, in window: NSWindow?,
                 completion: @escaping (ExtensionPromptAction) -> Void) -> ExtensionPromptHandle?
}

/// An NSAlert sheet on the page's window (the key window for prompts that
/// belong to no tab), with Chromium's localized title, buttons, permission
/// lines and the extension's icon. One sheet per window at a time: later
/// requests wait their turn here instead of in AppKit's sheet queue, and a
/// sheet's 500 ms delay starts when it is on screen, so a queued sheet never
/// comes up already armed (security RC-0.1.0-544 F-10).
final class AlertExtensionPromptPresenter: ExtensionPromptPresenting {
    private final class Handle: ExtensionPromptHandle {
        weak var alert: NSAlert?
        weak var window: NSWindow?
        weak var presenter: AlertExtensionPromptPresenter?
        var withdrawn = false
        var shown = false
        var readyAt = TimeInterval.infinity
        var start: (() -> Void)?
        var keyObserver: NSObjectProtocol?

        func close() {
            withdrawn = true
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            guard shown else {
                presenter?.dequeue(self)
                return
            }
            guard let sheet = alert?.window, let window else { return }
            window.endSheet(sheet, returnCode: .abort)
        }
    }

    static let armDelay: TimeInterval = 0.5
    private var queues: [ObjectIdentifier: [Handle]] = [:]

    /// Build without presenting, so policy can be checked without opening UI.
    static func makeAlert(_ request: ExtensionPromptRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = request.displayTitle
        alert.informativeText = request.informativeText
        alert.alertStyle = request.isDestructive ? .warning : .informational
        if let data = request.iconPNG, let icon = NSImage(data: data) { alert.icon = icon }
        let accept = alert.addButton(withTitle: request.displayAcceptLabel)
        if request.isDestructive { accept.hasDestructiveAction = true }
        let cancel = alert.addButton(withTitle: request.displayCancelLabel)
        if request.cancelIsDefault {
            accept.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        }
        accept.isEnabled = false
        return alert
    }

    func present(_ request: ExtensionPromptRequest, in window: NSWindow?,
                 completion: @escaping (ExtensionPromptAction) -> Void) -> ExtensionPromptHandle? {
        guard let window else { return nil }
        let alert = Self.makeAlert(request)
        let accept = alert.buttons[0]
        let handle = Handle()
        handle.alert = alert
        handle.window = window
        handle.presenter = self
        let key = ObjectIdentifier(window)
        handle.start = { [weak self, weak handle, weak window] in
            guard let self, let handle, let window, !handle.withdrawn else { return }
            handle.shown = true
            // Arm once the sheet is on screen and key, not when it was asked for.
            handle.keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: alert.window, queue: .main
            ) { [weak handle, weak accept] _ in
                guard let handle, !handle.withdrawn, handle.readyAt == .infinity else { return }
                Self.arm(handle, accept: accept)
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                if let observer = handle.keyObserver { NotificationCenter.default.removeObserver(observer) }
                handle.keyObserver = nil
                let accepted = !handle.withdrawn && response == .alertFirstButtonReturn && accept.isEnabled
                    && ProcessInfo.processInfo.systemUptime >= handle.readyAt
                if !handle.withdrawn { completion(accepted ? .accept : .cancel) }
                self?.finished(handle, window: key)
            }
            if alert.window.isVisible, alert.window.isKeyWindow || window.attachedSheet === alert.window {
                Self.arm(handle, accept: accept)
            }
        }
        let busy = !(queues[key] ?? []).isEmpty
        queues[key, default: []].append(handle)
        if !busy { handle.start?() }
        return handle
    }

    private static func arm(_ handle: Handle, accept: NSButton?) {
        guard handle.readyAt == .infinity else { return }
        handle.readyAt = ProcessInfo.processInfo.systemUptime + armDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) { [weak handle, weak accept] in
            guard let handle, !handle.withdrawn else { return }
            accept?.isEnabled = true
        }
    }

    /// The sheet on `window` ended: show the next one.
    private func finished(_ handle: Handle, window key: ObjectIdentifier) {
        queues[key]?.removeAll { $0 === handle }
        if queues[key]?.isEmpty ?? true { queues[key] = nil }
        queues[key]?.first?.start?()
    }

    /// Withdrawn before it was shown.
    private func dequeue(_ handle: Handle) {
        for (key, queue) in queues where queue.contains(where: { $0 === handle }) {
            queues[key] = queue.filter { $0 !== handle }
            if queues[key]?.isEmpty ?? true { queues[key] = nil }
        }
    }

    /// Requests waiting behind the sheet on `window` (tests).
    func queuedCount(for window: NSWindow) -> Int {
        max(0, (queues[ObjectIdentifier(window)]?.count ?? 0) - 1)
    }
}
