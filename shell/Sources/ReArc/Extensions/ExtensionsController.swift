import AppKit
import SidebarModel

/// The engine side of the extensions toolbar (Chromium ABI 1.33). WebKit
/// has none, and the toolbar stays hidden there.
protocol ExtensionToolbarBackend: AnyObject {
    /// Asks for the tab's actions; the answer arrives through `setActions`.
    func refreshActions(for engine: any WebEngine, scale: CGFloat)
    /// A toolbar click: runs the action, or opens its popup under `anchor`.
    func runAction(_ extensionID: String, for engine: any WebEngine, anchor: NSView?)
    /// The window's page changed: a popup for another tab closes.
    func selectedEngineChanged(_ engine: (any WebEngine)?)
}

/// Arc-style extensions: pinned actions beside the URL field, everything
/// else in the extensions menu, popups under the clicked button. Actions are
/// per tab (chrome.action per-tab state), so they are kept per engine.
@Observable
final class ExtensionsController {
    static let webStoreURL = URL(string: "https://chromewebstore.google.com/")!

    /// The engine has toolbar actions (Chromium ABI 1.33 `extension_actions`).
    var isAvailable = false
    private(set) var actionsByEngine: [ObjectIdentifier: [ExtensionActionItem]] = [:]
    private(set) var pins: ExtensionPins
    /// The extension whose popup is open (its button stays highlighted).
    var openPopupExtensionID: String?
    @ObservationIgnored weak var backend: ExtensionToolbarBackend?
    /// Pins live here (a scratch suite in the self-test).
    @ObservationIgnored var defaults: UserDefaults {
        didSet { pins = ExtensionPins.load(from: defaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = ExtensionPins.load(from: defaults)
    }

    func actions(for engine: (any WebEngine)?) -> [ExtensionActionItem] {
        guard let engine else { return [] }
        return actionsByEngine[ObjectIdentifier(engine)] ?? []
    }

    func pinnedActions(for engine: (any WebEngine)?) -> [ExtensionActionItem] {
        pins.pinned(actions(for: engine))
    }

    func setActions(_ items: [ExtensionActionItem], for engine: AnyObject) {
        let key = ObjectIdentifier(engine)
        if actionsByEngine[key] != items { actionsByEngine[key] = items }
    }

    func forgetEngine(_ engine: AnyObject) {
        actionsByEngine[ObjectIdentifier(engine)] = nil
    }

    func refresh(_ engine: (any WebEngine)?, scale: CGFloat) {
        backend?.selectedEngineChanged(engine)
        guard isAvailable, let engine else { return }
        backend?.refreshActions(for: engine, scale: scale)
    }

    func run(_ extensionID: String, for engine: (any WebEngine)?, anchor: NSView?) {
        guard isAvailable, let engine else { return }
        backend?.runAction(extensionID, for: engine, anchor: anchor)
    }

    func togglePin(_ extensionID: String) {
        pins.toggle(extensionID)
        pins.save(to: defaults)
    }
}

extension BrowserViewModel {
    /// Opens `url` as a new today tab, if the engine admits it. Chromium's
    /// own pages reuse a tab already on that page's host (Chrome's singleton rule).
    func openPageInNewTab(_ url: URL, title: String? = nil) {
        guard NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else { return }
        let name = title ?? url.host() ?? url.absoluteString
        if url.scheme?.lowercased() == "chrome",
           let existing = store.displayTabs().first(where: { $0.url.scheme?.lowercased() == "chrome" && $0.url.host() == url.host() }) {
            store.updateTab(existing.id, title: name, url: url)
            store.focusTab(existing.id)
        } else {
            let tab = store.addTab(kind: .today, title: name, url: url)
            store.selectTab(tab.id)
        }
        loadSelectedIfNeeded()
    }

    func openChromeWebStore() {
        openPageInNewTab(ExtensionsController.webStoreURL, title: "Chrome Web Store")
    }
}
