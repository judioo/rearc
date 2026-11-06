import Foundation

/// Which side of the window an extension's side panel sits on: the side
/// opposite the sidebar (Arc and Chrome: the right, with the sidebar on the
/// left; Settings › General › Sidebar position Right puts it on the left).
/// Every caller asks here (docs/arc-recordings/2026-11-06-side-panel.md §2).
public enum SidePanelPlacement {
    public static func side(sidebarSide: SidebarSide = .left) -> SidebarSide {
        sidebarSide.opposite
    }
}

/// The side panel pane's width, shared by every window and persisted.
/// The recording's panel is about 373 pt (the page card gave up 378 pt);
/// 320 pt is Chrome's minimum side panel width. The page keeps at least
/// `minimumPageWidth`.
public enum SidePanelWidth {
    public static let defaultsKey = "rearc.extensionSidePanel.width"
    public static let standard: Double = 372
    public static let minimum: Double = 320
    public static let maximum: Double = 720
    public static let minimumPageWidth: Double = 420

    /// Within the pane's bounds; nil `available` (no window yet) skips the page rule.
    public static func clamped(_ width: Double, available: Double? = nil) -> Double {
        var upper = maximum
        if let available { upper = min(upper, available - minimumPageWidth) }
        return min(max(width, minimum), max(upper, minimum))
    }

    public static func load(from defaults: UserDefaults) -> Double {
        let stored = defaults.double(forKey: defaultsKey)
        return stored > 0 ? clamped(stored) : standard
    }

    public static func save(_ width: Double, to defaults: UserDefaults) {
        defaults.set(clamped(width), forKey: defaultsKey)
    }
}

/// One window's extension side panel (Chrome has one panel area per window).
/// A global panel (the extension's default options) stays on screen across
/// the window's tab switches with the same page; a contextual panel
/// (`sidePanel.setOptions({tabId})`) belongs to its tab and comes back when
/// that tab is shown again. IDs are the engine's panel tab IDs.
public struct SidePanelWindowState: Equatable, Sendable {
    public var extensionID: String
    public var globalPanel: UInt64?
    /// Owner page tab → its contextual panel.
    public var contextualPanels: [UInt64: UInt64] = [:]
    /// The panel on screen.
    public var shownPanel: UInt64?
    /// The page tab the panel is shown beside.
    public var ownerTab: UInt64

    public init(extensionID: String, ownerTab: UInt64) {
        self.extensionID = extensionID
        self.ownerTab = ownerTab
    }

    public enum Decision: Equatable, Sendable {
        /// An existing panel.
        case show(UInt64)
        /// Ask the engine for a panel of that scope.
        case create(contextual: Bool)
        /// The extension has no panel for the tab: the pane closes.
        case close
    }

    /// What to show beside `tab`, from the engine's `ReArcTabGetSidePanel`.
    public func decision(for tab: UInt64, available: Bool, contextual: Bool) -> Decision {
        guard available else { return .close }
        if contextual { return contextualPanels[tab].map(Decision.show) ?? .create(contextual: true) }
        return globalPanel.map(Decision.show) ?? .create(contextual: false)
    }

    /// Records a panel the engine made for `owner`.
    public mutating func adopt(panel: UInt64, contextual: Bool, owner: UInt64) {
        if contextual { contextualPanels[owner] = panel } else { globalPanel = panel }
    }

    /// Every panel tab this window holds.
    public var panels: [UInt64] {
        (globalPanel.map { [$0] } ?? []) + contextualPanels.values.sorted()
    }

    /// A panel tab went away (closed by its page or the engine). True when it
    /// was on screen.
    @discardableResult
    public mutating func forget(panel: UInt64) -> Bool {
        if globalPanel == panel { globalPanel = nil }
        contextualPanels = contextualPanels.filter { $0.value != panel }
        guard shownPanel == panel else { return false }
        shownPanel = nil
        return true
    }

    /// A page tab closed: its contextual panel goes with it.
    public mutating func forget(ownerTab tab: UInt64) -> UInt64? {
        contextualPanels.removeValue(forKey: tab)
    }
}

/// A toolbar click on an extension whose action opens its side panel
/// (`openPanelOnActionClick`), as Chrome toggles it.
public enum SidePanelToggle: Equatable, Sendable {
    case open
    /// Another extension's panel is shown: it closes, this one opens.
    case replace
    case close

    public static func resolve(shownExtension: String?, clicked: String) -> SidePanelToggle {
        guard let shownExtension else { return .open }
        return shownExtension == clicked ? .close : .replace
    }
}
