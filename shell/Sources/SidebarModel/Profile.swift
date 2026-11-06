import Foundation

/// Visual identity for a profile in the chrome (SF Symbol or emoji on a tinted circle).
public struct ProfileAvatarDescriptor: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case sfSymbol(name: String)
        case emoji(String)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static func personalDefault() -> ProfileAvatarDescriptor {
        ProfileAvatarDescriptor(kind: .sfSymbol(name: "person.fill"))
    }
}

public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var avatar: ProfileAvatarDescriptor
    public var themeColor: SpaceTheme

    public init(
        id: UUID = UUID(),
        name: String,
        avatar: ProfileAvatarDescriptor = .personalDefault(),
        themeColor: SpaceTheme = .default
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.themeColor = themeColor
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, themeColor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decodeIfPresent(ProfileAvatarDescriptor.self, forKey: .avatar) ?? .personalDefault()
        themeColor = try c.decodeIfPresent(SpaceTheme.self, forKey: .themeColor) ?? .default
    }

    public static func personalDefault(id: UUID = UUID()) -> Profile {
        Profile(
            id: id,
            name: "Personal",
            avatar: .personalDefault(),
            themeColor: SpaceTheme.presets[0]
        )
    }
}

public enum ProfileMutationError: Equatable, Sendable {
    case profileNotFound
    case cannotDeleteLastProfile
    case profileOwnsSpaces(count: Int)
    case duplicateName
}

/// Item overrides use the same glyph encoding as profile avatars.
public typealias SidebarItemIcon = ProfileAvatarDescriptor.Kind
