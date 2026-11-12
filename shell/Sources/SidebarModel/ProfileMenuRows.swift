import Foundation

/// One profile in the profile menus (the toolbar switcher, the mini
/// sidebar's Switch Profile, a space's profile choices, Little ReArc's
/// container). Names can be near-identical ("akilu", "Akilu"), so the
/// avatar and the space count tell them apart.
public struct ProfileMenuRow: Identifiable, Equatable, Sendable {
    public let profile: Profile
    /// The profile's name; a container's row ("Container for Mail") names its space.
    public let title: String
    /// A container's row (only in a menu that lists them: Little ReArc's).
    public let isContainer: Bool
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
    /// Every profile but containers, in the store's order, including those with
    /// no spaces. A profile's count includes its containers' spaces, and an
    /// `active` container checks its parent. With `includingContainers` (Little
    /// ReArc, whose window can use a container's session) each container
    /// follows its parent and only the exact `active` session is checked.
    public func profileMenuRows(active: Profile.ID?, includingContainers: Bool = false) -> [ProfileMenuRow] {
        var counts: [Profile.ID: Int] = [:]
        for space in spaces { counts[owningProfileID(of: space.profileID), default: 0] += 1 }
        let checked = includingContainers ? active : active.map(owningProfileID(of:))
        return listedProfiles.flatMap { profile in
            let row = ProfileMenuRow(profile: profile, title: profile.name, isContainer: false,
                                     spaceCount: counts[profile.id] ?? 0, isActive: profile.id == checked)
            guard includingContainers else { return [row] }
            return [row] + containers(of: profile.id).map { container in
                ProfileMenuRow(profile: container, title: containerTitle(container.id), isContainer: true,
                               spaceCount: spaces(in: container.id).count, isActive: container.id == checked)
            }
        }
    }
}
