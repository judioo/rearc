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
    /// Set on a container: a separate browsing session for one space of this
    /// parent profile (SPACE-CONTAINERS.md). The space stays in the parent's
    /// strip and follows its settings; `SidebarStore.parentProfile(ofContainer:)`
    /// says whether the link holds. Builds up to 0.1.0 (677) ignore the key
    /// and show the container as a plain profile.
    public var containerOf: Profile.ID?

    public init(
        id: UUID = UUID(),
        name: String,
        avatar: ProfileAvatarDescriptor = .personalDefault(),
        themeColor: SpaceTheme = .default,
        containerOf: Profile.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.themeColor = themeColor
        self.containerOf = containerOf
    }

    /// The profile a space still names after it went missing: the known one when `known`
    /// has it, otherwise a new "Recovered Container" under the same UUID, so the engine
    /// reopens that container's own storage (security RC-0.1.0-564 S-05).
    public static func recovered(_ id: UUID, from known: [Profile]) -> Profile {
        known.first { $0.id == id } ?? Profile(id: id, name: "Recovered Container")
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, themeColor, containerOf }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decodeIfPresent(ProfileAvatarDescriptor.self, forKey: .avatar) ?? .personalDefault()
        themeColor = try c.decodeIfPresent(SpaceTheme.self, forKey: .themeColor) ?? .default
        // A link that does not read leaves a plain profile, never a failed load.
        containerOf = (try? c.decodeIfPresent(Profile.ID.self, forKey: .containerOf)) ?? nil
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
