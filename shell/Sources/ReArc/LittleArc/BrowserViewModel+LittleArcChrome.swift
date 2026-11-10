import AppKit
import SidebarModel

/// Engines that report a ⌥⌘-click on a link instead of following it.
protocol LittleArcLinkOpening: AnyObject {
    var littleArcLinkHandler: ((URL) -> Void)? { get set }
}

/// Wave 26 Little Arc: its toolbar (address field, back, forward, reload,
/// profile), New Little Arc Window, the global hotkey and ⌥⌘-click
/// (PEEK-LITTLE-BROWSER §2–§2.2).
extension BrowserViewModel {

    /// The key window's Little Arc engine, for navigation commands.
    var keyLittleArcEngine: (any WebEngine)? {
        guard let id = keyLittleArcID, store.littleArcWindow(withID: id) != nil else { return nil }
        return littleArcEngine(for: id)
    }

    /// New Little Arc Window (⌥⌘N, the global hotkey): a blank Little Arc
    /// with its address field ready for typing.
    @discardableResult
    func openBlankLittleArc() -> LittleArcWindow {
        let record = openLittleArc(url: URL(string: "about:blank")!, title: "Little ReArc")
        littleArcFocusRequest = record.id
        return record
    }

    /// Return in the Little Arc address field: a URL or a search, in that window.
    @discardableResult
    func navigateLittleArc(_ id: LittleArcWindow.ID, to text: String) -> Bool {
        guard store.littleArcWindow(withID: id) != nil,
              let url = URLEntry.resolve(text, engine: engineHost.navigationSchemes, provider: searchProvider),
              NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else { return false }
        store.updateLittleArcWindow(id: id, title: url.host(), url: url)
        littleArcEngine(for: id).load(url)
        return true
    }

    /// The Little Arc's profile menu: the page reloads with that profile's storage.
    func changeLittleArcProfile(_ id: LittleArcWindow.ID, to profileID: Profile.ID) {
        guard let record = store.littleArcWindow(withID: id), store.setLittleArcProfile(id, to: profileID) else { return }
        let current = engineHost.existingLittleArcEngine(id, profileID: record.profileID)?.currentURL
        engineHost.removeLittleArc(id, profileID: record.profileID)
        if let current, current.absoluteString != "about:blank" {
            store.updateLittleArcWindow(id: id, title: nil, url: current)
        }
        loadLittleArcIfNeeded(id)
    }

    /// The opt-in system-wide ⌥⌘N.
    var isLittleArcHotkeyEnabled: Bool {
        get { littleArcHotkeyPreference.isEnabled }
        set {
            littleArcHotkeyPreference.isEnabled = newValue
            littleArcHotkeyPreference.save(to: littleArcHotkeyDefaults)
            updateLittleArcHotkey()
        }
    }

    /// Registers or drops the global hotkey to match the preference. Returns
    /// false when it is on but the system refused the combination.
    @discardableResult
    func updateLittleArcHotkey() -> Bool {
        guard littleArcHotkeyPreference.isEnabled else {
            littleArcHotkey = nil
            return true
        }
        guard littleArcHotkey == nil else { return true }
        littleArcHotkey = GlobalHotkey(keyCode: LittleArcHotkeyPreference.keyCode, modifiers: [.command, .option]) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.openBlankLittleArc()
        }
        return littleArcHotkey != nil
    }

    /// The keys held at the last mouse-down (the app-wide monitor records
    /// them): Chromium's new-tab event for that click arrives later, when
    /// the keys may already be up.
    func noteMouseDown(modifiers: NSEvent.ModifierFlags, at date: Date = Date()) {
        lastMouseDown = (modifiers.intersection(.deviceIndependentFlagsMask), date)
    }

    /// True once for a Chromium-created tab that a ⌥⌘-click made in the last two seconds.
    func takeLittleArcClick(now: Date = Date()) -> Bool {
        guard littleArcOnModifiedClick, let click = lastMouseDown, now.timeIntervalSince(click.at) < 2 else { return false }
        let flags = click.modifiers
        guard LittleArcChrome.clickOpensLittleArc(
            command: flags.contains(.command), option: flags.contains(.option),
            shift: flags.contains(.shift), control: flags.contains(.control)
        ) else { return false }
        lastMouseDown = nil
        return true
    }

    /// ⌥⌘-click in a sidebar tab's page: Little Arc in the source page's profile.
    /// Off in Settings › Links: the click follows the link as usual.
    func configureLittleArcClicks(on engine: any WebEngine, profileID: Profile.ID) {
        guard littleArcOnModifiedClick else {
            (engine as? LittleArcLinkOpening)?.littleArcLinkHandler = nil
            return
        }
        (engine as? LittleArcLinkOpening)?.littleArcLinkHandler = { [weak self] url in
            self?.openLittleArc(url: url, profileID: profileID)
        }
    }

    /// At launch: the saved hotkey preference, registered when it is on.
    func startLittleArcHotkey() {
        guard !littleArcHotkeyStarted else { return }
        littleArcHotkeyStarted = true
        littleArcHotkeyPreference = .load(from: littleArcHotkeyDefaults)
        updateLittleArcHotkey()
    }
}

extension BrowserViewModel {
    func canSplitLittleArcWindow(_ id: LittleArcWindow.ID) -> Bool {
        store.keyWindowID != nil && store.canSplitLittleArcToCurrentTab(id: id)
    }

    /// Open the live page beside the last focused browser window's tab.
    /// Like Open in, this closes the Little Arc only after the split exists.
    @discardableResult
    func splitLittleArcWindow(_ id: LittleArcWindow.ID) -> Bool {
        guard let target = store.keyWindowID, let record = store.littleArcWindow(withID: id) else { return false }
        if let tab = store.selectedTab, store.splitContaining(tabID: tab.id)?.split.isFull == true {
            showSplitFullToast()
            return false
        }
        guard canSplitLittleArcWindow(id) else { return false }
        if let engine = engineHost.existingLittleArcEngine(id, profileID: record.profileID) {
            store.updateLittleArcWindow(id: id, title: engine.pageTitle.flatMap { $0.isEmpty ? nil : $0 }, url: engine.currentURL)
        }
        guard store.splitLittleArcToCurrentTab(id: id) != nil else { return false }
        engineHost.removeLittleArc(id, profileID: record.profileID)
        if focusedLittleArcID == id { focusedLittleArcID = nil }
        if keyLittleArcID == id { keyLittleArcID = nil }
        closeLibrary(in: target)
        loadSelectedIfNeeded()
        windowPresenter?.focusBrowserWindow(target)
        windowPresenter?.dismissLittleArcWindow(id)
        return true
    }
}
