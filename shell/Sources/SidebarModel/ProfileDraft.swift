import Foundation

/// Creation and editing stay local until the user saves the profile.
public struct ProfileDraft: Equatable {
    public var name: String
    public var avatar: ProfileAvatarDescriptor
    public var themeColor: SpaceTheme

    public init(name: String = "", avatar: ProfileAvatarDescriptor = .personalDefault(), themeColor: SpaceTheme = .default) {
        self.name = name
        self.avatar = avatar
        self.themeColor = themeColor
    }

    public init(profile: Profile) {
        self.init(name: profile.name, avatar: profile.avatar, themeColor: profile.themeColor)
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canSave: Bool { !trimmedName.isEmpty }
}

extension SidebarStore {
    @discardableResult
    public func createProfile(from draft: ProfileDraft, createInitialSpace: Bool = true) -> Profile? {
        guard draft.canSave else { return nil }
        return addProfile(name: draft.trimmedName, avatar: draft.avatar, themeColor: draft.themeColor,
                          createInitialSpace: createInitialSpace)
    }
}
