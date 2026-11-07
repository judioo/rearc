import Foundation

/// Settings › General › Sidebar position (P3.14): Arc's sidebar on the
/// window's left (the default) or right. Other side-dependent chrome, such
/// as Chrome's extension side panel, takes `opposite` unless Settings ›
/// General › Side panel position fixes its side (`SidePanelPlacement`).
public enum SidebarSide: String, CaseIterable, Sendable {
    case left, right

    public static let defaultsKey = "rearc.sidebarSide"

    public var opposite: SidebarSide { self == .left ? .right : .left }

    public var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    public static func load(from defaults: UserDefaults) -> SidebarSide {
        defaults.string(forKey: defaultsKey).flatMap(SidebarSide.init(rawValue:)) ?? .left
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Where each piece of the window goes for a sidebar side. The layout reads
/// only this, so the left layout stays exactly as measured and the right
/// one is its mirror. Offsets are in points, x growing rightwards.
public struct SidebarPlacement: Equatable, Sendable {
    public var side: SidebarSide

    public init(side: SidebarSide) {
        self.side = side
    }

    /// From the sidebar towards the page: +1 on the left, −1 on the right.
    public var inward: Double { side == .left ? 1 : -1 }

    /// The window edge the sidebar, its edge-hover strip and its floating
    /// copy sit on.
    public var sidebarEdge: SidebarSide { side }

    /// The page card's edge beside the sidebar: ⌘S cuts the strip there
    /// that the sliding sidebar still covers. The other edge keeps the inset.
    public var cardSidebarEdge: SidebarSide { side }

    /// macOS draws the traffic lights at the top left whatever the side;
    /// only on the left do they sit in the sidebar's top row.
    public var trafficLightsEdge: SidebarSide { .left }
    public var trafficLightsInSidebar: Bool { side == .left }

    /// The resize handle is on the sidebar's inner edge.
    public var resizeHandleEdge: SidebarSide { side.opposite }

    /// The Library keeps its rail at the window's edge, the column beside the page.
    public var libraryRailEdge: SidebarSide { side }

    /// Row hover previews open over the page.
    public var hoverPreviewEdge: SidebarSide { side.opposite }

    /// A two-finger swipe pages spaces the same way on either side: the
    /// gesture follows the fingers, not the sidebar.
    public var mirrorsSpaceSwipe: Bool { false }

    /// The sidebar's x offset at `reveal` (1 shown, 0 hidden): it leaves
    /// through its own window edge. `growth` is the Library mid-widening.
    public func sidebarOffset(reveal: Double, width: Double, growth: LibrarySidebarGrowth? = nil) -> Double {
        let hidden = (reveal - 1) * width
        return (hidden + (growth?.sidebarOffset(width: width) ?? 0)) * inward
    }

    /// The page card's x offset for a ⌘S slide offset (a distance towards
    /// the page) and the Library's widening.
    public func pageOffset(slide: Double, growth: LibrarySidebarGrowth? = nil) -> Double {
        (slide + (growth?.pageOffset ?? 0)) * inward
    }

    /// The sidebar's width after a resize drag of `translation` points.
    public func resizedWidth(start: Double, translation: Double) -> Double {
        SidebarWidth.clamped(start + translation * inward)
    }

    /// How far `x` is from the sidebar's window edge, in a window `windowWidth` wide.
    public func distanceFromSidebarEdge(x: Double, windowWidth: Double) -> Double {
        side == .left ? x : windowWidth - x
    }

    /// With the sidebar hidden, a pointer this close to its edge floats it.
    public func revealsPeek(x: Double, windowWidth: Double, revealWidth: Double) -> Bool {
        let distance = distanceFromSidebarEdge(x: x, windowWidth: windowWidth)
        return distance >= 0 && distance <= revealWidth
    }

    /// The floating sidebar hides once the pointer is past `dismissWidth` from its edge.
    public func dismissesPeek(x: Double, windowWidth: Double, dismissWidth: Double) -> Bool {
        distanceFromSidebarEdge(x: x, windowWidth: windowWidth) > dismissWidth
    }
}
