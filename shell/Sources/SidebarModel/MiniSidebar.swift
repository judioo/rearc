import Foundation

/// ReArc's mini sidebar (⇧⌘S, Toggle Mini Sidebar; Arc has no equivalent):
/// a window's sidebar shows its full rows, or a narrow column of icons in
/// the same order. ⌘S hides and shows the sidebar in whichever mode it is in.
public enum SidebarMode: String, Codable, Sendable, CaseIterable {
    case full, mini

    public var toggled: SidebarMode { self == .full ? .mini : .full }
}

/// What ⇧⌘S did: the window's new mode, and whether a hidden sidebar comes
/// back for it (a mode change nobody can see would read as a dead key).
public struct MiniSidebarToggle: Equatable, Sendable {
    public let mode: SidebarMode
    public let showsSidebar: Bool
}

/// Each browser window's sidebar mode. A window opened from another takes
/// that window's mode; a restored one takes its saved mode
/// (`SavedBrowserWindow.sidebarMode`); any other starts full. The mode never
/// touches the user's full width (`SidebarWidth`), so leaving mini mode
/// brings back the width they dragged.
public struct SidebarModes: Equatable, Sendable {
    private var modes: [SidebarWindowID: SidebarMode] = [:]

    public init() {}

    /// Unknown windows (and no window) are full.
    public func mode(in window: SidebarWindowID?) -> SidebarMode {
        window.flatMap { modes[$0] } ?? .full
    }

    public func isMini(in window: SidebarWindowID?) -> Bool { mode(in: window) == .mini }

    public func isRegistered(_ window: SidebarWindowID) -> Bool { modes[window] != nil }

    /// A new window: its saved mode, else the mode of the window it was
    /// opened from, else full. A window already registered keeps its mode.
    public mutating func open(_ window: SidebarWindowID, restoring saved: SidebarMode? = nil, openedFrom parent: SidebarWindowID? = nil) {
        guard modes[window] == nil else { return }
        modes[window] = saved ?? parent.flatMap { modes[$0] } ?? .full
    }

    public mutating func set(_ mode: SidebarMode, in window: SidebarWindowID) {
        modes[window] = mode
    }

    /// ⇧⌘S in `window`.
    @discardableResult
    public mutating func toggle(in window: SidebarWindowID, sidebarVisible: Bool) -> MiniSidebarToggle {
        let mode = mode(in: window).toggled
        modes[window] = mode
        return MiniSidebarToggle(mode: mode, showsSidebar: !sidebarVisible)
    }

    public mutating func forget(_ window: SidebarWindowID) {
        modes[window] = nil
    }

    /// The sidebar's width in `window` outside the Library: the mini column,
    /// or the user's own width.
    public func width(in window: SidebarWindowID?, fullWidth: Double) -> Double {
        isMini(in: window) ? MiniSidebarLayout.width : fullWidth
    }
}

/// The mini sidebar's geometry, in points from the sidebar's window edge.
/// It is the full sidebar's own rule with the titles gone: rows keep their
/// 8 pt inset and 41 pt pitch, and the 36 pt highlight is square, so a 16 pt
/// icon sits 10 pt in on every side, exactly where it is in the full
/// sidebar (x 18). The icons stay put while the edge moves (⇧⌘S), and the
/// highlight ends 8 pt before the page card as it does at full width.
public enum MiniSidebarLayout {
    public static let rowInset: Double = 8
    public static let highlight: Double = 36
    public static let iconSize: Double = 16
    public static let iconLeading: Double = (highlight - iconSize) / 2
    public static let width: Double = rowInset * 2 + highlight
    /// A folder's children step in 4 pt a level (14 at full width), at most
    /// two levels, so a nested icon stays inside its narrower highlight.
    public static let indentPerLevel: Double = 4
    public static let maxIndentLevels = 2

    public static func indent(depth: Int) -> Double {
        Double(min(max(depth, 0), maxIndentLevels)) * indentPerLevel
    }

    /// The row highlight's leading x and width for a row at `depth`.
    public static func highlight(depth: Int) -> (x: Double, width: Double) {
        let x = rowInset + indent(depth: depth)
        return (x, width - rowInset - x)
    }

    /// The icon's leading x for a row at `depth`.
    public static func iconX(depth: Int) -> Double {
        highlight(depth: depth).x + iconLeading
    }

    /// A trackpad scroll over the space switcher travels this far to step
    /// one space (a wheel notch steps at once).
    public static let scrollStep: Double = 24

    /// Favorites at mini width: one tile per row.
    public static func favorites(count: Int) -> FavoritesGridLayout {
        FavoritesGridLayout(itemCount: count, availableWidth: highlight)
    }
}

/// A mini row's tooltip, after the standard delay: the title it no longer
/// shows, then the site.
public enum MiniSidebarTooltip {
    public static func text(title: String, url: URL?, isUnloaded: Bool = false) -> String {
        var lines = [title]
        if let host = url?.host(), !host.isEmpty {
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if site != title { lines.append(site) }
        }
        if isUnloaded { lines.append("Unloaded — reloads when you open it") }
        return lines.joined(separator: "\n")
    }
}

