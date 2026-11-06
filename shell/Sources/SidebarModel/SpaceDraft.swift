import Foundation

/// Create a Space's fields (Arc `SpaceCreationView`: name, profile,
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

    /// Arc's Create a Space opens blank: no name, so Create stays off until
    /// one is typed, no icon (the space gets the plain dot) and the built-in theme.
    public static func blank(in store: SidebarStore, profileID: Profile.ID? = nil) -> SpaceDraft {
        var draft = suggested(in: store, profileID: profileID)
        draft.name = ""
        draft.iconName = ""
        draft.theme = .arcDefault
        return draft
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
        let space = draft.iconName.isEmpty
            ? addSpace(name: draft.trimmedName, theme: draft.theme, profileID: draft.profileID)
            : addSpace(name: draft.trimmedName, theme: draft.theme, iconName: draft.iconName, profileID: draft.profileID)
        if !draft.iconName.isEmpty { setSpaceIcon(space.id, iconName: draft.iconName) }
        selectSpace(space.id)
        return self.space(withID: space.id)
    }
}

/// Create a Space in one window's sidebar. Arc pages it in after the
/// profile's last space (docs/arc-recordings/2026-11-06-space-swipe-feel-and-new-space.md
/// §2.4). The window keeps its space underneath, so Cancel, or a swipe
/// back onto a space, leaves the sidebar as it was.
public struct SpaceCreationSession: Equatable {
    public enum Origin: Equatable, Sendable {
        /// Pulled past the last space: the page pops in at once.
        case overscroll
        /// New Space from a menu, the + button or the command bar.
        case command
    }

    /// The pager's id for the creation page.
    public static let pageID = Space.ID(uuidString: "5BACE000-C0DE-4A11-8000-000000000001")!

    public var draft: SpaceDraft
    /// The window whose sidebar shows it (nil: whichever is key).
    public let window: SidebarWindowID?
    public let origin: Origin

    public init(draft: SpaceDraft, window: SidebarWindowID?, origin: Origin) {
        self.draft = draft
        self.window = window
        self.origin = origin
    }

    public func isShown(in window: SidebarWindowID?) -> Bool {
        self.window == nil || window == nil || self.window == window
    }

    /// The pager's pages: the profile's spaces, then the creation page.
    public static func pages(spaces: [Space.ID]) -> [Space.ID] {
        spaces + [pageID]
    }

    /// Arc's colour change when the page opens or closes without a swipe
    /// (§2.4): ≈ 2 frames after the pull, 0.25 s from a menu, 0.4 s on Cancel.
    public static func fadeDuration(opening origin: Origin?) -> Double {
        switch origin {
        case .overscroll: 0.03
        case .command: 0.25
        case nil: 0.4
        }
    }
}
