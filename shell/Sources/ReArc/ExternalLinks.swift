import AppKit
import SidebarModel

/// Receives links other apps open in ReArc (the `GetURL` Apple Event sent
/// to the default browser) on both engines, and hands them to the model.
/// Links that arrive before the model exists (the one that launched the
/// app) wait until it attaches.
final class ExternalLinkRouter: NSObject {
    static let shared = ExternalLinkRouter()

    private weak var model: BrowserViewModel?
    private var pending: [URL] = []
    private var observers: [NSObjectProtocol] = []

    /// Installs the handler now and again around launch, since AppKit (and
    /// SwiftUI's app delegate) may install their own while finishing launch.
    func install() {
        installHandler()
        guard observers.isEmpty else { return }
        for name in [NSApplication.willFinishLaunchingNotification, NSApplication.didFinishLaunchingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.installHandler()
            })
        }
    }

    private func installHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func attach(_ model: BrowserViewModel) {
        installHandler()
        self.model = model
        let queued = pending
        pending = []
        queued.forEach { model.openExternalURL($0) }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        receive(url)
    }

    func receive(_ url: URL) {
        if let model {
            model.openExternalURL(url)
        } else {
            pending.append(url)
        }
    }
}

/// Whether ReArc is the default web browser, and asking macOS to make it so.
protocol DefaultBrowserSetting {
    /// Only an app bundle can be registered (`swift run` cannot).
    var canBecomeDefault: Bool { get }
    var isDefault: Bool { get }
    /// macOS asks the user to confirm; `completion` gets nil on success.
    func makeDefault(_ completion: @escaping (Error?) -> Void)
}

/// LaunchServices through NSWorkspace (the replacement for
/// `LSSetDefaultHandlerForURLScheme`). http and https are set together.
struct SystemDefaultBrowser: DefaultBrowserSetting {
    var bundle: Bundle = .main

    var canBecomeDefault: Bool {
        bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil
    }

    var isDefault: Bool {
        guard canBecomeDefault,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == bundle.bundleIdentifier
    }

    func makeDefault(_ completion: @escaping (Error?) -> Void) {
        let app = bundle.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            if let error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { error in
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}

extension BrowserViewModel {

    /// A link from another app: focus it if already open, else Little Arc or
    /// a new tab in the current space, per the user's choice.
    func openExternalURL(_ url: URL) {
        switch ExternalLinkRouting.route(url, destination: externalLinkDestination, in: store, engine: engineHost.navigationSchemes) {
        case .littleArc(let url, let profileID):
            openLittleArc(url: url, profileID: profileID)
        case .newTab(let url, _):
            openInNewTab(url)
        case .focusTab(let id):
            store.focusTab(id)
            loadSelectedIfNeeded()
        case .rejected:
            return
        }
        NSApp?.activate(ignoringOtherApps: true)
    }

    var isDefaultBrowser: Bool { defaultBrowser.isDefault }

    /// Set as Default Browser (app menu, command bar). The result shows in
    /// `defaultBrowserMessage` when there is something to say.
    func setAsDefaultBrowser() {
        guard defaultBrowser.canBecomeDefault else {
            defaultBrowserMessage = "Run ReArc from its app bundle to make it your default browser."
            return
        }
        guard !defaultBrowser.isDefault else {
            defaultBrowserMessage = "ReArc is already your default browser."
            return
        }
        defaultBrowser.makeDefault { [weak self] error in
            guard let self else { return }
            if let error {
                self.defaultBrowserMessage = "ReArc could not become the default browser: \(error.localizedDescription)"
            } else {
                self.defaultBrowserRevision += 1
            }
        }
    }
}