/// How each part of the sidebar looks at mini width. Every part has one
/// (`MiniSidebarRepresentation.of`), so a new kind of row cannot be added
/// without deciding how it shows there.
public enum MiniSidebarRepresentation: Equatable, Sendable {
    /// Nothing drawn in the column: the traffic lights stay at the window's
    /// top left, over the column's empty top row and the page card's strip.
    case trafficLightsOverEmptyRow
    /// The space's icon; clicking opens the space menu.
    case spaceIconMenu
    /// The site's favicon, or the full sidebar's letter tile without one.
    case favicon
    /// The folder glyph (open, closed, with the dots of a live page).
    case folderGlyph
    /// The split's own icon, else its first pane's favicon with a split mark.
    case splitGlyph
    /// The easel or note glyph.
    case easelGlyph
    case plus
    case divider
    /// A drop target without its "Drop here…" words.
    case dropArea
    /// A badge on the space icon (Finish setup, sync trouble).
    case spaceIconBadge
    /// The media or call's favicon with its playing or capture state.
    case compactMediaIcon
    /// The bottom bar's button, alone on its own row.
    case stackedBarButton
    /// The current space's icon; click lists the spaces, scroll switches.
    case currentSpaceSwitcher
    /// Moved into the space menu.
    case inSpaceMenu
    /// Moved to the page card's toolbar strip, which mini mode always shows.
    case inCardToolbar

    /// One part of the sidebar, top to bottom.
    public enum Part: CaseIterable, Sendable {
        case trafficLights, sidebarToggle, navigationButtons, urlField, profileSwitcher
        case favorite
        case spaceHeader, pinnedTab, todayTab, folder, folderChild, split, easel
        case todayDivider, newTab, sectionDrop
        case liveVideo, mediaStrip, call
        case finishSetup, updateBanner
        case library, spaceSwitcher, syncAlert, downloads, newMenu
    }

    public static func of(_ part: Part) -> MiniSidebarRepresentation {
        switch part {
        case .trafficLights: .trafficLightsOverEmptyRow
        case .sidebarToggle, .navigationButtons, .urlField: .inCardToolbar
        case .profileSwitcher: .inSpaceMenu
        case .favorite, .pinnedTab, .todayTab, .folderChild: .favicon
        case .spaceHeader: .spaceIconMenu
        case .folder: .folderGlyph
        case .split: .splitGlyph
        case .easel: .easelGlyph
        case .todayDivider: .divider
        case .newTab, .newMenu: .plus
        case .sectionDrop: .dropArea
        case .liveVideo, .mediaStrip, .call: .compactMediaIcon
        case .finishSetup, .syncAlert: .spaceIconBadge
        case .updateBanner: .inSpaceMenu
        case .library, .downloads: .stackedBarButton
        case .spaceSwitcher: .currentSpaceSwitcher
        }
    }

    /// A list row's representation.
    public static func of(_ row: SidebarListRow) -> MiniSidebarRepresentation {
        switch row {
        case .header: of(Part.spaceHeader)
        case .todayDivider: of(Part.todayDivider)
        case .newTab: of(Part.newTab)
        case .sectionEnd: of(Part.sectionDrop)
        case .item(let item, let section):
            switch item.node.kind {
            case .tab: of(item.depth > 0 ? Part.folderChild : section == .pinned ? Part.pinnedTab : Part.todayTab)
            case .folder: of(Part.folder)
            case .split: of(Part.split)
            case .easel: of(Part.easel)
            }
        }
    }
}

/// The sidebar between two widths (⇧⌘S), on ⌘S's curve. Like ⌘S, the page
/// is laid out once per change: wide at the start of a narrowing, with the
/// strip the receding sidebar still covers cut from the card; beside the
/// old width through a widening, sliding with the sidebar's edge, and
/// narrow at the end. The sidebar shows its new rows at once, drawn up to
/// its moving edge.
public struct SidebarWidthMorph: Equatable, Sendable {
    public var from: Double
    public var to: Double
    /// The sidebar's edge as drawn, from `from` to `to`.
    public var shown: Double

    /// Nil when the width does not change. A change mid-way carries on from
    /// where the edge is drawn.
    public init?(from old: Double, to new: Double, current: SidebarWidthMorph? = nil) {
        let start = current?.shown ?? old
        guard abs(start - new) > 0.5 else { return nil }
        from = start
        to = new
        shown = start
    }

    public var isNarrowing: Bool { to < from }

    /// The width the page is laid out beside while the edge moves.
    public var layoutWidth: Double { min(from, to) }

    /// Narrowing: the part of the card the sidebar still covers.
    public var pageCut: Double { isNarrowing ? max(0, shown - to) : 0 }

    /// Widening: how far the page card has slid with the edge.
    public var pageOffset: Double { isNarrowing ? 0 : max(0, shown - from) }
}
