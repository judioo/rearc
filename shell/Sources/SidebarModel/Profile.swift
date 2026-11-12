import Foundation

/// Visual identity for a profile in the chrome (SF Symbol, emoji or picture on a tinted circle).
public struct ProfileAvatarDescriptor: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case sfSymbol(name: String)
        case emoji(String)
    }

    /// The symbol or emoji, also shown wherever `image` cannot be: on a Mac
    /// without the file, and in builds before pictures (677 and older).
    public var kind: Kind
    /// A picture chosen in Settings, by its file in `ProfileAvatarImageStore`.
    /// Its own key, not a `Kind` case: older builds throw on a case they do
    /// not know, which quarantines sidebar.json, and skip a key they do not know.
    public var image: ProfileAvatarImageName?

    public init(kind: Kind, image: ProfileAvatarImageName? = nil) {
        self.kind = kind
        self.image = image
    }

    enum CodingKeys: String, CodingKey { case kind, image }

    /// Total: a kind from a later build shows the default symbol, and a bad
    /// image name shows the kind.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? Self.personalDefault().kind
        image = try? c.decodeIfPresent(ProfileAvatarImageName.self, forKey: .image)
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

    /// The profile a space still names after it went missing: the known one when `known`
    /// has it, otherwise a new "Recovered Container" under the same UUID, so the engine
    /// reopens that container's own storage (security RC-0.1.0-564 S-05).
    public static func recovered(_ id: UUID, from known: [Profile]) -> Profile {
        known.first { $0.id == id } ?? Profile(id: id, name: "Recovered Container")
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, themeColor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = (try? c.decodeIfPresent(ProfileAvatarDescriptor.self, forKey: .avatar)) ?? .personalDefault()
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
