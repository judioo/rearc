import AppKit
import SidebarModel
import UniformTypeIdentifiers

// MARK: - File panels

/// An open panel the engine can withdraw.
protocol FilePanelHandle: AnyObject {
    func close()
}

/// Presents the open or save panel for a page's file chooser. The
/// completion runs once: chosen file URLs, or nil when cancelled or closed.
protocol FilePanelPresenting: AnyObject {
    func present(_ request: FileChooserRequest, in window: NSWindow?, completion: @escaping ([URL]?) -> Void) -> FilePanelHandle?
}

/// NSOpenPanel / NSSavePanel, as a sheet on the page's window (only that
/// window waits; other windows stay usable), else a free-standing panel.
final class SystemFilePanelPresenter: FilePanelPresenting {
    private final class Handle: FilePanelHandle {
        weak var panel: NSSavePanel?
        func close() { panel?.cancel(nil) }
    }

    func present(_ request: FileChooserRequest, in window: NSWindow?, completion: @escaping ([URL]?) -> Void) -> FilePanelHandle? {
        let panel = Self.makePanel(for: request)
        let handle = Handle()
        handle.panel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return completion(nil) }
            if let open = panel as? NSOpenPanel {
                completion(open.urls)
            } else {
                completion(panel.url.map { [$0] })
            }
        }
        if let window, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
        return handle
    }

    static func makePanel(for request: FileChooserRequest) -> NSSavePanel {
        if request.isSave {
            let panel = NSSavePanel()
            let defaults = request.saveDefaults(fallbackDirectory: DownloadsController.defaultDirectory.path)
            panel.directoryURL = URL(fileURLWithPath: defaults.directory, isDirectory: true)
            panel.nameFieldStringValue = defaults.fileName
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.prompt = request.prompt
            if let message = request.message { panel.message = message }
            // NSSavePanel confirms replacing an existing file itself.
            return panel
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !request.choosesDirectories
        panel.canChooseDirectories = request.choosesDirectories
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        panel.canCreateDirectories = request.mode == .openDirectory
        panel.resolvesAliases = true
        panel.prompt = request.prompt
        if let message = request.message { panel.message = message }
        if !request.choosesDirectories, let types = contentTypes(for: request.filter) {
            panel.allowedContentTypes = types
        }
        if !request.defaultPath.isEmpty, request.defaultPath.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: request.defaultPath)
        }
        return panel
    }

    /// The page's accept list as content types; nil (any file) when it is
    /// empty or names a type macOS does not know, since the filter is advisory.
    static func contentTypes(for filter: FileTypeFilter) -> [UTType]? {
        guard !filter.isEmpty else { return nil }
        var types: [UTType] = []
        for ext in filter.extensions {
            guard let type = UTType(filenameExtension: ext) else { return nil }
            types.append(type)
        }
        for mime in filter.mimeTypes {
            let wildcard: [String: UTType] = ["image/*": .image, "video/*": .movie, "audio/*": .audio, "text/*": .text]
            // An undeclared MIME type maps to a dynamic type no file on disk carries.
            if let type = wildcard[mime] ?? UTType(mimeType: mime), !type.isDynamic {
                types.append(type)
            } else {
                return nil
            }
        }
        return types
    }
}

// MARK: - Page context menu

protocol PageContextMenuPresenting: AnyObject {
    /// Shows `plan` at `point` (top-left coordinates of `view`); `completion`
    /// gets the chosen item, or nil when the menu closed without one.
    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void)
}

/// The page menu as a native NSMenu. It opens after the engine's callback
/// returns (never inside a Chromium task), and tracking does not block the
/// engine: Chromium's pump keeps running in the event-tracking mode.
final class NSMenuContextMenuPresenter: NSObject, PageContextMenuPresenting {
    private var chosen: PageContextMenuItem?
    private var items: [PageContextMenuItem] = []

    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void) {
        guard let view, view.window != nil else { return completion(nil) }
        let menu = makeMenu(plan)
        DispatchQueue.main.async { [self] in
            chosen = nil
            let location = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
            menu.popUp(positioning: nil, at: location, in: view)
            let result = chosen
            chosen = nil
            completion(result)
        }
    }

    func makeMenu(_ plan: PageContextMenuPlan) -> NSMenu {
        let menu = NSMenu(title: "Page")
        menu.autoenablesItems = false
        items = []
        for (index, section) in plan.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in section {
                let item = NSMenuItem(title: entry.item.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = items.count
                item.isEnabled = entry.isEnabled
                if entry.item == .inspect, !entry.isEnabled {
                    item.toolTip = "Developer tools are not available in this engine build"
                }
                if let symbol = Self.symbol(for: entry.item) {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                items.append(entry.item)
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        chosen = items[sender.tag]
    }

    /// Arc marks its own link destinations with their icons.
    static func symbol(for item: PageContextMenuItem) -> String? {
        switch item {
        case .openLinkInLittleArc: return "macwindow.on.rectangle"
        case .openLinkInNewSplit: return "rectangle.split.2x1"
        case .searchFor: return "magnifyingglass"
        default: return nil
        }
    }
}
