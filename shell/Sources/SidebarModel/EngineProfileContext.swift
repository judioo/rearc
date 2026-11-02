import Foundation

/// Persistent browser storage identity for a profile. The shell maps this to a
/// profile-scoped website data store in the WebKit adapter.
public struct EngineProfileContext: Equatable, Sendable, Codable {
    public let profileID: Profile.ID
    /// Incognito-class sessions use a non-persistent store when this is true.
    public let isEphemeral: Bool

    public init(profileID: Profile.ID, isEphemeral: Bool = false) {
        self.profileID = profileID
        self.isEphemeral = isEphemeral
    }

    /// Stable identifier passed to `WKWebsiteDataStore(forIdentifier:)` — one store per profile.
    public var websiteDataStoreIdentifier: Profile.ID { profileID }
}
