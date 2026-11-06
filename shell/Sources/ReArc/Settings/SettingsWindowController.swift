import AppKit
import SidebarModel
import SwiftUI

/// The Chromium shell's Settings window (⌘,): Arc's preferences toolbar of
/// icon-over-label items, the selected pane's name as the title, and the
/// window's height following the pane (ARC-RECORDING-2026-11-06 §6.1).
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let model: BrowserViewModel
    private let capabilities: () -> SettingsCapabilities
    private let hosting: NSHostingController<AnyView>

    init(model: BrowserViewModel, capabilities: @escaping () -> SettingsCapabilities) {
        self.model = model
        self.capabilities = capabilities
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The height follows the pane; only the position is remembered.
        if !window.setFrameUsingName("ReArcSettings") { window.center() }
        window.setFrameAutosaveName("ReArcSettings")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ReArcSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        showPane()
        observePane()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ pane: SettingsPane?) {
        if let pane { model.settingsPane = pane }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The pane changes from the toolbar or from inside (General's Profile Settings…).
    private func observePane() {
        withObservationTracking { _ = model.settingsPane } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.showPane()
                self?.observePane()
            }
        }
    }

    private func showPane() {
        let pane = model.settingsPane
        window?.title = pane.title
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
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }
}
