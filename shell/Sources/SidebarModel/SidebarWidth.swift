import Foundation

/// The sidebar's width (Arc `SidebarResizeState`, SIDEBAR-SPEC §3.3): dragged
/// from its trailing edge, clamped, and remembered across launches.
public enum SidebarWidth {
    public static let minimum: Double = 200
    public static let maximum: Double = 420
    public static let standard: Double = 228
    static let defaultsKey = "ReArcSidebarWidth"

    public static func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return standard }
        return min(max(width, minimum), maximum)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: defaultsKey)
        return stored == 0 ? standard : clamped(stored)
    }

    public static func save(_ width: Double, to defaults: UserDefaults = .standard) {
        defaults.set(clamped(width), forKey: defaultsKey)
    }
}
