import Foundation

/// The New Space dialog's fields (Arc `SpaceCreationView`: name, profile,
/// theme and icon, SIDEBAR-SPEC §4.6). Nothing is created until `create`.
public struct SpaceDraft: Equatable {
    public var name: String
    public var theme: SpaceTheme
    public var iconName: String
    public var profileID: Profile.ID

    public init(name: String, theme: SpaceTheme, iconName: String, profileID: Profile.ID) {
        self.name = name
        self.theme = theme
        self.iconName = iconName
        self.profileID = profileID
    }

    static let iconCycle = [
        "house.fill", "briefcase.fill", "star.fill", "flame.fill",
        "leaf.fill", "moon.fill", "globe", "music.note",
    ]

    /// Defaults for the next space in a profile: "Space N", the next preset
    /// theme and icon.
    public static func suggested(in store: SidebarStore, profileID: Profile.ID? = nil) -> SpaceDraft {
        let profile = profileID.flatMap { store.profile(withID: $0)?.id } ?? store.activeProfileID
        let index = store.spaces(in: profile).count
        return SpaceDraft(
            name: "Space \(index + 1)",
            theme: SpaceTheme.presets[index % SpaceTheme.presets.count],
            iconName: iconCycle[index % iconCycle.count],
            profileID: profile
        )
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A name is required and the profile must exist.
    public func canCreate(in store: SidebarStore) -> Bool {
        !trimmedName.isEmpty && store.profile(withID: profileID) != nil
    }
}

extension SidebarStore {
    /// Creates the drafted space and focuses it (switching to its profile).
    @discardableResult
    public func createSpace(from draft: SpaceDraft) -> Space? {
        guard draft.canCreate(in: self) else { return nil }
        let space = addSpace(name: draft.trimmedName, theme: draft.theme, iconName: draft.iconName, profileID: draft.profileID)
        if !draft.iconName.isEmpty { setSpaceIcon(space.id, iconName: draft.iconName) }
        selectSpace(space.id)
        return self.space(withID: space.id)
    }
}
