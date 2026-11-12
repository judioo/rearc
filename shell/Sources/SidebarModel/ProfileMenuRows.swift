import Foundation

/// One profile in the profile menus (the toolbar switcher, the mini
/// sidebar's Switch Profile, a space's profile choices, Little ReArc's
/// container). Names can be near-identical ("akilu", "Akilu"), so the
/// avatar and the space count tell them apart.
public struct ProfileMenuRow: Identifiable, Equatable, Sendable {
    public let profile: Profile
    public let spaceCount: Int
    /// The profile of what the menu is for: the window's space, the space,
    /// or the Little ReArc window. Drawn as the menu item's checkmark.
    public let isActive: Bool

    public var id: Profile.ID { profile.id }

    public var spaceCountText: String { Self.spaceCountText(spaceCount) }

    public static func spaceCountText(_ count: Int) -> String {
        switch count {
        case 0: return "No spaces"
        case 1: return "1 space"
        default: return "\(count.formatted()) spaces"
        }
    }
}

extension SidebarStore {
    /// Every profile, in the store's order, including those with no spaces.
    public func profileMenuRows(active: Profile.ID?) -> [ProfileMenuRow] {
        var counts: [Profile.ID: Int] = [:]
        for space in spaces { counts[space.profileID, default: 0] += 1 }
        return profiles.map { ProfileMenuRow(profile: $0, spaceCount: counts[$0.id] ?? 0, isActive: $0.id == active) }
    }
}
