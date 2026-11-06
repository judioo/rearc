import Foundation

/// Why a Little Arc window left the live set (mirrors archive source semantics).
public enum LittleArcArchiveReason: String, Codable, Equatable {
    case manual
    case auto
}

/// A minimal standalone browser window persisted while open.
public struct LittleArcWindow: Identifiable, Equatable, Codable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var profileID: Profile.ID
    public var createdAt: Date
    public var lastActiveAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, url, title, profileID, createdAt, lastActiveAt
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        profileID: Profile.ID,
        createdAt: Date = Date(),
        lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.profileID = profileID
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt ?? createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActiveAt = try c.decode(Date.self, forKey: .lastActiveAt)
        // v7 snapshots omit profileID; v7→v8 migration assigns the active profile.
        profileID = try c.decodeIfPresent(Profile.ID.self, forKey: .profileID)
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastActiveAt, forKey: .lastActiveAt)
    }
}

/// Little Arc window moved to the archive list (sidebar archive analogue).
public struct ArchivedLittleArcWindow: Identifiable, Equatable, Codable {
    public let id: UUID
    public var window: LittleArcWindow
    public var archivedAt: Date
    public var reason: LittleArcArchiveReason

    public init(window: LittleArcWindow, archivedAt: Date = Date(), reason: LittleArcArchiveReason) {
        self.id = window.id
        self.window = window
        self.archivedAt = archivedAt
        self.reason = reason
    }
}

public enum LittleArcPolicy {
    /// INFERRED: Arc syncs a configurable threshold; 24h is a reasonable default for idle Little Arcs.
    public static let autoArchiveIdleThreshold: TimeInterval = 24 * 60 * 60

    /// Archives live windows idle longer than `threshold` at `referenceDate`;
    /// `keeping` (the key window) stays whatever its age.
    public static func windowsEligibleForAutoArchive(
        live: [LittleArcWindow],
        referenceDate: Date,
        threshold: TimeInterval = autoArchiveIdleThreshold,
        keeping: Set<LittleArcWindow.ID> = []
    ) -> [LittleArcWindow.ID] {
        live.filter { !keeping.contains($0.id) && referenceDate.timeIntervalSince($0.lastActiveAt) > threshold }
            .map(\.id)
    }
}

/// Settings › Links › Archive Little Arcs after (Arc's pop-up; ReArc's
/// default stays the 24 hours it used before the setting existed).
public enum LittleArcArchivePreference {
    public static let defaultsKey = "rearc.littleArcArchiveAfter"
    public static let defaultValue: AutoArchiveThreshold = .oneDay

    public static func load(from defaults: UserDefaults) -> AutoArchiveThreshold {
        defaults.string(forKey: defaultsKey).flatMap(AutoArchiveThreshold.init(rawValue:)) ?? defaultValue
    }

    public static func save(_ threshold: AutoArchiveThreshold, to defaults: UserDefaults) {
        defaults.set(threshold.rawValue, forKey: defaultsKey)
    }
}
