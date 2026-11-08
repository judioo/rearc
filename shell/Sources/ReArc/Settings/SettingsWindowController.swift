import AppKit
import SidebarModel
import SwiftUI

/// The Chromium shell's Settings window (⌘,): Arc's preferences toolbar of
/// icon-over-label items, the selected pane's name as the title (the account
/// item's is the profile's), and a fixed 684 × 650 pt frame whose panes
/// scroll inside it (FEATURE-SPECS/SETTINGS.md §1).
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let model: BrowserViewModel
    private let capabilities: () -> SettingsCapabilities
    private let hosting: NSHostingController<AnyView>

    init(model: BrowserViewModel, capabilities: @escaping () -> SettingsCapabilities) {
        self.model = model
        self.capabilities = capabilities
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // Close only, as Arc's: minimise and zoom are off.
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The toolbar sits on the window's own white, as Arc's, not on a grey title bar.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(SettingsColors.background)
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ReArcSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: SettingsMetrics.windowSize.width, height: SettingsMetrics.contentHeight))
        fixSize()
        // Only the position is remembered (a launch on `REARC_DATA_DIR` keeps its own).
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        fixSize()
        window.setFrameAutosaveName(Self.frameName)
        showPane()
        observePane()
    }

    static let frameName = ShellDataLocation.isOverridden ? "ReArcSettings.isolated" : "ReArcSettings"

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ pane: SettingsPane?) {
        if let pane { model.settingsPane = pane }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 684 × 650 whatever the pane, as Arc's (and whatever an old saved frame said).
    private func fixSize() {
        guard let window else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = SettingsMetrics.windowSize
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: false)
        window.contentMinSize = window.contentRect(forFrameRect: frame).size
        window.contentMaxSize = window.contentMinSize
    }

    /// The pane changes from the toolbar or from inside (General's Profile
    /// Settings…); the account item follows the profile's name.
    private func observePane() {
        withObservationTracking {
            _ = model.settingsPane
            _ = model.accountName
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.showPane()
                self?.observePane()
            }
        }
    }

    private func showPane() {
        let pane = model.settingsPane
        window?.title = pane.title(accountName: model.accountName)
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == SettingsPane.account.rawValue }) {
            item.label = SettingsPane.account.title(accountName: model.accountName)
        }
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        hosting.rootView = AnyView(SettingsPaneView(model: model, pane: pane, capabilities: capabilities()))
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        model.settingsPane = pane
    }

    // MARK: NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title(accountName: model.accountName)
        item.image = pane == .icon ? ReArcMark.templateImage()
            : NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }
}
