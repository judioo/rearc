import Foundation

/// Settings › General › Side panel position: opposite the sidebar (the
/// default, as Arc and Chrome place it), or always on the window's left or
/// right. A fixed side that is the sidebar's puts the pane between the
/// sidebar and the page card.
public enum SidePanelPosition: String, CaseIterable, Sendable {
    case oppositeSidebar, left, right

    public static let defaultsKey = "rearc.sidePanelPosition"

    public var title: String {
        switch self {
        case .oppositeSidebar: return "Opposite the sidebar"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    public static func load(from defaults: UserDefaults) -> SidePanelPosition {
        defaults.string(forKey: defaultsKey).flatMap(SidePanelPosition.init(rawValue:)) ?? .oppositeSidebar
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Which side of the window an extension's side panel sits on: by default
/// the side opposite the sidebar (Arc and Chrome: the right, with the
/// sidebar on the left; Settings › General › Sidebar position Right puts it
/// on the left), else the side Settings › General › Side panel position
/// names. Every caller asks here (docs/arc-recordings/2026-11-06-side-panel.md §2).
public enum SidePanelPlacement {
    public static func side(sidebarSide: SidebarSide = .left,
                            position: SidePanelPosition = .oppositeSidebar) -> SidebarSide {
        switch position {
        case .oppositeSidebar: return sidebarSide.opposite
        case .left: return .left
        case .right: return .right
        }
    }
}

/// Where the pane goes against the sidebar and the page card. Opposite the
/// sidebar it takes the window's other edge, outside the sidebar and card's
/// layout. On the sidebar's side it sits between the two, laid out with the
/// card: the sidebar's width (less the card's inset) leads both, ⌘S slides
/// and the Library's widening move both, and HTML fullscreen drops both
/// lead and pane. Offsets are in points from the sidebar's window edge.
public struct SidePanelLayout: Equatable, Sendable {
    public var sidebarSide: SidebarSide
    public var position: SidePanelPosition

    public init(sidebarSide: SidebarSide, position: SidePanelPosition = .oppositeSidebar) {
        self.sidebarSide = sidebarSide
        self.position = position
    }

    public var side: SidebarSide { SidePanelPlacement.side(sidebarSide: sidebarSide, position: position) }

    /// Between the sidebar and the page card, rather than at the window's other edge.
    public var isBesideSidebar: Bool { side == sidebarSide }

    /// The pane holds the window's top left, where macOS draws the traffic
    /// lights, so its top clears them. On the left beside a left sidebar the
    /// lights are in the sidebar's top row instead.
    public var clearsTrafficLights: Bool { side == .left && sidebarSide == .right }

    /// Beside the sidebar, how far the pane and card start from the
    /// sidebar's window edge. Each keeps its own `inset` on that side (the
    /// pane at the window's edge, the card beside the pane), so at rest the
    /// lead is the sidebar's width less the inset and the first of them sits
    /// flush with the sidebar; with the sidebar hidden, sliding or in HTML
    /// fullscreen it is 0. `sidebarWidth` is the Library's `from` mid-widening.
    public static func lead(sidebarLaidOut: Bool, sidebarWidth: Double, inset: Double) -> Double {
        sidebarLaidOut ? max(0, sidebarWidth - inset) : 0
    }

    /// The pane's x offset while ⌘S hides the sidebar: it rides the receding
    /// edge, by the strip the card is cut at (`SidebarSlide.cut`), so it never
    /// sits under the sidebar. The card's own slide offset moves both.
    public func paneOffset(sidebarCut: Double) -> Double {
        guard isBesideSidebar else { return 0 }
        return sidebarCut * SidebarPlacement(side: sidebarSide).inward
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
/// (`sidePanel.setOptions({tabId})`) belongs to its tab: it hides when
/// another tab is shown and comes back, the same page, with its tab. Kept
/// panels stay alive while hidden. IDs are the engine's panel tab IDs.
public struct SidePanelWindowState: Equatable, Sendable {
    public var extensionID: String
    public var globalPanel: UInt64?
    /// Owner page tab → its contextual panel.
    public var contextualPanels: [UInt64: UInt64] = [:]
    /// The panel on screen; nil while the pane is hidden.
    public var shownPanel: UInt64?
    /// The page tab the panel is shown (or hidden) beside.
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
        /// Nothing for the tab, but the window keeps panels for other tabs:
        /// the pane hides until one of them is shown again.
        case hide
        /// Nothing for the tab and nothing kept: the pane closes.
        case close
    }

    /// What to show beside `tab`, from the engine's `ReArcTabGetSidePanel`,
    /// in Chrome's order on a tab switch (SidePanelUIBase::
    /// GetNewActiveKeyOnTabChanged): the tab's own panel, else the global
    /// one. A tab switch makes a panel only while one is on screen (a global
    /// panel follows the window; a tab's own options get their panel beside a
    /// shown global one); `explicit` (a toolbar click, sidePanel.open) makes
    /// it in any case.
    public func decision(for tab: UInt64, available: Bool, contextual: Bool, explicit: Bool = false) -> Decision {
        let nothing: Decision = panels.isEmpty ? .close : .hide
        guard available else { return nothing }
        if contextual {
            if let panel = contextualPanels[tab] { return .show(panel) }
            let besideGlobal = globalPanel != nil && shownPanel == globalPanel
            return explicit || besideGlobal ? .create(contextual: true) : nothing
        }
        if let globalPanel { return .show(globalPanel) }
        return explicit || shownPanel != nil ? .create(contextual: false) : nothing
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

    /// A page tab closed: its contextual panel goes with it (off screen too).
    public mutating func forget(ownerTab tab: UInt64) -> UInt64? {
        guard let panel = contextualPanels.removeValue(forKey: tab) else { return nil }
        if shownPanel == panel { shownPanel = nil }
        return panel
    }

    /// The close button, a second toolbar click or the shown page's
    /// `window.close()`: the shown panel goes, and the global one with it (as
    /// Chrome resets the window's active entry); other tabs' own panels stay
    /// for their tabs. Returns the panels to release.
    public mutating func closeShown() -> [UInt64] {
        let released = Set([shownPanel, globalPanel].compactMap { $0 }).sorted()
        for panel in released { forget(panel: panel) }
        return released
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
