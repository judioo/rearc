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
/// lines and the extension's icon.
final class AlertExtensionPromptPresenter: ExtensionPromptPresenting {
    private final class Handle: ExtensionPromptHandle {
        weak var alert: NSAlert?
        weak var window: NSWindow?
        var withdrawn = false
        var readyAt = TimeInterval.infinity

        func close() {
            withdrawn = true
            guard let sheet = alert?.window, let window else { return }
            window.endSheet(sheet, returnCode: .abort)
        }
    }

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
        alert.beginSheetModal(for: window) { response in
            guard !handle.withdrawn else { return }
            let accepted = response == .alertFirstButtonReturn && accept.isEnabled
                && ProcessInfo.processInfo.systemUptime >= handle.readyAt
            completion(accepted ? .accept : .cancel)
        }
        handle.readyAt = ProcessInfo.processInfo.systemUptime + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak handle, weak accept] in
            guard let handle, !handle.withdrawn else { return }
            accept?.isEnabled = true
        }
        return handle
    }
}
